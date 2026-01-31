"""
DynamoDB DCS implementation for Patroni.

Uses DynamoDB conditional writes for distributed consensus and leader election.
"""

import json
import logging
import time
import uuid
from typing import Any, Callable, Dict, List, Optional, Tuple, TYPE_CHECKING, Union

import boto3
from botocore.exceptions import ClientError

from patroni.dcs import (
    AbstractDCS,
    Cluster,
    ClusterConfig,
    Failover,
    Leader,
    Member,
    Status,
    SyncState,
    TimelineHistory,
)
from patroni.exceptions import DCSError

if TYPE_CHECKING:
    from patroni.config import Config

logger = logging.getLogger(__name__)


class DynamoDBError(DCSError):
    """DynamoDB-specific DCS error."""
    pass


class DynamoDB(AbstractDCS):
    """
    DynamoDB-based Distributed Configuration Store for Patroni.

    Configuration (patroni.yml):
        dynamodb:
            region: ca-central-1
            table_name: softoboros-patroni
            failover_time: 60  # Estimated max failover time in seconds (default 60, min 15)
            # Optional: endpoint_url for local testing
            # endpoint_url: http://localhost:8000

    The failover_time parameter is the single "dial" for cost vs responsiveness tradeoff.
    All other timing parameters are derived from it:
        - ttl = failover_time (leader lock validity)
        - loop_wait = failover_time / 3 (HA cycle interval)
        - retry_timeout = failover_time / 3 (DCS operation timeout)
        - rate_limit = failover_time / 3 (min seconds between DynamoDB operations)

    Examples:
        failover_time: 15   -> Fast failover, higher DynamoDB costs (~24 ops/min)
        failover_time: 60   -> Balanced (default, ~6 ops/min)
        failover_time: 180  -> Cost optimized, slower failover (~2 ops/min)
    """

    # Minimum allowed failover_time to prevent unsafe configurations
    MIN_FAILOVER_TIME = 15

    def __init__(self, config: Dict[str, Any], mpp: Any = None) -> None:
        # config is the DCS-specific section (dynamodb: {...}), not full Patroni config
        # mpp is Multi-Primary PostgreSQL config (for Citus support, usually None)
        super(DynamoDB, self).__init__(config, mpp)

        self._config = config
        # Config is already the dynamodb section, not nested
        dynamodb_config = config

        self._region = dynamodb_config.get('region', 'ca-central-1')
        self._table_name = dynamodb_config.get('table_name', 'softoboros-patroni')
        self._endpoint_url = dynamodb_config.get('endpoint_url')

        # Failover time is the single dial for cost/responsiveness tradeoff
        # All other timings are derived from this value
        failover_time = max(
            dynamodb_config.get('failover_time', 60),
            self.MIN_FAILOVER_TIME
        )

        # Derive timing parameters from failover_time
        # - TTL equals failover_time (leader lock validity window)
        # - loop_wait, retry_timeout, and rate_limit are 1/3 of failover_time
        #   This gives 3 chances to renew the leader lock before it expires
        self._derived_ttl = failover_time
        self._derived_loop_wait = failover_time // 3
        self._derived_retry_timeout = failover_time // 3

        # Create DynamoDB client
        client_kwargs = {'region_name': self._region}
        if self._endpoint_url:
            client_kwargs['endpoint_url'] = self._endpoint_url

        self._client = boto3.client('dynamodb', **client_kwargs)
        self._resource = boto3.resource('dynamodb', **client_kwargs)
        self._table = self._resource.Table(self._table_name)

        # Session ID for this Patroni instance (used for leader lock)
        self._session = str(uuid.uuid4())

        # Cluster name from Patroni config (merged in by get_dcs)
        self._cluster_name = config.get('scope') or 'default'

        # Track last known leader for CAS operations
        self._last_leader_version: Optional[int] = None
        self._last_leader_session: Optional[str] = None

        # Track last watch() return time to enforce minimum loop spacing
        # This prevents tight loops when Patroni calls watch with small timeouts
        self._last_watch_return: float = 0.0
        self._min_watch_interval: float = float(self._derived_loop_wait)

        # Rate limiting for DynamoDB operations to reduce costs
        # Derived from failover_time to align with Patroni's HA cycle
        self._last_operation_time: float = 0.0
        self._min_operation_interval: float = float(self._derived_loop_wait)

        logger.info(f"DynamoDB DCS initialized: table={self._table_name}, "
                   f"cluster={self._cluster_name}, session={self._session[:8]}..., "
                   f"failover_time={failover_time}s (ttl={self._derived_ttl}s, "
                   f"loop_wait={self._derived_loop_wait}s)")

    def _key(self, suffix: str) -> Dict[str, str]:
        """Build DynamoDB key for cluster data."""
        return {
            'cluster_name': self._cluster_name,
            'key': suffix
        }

    def _rate_limit(self) -> None:
        """Enforce minimum interval between DynamoDB operations to reduce costs."""
        now = time.time()
        elapsed = now - self._last_operation_time
        if elapsed < self._min_operation_interval:
            time.sleep(self._min_operation_interval - elapsed)
        self._last_operation_time = time.time()

    def _get_item(self, key_suffix: str) -> Optional[Dict[str, Any]]:
        """Get an item from DynamoDB."""
        self._rate_limit()

        try:
            response = self._table.get_item(
                Key=self._key(key_suffix),
                ConsistentRead=True
            )
            item = response.get('Item')
            if item:
                # Check TTL - DynamoDB may not have cleaned up yet
                ttl = item.get('ttl', 0)
                if ttl and ttl < time.time():
                    return None
            return item
        except ClientError as e:
            logger.error(f"DynamoDB get_item failed: {e}")
            raise DynamoDBError(f"Failed to get {key_suffix}: {e}")

    def _put_item(self, key_suffix: str, value: Any, ttl_seconds: Optional[int] = None,
                  session: Optional[str] = None, condition: Optional[str] = None,
                  condition_values: Optional[Dict] = None) -> bool:
        """Put an item to DynamoDB with optional conditional write."""
        self._rate_limit()

        item = {
            'cluster_name': self._cluster_name,
            'key': key_suffix,
            'value': json.dumps(value) if not isinstance(value, str) else value,
            'version': int(time.time() * 1000000),  # Microsecond timestamp as version
        }

        if ttl_seconds:
            item['ttl'] = int(time.time()) + ttl_seconds

        if session:
            item['session'] = session

        try:
            put_kwargs = {'Item': item}
            if condition:
                put_kwargs['ConditionExpression'] = condition
                if condition_values:
                    put_kwargs['ExpressionAttributeValues'] = condition_values

            self._table.put_item(**put_kwargs)
            return True
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                return False
            logger.error(f"DynamoDB put_item failed: {e}")
            raise DynamoDBError(f"Failed to put {key_suffix}: {e}")

    def _update_item(self, key_suffix: str, updates: Dict[str, Any],
                     condition: Optional[str] = None,
                     condition_values: Optional[Dict] = None) -> bool:
        """Update an item in DynamoDB with optional conditional write."""
        self._rate_limit()

        try:
            update_expr_parts = []
            expr_values = condition_values.copy() if condition_values else {}
            expr_names = {}

            for i, (k, v) in enumerate(updates.items()):
                placeholder = f":val{i}"
                name_placeholder = f"#attr{i}"
                update_expr_parts.append(f"{name_placeholder} = {placeholder}")
                expr_values[placeholder] = v
                expr_names[name_placeholder] = k

            # Always update version
            update_expr_parts.append("#ver = :newver")
            expr_values[':newver'] = int(time.time() * 1000000)
            expr_names['#ver'] = 'version'

            update_kwargs = {
                'Key': self._key(key_suffix),
                'UpdateExpression': 'SET ' + ', '.join(update_expr_parts),
                'ExpressionAttributeValues': expr_values,
                'ExpressionAttributeNames': expr_names
            }

            if condition:
                update_kwargs['ConditionExpression'] = condition

            self._table.update_item(**update_kwargs)
            return True
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                return False
            logger.error(f"DynamoDB update_item failed: {e}")
            raise DynamoDBError(f"Failed to update {key_suffix}: {e}")

    def _delete_item(self, key_suffix: str, condition: Optional[str] = None,
                     condition_values: Optional[Dict] = None) -> bool:
        """Delete an item from DynamoDB with optional conditional delete."""
        self._rate_limit()

        try:
            delete_kwargs = {'Key': self._key(key_suffix)}
            if condition:
                delete_kwargs['ConditionExpression'] = condition
                if condition_values:
                    delete_kwargs['ExpressionAttributeValues'] = condition_values

            self._table.delete_item(**delete_kwargs)
            return True
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                return False
            logger.error(f"DynamoDB delete_item failed: {e}")
            raise DynamoDBError(f"Failed to delete {key_suffix}: {e}")

    def _query_prefix(self, prefix: str) -> List[Dict[str, Any]]:
        """Query all items with a key prefix."""
        self._rate_limit()

        try:
            response = self._table.query(
                KeyConditionExpression='cluster_name = :cn AND begins_with(#k, :prefix)',
                ExpressionAttributeNames={'#k': 'key'},
                ExpressionAttributeValues={
                    ':cn': self._cluster_name,
                    ':prefix': prefix
                },
                ConsistentRead=True
            )

            now = time.time()
            items = []
            for item in response.get('Items', []):
                # Filter out expired items
                ttl = item.get('ttl', 0)
                if not ttl or ttl > now:
                    items.append(item)

            return items
        except ClientError as e:
            logger.error(f"DynamoDB query failed: {e}")
            raise DynamoDBError(f"Failed to query prefix {prefix}: {e}")

    def _load_all_cluster_items(self) -> Dict[str, Dict[str, Any]]:
        """Load all cluster items in a single query.

        This replaces 9 individual API calls (8 GetItem + 1 Query) with 1 Query,
        reducing DynamoDB costs by ~9x and eliminating rate-limit delays.

        Returns:
            Dict mapping key suffix to item, e.g.:
            {'leader': {...}, 'config': {...}, 'members/i-xxx': {...}, ...}
        """
        self._rate_limit()

        try:
            response = self._table.query(
                KeyConditionExpression='cluster_name = :cn',
                ExpressionAttributeValues={':cn': self._cluster_name},
                ConsistentRead=True
            )

            now = time.time()
            items = {}
            for item in response.get('Items', []):
                # Filter out expired items
                ttl = item.get('ttl', 0)
                if not ttl or ttl > now:
                    key = item.get('key', '')
                    items[key] = item

            return items
        except ClientError as e:
            logger.error(f"DynamoDB query_all failed: {e}")
            raise DynamoDBError(f"Failed to load cluster items: {e}")

    # ========== AbstractDCS Implementation ==========

    def set_ttl(self, ttl: int) -> Optional[bool]:
        """Set the TTL for leader key.

        Note: If not explicitly set via patroni.yml bootstrap.dcs.ttl,
        the TTL defaults to the value derived from failover_time.
        """
        self._ttl = ttl
        return None

    @property
    def ttl(self) -> int:
        """Return current TTL value (derived from failover_time if not set)."""
        return getattr(self, '_ttl', self._derived_ttl)

    def set_retry_timeout(self, retry_timeout: int) -> None:
        """Set retry timeout.

        Note: If not explicitly set via patroni.yml bootstrap.dcs.retry_timeout,
        the retry_timeout defaults to the value derived from failover_time.
        """
        self._retry_timeout = retry_timeout

    def _cluster_loader(self, path: str) -> Cluster:
        """Load cluster state from DynamoDB."""
        return self._postgresql_cluster_loader(path)

    def _postgresql_cluster_loader(self, path: str) -> Cluster:
        """Load a PostgreSQL cluster from DynamoDB."""
        # Get all cluster data in a single query (9 API calls -> 1)
        try:
            all_items = self._load_all_cluster_items()

            # Extract individual components from the single query result
            leader_item = all_items.get('leader')
            config_item = all_items.get('config')
            initialize_item = all_items.get('initialize')
            sync_item = all_items.get('sync')
            failover_item = all_items.get('failover')
            failsafe_item = all_items.get('failsafe')
            history_item = all_items.get('history')
            status_item = all_items.get('status')

            # Extract members (keys starting with 'members/')
            member_items = [item for key, item in all_items.items() if key.startswith('members/')]

            # Parse leader
            leader = None
            if leader_item:
                self._last_leader_version = leader_item.get('version')
                self._last_leader_session = leader_item.get('session')
                leader_name = leader_item.get('value', '')
                if isinstance(leader_name, str):
                    try:
                        leader_data = json.loads(leader_name)
                        leader_name = leader_data if isinstance(leader_data, str) else leader_data.get('name', '')
                    except (json.JSONDecodeError, TypeError):
                        pass
                # Find the member that is leader
                for m in member_items:
                    member_key = m.get('key', '')
                    member_name = member_key.replace('members/', '')
                    if member_name == leader_name:
                        try:
                            # Member.from_node expects JSON string, not dict
                            member_value = m.get('value', '{}')
                            leader = Leader(
                                leader_item.get('version', 0),
                                leader_item.get('session'),
                                Member.from_node(
                                    leader_item.get('version', 0),
                                    member_name,
                                    leader_item.get('session'),
                                    member_value
                                )
                            )
                        except (json.JSONDecodeError, TypeError):
                            pass
                        break

            # Parse members
            members = []
            for m in member_items:
                member_key = m.get('key', '')
                member_name = member_key.replace('members/', '')
                try:
                    # Member.from_node expects JSON string, not dict
                    member_value = m.get('value', '{}')
                    members.append(Member.from_node(
                        m.get('version', 0),
                        member_name,
                        m.get('session'),
                        member_value
                    ))
                except (json.JSONDecodeError, TypeError) as e:
                    logger.warning(f"Failed to parse member {member_name}: {e}")

            # Parse config
            config = None
            if config_item:
                try:
                    config_data = json.loads(config_item.get('value', '{}'))
                    config = ClusterConfig.from_node(
                        config_item.get('version', 0),
                        config_data
                    )
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse sync state - always need a SyncState object, not None
            sync = SyncState.empty()
            if sync_item:
                try:
                    sync_data = json.loads(sync_item.get('value', '{}'))
                    sync = SyncState.from_node(
                        sync_item.get('version', 0),
                        sync_data
                    )
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse initialize
            initialize = None
            if initialize_item:
                initialize = initialize_item.get('value')

            # Parse failover
            failover = None
            if failover_item:
                try:
                    failover_data = json.loads(failover_item.get('value', '{}'))
                    failover = Failover.from_node(
                        failover_item.get('version', 0),
                        failover_data
                    )
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse history
            history = None
            if history_item:
                try:
                    history_data = json.loads(history_item.get('value', '[]'))
                    history = TimelineHistory.from_node(
                        history_item.get('version', 0),
                        history_data
                    )
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse status
            status = Status.empty()
            if status_item:
                try:
                    status_data = json.loads(status_item.get('value', '{}'))
                    status = Status.from_node(status_data)
                except (json.JSONDecodeError, TypeError):
                    pass

            # Parse failsafe
            failsafe = None
            if failsafe_item:
                try:
                    failsafe = json.loads(failsafe_item.get('value', '{}'))
                except (json.JSONDecodeError, TypeError):
                    pass

            return Cluster(
                initialize,
                config,
                leader,
                status,
                members,
                failover,
                sync,
                history,
                failsafe
            )

        except Exception as e:
            logger.error(f"Failed to load cluster: {e}")
            raise DynamoDBError(f"Failed to load cluster: {e}")

    def _mpp_cluster_loader(self, path: str) -> Dict[int, Cluster]:
        """Load MPP clusters - not supported, return single cluster."""
        return {0: self._postgresql_cluster_loader(path)}

    def _load_cluster(
        self, path: str, loader: Callable[[str], Union[Cluster, Dict[int, Cluster]]]
    ) -> Union[Cluster, Dict[int, Cluster]]:
        """Load cluster using the specified loader."""
        return loader(path)

    def _write_leader_optime(self, last_lsn: str) -> bool:
        """Write leader optime (LSN) - legacy method."""
        return self._write_status({'optime': last_lsn})

    def _write_status(self, value: Dict[str, Any]) -> bool:
        """Write cluster status."""
        return self._put_item('status', value, ttl_seconds=self.ttl * 2)

    def _write_failsafe(self, value: Dict[str, Any]) -> bool:
        """Write failsafe topology."""
        return self._put_item('failsafe', value)

    def _update_leader(self, leader: Leader) -> bool:
        """Update leader key - renew leadership."""
        # Update TTL on leader key
        # Note: We verify session ownership in attempt_to_acquire_leader before this is called
        try:
            # Use put_item to renew the entire leader record
            return self._put_item(
                'leader',
                self._name,
                ttl_seconds=self.ttl,
                session=self._session
            )
        except Exception as e:
            logger.warning(f"Failed to update leader: {e}")
            return False

    def attempt_to_acquire_leader(self) -> bool:
        """Attempt to acquire leadership."""
        # Try to create leader key with our session
        # Condition: key doesn't exist OR TTL has expired OR we already hold it
        try:
            # First check if leader exists and is valid
            leader_item = self._get_item('leader')

            if leader_item:
                existing_session = leader_item.get('session')
                existing_ttl = leader_item.get('ttl', 0)

                # If we already hold the lock, just renew
                if existing_session == self._session:
                    return self._update_item(
                        'leader',
                        {
                            'ttl': int(time.time()) + self.ttl,
                            'value': self._name
                        },
                        condition='#sess = :sess',
                        condition_values={':sess': self._session}
                    )

                # If TTL expired, try to take over
                if existing_ttl < time.time():
                    # TTL expired - use unconditional put to take over
                    # This is safe because we've verified TTL expiration
                    return self._put_item(
                        'leader',
                        self._name,
                        ttl_seconds=self.ttl,
                        session=self._session
                    )

                # Leader exists and is valid - can't acquire
                return False

            # No leader exists - try to create
            return self._put_item(
                'leader',
                self._name,
                ttl_seconds=self.ttl,
                session=self._session,
                condition='attribute_not_exists(cluster_name)'
            )

        except DynamoDBError:
            return False
        except Exception as e:
            logger.error(f"Failed to acquire leader: {e}")
            return False

    def _delete_leader(self, leader: Optional[Leader]) -> bool:
        """Delete leader key - step down from leadership."""
        return self._delete_item(
            'leader',
            condition='#sess = :sess',
            condition_values={':sess': self._session}
        )

    def touch_member(self, data: Dict[str, Any]) -> bool:
        """Update member registration."""
        return self._put_item(
            f'members/{self._name}',
            data,
            ttl_seconds=self.ttl * 2,
            session=self._session
        )

    def take_leader(self) -> bool:
        """Take leadership immediately (for manual failover)."""
        return self.attempt_to_acquire_leader()

    def initialize(self, create_new: bool = True, sysid: str = '') -> bool:
        """Initialize cluster."""
        if create_new:
            return self._put_item(
                'initialize',
                sysid,
                condition='attribute_not_exists(cluster_name)'
            )
        return True

    def cancel_initialization(self) -> bool:
        """Cancel cluster initialization."""
        return self._delete_item('initialize')

    def delete_sync_state(self, version: Optional[int] = None) -> bool:
        """Delete sync state."""
        if version:
            return self._delete_item(
                'sync',
                condition='#ver = :ver',
                condition_values={':ver': version}
            )
        return self._delete_item('sync')

    def set_failover_value(self, value: str, version: Optional[int] = None) -> bool:
        """Set failover configuration."""
        if version:
            return self._put_item(
                'failover',
                value,
                condition='#ver = :ver OR attribute_not_exists(cluster_name)',
                condition_values={':ver': version}
            )
        return self._put_item('failover', value)

    def set_config_value(self, value: str, version: Optional[int] = None) -> bool:
        """Set cluster configuration."""
        if version:
            return self._put_item(
                'config',
                value,
                condition='#ver = :ver OR attribute_not_exists(cluster_name)',
                condition_values={':ver': version}
            )
        return self._put_item('config', value)

    def set_sync_state_value(self, value: str, version: Optional[int] = None) -> bool:
        """Set synchronous replication state."""
        if version:
            return self._put_item(
                'sync',
                value,
                condition='#ver = :ver OR attribute_not_exists(cluster_name)',
                condition_values={':ver': version}
            )
        return self._put_item('sync', value)

    def set_history_value(self, value: str) -> bool:
        """Set timeline history."""
        return self._put_item('history', value)

    def delete_cluster(self) -> bool:
        """Delete all cluster data."""
        try:
            # Query all items for this cluster
            response = self._table.query(
                KeyConditionExpression='cluster_name = :cn',
                ExpressionAttributeValues={':cn': self._cluster_name},
                ProjectionExpression='cluster_name, #k',
                ExpressionAttributeNames={'#k': 'key'}
            )

            # Delete each item
            with self._table.batch_writer() as batch:
                for item in response.get('Items', []):
                    batch.delete_item(Key={
                        'cluster_name': item['cluster_name'],
                        'key': item['key']
                    })

            return True
        except ClientError as e:
            logger.error(f"Failed to delete cluster: {e}")
            return False

    def watch(self, leader_version: Optional[int], timeout: float) -> bool:
        """
        Watch for changes in cluster state.

        DynamoDB doesn't support native watches. Instead of polling (which would
        consume many API calls), we simply sleep for the timeout period.

        Leader changes are detected by the subsequent get_cluster() call.
        Max detection delay = loop_wait, which is acceptable for failover.

        This reduces API calls from ~10 per watch (polling every 2s) to 0.
        Combined with batch cluster loading, total is 2 ops per HA cycle:
        - 1 read (get_cluster batch query)
        - 1 write (touch_member heartbeat)
        """
        # Enforce minimum interval to prevent tight loops
        effective_timeout = max(timeout, self._min_watch_interval)

        logger.debug(f"watch: sleeping {effective_timeout:.1f}s")
        time.sleep(effective_timeout)

        self._last_watch_return = time.time()
        return False  # Let get_cluster() detect actual changes
