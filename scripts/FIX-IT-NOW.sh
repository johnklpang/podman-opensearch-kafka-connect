#!/usr/bin/env bash
# ONE command to fix empty OpenSearch plugin list on CP 7.6.1 / Java 11.
# Root cause addressed:
#  - Aiven 4.x often needs Java 17; CP 7.6.1 is Java 11 → jars present, class never loads
#  - Use Aiven 3.1.1 + class OpensearchSinkConnector
#  - plugin.path must include the directory that contains the jars
#  - jars must be readable by appuser; ENTRYPOINT must be Confluent stock
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

BAKED_TAG="localhost/kafka-connect-opensearch:7.6.1"
BASE_IMAGE="docker.io/confluentinc/cp-kafka-connect:7.6.1"
# Java 11–compatible release (do NOT use 4.x on CP 7.6.1)
CONNECTOR_VERSION="${OPENSEARCH_CONNECTOR_VERSION:-3.1.1}"
EXPECTED_CLASS="io.aiven.kafka.connect.opensearch.OpensearchSinkConnector"
PLUGIN_HOST_DIR="${ROOT_DIR}/kafka-connect/plugins/aiven-opensearch-connector"
PLUGIN_CTR_DIR="/usr/share/confluent-hub-components/aiven-opensearch-connector"
CONNECT_URL="http://127.0.0.1:${CONNECT_HOST_PORT}"
TMP_NAME="connect-bake-fix-$$"

echo "============================================================"
echo " FIX Connect OpenSearch plugin (CP 7.6.1 / Java 11)"
echo " Connector: Aiven v${CONNECTOR_VERSION}"
echo " Class:     ${EXPECTED_CLASS}"
echo "============================================================"

# Keep .env / connector JSON in sync with the Java 11–compatible class
sed -i "s|^OPENSEARCH_CONNECTOR_VERSION=.*|OPENSEARCH_CONNECTOR_VERSION=${CONNECTOR_VERSION}|" .env || \
  echo "OPENSEARCH_CONNECTOR_VERSION=${CONNECTOR_VERSION}" >> .env
sed -i "s|^CONNECT_IMAGE=.*|CONNECT_IMAGE=${BAKED_TAG}|" .env
python3 - <<PY
import json
from pathlib import Path
p = Path("configs/connectors/opensearch-sink.json")
data = json.loads(p.read_text())
data["config"]["connector.class"] = "${EXPECTED_CLASS}"
# Ensure plugin path–friendly settings
data["config"]["connection.url"] = "http://opensearch:9200"
p.write_text(json.dumps(data, indent=2) + "\n")
print("updated", p, "->", data["config"]["connector.class"])
PY

echo "==> 1) Download Aiven connector v${CONNECTOR_VERSION}"
rm -rf "${PLUGIN_HOST_DIR}"
mkdir -p "${PLUGIN_HOST_DIR}"
TMP_ZIP="$(mktemp /tmp/os-conn.XXXXXX.zip)"
TMP_DIR="$(mktemp -d /tmp/os-conn.XXXXXX)"
curl -fsSL \
  "https://github.com/Aiven-Open/opensearch-connector-for-apache-kafka/releases/download/v${CONNECTOR_VERSION}/opensearch-connector-for-apache-kafka-${CONNECTOR_VERSION}.zip" \
  -o "${TMP_ZIP}"
unzip -q "${TMP_ZIP}" -d "${TMP_DIR}"
find "${TMP_DIR}" -type f -name '*.jar' -exec cp -a {} "${PLUGIN_HOST_DIR}/" \;
rm -rf "${TMP_ZIP}" "${TMP_DIR}"
HOST_COUNT="$(find "${PLUGIN_HOST_DIR}" -maxdepth 1 -name '*.jar' | wc -l | tr -d ' ')"
echo "host jars: ${HOST_COUNT}"
test "${HOST_COUNT}" -ge 1

