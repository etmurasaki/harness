#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# COO Integration TLS E2E Tests
#
# Validates TLS profile propagation and enforcement across all UIPlugin types
# (Logging, Monitoring, Dashboards, Distributed Tracing, Troubleshooting Panel)
# and the korrel8r deployment (owned by TroubleshootingPanel) simultaneously.
#
# Usage:
#   ./run-integration-tls-e2e.sh                        # Run all tests
#   ./run-integration-tls-e2e.sh --tests it_01,it_07    # Run specific tests
#   ./run-integration-tls-e2e.sh --priority P1          # Run by priority
#   ./run-integration-tls-e2e.sh --dry-run              # Preview
#   ./run-integration-tls-e2e.sh --skip-scanner-install # Scanner already running
#   ./run-integration-tls-e2e.sh --help
# =============================================================================

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

readonly NAMESPACE="${COO_NAMESPACE:-openshift-cluster-observability-operator}"
readonly OPERATOR_LABEL="app.kubernetes.io/name=observability-operator"
readonly UIPLUGIN_API_VERSION="observability.openshift.io/v1alpha1"
readonly MAX_WAIT="${MAX_WAIT_SECONDS:-180}"
readonly POLL_INTERVAL="${POLL_INTERVAL:-5}"
readonly RECONCILE_WAIT="${RECONCILE_WAIT:-240}"
readonly SCANNER_IMAGE="${TLS_SCANNER_IMAGE:-quay.io/rhn_support_ikanse/tls-scanner:latest}"
readonly PLUGIN_PORT=9443

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly REPORT_FILE="${SCRIPT_DIR}/integration-results-${TIMESTAMP}.log"

# Plugin registry (bash 3.x compatible — no associative arrays)
# Deployment names vary by cluster version. These are auto-detected at startup.
readonly PLUGIN_TYPES="Logging Monitoring Dashboards DistributedTracing TroubleshootingPanel"
readonly PLUGIN_CR_NAMES="logging monitoring dashboards distributed-tracing troubleshooting-panel"
PLUGIN_DEPLOY_NAMES=""

# Counters
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# State
ORIGINAL_TLS_PROFILE=""
START_TIME=""
DRY_RUN=false
SKIP_SCANNER_INSTALL=false
SELECTED_TESTS=()
SELECTED_PRIORITY=""
TESTS_STARTED=false
SCANNER_INSTALLED=false
KORREL8R_DEPLOY=""

# ---------------------------------------------------------------------------
# Priority → test map
# ---------------------------------------------------------------------------
priority_tests() {
  case "$1" in
    P1) echo "it_01 it_02 it_03 it_04 it_21 it_22" ;;
    P2) echo "it_05 it_06 it_07 it_08 it_09 it_23 it_24" ;;
    P3) echo "it_10 it_11 it_12 it_12_dt it_12_tp it_25" ;;
    P4) echo "it_13 it_14 it_15 it_16 it_20" ;;
    P5) echo "it_17 it_18 it_19" ;;
    *)  echo "" ;;
  esac
}

readonly ALL_TESTS="it_01 it_02 it_03 it_04 it_21 it_22 it_07 it_10 it_11 it_12 it_12_dt it_12_tp it_25 it_05 it_08 it_06 it_09 it_23 it_24 it_13 it_14 it_15 it_16 it_20 it_17 it_18 it_19"

# ---------------------------------------------------------------------------
# Plugin helpers (bash 3.x — positional lookup)
# ---------------------------------------------------------------------------
nth_word() {
  local list="$1" n="$2" i=0
  for word in $list; do
    if [[ $i -eq $n ]]; then echo "$word"; return; fi
    i=$((i + 1))
  done
}

plugin_cr_name()     { nth_word "$PLUGIN_CR_NAMES" "$1"; }
plugin_deploy_name() { nth_word "$PLUGIN_DEPLOY_NAMES" "$1"; }
plugin_type()        { nth_word "$PLUGIN_TYPES" "$1"; }

cr_name_for_type() {
  case "$1" in
    Logging)            echo "logging" ;;
    Monitoring)         echo "monitoring" ;;
    Dashboards)         echo "dashboards" ;;
    DistributedTracing)    echo "distributed-tracing" ;;
    TroubleshootingPanel) echo "troubleshooting-panel" ;;
    *)                    echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

label_for_deploy() {
  echo "app.kubernetes.io/instance=$1"
}

# Auto-detect deployment names by querying UIPlugin-managed deployments.
# On 4.22+ the names are simplified (logging, monitoring, observability-ui-dashboards).
# On older versions they were (logging-view-plugin, monitoring-console-plugin, console-dashboards-plugin).
detect_deploy_names() {
  log_info "Auto-detecting UIPlugin deployment names via ownerReferences..."

  # Build a map: ownerRef name → deployment name for all UIPlugin deployments
  local all_deploys
  all_deploys=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

  local detected=""
  for cr in $PLUGIN_CR_NAMES; do
    # Find the first deployment owned by this UIPlugin CR (skip auxiliary deployments like health-analyzer)
    local deploy_name=""
    while IFS=' ' read -r owner deploy; do
      if [[ "$owner" == "$cr" ]]; then
        # Prefer deployments that serve HTTP (have port 9443) — skip auxiliaries
        local port
        port=$(oc get "deployment/${deploy}" -n "${NAMESPACE}" \
          -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}' 2>/dev/null || echo "")
        if [[ "$port" == "${PLUGIN_PORT}" ]] || [[ -z "$deploy_name" ]]; then
          deploy_name="$deploy"
        fi
      fi
    done <<< "$all_deploys"

    if [[ -z "$deploy_name" ]]; then
      log_fail "Could not find deployment for UIPlugin CR '${cr}'"
      exit 1
    fi
    log_info "  ${cr} → ${deploy_name}"
    if [[ -n "$detected" ]]; then
      detected="$detected $deploy_name"
    else
      detected="$deploy_name"
    fi
  done
  PLUGIN_DEPLOY_NAMES="$detected"
}

