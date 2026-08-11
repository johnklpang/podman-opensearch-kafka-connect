#!/usr/bin/env bash
# Definitive Dashboards fix for this host:
# "opensearch" DNS was resolving to 127.0.0.1 inside the Dashboards container.
# We pin the real OpenSearch container IP via --add-host and OPENSEARCH_URL.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

TAG="localhost/opensearch-dashboards-streamstack:2.14.0"
BASE="docker.io/opensearchproject/opensearch-dashboards:2.14.0"
NET="streamstack-net"
OS_NAME="streamstack-opensearch"

echo "============================================================"
echo " FIX Dashboards (broken DNS: opensearch -> 127.0.0.1)"
echo "============================================================"

echo "==> 1) OpenSearch must be up on host port ${OPENSEARCH_HOST_PORT}"
if ! curl -fsS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health" >/dev/null; then
  echo "ERROR: OpenSearch not reachable at :${OPENSEARCH_HOST_PORT}" >&2
  exit 1
fi
curl -sS "http://127.0.0.1:${OPENSEARCH_HOST_PORT}/_cluster/health?pretty" | head -n 12

echo "==> 2) Ensure network ${NET} exists"
podman network exists "${NET}" || podman network create "${NET}"

echo "==> 3) Put OpenSearch on ${NET} with alias 'opensearch'"
if ! podman inspect "${OS_NAME}" >/dev/null 2>&1; then
  echo "ERROR: container ${OS_NAME} not found" >&2
  exit 1
fi
# reconnect to refresh aliases
podman network disconnect "${NET}" "${OS_NAME}" 2>/dev/null || true
podman network connect --alias opensearch "${NET}" "${OS_NAME}"

OS_IP="$(podman inspect "${OS_NAME}" --format '{{$net := index .NetworkSettings.Networks "'"${NET}"'"}}{{$net.IPAddress}}' 2>/dev/null || true)"
if [[ -z "${OS_IP}" ]]; then
  # fallback: first IP
  OS_IP="$(podman inspect "${OS_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | awk '{print $1}')"
fi
if [[ -z "${OS_IP}" ]]; then
  echo "ERROR: could not determine OpenSearch IP on ${NET}" >&2
  podman inspect "${OS_NAME}" --format '{{json .NetworkSettings.Networks}}' >&2
  exit 1
fi
echo "OpenSearch IP on ${NET}: ${OS_IP}"
OPENSEARCH_URL="http://${OS_IP}:9200"

echo "==> 4) Build Dashboards image"
podman pull "${BASE}"
podman build --no-cache -t "${TAG}" -f opensearch-dashboards/Containerfile opensearch-dashboards
sed -i "s|^DASHBOARDS_IMAGE=.*|DASHBOARDS_IMAGE=${TAG}|" .env

echo "==> 5) Recreate Dashboards with --add-host opensearch=${OS_IP}"
podman rm -f streamstack-opensearch-dashboards 2>/dev/null || true

podman run -d \
  --name streamstack-opensearch-dashboards \
  --hostname opensearch-dashboards \
  --network "${NET}" \
  --restart unless-stopped \
  --add-host "opensearch:${OS_IP}" \
  -p "${DASHBOARDS_HOST_PORT}:5601" \
  -e DISABLE_SECURITY_DASHBOARDS_PLUGIN=true \
  -e "OPENSEARCH_URL=${OPENSEARCH_URL}" \
  -e "OPENSEARCH_HOSTS=[\"${OPENSEARCH_URL}\"]" \
  "${TAG}"

echo "==> 6) Verify DNS + TCP (must NOT be 127.0.0.1)"
sleep 5
echo "getent hosts opensearch:"
podman exec streamstack-opensearch-dashboards getent hosts opensearch || true
echo "TCP check to ${OS_IP}:9200 and opensearch:9200:"
podman exec streamstack-opensearch-dashboards bash -lc "
  (echo >/dev/tcp/${OS_IP}/9200) >/dev/null 2>&1 && echo IP_TCP_OK || echo IP_TCP_FAIL
  (echo >/dev/tcp/opensearch/9200) >/dev/null 2>&1 && echo NAME_TCP_OK || echo NAME_TCP_FAIL
" || true

echo "==> 7) Wait for anonymous /api/status (must be HTTP 200, not 401)"
for i in $(seq 1 40); do
  # Podman on RHEL wants options BEFORE the container name
  LOGS="$(podman logs --tail 30 streamstack-opensearch-dashboards 2>&1 || true)"
  if echo "${LOGS}" | grep -q 'ECONNREFUSED 127.0.0.1:9200'; then
    # If still 127.0.0.1, DNS override failed — abort early with guidance
    RESOLVED="$(podman exec streamstack-opensearch-dashboards getent hosts opensearch 2>/dev/null || true)"
    if echo "${RESOLVED}" | grep -q '127.0.0.1'; then
      echo "ERROR: opensearch still resolves to 127.0.0.1 inside Dashboards: ${RESOLVED}" >&2
      echo "OPENSEARCH_URL in use should be ${OPENSEARCH_URL}" >&2
      podman logs --tail 20 streamstack-opensearch-dashboards >&2 || true
      exit 1
    fi
  fi

  CODE="$(curl -sS -o /tmp/osd-status.body -w '%{http_code}' \
    "http://127.0.0.1:${DASHBOARDS_HOST_PORT}/api/status" 2>/dev/null || echo 000)"

  if [[ "${CODE}" == "200" ]]; then
    if echo "${LOGS}" | grep -q 'ECONNREFUSED 127.0.0.1:9200'; then
      echo "API up but still logging localhost errors — check OPENSEARCH_URL" >&2
      podman logs --tail 30 streamstack-opensearch-dashboards >&2 || true
      exit 1
    fi
    echo "SUCCESS: Dashboards is up (anonymous /api/status -> 200)"
    echo "Open: http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
    echo "OpenSearch URL used: ${OPENSEARCH_URL}"
    exit 0
  fi

  if [[ "${CODE}" == "401" ]]; then
    echo "  attempt ${i}/40: /api/status -> 401 (securityDashboards still enabled; waiting for rebuilt image)..."
  else
    echo "  attempt ${i}/40: waiting for API (HTTP ${CODE})..."
  fi
  sleep 3
done

echo "FAILED — /api/status never became anonymous 200." >&2
echo "If you still see 401, the custom image did not remove securityDashboards." >&2
podman logs --tail 50 streamstack-opensearch-dashboards >&2 || true
exit 1