# Verify class name inside jar (3.x = OpensearchSinkConnector)
python3 - <<PY
import zipfile, glob, sys
jars = glob.glob("${PLUGIN_HOST_DIR}/*.jar")
want = "io/aiven/kafka/connect/opensearch/OpensearchSinkConnector.class"
alt = "io/aiven/kafka/connect/opensearch/OpenSearchSinkConnector.class"
found = None
for j in jars:
    with zipfile.ZipFile(j) as z:
        names = set(z.namelist())
        if want in names:
            found = ("OpensearchSinkConnector", j)
            break
        if alt in names:
            found = ("OpenSearchSinkConnector", j)
            break
if not found:
    print("ERROR: neither OpensearchSinkConnector nor OpenSearchSinkConnector in jars", file=sys.stderr)
    sys.exit(1)
print(f"SPI class in jar: {found[0]} ({found[1]})")
if found[0] != "OpensearchSinkConnector":
    print("WARNING: jar has OpenSearchSinkConnector (likely 4.x / Java 17). Use 3.1.1 for CP 7.6.1.", file=sys.stderr)
PY

echo "==> 2) Bake image with readable jars + stock ENTRYPOINT"
podman pull "${BASE_IMAGE}"
podman rm -f "${TMP_NAME}" streamstack-kafka-connect 2>/dev/null || true
podman run -d --name "${TMP_NAME}" --user 0 --entrypoint bash "${BASE_IMAGE}" -lc 'sleep infinity' >/dev/null
podman exec -u 0 "${TMP_NAME}" mkdir -p "${PLUGIN_CTR_DIR}"
podman cp "${PLUGIN_HOST_DIR}/." "${TMP_NAME}:${PLUGIN_CTR_DIR}/"
podman exec -u 0 "${TMP_NAME}" bash -lc "
  set -e
  chown -R appuser:appuser '${PLUGIN_CTR_DIR}' 2>/dev/null || chown -R 1000:1000 '${PLUGIN_CTR_DIR}'
  chmod -R a+rX '${PLUGIN_CTR_DIR}'
  echo 'Java in base image:'
  java -version 2>&1 | head -n 1 || true
  ls -la '${PLUGIN_CTR_DIR}' | head
"
podman stop "${TMP_NAME}" >/dev/null
podman commit \
  --change 'ENTRYPOINT ["/etc/confluent/docker/run"]' \
  --change 'CMD []' \
  --change 'USER root' \
  "${TMP_NAME}" "${BAKED_TAG}"
podman rm -f "${TMP_NAME}" >/dev/null