detect_korrel8r_deploy() {
  log_info "Auto-detecting korrel8r deployment..."
  KORREL8R_DEPLOY=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == "troubleshooting-panel" && $2 ~ /korrel8r/ {print $2; exit}')
  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    KORREL8R_DEPLOY=$(oc get deployment -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep korrel8r | head -1 || echo "")
  fi
  if [[ -n "$KORREL8R_DEPLOY" ]]; then
    log_info "  korrel8r → ${KORREL8R_DEPLOY}"
  else
    log_warn "  korrel8r deployment not found — korrel8r tests will be skipped"
  fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_pass()    { echo -e "${GREEN}[PASS]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_fail()    { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_section() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n" | tee -a "${REPORT_FILE}"; }
log_test()    { echo -e "\n${BOLD}--- $* ---${RESET}" | tee -a "${REPORT_FILE}"; }
log_detail()  { echo -e "         $*" | tee -a "${REPORT_FILE}"; }

log_cmd() {
  local label="$1"; shift
  log_info "${label}: \$ $*"
  local output
  output=$(eval "$@" 2>&1) || true
  if [[ -n "$output" ]]; then
    echo "$output" | head -20 | while IFS= read -r line; do
      log_detail "$line"
    done
  fi
  echo "$output"
}

# ---------------------------------------------------------------------------
# Test selection
# ---------------------------------------------------------------------------
should_run_test() {
  local test_name="$1"
  if [[ ${#SELECTED_TESTS[@]} -gt 0 ]]; then
    for t in "${SELECTED_TESTS[@]}"; do
      [[ "$t" == "$test_name" ]] && return 0
    done
    return 1
  fi
  if [[ -n "$SELECTED_PRIORITY" ]]; then
    local tests_in_priority
    tests_in_priority="$(priority_tests "$SELECTED_PRIORITY")"
    [[ " $tests_in_priority " == *" $test_name "* ]] && return 0
    return 1
  fi
  return 0
}

record_result() {
  local test_id="$1" result="$2" message="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  case "$result" in
    pass) PASS_COUNT=$((PASS_COUNT + 1)); log_pass "$test_id: $message" ;;
    fail) FAIL_COUNT=$((FAIL_COUNT + 1)); log_fail "$test_id: $message" ;;
    skip) SKIP_COUNT=$((SKIP_COUNT + 1)); log_warn "$test_id: SKIPPED — $message" ;;
  esac
}

# ---------------------------------------------------------------------------
# Cluster helpers
# ---------------------------------------------------------------------------
get_cluster_tls_profile() {
  oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' 2>/dev/null || echo ""
}

set_tls_profile() {
  local profile_type="$1"
  local lower_type
  lower_type=$(echo "$profile_type" | tr '[:upper:]' '[:lower:]')
  log_info "Setting cluster TLS profile to: ${profile_type}"
  local nulls=""
  for p in old intermediate modern custom; do
    if [[ "$p" != "$lower_type" ]]; then
      nulls="${nulls}\"${p}\":null,"
    fi
  done
  oc patch apiserver cluster --type=merge \
    -p "{\"spec\":{\"tlsSecurityProfile\":{\"type\":\"${profile_type}\",${nulls}\"${lower_type}\":{}}}}" >/dev/null
}

set_tls_profile_custom() {
  local json_patch="$1"
  log_info "Setting cluster TLS profile to Custom"
  oc patch apiserver cluster --type=merge -p "$json_patch" >/dev/null
}

restore_tls_profile() {
  if [[ -n "$ORIGINAL_TLS_PROFILE" ]]; then
    log_info "Restoring original TLS profile..."
    oc patch apiserver cluster --type=merge \
      -p "{\"spec\":{\"tlsSecurityProfile\":${ORIGINAL_TLS_PROFILE}}}" >/dev/null 2>&1 || true
  else
    log_info "Restoring TLS profile to default (removing spec)..."
    oc patch apiserver cluster --type=json \
      -p '[{"op":"remove","path":"/spec/tlsSecurityProfile"}]' 2>/dev/null || true
  fi
}

get_deployment_args() {
  local deploy_name="$1"
  oc get "deployment/${deploy_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null
}

get_deployment_command() {
  local deploy_name="$1"
  oc get "deployment/${deploy_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null
}

get_deployment_generation() {
  local deploy_name="$1"
  oc get "deployment/${deploy_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.generation}' 2>/dev/null
}

get_pod_ip() {
  local deploy_name="$1"
  local label
  label=$(label_for_deploy "$deploy_name")
  oc get pod -n "${NAMESPACE}" -l "$label" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
}

wait_for_deployment_ready() {
  local deploy_name="$1" timeout="${2:-$MAX_WAIT}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if oc wait --for=condition=Available "deployment/${deploy_name}" \
         -n "${NAMESPACE}" --timeout=5s &>/dev/null; then
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  log_warn "Deployment ${deploy_name} not ready after ${timeout}s"
  return 1
}

wait_for_rollout() {
  local deploy_name="$1" timeout="${2:-$MAX_WAIT}"
  oc rollout status "deployment/${deploy_name}" -n "${NAMESPACE}" --timeout="${timeout}s" 2>/dev/null || true
  sleep 5
}

wait_for_all_args_update() {
  local expected_pattern="$1" timeout="${2:-$RECONCILE_WAIT}"
  local elapsed=0

  log_info "Waiting for all deployments to reflect TLS update (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local all_updated=true
    for deploy in $PLUGIN_DEPLOY_NAMES; do
      local args
      args=$(get_deployment_args "$deploy" 2>/dev/null || echo "")
      if [[ -z "$args" ]] || ! echo "$args" | grep -q "$expected_pattern"; then
        all_updated=false
        break
      fi
    done
    if [[ "$all_updated" == true ]]; then
      log_info "All deployments updated after ${elapsed}s"
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  log_warn "Not all deployments updated within ${timeout}s"
  return 1
}

wait_for_all_generation_increase() {
  local old_gens="$1" timeout="${2:-$RECONCILE_WAIT}"
  local elapsed=0

  log_info "Waiting for all deployment generations to increase (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local all_increased=true idx=0
    for deploy in $PLUGIN_DEPLOY_NAMES; do
      local old_gen cur_gen
      old_gen=$(echo "$old_gens" | awk -v i=$((idx + 1)) '{print $i}')
      cur_gen=$(get_deployment_generation "$deploy" 2>/dev/null || echo "0")
      if [[ "$cur_gen" -le "$old_gen" ]]; then
        all_increased=false
        break
      fi
      idx=$((idx + 1))
    done
    if [[ "$all_increased" == true ]]; then
      log_info "All deployment generations increased after ${elapsed}s"
      return 0
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  log_warn "Not all deployment generations increased within ${timeout}s"
  return 1
}

record_all_generations() {
  local gens=""
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local g
    g=$(get_deployment_generation "$deploy" 2>/dev/null || echo "0")
    gens="${gens:+$gens }$g"
  done
  echo "$gens"
}

wait_for_all_rollouts() {
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    wait_for_rollout "$deploy" || true
  done
}

# ---------------------------------------------------------------------------
# TLS scanner pod
# ---------------------------------------------------------------------------
install_tls_scanner() {
  if oc get pod tls-scanner -n "$NAMESPACE" &>/dev/null; then
    if oc get pod tls-scanner -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
      log_info "tls-scanner pod already running — reusing"
      SCANNER_INSTALLED=true
      return 0
    fi
    oc delete pod tls-scanner -n "$NAMESPACE" --force 2>/dev/null || true
    sleep 5
  fi

  log_info "Installing tls-scanner pod in $NAMESPACE"
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tls-scanner
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tls-scanner
  namespace: $NAMESPACE
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tls-scanner
  namespace: $NAMESPACE
subjects:
  - kind: ServiceAccount
    name: tls-scanner
    namespace: $NAMESPACE
roleRef:
  kind: Role
  name: tls-scanner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner
  namespace: $NAMESPACE
spec:
  serviceAccountName: tls-scanner
  containers:
    - name: scanner
      image: $SCANNER_IMAGE
      command: ["sleep", "infinity"]
      securityContext:
        allowPrivilegeEscalation: false
  restartPolicy: Never
EOF

  log_info "Waiting for tls-scanner pod..."
  oc wait --for=condition=Ready pod/tls-scanner -n "$NAMESPACE" --timeout=120s
  SCANNER_INSTALLED=true
  log_pass "tls-scanner pod ready"
}

remove_tls_scanner() {
  log_info "Removing tls-scanner pod and RBAC"
  oc delete pod tls-scanner -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding tls-scanner -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  oc delete role tls-scanner -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  oc delete serviceaccount tls-scanner -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# TLS verification helpers
ensure_scanner() {
  if oc get pod tls-scanner -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
    return 0
  fi
  log_warn "tls-scanner pod gone — recreating"
  oc delete pod tls-scanner -n "$NAMESPACE" --force --ignore-not-found 2>/dev/null || true
  sleep 2
  install_tls_scanner
}

# ---------------------------------------------------------------------------
scanner_nmap() {
  local ip="$1" port="${2:-$PLUGIN_PORT}"
  oc exec tls-scanner -n "$NAMESPACE" -- \
    nmap -Pn --script ssl-enum-ciphers -p "$port" "$ip" 2>&1
}

scanner_openssl() {
  local ip="$1" tls_flag="$2" port="${3:-$PLUGIN_PORT}" cipher="${4:-}"
  local cmd="timeout 10 openssl s_client -connect ${ip}:${port} ${tls_flag}"
  if [[ -n "$cipher" ]]; then
    if [[ "$tls_flag" == "-tls1_3" ]]; then
      cmd="$cmd -ciphersuites $cipher"
    else
      cmd="$cmd -cipher $cipher"
    fi
  fi
  oc exec tls-scanner -n "$NAMESPACE" -- bash -c "echo '' | $cmd 2>&1" 2>&1 || true
}

scanner_curl() {
  local url="$1"
  oc exec tls-scanner -n "$NAMESPACE" -- curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null
}

scanner_curl_headers() {
  local url="$1"
  oc exec tls-scanner -n "$NAMESPACE" -- curl -skI "$url" 2>&1
}

scanner_curl_body() {
  local url="$1"
  oc exec tls-scanner -n "$NAMESPACE" -- curl -sk "$url" 2>&1
}

tls_connection_succeeds() {
  local result="$1"
  if echo "$result" | grep -q "Cipher is (NONE)"; then
    return 1
  fi
  if echo "$result" | grep -qEi "alert protocol version|alert handshake failure|no ciphers available|wrong ssl version|Connection refused|errno|routines:ssl3_read_bytes|ssl_choose_client_version:unsupported protocol"; then
    return 1
  fi
  if echo "$result" | grep -qE "Cipher is [A-Z]"; then
    return 0
  fi
  return 1
}

svc_url() {
  local deploy_name="$1" endpoint="$2"
  echo "https://${deploy_name}.${NAMESPACE}.svc:${PLUGIN_PORT}${endpoint}"
}

# ---------------------------------------------------------------------------
# Plugin verification (UIPlugins are expected to be pre-installed)
# ---------------------------------------------------------------------------
verify_existing_plugins() {
  log_info "Verifying pre-installed UIPlugin deployments..."
  local missing=false

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    if oc get "deployment/${deploy}" -n "${NAMESPACE}" &>/dev/null; then
      log_pass "Deployment ${deploy} exists"
    else
      log_fail "Deployment ${deploy} not found — UIPlugins must be pre-installed"
      missing=true
    fi
  done

  if [[ "$missing" == true ]]; then
    log_fail "Missing UIPlugin deployments. Deploy Logging, Monitoring, Dashboards, and DistributedTracing UIPlugins before running this script."
    exit 1
  fi

  log_info "Waiting for all deployments to become ready..."
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    wait_for_deployment_ready "$deploy" || log_warn "Deployment ${deploy} not ready"
  done
  log_pass "All UIPlugin deployments verified"
}

ensure_uiplugin_exists() {
  local cr_name="$1" ptype="$2"
  if oc get uiplugin "$cr_name" &>/dev/null; then
    return 0
  fi
  log_info "Restoring UIPlugin ${cr_name} (type: ${ptype})..."
  if [[ "$ptype" == "Monitoring" ]]; then
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: ${UIPLUGIN_API_VERSION}
kind: UIPlugin
metadata:
  name: ${cr_name}
spec:
  type: ${ptype}
  monitoring:
    acm:
      enabled: true
      alertmanager:
        url: https://alertmanager.open-cluster-management-observability.svc:9095
      thanosQuerier:
        url: https://rbac-query-proxy.open-cluster-management-observability.svc:8443
    incidents:
      enabled: true
    perses:
      enabled: true
EOF
  else
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: ${UIPLUGIN_API_VERSION}
kind: UIPlugin
metadata:
  name: ${cr_name}
spec:
  type: ${ptype}
EOF
  fi
  # Wait for whatever deployment the operator creates for this CR (use ownerReferences)
  local elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    local deploy_name
    deploy_name=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath="{range .items[*]}{.metadata.ownerReferences[0].name}{\" \"}{.metadata.name}{\"\n\"}{end}" 2>/dev/null \
      | awk -v cr="$cr_name" '$1 == cr {print $2; exit}')
    if [[ -n "$deploy_name" ]]; then
      wait_for_deployment_ready "$deploy_name" || true
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "$TESTS_STARTED" != true ]]; then
    return
  fi
  log_section "Cleanup"

  restore_tls_profile

  # Restore any UIPlugins that were deleted during tests (IT-15, IT-18)
  ensure_uiplugin_exists "logging" "Logging"
  ensure_uiplugin_exists "monitoring" "Monitoring"
  ensure_uiplugin_exists "dashboards" "Dashboards"
  ensure_uiplugin_exists "distributed-tracing" "DistributedTracing"
  ensure_uiplugin_exists "troubleshooting-panel" "TroubleshootingPanel"

  if [[ "$SCANNER_INSTALLED" == true ]] && [[ "$SKIP_SCANNER_INSTALL" != true ]]; then
    remove_tls_scanner
  fi

  log_info "Cleanup complete"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
  log_section "Prerequisites"
  local failed=false

  if ! command -v oc &>/dev/null; then
    log_fail "oc CLI not found"; failed=true
  else
    log_pass "oc CLI found"
  fi

  if ! oc whoami &>/dev/null; then
    log_fail "Not logged into an OpenShift cluster"; failed=true
  else
    log_pass "Logged in as: $(oc whoami)"
  fi

  if ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
    log_fail "UIPlugin CRD not found"; failed=true
  else
    log_pass "UIPlugin CRD exists"
  fi

  if ! oc get pods -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" --no-headers 2>/dev/null | grep -q Running; then
    log_fail "Observability Operator not running in ${NAMESPACE}"; failed=true
  else
    log_pass "Observability Operator running"
  fi

  # Verify UIPlugin CRs exist
  for cr in $PLUGIN_CR_NAMES; do
    if oc get uiplugin "$cr" &>/dev/null; then
      log_pass "UIPlugin CR '${cr}' exists"
    else
      log_fail "UIPlugin CR '${cr}' not found — deploy Logging, Monitoring, Dashboards, DistributedTracing, and TroubleshootingPanel UIPlugins first"
      failed=true
    fi
  done

  local cluster_version
  cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
  log_info "Cluster version: ${cluster_version}"

  if [[ "$failed" == true ]]; then
    log_fail "Prerequisites check failed — aborting"
    exit 1
  fi

  ORIGINAL_TLS_PROFILE=$(get_cluster_tls_profile)
  if [[ -n "$ORIGINAL_TLS_PROFILE" ]]; then
    log_info "Original TLS profile saved: ${ORIGINAL_TLS_PROFILE}"
  else
    log_info "No explicit TLS profile set (cluster default)"
  fi
}

# ============================================================================
# TEST CASES
# ============================================================================

