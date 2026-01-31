#!/usr/bin/env bash
set -euo pipefail

# Generate pgbouncer configuration from template and secrets
# Run before pgbouncer starts

SECRETS_FILE="/etc/default/dumbo-secrets"
TEMPLATE_FILE="/etc/pgbouncer/pgbouncer.ini.template"
CONFIG_FILE="/etc/pgbouncer/pgbouncer.ini"
USERLIST_FILE="/etc/pgbouncer/userlist.txt"

echo "[dumbo-pgbouncer] Generating pgbouncer configuration..."

# Source secrets
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
else
  echo "[dumbo-pgbouncer] No secrets file found; using defaults"
  POSTGRES_USER="postgres"
  POSTGRES_PASSWORD=""
  PGBOUNCER_POOL_MODE="session"
  PGBOUNCER_MAX_CLIENT_CONN="1000"
  PGBOUNCER_DEFAULT_POOL_SIZE="25"
  PGBOUNCER_MIN_POOL_SIZE="10"
  PGBOUNCER_RESERVE_POOL_SIZE="5"
  PGBOUNCER_MAX_DB_CONNECTIONS="50"
  PGBOUNCER_SERVER_IDLE_TIMEOUT="600"
fi

# Generate userlist.txt with SCRAM-SHA-256 password hash
# For scram-sha-256, we extract the stored hash from PostgreSQL's pg_authid
# pgbouncer expects: "username" "SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>"
password_hash=""
if command -v psql &>/dev/null; then
  # Try to get the SCRAM hash from PostgreSQL (requires PostgreSQL to be running)
  password_hash=$(su -l postgres -c "psql -t -A -c \"SELECT rolpassword FROM pg_authid WHERE rolname='$POSTGRES_USER'\"" 2>/dev/null || echo "")
fi

if [[ -z "$password_hash" || "$password_hash" == *"null"* ]]; then
  echo "[dumbo-pgbouncer] WARNING: Could not get password hash from PostgreSQL, password auth may fail"
  # Fall back to plaintext (pgbouncer can hash it for scram-sha-256)
  password_hash="$POSTGRES_PASSWORD"
fi

echo "\"$POSTGRES_USER\" \"$password_hash\"" > "$USERLIST_FILE"
chmod 600 "$USERLIST_FILE"
chown postgres:postgres "$USERLIST_FILE"
echo "[dumbo-pgbouncer] Generated $USERLIST_FILE"

# Export variables for envsubst
export POSTGRES_USER
export PGBOUNCER_POOL_MODE
export PGBOUNCER_MAX_CLIENT_CONN
export PGBOUNCER_DEFAULT_POOL_SIZE
export PGBOUNCER_MIN_POOL_SIZE
export PGBOUNCER_RESERVE_POOL_SIZE
export PGBOUNCER_MAX_DB_CONNECTIONS
export PGBOUNCER_SERVER_IDLE_TIMEOUT

# Generate pgbouncer.ini from template
if [[ -f "$TEMPLATE_FILE" ]]; then
  envsubst < "$TEMPLATE_FILE" > "$CONFIG_FILE"
else
  echo "[dumbo-pgbouncer] ERROR: Template file not found: $TEMPLATE_FILE"
  exit 1
fi

chmod 640 "$CONFIG_FILE"
chown postgres:postgres "$CONFIG_FILE"

echo "[dumbo-pgbouncer] Generated $CONFIG_FILE"
echo "[dumbo-pgbouncer] Pool mode: $PGBOUNCER_POOL_MODE"
echo "[dumbo-pgbouncer] Max client connections: $PGBOUNCER_MAX_CLIENT_CONN"
echo "[dumbo-pgbouncer] Default pool size: $PGBOUNCER_DEFAULT_POOL_SIZE"

# Ensure runtime directories exist
mkdir -p /var/run/pgbouncer /var/log/pgbouncer
chown postgres:postgres /var/run/pgbouncer /var/log/pgbouncer
chmod 0750 /var/run/pgbouncer /var/log/pgbouncer

echo "[dumbo-pgbouncer] Configuration complete"
exit 0
