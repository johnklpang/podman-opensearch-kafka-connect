#!/usr/bin/env bash
# Emergency: stop crash-loop, bake plugin into image, start Connect with stock entrypoint.
# Use this when logs show:
#   /entrypoint/docker-entrypoint.sh: line N: find: command not found
# or:
#   Failed to find ... OpenSearchSinkConnector
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"
CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
EXPECTED="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"

echo "==> Stopping crash-loop / old Connect container"
podman rm -f streamstack-kafka-connect 2>/dev/null || true

echo "==> Ensuring .env uses baked image (no custom entrypoint required)"
sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

echo "==> Building baked image with OpenSearch Sink jars"
./scripts/03-build-connect.sh

echo "==> Verify jars inside image"
JAR_COUNT="$(podman run --rm --entrypoint bash "${BAKED_TAG}" -lc \
  'shopt -s nullglob; a=(/usr/share/confluent-hub-components/aiven-opensearch-connector/*.jar); echo ${#a[@]}')"
echo "baked jars=${JAR_COUNT}"
if [[ "${JAR_COUNT}" -lt 1 ]]; then
  echo "ERROR: baked image has no plugin jars" >&2
  exit 1
fi

# Prefer compose if it no longer overrides entrypoint; otherwise run directly.
USE_COMPOSE=1
if grep -q 'entrypoint:.*docker-entrypoint' podman-compose.yml 2>/dev/null; then
  echo "==> WARNING: local podman-compose.yml still uses custom entrypoint — starting with podman run"
  USE_COMPOSE=0
fi

if [[ "${USE_COMPOSE}" -eq 1 ]]; then
  COMPOSE=(podman-compose)
  if ! command -v podman-compose >/dev/null 2>&1; then
    COMPOSE=(python3 -m podman_compose)
  fi
  echo "==> Starting Connect via podman-compose (stock entrypoint)"
  "${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d --force-recreate --no-deps kafka-connect
else
  echo "==> Starting Connect via podman run (bypasses broken compose entrypoint)"
  podman network exists streamstack-net || podman network create streamstack-net
  podman run -d \
    --name streamstack-kafka-connect \
    --hostname kafka-connect \
    --network streamstack-net \
    --restart unless-stopped \
    -p "${CONNECT_HOST_PORT}:8083" \
    -e CONNECT_BOOTSTRAP_SERVERS=kafka:29092 \
    -e CONNECT_REST_ADVERTISED_HOST_NAME=kafka-connect \
    -e CONNECT_REST_PORT=8083 \
    -e CONNECT_GROUP_ID="${CONNECT_GROUP_ID}" \
    -e CONNECT_CONFIG_STORAGE_TOPIC="${CONNECT_CONFIG_STORAGE_TOPIC}" \
    -e CONNECT_OFFSET_STORAGE_TOPIC="${CONNECT_OFFSET_STORAGE_TOPIC}" \
    -e CONNECT_STATUS_STORAGE_TOPIC="${CONNECT_STATUS_STORAGE_TOPIC}" \
    -e CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR=1 \
    -e CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR=1 \
    -e CONNECT_STATUS_STORAGE_REPLICATION_FACTOR=1 \
    -e CONNECT_KEY_CONVERTER=org.apache.kafka.connect.json.JsonConverter \
    -e CONNECT_VALUE_CONVERTER=org.apache.kafka.connect.json.JsonConverter \
    -e CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE=false \
    -e CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE=false \
    -e CONNECT_PLUGIN_PATH=/usr/share/java,/usr/share/confluent-hub-components \
    "${BAKED_TAG}"
fi

echo "==> Waiting for REST ${CONNECT_URL}"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    echo "Connect REST is up"
    break
  fi
  if ! podman ps --filter name=streamstack-kafka-connect --filter status=running --format '{{.Names}}' | grep -q .; then
    echo "ERROR: container not running" >&2
    podman logs streamstack-kafka-connect --tail 80 >&2 || true
    exit 1
  fi
  sleep 3
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: REST not ready" >&2
    podman logs streamstack-kafka-connect --tail 80 >&2 || true
    exit 1
  fi
done

echo "==> Confirm plugin ${EXPECTED}"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED}" 'map(.class)|index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: plugin loaded"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  attempt ${i}/40: waiting for plugin"
  sleep 3
done

echo "ERROR: plugin still missing" >&2
podman exec streamstack-kafka-connect bash -lc 'ls /usr/share/confluent-hub-components/aiven-opensearch-connector | head' >&2 || true
podman logs streamstack-kafka-connect --tail 100 >&2 || true
exit 1