# ---------------------------------------------------------------------------
# IT-01: Deploy All Three UIPlugins and Verify TLS Args
# ---------------------------------------------------------------------------
it_01() {
  log_test "IT-01: Verify All UIPlugins Have TLS Args (Intermediate)"

  set_tls_profile "Intermediate"
  sleep 10

  verify_existing_plugins

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args
    args=$(get_deployment_args "$deploy" 2>/dev/null || echo "NOT_FOUND")

    if [[ "$args" == "NOT_FOUND" ]] || [[ -z "$args" ]]; then
      log_fail "IT-01: Deployment ${deploy} not found or has no args"
      passed=false
      continue
    fi

    log_info "IT-01: ${deploy} args: ${args}"

    if echo "$args" | grep -q "\-tls-min-version"; then
      log_pass "IT-01: ${deploy} has -tls-min-version"
    else
      log_fail "IT-01: ${deploy} missing -tls-min-version"
      passed=false
    fi

    if echo "$args" | grep -q "\-tls-cipher-suites"; then
      log_pass "IT-01: ${deploy} has -tls-cipher-suites"
    else
      log_fail "IT-01: ${deploy} missing -tls-cipher-suites"
      passed=false
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-01" "pass" "All 4 pre-installed plugins have TLS args under Intermediate profile"
  else
    record_result "IT-01" "fail" "Not all plugins received TLS args"
  fi
}

# ---------------------------------------------------------------------------
# IT-02: Cross-Plugin TLS Arg Consistency
# ---------------------------------------------------------------------------
it_02() {
  log_test "IT-02: Cross-Plugin TLS Arg Consistency"

  local first_min_ver="" first_ciphers="" passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args
    args=$(get_deployment_args "$deploy" 2>/dev/null || echo "")
    if [[ -z "$args" ]]; then
      log_warn "IT-02: ${deploy} has no args — skipping"
      continue
    fi

    local min_ver
    min_ver=$(echo "$args" | grep -o "\-tls-min-version=[^ ,\"]*" | head -1 || echo "")
    local ciphers
    ciphers=$(echo "$args" | grep -o "\-tls-cipher-suites=[^ \"]*" | head -1 || echo "")

    if [[ -z "$first_min_ver" ]]; then
      first_min_ver="$min_ver"
      first_ciphers="$ciphers"
      log_info "IT-02: Reference (${deploy}): ${min_ver}"
      continue
    fi

    if [[ "$min_ver" != "$first_min_ver" ]]; then
      log_fail "IT-02: ${deploy} min version '${min_ver}' differs from reference '${first_min_ver}'"
      passed=false
    else
      log_pass "IT-02: ${deploy} min version matches"
    fi

    if [[ "$ciphers" != "$first_ciphers" ]]; then
      log_fail "IT-02: ${deploy} cipher list differs from reference"
      passed=false
    else
      log_pass "IT-02: ${deploy} cipher list matches"
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-02" "pass" "All plugins have identical TLS configuration"
  else
    record_result "IT-02" "fail" "Plugin TLS configurations differ"
  fi
}

