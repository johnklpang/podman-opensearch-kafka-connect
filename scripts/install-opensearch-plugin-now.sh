#!/usr/bin/env bash
# End-to-end: diagnose why OpenSearch plugin is missing, bake via podman cp,
# recreate Connect on the baked image, verify plugin, register connector.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"
CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
EXPECTED="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"
PLUGIN_CTR_DIR="/usr/share/confluent-hub-components/aiven-opensearch-connector"

echo "======== DIAGNOSE ========"
echo "Running container image:"
podman ps -a --filter name=streamstack-kafka-connect \
  --format 'name={{.Names}} image={{.Image}} status={{.Status}}' || true

if podman inspect streamstack-kafka-connect >/dev/null 2>&1; then
  echo "Config.Image=$(podman inspect streamstack-kafka-connect --format '{{.Config.Image}}')"
  echo "CONNECT_PLUGIN_PATH in container:"
  podman exec streamstack-kafka-connect bash -lc 'echo "$CONNECT_PLUGIN_PATH"' 2>/dev/null || true
  echo "Jar count in running container:"
  podman exec streamstack-kafka-connect bash -lc \
    "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}; ls -la ${PLUGIN_CTR_DIR} 2>/dev/null | head" \
    2>/dev/null || echo "(exec failed — container not ready)"
fi

echo "Current /connector-plugins (opensearch filter):"
curl -sS "${CONNECT_URL}/connector-plugins" 2>/dev/null \
  | jq 'map(.class)|map(select(test("(?i)opensearch")))' 2>/dev/null || echo "[] (REST not reachable)"

echo
echo "======== BAKE IMAGE (podman cp + commit) ========"
./scripts/03-bake-connect-via-cp.sh

echo "==> Point .env at baked image"
sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"
echo "CONNECT_IMAGE=${CONNECT_IMAGE}"

echo
echo "======== RECREATE CONNECT (stock entrypoint, no docker-entrypoint.sh) ========"
podman rm -f streamstack-kafka-connect 2>/dev/null || true

# Always use podman run to avoid stale compose entrypoint overrides on the host.
podman network exists streamstack-net || podman network create streamstack-net

podman run -d \
  --name streamstack-kafka-connect \
  --hostname kafka-connect \
  --network streamstack-net \
  --restart unless-stopped \
  -p "${CONNECT_HOST_PORT}:8083" \
  -e CONNECT_BOOTSTRAP_SERVERS=kafka:"${KAFKA_INTERNAL_PORT}" \
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
  -e CONNECT_LOG4J_ROOT_LOGLEVEL=INFO \
  "${BAKED_TAG}"

echo "==> Waiting for REST"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    echo "REST up"
    break
  fi
  if ! podman ps --filter name=streamstack-kafka-connect --filter status=running --format '{{.Names}}' | grep -q .; then
    echo "ERROR: container exited" >&2
    podman logs streamstack-kafka-connect --tail 100 >&2
    exit 1
  fi
  sleep 3
  [[ "${i}" -eq 60 ]] && { echo "REST timeout" >&2; podman logs streamstack-kafka-connect --tail 100 >&2; exit 1; }
done

echo "==> Jar count after recreate"
podman exec streamstack-kafka-connect bash -lc \
  "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}; ls ${PLUGIN_CTR_DIR} | head"

echo "==> Waiting for ${EXPECTED}"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED}" 'map(.class)|index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: plugin visible"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  attempt ${i}/40"
  sleep 3
done

echo "ERROR: jars may be present but plugin not registered — dump logs" >&2
podman logs streamstack-kafka-connect --tail 200 2>&1 \
  | grep -Ei 'plugin|opensearch|aiven|Failed|Invalid|Exception' | tail -n 80 >&2 || true
exit 1
