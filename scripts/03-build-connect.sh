#!/usr/bin/env bash
# Optional: bake OpenSearch Sink plugin into a local Connect image.
# Preferred runtime path is host plugin mount via 03-fetch-opensearch-plugin.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

TAG="${CONNECT_IMAGE_BAKED:-localhost/kafka-connect-opensearch:7.6.1}"

echo "==> Also fetching host-mounted plugin copy"
"${ROOT_DIR}/scripts/03-fetch-opensearch-plugin.sh"

echo "==> Building baked image ${TAG}"
podman build \
  --layers \
  -t "${TAG}" \
  -f "${ROOT_DIR}/kafka-connect/Containerfile" \
  "${ROOT_DIR}/kafka-connect"

echo "==> Verifying OpenSearch connector SPI class inside image"
podman run --rm --entrypoint bash "${TAG}" -lc '
  set -euo pipefail
  PLUGIN_DIR=/usr/share/confluent-hub-components/aiven-opensearch-connector
  ls -la "${PLUGIN_DIR}" | head
  FOUND=0
  for j in "${PLUGIN_DIR}"/*.jar; do
    if unzip -l "${j}" 2>/dev/null | grep -q "io/aiven/kafka/connect/opensearch/OpenSearchSinkConnector.class"; then
      echo "OK: found OpenSearchSinkConnector in ${j}"
      FOUND=1
      break
    fi
  done
  test "${FOUND}" -eq 1
'

echo
echo "Baked image ready: ${TAG}"
echo "To use it, set CONNECT_IMAGE=${TAG} in .env"
echo "Otherwise keep stock CONNECT_IMAGE and rely on the host plugin mount."
echo "Recreate Connect: podman-compose --env-file .env -f podman-compose.yml up -d kafka-connect"
