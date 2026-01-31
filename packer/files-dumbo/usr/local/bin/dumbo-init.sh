#!/usr/bin/env bash
set -euo pipefail

# Initialize PostgreSQL databases (first boot only, primary only)
# Creates all softoboros databases and enables pgvector extension
# In Patroni HA setup, replicas sync from primary - no initialization needed

MARKER_FILE="/var/lib/postgresql/.dumbo-init-complete"
SECRETS_FILE="/etc/default/dumbo-secrets"

# Check if already initialized
if [[ -f "$MARKER_FILE" ]]; then
  echo "[dumbo-init] Already initialized (marker exists); skipping"
  exit 0
fi

# Source secrets
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
else
  echo "[dumbo-init] No secrets file found; using defaults"
  POSTGRES_USER="postgres"
  POSTGRES_DB="softoboros"
  POSTGRES_PASSWORD=""
fi

# Wait for PostgreSQL to be ready
echo "[dumbo-init] Waiting for PostgreSQL to be ready..."
for i in $(seq 1 60); do
  if su - postgres -c "pg_isready -p 5432" >/dev/null 2>&1; then
    echo "[dumbo-init] PostgreSQL is ready"
    break
  fi
  sleep 1
done

if ! su - postgres -c "pg_isready -p 5432" >/dev/null 2>&1; then
  echo "[dumbo-init] ERROR: PostgreSQL not ready after 60s"
  exit 1
fi

# Patroni HA: Check if this is a replica - skip initialization if so
# Replicas sync all data from primary via streaming replication
if su - postgres -c "psql -tAc \"SELECT pg_is_in_recovery();\"" 2>/dev/null | grep -q "t"; then
  echo "[dumbo-init] This is a replica (in recovery mode); skipping database initialization"
  echo "[dumbo-init] Databases will sync from primary via streaming replication"
  # Create marker file to prevent future runs
  touch "$MARKER_FILE"
  chown postgres:postgres "$MARKER_FILE"
  exit 0
fi

echo "[dumbo-init] This is the primary; proceeding with database initialization"

# Set postgres password if provided
if [[ -n "$POSTGRES_PASSWORD" ]]; then
  echo "[dumbo-init] Setting postgres password"
  su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${POSTGRES_PASSWORD}';\""
fi

# List of databases to create (from CLAUDE.md database split architecture)
DATABASES=(
  "softoboros"       # Default DB
  "memalpha"         # RAG metadata
  "memalpha_vectors" # pgvector embeddings
  "mailman"          # Email storage
  "media"            # Public/private media
  "pdf_ingest"       # PDF documents
  "istate"           # iState data
  "oapps"            # OAuth apps
  "spice"            # SPICE simulations
  "beancounter"      # Accounting
)

echo "[dumbo-init] Creating databases..."
for db in "${DATABASES[@]}"; do
  if su - postgres -c "psql -lqt | cut -d '|' -f 1 | grep -qw $db"; then
    echo "[dumbo-init] Database '$db' already exists"
  else
    echo "[dumbo-init] Creating database '$db'"
    su - postgres -c "createdb '$db'"
  fi
done

# Enable pgvector extension in memalpha_vectors database
echo "[dumbo-init] Enabling pgvector extension in memalpha_vectors..."
su - postgres -c "psql -d memalpha_vectors -c 'CREATE EXTENSION IF NOT EXISTS vector;'"

# Verify pgvector is installed
if su - postgres -c "psql -d memalpha_vectors -c \"SELECT extname FROM pg_extension WHERE extname='vector';\"" | grep -q vector; then
  echo "[dumbo-init] pgvector extension enabled successfully"
else
  echo "[dumbo-init] WARNING: pgvector extension may not be installed correctly"
fi

# Create marker file
touch "$MARKER_FILE"
chown postgres:postgres "$MARKER_FILE"

echo "[dumbo-init] Database initialization complete"
echo "[dumbo-init] Created databases: ${DATABASES[*]}"
exit 0
