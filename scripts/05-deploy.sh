#!/usr/bin/env bash
# Bring up the full stack with podman-compose
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

COMPOSE=(podman-compose)
if ! command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(python3 -m podman_compose)
fi

echo "==> Creating user-defined network if missing"
podman network exists streamstack-net || podman network create streamstack-net

echo "==> Starting stack"
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d

echo "==> Waiting for health (Kafka Connect REST on :${CONNECT_HOST_PORT})"
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${CONNECT_HOST_PORT}/" >/dev/null 2>&1; then
    echo "Kafka Connect is responding."
    break
  fi
  sleep 5
  if [[ "${i}" -eq 60 ]]; then
    echo "Timed out waiting for Kafka Connect. Check: podman logs streamstack-kafka-connect"
    exit 1
  fi
done

echo
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml ps
echo
echo "Stack is up. Register connector: ./scripts/06-register-connector.sh"
echo "UIs:"
echo "  Kafka UI:              http://127.0.0.1:${KAFKA_UI_HOST_PORT}"
echo "  OpenSearch Dashboards: http://127.0.0.1:${DASHBOARDS_HOST_PORT}"
echo "  OpenSearch API:        http://127.0.0.1:${OPENSEARCH_HOST_PORT}"
echo "  Kafka Connect REST:    http://127.0.0.1:${CONNECT_HOST_PORT}"
