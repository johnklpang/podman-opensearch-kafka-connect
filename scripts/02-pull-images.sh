#!/usr/bin/env bash
# Pull base images defined in .env
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

images=(
  "${ZOOKEEPER_IMAGE}"
  "${KAFKA_IMAGE}"
  "${OPENSEARCH_IMAGE}"
  "${DASHBOARDS_IMAGE}"
  "${KAFKA_UI_IMAGE}"
  "docker.io/confluentinc/cp-kafka-connect:7.6.1"
)

echo "==> Pulling base images"
for img in "${images[@]}"; do
  echo "---- ${img}"
  podman pull "${img}"
done

echo
echo "Pull complete. Next: ./scripts/03-build-connect.sh"
