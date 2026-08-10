#!/usr/bin/env bash
# Build Kafka Connect image with OpenSearch Sink plugin
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"

TAG="${CONNECT_IMAGE}"

echo "==> Building ${TAG}"
podman build \
  --layers \
  -t "${TAG}" \
  -f "${ROOT_DIR}/kafka-connect/Containerfile" \
  "${ROOT_DIR}/kafka-connect"

echo "==> Verifying OpenSearch connector classes are present"
podman run --rm "${TAG}" bash -lc '
  set -e
  find /usr/share/confluent-hub-components -maxdepth 3 -type d -iname "*opensearch*" -print
  find /usr/share/confluent-hub-components -name "*opensearch*.jar" 2>/dev/null | head -n 20 || true
'

echo
echo "Build complete. Next (as root once): sudo ./scripts/04-firewall-selinux.sh"
echo "Then: ./scripts/05-deploy.sh"
