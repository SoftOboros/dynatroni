#!/usr/bin/env bash
set -euo pipefail

# Patroni callback script for role change events
# Called by Patroni on: on_start, on_stop, on_role_change
#
# Arguments:
#   $1 - action: on_start, on_stop, on_role_change
#   $2 - role: master, replica, or empty
#   $3 - cluster scope name

ACTION=${1:-}
ROLE=${2:-}
SCOPE=${3:-}

SECRETS_FILE="/etc/default/dumbo-secrets"
LOG_PREFIX="[patroni-callback]"

echo "$LOG_PREFIX Action: $ACTION, Role: $ROLE, Scope: $SCOPE"

# Load secrets for Cloud Map registration and replicator password
# Note: secrets file is root-owned (600); callback runs as postgres via Patroni
# Try to read secrets file, fallback to SSM if not readable
if [[ -f "$SECRETS_FILE" && -r "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
else
  echo "$LOG_PREFIX Secrets file not readable, will fetch from SSM as needed"
fi

# Get instance metadata
get_imds_token() {
  curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo ""
}

TOKEN=$(get_imds_token)
if [[ -z "$TOKEN" ]]; then
  echo "$LOG_PREFIX WARNING: Failed to get IMDS token"
  exit 0
fi

INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "")
AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")
REGION=${AZ:0:-1}

# Cloud Map service ID (optional)
CLOUDMAP_SERVICE_ID=${CLOUDMAP_SERVICE_ID:-}

register_system_table() {
  local role=$1

  # Map Patroni role names to our convention
  local normalized_role
  case "$role" in
    master|primary) normalized_role="primary" ;;
    replica|standby) normalized_role="replica" ;;
    *) normalized_role="$role" ;;
  esac

  echo "$LOG_PREFIX Registering in system table: role=$normalized_role ip=$PRIVATE_IP"

  # Use the system_table module to register this instance
  # Note: Must use Patroni venv Python which has boto3 installed
  PYTHONPATH="/usr/local/lib/softoboros:${PYTHONPATH:-}" /opt/patroni/bin/python -c "
from redqueen.system_table import SystemTable
st = SystemTable()
st.register_participant(
    component='dumbo',
    instance_id='$INSTANCE_ID',
    az='$AZ',
    ip='$PRIVATE_IP',
    role='$normalized_role',
    metadata={'port': 6432},
    ttl_minutes=5,
)
print('Registered dumbo as $normalized_role')
" 2>&1 && echo "$LOG_PREFIX System table registration successful" \
       || echo "$LOG_PREFIX WARNING: System table registration failed"
}

update_cloudmap() {
  local role=$1

  if [[ -z "$CLOUDMAP_SERVICE_ID" ]]; then
    echo "$LOG_PREFIX No Cloud Map service ID configured; skipping DNS update"
    return 0
  fi

  echo "$LOG_PREFIX Updating Cloud Map registration for role: $role"

  # Deregister first (in case of role change)
  aws servicediscovery deregister-instance \
    --region "$REGION" \
    --service-id "$CLOUDMAP_SERVICE_ID" \
    --instance-id "$INSTANCE_ID" 2>/dev/null || true

  if [[ "$role" == "master" || "$role" == "primary" ]]; then
    # Register as primary with AWS_INSTANCE_IPV4 for A record
    aws servicediscovery register-instance \
      --region "$REGION" \
      --service-id "$CLOUDMAP_SERVICE_ID" \
      --instance-id "$INSTANCE_ID" \
      --attributes "AWS_INSTANCE_IPV4=$PRIVATE_IP,ROLE=primary,AZ=$AZ"
    echo "$LOG_PREFIX Registered as PRIMARY in Cloud Map"
  elif [[ "$role" == "replica" ]]; then
    # Replicas can also be registered for read-only access
    echo "$LOG_PREFIX Role is replica; not updating primary DNS record"
  fi
}

# Get DynamoDB table name from secrets or default
PATRONI_DYNAMODB_TABLE=${PATRONI_DYNAMODB_TABLE:-softoboros-patroni}
PATRONI_SCOPE=${SCOPE:-softoboros-dumbo}

# Check if we're the solo leader (no other members running)
check_solo_leader() {
  # Query Patroni REST API for cluster members
  local members_json
  members_json=$(curl -s "http://127.0.0.1:8008/cluster" 2>/dev/null || echo "{}")

  # Count running members (excluding ourselves)
  local running_count
  running_count=$(echo "$members_json" | jq -r '[.members[] | select(.state == "running" or .state == "streaming")] | length' 2>/dev/null || echo "0")

  # If we're the only running member, we're solo
  [[ "$running_count" -le 1 ]]
}

