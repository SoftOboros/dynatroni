#!/usr/bin/env bash
set -euo pipefail

# Gracefully remove the replica from Patroni cluster and shut down.
# The ASG will launch a new instance with the updated AMI.
#
# Prerequisites:
# - Must be run on the REPLICA node
# - Both leader and replica must be healthy
#
# Exit codes:
#   0 - Shutdown initiated (script exits before shutdown completes for SSM)
#   1 - Cluster not healthy or not a replica

LOG_PREFIX="[patroni-upgrade-replica]"
PATRONI_CONFIG="/etc/patroni/patroni.yml"

echo "$LOG_PREFIX Starting replica upgrade process"

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

# Get this node's role
get_my_role() {
    curl -s http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // "unknown"'
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

# Verify we are the replica
MY_ROLE=$(get_my_role)
echo "$LOG_PREFIX This node's role: $MY_ROLE"

if [[ "$MY_ROLE" != "replica" ]]; then
    echo "$LOG_PREFIX ERROR: This node is not a replica (role: $MY_ROLE)"
    echo "$LOG_PREFIX Run patroni-upgrade-leader.sh on the leader instead"
    exit 1
fi

echo "$LOG_PREFIX Cluster is healthy, proceeding with replica upgrade"

# Stop Patroni gracefully - this will:
# 1. Deregister from DCS (DynamoDB)
# 2. Stop PostgreSQL gracefully
# 3. Run on_stop callback
echo "$LOG_PREFIX Stopping Patroni service..."
sudo systemctl stop patroni

echo "$LOG_PREFIX Patroni stopped, initiating system shutdown..."
echo "$LOG_PREFIX SSM session will close. ASG will launch replacement instance."

# Use nohup + disown to ensure shutdown proceeds after script exits
# This allows SSM to close gracefully before shutdown completes
nohup sudo shutdown -h +1 "Patroni replica upgrade - launching new instance" &>/dev/null &
disown

echo "$LOG_PREFIX Shutdown scheduled in 1 minute. Exiting script for SSM cleanup."
exit 0
