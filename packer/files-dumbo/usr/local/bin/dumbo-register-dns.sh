#!/usr/bin/env bash
set -euo pipefail

# Register/deregister instance with AWS Cloud Map for DNS discovery
# Usage: dumbo-register-dns.sh [register|deregister]

ACTION=${1:-register}
SECRETS_FILE=${2:-/etc/default/dumbo-secrets}

# Load Cloud Map service ID from secrets
if [[ -f "$SECRETS_FILE" ]]; then
  source "$SECRETS_FILE"
fi

# Get instance metadata
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
if [[ -n "$TOKEN" ]]; then
  INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
  REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
else
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
  REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "ca-central-1")
fi

# Validate we have required info
if [[ -z "$INSTANCE_ID" || -z "$PRIVATE_IP" ]]; then
  echo "[dumbo-dns] ERROR: Could not get instance metadata"
  exit 1
fi

# If no Cloud Map service ID configured, skip DNS registration
if [[ -z "${CLOUDMAP_SERVICE_ID:-}" ]]; then
  echo "[dumbo-dns] No CLOUDMAP_SERVICE_ID configured, skipping DNS registration"
  echo "[dumbo-dns] To enable, set /softoboros/dumbo/cloudmap_service_id in SSM Parameter Store"
  exit 0
fi

case "$ACTION" in
  register)
    echo "[dumbo-dns] Registering instance $INSTANCE_ID ($PRIVATE_IP) with Cloud Map..."

    aws servicediscovery register-instance \
      --region "$REGION" \
      --service-id "$CLOUDMAP_SERVICE_ID" \
      --instance-id "$INSTANCE_ID" \
      --attributes "AWS_INSTANCE_IPV4=$PRIVATE_IP,AWS_INSTANCE_PORT=5432"

    echo "[dumbo-dns] Registration complete: dumbo.softoboros-ca -> $PRIVATE_IP"

    # Also register with DynamoDB system table for infrastructure coordination
    if [[ -x /usr/local/bin/softoboros-register-participant.sh ]]; then
      echo "[dumbo-dns] Registering with system table..."
      /usr/local/bin/softoboros-register-participant.sh register --component dumbo --role "${PATRONI_ROLE:-replica}" || \
        echo "[dumbo-dns] WARNING: System table registration failed (non-fatal)"
    fi
    ;;

  deregister)
    echo "[dumbo-dns] Deregistering instance $INSTANCE_ID from Cloud Map..."

    aws servicediscovery deregister-instance \
      --region "$REGION" \
      --service-id "$CLOUDMAP_SERVICE_ID" \
      --instance-id "$INSTANCE_ID" 2>/dev/null || true

    echo "[dumbo-dns] Deregistration complete"

    # Also deregister from DynamoDB system table
    if [[ -x /usr/local/bin/softoboros-register-participant.sh ]]; then
      echo "[dumbo-dns] Deregistering from system table..."
      /usr/local/bin/softoboros-register-participant.sh deregister --component dumbo --reason shutdown || \
        echo "[dumbo-dns] WARNING: System table deregistration failed (non-fatal)"
    fi
    ;;

  *)
    echo "Usage: $0 [register|deregister]"
    exit 1
    ;;
esac

exit 0
