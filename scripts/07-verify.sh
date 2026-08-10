#!/usr/bin/env bash
# End-to-end verification of data flow and UI endpoints
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"

CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
OS_URL="http://127.0.0.1:${OPENSEARCH_HOST_PORT}"
UI_URL="http://127.0.0.1:${KAFKA_UI_HOST_PORT}"
DB_URL="http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
CONNECTOR_NAME="$(jq -r '.name' "${ROOT_DIR}/configs/connectors/opensearch-sink.json")"

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "[OK]   ${name}"
    pass=$((pass + 1))
  else
    echo "[FAIL] ${name}"
    fail=$((fail + 1))
  fi
}

echo "==> Service endpoints"
check "ZooKeeper port listening" bash -c "ss -lnt | grep -q ':${ZOOKEEPER_HOST_PORT}'"
check "Kafka port listening" bash -c "ss -lnt | grep -q ':${KAFKA_HOST_PORT}'"
check "Connect REST" curl -fsS "${CONNECT_URL}/" >/dev/null
check "OpenSearch cluster" curl -fsS "${OS_URL}/_cluster/health" >/dev/null
check "Kafka UI" curl -fsS -o /dev/null -w '%{http_code}' "${UI_URL}" | grep -Eq '200|302'
check "OpenSearch Dashboards" curl -fsS "${DB_URL}/api/status" >/dev/null

echo
echo "==> Connector"
check "Connector RUNNING" bash -c \
  "curl -fsS '${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status' | jq -e '.connector.state==\"RUNNING\"' >/dev/null"

echo
echo "==> Refresh OpenSearch index and count docs"
curl -fsS -X POST "${OS_URL}/${OPENSEARCH_INDEX}/_refresh" >/dev/null || true
DOC_COUNT="$(curl -fsS "${OS_URL}/${OPENSEARCH_INDEX}/_count" 2>/dev/null | jq -r '.count // 0' || echo 0)"
echo "Indexed documents in '${OPENSEARCH_INDEX}': ${DOC_COUNT}"
if [[ "${DOC_COUNT}" -gt 0 ]]; then
  echo "[OK]   Documents present in OpenSearch"
  pass=$((pass + 1))
  echo
  echo "Sample hit:"
  curl -fsS "${OS_URL}/${OPENSEARCH_INDEX}/_search?size=1&pretty" | jq '.hits.hits[0]._source'
else
  echo "[FAIL] No documents found — produce data with ./scripts/produce-sample-data.sh and retry"
  fail=$((fail + 1))
fi

echo
echo "==> Summary: ${pass} passed, ${fail} failed"
echo "Kafka UI:              ${UI_URL}"
echo "OpenSearch Dashboards: ${DB_URL}"
echo "OpenSearch API:        ${OS_URL}"
echo "Kafka bootstrap (host): ${KAFKA_ADVERTISED_HOST}:${KAFKA_HOST_PORT}"
echo "Connect REST:          ${CONNECT_URL}"

[[ "${fail}" -eq 0 ]]
