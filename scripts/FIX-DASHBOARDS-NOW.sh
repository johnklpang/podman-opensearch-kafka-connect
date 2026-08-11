#!/usr/bin/env bash
# Definitive Dashboards fix: bake image that CLI-forces opensearch:9200 (never 127.0.0.1).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

TAG="localhost/opensearch-dashboards-streamstack:2.14.0"
BASE="docker.io/opensearchproject/opensearch-dashboards:2.14.0"

echo "============================================================"
echo " FIX OpenSearch Dashboards (stop using 127.0.0.1:9200)"
echo "============================================================"

echo "==> 1) OpenSearch must be up"
if ! curl -fsS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health" >/dev/null; then
  echo "ERROR: OpenSearch not reachable at :${OPENSEARCH_HOST_PORT}" >&2
  echo "Run: podman-compose --env-file .env -f podman-compose.yml up -d opensearch" >&2
  exit 1
fi
curl -sS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health?pretty" | head -n 15

echo "==> 2) Build Dashboards image with CLI host override"
podman pull "${BASE}"
podman build --no-cache -t "${TAG}" -f opensearch-dashboards/Containerfile opensearch-dashboards

echo "==> 3) Point .env at fixed image"
if grep -q '^DASHBOARDS_IMAGE=' .env; then
  sed -i "s|^DASHBOARDS_IMAGE=.*|DASHBOARDS_IMAGE=${TAG}|" .env
else
  echo "DASHBOARDS_IMAGE=${TAG}" >> .env
fi

echo "==> 4) Remove ANY old Dashboards containers"
podman rm -f streamstack-opensearch-dashboards 2>/dev/null || true
# also remove anonymous leftovers
podman ps -a --filter ancestor="${BASE}" --format '{{.ID}} {{.Names}}' | while read -r id name; do
  [[ "${name}" == *dashboards* ]] && podman rm -f "${id}" || true
done

echo "==> 5) Ensure network + OpenSearch DNS name"
podman network exists streamstack-net || podman network create streamstack-net
if ! podman inspect streamstack-opensearch --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q streamstack-net; then
  echo "Connecting existing OpenSearch container to streamstack-net"
  podman network connect streamstack-net streamstack-opensearch 2>/dev/null || true
fi

echo "==> 6) Start fixed Dashboards"
podman run -d \
  --name streamstack-opensearch-dashboards \
  --hostname opensearch-dashboards \
  --network streamstack-net \
  --restart unless-stopped \
  -p "${DASHBOARDS_HOST_PORT}:5601" \
  -e DISABLE_SECURITY_DASHBOARDS_PLUGIN=true \
  -e 'OPENSEARCH_HOSTS=["http://opensearch:9200"]' \
  "${TAG}"

echo "==> 7) Wait and verify (must NOT use 127.0.0.1:9200)"
sleep 6
echo "--- process/cmdline ---"
podman exec streamstack-opensearch-dashboards bash -lc 'ps aux | head -n 5' 2>/dev/null || true
echo "--- config grep ---"
podman exec streamstack-opensearch-dashboards \
  grep -E 'opensearch.hosts|server.host' /usr/share/opensearch-dashboards/config/opensearch_dashboards.yml 2>/dev/null || true
echo "--- DNS/TCP to opensearch:9200 ---"
podman exec streamstack-opensearch-dashboards bash -lc \
  'getent hosts opensearch || true; (echo >/dev/tcp/opensearch/9200) >/dev/null 2>&1 && echo TCP_OK || echo TCP_FAIL' \
  2>/dev/null || true

for i in $(seq 1 30); do
  LOGS="$(podman logs streamstack-opensearch-dashboards --tail 40 2>&1 || true)"
  if echo "${LOGS}" | grep -q '127.0.0.1:9200'; then
    echo "attempt ${i}: still seeing 127.0.0.1:9200 in logs..."
    sleep 3
    continue
  fi
  if curl -fsS "http://127.0.0.1:${DASHBOARDS_HOST_PORT}/api/status" >/dev/null 2>&1; then
    echo "SUCCESS: Dashboards API is up and logs are not targeting 127.0.0.1:9200"
    echo "Open: http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
    exit 0
  fi
  echo "attempt ${i}: waiting for API..."
  sleep 3
done

echo "FAILED — recent logs:" >&2
podman logs streamstack-opensearch-dashboards --tail 50 >&2 || true
exit 1
