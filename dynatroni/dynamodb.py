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
        # Set to 1/2 of loop_wait to allow read + write within each HA cycle
        # (previously was equal to loop_wait, which caused TTL expiration)
        self._last_operation_time: float = 0.0
        self._min_operation_interval: float = float(self._derived_loop_wait) / 2.0

        # Leader lock tracking for smart rate limiting
        # Allows emergency renewal when approaching TTL expiry
        self._is_leader: bool = False
        self._leader_lock_acquired_at: float = 0.0

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
        """Enforce minimum interval between DynamoDB operations to reduce costs.

        Smart rate limiting that:
        1. Tracks real elapsed time - if enough time passed, no wait needed
        2. Emergency mode for leader renewal - skip delay when approaching TTL expiry
        3. Doesn't compound delays when Patroni is running slow
        """
        now = time.time()
        elapsed = now - self._last_operation_time

        # If enough real time has already passed, no need to wait
        # This handles the case where Patroni's loop_wait already provided the delay
        if elapsed >= self._min_operation_interval:
            self._last_operation_time = now
            return

        # Emergency mode: if we're leader and approaching TTL expiry, skip delay
        # This prevents leader lock from expiring due to rate limit delays
        if self._is_leader and self._leader_lock_acquired_at > 0:
            time_since_lock = now - self._leader_lock_acquired_at
            time_until_expiry = self.ttl - time_since_lock

            # TTL already expired - we've lost the lock
            if time_until_expiry <= 0:
                logger.error(f"Rate limit: TTL EXPIRED {-time_until_expiry:.1f}s ago! "
                            f"Patroni loop exceeded TTL ({self.ttl}s). Lock lost.")
                self._is_leader = False
                self._leader_lock_acquired_at = 0.0
                self._last_operation_time = now
                return

            # Approaching expiry - skip delay for emergency renewal
            if time_until_expiry < self._min_operation_interval * 2:
                logger.warning(f"Rate limit: emergency renewal mode - {time_until_expiry:.1f}s until TTL expiry")
                self._last_operation_time = now
                return

        # Normal case: wait the remaining time
        remaining = self._min_operation_interval - elapsed
        time.sleep(remaining)
        self._last_operation_time = time.time()

    def _get_item(self, key_suffix: str, check_ttl: bool = False) -> Optional[Dict[str, Any]]:
        """Get an item from DynamoDB.

        Args:
            key_suffix: The key suffix to look up
            check_ttl: If True, return None for expired items. Default False
                       to let caller decide how to handle expired items.
                       Important: For leader key, caller must see expired items
                       to do unconditional takeover (conditional create fails
                       because item still exists until DynamoDB cleanup).
        """
        self._rate_limit()

        try:
            response = self._table.get_item(
                Key=self._key(key_suffix),
                ConsistentRead=True
            )
            item = response.get('Item')
            if item and check_ttl:
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
                     condition_values: Optional[Dict] = None,
                     condition_names: Optional[Dict] = None) -> bool:
        """Update an item in DynamoDB with optional conditional write."""
        self._rate_limit()

        try:
            update_expr_parts = []
            expr_values = condition_values.copy() if condition_values else {}
            expr_names = condition_names.copy() if condition_names else {}

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
                     condition_values: Optional[Dict] = None,
                     condition_names: Optional[Dict] = None) -> bool:
        """Delete an item from DynamoDB with optional conditional delete."""
        self._rate_limit()

        try:
            delete_kwargs = {'Key': self._key(key_suffix)}
            if condition:
                delete_kwargs['ConditionExpression'] = condition
                if condition_values:
                    delete_kwargs['ExpressionAttributeValues'] = condition_values
                if condition_names:
                    delete_kwargs['ExpressionAttributeNames'] = condition_names

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
            expired_keys = []
            for item in response.get('Items', []):
                # Filter out expired items
                ttl = item.get('ttl', 0)
                key = item.get('key', '')
                if not ttl or ttl > now:
                    items[key] = item
                else:
                    expired_keys.append(f"{key}(ttl={ttl}, expired {int(now - ttl)}s ago)")

            if expired_keys:
                logger.info(f"[cluster-load] Filtered out expired items: {expired_keys}")

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

            # Debug logging for leader election issues
            logger.info(f"[cluster-load] Loaded {len(all_items)} items: {list(all_items.keys())}")

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
            if not leader_item:
                logger.info(f"[cluster-load] No leader item found in DynamoDB")
            if leader_item:
                self._last_leader_version = leader_item.get('version')
                self._last_leader_session = leader_item.get('session')
                leader_name = leader_item.get('value', '')
                leader_ttl = leader_item.get('ttl', 0)
                logger.info(f"[cluster-load] Leader item: name={leader_name}, session={self._last_leader_session[:8] if self._last_leader_session else 'None'}..., ttl={leader_ttl}, now={int(time.time())}, ttl_remaining={leader_ttl - int(time.time()) if leader_ttl else 'N/A'}s")
                if isinstance(leader_name, str):
                    try:
                        leader_data = json.loads(leader_name)
                        leader_name = leader_data if isinstance(leader_data, str) else leader_data.get('name', '')
                    except (json.JSONDecodeError, TypeError):
                        pass
                # Find the member that is leader
                member_names = [m.get('key', '').replace('members/', '') for m in member_items]
                logger.info(f"[cluster-load] Looking for leader '{leader_name}' in members: {member_names}")
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
                            logger.info(f"[cluster-load] Created Leader object for {member_name}")
                        except (json.JSONDecodeError, TypeError) as e:
                            logger.warning(f"Failed to create Leader: {e}")
                        break
                if not leader and leader_item:
                    logger.warning(f"Leader key exists (name={leader_name}) but no matching member found in {member_names}")

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
        """Update leader key - renew leadership (called by base class update_leader).

        CRITICAL: This bypasses rate limiting because leader renewal must happen
        immediately to prevent TTL expiration and cluster instability.
        """
        logger.info(f"_update_leader called: renewing TTL for {self._name} (ttl={self.ttl}s, session={self._session[:8]}...)")
        try:
            # Direct DynamoDB write - bypass rate limiting for leader renewal
            # The rate limiter can delay writes by up to loop_wait seconds, which
            # combined with the HA cycle timing, can cause TTL expiration.
            item = {
                'cluster_name': self._cluster_name,
                'key': 'leader',
                'value': self._name,
                'version': int(time.time() * 1000000),
                'ttl': int(time.time()) + self.ttl,
                'session': self._session
            }
            self._table.put_item(Item=item)

            # Renew the lock timestamp for TTL tracking
            self._leader_lock_acquired_at = time.time()
            self._is_leader = True
            logger.info(f"_update_leader: successfully renewed TTL (expires at {item['ttl']})")
            return True
        except ClientError as e:
            logger.warning(f"Failed to update leader: {e}")
            return False
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
                    success = self._update_item(
                        'leader',
                        {
                            'ttl': int(time.time()) + self.ttl,
                            'value': self._name
                        },
                        condition='#sess = :sess',
                        condition_values={':sess': self._session},
                        condition_names={'#sess': 'session'}
                    )
                    if success:
                        # Renew the lock timestamp for TTL tracking
                        self._leader_lock_acquired_at = time.time()
                        self._is_leader = True
                    else:
                        logger.warning(f"Leader lock renewal failed - session mismatch or item deleted")
                    return success

                # If TTL expired, try to take over
                if existing_ttl < time.time():
                    # TTL expired - use unconditional put to take over
                    # This is safe because we've verified TTL expiration
                    success = self._put_item(
                        'leader',
                        self._name,
                        ttl_seconds=self.ttl,
                        session=self._session
                    )
                    if success:
                        self._leader_lock_acquired_at = time.time()
                        self._is_leader = True
                        logger.info(f"Acquired leader lock (expired TTL takeover)")
                    return success

                # Leader exists and is valid - can't acquire
                self._is_leader = False
                return False

            # No leader exists - try to create
            success = self._put_item(
                'leader',
                self._name,
                ttl_seconds=self.ttl,
                session=self._session,
                condition='attribute_not_exists(cluster_name)'
            )
            if success:
                self._leader_lock_acquired_at = time.time()
                self._is_leader = True
                logger.info(f"Acquired leader lock (new cluster)")
            return success

        except DynamoDBError:
            self._is_leader = False
            return False
        except Exception as e:
            logger.error(f"Failed to acquire leader: {e}")
            self._is_leader = False
            return False

    def _delete_leader(self, leader: Optional[Leader]) -> bool:
        """Delete leader key - step down from leadership."""
        success = self._delete_item(
            'leader',
            condition='#sess = :sess',
            condition_values={':sess': self._session},
            condition_names={'#sess': 'session'}
        )
        # Clear leadership state regardless of delete success
        # (if delete fails, we're likely not leader anyway)
        self._is_leader = False
        self._leader_lock_acquired_at = 0.0
        return success

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
