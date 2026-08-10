#!/usr/bin/env bash
# Download + flatten Aiven OpenSearch Sink connector jars onto the host.
# CP 7.6.1 (Java 11) requires Aiven 3.1.1 (OpensearchSinkConnector).
# Aiven 4.x (OpenSearchSinkConnector) needs Java 17+ and will not load.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

CONNECTOR_VERSION="${OPENSEARCH_CONNECTOR_VERSION:-3.1.1}"
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
test "${JAR_COUNT}" -ge 1

# 3.x => OpensearchSinkConnector ; 4.x => OpenSearchSinkConnector
FOUND_CLASS=""
for j in "${PLUGIN_DIR}"/*.jar; do
  listing="$(unzip -l "${j}" 2>/dev/null || true)"
  if echo "${listing}" | grep -q 'io/aiven/kafka/connect/opensearch/OpensearchSinkConnector.class'; then
    FOUND_CLASS="io.aiven.kafka.connect.opensearch.OpensearchSinkConnector"
    echo "OK: OpensearchSinkConnector (3.x / Java 11) in $(basename "${j}")"
    break
  fi
  if echo "${listing}" | grep -q 'io/aiven/kafka/connect/opensearch/OpenSearchSinkConnector.class'; then
    FOUND_CLASS="io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector"
    echo "OK: OpenSearchSinkConnector (4.x / Java 17+) in $(basename "${j}")"
    echo "WARNING: CP 7.6.1 is Java 11 — 4.x will NOT load. Set OPENSEARCH_CONNECTOR_VERSION=3.1.1" >&2
    break
  fi
done

if [[ -z "${FOUND_CLASS}" ]]; then
  echo "ERROR: no Aiven OpenSearch SinkConnector class found in downloaded jars" >&2
  exit 1
fi

echo
echo "Plugin ready at: ${PLUGIN_DIR}"
echo "SPI class: ${FOUND_CLASS}"
echo "Preferred next step on CP 7.6.1: ./scripts/FIX-IT-NOW.sh"
