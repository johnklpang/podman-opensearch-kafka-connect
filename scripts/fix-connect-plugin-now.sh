#!/usr/bin/env bash
# One-shot recovery: fetch plugin jars, recreate Connect, verify plugin, register connector.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

COMPOSE=(podman-compose)
if ! command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(python3 -m podman_compose)
fi

CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
EXPECTED="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"

echo "==> Ensuring stock Connect image in .env (recommended)"
if grep -q '^CONNECT_IMAGE=localhost/kafka-connect-opensearch' .env 2>/dev/null; then
  sed -i 's|^CONNECT_IMAGE=.*|CONNECT_IMAGE=docker.io/confluentinc/cp-kafka-connect:7.6.1|' .env
  # reload
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/lib/load-env.sh"
fi
echo "CONNECT_IMAGE=${CONNECT_IMAGE}"

echo "==> Fetch plugin jars onto host"
./scripts/03-fetch-opensearch-plugin.sh

HOST_PLUGIN_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"
JAR_COUNT="$(find "${HOST_PLUGIN_DIR}" -maxdepth 1 -name '*.jar' | wc -l | tr -d ' ')"
if [[ "${JAR_COUNT}" -lt 1 ]]; then
  echo "ERROR: no jars in ${HOST_PLUGIN_DIR}" >&2
  exit 1
fi

echo "==> Pull Connect image if needed"
podman pull "${CONNECT_IMAGE}"

echo "==> Force-recreate kafka-connect with plugin staging mount + entrypoint"
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d --force-recreate --no-deps kafka-connect

echo "==> Waiting for Connect REST"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    echo "Connect is up"
    break
  fi
  sleep 3
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: Connect did not become ready" >&2
    podman logs streamstack-kafka-connect --tail 100 >&2 || true
    exit 1
  fi
done

echo "==> Init / staging log lines"
podman logs streamstack-kafka-connect 2>&1 | grep -E 'streamstack-connect-init|OpenSearch' | tail -n 30 || true

echo "==> Waiting for plugin ${EXPECTED}"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
    | jq -e --arg c "${EXPECTED}" 'map(.class) | index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: plugin is visible"
    curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    echo
    echo "==> Registering connector"
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  attempt ${i}/40: not listed yet"
  sleep 3
done

echo "ERROR: plugin still not visible after recreate" >&2
./scripts/diagnose-connect-plugin.sh >&2 || true
exit 1
