#!/usr/bin/env bash
# Create sample topic and deploy OpenSearch Sink connector via REST API
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
CONNECTOR_JSON="${ROOT_DIR}/configs/connectors/opensearch-sink.json"
CONNECTOR_NAME="$(jq -r '.name' "${CONNECTOR_JSON}")"
EXPECTED_CLASS="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install with: dnf -y install jq" >&2
  exit 1
fi

echo "==> Connect REST: ${CONNECT_URL}"
if ! curl -fsS "${CONNECT_URL}/" >/dev/null; then
  echo "ERROR: Kafka Connect REST is not reachable at ${CONNECT_URL}" >&2
  echo "Connect is probably not running. Check:" >&2
  echo "  podman ps -a --filter name=streamstack-kafka-connect" >&2
  echo "  podman logs streamstack-kafka-connect --tail 100" >&2
  echo "Start/rebuild with:" >&2
  echo "  ./scripts/start-connect.sh" >&2
  echo "  # or: ./scripts/recover-connect-baked.sh" >&2
  exit 1
fi

echo "==> Waiting for OpenSearch Sink plugin discovery (${EXPECTED_CLASS})"
# Fail fast if jars are missing in the running container
if podman inspect streamstack-kafka-connect >/dev/null 2>&1; then
  JAR_NOW="$(podman exec streamstack-kafka-connect bash -lc \
    'shopt -s nullglob; a=(/usr/share/confluent-hub-components/aiven-opensearch-connector/*.jar); echo ${#a[@]}' 2>/dev/null || echo 0)"
  IMG="$(podman inspect streamstack-kafka-connect --format '{{.Config.Image}}' 2>/dev/null || true)"
  echo "    running image: ${IMG}"
  echo "    plugin jars in container: ${JAR_NOW}"
  if [[ "${JAR_NOW}" -lt 1 ]]; then
    echo "ERROR: OpenSearch plugin jars are not in the running Connect container." >&2
    echo "Do NOT keep retrying this script. Bake and recreate first:" >&2
    echo "  ./scripts/install-opensearch-plugin-now.sh" >&2
    exit 1
  fi
fi

for i in $(seq 1 40); do
  PLUGINS_JSON="$(curl -fsS "${CONNECT_URL}/connector-plugins" || true)"
  if [[ -z "${PLUGINS_JSON}" ]]; then
    echo "  attempt ${i}/40: Connect REST not ready"
    sleep 3
    continue
  fi

  if echo "${PLUGINS_JSON}" | jq -e --arg c "${EXPECTED_CLASS}" '
      map(.class) | index($c)
    ' >/dev/null 2>&1; then
    echo "OpenSearch Sink plugin is available."
    break
  fi

  # Also accept any *opensearch* sink class (diagnostic fallback)
  if echo "${PLUGINS_JSON}" | jq -e '
      map(.class) | map(select(test("(?i)opensearch"))) | length > 0
    ' >/dev/null 2>&1; then
    echo "OpenSearch-related plugin found (non-exact class match):"
    echo "${PLUGINS_JSON}" | jq 'map(select(.class|test("(?i)opensearch")))'
    break
  fi

  echo "  attempt ${i}/40: plugin not listed yet"
  if [[ "${i}" -eq 40 ]]; then
    echo "ERROR: OpenSearch connector plugin not found after waiting." >&2
    echo "Plugins currently known:" >&2
    echo "${PLUGINS_JSON}" | jq . >&2 || echo "${PLUGINS_JSON}" >&2
    echo >&2
    echo "Jars were present but class not loaded — run:" >&2
    echo "  ./scripts/install-opensearch-plugin-now.sh" >&2
    exit 1
  fi
  sleep 3
done

echo "==> Ensuring sample topic '${SAMPLE_TOPIC}' exists"
podman exec streamstack-kafka kafka-topics \
  --bootstrap-server "kafka:${KAFKA_INTERNAL_PORT}" \
  --create --if-not-exists \
  --topic "${SAMPLE_TOPIC}" \
  --partitions 3 \
  --replication-factor 1

OS_URL="http://127.0.0.1:${OPENSEARCH_HOST_PORT}"
TEMPLATE_FILE="${ROOT_DIR}/configs/opensearch/index-template-app-events.json"
if [[ -f "${TEMPLATE_FILE}" ]]; then
  echo "==> Applying OpenSearch index template for '${OPENSEARCH_INDEX}*'"
  curl -fsS -X PUT "${OS_URL}/_index_template/app-events-template" \
    -H "Content-Type: application/json" \
    --data-binary @"${TEMPLATE_FILE}" | jq .
fi

echo "==> Creating / updating connector '${CONNECTOR_NAME}'"
if curl -fsS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}" >/dev/null 2>&1; then
  echo "Connector exists — applying config update"
  jq '.config' "${CONNECTOR_JSON}" | curl -fsS -X PUT \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config" | jq .
else
  curl -fsS -X POST \
    -H "Content-Type: application/json" \
    --data-binary @"${CONNECTOR_JSON}" \
    "${CONNECT_URL}/connectors" | jq .
fi

echo "==> Connector status"
curl -fsS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | jq .

echo
echo "Next: ./scripts/produce-sample-data.sh && ./scripts/07-verify.sh"
