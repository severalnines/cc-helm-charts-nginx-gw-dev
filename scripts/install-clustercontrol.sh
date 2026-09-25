#!/usr/bin/env bash
#
# Install or upgrade ClusterControl with Gateway API (NGINX Gateway Fabric).
#
# Wraps the steps Helm cannot do itself:
#
#   1. Gateway API CRDs      - cluster-scoped, not shipped by any chart
#   2. NGF vendor CRDs       - Helm never installs a subchart's crds/ on upgrade
#   3. cert-generator RBAC   - upstream NGF tags it `pre-install`, which never
#                              fires when you upgrade an existing release
#   4. helm upgrade --install
#   5. backend CA bundle     - cmon generates its RPC certificate at runtime, so
#                              it cannot be known until the pod is up
#
# Every step is idempotent; re-running is safe and is the intended way to apply
# changes. For routine value changes you do NOT need this script - just:
#
#   helm upgrade clustercontrol ngf-dev/clustercontrol -n clustercontrol \
#     -f my-values.yaml --version <ver>
#
# Usage:
#   ./install-clustercontrol.sh [options]
#
#   -f, --values FILE     values file (repeatable)
#   -n, --namespace NS    default: clustercontrol
#   -r, --release NAME    default: clustercontrol
#       --chart REF       default: ngf-dev/clustercontrol (or a local path)
#       --version VER     chart version (required for prereleases like 0.4.0-ngf.2)
#       --repo-url URL    helm repo to add as the alias in --chart
#       --skip-crds       cluster CRDs already installed by someone else
#       --skip-ca-bundle  you manage cmon-backend-ca yourself
#       --dry-run         render only, change nothing
#   -h, --help

set -euo pipefail

NAMESPACE="clustercontrol"
RELEASE="clustercontrol"
CHART="cc-ngf-dev/clustercontrol"
REPO_ALIAS="cc-ngf-dev"
REPO_URL="https://severalnines.github.io/cc-helm-charts-nginx-gw-dev/"
CHART_VERSION=""
VALUES_ARGS=()
SKIP_CRDS=0
SKIP_CA_BUNDLE=0
DRY_RUN=0
WORKDIR=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR \033[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '\033[0;90mDRY  %s\033[0m\n' "$*"; else "$@"; fi; }

cleanup() { [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"; }
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--values)      VALUES_ARGS+=(-f "$2"); shift 2 ;;
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -r|--release)     RELEASE="$2"; shift 2 ;;
    --chart)          CHART="$2"; shift 2 ;;
    --version)        CHART_VERSION="$2"; shift 2 ;;
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --skip-crds)      SKIP_CRDS=1; shift ;;
    --skip-ca-bundle) SKIP_CA_BUNDLE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight
for bin in helm kubectl openssl; do
  command -v "$bin" >/dev/null || die "$bin not found in PATH"
done
kubectl version -o json >/dev/null 2>&1 || die "cannot reach a Kubernetes cluster"

WORKDIR="$(mktemp -d)"

# ------------------------------------------------------------- fetch chart
# Pulled up front so the NGF version can be read from it - that keeps the
# Gateway API CRD channel and the controller on the same release without
# hardcoding the version in two places.
if [[ -d "${CHART}" ]]; then
  log "Using local chart: ${CHART}"
  CHART_DIR="${CHART}"
  helm dependency build "${CHART_DIR}" >/dev/null
else
  log "Adding helm repo ${REPO_ALIAS} -> ${REPO_URL}"
  helm repo add "${REPO_ALIAS}" "${REPO_URL}" >/dev/null 2>&1 || true
  helm repo update "${REPO_ALIAS}" >/dev/null

  log "Pulling ${CHART} ${CHART_VERSION:-(latest stable)}"
  pull_args=(--untar -d "${WORKDIR}")
  [[ -n "${CHART_VERSION}" ]] && pull_args+=(--version "${CHART_VERSION}")
  helm pull "${CHART}" "${pull_args[@]}" \
    || die "helm pull failed. Prerelease versions need an explicit --version"
  CHART_DIR="${WORKDIR}/$(basename "${CHART}")"
fi

NGF_VERSION="$(awk '/name: nginx-gateway-fabric/{f=1} f && /version:/{print $2; exit}' \
  "${CHART_DIR}/Chart.yaml" | tr -d "'\"")"
[[ -n "${NGF_VERSION}" ]] || die "could not read the nginx-gateway-fabric version from Chart.yaml"
log "Chart declares NGINX Gateway Fabric ${NGF_VERSION}"

# --------------------------------------------------------- 1. Gateway API CRDs
if (( SKIP_CRDS )); then
  log "Skipping CRDs (--skip-crds)"
