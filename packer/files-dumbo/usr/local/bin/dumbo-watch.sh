#!/usr/bin/env bash
set -euo pipefail

# Health watchdog for PostgreSQL and pgbouncer
# Restarts services if they become unhealthy

RESTART_DELAY=5

check_postgresql() {
  # Check if systemd service is active
  if ! systemctl is-active --quiet postgresql@16-main; then
    echo "[dumbo-watch] PostgreSQL service not active"
    return 1
  fi

  # Check if PostgreSQL is accepting connections
  if ! su - postgres -c "pg_isready -p 5432" >/dev/null 2>&1; then
    echo "[dumbo-watch] PostgreSQL not accepting connections on port 5432"
    return 1
  fi

  return 0
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
  echo "[dumbo-watch] Restarting PostgreSQL..."
  systemctl restart postgresql@16-main
  sleep "$RESTART_DELAY"
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
