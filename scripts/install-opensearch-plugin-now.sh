#!/usr/bin/env bash
# Compatibility wrapper → Java 11–compatible fix
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/FIX-IT-NOW.sh"
