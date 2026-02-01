#!/usr/bin/env bash
set -euo pipefail

# Cold Boot Leader Check
# Runs before Patroni starts to ensure proper leader election after full cluster shutdown
#
# Behavior:
#   1. Check DynamoDB for last_leader record (written whenever a node becomes leader)
#   2. AWS (IMDS available): Use AZ-based preference - same AZ proceeds immediately
#   3. Docker (no IMDS): Use volume_id matching - same volume proceeds immediately
#   4. If different AZ/volume, wait for the last leader's AZ to come up first
#   5. If DUMBO_FORCE_LEADER_PROMOTION=true, skip waiting
#   6. If no last_leader record exists, use checkpoint timestamp election
#
# This prevents a replica with stale data from becoming leader during cold start

LOG_PREFIX="[cold-boot-check]"
SECRETS_FILE="/etc/default/dumbo-secrets"

# Configurable via env var or user data (default 5 minutes)
MAX_WAIT_SECONDS=${DUMBO_COLD_BOOT_TIMEOUT:-300}
WAIT_INTERVAL=10      # Check every 10 seconds
WARN_INTERVAL=60      # Log warning every 60 seconds

echo "$LOG_PREFIX Starting cold boot leader check (timeout=${MAX_WAIT_SECONDS}s)"

# Load secrets for DynamoDB table name
PATRONI_DYNAMODB_TABLE="softoboros-patroni"
PATRONI_SCOPE="softoboros-dumbo"
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
  PATRONI_DYNAMODB_TABLE=${PATRONI_DYNAMODB_TABLE:-softoboros-patroni}
fi

# Get instance metadata (AWS) or use environment (Docker)
get_imds_token() {
  curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --connect-timeout 2 2>/dev/null || echo ""
}

# Mode: "aws" (IMDS available) or "docker" (no IMDS, use volume matching)
MODE="aws"
TOKEN=$(get_imds_token)

if [[ -z "$TOKEN" ]]; then
  echo "$LOG_PREFIX No IMDS available - using Docker/local mode with volume matching"
  MODE="docker"
  # Docker mode: use hostname as instance ID, get region from env
  INSTANCE_ID="${HOSTNAME:-$(hostname)}"
  AZ=""
  MY_AZ_SUFFIX=""
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ca-central-1}}"
else
  INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
  AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")
  REGION=${AZ:0:-1}
  MY_AZ_SUFFIX="${AZ: -1}"
  echo "$LOG_PREFIX Instance: $INSTANCE_ID, AZ: $AZ (suffix: $MY_AZ_SUFFIX)"
fi

# Get the volume ID for this node (used in Docker mode for matching)
# In Docker, this comes from DUMBO_VOLUME_ID env var or volume label
get_my_volume_id() {
  # Check env var first (Docker compose can set this)
  if [[ -n "${DUMBO_VOLUME_ID:-}" ]]; then
    echo "$DUMBO_VOLUME_ID"
    return
  fi

  # AWS: query from NVMe or EC2 API
  if [[ "$MODE" == "aws" ]]; then
    local device
    device=$(df /data 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ -z "$device" ]]; then
      echo ""
      return
    fi

    local nvme_name
    nvme_name=$(readlink -f "$device" 2>/dev/null | sed 's|/dev/||')

    if command -v nvme &>/dev/null; then
      nvme id-ctrl -v "/dev/${nvme_name%%p*}" 2>/dev/null | grep -oE 'vol-[a-f0-9]+' | head -1
    else
      aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[].Instances[].BlockDeviceMappings[?DeviceName==`/dev/xvdf` || DeviceName==`/dev/sdf`].Ebs.VolumeId' \
        --output text 2>/dev/null || echo ""
    fi
  else
    echo ""
  fi
}

MY_VOLUME_ID=""
if [[ "$MODE" == "docker" ]]; then
  MY_VOLUME_ID=$(get_my_volume_id)
  echo "$LOG_PREFIX Docker mode: instance=$INSTANCE_ID, volume=${MY_VOLUME_ID:-<none>}"
fi

