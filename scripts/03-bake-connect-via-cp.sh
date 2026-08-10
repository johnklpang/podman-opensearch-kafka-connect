#!/usr/bin/env bash
# Bake OpenSearch Sink jars into a Connect image using podman cp + commit.
# Critical: fix ownership (appuser must read jars) and restore Confluent ENTRYPOINT.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

BASE_IMAGE="${CONNECT_BASE_IMAGE:-docker.io/confluentinc/cp-kafka-connect:7.6.1}"
BAKED_TAG="${CONNECT_IMAGE_BAKED:-localhost/kafka-connect-opensearch:7.6.1}"
PLUGIN_HOST_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"
PLUGIN_CTR_DIR="/usr/share/confluent-hub-components/aiven-opensearch-connector"
TMP_NAME="connect-bake-tmp-$$"

echo "==> Fetch plugin jars onto host"
"${ROOT_DIR}/scripts/03-fetch-opensearch-plugin.sh"

HOST_JARS=("${PLUGIN_HOST_DIR}"/*.jar)
if [[ ! -e "${HOST_JARS[0]:-}" ]]; then
  echo "ERROR: no jars in ${PLUGIN_HOST_DIR}" >&2
  exit 1
fi
echo "host jars: ${#HOST_JARS[@]}"

echo "==> Pull base image ${BASE_IMAGE}"
podman pull "${BASE_IMAGE}"

echo "==> Create temp container and copy jars in"
podman rm -f "${TMP_NAME}" 2>/dev/null || true
podman run -d --name "${TMP_NAME}" --user 0 --entrypoint bash "${BASE_IMAGE}" -lc 'sleep infinity' >/dev/null

podman exec -u 0 "${TMP_NAME}" bash -lc "mkdir -p '${PLUGIN_CTR_DIR}' && rm -rf '${PLUGIN_CTR_DIR}'/"* || \
  podman exec -u 0 "${TMP_NAME}" bash -lc "mkdir -p '${PLUGIN_CTR_DIR}'"

podman cp "${PLUGIN_HOST_DIR}/." "${TMP_NAME}:${PLUGIN_CTR_DIR}/"

# Connect runs as appuser — root-owned 0600 jars from podman cp are invisible to the plugin scanner
echo "==> Fix ownership/permissions for appuser"
podman exec -u 0 "${TMP_NAME}" bash -lc "
  set -e
  # appuser may be uid 1000 on Confluent images
  if id appuser >/dev/null 2>&1; then
    chown -R appuser:appuser '${PLUGIN_CTR_DIR}'
  else
    chown -R 1000:1000 '${PLUGIN_CTR_DIR}' || true
  fi
  chmod -R a+rX '${PLUGIN_CTR_DIR}'
  ls -la '${PLUGIN_CTR_DIR}' | head
"

CTR_COUNT="$(podman exec "${TMP_NAME}" bash -lc "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jars inside temp container: ${CTR_COUNT}"
if [[ "${CTR_COUNT}" -lt 1 ]]; then
  echo "ERROR: podman cp did not place jars in container" >&2
  podman rm -f "${TMP_NAME}" >/dev/null || true
  exit 1
fi

podman exec "${TMP_NAME}" bash -lc "
  ls ${PLUGIN_CTR_DIR}/opensearch-connector-for-apache-kafka-*.jar >/dev/null
  echo 'OK: connector jar present'
"

echo "==> Commit as ${BAKED_TAG} with stock Confluent ENTRYPOINT"
podman stop "${TMP_NAME}" >/dev/null
podman commit \
  --change 'ENTRYPOINT ["/etc/confluent/docker/run"]' \
  --change 'CMD []' \
  --change 'ENV CONNECT_PLUGIN_PATH=/usr/share/java,/usr/share/confluent-hub-components' \
  --change 'USER root' \
  "${TMP_NAME}" "${BAKED_TAG}"
podman rm -f "${TMP_NAME}" >/dev/null

echo "==> Verify committed image jars + entrypoint"
VERIFY_COUNT="$(podman run --rm --user 0 --entrypoint bash "${BAKED_TAG}" -lc \
  "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jars in ${BAKED_TAG}: ${VERIFY_COUNT}"
test "${VERIFY_COUNT}" -ge 1
podman image inspect "${BAKED_TAG}" --format 'Entrypoint={{json .Config.Entrypoint}} User={{.Config.User}}'

echo
echo "Baked image ready: ${BAKED_TAG}"
