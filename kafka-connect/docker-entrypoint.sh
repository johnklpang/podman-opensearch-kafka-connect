#!/usr/bin/env bash
# Ensure OpenSearch Sink plugin jars are present under Confluent's default
# plugin path, then hand off to the stock Connect entrypoint.
set -euo pipefail

DEST="/usr/share/confluent-hub-components/aiven-opensearch-connector"
STAGING="${CONNECT_PLUGIN_STAGING:-/plugin-staging}"

echo "[streamstack-connect-init] staging=${STAGING} dest=${DEST}"

mkdir -p "${DEST}"

if compgen -G "${STAGING}/*.jar" >/dev/null 2>&1; then
  # Copy (not symlink) so Connect's plugin scanner always sees real jars
  cp -a "${STAGING}/." "${DEST}/"
  JAR_COUNT="$(find "${DEST}" -maxdepth 1 -type f -name '*.jar' | wc -l | tr -d ' ')"
  echo "[streamstack-connect-init] installed ${JAR_COUNT} jars into ${DEST}"
else
  echo "[streamstack-connect-init] WARNING: no *.jar found in ${STAGING}" >&2
  echo "[streamstack-connect-init] host must run: ./scripts/03-fetch-opensearch-plugin.sh" >&2
  ls -la "${STAGING}" >&2 || true
fi

# Keep default Confluent plugin locations; include dest parent explicitly.
export CONNECT_PLUGIN_PATH="${CONNECT_PLUGIN_PATH:-/usr/share/java,/usr/share/confluent-hub-components}"
case ",${CONNECT_PLUGIN_PATH}," in
  *",/usr/share/confluent-hub-components,"*) ;;
  *) CONNECT_PLUGIN_PATH="${CONNECT_PLUGIN_PATH},/usr/share/confluent-hub-components" ;;
esac
export CONNECT_PLUGIN_PATH

echo "[streamstack-connect-init] CONNECT_PLUGIN_PATH=${CONNECT_PLUGIN_PATH}"
ls -la "${DEST}" | head -n 20 || true

exec /etc/confluent/docker/run
