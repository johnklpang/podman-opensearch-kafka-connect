#!/usr/bin/env bash
# Optional legacy helper. Prefer baked image + stock /etc/confluent/docker/run.
# Do NOT use `find` — it is not present in cp-kafka-connect images.
set -euo pipefail

DEST="/usr/share/confluent-hub-components/aiven-opensearch-connector"
STAGING="${CONNECT_PLUGIN_STAGING:-/plugin-staging}"

echo "[streamstack-connect-init] staging=${STAGING} dest=${DEST}"
mkdir -p "${DEST}"

shopt -s nullglob
staged=("${STAGING}"/*.jar)
if ((${#staged[@]} > 0)); then
  cp -a "${STAGING}/." "${DEST}/"
  dest_jars=("${DEST}"/*.jar)
  echo "[streamstack-connect-init] installed ${#dest_jars[@]} jars into ${DEST}"
else
  echo "[streamstack-connect-init] WARNING: no *.jar in ${STAGING}" >&2
  ls -la "${STAGING}" >&2 || true
fi

export CONNECT_PLUGIN_PATH="${CONNECT_PLUGIN_PATH:-/usr/share/java,/usr/share/confluent-hub-components}"
echo "[streamstack-connect-init] CONNECT_PLUGIN_PATH=${CONNECT_PLUGIN_PATH}"
ls -la "${DEST}" | head -n 20 || true

exec /etc/confluent/docker/run
