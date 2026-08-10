#!/usr/bin/env bash
# firewalld + SELinux adjustments for the custom host ports
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/load-env.sh"

ports=(
  "${ZOOKEEPER_HOST_PORT}/tcp"
  "${KAFKA_HOST_PORT}/tcp"
  "${CONNECT_HOST_PORT}/tcp"
  "${OPENSEARCH_HOST_PORT}/tcp"
  "${OPENSEARCH_TRANSPORT_HOST_PORT}/tcp"
  "${KAFKA_UI_HOST_PORT}/tcp"
  "${DASHBOARDS_HOST_PORT}/tcp"
)

echo "==> Opening custom host ports in firewalld (permanent)"
for p in "${ports[@]}"; do
  firewall-cmd --permanent --add-port="${p}"
done
firewall-cmd --reload
firewall-cmd --list-ports

echo "==> SELinux: container-selinux should already allow labeled volume mounts (:Z)"
getenforce || true
sestatus || true

# If volumes live under a custom path that is not container_file_t, restorecon helps.
# Named volumes managed by Podman under ~/.local/share/containers usually work with :Z.
echo "==> Optional: allow containers to connect to the host network (rootless often needs this)"
setsebool -P container_connect_any 1 || true

echo
echo "Firewall/SELinux step complete. Next: ./scripts/05-deploy.sh (as runtime user)"
