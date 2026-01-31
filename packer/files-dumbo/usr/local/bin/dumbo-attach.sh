#!/usr/bin/env bash
set -euo pipefail

# Attach EBS volume for PostgreSQL data directory
# Adapted from attach-db.sh for standalone Dumbo AMI

# Optional environment file for overrides
ENV_FILE=/etc/default/dumbo-attach
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

MOUNT_POINT=${DUMBO_MOUNT_POINT:-/data/pgdata}
PGDATA_SUBDIR=${DUMBO_PGDATA_SUBDIR:-16/main}

# Get IMDSv2 token (required when HttpTokens=required)
TOKEN=""
for i in $(seq 1 10); do
  TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null | grep -v '^$' || echo "")
  [[ -n "$TOKEN" ]] && break
  sleep 2
done

# Use token for metadata requests (IMDSv2) or fall back to IMDSv1 if no token
if [[ -n "$TOKEN" ]]; then
  IID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
else
  IID=$(curl http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  AZ=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
fi

[[ -z "$IID" ]] && { echo "[dumbo-attach] failed to get instance-id from IMDS"; exit 1; }
[[ -z "$AZ" ]] && { echo "[dumbo-attach] failed to get availability-zone from IMDS"; exit 1; }

REGION=${AZ:0:-1}

# Determine AZ suffix and select appropriate volume parameter
# Patroni HA: each AZ has its own EBS volume for data persistence
AZ_SUFFIX=${AZ: -1}
case "$AZ_SUFFIX" in
  a) VOL_PARAM_PATH="/softoboros/dumbo/volume-id-a" ;;
  b) VOL_PARAM_PATH="/softoboros/dumbo/volume-id-b" ;;
  c) VOL_PARAM_PATH="/softoboros/dumbo/volume-id-c" ;;
  d) VOL_PARAM_PATH="/softoboros/dumbo/volume-id-d" ;;
  *)
    echo "[dumbo-attach] WARNING: Unrecognized AZ suffix '$AZ_SUFFIX', falling back to legacy parameter"
    VOL_PARAM_PATH="/softoboros/dumbo/volume-id"
    ;;
esac

echo "[dumbo-attach] AZ: $AZ, using volume parameter: $VOL_PARAM_PATH"

vol_id=""

