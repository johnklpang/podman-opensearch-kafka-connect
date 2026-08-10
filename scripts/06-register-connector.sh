#!/usr/bin/env bash
# Create sample topic and deploy OpenSearch Sink connector via REST API
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
CONNECTOR_JSON="${ROOT_DIR}/configs/connectors/opensearch-sink.json"
CONNECTOR_NAME="$(jq -r '.name' "${CONNECTOR_JSON}")"

echo "==> Waiting for Connect REST + plugin discovery"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" | jq -e '
      map(.class) | map(select(test("(?i)opensearch"))) | length > 0
    ' >/dev/null 2>&1; then
    echo "OpenSearch Sink plugin is available."
    break
  fi
  sleep 3
  if [[ "${i}" -eq 40 ]]; then
    echo "OpenSearch connector plugin not found. Plugins currently known:"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq .
    exit 1
  fi
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
