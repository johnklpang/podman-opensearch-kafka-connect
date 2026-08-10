#!/usr/bin/env bash
# Compatibility: always use podman-cp bake + recreate path
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/install-opensearch-plugin-now.sh"
