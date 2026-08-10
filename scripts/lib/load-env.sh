# shellcheck shell=bash
# Safe loader for repo .env (quoted values, no history expansion on '!').
# Usage: source "${ROOT_DIR}/scripts/lib/load-env.sh"

if [[ -z "${ROOT_DIR:-}" ]]; then
  echo "load-env.sh: ROOT_DIR must be set before sourcing" >&2
  return 1 2>/dev/null || exit 1
fi

set +H
set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a

# Normalize Dashboards hosts if a plain URL was provided in .env
if [[ -n "${OPENSEARCH_HOSTS:-}" && "${OPENSEARCH_HOSTS}" != \[* ]]; then
  OPENSEARCH_HOSTS="[\"${OPENSEARCH_HOSTS}\"]"
fi
