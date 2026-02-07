#!/usr/bin/env bash
set -euo pipefail

# Gracefully promote replica to leader, then remove this node and shut down.
# The ASG will launch a new instance with the updated AMI.
#
# Prerequisites:
# - Must be run on the LEADER node
# - Both leader and replica must be healthy
#
# Exit codes:
#   0 - Shutdown initiated (script exits before shutdown completes for SSM)
#   1 - Cluster not healthy, not the leader, or switchover failed

LOG_PREFIX="[patroni-upgrade-leader]"
PATRONI_CONFIG="/etc/patroni/patroni.yml"
SWITCHOVER_TIMEOUT=60

echo "$LOG_PREFIX Starting leader upgrade process"

# Check patronictl is available
if [[ -x /opt/patroni/bin/patronictl ]]; then
    PATRONICTL="/opt/patroni/bin/patronictl"
elif command -v patronictl &>/dev/null; then
    PATRONICTL="patronictl"
else
    echo "$LOG_PREFIX ERROR: patronictl not found"
    exit 1
fi

# Get cluster status as JSON
get_cluster_json() {
    curl -s http://127.0.0.1:8008/cluster 2>/dev/null || echo "{}"
}

# Get this node's name and role
get_my_name() {
    curl -s http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.patroni.name // .name // "unknown"'
}

get_my_role() {
    curl -s http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // "unknown"'
}

# Get the replica's name
get_replica_name() {
    local cluster_json
    cluster_json=$(get_cluster_json)
    echo "$cluster_json" | jq -r '.members[] | select(.role == "replica" and (.state == "running" or .state == "streaming")) | .name' | head -1
}

# Get the current leader's name
get_leader_name() {
    local cluster_json
    cluster_json=$(get_cluster_json)
    echo "$cluster_json" | jq -r '.members[] | select(.role == "leader" or .role == "primary" or .role == "master") | .name' | head -1
}

# Check cluster health - both leader and replica must be running
check_cluster_health() {
    local cluster_json
    cluster_json=$(get_cluster_json)

    local leader_count replica_count
    leader_count=$(echo "$cluster_json" | jq '[.members[] | select((.role == "leader" or .role == "primary" or .role == "master") and (.state == "running" or .state == "streaming"))] | length')
    replica_count=$(echo "$cluster_json" | jq '[.members[] | select(.role == "replica" and (.state == "running" or .state == "streaming"))] | length')

    if [[ "$leader_count" -ge 1 && "$replica_count" -ge 1 ]]; then
        return 0
    else
        return 1
    fi
}

# Display cluster status
show_cluster_status() {
    echo "$LOG_PREFIX Current cluster status:"
    $PATRONICTL -c "$PATRONI_CONFIG" list 2>/dev/null || echo "$LOG_PREFIX Failed to get cluster list"
}

# Wait for switchover to complete
wait_for_new_leader() {
    local expected_leader=$1
    local timeout=$2
    local elapsed=0

    echo "$LOG_PREFIX Waiting for $expected_leader to become leader (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local current_leader
        current_leader=$(get_leader_name)

        if [[ "$current_leader" == "$expected_leader" ]]; then
            echo "$LOG_PREFIX Switchover complete: $expected_leader is now leader"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo "$LOG_PREFIX Waiting... (${elapsed}s) current leader: $current_leader"
    done

    echo "$LOG_PREFIX ERROR: Switchover timed out after ${timeout}s"
    return 1
}

# Main logic
show_cluster_status
echo ""

# Check cluster health
if ! check_cluster_health; then
    echo "$LOG_PREFIX ERROR: Cluster is not healthy (need both leader and replica running)"
    echo "$LOG_PREFIX Aborting upgrade - fix cluster health first"
    show_cluster_status
    exit 1
fi

# Verify we are the leader
MY_NAME=$(get_my_name)
MY_ROLE=$(get_my_role)
echo "$LOG_PREFIX This node: $MY_NAME (role: $MY_ROLE)"

if [[ "$MY_ROLE" != "master" && "$MY_ROLE" != "leader" && "$MY_ROLE" != "primary" ]]; then
    echo "$LOG_PREFIX ERROR: This node is not the leader (role: $MY_ROLE)"
    echo "$LOG_PREFIX Run patroni-upgrade-replica.sh on the replica instead"
    exit 1
fi

# Get replica name for switchover
REPLICA_NAME=$(get_replica_name)
if [[ -z "$REPLICA_NAME" || "$REPLICA_NAME" == "null" ]]; then
    echo "$LOG_PREFIX ERROR: Could not find a healthy replica for switchover"
    exit 1
fi

echo "$LOG_PREFIX Cluster is healthy, proceeding with leader upgrade"
echo "$LOG_PREFIX Will switch leadership to: $REPLICA_NAME"

# Get cluster scope from config
SCOPE=$(grep -E '^\s*scope:' "$PATRONI_CONFIG" | awk '{print $2}' | tr -d '"' | head -1)
if [[ -z "$SCOPE" ]]; then
    SCOPE="softoboros-dumbo"
fi
echo "$LOG_PREFIX Cluster scope: $SCOPE"

# Initiate switchover - promote replica to leader
echo "$LOG_PREFIX Initiating switchover to $REPLICA_NAME..."
if ! $PATRONICTL -c "$PATRONI_CONFIG" switchover "$SCOPE" \
    --leader "$MY_NAME" \
    --candidate "$REPLICA_NAME" \
    --force 2>&1; then
    echo "$LOG_PREFIX ERROR: Switchover command failed"
    show_cluster_status
    exit 1
fi

# Wait for switchover to complete
if ! wait_for_new_leader "$REPLICA_NAME" "$SWITCHOVER_TIMEOUT"; then
    echo "$LOG_PREFIX ERROR: Switchover did not complete in time"
    show_cluster_status
    exit 1
fi

echo "$LOG_PREFIX Switchover successful!"
show_cluster_status
echo ""

# Schedule shutdown FIRST so the instance always terminates, even if
# systemctl stop gets interrupted by SSM timeout or other race conditions.
echo "$LOG_PREFIX Scheduling shutdown in 2 minutes..."
nohup sudo shutdown -h +2 "Patroni leader upgrade - launching new instance" &>/dev/null &
disown

# Now we are a replica, stop Patroni gracefully
echo "$LOG_PREFIX Stopping Patroni service (now a replica)..."
sudo systemctl stop patroni || echo "$LOG_PREFIX WARNING: Patroni stop returned non-zero (shutdown still scheduled)"

echo "$LOG_PREFIX Patroni stopped, shutdown scheduled."
echo "$LOG_PREFIX SSM session will close. ASG will launch replacement instance."
exit 0
