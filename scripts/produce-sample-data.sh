#!/usr/bin/env bash
# Produce sample JSON events into the Kafka topic
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"

COUNT="${1:-20}"

echo "==> Producing ${COUNT} JSON messages to topic '${SAMPLE_TOPIC}'"
for i in $(seq 1 "${COUNT}"); do
  TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  MSG=$(jq -nc \
    --arg id "evt-${i}" \
    --arg ts "${TS}" \
    --argjson n "${i}" \
    '{id:$id, event_type:"user.signup", user_id:("user-"+($n|tostring)), amount:($n * 1.25), ts:$ts}')
  printf '%s\n' "${MSG}"
done | podman exec -i streamstack-kafka kafka-console-producer \
  --bootstrap-server "kafka:${KAFKA_INTERNAL_PORT}" \
  --topic "${SAMPLE_TOPIC}"

echo "Done. Verify with ./scripts/07-verify.sh"