VERIFY="$(podman run --rm --user 0 --entrypoint bash "${BAKED_TAG}" -lc \
  "shopt -s nullglob; a=(${PLUGIN_CTR_DIR}/*.jar); echo \${#a[@]}")"
echo "jars in baked image: ${VERIFY}"
test "${VERIFY}" -ge 1

echo "==> 3) Start Connect with plugin.path pointing AT the jar directory"
podman network exists streamstack-net || podman network create streamstack-net
# Critical: include the connector dir itself in plugin.path (directory-of-jars form)
PLUGIN_PATH="/usr/share/java,${PLUGIN_CTR_DIR},/usr/share/confluent-hub-components"

podman run -d \
  --name streamstack-kafka-connect \
  --hostname kafka-connect \
  --network streamstack-net \
  --restart unless-stopped \
  --entrypoint /etc/confluent/docker/run \
  -p "${CONNECT_HOST_PORT}:8083" \
  -e CONNECT_BOOTSTRAP_SERVERS=kafka:"${KAFKA_INTERNAL_PORT}" \
  -e CONNECT_REST_ADVERTISED_HOST_NAME=kafka-connect \
  -e CONNECT_REST_PORT=8083 \
  -e CONNECT_GROUP_ID="${CONNECT_GROUP_ID}" \
  -e CONNECT_CONFIG_STORAGE_TOPIC="${CONNECT_CONFIG_STORAGE_TOPIC}" \
  -e CONNECT_OFFSET_STORAGE_TOPIC="${CONNECT_OFFSET_STORAGE_TOPIC}" \
  -e CONNECT_STATUS_STORAGE_TOPIC="${CONNECT_STATUS_STORAGE_TOPIC}" \
  -e CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR=1 \
  -e CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR=1 \
  -e CONNECT_STATUS_STORAGE_REPLICATION_FACTOR=1 \
  -e CONNECT_KEY_CONVERTER=org.apache.kafka.connect.json.JsonConverter \
  -e CONNECT_VALUE_CONVERTER=org.apache.kafka.connect.json.JsonConverter \
  -e CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE=false \
  -e CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE=false \
  -e "CONNECT_PLUGIN_PATH=${PLUGIN_PATH}" \
  -e CONNECT_LOG4J_ROOT_LOGLEVEL=INFO \
  -e CONNECT_LOG4J_LOGGERS=org.apache.zookeeper=ERROR,org.I0Itec.zkclient=ERROR,org.reflections=ERROR,org.apache.kafka.connect.runtime.isolation=DEBUG \
  "${BAKED_TAG}"

echo "==> 4) Wait for REST + plugin"
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/" >/dev/null 2>&1; then
    break
  fi
  if ! podman ps --filter name=streamstack-kafka-connect --filter status=running --format '{{.Names}}' | grep -q .; then
    echo "Connect exited:" >&2
    podman logs streamstack-kafka-connect --tail 80 >&2
    exit 1
  fi
  sleep 3
done

for i in $(seq 1 40); do
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e --arg c "${EXPECTED_CLASS}" 'map(.class)|index($c)' >/dev/null 2>&1; then
    echo "SUCCESS: ${EXPECTED_CLASS} is loaded"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq --arg c "${EXPECTED_CLASS}" 'map(select(.class==$c))'
    ./scripts/06-register-connector.sh
    echo
    echo "DONE. Produce data: ./scripts/produce-sample-data.sh 20"
    exit 0
  fi
  # also accept capital-S variant
  if curl -fsS "${CONNECT_URL}/connector-plugins" \
      | jq -e 'map(.class)|map(select(test("(?i)opensearch")))|length>0' >/dev/null 2>&1; then
    echo "SUCCESS: opensearch plugin loaded (check class name below)"
    curl -fsS "${CONNECT_URL}/connector-plugins" | jq 'map(select(.class|test("(?i)opensearch")))'
    # rewrite connector json to match whatever class Connect exposed
    CLASS="$(curl -fsS "${CONNECT_URL}/connector-plugins" | jq -r 'map(select(.class|test("(?i)opensearch")))[0].class')"
    python3 - <<PY
import json
from pathlib import Path
p=Path("configs/connectors/opensearch-sink.json")
d=json.loads(p.read_text()); d["config"]["connector.class"]="${CLASS}"; p.write_text(json.dumps(d, indent=2)+"\n")
print("connector.class set to", "${CLASS}")
PY
    ./scripts/06-register-connector.sh
    exit 0
  fi
  echo "  waiting for plugin ${i}/40"
  sleep 3
done

echo "FAILED. Dumping diagnostics:" >&2
echo "--- image/java ---" >&2
podman exec streamstack-kafka-connect bash -lc 'java -version; echo PLUGIN_PATH=$CONNECT_PLUGIN_PATH; ls -la '"${PLUGIN_CTR_DIR}"' | head' >&2 || true
echo "--- plugin load errors ---" >&2
podman logs streamstack-kafka-connect --tail 300 2>&1 \
  | grep -Ei 'UnsupportedClassVersion|Failed loading|InvalidPlugin|opensearch|aiven|Exception|Error' | tail -n 80 >&2 || true
echo "--- all plugins ---" >&2
curl -sS "${CONNECT_URL}/connector-plugins" | jq . >&2 || true
exit 1
