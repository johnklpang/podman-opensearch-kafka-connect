#!/usr/bin/env bash
# Compatibility wrapper
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/FIX-DASHBOARDS-NOW.sh"
