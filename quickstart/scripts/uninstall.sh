#!/usr/bin/env bash
# Remove the h2oGPTe installation of the knowledge management quickstart.
# Usage: ./scripts/uninstall.sh   (run from the quickstart folder or anywhere else)
#
# Deletes the Helm release and the namespace from .env, including all documents and data.
# Doesn't remove the cluster operators, or a model that you deployed in OpenShift AI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICKSTART_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${QUICKSTART_DIR}/.env"

# Must match install.sh.
RELEASE_NAME="h2oai"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. It must contain the NAMESPACE that you installed into."
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  [[ -n "${NAMESPACE:-}" ]] || die "Missing value in ${ENV_FILE}: NAMESPACE."
}

# Step 0: check the tools, show the cluster, and ask for confirmation.
confirm() {
  log "Step 0: cluster context"
  local tool answer
  for tool in oc helm; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed or not in PATH."
  done
  oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster. Run: oc login <API URL>"

  echo "API server: $(oc whoami --show-server)"
  echo "User:       $(oc whoami)"
  echo "Context:    $(oc config current-context)"

  if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} doesn't exist. Nothing to remove."
    exit 0
  fi

  echo
  echo "This deletes the Helm release ${RELEASE_NAME} and the namespace ${NAMESPACE},"
  echo "including all documents, collections, and users stored in h2oGPTe."
  read -r -p "Type the namespace name to continue: " answer
  [[ "${answer}" == "${NAMESPACE}" ]] || die "Cancelled."
}

# Step 1: uninstall the Helm release. This also removes its cluster-scoped resources.
uninstall_release() {
  log "Step 1: Helm release ${RELEASE_NAME}"
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 10m
  else
    echo "Release ${RELEASE_NAME} not found in ${NAMESPACE}."
  fi
}

# Step 2: delete the namespace, with the secrets and persistent volume claims in it.
delete_namespace() {
  log "Step 2: namespace ${NAMESPACE}"
  oc delete namespace "${NAMESPACE}" --wait=true --timeout=10m
}

main() {
  load_env
  confirm
  uninstall_release
  delete_namespace
  log "Done"
  echo "If you deployed a model in OpenShift AI, delete it in the OpenShift AI dashboard."
}

main "$@"
