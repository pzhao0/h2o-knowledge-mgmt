#!/usr/bin/env bash
# Manage only the optional model Helm release; no H2O credentials are needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICKSTART_DIR="$(dirname "${SCRIPT_DIR}")"

case "${1:-}" in
  install|uninstall) action="$1" ;;
  *) echo "Usage: $0 install|uninstall" >&2; exit 1 ;;
esac
[[ $# == 1 ]] || { echo "Expected one action." >&2; exit 1; }
[[ -f "${QUICKSTART_DIR}/.env" ]] || { echo "Missing .env; copy .env.example and set NAMESPACE." >&2; exit 1; }
# shellcheck source=/dev/null
source "${QUICKSTART_DIR}/.env"
: "${NAMESPACE:?Set NAMESPACE in .env}"

if [[ "${action}" == install ]]; then
  helm upgrade --install h2oai-model "${QUICKSTART_DIR}/deploy/helm/model" \
    --namespace "${NAMESPACE}" --create-namespace --timeout 30m
else
  # --ignore-not-found keeps cleanup idempotent while preserving real Helm errors.
  helm uninstall h2oai-model --namespace "${NAMESPACE}" \
    --ignore-not-found --wait --timeout 10m
fi