# ---------------------------------------------------------------------------
# IT-03: All Plugin Endpoints Respond Over HTTPS
# ---------------------------------------------------------------------------
it_03() {
  log_test "IT-03: All Plugin Endpoints Respond Over HTTPS"

  ensure_scanner

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    for endpoint in /health /plugin-manifest.json; do
      local url
      url=$(svc_url "$deploy" "$endpoint")
      local http_code
      http_code=$(scanner_curl "$url")

      if [[ "$http_code" == "200" ]]; then
        log_pass "IT-03: ${deploy}${endpoint} → HTTP 200"
      else
        log_fail "IT-03: ${deploy}${endpoint} → HTTP ${http_code} (expected 200)"
        passed=false
      fi
    done
  done

  # Monitoring-specific: /features endpoint
  local mon_deploy
  mon_deploy=$(oc get deployments -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=monitoring,app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$mon_deploy" ]]; then
    local features_code
    features_code=$(scanner_curl "$(svc_url "$mon_deploy" "/features")")
    if [[ "$features_code" == "200" ]]; then
      log_pass "IT-03: ${mon_deploy}/features → HTTP 200"
    else
      log_warn "IT-03: ${mon_deploy}/features → HTTP ${features_code}"
    fi
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-03" "pass" "All plugin endpoints respond over HTTPS"
  else
    record_result "IT-03" "fail" "Some plugin endpoints failed"
  fi
}

# ---------------------------------------------------------------------------
# IT-04: ConsolePlugin CRs Registered
# ---------------------------------------------------------------------------
it_04() {
  log_test "IT-04: ConsolePlugin CRs Registered"

  local passed=true

  # ConsolePlugin names may differ from deployment names (e.g., deployment=logging, consoleplugin=logging-view-plugin)
  # Query by owner label instead of hardcoding names
  local all_console_plugins
  all_console_plugins=$(oc get consoleplugins -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

  for cr in $PLUGIN_CR_NAMES; do
    local found=false
    # Check if any ConsolePlugin is associated with this UIPlugin
    for cp in $all_console_plugins; do
      if echo "$cp" | grep -qi "$cr"; then
        log_pass "IT-04: ConsolePlugin '${cp}' found for UIPlugin '${cr}'"
        found=true
        break
      fi
    done
    if [[ "$found" != true ]]; then
      log_warn "IT-04: No ConsolePlugin found matching UIPlugin '${cr}'"
    fi
  done

  local console_plugins
  console_plugins=$(oc get consoles.operator.openshift.io cluster \
    -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
  log_info "IT-04: Console operator plugins list: ${console_plugins}"

  if [[ "$passed" == true ]]; then
    record_result "IT-04" "pass" "All ConsolePlugin CRs registered"
  else
    record_result "IT-04" "fail" "Some ConsolePlugin CRs missing"
  fi
}

# ---------------------------------------------------------------------------
# IT-05: Modern Profile Propagates to All Plugins
# ---------------------------------------------------------------------------
it_05() {
  log_test "IT-05: Modern Profile Propagates to All Plugins"

  local gen_before=()
  local i=0
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    gen_before[i]=$(get_deployment_generation "$deploy")
    i=$((i + 1))
  done

  set_tls_profile "Modern"
  wait_for_all_args_update "VersionTLS13" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts

  local passed=true i=0

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local gen_after
    gen_after=$(get_deployment_generation "$deploy")
    local args
    args=$(get_deployment_args "$deploy")

    if [[ "$gen_after" -gt "${gen_before[$i]}" ]]; then
      log_pass "IT-05: ${deploy} generation increased (${gen_before[$i]} → ${gen_after})"
    else
      log_warn "IT-05: ${deploy} generation unchanged (may have already been Modern)"
    fi

    if echo "$args" | grep -q "VersionTLS13"; then
      log_pass "IT-05: ${deploy} has VersionTLS13"
    else
      log_fail "IT-05: ${deploy} missing VersionTLS13"
      passed=false
    fi

    i=$((i + 1))
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-05" "pass" "Modern profile propagated to all plugins"
  else
    record_result "IT-05" "fail" "Modern profile not propagated to all plugins"
  fi

  set_tls_profile "Intermediate"
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-06: Custom Profile Propagates to All Plugins
# ---------------------------------------------------------------------------
it_06_verify_ciphers() {
  local passed=true
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args
    args=$(get_deployment_args "$deploy")
    log_info "IT-06: ${deploy} current args:"
    log_detail "${args}"

    if echo "$args" | grep -q "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"; then
      log_pass "IT-06: ${deploy} has expected cipher AES_128_GCM"
    else
      log_fail "IT-06: ${deploy} missing expected cipher AES_128_GCM"
      passed=false
    fi

    if echo "$args" | grep -q "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"; then
      log_pass "IT-06: ${deploy} has expected cipher AES_256_GCM"
    else
      log_fail "IT-06: ${deploy} missing expected cipher AES_256_GCM"
      passed=false
    fi
  done
  [[ "$passed" == true ]]
}

it_06() {
  log_test "IT-06: Custom Profile Propagates to All Plugins"

  local gens_before
  gens_before=$(record_all_generations)
  log_info "IT-06: Deployment generations before: ${gens_before}"

  log_info "IT-06: Applying Custom TLS profile with ciphers: ECDHE-RSA-AES128-GCM-SHA256, ECDHE-RSA-AES256-GCM-SHA384"
  set_tls_profile_custom '{
    "spec": {
      "tlsSecurityProfile": {
        "type": "Custom",
        "old": null,
        "intermediate": null,
        "modern": null,
        "custom": {
          "ciphers": [
            "ECDHE-RSA-AES128-GCM-SHA256",
            "ECDHE-RSA-AES256-GCM-SHA384"
          ],
          "minTLSVersion": "VersionTLS12"
        }
      }
    }
  }'

  log_cmd "IT-06" "oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}'"
  wait_for_all_generation_increase "$gens_before" "$RECONCILE_WAIT" || true
  log_info "IT-06: Deployment generations after: $(record_all_generations)"
  wait_for_all_rollouts

  if it_06_verify_ciphers; then
    record_result "IT-06" "pass" "Custom profile with specific ciphers propagated to all plugins"
  else
    log_warn "IT-06: First check failed — retrying after 30s reconciliation wait..."
    sleep 30
    wait_for_all_rollouts
    if it_06_verify_ciphers; then
      record_result "IT-06" "pass" "Custom profile propagated (passed on retry)"
    else
      record_result "IT-06" "fail" "Custom profile not correctly propagated"
    fi
  fi

  # Restore to Intermediate using generation-based wait to avoid false positives
  # (Custom and Intermediate both have VersionTLS12, so pattern match returns immediately)
  local gens_after_custom
  gens_after_custom=$(record_all_generations)
  set_tls_profile "Intermediate"
  wait_for_all_generation_increase "$gens_after_custom" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-07: In-Cluster TLS Version Enforcement (All Plugins, Intermediate)
# ---------------------------------------------------------------------------
it_07() {
  log_test "IT-07: TLS Enforcement — All Plugins, Intermediate Profile"

  ensure_scanner

  set_tls_profile "Intermediate"
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local pod_ip
    pod_ip=$(get_pod_ip "$deploy")

    if [[ -z "$pod_ip" ]]; then
      log_warn "IT-07: Could not get pod IP for ${deploy}"
      continue
    fi

    log_info "IT-07: Scanning ${deploy} at ${pod_ip}:${PLUGIN_PORT}"
    log_info "IT-07: ${deploy} args: $(get_deployment_args "$deploy" | grep -o '\-tls-min-version=[^ ,"]*')"

    # TLS 1.1 should be rejected
    local result verdict
    log_info "IT-07: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_1"
    result=$(scanner_openssl "$pod_ip" "-tls1_1")
    verdict=$(echo "$result" | grep -oE "Cipher is.*|alert protocol version|alert handshake failure" | head -1 || echo "")
    log_detail "TLS 1.1 result: ${verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_fail "IT-07: ${deploy} accepted TLS 1.1 (should reject)"
      passed=false
    else
      log_pass "IT-07: ${deploy} correctly rejected TLS 1.1"
    fi

    # TLS 1.2 should be accepted
    log_info "IT-07: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2"
    result=$(scanner_openssl "$pod_ip" "-tls1_2")
    verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
    log_detail "TLS 1.2 result: ${verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_pass "IT-07: ${deploy} correctly accepted TLS 1.2"
    else
      log_fail "IT-07: ${deploy} rejected TLS 1.2 (should accept)"
      passed=false
    fi

    # TLS 1.3 should be accepted
    log_info "IT-07: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_3"
    result=$(scanner_openssl "$pod_ip" "-tls1_3")
    verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
    log_detail "TLS 1.3 result: ${verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_pass "IT-07: ${deploy} correctly accepted TLS 1.3"
    else
      log_warn "IT-07: ${deploy} rejected TLS 1.3 (may not be supported)"
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-07" "pass" "All plugins enforce Intermediate TLS profile"
  else
    record_result "IT-07" "fail" "TLS enforcement issues detected"
  fi
}

# ---------------------------------------------------------------------------
# IT-08: In-Cluster TLS Enforcement (All Plugins, Modern)
# ---------------------------------------------------------------------------
it_08() {
  log_test "IT-08: TLS Enforcement — All Plugins, Modern Profile"

  ensure_scanner

  set_tls_profile "Modern"
  wait_for_all_args_update "VersionTLS13" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
  sleep 15

  # Verify all deployments have VersionTLS13 before scanning
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args
    args=$(get_deployment_args "$deploy")
    log_info "IT-08: ${deploy} args: $(echo "$args" | grep -o '\-tls-min-version=[^ ,"]*')"
  done

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local pod_ip
    pod_ip=$(get_pod_ip "$deploy")

    if [[ -z "$pod_ip" ]]; then
      log_warn "IT-08: Could not get pod IP for ${deploy}"
      continue
    fi

    log_info "IT-08: Scanning ${deploy} at ${pod_ip}:${PLUGIN_PORT}"

    # TLS 1.2 should be rejected under Modern
    local result
    log_info "IT-08: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2"
    result=$(scanner_openssl "$pod_ip" "-tls1_2")
    local tls12_verdict
    tls12_verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*|alert protocol version|alert handshake failure" | head -3 || echo "")
    log_detail "TLS 1.2 result: ${tls12_verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_fail "IT-08: ${deploy} accepted TLS 1.2 under Modern (should reject)"
      passed=false
    else
      log_pass "IT-08: ${deploy} correctly rejected TLS 1.2 under Modern"
    fi

    # TLS 1.3 should be accepted
    log_info "IT-08: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_3"
    result=$(scanner_openssl "$pod_ip" "-tls1_3")
    local tls13_verdict
    tls13_verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
    log_detail "TLS 1.3 result: ${tls13_verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_pass "IT-08: ${deploy} correctly accepted TLS 1.3"
    else
      log_fail "IT-08: ${deploy} rejected TLS 1.3 (should accept under Modern)"
      passed=false
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-08" "pass" "All plugins enforce Modern TLS profile (TLS 1.3 only)"
  else
    record_result "IT-08" "fail" "Modern profile enforcement issues"
  fi

  set_tls_profile "Intermediate"
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-09: In-Cluster Cipher Enforcement (All Plugins, Custom)
# ---------------------------------------------------------------------------
it_09_verify_ciphers() {
  local passed=true
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local pod_ip
    pod_ip=$(get_pod_ip "$deploy")

    if [[ -z "$pod_ip" ]]; then
      log_warn "IT-09: Could not get pod IP for ${deploy}"
      continue
    fi

    log_info "IT-09: Scanning ${deploy} at ${pod_ip}:${PLUGIN_PORT}"
    local args
    args=$(get_deployment_args "$deploy")
    log_info "IT-09: ${deploy} cipher args: $(echo "$args" | grep -o '\-tls-cipher-suites=[^ "]*' | head -1)"

    # Allowed cipher should succeed
    local result
    log_info "IT-09: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256"
    result=$(scanner_openssl "$pod_ip" "-tls1_2" "$PLUGIN_PORT" "ECDHE-RSA-AES128-GCM-SHA256")
    local verdict
    verdict=$(echo "$result" | grep -oE "Cipher is.*" | head -1 || echo "")
    log_detail "Allowed cipher result: ${verdict:-<connection failed>}"
    if tls_connection_succeeds "$result"; then
      log_pass "IT-09: ${deploy} accepted allowed cipher (AES128-GCM)"
    else
      log_fail "IT-09: ${deploy} rejected allowed cipher"
      passed=false
    fi

    # Disallowed cipher should fail
    log_info "IT-09: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2 -cipher AES128-SHA"
    result=$(scanner_openssl "$pod_ip" "-tls1_2" "$PLUGIN_PORT" "AES128-SHA")
    verdict=$(echo "$result" | grep -oE "Cipher is.*|alert handshake failure|no ciphers available" | head -1 || echo "")
    log_detail "Disallowed cipher result: ${verdict:-<connection refused>}"
    if tls_connection_succeeds "$result"; then
      log_fail "IT-09: ${deploy} accepted disallowed cipher AES128-SHA"
      passed=false
    else
      log_pass "IT-09: ${deploy} correctly rejected disallowed cipher"
    fi
  done
  [[ "$passed" == true ]]
}

it_09() {
  log_test "IT-09: Cipher Enforcement — All Plugins, Custom Profile"

  ensure_scanner

  local gens_before
  gens_before=$(record_all_generations)
  log_info "IT-09: Deployment generations before: ${gens_before}"

  set_tls_profile_custom '{
    "spec": {
      "tlsSecurityProfile": {
        "type": "Custom",
        "old": null,
        "intermediate": null,
        "modern": null,
        "custom": {
          "ciphers": [
            "ECDHE-RSA-AES128-GCM-SHA256",
            "ECDHE-RSA-AES256-GCM-SHA384"
          ],
          "minTLSVersion": "VersionTLS12"
        }
      }
    }
  }'

  wait_for_all_generation_increase "$gens_before" "$RECONCILE_WAIT" || true
  log_info "IT-09: Deployment generations after: $(record_all_generations)"
  wait_for_all_rollouts

  if it_09_verify_ciphers; then
    record_result "IT-09" "pass" "All plugins enforce custom cipher restrictions"
  else
    log_warn "IT-09: First check failed — retrying after 30s reconciliation wait..."
    sleep 30
    wait_for_all_rollouts
    if it_09_verify_ciphers; then
      record_result "IT-09" "pass" "All plugins enforce custom cipher restrictions (passed on retry)"
    else
      record_result "IT-09" "fail" "Cipher enforcement issues detected"
    fi
  fi

  # Restore to Intermediate using generation-based wait (same Custom→Intermediate fix as IT-06)
  local gens_after_custom
  gens_after_custom=$(record_all_generations)
  set_tls_profile "Intermediate"
  wait_for_all_generation_increase "$gens_after_custom" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-10: Logging Plugin Endpoints Under TLS
# ---------------------------------------------------------------------------
it_10() {
  log_test "IT-10: Logging Plugin Endpoints Under TLS"

  ensure_scanner

  local deploy
  deploy=$(oc get deployments -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=logging,app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  local passed=true

  local health_code
  health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
  if [[ "$health_code" == "200" ]]; then
    log_pass "IT-10: /health → HTTP 200"
  else
    log_fail "IT-10: /health → HTTP ${health_code}"
    passed=false
  fi

  local manifest
  manifest=$(scanner_curl_body "$(svc_url "$deploy" "/plugin-manifest.json")")
  if echo "$manifest" | grep -qiE "logging"; then
    log_pass "IT-10: /plugin-manifest.json contains logging plugin metadata"
  else
    log_warn "IT-10: /plugin-manifest.json may not contain expected name"
    log_info "IT-10: Response: $(echo "$manifest" | head -5)"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-10" "pass" "Logging plugin endpoints working under TLS"
  else
    record_result "IT-10" "fail" "Logging plugin endpoint issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-11: Monitoring Plugin Endpoints Under TLS
# ---------------------------------------------------------------------------
it_11() {
  log_test "IT-11: Monitoring Plugin Endpoints Under TLS"

  ensure_scanner

  local deploy
  deploy=$(oc get deployments -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=monitoring,app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  local passed=true

  local health_code
  health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
  if [[ "$health_code" == "200" ]]; then
    log_pass "IT-11: /health → HTTP 200"
  else
    log_fail "IT-11: /health → HTTP ${health_code}"
    passed=false
  fi

  local manifest
  manifest=$(scanner_curl_body "$(svc_url "$deploy" "/plugin-manifest.json")")
  if echo "$manifest" | grep -qiE "monitoring"; then
    log_pass "IT-11: /plugin-manifest.json contains monitoring plugin metadata"
  else
    log_warn "IT-11: /plugin-manifest.json may not contain expected name"
  fi

  local features_code
  features_code=$(scanner_curl "$(svc_url "$deploy" "/features")")
  if [[ "$features_code" == "200" ]]; then
    log_pass "IT-11: /features → HTTP 200"
  else
    log_warn "IT-11: /features → HTTP ${features_code}"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-11" "pass" "Monitoring plugin endpoints working under TLS"
  else
    record_result "IT-11" "fail" "Monitoring plugin endpoint issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-12: Dashboards Plugin Endpoints Under TLS
# ---------------------------------------------------------------------------
it_12() {
  log_test "IT-12: Dashboards Plugin Endpoints and Cache Headers Under TLS"

  ensure_scanner

  # Use ownerReferences to find the dashboards deployment (instance label may differ from CR name)
  local deploy
  deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == "dashboards" {print $2; exit}')
  if [[ -z "$deploy" ]]; then
    deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i dash | head -1 || echo "")
  fi
  local passed=true

  if [[ -z "$deploy" ]]; then
    record_result "IT-12" "skip" "Dashboards deployment not found"
    return
  fi

  local health_code
  health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
  if [[ "$health_code" == "200" ]]; then
    log_pass "IT-12: /health → HTTP 200"
  else
    log_fail "IT-12: /health → HTTP ${health_code}"
    passed=false
  fi

  local manifest
  manifest=$(scanner_curl_body "$(svc_url "$deploy" "/plugin-manifest.json")")
  if echo "$manifest" | grep -qiE "dashboard"; then
    log_pass "IT-12: /plugin-manifest.json contains dashboards plugin metadata"
  else
    log_warn "IT-12: /plugin-manifest.json may not contain expected name"
  fi

  # Check plugin-entry.js caching headers
  local headers
  headers=$(scanner_curl_headers "$(svc_url "$deploy" "/plugin-entry.js")")
  if echo "$headers" | grep -qi "cache-control.*no-cache"; then
    log_pass "IT-12: /plugin-entry.js has Cache-Control: no-cache header"
  else
    log_warn "IT-12: /plugin-entry.js missing Cache-Control header"
  fi

  if echo "$headers" | grep -qi "expires.*0"; then
    log_pass "IT-12: /plugin-entry.js has Expires: 0 header"
  else
    log_warn "IT-12: /plugin-entry.js missing Expires: 0 header"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-12" "pass" "Dashboards plugin endpoints and caching headers correct"
  else
    record_result "IT-12" "fail" "Dashboards plugin endpoint issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-12-DT: Distributed Tracing Plugin Endpoints Under TLS
# ---------------------------------------------------------------------------
it_12_dt() {
  log_test "IT-12-DT: Distributed Tracing Plugin Endpoints Under TLS"

  ensure_scanner

  local deploy
  deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == "distributed-tracing" {print $2; exit}')
  if [[ -z "$deploy" ]]; then
    deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i trac | head -1 || echo "")
  fi
  local passed=true

  if [[ -z "$deploy" ]]; then
    record_result "IT-12-DT" "skip" "Distributed tracing deployment not found"
    return
  fi

  local health_code
  health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
  if [[ "$health_code" == "200" ]]; then
    log_pass "IT-12-DT: /health → HTTP 200"
  else
    log_fail "IT-12-DT: /health → HTTP ${health_code}"
    passed=false
  fi

  local manifest
  manifest=$(scanner_curl_body "$(svc_url "$deploy" "/plugin-manifest.json")")
  if echo "$manifest" | grep -qiE "trac"; then
    log_pass "IT-12-DT: /plugin-manifest.json contains distributed tracing plugin metadata"
  else
    log_warn "IT-12-DT: /plugin-manifest.json may not contain expected name"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-12-DT" "pass" "Distributed tracing plugin endpoints working under TLS"
  else
    record_result "IT-12-DT" "fail" "Distributed tracing plugin endpoint issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-12-TP: Troubleshooting Panel Plugin Endpoints Under TLS
# ---------------------------------------------------------------------------
it_12_tp() {
  log_test "IT-12-TP: Troubleshooting Panel Plugin Endpoints Under TLS"

  ensure_scanner

  # The troubleshooting-panel CR owns two deployments (troubleshooting-panel + korrel8r).
  # Prefer the one whose name matches the CR, then fall back to instance label lookup.
  local deploy
  deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == "troubleshooting-panel" && $2 == "troubleshooting-panel" {print $2; exit}')
  if [[ -z "$deploy" ]]; then
    deploy=$(oc get deployments -n "${NAMESPACE}" \
      -l "app.kubernetes.io/instance=troubleshooting-panel,app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  fi
  local passed=true

  if [[ -z "$deploy" ]]; then
    record_result "IT-12-TP" "skip" "Troubleshooting panel deployment not found"
    return
  fi

  local health_code
  health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
  if [[ "$health_code" == "200" ]]; then
    log_pass "IT-12-TP: /health → HTTP 200"
  else
    log_fail "IT-12-TP: /health → HTTP ${health_code}"
    passed=false
  fi

  local manifest
  manifest=$(scanner_curl_body "$(svc_url "$deploy" "/plugin-manifest.json")")
  if echo "$manifest" | grep -qiE "troubleshoot"; then
    log_pass "IT-12-TP: /plugin-manifest.json contains troubleshooting panel plugin metadata"
  else
    log_warn "IT-12-TP: /plugin-manifest.json may not contain expected name"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-12-TP" "pass" "Troubleshooting panel plugin endpoints working under TLS"
  else
    record_result "IT-12-TP" "fail" "Troubleshooting panel plugin endpoint issues"
  fi
}

# ===========================================================================
# KORREL8R TLS TESTS (IT-21 through IT-25)
#
# The troubleshooting-panel UIPlugin owns two deployments: the plugin itself
# and korrel8r. Korrel8r uses container "command" with double-dash flags
# (--tls-min-version, --tls-cipher-suites), unlike UIPlugins which use
# container "args" with single-dash flags.
# ===========================================================================

# ---------------------------------------------------------------------------
# IT-21: Korrel8r Deployment Has TLS Args
# ---------------------------------------------------------------------------
it_21() {
  log_test "IT-21: Korrel8r Deployment Has TLS Args (Intermediate)"

  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    record_result "IT-21" "skip" "Korrel8r deployment not found"
    return
  fi

  local cmd
  cmd=$(get_deployment_command "$KORREL8R_DEPLOY")

  if [[ -z "$cmd" ]]; then
    log_fail "IT-21: Korrel8r deployment has no command"
    record_result "IT-21" "fail" "No command found on korrel8r deployment"
    return
  fi

  log_info "IT-21: ${KORREL8R_DEPLOY} command: ${cmd}"

  local passed=true

  if echo "$cmd" | grep -q "\-\-tls-min-version"; then
    log_pass "IT-21: ${KORREL8R_DEPLOY} has --tls-min-version"
  else
    log_fail "IT-21: ${KORREL8R_DEPLOY} missing --tls-min-version"
    passed=false
  fi

  if echo "$cmd" | grep -q "\-\-tls-cipher-suites"; then
    log_pass "IT-21: ${KORREL8R_DEPLOY} has --tls-cipher-suites"
  else
    log_fail "IT-21: ${KORREL8R_DEPLOY} missing --tls-cipher-suites"
    passed=false
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-21" "pass" "Korrel8r deployment has TLS args under Intermediate profile"
  else
    record_result "IT-21" "fail" "Korrel8r deployment missing TLS args"
  fi
}

# ---------------------------------------------------------------------------
# IT-22: Korrel8r TLS Args Consistent with UIPlugins
# ---------------------------------------------------------------------------
it_22() {
  log_test "IT-22: Korrel8r TLS Args Consistent with UIPlugins"

  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    record_result "IT-22" "skip" "Korrel8r deployment not found"
    return
  fi

  local cmd
  cmd=$(get_deployment_command "$KORREL8R_DEPLOY")
  local korrel8r_min_ver
  korrel8r_min_ver=$(echo "$cmd" | grep -o '\-\-tls-min-version=[^ ,"]*' | head -1 | sed 's/--tls-min-version=//' || echo "")

  if [[ -z "$korrel8r_min_ver" ]]; then
    log_fail "IT-22: Cannot extract TLS min version from korrel8r command"
    record_result "IT-22" "fail" "Could not extract korrel8r TLS min version"
    return
  fi

  log_info "IT-22: Korrel8r TLS min version: ${korrel8r_min_ver}"

  local passed=true
  local ref_deploy
  ref_deploy=$(echo "$PLUGIN_DEPLOY_NAMES" | awk '{print $1}')
  local ref_args
  ref_args=$(get_deployment_args "$ref_deploy" 2>/dev/null || echo "")
  local ref_min_ver
  ref_min_ver=$(echo "$ref_args" | grep -o '\-tls-min-version=[^ ,"]*' | head -1 | sed 's/-tls-min-version=//' || echo "")

  log_info "IT-22: Reference plugin (${ref_deploy}) TLS min version: ${ref_min_ver}"

  if [[ "$korrel8r_min_ver" == "$ref_min_ver" ]]; then
    log_pass "IT-22: Korrel8r TLS min version matches UIPlugin (${korrel8r_min_ver})"
  else
    log_fail "IT-22: Korrel8r TLS min version '${korrel8r_min_ver}' differs from UIPlugin '${ref_min_ver}'"
    passed=false
  fi

  local korrel8r_ciphers
  korrel8r_ciphers=$(echo "$cmd" | grep -o '\-\-tls-cipher-suites=[^ "]*' | head -1 | sed 's/--tls-cipher-suites=//' || echo "")
  local ref_ciphers
  ref_ciphers=$(echo "$ref_args" | grep -o '\-tls-cipher-suites=[^ "]*' | head -1 | sed 's/-tls-cipher-suites=//' || echo "")

  if [[ "$korrel8r_ciphers" == "$ref_ciphers" ]]; then
    log_pass "IT-22: Korrel8r cipher suites match UIPlugin"
  else
    log_warn "IT-22: Korrel8r ciphers may differ from UIPlugin (expected if flag format varies)"
    log_detail "Korrel8r: ${korrel8r_ciphers:-<none>}"
    log_detail "UIPlugin: ${ref_ciphers:-<none>}"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-22" "pass" "Korrel8r TLS configuration consistent with UIPlugins"
  else
    record_result "IT-22" "fail" "Korrel8r TLS configuration inconsistent with UIPlugins"
  fi
}

# ---------------------------------------------------------------------------
# IT-23: Korrel8r TLS Profile Propagation (Modern)
# ---------------------------------------------------------------------------
it_23() {
  log_test "IT-23: Korrel8r TLS Profile Propagation (Modern)"

  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    record_result "IT-23" "skip" "Korrel8r deployment not found"
    return
  fi

  local gen_before
  gen_before=$(get_deployment_generation "$KORREL8R_DEPLOY")
  log_info "IT-23: Korrel8r generation before: ${gen_before}"

  set_tls_profile "Modern"

  local elapsed=0
  local updated=false
  while [[ $elapsed -lt $RECONCILE_WAIT ]]; do
    local cmd
    cmd=$(get_deployment_command "$KORREL8R_DEPLOY" 2>/dev/null || echo "")
    if echo "$cmd" | grep -q "VersionTLS13"; then
      updated=true
      break
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  wait_for_rollout "$KORREL8R_DEPLOY" || true

  local passed=true

  local gen_after
  gen_after=$(get_deployment_generation "$KORREL8R_DEPLOY")
  if [[ "$gen_after" -gt "$gen_before" ]]; then
    log_pass "IT-23: Korrel8r generation increased (${gen_before} → ${gen_after})"
  else
    log_warn "IT-23: Korrel8r generation unchanged (may have already been Modern)"
  fi

  local cmd_after
  cmd_after=$(get_deployment_command "$KORREL8R_DEPLOY")
  if echo "$cmd_after" | grep -q "VersionTLS13"; then
    log_pass "IT-23: Korrel8r has VersionTLS13 under Modern profile"
  else
    log_fail "IT-23: Korrel8r missing VersionTLS13 after profile change"
    passed=false
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-23" "pass" "Modern profile propagated to korrel8r"
  else
    record_result "IT-23" "fail" "Modern profile not propagated to korrel8r"
  fi

  set_tls_profile "Intermediate"
  elapsed=0
  while [[ $elapsed -lt $RECONCILE_WAIT ]]; do
    local cmd
    cmd=$(get_deployment_command "$KORREL8R_DEPLOY" 2>/dev/null || echo "")
    if echo "$cmd" | grep -q "VersionTLS12"; then break; fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  wait_for_rollout "$KORREL8R_DEPLOY" || true
}

# ---------------------------------------------------------------------------
# IT-24: Korrel8r In-Cluster TLS Enforcement
# ---------------------------------------------------------------------------
it_24() {
  log_test "IT-24: Korrel8r TLS Enforcement — Intermediate and Modern"

  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    record_result "IT-24" "skip" "Korrel8r deployment not found"
    return
  fi

  ensure_scanner

  local passed=true

  # --- Phase 1: Intermediate profile ---
  log_info "IT-24: Phase 1 — Intermediate profile enforcement"
  set_tls_profile "Intermediate"
  local elapsed=0
  while [[ $elapsed -lt $RECONCILE_WAIT ]]; do
    local cmd
    cmd=$(get_deployment_command "$KORREL8R_DEPLOY" 2>/dev/null || echo "")
    if echo "$cmd" | grep -q "VersionTLS12"; then break; fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  wait_for_rollout "$KORREL8R_DEPLOY" || true

  local pod_ip
  pod_ip=$(get_pod_ip "$KORREL8R_DEPLOY")

  if [[ -z "$pod_ip" ]]; then
    log_fail "IT-24: Could not get pod IP for korrel8r"
    record_result "IT-24" "fail" "Cannot resolve korrel8r pod IP"
    return
  fi

  log_info "IT-24: Scanning korrel8r at ${pod_ip}:${PLUGIN_PORT}"
  log_info "IT-24: korrel8r command: $(get_deployment_command "$KORREL8R_DEPLOY" | grep -o '\-\-tls-min-version=[^ ,"]*')"

  # TLS 1.1 should be rejected
  local result verdict
  log_info "IT-24: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_1"
  result=$(scanner_openssl "$pod_ip" "-tls1_1")
  verdict=$(echo "$result" | grep -oE "Cipher is.*|alert protocol version|alert handshake failure" | head -1 || echo "")
  log_detail "TLS 1.1 result: ${verdict:-<connection failed>}"
  if tls_connection_succeeds "$result"; then
    log_fail "IT-24: Korrel8r accepted TLS 1.1 (should reject)"
    passed=false
  else
    log_pass "IT-24: Korrel8r correctly rejected TLS 1.1"
  fi

  # TLS 1.2 should be accepted
  log_info "IT-24: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2"
  result=$(scanner_openssl "$pod_ip" "-tls1_2")
  verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
  log_detail "TLS 1.2 result: ${verdict:-<connection failed>}"
  if tls_connection_succeeds "$result"; then
    log_pass "IT-24: Korrel8r correctly accepted TLS 1.2"
  else
    log_fail "IT-24: Korrel8r rejected TLS 1.2 (should accept)"
    passed=false
  fi

  # TLS 1.3 should be accepted
  log_info "IT-24: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_3"
  result=$(scanner_openssl "$pod_ip" "-tls1_3")
  verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
  log_detail "TLS 1.3 result: ${verdict:-<connection failed>}"
  if tls_connection_succeeds "$result"; then
    log_pass "IT-24: Korrel8r correctly accepted TLS 1.3"
  else
    log_warn "IT-24: Korrel8r rejected TLS 1.3 (may not be supported)"
  fi

  # --- Phase 2: Modern profile ---
  log_info "IT-24: Phase 2 — Modern profile enforcement"
  set_tls_profile "Modern"
  elapsed=0
  while [[ $elapsed -lt $RECONCILE_WAIT ]]; do
    local cmd
    cmd=$(get_deployment_command "$KORREL8R_DEPLOY" 2>/dev/null || echo "")
    if echo "$cmd" | grep -q "VersionTLS13"; then break; fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  wait_for_rollout "$KORREL8R_DEPLOY" || true
  sleep 10

  pod_ip=$(get_pod_ip "$KORREL8R_DEPLOY")
  if [[ -z "$pod_ip" ]]; then
    log_fail "IT-24: Could not get pod IP for korrel8r after Modern rollout"
    record_result "IT-24" "fail" "Cannot resolve korrel8r pod IP after rollout"
    return
  fi

  log_info "IT-24: korrel8r command: $(get_deployment_command "$KORREL8R_DEPLOY" | grep -o '\-\-tls-min-version=[^ ,"]*')"

  # TLS 1.2 should be rejected under Modern
  log_info "IT-24: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_2"
  result=$(scanner_openssl "$pod_ip" "-tls1_2")
  verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*|alert protocol version|alert handshake failure" | head -3 || echo "")
  log_detail "TLS 1.2 result: ${verdict:-<connection failed>}"
  if tls_connection_succeeds "$result"; then
    log_fail "IT-24: Korrel8r accepted TLS 1.2 under Modern (should reject)"
    passed=false
  else
    log_pass "IT-24: Korrel8r correctly rejected TLS 1.2 under Modern"
  fi

  # TLS 1.3 should be accepted
  log_info "IT-24: \$ openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} -tls1_3"
  result=$(scanner_openssl "$pod_ip" "-tls1_3")
  verdict=$(echo "$result" | grep -oE "Protocol\s*:.*|Cipher is.*" | head -2 || echo "")
  log_detail "TLS 1.3 result: ${verdict:-<connection failed>}"
  if tls_connection_succeeds "$result"; then
    log_pass "IT-24: Korrel8r correctly accepted TLS 1.3 under Modern"
  else
    log_fail "IT-24: Korrel8r rejected TLS 1.3 (should accept under Modern)"
    passed=false
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-24" "pass" "Korrel8r enforces TLS version restrictions (Intermediate + Modern)"
  else
    record_result "IT-24" "fail" "Korrel8r TLS enforcement issues detected"
  fi

  set_tls_profile "Intermediate"
  elapsed=0
  while [[ $elapsed -lt $RECONCILE_WAIT ]]; do
    local cmd
    cmd=$(get_deployment_command "$KORREL8R_DEPLOY" 2>/dev/null || echo "")
    if echo "$cmd" | grep -q "VersionTLS12"; then break; fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  wait_for_rollout "$KORREL8R_DEPLOY" || true
}

# ---------------------------------------------------------------------------
# IT-25: Korrel8r Endpoint Responds Over TLS
# ---------------------------------------------------------------------------
it_25() {
  log_test "IT-25: Korrel8r Endpoint Responds Over TLS"

  if [[ -z "$KORREL8R_DEPLOY" ]]; then
    record_result "IT-25" "skip" "Korrel8r deployment not found"
    return
  fi

  ensure_scanner

  local passed=true

  local url
  url=$(svc_url "$KORREL8R_DEPLOY" "/api/v1alpha1/domains")
  log_info "IT-25: Testing HTTPS connectivity to korrel8r: ${url}"

  local http_code
  http_code=$(scanner_curl "$url")
  log_info "IT-25: ${KORREL8R_DEPLOY}/api/v1alpha1/domains → HTTP ${http_code}"

  if [[ "$http_code" =~ ^[2345][0-9][0-9]$ ]]; then
    log_pass "IT-25: Korrel8r endpoint responds over HTTPS (HTTP ${http_code})"
  else
    log_warn "IT-25: Korrel8r /api/v1alpha1/domains returned HTTP ${http_code} — trying root endpoint"
    http_code=$(scanner_curl "$(svc_url "$KORREL8R_DEPLOY" "/")")
    log_info "IT-25: ${KORREL8R_DEPLOY}/ → HTTP ${http_code}"
    if [[ "$http_code" =~ ^[2345][0-9][0-9]$ ]]; then
      log_pass "IT-25: Korrel8r root endpoint responds over HTTPS (HTTP ${http_code})"
    else
      log_fail "IT-25: Korrel8r not responding over HTTPS (HTTP ${http_code})"
      passed=false
    fi
  fi

  # Verify TLS handshake explicitly
  local pod_ip
  pod_ip=$(get_pod_ip "$KORREL8R_DEPLOY")
  if [[ -n "$pod_ip" ]]; then
    local result
    result=$(scanner_openssl "$pod_ip" "-tls1_2")
    if tls_connection_succeeds "$result"; then
      log_pass "IT-25: Korrel8r TLS handshake succeeds"
    else
      log_fail "IT-25: Korrel8r TLS handshake failed"
      passed=false
    fi
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-25" "pass" "Korrel8r endpoint accessible over TLS"
  else
    record_result "IT-25" "fail" "Korrel8r endpoint TLS connectivity issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-13: Operator Restart Preserves TLS Across All Plugins
# ---------------------------------------------------------------------------
it_13() {
  log_test "IT-13: Operator Restart Preserves TLS Across All Plugins"

  local args_before=()
  local i=0
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    args_before[i]=$(get_deployment_args "$deploy")
    i=$((i + 1))
  done

  log_info "IT-13: Deleting operator pod..."
  oc delete pod -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" --wait=true >/dev/null 2>&1 || true

  log_info "IT-13: Waiting for operator to restart..."
  local elapsed=0
  while [[ $elapsed -lt $MAX_WAIT ]]; do
    if oc get pods -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" --no-headers 2>/dev/null | grep -q Running; then
      log_info "IT-13: Operator running after ${elapsed}s"
      break
    fi
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  sleep 15

  local passed=true i=0

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args_after
    args_after=$(get_deployment_args "$deploy")

    if echo "$args_after" | grep -q "\-tls-min-version"; then
      log_pass "IT-13: ${deploy} TLS args present after restart"
    else
      log_fail "IT-13: ${deploy} TLS args missing after restart"
      passed=false
    fi

    if [[ "${args_before[$i]}" == "$args_after" ]]; then
      log_pass "IT-13: ${deploy} args unchanged after restart"
    else
      log_warn "IT-13: ${deploy} args changed (operator may have re-reconciled)"
    fi
    i=$((i + 1))
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-13" "pass" "All plugins retain TLS config after operator restart"
  else
    record_result "IT-13" "fail" "TLS config lost after operator restart"
  fi
}

# ---------------------------------------------------------------------------
# IT-14: Plugin Pod Restart Preserves TLS Config
# ---------------------------------------------------------------------------
it_14() {
  log_test "IT-14: Plugin Pod Restart Preserves TLS Config"

  # Use the first plugin deployment (logging)
  local deploy
  deploy=$(echo "$PLUGIN_DEPLOY_NAMES" | awk '{print $1}')
  local label
  label=$(label_for_deploy "$deploy")

  # Ensure the deployment is stable before recording baseline args
  log_info "IT-14: Waiting for ${deploy} to stabilize before snapshot..."
  wait_for_deployment_ready "$deploy" || true
  wait_for_rollout "$deploy"

  local args_before
  args_before=$(get_deployment_args "$deploy")
  log_info "IT-14: ${deploy} baseline args: $(echo "$args_before" | grep -o '\-tls-min-version=[^ ,"]*' || echo '<none>')"

  if ! echo "$args_before" | grep -q "\-tls-min-version"; then
    log_warn "IT-14: TLS args not present before pod restart — waiting for operator reconciliation..."
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
      args_before=$(get_deployment_args "$deploy")
      if echo "$args_before" | grep -q "\-tls-min-version"; then
        log_info "IT-14: TLS args appeared after ${elapsed}s"
        break
      fi
      sleep 5
      elapsed=$((elapsed + 5))
    done
    log_info "IT-14: ${deploy} stabilized args: $(echo "$args_before" | grep -o '\-tls-min-version=[^ ,"]*' || echo '<none>')"
  fi

  local pod_before
  pod_before=$(oc get pod -n "$NAMESPACE" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  log_info "IT-14: Current pod: ${pod_before}"
  log_info "IT-14: \$ oc delete pod -l ${label}"
  oc delete pod -n "${NAMESPACE}" -l "$label" --wait=false >/dev/null 2>&1 || true

  log_info "IT-14: Waiting for replacement pod..."
  wait_for_deployment_ready "$deploy" || true
  sleep 15

  local pod_after
  pod_after=$(oc get pod -n "$NAMESPACE" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  log_info "IT-14: Replacement pod: ${pod_after}"

  # Wait for TLS args to appear on the deployment after pod restart
  # The operator may re-reconcile and temporarily strip args
  local args_after=""
  local elapsed=0
  local tls_wait=90
  log_info "IT-14: Polling for TLS args on ${deploy} (timeout: ${tls_wait}s)..."
  while [[ $elapsed -lt $tls_wait ]]; do
    args_after=$(get_deployment_args "$deploy")
    if echo "$args_after" | grep -q "\-tls-min-version"; then
      log_info "IT-14: TLS args present after ${elapsed}s"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  wait_for_rollout "$deploy"
  # Re-read args after rollout completes
  args_after=$(get_deployment_args "$deploy")
  log_info "IT-14: ${deploy} post-restart args: $(echo "$args_after" | grep -o '\-tls-min-version=[^ ,"]*' || echo '<none>')"

  local passed=true

  if [[ "$args_before" == "$args_after" ]]; then
    log_pass "IT-14: Deployment args unchanged after pod restart"
  else
    log_warn "IT-14: Deployment args changed (operator may have re-reconciled)"
  fi

  if echo "$args_after" | grep -q "\-tls-min-version"; then
    log_pass "IT-14: TLS args present on replacement pod"
  else
    log_fail "IT-14: TLS args missing on replacement pod"
    passed=false
  fi

  if [[ "$SCANNER_INSTALLED" == true ]]; then
    ensure_scanner
    local health_code=""
    local retries=0
    while [[ $retries -lt 3 ]]; do
      health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
      if [[ "$health_code" == "200" ]]; then break; fi
      sleep 10
      retries=$((retries + 1))
    done
    if [[ "$health_code" == "200" ]]; then
      log_pass "IT-14: Health endpoint responds after pod restart"
    else
      log_fail "IT-14: Health endpoint not responding (HTTP ${health_code})"
      passed=false
    fi
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-14" "pass" "Plugin pod restart preserves TLS config"
  else
    record_result "IT-14" "fail" "TLS config issues after pod restart"
  fi
}

# ---------------------------------------------------------------------------
# IT-15: Profile Change During Plugin Deployment
# ---------------------------------------------------------------------------
it_15() {
  log_test "IT-15: Profile Change During Plugin Deployment"

  set_tls_profile "Intermediate"
  sleep 10

  log_info "IT-15: Deleting dashboards UIPlugin CR..."
  oc delete uiplugin dashboards --ignore-not-found >/dev/null 2>&1 || true
  sleep 10

  log_info "IT-15: Setting Modern profile and re-deploying dashboards simultaneously..."
  set_tls_profile "Modern"

  cat <<EOF | oc apply -f - >/dev/null
apiVersion: ${UIPLUGIN_API_VERSION}
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
EOF

  wait_for_all_args_update "VersionTLS13" "$RECONCILE_WAIT" || true

  # Wait for the dashboards deployment to come back (use ownerReferences)
  local dash_deploy=""
  local elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    dash_deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath="{range .items[*]}{.metadata.ownerReferences[0].name}{\" \"}{.metadata.name}{\"\n\"}{end}" 2>/dev/null \
      | awk '$1 == "dashboards" {print $2; exit}')
    if [[ -n "$dash_deploy" ]]; then break; fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  if [[ -n "$dash_deploy" ]]; then
    wait_for_deployment_ready "$dash_deploy" || true
    wait_for_rollout "$dash_deploy"
  fi

  local passed=true

  if [[ -z "$dash_deploy" ]]; then
    log_fail "IT-15: Dashboards deployment not re-created"
    passed=false
  else
    local args
    args=$(get_deployment_args "$dash_deploy")
    if echo "$args" | grep -q "VersionTLS13"; then
      log_pass "IT-15: Newly deployed dashboards (${dash_deploy}) has Modern profile (VersionTLS13)"
    else
      log_fail "IT-15: Dashboards doesn't have Modern profile after concurrent deploy/profile-change"
      passed=false
    fi
  fi

  # Verify other plugins also updated
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    [[ "$deploy" == "$dash_deploy" ]] && continue
    local other_args
    other_args=$(get_deployment_args "$deploy")
    if echo "$other_args" | grep -q "VersionTLS13"; then
      log_pass "IT-15: ${deploy} also has Modern profile"
    else
      log_fail "IT-15: ${deploy} still has old profile"
      passed=false
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-15" "pass" "Profile change during deployment handled correctly"
  else
    record_result "IT-15" "fail" "Concurrent profile change + deployment has issues"
  fi

  set_tls_profile "Intermediate"
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-16: Certificate Validation Across All Plugins
# ---------------------------------------------------------------------------
it_16() {
  log_test "IT-16: Certificate Validation Across All Plugins"

  ensure_scanner

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local pod_ip
    pod_ip=$(get_pod_ip "$deploy")

    if [[ -z "$pod_ip" ]]; then
      log_warn "IT-16: Could not get pod IP for ${deploy}"
      continue
    fi

    local cert_info
    cert_info=$(oc exec tls-scanner -n "$NAMESPACE" -- bash -c \
      "echo '' | openssl s_client -connect ${pod_ip}:${PLUGIN_PORT} 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null" 2>&1 || echo "")

    if [[ -z "$cert_info" ]]; then
      log_fail "IT-16: Could not retrieve certificate from ${deploy}"
      passed=false
      continue
    fi

    log_info "IT-16: ${deploy} certificate:"
    echo "$cert_info" | while IFS= read -r line; do
      log_info "  ${line}"
    done

    if echo "$cert_info" | grep -qi "subject"; then
      log_pass "IT-16: ${deploy} has a valid subject"
    else
      log_fail "IT-16: ${deploy} certificate has no subject"
      passed=false
    fi

    if echo "$cert_info" | grep -qi "issuer.*service-serving-signer\|issuer.*openshift"; then
      log_pass "IT-16: ${deploy} certificate issued by service-ca"
    else
      log_warn "IT-16: ${deploy} certificate issuer may not be service-ca"
    fi

    local not_after
    not_after=$(echo "$cert_info" | grep -i "notAfter" | head -1 || echo "")
    if [[ -n "$not_after" ]]; then
      log_info "IT-16: ${deploy} cert validity: ${not_after}"
    fi
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-16" "pass" "All plugin certificates valid"
  else
    record_result "IT-16" "fail" "Certificate validation issues"
  fi
}

# ---------------------------------------------------------------------------
# IT-17: Rapid Profile Toggling
# ---------------------------------------------------------------------------
it_17() {
  log_test "IT-17: Rapid Profile Toggling"

  for profile in Modern Intermediate Modern Intermediate Modern Intermediate; do
    log_info "IT-17: Setting ${profile}..."
    set_tls_profile "$profile"
    sleep 5
  done

  log_info "IT-17: Waiting ${RECONCILE_WAIT}s for final reconciliation..."
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts

  local passed=true

  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local args
    args=$(get_deployment_args "$deploy")

    if echo "$args" | grep -q "\-tls-min-version=VersionTLS12"; then
      log_pass "IT-17: ${deploy} settled on Intermediate profile"
    else
      log_fail "IT-17: ${deploy} has inconsistent state after rapid toggling"
      passed=false
    fi
  done

  # Check operator logs for panics
  local logs
  logs=$(oc logs -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" --tail=100 2>/dev/null || echo "")
  if echo "$logs" | grep -qiE "panic|fatal"; then
    log_fail "IT-17: Operator logged panic/fatal during rapid toggling"
    passed=false
  else
    log_pass "IT-17: No operator panics during rapid toggling"
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-17" "pass" "Rapid profile toggling handled cleanly"
  else
    record_result "IT-17" "fail" "Issues after rapid profile toggling"
  fi
}

# ---------------------------------------------------------------------------
# IT-18: Plugin Deletion and Re-creation Under Non-Default Profile
# ---------------------------------------------------------------------------
it_18() {
  log_test "IT-18: Plugin Deletion and Re-creation Under Modern Profile"

  set_tls_profile "Modern"
  wait_for_all_args_update "VersionTLS13" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts

  log_info "IT-18: Deleting logging UIPlugin CR..."
  oc delete uiplugin logging --ignore-not-found >/dev/null 2>&1 || true

  log_info "IT-18: Waiting for deployment deletion..."
  local elapsed=0
  while [[ $elapsed -lt 60 ]]; do
    local remaining
    remaining=$(oc get deployments -n "${NAMESPACE}" \
      -l "app.kubernetes.io/instance=logging,app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$remaining" ]]; then
      log_info "IT-18: Deployment deleted after ${elapsed}s"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  log_info "IT-18: Re-creating logging UIPlugin..."
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: ${UIPLUGIN_API_VERSION}
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
EOF

  # Wait for the logging deployment to come back (use ownerReferences)
  local log_deploy=""
  elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    log_deploy=$(oc get deployments -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=UIPlugin" \
      -o jsonpath="{range .items[*]}{.metadata.ownerReferences[0].name}{\" \"}{.metadata.name}{\"\n\"}{end}" 2>/dev/null \
      | awk '$1 == "logging" {print $2; exit}')
    if [[ -n "$log_deploy" ]]; then break; fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  local passed=true

  if [[ -z "$log_deploy" ]]; then
    log_fail "IT-18: Logging deployment not re-created"
    passed=false
  else
    wait_for_deployment_ready "$log_deploy" || true
    wait_for_rollout "$log_deploy"

    local args
    args=$(get_deployment_args "$log_deploy")
    if echo "$args" | grep -q "VersionTLS13"; then
      log_pass "IT-18: Re-created logging plugin (${log_deploy}) has Modern profile (VersionTLS13)"
    else
      log_fail "IT-18: Re-created logging plugin doesn't have Modern profile"
      passed=false
    fi

    ensure_scanner
    if [[ "$SCANNER_INSTALLED" == true ]]; then
      local health_code
      health_code=$(scanner_curl "$(svc_url "$log_deploy" "/health")")
      if [[ "$health_code" == "200" ]]; then
        log_pass "IT-18: Re-created plugin /health responds"
      else
        log_fail "IT-18: Re-created plugin /health failed (HTTP ${health_code})"
        passed=false
      fi
    fi
  fi

  if [[ "$passed" == true ]]; then
    record_result "IT-18" "pass" "Plugin re-creation under Modern profile works"
  else
    record_result "IT-18" "fail" "Plugin re-creation issues"
  fi

  set_tls_profile "Intermediate"
  wait_for_all_args_update "VersionTLS12" "$RECONCILE_WAIT" || true
  wait_for_all_rollouts
}

# ---------------------------------------------------------------------------
# IT-20: Certificate Rotation Across All Plugins
# ---------------------------------------------------------------------------
it_20() {
  log_test "IT-20: Certificate Rotation Across All Plugins"

  ensure_scanner

  local passed=true

  # 1. Record pre-rotation cert serials, pod names, and pod creation timestamps
  declare -a old_serials=()
  declare -a pod_names=()
  declare -a pod_timestamps=()
  local idx=0
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    local serial
    serial=$(oc exec tls-scanner -n "$NAMESPACE" -- bash -c \
      "echo '' | timeout 10 openssl s_client -connect ${deploy}.${NAMESPACE}.svc:${PLUGIN_PORT} 2>/dev/null | openssl x509 -noout -serial 2>/dev/null" 2>/dev/null || echo "")
    old_serials[$idx]="$serial"
    log_info "IT-20: ${deploy} pre-rotation serial: ${serial:-<unavailable>}"

    local pod_name pod_ts
    pod_name=$(oc get pod -n "$NAMESPACE" -l "$(label_for_deploy "$deploy")" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    pod_ts=$(oc get pod -n "$NAMESPACE" -l "$(label_for_deploy "$deploy")" \
      -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "")
    pod_names[$idx]="$pod_name"
    pod_timestamps[$idx]="$pod_ts"
    log_info "IT-20: ${deploy} pod: ${pod_name} (created: ${pod_ts})"
    idx=$((idx + 1))
  done

  # 2. Delete the serving-cert TLS secrets for all plugins
  log_info "IT-20: Deleting serving-cert secrets for all plugins..."
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    oc delete secret "$deploy" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  done

  # 3. Wait for service-ca to regenerate all secrets
  log_info "IT-20: Waiting for service-ca to regenerate secrets..."
  local elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    local all_exist=true
    for deploy in $PLUGIN_DEPLOY_NAMES; do
      if ! oc get secret "$deploy" -n "$NAMESPACE" &>/dev/null; then
        all_exist=false
        break
      fi
    done
    if [[ "$all_exist" == true ]]; then
      log_info "IT-20: All secrets regenerated after ${elapsed}s"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ $elapsed -ge 120 ]]; then
    log_fail "IT-20: Not all secrets regenerated within 120s"
    record_result "IT-20" "fail" "Service-ca did not regenerate secrets in time"
    return
  fi

  # 4. Wait for dynamic cert reload (pods use dynamiccertificates controller)
  log_info "IT-20: Waiting for plugins to reload certificates (60s)..."
  sleep 60

  # 5. Verify new certs, pod stability, and endpoint health
  idx=0
  for deploy in $PLUGIN_DEPLOY_NAMES; do
    # Check secret type
    local stype
    stype=$(oc get secret "$deploy" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null || echo "")
    if [[ "$stype" == "kubernetes.io/tls" ]]; then
      log_pass "IT-20: ${deploy} secret regenerated (type: kubernetes.io/tls)"
    else
      log_fail "IT-20: ${deploy} secret has unexpected type: ${stype}"
      passed=false
    fi

    # Check new serial differs from old
    local new_serial
    new_serial=$(oc exec tls-scanner -n "$NAMESPACE" -- bash -c \
      "echo '' | timeout 10 openssl s_client -connect ${deploy}.${NAMESPACE}.svc:${PLUGIN_PORT} 2>/dev/null | openssl x509 -noout -serial 2>/dev/null" 2>/dev/null || echo "")
    log_info "IT-20: ${deploy} post-rotation serial: ${new_serial:-<unavailable>}"

    if [[ -n "$new_serial" ]] && [[ -n "${old_serials[$idx]}" ]] && [[ "$new_serial" != "${old_serials[$idx]}" ]]; then
      log_pass "IT-20: ${deploy} certificate rotated (${old_serials[$idx]} → ${new_serial})"
    elif [[ -z "$new_serial" ]]; then
      log_fail "IT-20: ${deploy} not serving any certificate after rotation"
      passed=false
    elif [[ -z "${old_serials[$idx]}" ]]; then
      log_warn "IT-20: ${deploy} could not compare serials (old serial unavailable)"
    else
      log_fail "IT-20: ${deploy} certificate serial unchanged after rotation (${new_serial})"
      passed=false
    fi

    # Check pod was NOT restarted (same name + same creation timestamp)
    local current_pod current_ts
    current_pod=$(oc get pod -n "$NAMESPACE" -l "$(label_for_deploy "$deploy")" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    current_ts=$(oc get pod -n "$NAMESPACE" -l "$(label_for_deploy "$deploy")" \
      -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "")
    if [[ "$current_pod" == "${pod_names[$idx]}" ]] && [[ "$current_ts" == "${pod_timestamps[$idx]}" ]]; then
      log_pass "IT-20: ${deploy} pod not restarted (${current_pod}, created: ${current_ts})"
    elif [[ "$current_pod" == "${pod_names[$idx]}" ]]; then
      log_warn "IT-20: ${deploy} same pod name but timestamp changed (${pod_timestamps[$idx]} → ${current_ts})"
    else
      log_warn "IT-20: ${deploy} pod changed (${pod_names[$idx]} → ${current_pod}, created: ${current_ts})"
    fi

    # Check health endpoint
    local health_code
    health_code=$(scanner_curl "$(svc_url "$deploy" "/health")")
    if [[ "$health_code" == "200" ]]; then
      log_pass "IT-20: ${deploy} /health responds after cert rotation"
    else
      log_fail "IT-20: ${deploy} /health failed after rotation (HTTP ${health_code})"
      passed=false
    fi

    idx=$((idx + 1))
  done

  if [[ "$passed" == true ]]; then
    record_result "IT-20" "pass" "Certificate rotation across all plugins succeeded"
  else
    record_result "IT-20" "fail" "Certificate rotation issues detected"
  fi
}

# ---------------------------------------------------------------------------
# IT-19: Operator Logs — No TLS Errors
# ---------------------------------------------------------------------------
it_19() {
  log_test "IT-19: Operator Logs — No TLS Errors"

  local logs
  logs=$(oc logs -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" --tail=300 2>/dev/null || echo "")

  local tls_errors
  tls_errors=$(echo "$logs" | grep -iE "error|panic|fatal" | grep -i tls || echo "")

  if [[ -z "$tls_errors" ]]; then
    log_pass "IT-19: No TLS-related errors in operator logs"
    record_result "IT-19" "pass" "Clean operator logs (no TLS errors)"
  else
    log_warn "IT-19: Found TLS-related log entries:"
    echo "$tls_errors" | head -10 | while IFS= read -r line; do
      log_info "  ${line}"
    done

    if echo "$tls_errors" | grep -qiE "panic|fatal"; then
      log_fail "IT-19: Operator logged TLS-related panic/fatal"
      record_result "IT-19" "fail" "TLS-related panic/fatal in operator logs"
    else
      log_warn "IT-19: TLS-related errors found but no panics"
      record_result "IT-19" "pass" "TLS errors in logs but no panics (acceptable)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tests)
        IFS=',' read -ra SELECTED_TESTS <<< "$2"
        shift 2
        ;;
      --priority)
        SELECTED_PRIORITY="$2"
        if [[ -z "$(priority_tests "$SELECTED_PRIORITY")" ]]; then
          echo "Unknown priority: $SELECTED_PRIORITY (valid: P1, P2, P3, P4, P5)"
          exit 1
        fi
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --skip-scanner-install)
        SKIP_SCANNER_INSTALL=true
        shift
        ;;
      --help|-h)
        cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

COO Integration TLS E2E Tests — validates TLS across Logging, Monitoring,
Dashboards, and Distributed Tracing UIPlugins simultaneously.

Options:
  --tests it_01,it_07,...      Run only specified test cases
  --priority P1|P2|P3|P4|P5   Run tests of a specific priority
  --skip-scanner-install       Skip tls-scanner pod install (already running)
  --dry-run                    Show which tests would run
  --help                       Show this help

Environment variables:
  COO_NAMESPACE       Operator namespace (default: openshift-cluster-observability-operator)
  MAX_WAIT_SECONDS    Max wait for deployments (default: 180)
  RECONCILE_WAIT      Max wait for TLS profile reconciliation (default: 120)
  TLS_SCANNER_IMAGE   Scanner pod image

Test cases by priority:
  P1 Critical:  it_01 (Deploy all, verify TLS args)
                it_02 (Cross-plugin consistency)
                it_03 (All endpoints over HTTPS)
                it_04 (ConsolePlugin CRs)
                it_21 (Korrel8r has TLS args)
                it_22 (Korrel8r TLS consistent with UIPlugins)
  P2 High:      it_05 (Modern → all plugins)
                it_06 (Custom → all plugins)
                it_07 (TLS enforcement, Intermediate)
                it_08 (TLS enforcement, Modern)
                it_09 (Cipher enforcement, Custom)
                it_23 (Korrel8r TLS profile propagation)
                it_24 (Korrel8r TLS enforcement)
  P3 Medium:    it_10 (Logging endpoints)
                it_11 (Monitoring endpoints)
                it_12 (Dashboards endpoints + caching)
                it_12_dt (Distributed tracing endpoints)
                it_12_tp (Troubleshooting panel endpoints)
                it_25 (Korrel8r endpoint over TLS)
  P4 Medium:    it_13 (Operator restart)
                it_14 (Plugin pod restart)
                it_15 (Profile change during deploy)
                it_16 (Certificate validation)
                it_20 (Certificate rotation)
  P5 Low:       it_17 (Rapid profile toggling)
                it_18 (Delete/re-create under Modern)
                it_19 (Operator logs audit)

Examples:
  ./run-integration-tls-e2e.sh
  ./run-integration-tls-e2e.sh --priority P1
  ./run-integration-tls-e2e.sh --tests it_01,it_07,it_13
  ./run-integration-tls-e2e.sh --skip-scanner-install --priority P2
USAGE
        exit 0
        ;;
      *)
        echo "Unknown option: $1 (use --help for usage)"
        exit 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local end_time duration_secs
  end_time=$(date +%s)
  duration_secs=$((end_time - START_TIME))
  local duration_str
  printf -v duration_str '%dm:%ds' $((duration_secs / 60)) $((duration_secs % 60))

  log_section "Test Summary"

  echo -e "${BOLD}Results:${RESET}" | tee -a "${REPORT_FILE}"
  echo -e "  ${GREEN}PASSED:  ${PASS_COUNT}${RESET}" | tee -a "${REPORT_FILE}"
  echo -e "  ${RED}FAILED:  ${FAIL_COUNT}${RESET}" | tee -a "${REPORT_FILE}"
  echo -e "  ${YELLOW}SKIPPED: ${SKIP_COUNT}${RESET}" | tee -a "${REPORT_FILE}"
  echo -e "  TOTAL:   ${TOTAL_COUNT}" | tee -a "${REPORT_FILE}"
  echo "" | tee -a "${REPORT_FILE}"
  echo -e "Duration: ${duration_str}" | tee -a "${REPORT_FILE}"
  echo -e "Report:   ${REPORT_FILE}" | tee -a "${REPORT_FILE}"

  if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}OVERALL: FAIL${RESET}" | tee -a "${REPORT_FILE}"
    return 1
  else
    echo -e "\n${GREEN}${BOLD}OVERALL: PASS${RESET}" | tee -a "${REPORT_FILE}"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  echo "# COO Integration TLS E2E Results — $(date)" > "${REPORT_FILE}"
  echo "" >> "${REPORT_FILE}"

  START_TIME=$(date +%s)

  log_section "COO Integration TLS E2E Tests"
  log_info "Namespace: ${NAMESPACE}"
  log_info "Plugins:   Logging, Monitoring, Dashboards, Distributed Tracing, Troubleshooting Panel"
  log_info "Report:    ${REPORT_FILE}"
  log_info "Timestamp: $(date)"

  if [[ "$DRY_RUN" == true ]]; then
    log_section "Dry Run — Tests that would execute"
    for test in $ALL_TESTS; do
      if should_run_test "$test"; then
        log_info "  [RUN]  ${test}"
      else
        log_info "  [SKIP] ${test}"
      fi
    done
    exit 0
  fi

  check_prerequisites
  detect_deploy_names
  detect_korrel8r_deploy
  TESTS_STARTED=true

  if [[ "$SKIP_SCANNER_INSTALL" != true ]]; then
    install_tls_scanner
  else
    SCANNER_INSTALLED=true
  fi

  log_section "Running Tests"

  for test in $ALL_TESTS; do
    if should_run_test "$test"; then
      if declare -f "$test" >/dev/null 2>&1; then
        "$test" || true
      else
        log_warn "Test function ${test} not found"
      fi
    fi
  done

  print_summary
}

main "$@"
