#!/usr/bin/env bash
# Download + flatten Aiven OpenSearch Sink connector jars onto the host.
# Mounted into Kafka Connect at runtime (see podman-compose.yml).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CONNECTOR_VERSION="${OPENSEARCH_CONNECTOR_VERSION:-4.1.0}"
PLUGIN_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"
TMP_ZIP="$(mktemp /tmp/opensearch-connector.XXXXXX.zip)"
TMP_DIR="$(mktemp -d /tmp/opensearch-connector.XXXXXX)"

cleanup() {
  rm -f "${TMP_ZIP}"
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "==> Fetching Aiven OpenSearch connector v${CONNECTOR_VERSION}"
curl -fsSL \
  "https://github.com/Aiven-Open/opensearch-connector-for-apache-kafka/releases/download/v${CONNECTOR_VERSION}/opensearch-connector-for-apache-kafka-${CONNECTOR_VERSION}.zip" \
  -o "${TMP_ZIP}"

echo "==> Extracting and flattening jars into ${PLUGIN_DIR}"
rm -rf "${PLUGIN_DIR}"
mkdir -p "${PLUGIN_DIR}"
unzip -q "${TMP_ZIP}" -d "${TMP_DIR}"
find "${TMP_DIR}" -type f -name '*.jar' -exec cp -a {} "${PLUGIN_DIR}/" \;

JAR_COUNT="$(find "${PLUGIN_DIR}" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')"
echo "Installed ${JAR_COUNT} jars"

FOUND=0
for j in "${PLUGIN_DIR}"/*.jar; do
  if unzip -l "${j}" 2>/dev/null | grep -q 'io/aiven/kafka/connect/opensearch/OpenSearchSinkConnector.class'; then
    echo "OK: OpenSearchSinkConnector found in $(basename "${j}")"
    FOUND=1
    break
  fi
done

if [[ "${FOUND}" -ne 1 ]]; then
  echo "ERROR: OpenSearchSinkConnector class not found in downloaded jars" >&2
  exit 1
fi

echo
echo "Plugin ready at: ${PLUGIN_DIR}"
echo "Next: recreate Connect so the mount is applied:"
echo "  podman-compose --env-file .env -f podman-compose.yml up -d kafka-connect"
echo "Then: ./scripts/06-register-connector.sh"