# Load settings from user data (AWS only)
# Exports: DUMBO_COLD_BOOT_TIMEOUT, DUMBO_FORCE_LEADER_PROMOTION
load_user_data_settings() {
  if [[ "$MODE" != "aws" || -z "$TOKEN" ]]; then
    return
  fi

  local user_data
  user_data=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/user-data 2>/dev/null || echo "")

  # Extract DUMBO_COLD_BOOT_TIMEOUT if set in user data
  local timeout_val
  timeout_val=$(echo "$user_data" | grep -oE "DUMBO_COLD_BOOT_TIMEOUT\s*=\s*[0-9]+" | grep -oE "[0-9]+")
  if [[ -n "$timeout_val" ]]; then
    MAX_WAIT_SECONDS="$timeout_val"
    echo "$LOG_PREFIX Using DUMBO_COLD_BOOT_TIMEOUT=$timeout_val from user data"
  fi

  # Extract DUMBO_FORCE_LEADER_PROMOTION if set in user data
  if echo "$user_data" | grep -qE "DUMBO_FORCE_LEADER_PROMOTION\s*=\s*true"; then
    export DUMBO_FORCE_LEADER_PROMOTION=true
  fi
}

# Load user data settings early
load_user_data_settings

# Check for force promotion flag in user data (AWS) or env var (Docker)
check_force_promotion() {
  # Check env var (set by load_user_data_settings or externally)
  if [[ "${DUMBO_FORCE_LEADER_PROMOTION:-}" == "true" ]]; then
    return 0
  fi

  return 1  # Force promotion not enabled
}

# Get last_leader record from DynamoDB
get_last_leader() {
  aws dynamodb get-item \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --key "{\"cluster_name\":{\"S\":\"$PATRONI_SCOPE\"},\"key\":{\"S\":\"last_leader\"}}" \
    --output json 2>/dev/null | jq -r '.Item.value.S // empty'
}

# Check if the last leader's AZ has an active Patroni member
check_leader_alive() {
  local leader_info=$1
  local leader_az_suffix
  leader_az_suffix=$(echo "$leader_info" | jq -r '.az_suffix // empty')

  # Check if any member from the leader's AZ is now active in the cluster
  # We query our local Patroni (if running) or check DynamoDB members

  # First, check DynamoDB for members in the leader's AZ
  local members_json
  members_json=$(aws dynamodb query \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --key-condition-expression "cluster_name = :cn AND begins_with(#k, :prefix)" \
    --expression-attribute-names '{"#k":"key"}' \
    --expression-attribute-values "{\":cn\":{\"S\":\"$PATRONI_SCOPE\"},\":prefix\":{\"S\":\"members/\"}}" \
    --output json 2>/dev/null || echo "{}")

  # Check if any member has a recent TTL (meaning it's alive)
  local current_time
  current_time=$(date +%s)

  local alive_in_leader_az
  alive_in_leader_az=$(echo "$members_json" | jq -r --arg az "$leader_az_suffix" --argjson now "$current_time" '
    [.Items[] |
     select(.value.S | fromjson | .role == "master" or .role == "primary" or .role == "leader") |
     select((.ttl.N | tonumber) > $now)
    ] | length
  ' 2>/dev/null || echo "0")

  [[ "$alive_in_leader_az" -gt 0 ]]
}

# Clear last_leader record (call after successful cluster formation)
clear_last_leader() {
  echo "$LOG_PREFIX Clearing last_leader record"
  aws dynamodb delete-item \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --key "{\"cluster_name\":{\"S\":\"$PATRONI_SCOPE\"},\"key\":{\"S\":\"last_leader\"}}" 2>/dev/null || true
}

# Clear cold boot candidates (cleanup after election)
clear_cold_boot_candidates() {
  echo "$LOG_PREFIX Clearing cold boot candidate records"
  # Delete our candidate record
  aws dynamodb delete-item \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --key "{\"cluster_name\":{\"S\":\"$PATRONI_SCOPE\"},\"key\":{\"S\":\"cold_boot_candidate/$INSTANCE_ID\"}}" 2>/dev/null || true
}

# Get PostgreSQL checkpoint timestamp from pg_controldata
# Returns epoch timestamp or empty if no data
get_pg_checkpoint_timestamp() {
  local pgdata="/data/pgdata/16/main"
  local pg_controldata="/usr/lib/postgresql/16/bin/pg_controldata"

  # Check if data directory exists and has data
  if [[ ! -d "$pgdata" ]] || [[ ! -f "$pgdata/global/pg_control" ]]; then
    echo ""
    return
  fi

  # Get checkpoint timestamp from pg_controldata
  local checkpoint_time
  checkpoint_time=$("$pg_controldata" "$pgdata" 2>/dev/null | grep "Time of latest checkpoint:" | cut -d: -f2- | xargs)

  if [[ -z "$checkpoint_time" ]]; then
    echo ""
    return
  fi

  # Convert to epoch timestamp
  date -d "$checkpoint_time" +%s 2>/dev/null || echo ""
}

# Register as a cold boot candidate with our checkpoint timestamp
register_cold_boot_candidate() {
  local checkpoint_ts=$1
  local current_time
  current_time=$(date +%s)
  local ttl=$((current_time + 120))  # 2 minute TTL

  echo "$LOG_PREFIX Registering as cold boot candidate: checkpoint_ts=$checkpoint_ts"

  aws dynamodb put-item \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --item "{
      \"cluster_name\": {\"S\": \"$PATRONI_SCOPE\"},
      \"key\": {\"S\": \"cold_boot_candidate/$INSTANCE_ID\"},
      \"value\": {\"S\": \"{\\\"instance_id\\\": \\\"$INSTANCE_ID\\\", \\\"az\\\": \\\"$AZ\\\", \\\"checkpoint_ts\\\": $checkpoint_ts}\"},
      \"ttl\": {\"N\": \"$ttl\"}
    }" 2>/dev/null
}

