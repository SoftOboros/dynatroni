<p align="center">
  <img src="dynatroni.png" alt="Dynatroni" width="300">
</p>

# Changelog

## 0.2.0

### Cold Boot Leader Election
- **Changed**: Renamed `cold_boot_leader` to `last_leader` record in DynamoDB
  - Now written whenever a node becomes primary (on `on_start` or `on_role_change`)
  - Previously only written when a solo leader shut down cleanly
- **Added**: Configurable cold boot timeout via `DUMBO_COLD_BOOT_TIMEOUT` env var or EC2 user data (default: 300s)
- **Added**: `load_user_data_settings()` function to read settings from EC2 user data
- **Changed**: Systemd `TimeoutStartSec=360` in patroni.service to accommodate cold boot wait

### DynamoDB DCS (dynatroni)
- **Added**: Smart rate limiting with TTL-aware emergency renewal mode
  - Tracks real elapsed time instead of fixed delays
  - Emergency mode when approaching TTL expiry (skips delay)
  - Prevents rate limit delays from causing TTL expiry
- **Fixed**: `_get_item()` now returns expired items by default (`check_ttl=False`)
  - Allows proper leader takeover when TTL expired but item still exists
  - Caller can opt-in to TTL checking with `check_ttl=True`
- **Added**: Leader state tracking (`_is_leader`, `_leader_lock_acquired_at`)

### Patroni Callback
- **Added**: System table registration for HA participant discovery
- **Changed**: `record_last_leader()` called on becoming primary (both `on_start` and `on_role_change`)

### Documentation
- Updated multi-az-and-cold-start.md with complete cold boot behavior documentation
- Updated configuration.md with cold boot environment variables
- Updated operations.md with configurable timeout and troubleshooting tips

## 0.1.0
- Initial release extracted from the source monorepo