else
  log "Installing Gateway API CRDs (experimental channel, v${NGF_VERSION})"
  # --server-side is required: the httproutes schema exceeds the 256KiB
  # last-applied-configuration annotation limit that client-side apply uses.
  # Experimental channel is required: TCPRoute (kuber-proxy gRPC) lives only there.
  if (( DRY_RUN )); then
    printf '\033[0;90mDRY  kubectl kustomize .../experimental?ref=v%s | kubectl apply --server-side\033[0m\n' "${NGF_VERSION}"
  else
    kubectl kustomize \
      "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/experimental?ref=v${NGF_VERSION}" \
      | kubectl apply --server-side --force-conflicts -f -
  fi

  # 2. NGF's own CRDs (NginxProxy, NginxGateway, SnippetsFilter). Helm installs a
  #    chart's crds/ only on `helm install`, never on `helm upgrade`, and this is
  #    a subchart - so on any upgrade they would silently never be created.
  log "Installing NGINX Gateway Fabric CRDs"
  run kubectl apply --server-side --force-conflicts \
    -f "${CHART_DIR}/charts/nginx-gateway-fabric/crds/"
fi

# ------------------------------------------------------ 3. cert-generator RBAC
# The upstream NGF chart tags these three objects `helm.sh/hook: pre-install`.
# On an upgrade that hook never fires, so the pre-upgrade cert-generator Job has
# no ServiceAccount, hangs for its full 5 minute timeout, then fails. Creating
# them as plain objects up front makes both paths work.
log "Ensuring NGF cert-generator RBAC exists"
SA_NAME="${RELEASE}-nginx-gateway-fabric-cert-generator"
if (( DRY_RUN )); then
  printf '\033[0;90mDRY  kubectl apply ServiceAccount/Role/RoleBinding %s\033[0m\n' "${SA_NAME}"
else
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${SA_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
EOF
fi

# ------------------------------------------------------------- 4. helm release
log "Installing/upgrading release ${RELEASE} in ${NAMESPACE}"
helm_args=(upgrade --install "${RELEASE}" "${CHART_DIR}"
           --namespace "${NAMESPACE}" --create-namespace)
[[ ${#VALUES_ARGS[@]} -gt 0 ]] && helm_args+=("${VALUES_ARGS[@]}")
(( DRY_RUN )) && helm_args+=(--dry-run)
helm "${helm_args[@]}"

(( DRY_RUN )) && { log "Dry run complete - nothing was changed"; exit 0; }

# --------------------------------------------------------- 5. backend CA bundle
# BackendTLSPolicy validates the backend certificate and has no skip-verify mode,
# so the gateway needs to trust both backends:
#   * ccmgr (19051) - issued by this chart, readable from a Secret
#   * cmon  (9501)  - generated by cmon itself at runtime, so it can only be read
#                     off the live listener once the pod is up
if (( SKIP_CA_BUNDLE )); then
  log "Skipping CA bundle (--skip-ca-bundle)"
  exit 0
fi

CCMGR_SECRET="clustercontrol-ccmgr-tls"
if ! kubectl get secret "${CCMGR_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  warn "Secret ${CCMGR_SECRET} not found - chart too old, or provisionCcmgrCert=false."
  warn "Skipping CA bundle; the / route will 502 until cmon-backend-ca is built by hand."
  exit 0
fi

log "Waiting for cmon-master to become ready"
kubectl wait --for=condition=ready pod/cmon-master-0 -n "${NAMESPACE}" --timeout=600s \
  || die "cmon-master-0 did not become ready"

log "Building backend CA bundle"
kubectl get secret "${CCMGR_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${WORKDIR}/ccmgr.crt"

# port-forward on an unusual local port so a busy 9501 cannot collide
kubectl port-forward -n "${NAMESPACE}" svc/cmon-master 19501:9501 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 15); do
  sleep 1
  openssl s_client -connect 127.0.0.1:19501 -showcerts </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "${WORKDIR}/cmon-9501.crt" 2>/dev/null && break
done
kill "${PF_PID}" 2>/dev/null || true
wait "${PF_PID}" 2>/dev/null || true

[[ -s "${WORKDIR}/cmon-9501.crt" ]] || die "could not read cmon's certificate from port 9501"

cat "${WORKDIR}/cmon-9501.crt" "${WORKDIR}/ccmgr.crt" > "${WORKDIR}/ca-bundle.crt"
# key MUST be ca.crt - mandated by the Gateway API BackendTLSPolicy spec
kubectl create configmap cmon-backend-ca -n "${NAMESPACE}" \
  --from-file=ca.crt="${WORKDIR}/ca-bundle.crt" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Done."
echo
kubectl get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=nginx-gateway-fabric 2>/dev/null || true
echo
cat <<EOF
Next:
  kubectl describe gateway ${RELEASE}-gateway -n ${NAMESPACE} | grep -A8 Conditions:

To change configuration later, plain helm is enough - this script is only needed
when the chart version changes (its CRDs may change with it):

  helm upgrade ${RELEASE} ${CHART} -n ${NAMESPACE} -f my-values.yaml${CHART_VERSION:+ --version ${CHART_VERSION}}
EOF
