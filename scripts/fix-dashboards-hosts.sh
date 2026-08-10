#!/usr/bin/env bash
# Fix Dashboards connecting to 127.0.0.1:9200 instead of opensearch:9200
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

COMPOSE=(podman-compose)
if ! command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(python3 -m podman_compose)
fi

echo "==> Recreating OpenSearch Dashboards with OPENSEARCH_HOSTS=[\"http://opensearch:9200\"]"
podman rm -f streamstack-opensearch-dashboards 2>/dev/null || true

# Prefer compose (now hardcodes the hosts). Fallback to podman run.
if grep -q "http://opensearch:9200" podman-compose.yml; then
  "${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d --force-recreate --no-deps opensearch-dashboards
else
  podman run -d \
    --name streamstack-opensearch-dashboards \
    --hostname opensearch-dashboards \
    --network streamstack-net \
    --restart unless-stopped \
    -p "${DASHBOARDS_HOST_PORT}:5601" \
    -e 'OPENSEARCH_HOSTS=["http://opensearch:9200"]' \
    -e DISABLE_SECURITY_DASHBOARDS_PLUGIN=true \
    -e SERVER_HOST=0.0.0.0 \
    "${DASHBOARDS_IMAGE}"
fi

echo "==> Waiting for Dashboards"
for i in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:${DASHBOARDS_HOST_PORT}/api/status" >/dev/null 2>&1; then
    echo "Dashboards API is up"
    break
  fi
  sleep 3
done

echo "==> Effective OPENSEARCH_HOSTS inside container"
podman exec streamstack-opensearch-dashboards bash -lc 'echo OPENSEARCH_HOSTS=$OPENSEARCH_HOSTS' 2>/dev/null \
  || podman exec streamstack-opensearch-dashboards printenv OPENSEARCH_HOSTS 2>/dev/null \
  || true

echo "==> Recent Dashboards connection logs (should NOT show 127.0.0.1:9200)"
podman logs streamstack-opensearch-dashboards --tail 20 2>&1 | grep -E 'opensearch|ECONNREFUSED|9200' || echo "(no connection errors in last lines)"

echo
echo "Open: http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
