#!/usr/bin/env bash
# Fetch OpenSearch Sink jars and bake them into a local Connect image.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

TAG="${CONNECT_IMAGE_BAKED:-localhost/kafka-connect-opensearch:7.6.1}"
PLUGIN_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"

echo "==> Fetching plugin jars into build context"
"${ROOT_DIR}/scripts/03-fetch-opensearch-plugin.sh"

JAR_COUNT="$(find "${PLUGIN_DIR}" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')"
echo "Build-context jars: ${JAR_COUNT}"
test "${JAR_COUNT}" -ge 1

echo "==> Building ${TAG} (COPY jars into image)"
podman build \
  --no-cache \
  -t "${TAG}" \
  -f "${ROOT_DIR}/kafka-connect/Containerfile" \
  "${ROOT_DIR}/kafka-connect"

echo "==> Verifying jars inside image"
podman run --rm --entrypoint bash "${TAG}" -lc '
  set -euo pipefail
  PLUGIN_DIR=/usr/share/confluent-hub-components/aiven-opensearch-connector
  ls -la "${PLUGIN_DIR}" | head
  test "$(find "${PLUGIN_DIR}" -maxdepth 1 -name "*.jar" | wc -l)" -ge 1
  FOUND=0
  for j in "${PLUGIN_DIR}"/*.jar; do
    if unzip -l "${j}" 2>/dev/null | grep -q "OpenSearchSinkConnector.class"; then
      echo "OK: ${j}"
      FOUND=1
      break
    fi
  done
  test "${FOUND}" -eq 1
'

echo
echo "Built ${TAG}"
echo "Set in .env: CONNECT_IMAGE=${TAG}"
echo "Then: ./scripts/recover-connect-baked.sh"