# Get the EBS volume ID attached to /data (AWS) or from env var (Docker)
get_data_volume_id() {
  # Docker: use env var if set
  if [[ -n "${DUMBO_VOLUME_ID:-}" ]]; then
    echo "$DUMBO_VOLUME_ID"
    return
  fi

  local device
  device=$(df /data 2>/dev/null | tail -1 | awk '{print $1}')
  if [[ -z "$device" ]]; then
    echo ""
    return
  fi

  # Get the NVMe device name mapping
  local nvme_name
  nvme_name=$(readlink -f "$device" 2>/dev/null | sed 's|/dev/||')

  # Query IMDS for block device mapping or use nvme tool
  if command -v nvme &>/dev/null; then
    # Get volume ID from NVMe controller
    local vol_id
    vol_id=$(nvme id-ctrl -v "/dev/${nvme_name%%p*}" 2>/dev/null | grep -oE 'vol-[a-f0-9]+' | head -1)
    echo "$vol_id"
  else
    # Fallback: query EC2 for attached volumes
    aws ec2 describe-instances \
      --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[].Instances[].BlockDeviceMappings[?DeviceName==`/dev/xvdf` || DeviceName==`/dev/sdf`].Ebs.VolumeId' \
      --output text 2>/dev/null || echo ""
  fi
}

# Ensure replicator user exists (needed for cold boot when leader has existing data)
ensure_replicator_user() {
  local replicator_password=${REPLICATOR_PASSWORD:-}

  # If password not in env, fetch from SSM
  if [[ -z "$replicator_password" ]]; then
    echo "$LOG_PREFIX Fetching replicator password from SSM..."
    replicator_password=$(aws ssm get-parameter \
      --region "$REGION" \
      --name /softoboros/postgres/replicator_password \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text 2>/dev/null || echo "")
  fi

  if [[ -z "$replicator_password" ]]; then
    echo "$LOG_PREFIX WARNING: No REPLICATOR_PASSWORD found in env or SSM, cannot ensure replicator user"
    return 1
  fi

  echo "$LOG_PREFIX Ensuring replicator user exists..."

  # Check if user exists (callback runs as postgres user via Patroni)
  local user_exists
  user_exists=$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='replicator'" 2>/dev/null || echo "")

  if [[ "$user_exists" == "1" ]]; then
    echo "$LOG_PREFIX Replicator user already exists"
    # Update password in case it changed
    psql -c "ALTER ROLE replicator WITH PASSWORD '$replicator_password';" 2>/dev/null || true
  else
    echo "$LOG_PREFIX Creating replicator user"
    if psql -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$replicator_password';" 2>/dev/null; then
      echo "$LOG_PREFIX Replicator user created successfully"
    else
      echo "$LOG_PREFIX WARNING: Failed to create replicator user"
      return 1
    fi
  fi

  return 0
}

# Record cold boot leader in DynamoDB when shutting down as solo leader
record_cold_boot_leader() {
  local volume_id
  volume_id=$(get_data_volume_id)

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local az_suffix="${AZ: -1}"  # Get last character (a, b, c, etc.)

  echo "$LOG_PREFIX Recording cold boot leader: instance=$INSTANCE_ID, volume=$volume_id, az=$AZ"

  # Write cold_boot_leader record to DynamoDB
  aws dynamodb put-item \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --item "{
      \"cluster_name\": {\"S\": \"$PATRONI_SCOPE\"},
      \"key\": {\"S\": \"cold_boot_leader\"},
      \"value\": {\"S\": \"{\\\"instance_id\\\": \\\"$INSTANCE_ID\\\", \\\"volume_id\\\": \\\"$volume_id\\\", \\\"az\\\": \\\"$AZ\\\", \\\"az_suffix\\\": \\\"$az_suffix\\\", \\\"timestamp\\\": \\\"$timestamp\\\"}\"}
    }" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    echo "$LOG_PREFIX Cold boot leader recorded successfully"
  else
    echo "$LOG_PREFIX WARNING: Failed to record cold boot leader"
  fi
}

case "$ACTION" in
  on_start)
    echo "$LOG_PREFIX PostgreSQL started as $ROLE"

    # Register in system table for all roles (primary and replica)
    register_system_table "$ROLE"

    if [[ "$ROLE" == "master" || "$ROLE" == "primary" ]]; then
      # Ensure replicator user exists (critical for replicas to connect)
      # This handles cold boot scenarios where leader has existing data
      ensure_replicator_user || echo "$LOG_PREFIX WARNING: Replicator user setup failed"

      update_cloudmap "$ROLE"
    fi
    ;;
  on_stop)
    echo "$LOG_PREFIX PostgreSQL stopped"

    # If we were the leader, check if we're the solo leader
    if [[ "$ROLE" == "master" || "$ROLE" == "primary" ]]; then
      if check_solo_leader; then
        echo "$LOG_PREFIX Shutting down as SOLO LEADER - recording cold boot leader"
        record_cold_boot_leader
      else
        echo "$LOG_PREFIX Shutting down with other members running - no cold boot record needed"
      fi
    fi

    # Deregister from Cloud Map
    if [[ -n "$CLOUDMAP_SERVICE_ID" ]]; then
      aws servicediscovery deregister-instance \
        --region "$REGION" \
        --service-id "$CLOUDMAP_SERVICE_ID" \
        --instance-id "$INSTANCE_ID" 2>/dev/null || true
      echo "$LOG_PREFIX Deregistered from Cloud Map"
    fi
    ;;
  on_role_change)
    echo "$LOG_PREFIX Role changed to $ROLE"
    register_system_table "$ROLE"
    update_cloudmap "$ROLE"
    ;;
  *)
    echo "$LOG_PREFIX Unknown action: $ACTION"
    ;;
esac

exit 0
