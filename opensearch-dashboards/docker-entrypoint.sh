#!/usr/bin/env bash
# Force OpenSearch Dashboards onto a reachable OpenSearch URL.
# Prefer OPENSEARCH_URL (may be http://IP:9200) to avoid broken DNS aliases.
#
# Also honor DISABLE_SECURITY_DASHBOARDS_PLUGIN (official image does this in its
# entrypoint — we replaced that entrypoint, so we must do it here too).
set -euo pipefail

OPENSEARCH_DASHBOARDS_HOME="${OPENSEARCH_DASHBOARDS_HOME:-/usr/share/opensearch-dashboards}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://opensearch:9200}"

export DISABLE_SECURITY_DASHBOARDS_PLUGIN="${DISABLE_SECURITY_DASHBOARDS_PLUGIN:-true}"
export OPENSEARCH_HOSTS="[\"${OPENSEARCH_URL}\"]"
export SERVER_HOST="${SERVER_HOST:-0.0.0.0}"

CFG_DIR="${OPENSEARCH_DASHBOARDS_HOME}/config"
CFG="${CFG_DIR}/opensearch_dashboards.yml"
PLUGIN_DIR="${OPENSEARCH_DASHBOARDS_HOME}/plugins/securityDashboards"

disable_security_dashboards_plugin() {
  if [[ "${DISABLE_SECURITY_DASHBOARDS_PLUGIN}" != "true" ]]; then
    return 0
  fi
  if [[ ! -d "${PLUGIN_DIR}" ]]; then
    echo "[streamstack-osd] securityDashboards plugin already absent"
    return 0
  fi
  echo "[streamstack-osd] Disabling OpenSearch Security Dashboards Plugin"
  # Prefer the official CLI; fall back to rm if the writable layer blocks the CLI.
  if [[ -x "${OPENSEARCH_DASHBOARDS_HOME}/bin/opensearch-dashboards-plugin" ]]; then
    (
      cd "${OPENSEARCH_DASHBOARDS_HOME}"
      ./bin/opensearch-dashboards-plugin remove securityDashboards
    ) || rm -rf "${PLUGIN_DIR}"
  else
    rm -rf "${PLUGIN_DIR}"
  fi
}

disable_security_dashboards_plugin

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
echo "[streamstack-osd] DISABLE_SECURITY_DASHBOARDS_PLUGIN=${DISABLE_SECURITY_DASHBOARDS_PLUGIN}"
echo "[streamstack-osd] getent opensearch -> $(getent hosts opensearch 2>/dev/null || echo 'no DNS')"
echo "[streamstack-osd] starting CLI --opensearch.hosts=${OPENSEARCH_URL}"

cd "${OPENSEARCH_DASHBOARDS_HOME}"
exec ./bin/opensearch-dashboards \
  --server.host=0.0.0.0 \
  --server.port=5601 \
  --opensearch.hosts="${OPENSEARCH_URL}" \
  --opensearch.ssl.verificationMode=none
