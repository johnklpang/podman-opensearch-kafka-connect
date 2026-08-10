#!/usr/bin/env bash
# Diagnose why OpenSearch Sink plugin is not visible to Kafka Connect.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
HOST_PLUGIN_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"

echo "==> Host plugin dir: ${HOST_PLUGIN_DIR}"
if [[ -d "${HOST_PLUGIN_DIR}" ]]; then
  echo "jar count: $(find "${HOST_PLUGIN_DIR}" -maxdepth 1 -name '*.jar' | wc -l | tr -d ' ')"
  ls -la "${HOST_PLUGIN_DIR}" | head -n 15
else
  echo "MISSING — run ./scripts/03-fetch-opensearch-plugin.sh"
fi

echo
echo "==> Connect container"
podman ps -a --filter name=streamstack-kafka-connect --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo
echo "==> Mounts / plugin paths inside container"
if podman inspect streamstack-kafka-connect >/dev/null 2>&1; then
  podman inspect streamstack-kafka-connect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
  echo "--- env CONNECT_PLUGIN_PATH ---"
  podman exec streamstack-kafka-connect bash -lc 'echo "CONNECT_PLUGIN_PATH=$CONNECT_PLUGIN_PATH"; echo "staging=$CONNECT_PLUGIN_STAGING"; ls -la /plugin-staging 2>/dev/null | head || echo "no /plugin-staging"; ls -la /usr/share/confluent-hub-components/aiven-opensearch-connector 2>/dev/null | head || echo "no dest plugin dir"'
else
  echo "container not found"
fi

echo
echo "==> REST /connector-plugins (opensearch filter)"
if curl -fsS "${CONNECT_URL}/connector-plugins" >/tmp/connect-plugins.json 2>/dev/null; then
  jq 'map(select(.class|test("(?i)opensearch")))' /tmp/connect-plugins.json
  echo "All classes:"
  jq -r '.[].class' /tmp/connect-plugins.json
else
  echo "Connect REST not reachable at ${CONNECT_URL}"
fi

echo
echo "==> Recent Connect logs (plugin / error lines)"
podman logs streamstack-kafka-connect --tail 200 2>&1 \
  | grep -Ei 'plugin|opensearch|aiven|ERROR|Exception|staging|streamstack-connect-init' \
  | tail -n 80 || true

echo
echo "If jars missing on host: ./scripts/03-fetch-opensearch-plugin.sh"
echo "Then force recreate: ./scripts/fix-connect-plugin-now.sh"
