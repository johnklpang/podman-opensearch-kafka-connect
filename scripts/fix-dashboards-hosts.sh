#!/usr/bin/env bash
# Recreate Dashboards so it talks to http://opensearch:9200 (not 127.0.0.1:9200)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CFG="${ROOT_DIR}/configs/opensearch-dashboards/opensearch_dashboards.yml"
if [[ ! -f "${CFG}" ]]; then
  echo "ERROR: missing ${CFG}" >&2
  exit 1
fi

echo "==> Checking OpenSearch is reachable on the host publish port"
if ! curl -fsS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health" >/dev/null; then
  echo "ERROR: OpenSearch not reachable at http://127.0.0.1:${OPENSEARCH_HOST_PORT}" >&2
  echo "Start it first: podman-compose --env-file .env -f podman-compose.yml up -d opensearch" >&2
  exit 1
fi
curl -sS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health?pretty" | head -n 20

echo "==> Removing old Dashboards container"
podman rm -f streamstack-opensearch-dashboards 2>/dev/null || true

echo "==> Ensuring network exists"
podman network exists streamstack-net || podman network create streamstack-net

echo "==> Starting Dashboards with mounted config (opensearch.hosts -> http://opensearch:9200)"
podman run -d \
  --name streamstack-opensearch-dashboards \
  --hostname opensearch-dashboards \
  --network streamstack-net \
  --restart unless-stopped \
  -p "${DASHBOARDS_HOST_PORT}:5601" \
  -e DISABLE_SECURITY_DASHBOARDS_PLUGIN=true \
  -e SERVER_HOST=0.0.0.0 \
  -e 'OPENSEARCH_HOSTS=["http://opensearch:9200"]' \
  -v "${CFG}:/usr/share/opensearch-dashboards/config/opensearch_dashboards.yml:ro,Z" \
  "${DASHBOARDS_IMAGE}"

echo "==> Waiting for Dashboards API"
for i in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:${DASHBOARDS_HOST_PORT}/api/status" >/dev/null 2>&1; then
    echo "Dashboards API OK"
    break
  fi
  sleep 3
  if [[ "${i}" -eq 40 ]]; then
    echo "WARNING: API not ready yet — check logs below" >&2
  fi
done

echo "==> Config inside container"
podman exec streamstack-opensearch-dashboards bash -lc \
  'grep -E "opensearch.hosts|server.host" /usr/share/opensearch-dashboards/config/opensearch_dashboards.yml' \
  || podman exec streamstack-opensearch-dashboards \
       grep -E 'opensearch.hosts|server.host' /usr/share/opensearch-dashboards/config/opensearch_dashboards.yml

echo "==> Can Dashboards resolve/reach OpenSearch on the container network?"
podman exec streamstack-opensearch-dashboards bash -lc \
  'getent hosts opensearch || true; (exec 3<>/dev/tcp/opensearch/9200 && echo TCP_OK || echo TCP_FAIL)' \
  2>/dev/null || true

echo "==> Logs (must NOT show 127.0.0.1:9200)"
sleep 5
podman logs streamstack-opensearch-dashboards --tail 30 2>&1 | grep -E 'ECONNREFUSED|opensearch.hosts|9200|error' || echo "(no 127.0.0.1 connection errors)"

echo
echo "UI: http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
