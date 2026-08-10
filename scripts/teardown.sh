#!/usr/bin/env bash
# Stop and optionally remove volumes
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COMPOSE=(podman-compose)
if ! command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(python3 -m podman_compose)
fi

REMOVE_VOLUMES="${1:-}"

echo "==> Stopping stack"
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml down

if [[ "${REMOVE_VOLUMES}" == "--volumes" ]]; then
  echo "==> Removing named volumes"
  podman volume rm -f \
    streamstack-zookeeper-data \
    streamstack-zookeeper-log \
    streamstack-kafka-data \
    streamstack-opensearch-data \
    streamstack-connect-data 2>/dev/null || true
fi

echo "Teardown complete."
