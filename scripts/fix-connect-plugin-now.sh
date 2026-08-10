#!/usr/bin/env bash
# Compatibility wrapper → emergency baked-image recovery
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/emergency-fix-connect.sh"