# Try AZ-specific parameter first
if aws ssm get-parameter --region "$REGION" --name "$VOL_PARAM_PATH" >/dev/null 2>&1; then
  vol_id=$(aws ssm get-parameter --with-decryption --region "$REGION" --name "$VOL_PARAM_PATH" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
fi

# Fallback to legacy parameter (for backwards compatibility during migration)
if [[ -z "$vol_id" || "$vol_id" == "None" ]]; then
  echo "[dumbo-attach] AZ-specific parameter not found, trying legacy /softoboros/dumbo/volume-id"
  vol_id=$(aws ssm get-parameter --with-decryption --region "$REGION" --name "/softoboros/dumbo/volume-id" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
fi

# Fallback to volume with matching tag (for AZ-specific tag)
if [[ -z "$vol_id" || "$vol_id" == "None" ]]; then
  VOL_TAG_VALUE="dumbo-data-${AZ_SUFFIX}"
  echo "[dumbo-attach] Trying tag lookup: Name=$VOL_TAG_VALUE"
  vol_id=$(aws ec2 describe-volumes --region "$REGION" \
    --filters Name=tag:Name,Values=${VOL_TAG_VALUE} Name=availability-zone,Values=${AZ} \
    --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo "")
fi

# Final fallback to generic dumbo-data tag
if [[ -z "$vol_id" || "$vol_id" == "None" ]]; then
  echo "[dumbo-attach] Trying tag lookup: Name=dumbo-data"
  vol_id=$(aws ec2 describe-volumes --region "$REGION" \
    --filters Name=tag:Name,Values=dumbo-data --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo "")
fi

# No volume configured - fatal error
if [[ -z "$vol_id" || "$vol_id" == "None" ]]; then
  echo "[dumbo-attach] CRITICAL: no volume id found (param=$VOL_PARAM_PATH)" >&2
  logger -p local0.crit -t dumbo-attach "CRITICAL: no volume id found for $AZ - terminating instance"
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --region "$REGION" \
    --instance-id "$IID" \
    --should-decrement-desired-capacity || true
  exit 1
fi

vol_az=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol_id" --query 'Volumes[0].AvailabilityZone' --output text 2>/dev/null || echo "")
if [[ "$vol_az" != "$AZ" ]]; then
  echo "[dumbo-attach] CRITICAL: volume AZ ($vol_az) != instance AZ ($AZ)" >&2
  logger -p local0.crit -t dumbo-attach "CRITICAL: volume $vol_id AZ mismatch - terminating instance"
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --region "$REGION" \
    --instance-id "$IID" \
    --should-decrement-desired-capacity || true
  exit 1
fi

# Retry loop: wait for volume to become available (5 second intervals, 5 minutes max)
MAX_ATTEMPTS=60
RETRY_INTERVAL=5
attempt=0

while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
  attempt=$((attempt + 1))

  attached_to=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol_id" --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo "")

  # Volume is available (not attached) - try to attach it
  if [[ -z "$attached_to" || "$attached_to" == "None" ]]; then
    echo "[dumbo-attach] volume available, attaching $vol_id to $IID"
    if aws ec2 attach-volume --region "$REGION" --volume-id "$vol_id" --instance-id "$IID" --device /dev/xvdg 2>/dev/null; then
      # Wait for attachment to complete
      for i in $(seq 1 30); do
        attached_to=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol_id" --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo "")
        [[ "$attached_to" == "$IID" ]] && break
        sleep 2
      done
    fi
  fi

  # Check if we got the volume
  if [[ "$attached_to" == "$IID" ]]; then
    echo "[dumbo-attach] successfully attached volume $vol_id"
    break
  fi

  # Volume still attached to another instance - wait and retry
  echo "[dumbo-attach] volume $vol_id attached to $attached_to, waiting... (attempt $attempt/$MAX_ATTEMPTS)"
  sleep $RETRY_INTERVAL
done

# Final check - if we still don't have the volume, terminate
if [[ "$attached_to" != "$IID" ]]; then
  echo "[dumbo-attach] CRITICAL: failed to attach volume $vol_id after $MAX_ATTEMPTS attempts (attached to: $attached_to)" >&2
  logger -p local0.crit -t dumbo-attach "CRITICAL: failed to attach volume $vol_id after 5 minutes - terminating instance"
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --region "$REGION" \
    --instance-id "$IID" \
    --should-decrement-desired-capacity || true
  exit 1
fi

# Resolve NVMe by-id symlink (handle different naming formats)
link1="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_id}"
link2="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_id//-/}"
link3="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_id#vol-}"
for i in $(seq 1 45); do [[ -e "$link1" || -e "$link2" || -e "$link3" ]] && break; sleep 2; done
[[ -e "$link1" || -e "$link2" || -e "$link3" ]] || { echo "[dumbo-attach] by-id link not found for $vol_id"; exit 0; }

dev=$(readlink -f "${link1}" 2>/dev/null)
[[ -z "$dev" || ! -b "$dev" ]] && dev=$(readlink -f "${link2}" 2>/dev/null)
[[ -z "$dev" || ! -b "$dev" ]] && dev=$(readlink -f "${link3}" 2>/dev/null)
[[ -z "$dev" || ! -b "$dev" ]] && { echo "[dumbo-attach] resolved device invalid"; exit 0; }

# Format if blank volume
if ! blkid "$dev" >/dev/null 2>&1; then
  echo "[dumbo-attach] mkfs.ext4 on $dev"
  mkfs.ext4 -F -L dumbo-data "$dev"
fi

# Mount the volume
mkdir -p "$MOUNT_POINT"
uuid=$(blkid -s UUID -o value "$dev")
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $MOUNT_POINT ext4 noatime,nofail 0 2" >> /etc/fstab
mount -a || mount "$dev" "$MOUNT_POINT" || true

# Create PGDATA structure if missing
PGDATA_PATH="${MOUNT_POINT}/${PGDATA_SUBDIR}"
if [[ ! -d "$PGDATA_PATH" ]]; then
  echo "[dumbo-attach] creating PGDATA structure at $PGDATA_PATH"
  mkdir -p "$PGDATA_PATH"
fi

# Set ownership
chown -R postgres:postgres "$MOUNT_POINT"
chmod 0700 "$PGDATA_PATH"

# Create symlink from default PGDATA to mounted volume
DEFAULT_PGDATA="/var/lib/postgresql/16/main"
if [[ -d "$DEFAULT_PGDATA" && ! -L "$DEFAULT_PGDATA" ]]; then
  # Move existing data if any
  if [[ -n "$(ls -A $DEFAULT_PGDATA 2>/dev/null)" ]]; then
    echo "[dumbo-attach] moving existing PGDATA to EBS volume"
    mv "$DEFAULT_PGDATA"/* "$PGDATA_PATH"/ || true
  fi
  rmdir "$DEFAULT_PGDATA" 2>/dev/null || rm -rf "$DEFAULT_PGDATA"
fi

if [[ ! -L "$DEFAULT_PGDATA" ]]; then
  echo "[dumbo-attach] creating symlink $DEFAULT_PGDATA -> $PGDATA_PATH"
  ln -sf "$PGDATA_PATH" "$DEFAULT_PGDATA"
  chown -h postgres:postgres "$DEFAULT_PGDATA"
fi

echo "[dumbo-attach] EBS volume $vol_id mounted at $MOUNT_POINT"
exit 0
