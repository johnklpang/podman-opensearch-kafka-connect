#!/usr/bin/env bash
# Ensure Kafka Connect is built, running, and exposing REST + OpenSearch plugin.
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
BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"

echo "==> Current Connect container state"
podman ps -a --filter name=streamstack-kafka-connect --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true

if [[ "${CONNECT_IMAGE}" != "${BAKED_TAG}" ]]; then
  echo "==> Setting CONNECT_IMAGE=${BAKED_TAG} in .env (plugin must be baked in)"
  sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/lib/load-env.sh"
fi

if ! podman image exists "${CONNECT_IMAGE}" 2>/dev/null; then
  echo "==> Image ${CONNECT_IMAGE} not found — building"
  ./scripts/03-build-connect.sh
else
  echo "==> Image present: ${CONNECT_IMAGE}"
  # Quick jar sanity check inside image
  JAR_COUNT="$(podman run --rm --entrypoint bash "${CONNECT_IMAGE}" -lc \
    'ls /usr/share/confluent-hub-components/aiven-opensearch-connector/*.jar 2>/dev/null | wc -l' | tr -d ' ')"
  echo "    baked jars in image: ${JAR_COUNT}"
  if [[ "${JAR_COUNT}" -lt 1 ]]; then
    echo "==> Image missing plugin jars — rebuilding"
    ./scripts/03-build-connect.sh
  fi
fi

echo "==> Recreating kafka-connect"
podman rm -f streamstack-kafka-connect 2>/dev/null || true
"${COMPOSE[@]}" --env-file .env -f podman-compose.yml up -d --force-recreate --no-deps kafka-connect

echo "==> Waiting for container to stay up"
sleep 3
if ! podman ps --filter name=streamstack-kafka-connect --filter status=running --format '{{.Names}}' | grep -q streamstack-kafka-connect; then
  echo "ERROR: streamstack-kafka-connect is not running" >&2
  podman ps -a --filter name=streamstack-kafka-connect >&2 || true
  echo "---- logs ----" >&2
  podman logs streamstack-kafka-connect --tail 200 >&2 || true
  exit 1
fi

echo "==> Waiting for Connect REST on ${CONNECT_URL}"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    echo "Connect REST is up"
    break
  fi
  # Bail early if container died
  if ! podman ps --filter name=streamstack-kafka-connect --filter status=running --format '{{.Names}}' | grep -q streamstack-kafka-connect; then
    echo "ERROR: Connect container exited while waiting for REST" >&2
    podman logs streamstack-kafka-connect --tail 200 >&2 || true
    exit 1
  fi
  sleep 3
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: Connect REST not ready after waiting" >&2
    podman logs streamstack-kafka-connect --tail 200 >&2 || true
    exit 1
  fi
done

echo "==> Waiting for plugin ${EXPECTED}"
for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED}" 'map(.class) | index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: OpenSearch Sink plugin is loaded"
    curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq --arg c "${EXPECTED}" 'map(select(.class==$c))'
    echo
    echo "Next: ./scripts/06-register-connector.sh"
    exit 0
  fi
  echo "  attempt ${i}/40: plugin not listed yet"
  sleep 3
done

echo "ERROR: Connect is up but plugin not listed" >&2
podman exec streamstack-kafka-connect bash -lc \
  'ls -la /usr/share/confluent-hub-components/aiven-opensearch-connector | head' >&2 || true
podman logs streamstack-kafka-connect --tail 200 >&2 || true
exit 1
