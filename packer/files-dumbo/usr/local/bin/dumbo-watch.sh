#!/usr/bin/env bash
set -euo pipefail

# Health watchdog for PostgreSQL (via Patroni) and pgbouncer
# Restarts services if they become unhealthy
#
# Note: Patroni runs postgres directly as a subprocess, not via systemd.
# We use Patroni's REST API (port 8008) for health checks and patronictl
# for restarts to respect HA cluster state.

RESTART_DELAY=5
PATRONI_CONFIG="/etc/patroni/patroni.yml"

check_postgresql() {
  # Check Patroni health via REST API (port 8008)
  # Returns 200 for leader, 503 for replica (both are "healthy" states)
  if curl -sf "http://127.0.0.1:8008/health" >/dev/null 2>&1; then
    return 0  # Patroni is healthy
  fi

  # Fallback: check if postgres is accepting connections directly
  # This catches cases where Patroni API is slow but postgres is fine
  if pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    return 0
  fi

  echo "[dumbo-watch] PostgreSQL/Patroni unhealthy (REST API and pg_isready failed)"
  return 1
}

check_pgbouncer() {
  # Check if pgbouncer is configured to run
  if ! systemctl is-enabled --quiet dumbo-pgbouncer.service 2>/dev/null; then
    # pgbouncer not enabled, skip check
    return 0
  fi

  # Check if pgbouncer process is running
  if ! pgrep -x pgbouncer >/dev/null 2>&1; then
    echo "[dumbo-watch] pgbouncer process not running"
    return 1
  fi

  # Check if pgbouncer is accepting connections
  if ! pg_isready -h 127.0.0.1 -p 6432 >/dev/null 2>&1; then
    echo "[dumbo-watch] pgbouncer not accepting connections on port 6432"
    return 1
  fi

  return 0
}

restart_postgresql() {
  echo "[dumbo-watch] PostgreSQL/Patroni unhealthy, attempting restart..."

  # Use patronictl to restart - respects HA cluster state
  # The --force flag skips confirmation prompt
  if /opt/patroni/bin/patronictl -c "$PATRONI_CONFIG" restart softoboros-dumbo --force 2>&1; then
    echo "[dumbo-watch] patronictl restart initiated"
    sleep "$RESTART_DELAY"
  else
    echo "[dumbo-watch] WARNING: patronictl restart failed, trying systemctl restart patroni"
    # Fallback: restart the Patroni service itself
    systemctl restart patroni
    sleep "$RESTART_DELAY"
  fi
}

restart_pgbouncer() {
  echo "[dumbo-watch] Restarting pgbouncer..."
  # Kill existing pgbouncer if running
  pkill -x pgbouncer 2>/dev/null || true
  sleep 1
  # Restart via our service (regenerates config)
  systemctl restart dumbo-pgbouncer.service
  sleep "$RESTART_DELAY"
}

main() {
  echo "[dumbo-watch] Running health check at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Check PostgreSQL
  if ! check_postgresql; then
    restart_postgresql
    # Recheck after restart
    if ! check_postgresql; then
      echo "[dumbo-watch] PostgreSQL still unhealthy after restart"
    else
      echo "[dumbo-watch] PostgreSQL recovered"
    fi
  fi

  # Check pgbouncer
  if ! check_pgbouncer; then
    restart_pgbouncer
    # Recheck after restart
    if ! check_pgbouncer; then
      echo "[dumbo-watch] pgbouncer still unhealthy after restart"
    else
      echo "[dumbo-watch] pgbouncer recovered"
    fi
  fi

  echo "[dumbo-watch] Health check complete"
  exit 0
}

main "$@"
