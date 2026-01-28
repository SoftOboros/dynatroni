#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="/etc/patroni/patroni.yml.template"
OUTPUT="/etc/patroni/patroni.yml"

: "${PATRONI_SCOPE:=patroni}"
: "${PATRONI_NODE_NAME:=$(hostname -s)}"
: "${PATRONI_CONNECT_ADDRESS:=$(hostname -I | awk '{print $1}')}"
: "${AWS_REGION:=${DYNATRONI_AWS_REGION:-}}"
: "${DYNAMODB_TABLE:=patroni-dynamodb}"
: "${REPLICATOR_PASSWORD:=replicator}"
: "${POSTGRES_PASSWORD:=postgres}"

sed \
  -e "s|\${PATRONI_SCOPE}|${PATRONI_SCOPE}|g" \
  -e "s|\${PATRONI_NODE_NAME}|${PATRONI_NODE_NAME}|g" \
  -e "s|\${PATRONI_CONNECT_ADDRESS}|${PATRONI_CONNECT_ADDRESS}|g" \
  -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
  -e "s|\${DYNAMODB_TABLE}|${DYNAMODB_TABLE}|g" \
  -e "s|\${REPLICATOR_PASSWORD}|${REPLICATOR_PASSWORD}|g" \
  -e "s|\${POSTGRES_PASSWORD}|${POSTGRES_PASSWORD}|g" \
  "$TEMPLATE" > "$OUTPUT"

chmod 600 "$OUTPUT"
