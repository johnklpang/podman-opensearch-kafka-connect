#!/usr/bin/env bash
# Prerequisites for RHEL 8.10: Podman, podman-compose, sysctl, firewalld, SELinux helpers
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (or via sudo): sudo $0"
  exit 1
fi

echo "==> Enabling required repositories and updating metadata"
dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm || true
dnf -y makecache

echo "==> Installing Podman, compose tooling, and utilities"
dnf -y install \
  podman \
  podman-plugins \
  containernetworking-plugins \
  slirp4netns \
  fuse-overlayfs \
  aardvark-dns \
  netavark \
  python3 \
  python3-pip \
  curl \
  jq \
  nc \
  firewalld \
  policycoreutils-python-utils \
  setools-console \
  container-selinux

# podman-compose: prefer packaged; otherwise pip (user or root)
if ! command -v podman-compose >/dev/null 2>&1; then
  if dnf -y install podman-compose 2>/dev/null; then
    echo "Installed podman-compose from dnf"
  else
    echo "Installing podman-compose via pip"
    python3 -m pip install --upgrade pip
    python3 -m pip install "podman-compose>=1.0.6"
  fi
fi

echo "==> Enabling linger for rootless systemd user services (optional but recommended)"
if [[ -n "${SUDO_USER:-}" ]]; then
  loginctl enable-linger "${SUDO_USER}" || true
  # Ensure subuid/subgid for rootless
  if ! grep -q "^${SUDO_USER}:" /etc/subuid 2>/dev/null; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${SUDO_USER}"
  fi
fi

echo "==> OpenSearch requires vm.max_map_count >= 262144"
SYSCTL_FILE=/etc/sysctl.d/99-streamstack-opensearch.conf
cat >"${SYSCTL_FILE}" <<'EOF'
vm.max_map_count=262144
fs.file-max=65536
EOF
sysctl --system >/dev/null
sysctl vm.max_map_count

echo "==> Ensure firewalld is running"
systemctl enable --now firewalld

echo "==> Versions"
podman --version
podman-compose --version || python3 -m podman_compose --version
python3 --version

echo
echo "Prerequisites complete."
echo "Next: ./scripts/02-pull-images.sh (as the runtime user)"
