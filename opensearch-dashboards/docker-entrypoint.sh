#!/usr/bin/env bash
# Force OpenSearch Dashboards to use the Podman service name.
# Bypasses docker-entrypoint / env / yml defaults that keep selecting 127.0.0.1:9200.
set -euo pipefail

export DISABLE_SECURITY_DASHBOARDS_PLUGIN="${DISABLE_SECURITY_DASHBOARDS_PLUGIN:-true}"
export OPENSEARCH_HOSTS='["http://opensearch:9200"]'
export SERVER_HOST="${SERVER_HOST:-0.0.0.0}"

CFG_DIR="/usr/share/opensearch-dashboards/config"
CFG="${CFG_DIR}/opensearch_dashboards.yml"

# Rewrite config when the filesystem allows it (covers entrypoint template races)
if [[ -d "${CFG_DIR}" ]] && [[ -w "${CFG_DIR}" || -w "${CFG}" || ! -e "${CFG}" ]]; then
  cat >"${CFG}" <<'EOF'
server.host: "0.0.0.0"
server.port: 5601
opensearch.hosts: ["http://opensearch:9200"]
opensearch.ssl.verificationMode: none
logging.dest: stdout
logging.silent: false
EOF
fi

echo "[streamstack-osd] OPENSEARCH_HOSTS=${OPENSEARCH_HOSTS}"
echo "[streamstack-osd] starting with CLI --opensearch.hosts=http://opensearch:9200"

cd /usr/share/opensearch-dashboards

# CLI flags override config defaults — this is the reliable fix
exec ./bin/opensearch-dashboards \
  --server.host=0.0.0.0 \
  --server.port=5601 \
  --opensearch.hosts=http://opensearch:9200 \
  --opensearch.ssl.verificationMode=none
