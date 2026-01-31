#!/usr/bin/env bash
set -euo pipefail

# Generate Patroni configuration from template
# Uses DynamoDB as Distributed Configuration Store (no quorum needed)

TEMPLATE="/etc/patroni/patroni.yml.template"
OUTPUT="/etc/patroni/patroni.yml"
SECRETS_FILE="/etc/default/dumbo-secrets"

echo "[patroni-configure] Generating Patroni configuration..."

# Get IMDSv2 token
TOKEN=""
for i in $(seq 1 10); do
  TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null | grep -v '^$' || echo "")
  [[ -n "$TOKEN" ]] && break
  sleep 2
done

if [[ -z "$TOKEN" ]]; then
  echo "[patroni-configure] ERROR: Failed to get IMDS token"
  exit 1
fi

# Get instance metadata
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
REGION=${AZ:0:-1}

if [[ -z "$INSTANCE_ID" || -z "$PRIVATE_IP" ]]; then
  echo "[patroni-configure] ERROR: Failed to get instance metadata"
  exit 1
fi

# Use instance ID as node name (unique within cluster)
NODE_NAME="$INSTANCE_ID"
echo "[patroni-configure] Node: $NODE_NAME, IP: $PRIVATE_IP, AZ: $AZ"

# Load secrets
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
else
  echo "[patroni-configure] WARNING: $SECRETS_FILE not found"
fi

# Get DynamoDB table name from SSM (or use default)
DYNAMODB_TABLE=$(aws ssm get-parameter --region "$REGION" --name /softoboros/patroni/dynamodb_table --query 'Parameter.Value' --output text 2>/dev/null || echo "softoboros-patroni")

# Get failover_time from SSM (or use default of 60 seconds)
# This is the single "dial" for cost vs responsiveness tradeoff:
#   15s  = Fast failover, higher DynamoDB costs
#   60s  = Balanced (default)
#   180s = Cost optimized, slower failover
FAILOVER_TIME=$(aws ssm get-parameter --region "$REGION" --name /softoboros/patroni/failover_time --query 'Parameter.Value' --output text 2>/dev/null || echo "60")

# Enforce minimum of 15 seconds for safety
if [[ "$FAILOVER_TIME" -lt 15 ]]; then
  echo "[patroni-configure] WARNING: failover_time=$FAILOVER_TIME is below minimum, using 15"
  FAILOVER_TIME=15
fi

# Derive timing parameters from failover_time
# TTL = failover_time (leader lock validity window)
# loop_wait, retry_timeout = failover_time / 3 (3 chances to renew before expiry)
PATRONI_TTL=$FAILOVER_TIME
PATRONI_LOOP_WAIT=$((FAILOVER_TIME / 3))
PATRONI_RETRY_TIMEOUT=$((FAILOVER_TIME / 3))

echo "[patroni-configure] Timing: failover_time=${FAILOVER_TIME}s, ttl=${PATRONI_TTL}s, loop_wait=${PATRONI_LOOP_WAIT}s"

# Get replicator password from SSM
REPLICATOR_PASSWORD=$(aws ssm get-parameter --region "$REGION" --name /softoboros/postgres/replicator_password --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || echo "")

# Use postgres password from secrets file (already fetched by dumbo-fetch-secrets.sh)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-""}

if [[ -z "$REPLICATOR_PASSWORD" ]]; then
  echo "[patroni-configure] WARNING: No replicator password found in SSM"
  echo "[patroni-configure] Set /softoboros/postgres/replicator_password in Parameter Store"
fi

if [[ -z "$POSTGRES_PASSWORD" ]]; then
  echo "[patroni-configure] WARNING: No postgres password found"
fi

# Export variables for envsubst
export NODE_NAME PRIVATE_IP DYNAMODB_TABLE REPLICATOR_PASSWORD POSTGRES_PASSWORD
export FAILOVER_TIME PATRONI_TTL PATRONI_LOOP_WAIT PATRONI_RETRY_TIMEOUT

# Generate configuration
echo "[patroni-configure] Writing configuration to $OUTPUT"
envsubst < "$TEMPLATE" > "$OUTPUT"

# Secure the config file (contains passwords)
chmod 600 "$OUTPUT"
chown postgres:postgres "$OUTPUT"

# Ensure data directory exists and has correct permissions
DATA_DIR="/data/pgdata/16/main"
if [[ -d "$DATA_DIR" ]]; then
  chown -R postgres:postgres "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
fi

# Ensure pg_hba.conf matches the managed version from the repo
# bootstrap.pg_hba only applies on initial cluster creation, so we overwrite on every boot
PG_HBA_MANAGED="/etc/postgresql/16/main/pg_hba.conf"
PG_HBA_DATA="$DATA_DIR/pg_hba.conf"
if [[ -f "$PG_HBA_MANAGED" && -d "$DATA_DIR" ]]; then
  echo "[patroni-configure] Installing managed pg_hba.conf"
  cp "$PG_HBA_MANAGED" "$PG_HBA_DATA"
  chown postgres:postgres "$PG_HBA_DATA"
  chmod 600 "$PG_HBA_DATA"
fi

echo "[patroni-configure] Configuration generated successfully"
echo "[patroni-configure] DynamoDB table: $DYNAMODB_TABLE"
exit 0
