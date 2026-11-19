#!/usr/bin/env bash
# Install H2O Enterprise h2oGPTe on OpenShift for the knowledge management quickstart.
# Usage: ./scripts/install.sh   (run from the repository root or use an absolute path)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUICKSTART_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${QUICKSTART_DIR}/.env"

# Variables that must be set in .env. Their default values are in .env.example.
REQUIRED_VARS=(
  H2O_REGISTRY
  H2O_REGISTRY_USERNAME
  H2O_REGISTRY_TOKEN
  H2OGPTE_LICENSE
  H2O_CHART_VERSION
  NAMESPACE
  KEYCLOAK_ADMIN_PASSWORD
  H2OGPTE_ADMIN_PASSWORD
)

# Names of the secrets that the script creates in the namespace.
TLS_SECRET_NAME="h2oai-tls"
PULL_SECRET_NAME="h2oai-registry"
LICENSE_SECRET_NAME="h2oai-h2ogpte-license"
KEYCLOAK_ADMIN_SECRET_NAME="h2oai-keycloak-admin-user"

# Helm values: deploy/helm/values.<chart version>.yaml.tmp is the template, deploy/helm/values.yaml is generated.
YAML_DIR="${QUICKSTART_DIR}/deploy/helm"
VALUES_FILE="${YAML_DIR}/values.yaml"

# Helm release name. The chart's secret names (h2oai-*) depend on it.
RELEASE_NAME="h2oai"

# Step 9: the h2oGPTe admin user that the script creates in the Keycloak "hac" realm,
# and where kcadm.sh is in the Keycloak pod of the H2O AI Cloud chart.
H2OGPTE_ADMIN_USERNAME="test"
KEYCLOAK_POD="h2oai-keycloak-0"
KCADM="/opt/iamguarded/keycloak/bin/kcadm.sh"

# Step 8: how long to wait for the pods, and how often to check.
# The first installation downloads large images (up to about 54 GB on the GPU node).
# If the wait times out, run the script again: it continues where it stopped.
POD_WAIT_TIMEOUT_SECONDS=1800
POD_WAIT_INTERVAL_SECONDS=20

# Temporary files (certificate, license, registry credentials) go here and are
# deleted when the script exits, also after an error.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. Run: cp .env.example .env, then edit .env."
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a

  local var missing=()
  for var in "${REQUIRED_VARS[@]}"; do
    [[ -n "${!var:-}" ]] || missing+=("${var}")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing values in ${ENV_FILE}: ${missing[*]}. See .env.example."
  fi
}

# Create or update a secret with one key.
# The value is written to a temporary file so that it doesn't appear in the process list,
# and server-side apply keeps it out of the last-applied-configuration annotation.
apply_secret() {
  local name="$1" type="$2" key="$3" value="$4" file
  file="${TMP_DIR}/${name}"
  printf '%s' "${value}" > "${file}"
  oc create secret generic "${name}" -n "${NAMESPACE}" --type="${type}" \
    --from-file="${key}=${file}" \
    --dry-run=client -o yaml \
    | oc apply --server-side --force-conflicts -f -
}

# Step 0: check the tools and show which cluster the script will change.
check_cluster() {
  log "Step 0: cluster context"
  local tool
  for tool in oc helm; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed or not in PATH."
  done
  oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster. Run: oc login <API URL>"

  echo "API server: $(oc whoami --show-server)"
  echo "User:       $(oc whoami)"
  echo "Context:    $(oc config current-context)"
}

# Step 1: create the namespace.
create_namespace() {
  log "Step 1: namespace ${NAMESPACE}"
  if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} already exists."
  else
    oc create namespace "${NAMESPACE}"
  fi
}

# Step 2: copy the cluster's default ingress certificate into the namespace,
# so the h2oGPTe routes use the same certificate as *.apps.<cluster-domain>.
copy_tls_secret() {
  log "Step 2: TLS secret ${TLS_SECRET_NAME}"
  local src
  src="$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}')"
  if [[ -z "${src}" ]]; then
    # No custom certificate on the cluster: use the router's own certificate.
    src="router-certs-default"
  fi
  echo "Source: secret ${src} in namespace openshift-ingress"

  oc extract "secret/${src}" -n openshift-ingress --keys=tls.crt,tls.key --to="${TMP_DIR}" >/dev/null
  # Server-side apply: no last-applied-configuration annotation with the key in it.
  oc create secret tls "${TLS_SECRET_NAME}" -n "${NAMESPACE}" \
    --cert="${TMP_DIR}/tls.crt" --key="${TMP_DIR}/tls.key" --dry-run=client -o yaml \
    | oc apply --server-side --force-conflicts -f -
}

