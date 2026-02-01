# User Data Configuration Analysis

## Current State

The current user_data handling in `dumbo-cold-boot-check.sh:52-59` only checks for one hardcoded key:

```bash
user_data=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/user-data 2>/dev/null || echo "")
if echo "$user_data" | grep -qE "DUMBO_FORCE_LEADER_PROMOTION\s*=\s*true"; then
```

## Proposed: Generic key=value Parser

To support configurable SYSLOG/CloudWatch via user_data, add a generic parser:

```bash
# Parse user_data key=value pairs into env vars
parse_user_data() {
  local user_data
  user_data=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/user-data 2>/dev/null || echo "")

  # Export each KEY=value line (skip comments/empty)
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    export "$key"="$value"
  done <<< "$user_data"
}
```

## Supported Keys (Proposed)

| Key | Default | Description |
|-----|---------|-------------|
| `DUMBO_FORCE_LEADER_PROMOTION` | `false` | Skip cold boot check, force leader |
| `DUMBO_SYSLOG_ENABLED` | `true` | Enable/disable syslog forwarding |
| `DUMBO_CLOUDWATCH_ENABLED` | `false` | Enable CloudWatch agent logging |

## Can SYSLOG be Disabled?

**Yes, but needs code changes.**

Currently `dumbo-syslog.service` is unconditionally enabled in the packer build (`softoboros-dumbo-debian12-arm64.pkr.hcl:285`):

```bash
sudo systemctl enable dumbo-syslog.service
```

To make it conditional:
1. Keep service installed but not enabled in packer
2. Add check in boot sequence (e.g., `dumbo-init.sh` or new `dumbo-logging.sh`)
3. Enable/start syslog only if `DUMBO_SYSLOG_ENABLED != false`

## Can CloudWatch be Enabled?

**Not currently implemented.**

Would require:
1. Install CloudWatch agent in packer build
2. Add CloudWatch agent config template
3. Add `dumbo-cloudwatch.service` to configure and start agent
4. Check `DUMBO_CLOUDWATCH_ENABLED=true` in user_data before enabling

## Example user_data

```
# Disable syslog forwarding, enable CloudWatch
DUMBO_SYSLOG_ENABLED=false
DUMBO_CLOUDWATCH_ENABLED=true

# Force leader promotion (emergency only)
# DUMBO_FORCE_LEADER_PROMOTION=true
```

## Files to Modify

1. **New**: `packer/files-common/usr/local/bin/softoboros-parse-userdata.sh` - generic parser
2. **Modify**: `packer/files-dumbo/usr/local/bin/dumbo-cold-boot-check.sh` - use parser
3. **Modify**: `packer/files-dumbo/etc/systemd/system/dumbo-syslog.service` - conditional start
4. **New**: `packer/files-dumbo/etc/systemd/system/dumbo-cloudwatch.service` - CloudWatch support
5. **Modify**: `packer/softoboros-dumbo-debian12-arm64.pkr.hcl` - install CloudWatch agent
