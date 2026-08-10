#!/usr/bin/env bash
# Bake OpenSearch Sink jars into a Connect image using podman cp + commit.
# Does not depend on Containerfile COPY / build-context quirks.
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
podman create --name "${TMP_NAME}" --entrypoint sleep "${BASE_IMAGE}" infinity >/dev/null
podman start "${TMP_NAME}" >/dev/null

podman exec "${TMP_NAME}" bash -lc "mkdir -p '${PLUGIN_CTR_DIR}' && rm -rf '${PLUGIN_CTR_DIR}'/*"
podman cp "${PLUGIN_HOST_DIR}/." "${TMP_NAME}:${PLUGIN_CTR_DIR}/"

CTR_COUNT="$(podman exec "${TMP_NAME}" bash -lc "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jars inside temp container: ${CTR_COUNT}"
if [[ "${CTR_COUNT}" -lt 1 ]]; then
  echo "ERROR: podman cp did not place jars in container" >&2
  podman rm -f "${TMP_NAME}" >/dev/null || true
  exit 1
fi

# Ensure SPI class exists
podman exec "${TMP_NAME}" bash -lc "
  set -e
  FOUND=0
  for j in ${PLUGIN_CTR_DIR}/*.jar; do
    if unzip -l \"\$j\" 2>/dev/null | grep -q 'OpenSearchSinkConnector.class'; then
      echo OK: \$j
      FOUND=1
      break
    fi
  done
  # unzip may be missing — fall back to jar filename check
  if [[ \$FOUND -eq 0 ]]; then
    ls ${PLUGIN_CTR_DIR}/opensearch-connector-for-apache-kafka-*.jar >/dev/null
    echo 'OK: connector jar present (unzip unavailable for class check)'
  fi
"

echo "==> Commit temp container as ${BAKED_TAG}"
podman stop "${TMP_NAME}" >/dev/null
podman commit \
  --change 'ENV CONNECT_PLUGIN_PATH=/usr/share/java,/usr/share/confluent-hub-components' \
  --change 'USER appuser' \
  "${TMP_NAME}" "${BAKED_TAG}"
podman rm -f "${TMP_NAME}" >/dev/null

echo "==> Verify committed image"
VERIFY_COUNT="$(podman run --rm --entrypoint bash "${BAKED_TAG}" -lc \
  "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jars in ${BAKED_TAG}: ${VERIFY_COUNT}"
test "${VERIFY_COUNT}" -ge 1

echo
echo "Baked image ready: ${BAKED_TAG}"