# Step 3: create the image pull secret for the H2O registry.
create_pull_secret() {
  log "Step 3: image pull secret ${PULL_SECRET_NAME}"
  # Registry host from H2O_REGISTRY, for example docker.io/h2oairelease -> docker.io.
  local server="${H2O_REGISTRY%%/*}"
  if [[ "${server}" == "docker.io" ]]; then
    server="https://index.docker.io/v1/"
  fi
  echo "Registry: ${server}"

  local auth
  auth="$(printf '%s:%s' "${H2O_REGISTRY_USERNAME}" "${H2O_REGISTRY_TOKEN}" | base64 | tr -d '\n')"
  apply_secret "${PULL_SECRET_NAME}" kubernetes.io/dockerconfigjson .dockerconfigjson \
    "{\"auths\":{\"${server}\":{\"auth\":\"${auth}\"}}}"
}

# Step 4: create the h2oGPTe license secret.
create_license_secret() {
  log "Step 4: license secret ${LICENSE_SECRET_NAME}"
  apply_secret "${LICENSE_SECRET_NAME}" Opaque license.sig "${H2OGPTE_LICENSE}"
}

# Step 5: create the Keycloak administrator password secret.
create_keycloak_admin_secret() {
  log "Step 5: Keycloak admin secret ${KEYCLOAK_ADMIN_SECRET_NAME}"
  apply_secret "${KEYCLOAK_ADMIN_SECRET_NAME}" Opaque password "${KEYCLOAK_ADMIN_PASSWORD}"
}

# Step 6: generate deploy/helm/values.yaml from the template for H2O_CHART_VERSION.
generate_values() {
  log "Step 6: Helm values for chart ${H2O_CHART_VERSION}"
  local template="${YAML_DIR}/values.${H2O_CHART_VERSION}.yaml.tmp"
  if [[ ! -f "${template}" ]]; then
    die "No values template for chart ${H2O_CHART_VERSION}: ${template} not found. Available: $(find "${YAML_DIR}" -maxdepth 1 -name 'values.*.yaml.tmp' -exec basename {} \; | tr '\n' ' ')"
  fi

  local cloud_host
  cloud_host="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
  [[ -n "${cloud_host}" ]] || die "Could not read the cluster's application domain."
  echo "Template:      ${template#"${QUICKSTART_DIR}/"}"
  echo "cloudHost:     ${cloud_host}"
  echo "imageRegistry: ${H2O_REGISTRY}"

  # Placeholders in the template: __CLOUD_HOST__, __IMAGE_REGISTRY__.
  sed -e "s|__CLOUD_HOST__|${cloud_host}|g" \
      -e "s|__IMAGE_REGISTRY__|${H2O_REGISTRY}|g" \
      "${template}" > "${VALUES_FILE}"
  if grep -n -E '__[A-Z0-9_]+__' "${VALUES_FILE}"; then
    die "Unreplaced placeholders in ${VALUES_FILE} (lines above)."
  fi
  echo "Generated ${VALUES_FILE#"${QUICKSTART_DIR}/"}"
}

# Step 7: install or upgrade h2oGPTe with the H2O AI Cloud Helm chart.
install_chart() {
  local chart="oci://${H2O_REGISTRY}/h2oai-chart"
  log "Step 7: helm upgrade --install ${RELEASE_NAME} ${chart} --version ${H2O_CHART_VERSION}"

  # Log in to the registry with a temporary Helm registry config, so that the
  # credentials are not saved in your Helm configuration.
  local registry_config="${TMP_DIR}/registry.json"
  printf '%s' "${H2O_REGISTRY_TOKEN}" | helm registry login "${H2O_REGISTRY%%/*}" \
    --registry-config "${registry_config}" \
    --username "${H2O_REGISTRY_USERNAME}" --password-stdin

  helm upgrade --install "${RELEASE_NAME}" "${chart}" \
    --registry-config "${registry_config}" \
    --version "${H2O_CHART_VERSION}" \
    --namespace "${NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --timeout 30m
}

