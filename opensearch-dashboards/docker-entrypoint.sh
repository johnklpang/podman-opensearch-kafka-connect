#!/usr/bin/env bash
# Force OpenSearch Dashboards onto a reachable OpenSearch URL.
# Prefer OPENSEARCH_URL (may be http://IP:9200) to avoid broken DNS aliases.
set -euo pipefail

# If DNS maps "opensearch" -> 127.0.0.1 (seen on this host), use explicit URL/IP.
OPENSEARCH_URL="${OPENSEARCH_URL:-http://opensearch:9200}"

export DISABLE_SECURITY_DASHBOARDS_PLUGIN="${DISABLE_SECURITY_DASHBOARDS_PLUGIN:-true}"
export OPENSEARCH_HOSTS="[\"${OPENSEARCH_URL}\"]"
export SERVER_HOST="${SERVER_HOST:-0.0.0.0}"

CFG_DIR="/usr/share/opensearch-dashboards/config"
CFG="${CFG_DIR}/opensearch_dashboards.yml"

if [[ -d "${CFG_DIR}" ]] && [[ -w "${CFG_DIR}" || -w "${CFG}" || ! -e "${CFG}" ]]; then
  cat >"${CFG}" <<EOF
server.host: "0.0.0.0"
server.port: 5601
opensearch.hosts: ["${OPENSEARCH_URL}"]
opensearch.ssl.verificationMode: none
logging.dest: stdout
logging.silent: false
EOF
fi

echo "[streamstack-osd] OPENSEARCH_URL=${OPENSEARCH_URL}"
echo "[streamstack-osd] getent opensearch -> $(getent hosts opensearch 2>/dev/null || echo 'no DNS')"
echo "[streamstack-osd] starting CLI --opensearch.hosts=${OPENSEARCH_URL}"

cd /usr/share/opensearch-dashboards
exec ./bin/opensearch-dashboards \
  --server.host=0.0.0.0 \
  --server.port=5601 \
  --opensearch.hosts="${OPENSEARCH_URL}" \
  --opensearch.ssl.verificationMode=none
