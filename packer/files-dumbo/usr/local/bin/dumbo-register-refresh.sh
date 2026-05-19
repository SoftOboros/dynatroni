#!/bin/bash
set -euo pipefail

# Refresh dumbo registration in DynamoDB system table
#
# Called periodically (every 2 min) to keep registration alive.
# The TTL is 5 minutes, so 2-minute refresh ensures continuity.

LOG_PREFIX="[dumbo-register-refresh]"

# Get instance metadata
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")

if [[ -n "$TOKEN" ]]; then
    INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null)
    AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/availability-zone" 2>/dev/null)
    PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null)
    AMI_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/ami-id" 2>/dev/null)
else
    INSTANCE_ID=$(curl -s "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null)
    AZ=$(curl -s "http://169.254.169.254/latest/meta-data/placement/availability-zone" 2>/dev/null)
    PRIVATE_IP=$(curl -s "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null)
    AMI_ID=$(curl -s "http://169.254.169.254/latest/meta-data/ami-id" 2>/dev/null)
fi

# Get current role from Patroni
ROLE=$(curl -s "http://127.0.0.1:8008/" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role','unknown'))" 2>/dev/null || echo "unknown")

# Normalize role
case "$ROLE" in
    master|primary) ROLE="primary" ;;
    replica|standby) ROLE="replica" ;;
esac

if [[ "$ROLE" == "unknown" ]]; then
    echo "$LOG_PREFIX WARNING: Could not determine role, skipping refresh"
    exit 0
fi

# Read version from VERSION file
INSTANCE_VERSION=$(cat /opt/softoboros/VERSION 2>/dev/null | head -1 | tr -d '[:space:]' || echo "unknown")

# Refresh registration in DynamoDB
# Note: Must use Patroni venv Python which has boto3 installed
export PYTHONPATH="/usr/local/lib/softoboros:${PYTHONPATH:-}"

/opt/patroni/bin/python -c "
from redqueen.system_table import SystemTable
st = SystemTable()
st.register_participant(
    component='dumbo',
    instance_id='$INSTANCE_ID',
    az='$AZ',
    ip='$PRIVATE_IP',
    role='$ROLE',
    metadata={'port': 6432, 'version': '$INSTANCE_VERSION', 'ami_id': '$AMI_ID'},
    ttl_minutes=5,
)
" && echo "$LOG_PREFIX role=$ROLE ip=$PRIVATE_IP" || {
    echo "$LOG_PREFIX WARNING: Failed to refresh registration"
}

exit 0