# Get all cold boot candidates and find the one with newest checkpoint
get_newest_candidate() {
  local candidates_json
  candidates_json=$(aws dynamodb query \
    --region "$REGION" \
    --table-name "$PATRONI_DYNAMODB_TABLE" \
    --key-condition-expression "cluster_name = :cn AND begins_with(#k, :prefix)" \
    --expression-attribute-names '{"#k":"key"}' \
    --expression-attribute-values "{\":cn\":{\"S\":\"$PATRONI_SCOPE\"},\":prefix\":{\"S\":\"cold_boot_candidate/\"}}" \
    --output json 2>/dev/null || echo "{}")

  # Find candidate with highest checkpoint_ts
  echo "$candidates_json" | jq -r '
    [.Items[] | .value.S | fromjson] |
    sort_by(.checkpoint_ts) |
    reverse |
    .[0].instance_id // empty
  ' 2>/dev/null || echo ""
}

# Fallback election when no last_leader record exists
# Uses PostgreSQL checkpoint timestamp to elect the node with newest data
fallback_checkpoint_election() {
  local my_checkpoint_ts
  my_checkpoint_ts=$(get_pg_checkpoint_timestamp)

  if [[ -z "$my_checkpoint_ts" ]]; then
    echo "$LOG_PREFIX No PostgreSQL data found - proceeding as fresh node"
    return 0  # Proceed
  fi

  echo "$LOG_PREFIX Found PostgreSQL data with checkpoint timestamp: $my_checkpoint_ts ($(date -d @"$my_checkpoint_ts" 2>/dev/null || echo 'unknown'))"

  # Register ourselves as a candidate
  register_cold_boot_candidate "$my_checkpoint_ts"

  # Wait for other candidates to register (give them 30 seconds)
  echo "$LOG_PREFIX Waiting 30s for other cold boot candidates to register..."
  local wait_for_candidates=30
  local waited=0

  while [[ $waited -lt $wait_for_candidates ]]; do
    sleep 5
    waited=$((waited + 5))

    local newest
    newest=$(get_newest_candidate)

    if [[ -n "$newest" ]]; then
      echo "$LOG_PREFIX Current newest candidate: $newest (waited ${waited}s)"
    fi
  done

  # Final check - who has the newest checkpoint?
  local newest_candidate
  newest_candidate=$(get_newest_candidate)

  if [[ -z "$newest_candidate" ]]; then
    echo "$LOG_PREFIX No candidates found (unexpected) - proceeding"
    clear_cold_boot_candidates
    return 0
  fi

  if [[ "$newest_candidate" == "$INSTANCE_ID" ]]; then
    echo "$LOG_PREFIX We have the newest checkpoint - proceeding as leader candidate"
    clear_cold_boot_candidates
    return 0  # Proceed
  else
    echo "$LOG_PREFIX Node $newest_candidate has newer checkpoint - waiting for it to become leader"

    # Wait for the winner to start Patroni and become leader
    local max_wait=180  # 3 minutes
    waited=0

    while [[ $waited -lt $max_wait ]]; do
      # Check if any leader exists in DynamoDB
      local leader_exists
      leader_exists=$(aws dynamodb get-item \
        --region "$REGION" \
        --table-name "$PATRONI_DYNAMODB_TABLE" \
        --key "{\"cluster_name\":{\"S\":\"$PATRONI_SCOPE\"},\"key\":{\"S\":\"leader\"}}" \
        --output json 2>/dev/null | jq -r '.Item.value.S // empty')

      if [[ -n "$leader_exists" ]]; then
        echo "$LOG_PREFIX Leader established: $leader_exists - proceeding to join"
        clear_cold_boot_candidates
        return 0
      fi

      sleep 10
      waited=$((waited + 10))
      echo "$LOG_PREFIX Waiting for leader to be established... (${waited}s)"
    done

    echo "$LOG_PREFIX WARNING: Timeout waiting for leader - proceeding anyway"
    clear_cold_boot_candidates
    return 0
  fi
}

