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
MODEL_RELEASE_NAME="${MODEL_RELEASE_NAME:-h2oai-model}"
[[ "${MODEL_RELEASE_NAME}" != h2oai ]] || { echo "MODEL_RELEASE_NAME must differ from h2oai." >&2; exit 1; }

if [[ "${action}" == install ]]; then
  helm_args=(upgrade --install "${MODEL_RELEASE_NAME}" "${QUICKSTART_DIR}/deploy/helm/model"
    --namespace "${NAMESPACE}" --create-namespace --timeout 30m)
  if [[ -n "${MODEL_VALUES_FILE:-}" ]]; then
    [[ "${MODEL_VALUES_FILE}" == /* ]] || MODEL_VALUES_FILE="${QUICKSTART_DIR}/${MODEL_VALUES_FILE}"
    [[ -f "${MODEL_VALUES_FILE}" ]] || { echo "Model values file not found: ${MODEL_VALUES_FILE}" >&2; exit 1; }
    helm_args+=(--values "${MODEL_VALUES_FILE}")
  fi
  helm "${helm_args[@]}"
else
  # --ignore-not-found keeps cleanup idempotent while preserving real Helm errors.
  helm uninstall "${MODEL_RELEASE_NAME}" --namespace "${NAMESPACE}" \
    --ignore-not-found --wait --timeout 10m
fi
