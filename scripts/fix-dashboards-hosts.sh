#!/usr/bin/env bash
# Compatibility wrapper — canonical fix is FIX-DASHBOARDS-NOW.sh
# (pins OpenSearch IP; hostname "opensearch" can resolve to 127.0.0.1).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT_DIR}/scripts/FIX-DASHBOARDS-NOW.sh"