# Main logic
main() {
  # Check for force promotion flag
  if check_force_promotion; then
    echo "$LOG_PREFIX DUMBO_FORCE_LEADER_PROMOTION=true detected - skipping cold boot check"
    echo "$LOG_PREFIX WARNING: Forcing leader promotion may cause data loss if this node has stale data"
    clear_last_leader
    exit 0
  fi

  # Get last_leader record
  local last_leader
  last_leader=$(get_last_leader)

  if [[ -z "$last_leader" ]]; then
    echo "$LOG_PREFIX No last_leader record found"
    echo "$LOG_PREFIX Using fallback: checkpoint timestamp election"
    fallback_checkpoint_election
    exit 0
  fi

  echo "$LOG_PREFIX Found last_leader record: $last_leader"

  local leader_az_suffix
  local leader_timestamp
  local leader_volume_id
  leader_az_suffix=$(echo "$last_leader" | jq -r '.az_suffix // empty')
  leader_timestamp=$(echo "$last_leader" | jq -r '.timestamp // empty')
  leader_volume_id=$(echo "$last_leader" | jq -r '.volume_id // empty')

  echo "$LOG_PREFIX Cold boot leader: az_suffix=$leader_az_suffix, volume=$leader_volume_id (recorded at: $leader_timestamp)"

  # Matching logic depends on mode
  if [[ "$MODE" == "aws" ]]; then
    # AWS mode: use AZ matching
    if [[ -n "$MY_AZ_SUFFIX" && "$MY_AZ_SUFFIX" == "$leader_az_suffix" ]]; then
      echo "$LOG_PREFIX We are in the last leader's AZ ($MY_AZ_SUFFIX) - proceeding as potential leader"
      clear_last_leader
      exit 0
    fi
    echo "$LOG_PREFIX We are in AZ $MY_AZ_SUFFIX, last leader was in AZ $leader_az_suffix"
  else
    # Docker mode: use volume matching
    if [[ -n "$MY_VOLUME_ID" && -n "$leader_volume_id" && "$MY_VOLUME_ID" == "$leader_volume_id" ]]; then
      echo "$LOG_PREFIX We have the last leader's volume ($MY_VOLUME_ID) - proceeding as potential leader"
      clear_last_leader
      exit 0
    fi
    if [[ -n "$leader_volume_id" ]]; then
      echo "$LOG_PREFIX Our volume ($MY_VOLUME_ID) != leader volume ($leader_volume_id)"
    else
      echo "$LOG_PREFIX No volume_id in last_leader record - using checkpoint fallback"
      fallback_checkpoint_election
      exit 0
    fi
  fi

  echo "$LOG_PREFIX Waiting for last leader's AZ to start first (prevents stale replica from becoming leader)"

  local waited=0
  local last_warn=0

  while [[ $waited -lt $MAX_WAIT_SECONDS ]]; do
    # Check if leader is alive
    if check_leader_alive "$last_leader"; then
      echo "$LOG_PREFIX Cold boot leader is now active - proceeding to join cluster"
      exit 0
    fi

    # Log warning periodically
    if [[ $((waited - last_warn)) -ge $WARN_INTERVAL ]]; then
      echo "$LOG_PREFIX WAITING: Cold boot leader (AZ $leader_az_suffix) not yet active. Waited ${waited}s of ${MAX_WAIT_SECONDS}s max"
      echo "$LOG_PREFIX To force promotion, set DUMBO_FORCE_LEADER_PROMOTION=true in instance user_data"
      last_warn=$waited
    fi

    sleep $WAIT_INTERVAL
    waited=$((waited + WAIT_INTERVAL))
  done

  # Timeout reached
  echo "$LOG_PREFIX WARNING: Timeout waiting for last leader's AZ (${MAX_WAIT_SECONDS}s)"
  echo "$LOG_PREFIX Proceeding anyway - cluster may need manual intervention"
  echo "$LOG_PREFIX If this node has stale data, run: patronictl reinit $PATRONI_SCOPE $INSTANCE_ID"

  exit 0
}

main "$@"
