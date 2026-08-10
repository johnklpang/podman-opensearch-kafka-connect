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

echo "==> Building baked Connect image with OpenSearch plugin"
./scripts/03-build-connect.sh

echo "==> Pointing .env CONNECT_IMAGE at ${BAKED_TAG}"
sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"
echo "CONNECT_IMAGE=${CONNECT_IMAGE}"

echo "==> Stopping old Connect container"
podman rm -f streamstack-kafka-connect 2>/dev/null || true

echo "==> Starting Connect from baked image"
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d --force-recreate --no-deps kafka-connect

echo "==> Waiting for Connect REST"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    echo "Connect REST is up"
    break
  fi
  sleep 3
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: Connect REST not ready" >&2
    podman logs streamstack-kafka-connect --tail 120 >&2 || true
    exit 1
  fi
done

echo "==> Jar count inside running container"
JAR_IN_CTR="$(podman exec streamstack-kafka-connect bash -lc \
  'ls /usr/share/confluent-hub-components/aiven-opensearch-connector/*.jar 2>/dev/null | wc -l' | tr -d ' ')"
echo "jars=${JAR_IN_CTR}"
if [[ "${JAR_IN_CTR}" -lt 1 ]]; then
  echo "ERROR: baked image has no plugin jars in running container" >&2
  podman image inspect "${BAKED_TAG}" --format '{{.Id}} {{.Created}}' >&2 || true
  exit 1
fi

echo "==> Waiting for plugin class ${EXPECTED}"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED}" 'map(.class) | index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: plugin visible"
    curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  attempt ${i}/40: not listed yet"
  sleep 3
done

echo "ERROR: jars are present but plugin class not listed — likely plugin load failure" >&2
podman logs streamstack-kafka-connect --tail 300 2>&1 \
  | grep -Ei 'opensearch|aiven|Failed to load|Error|Exception|plugin' | tail -n 100 >&2 || true
exit 1
