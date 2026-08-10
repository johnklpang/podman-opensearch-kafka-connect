#!/usr/bin/env bash
# Compatibility wrapper — use baked-image recovery (no bind mounts).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/recover-connect-baked.sh"
