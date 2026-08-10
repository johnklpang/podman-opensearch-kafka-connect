#!/usr/bin/env bash
# Stop waiting on empty plugins — bake with correct perms/entrypoint and recreate Connect.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"
CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
EXPECTED="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"
PLUGIN_CTR_DIR="/usr/share/confluent-hub-components/aiven-opensearch-connector"

echo "======== DIAGNOSE (do NOT run 06-register until plugin appears) ========"
podman ps -a --filter name=streamstack-kafka-connect \
  --format 'name={{.Names}} image={{.Image}} status={{.Status}}' || true

if podman inspect streamstack-kafka-connect >/dev/null 2>&1; then
  echo "Config.Image=$(podman inspect streamstack-kafka-connect --format '{{.Config.Image}}')"
  echo "Entrypoint=$(podman inspect streamstack-kafka-connect --format '{{json .Config.Entrypoint}}')"
  podman exec streamstack-kafka-connect bash -lc \
    "echo CONNECT_PLUGIN_PATH=\$CONNECT_PLUGIN_PATH; echo 'jar listing:'; ls -la ${PLUGIN_CTR_DIR} 2>&1 | head" \
    2>/dev/null || echo "(cannot exec into container)"
fi

echo "opensearch plugins now:"
curl -sS "${CONNECT_URL}/connector-plugins" 2>/dev/null \
  | jq 'map(.class)|map(select(test("(?i)opensearch")))' 2>/dev/null || echo '[]'

echo
echo "======== BAKE (cp + chown appuser + restore ENTRYPOINT) ========"
./scripts/03-bake-connect-via-cp.sh
sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env

echo
echo "======== RECREATE CONNECT ========"
podman rm -f streamstack-kafka-connect 2>/dev/null || true
podman network exists streamstack-net || podman network create streamstack-net

# Explicit stock entrypoint — never use docker-entrypoint.sh
podman run -d \
  --name streamstack-kafka-connect \
  --hostname kafka-connect \
  --network streamstack-net \
  --restart unless-stopped \
  --entrypoint /etc/confluent/docker/run \
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
    podman logs streamstack-kafka-connect --tail 120 >&2
    exit 1
  fi
  sleep 3
  if [[ "${i}" -eq 60 ]]; then
    echo "REST timeout" >&2
    podman logs streamstack-kafka-connect --tail 120 >&2
    exit 1
  fi
done

echo "==> Running container must be baked image + have jars"
echo "Config.Image=$(podman inspect streamstack-kafka-connect --format '{{.Config.Image}}')"
JAR_NOW="$(podman exec streamstack-kafka-connect bash -lc \
  "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jar count in running container: ${JAR_NOW}"
if [[ "${JAR_NOW}" -lt 1 ]]; then
  echo "ERROR: recreated container still has 0 jars — wrong image was started" >&2
  exit 1
fi

echo "==> Waiting for ${EXPECTED}"
for i in $(seq 1 30); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED}" 'map(.class)|index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: plugin visible"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  attempt ${i}/30"
  sleep 3
done

echo "ERROR: jars present (${JAR_NOW}) but class not listed — plugin load failure" >&2
podman logs streamstack-kafka-connect --tail 250 2>&1 \
  | grep -Ei 'plugin|opensearch|aiven|Failed|Invalid|Exception|Permission|denied' | tail -n 100 >&2 || true
exit 1
