#!/usr/bin/env bash
# Nuclear recovery: bake plugin into image (no bind-mounts), recreate Connect, register.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

COMPOSE=(podman-compose)
if ! command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(python3 -m podman_compose)
fi

BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"
CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
EXPECTED="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"

# Build + start + verify plugin, then register
./scripts/start-connect.sh
./scripts/06-register-connector.sh