# Step 8: wait until every pod is Running (and ready) or Completed.
wait_for_pods() {
  log "Step 8: wait for the pods in ${NAMESPACE} (timeout $((POD_WAIT_TIMEOUT_SECONDS / 60)) minutes)"
  local start elapsed pods total not_ready previous=""
  start=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start ))
    # Columns: NAME READY STATUS RESTARTS AGE.
    pods="$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true)"
    total=$(grep -c . <<< "${pods}" || true)
    not_ready="$(awk '{split($2, r, "/"); if (!($3 == "Completed" || ($3 == "Running" && r[1] == r[2]))) print "  " $1 "  " $2 "  " $3}' <<< "${pods}")"

    printf '[%02d:%02d] pods ready: %d/%d\n' $((elapsed / 60)) $((elapsed % 60)) \
      $(( total - $(grep -c . <<< "${not_ready}" || true) )) "${total}"

    if (( total > 0 )) && [[ -z "${not_ready}" ]]; then
      echo "All pods are Running or Completed."
      return 0
    fi

    # List the pods that aren't ready, only when the list changes.
    if [[ -n "${not_ready}" && "${not_ready}" != "${previous}" ]]; then
      printf 'Not ready yet:\n%s\n' "${not_ready}"
      previous="${not_ready}"
    fi

    if (( elapsed >= POD_WAIT_TIMEOUT_SECONDS )); then
      die "Timed out. Images may still be downloading: run the script again to keep waiting. Check a pod with: oc describe pod <name> -n ${NAMESPACE}"
    fi
    sleep "${POD_WAIT_INTERVAL_SECONDS}"
  done
}

# Step 9: create the h2oGPTe admin user in Keycloak, with the realm roles admin and full_access.
# kcadm.sh runs inside the Keycloak pod. The commands are sent through stdin, so the
# passwords don't appear in any command line.
create_admin_user() {
  log "Step 9: h2oGPTe admin user ${H2OGPTE_ADMIN_USERNAME} in Keycloak realm hac"
  local user="${H2OGPTE_ADMIN_USERNAME}"
  oc exec -i -n "${NAMESPACE}" "${KEYCLOAK_POD}" -c keycloak -- bash -s <<EOF 2>&1 \
    | grep -v -E 'Picked up (JDK_JAVA|JAVA_TOOL)_OPTIONS'
set -euo pipefail
KCADM=${KCADM}
CFG=\$(mktemp)
trap 'rm -f "\$CFG"' EXIT
kc() { "\$KCADM" "\$@" --config "\$CFG"; }

kc config credentials --server http://localhost:8080/auth --realm master \
  --user "\$KC_BOOTSTRAP_ADMIN_USERNAME" --password $(printf '%q' "${KEYCLOAK_ADMIN_PASSWORD}")

if [ -z "\$(kc get users -r hac -q username=${user} -q exact=true --fields id --format csv --noquotes)" ]; then
  kc create users -r hac -s username=${user} -s enabled=true \
    -s email=${user}@example.com -s emailVerified=true -s firstName=Test -s lastName=User
  echo "Created user ${user}."
else
  echo "User ${user} already exists."
fi
kc set-password -r hac --username ${user} --new-password $(printf '%q' "${H2OGPTE_ADMIN_PASSWORD}")
echo "Password set."
kc add-roles -r hac --uusername ${user} --rolename admin --rolename full_access
echo "Realm roles admin and full_access assigned."
EOF
}

# Step 10: print the URLs and usernames. Passwords are in .env and aren't printed.
print_summary() {
  log "Step 10: done"
  local hosts h2ogpte_host auth_host keycloak_admin
  hosts="$(oc get ingress -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}')"
  h2ogpte_host="$(grep -m1 '^h2ogpte\.' <<< "${hosts}" || true)"
  auth_host="$(grep -m1 '^auth\.' <<< "${hosts}" || true)"
  keycloak_admin="$(oc exec -n "${NAMESPACE}" "${KEYCLOAK_POD}" -c keycloak -- printenv KC_BOOTSTRAP_ADMIN_USERNAME)"

  cat <<EOF
h2oGPTe
  URL:      https://${h2ogpte_host}
  Username: ${H2OGPTE_ADMIN_USERNAME}
  Password: H2OGPTE_ADMIN_PASSWORD in .env

Keycloak administration console
  URL:      https://${auth_host}/auth/admin/
  Username: ${keycloak_admin}
  Password: KEYCLOAK_ADMIN_PASSWORD in .env

Next: connect a model and load the sample documents (see README.md).
EOF
}

main() {
  load_env
  check_cluster
  create_namespace
  copy_tls_secret
  create_pull_secret
  create_license_secret
  create_keycloak_admin_secret
  generate_values
  install_chart
  wait_for_pods
  create_admin_user
  print_summary
}

main "$@"
