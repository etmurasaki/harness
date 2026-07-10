#!/usr/bin/env bash
set -eo pipefail

# =============================================================================
# OU-1326 / COO-1014: COO 1.5.0 Smoke Test — Resource Consumption Validation
# Creates cluster load (namespaces + secrets), deploys Monitoring UIPlugin with
# Perses, and validates that memory consumption stays within CSV-declared limits.
# Also validates COO-1014: memory limits increased to >=500Mi for operator and
# perses-operator pods (OOMKill fix), and detects any OOMKilled containers.
#
# Prerequisites:
#   - oc CLI logged into an OpenShift 4.13+ cluster with cluster-admin
#   - COO (Cluster Observability Operator) already installed
#
# Usage:
#   ./run-smoke-test.sh                      # Full smoke test
#   ./run-smoke-test.sh --dry-run            # Show plan without executing
#   ./run-smoke-test.sh --skip-cleanup       # Keep resources after test
#   ./run-smoke-test.sh --skip-load          # Skip namespace/secret creation
#   ./run-smoke-test.sh --skip-deploy        # Skip UIPlugin deployment (measure existing)
#   ./run-smoke-test.sh --skip-oomkill-check # Skip OOMKill detection
#   ./run-smoke-test.sh --skip-dashboards    # Skip dashboard creation
#   ./run-smoke-test.sh --cleanup-only       # Only clean up resources (dashboards, namespaces, UIPlugin)
#   ./run-smoke-test.sh --help               # Show usage
#
# Dashboard load (set DASHBOARDS_DIR to enable):
#   DASHBOARDS_DIR=/path/to/dashboards ./run-smoke-test.sh
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
readonly NUM_NS="${NUM_NAMESPACES:-100}"
readonly SECRETS_PER="${SECRETS_PER_NS:-10}"
readonly NS_PFX="${NS_PREFIX:-smoke-test-ns}"
readonly MAX_WAIT="${MAX_WAIT_SECONDS:-300}"
readonly POLL="${POLL_INTERVAL:-5}"
readonly DASH_DIR="${DASHBOARDS_DIR:-}"
readonly DASH_PER_NS="${DASHBOARDS_PER_NS:-50}"
readonly RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-2}"
readonly EXTENDED_WAIT="${EXTENDED_WAIT_SECONDS:-300}"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly REPORT_FILE="${SCRIPT_DIR}/smoke-results-${TIMESTAMP}.log"

# COO-1014: minimum expected memory limits for operator and perses-operator
readonly COO1014_MIN_LIMIT_MI=500

# State
DRY_RUN=false
SKIP_CLEANUP=false
SKIP_LOAD=false
SKIP_DEPLOY=false
SKIP_OOMKILL=false
SKIP_DASHBOARDS=false
CLEANUP_ONLY=false
UIPLUGIN_CREATED=false
PASS_COUNT=0
FAIL_COUNT=0
START_TIME=""

# CSV resource requests/limits (populated during preflight)
CSV_OPERATOR_MEM_REQUEST=""
CSV_OPERATOR_MEM_LIMIT=""
CSV_PERSES_OP_MEM_LIMIT=""

# Memory tracking across phases (baseline → post-creation → post-deletion)
BASELINE_PERSES_OP_MEM=""
BASELINE_PERSES_MEM=""
POST_DELETE_PERSES_OP_MEM=""
POST_DELETE_PERSES_MEM=""
EXTENDED_PERSES_OP_MEM=""
EXTENDED_PERSES_MEM=""
DASHBOARDS_CREATED=false

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_pass()    { echo -e "${GREEN}[PASS]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_fail()    { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${REPORT_FILE}"; }
log_section() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n" | tee -a "${REPORT_FILE}"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run            Show what would be done without executing
  --skip-cleanup       Don't delete namespaces/UIPlugin on exit
  --skip-load          Skip namespace/secret creation phase
  --skip-deploy        Skip UIPlugin deployment (measure what's already running)
  --skip-oomkill-check Skip OOMKill detection (COO-1014)
  --skip-dashboards    Skip dashboard creation phase
  --cleanup-only       Only clean up resources (dashboards, namespaces, UIPlugin) and exit
  --help               Show this help

Environment variables:
  NUM_NAMESPACES    Number of namespaces to create      (default: 100)
  SECRETS_PER_NS    Number of secrets per namespace     (default: 10)
  COO_NAMESPACE     Operator namespace                  (default: openshift-observability-operator)
  NS_PREFIX         Namespace name prefix               (default: smoke-test-ns)
  MAX_WAIT_SECONDS  Timeout for deployment readiness    (default: 300)
  POLL_INTERVAL     Polling interval in seconds         (default: 5)
  DASHBOARDS_DIR    Path to sample PersesDashboard YAMLs (required for dashboard load)
  DASHBOARDS_PER_NS Target dashboards per namespace     (default: 50)
  RECOVERY_THRESHOLD Post-deletion memory recovery factor (default: 2, meaning ≤2x baseline)
  EXTENDED_WAIT_SECONDS Extended wait after deletion for GC (default: 300)
USAGE
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)       DRY_RUN=true ;;
      --skip-cleanup)  SKIP_CLEANUP=true ;;
      --skip-load)     SKIP_LOAD=true ;;
      --skip-deploy)   SKIP_DEPLOY=true ;;
      --skip-oomkill-check) SKIP_OOMKILL=true ;;
      --skip-dashboards) SKIP_DASHBOARDS=true ;;
      --cleanup-only)  CLEANUP_ONLY=true ;;
      --help|-h)       usage ;;
      *) log_warn "Unknown option: $1" ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
wait_for_deployment_ready() {
  local deploy_name="$1" ns="${2:-$NAMESPACE}" timeout="${3:-$MAX_WAIT}"
  local elapsed=0
  log_info "Waiting for deployment/${deploy_name} in ${ns} (timeout: ${timeout}s)"
  while [[ $elapsed -lt $timeout ]]; do
    if oc wait --for=condition=Available "deployment/${deploy_name}" \
         -n "${ns}" --timeout=5s &>/dev/null; then
      log_info "deployment/${deploy_name} is ready (${elapsed}s)"
      return 0
    fi
    sleep "${POLL}"
    elapsed=$((elapsed + POLL))
  done
  log_fail "deployment/${deploy_name} not ready after ${timeout}s"
  return 1
}

# Convert memory string (e.g., "128Mi", "1Gi", "256000Ki") to MiB integer
mem_to_mib() {
  local val="$1"
  if [[ "$val" =~ ^([0-9]+)Gi$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$val" =~ ^([0-9]+)Mi$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$val" =~ ^([0-9]+)Ki$ ]]; then
    echo $(( ${BASH_REMATCH[1]} / 1024 ))
  elif [[ "$val" =~ ^([0-9]+)$ ]]; then
    echo $(( val / 1048576 ))
  else
    echo "0"
  fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  log_section "Cleanup"
  if $SKIP_CLEANUP; then
    log_warn "Skipping cleanup (--skip-cleanup). Resources remain on cluster."
    return
  fi

  cleanup_dashboards

  if $UIPLUGIN_CREATED; then
    log_info "Deleting UIPlugin/monitoring ..."
    oc delete uiplugin monitoring --ignore-not-found=true 2>/dev/null || true
  fi

  log_info "Deleting smoke-test namespaces (prefix: ${NS_PFX}) ..."
  local ns_list
  ns_list="$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  local to_delete=""
  for ns in $ns_list; do
    if [[ "$ns" == "${NS_PFX}-"* ]]; then
      to_delete="${to_delete} ${ns}"
    fi
  done
  if [[ -n "$to_delete" ]]; then
    # shellcheck disable=SC2086
    oc delete namespace $to_delete --wait=false 2>/dev/null || true
    log_info "Namespace deletion initiated for $(echo $to_delete | wc -w | tr -d ' ') namespaces"
  else
    log_info "No smoke-test namespaces found to delete"
  fi

  if [[ -n "$START_TIME" ]]; then
    local duration=$(( $(date +%s) - START_TIME ))
    log_info "Total duration: ${duration}s"
  fi
}

cleanup_dashboards() {
  log_info "Cleaning up PersesDashboard CRs in smoke-test namespaces ..."

  local ns_list
  ns_list="$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

  local cleaned=0 total_deleted=0
  for ns in $ns_list; do
    [[ "$ns" != "${NS_PFX}-"* ]] && continue

    local dashboards
    dashboards="$(oc get persesdashboards -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [[ -z "$dashboards" ]]; then
      cleaned=$((cleaned + 1))
      continue
    fi

    local count
    count="$(echo "$dashboards" | wc -w | tr -d ' ')"
    # shellcheck disable=SC2086
    if oc delete persesdashboards --all -n "$ns" --wait=false 2>/dev/null; then
      total_deleted=$((total_deleted + count))
    else
      log_warn "Failed to delete dashboards in ${ns}"
    fi

    cleaned=$((cleaned + 1))
    if (( cleaned % 10 == 0 )); then
      log_info "Dashboard cleanup progress: ${cleaned} namespaces processed (${total_deleted} dashboards deleted)"
    fi
  done

  if [[ "$total_deleted" -gt 0 ]]; then
    log_info "Dashboard cleanup complete: ${total_deleted} PersesDashboard CRs deleted across ${cleaned} namespaces"
  else
    log_info "No PersesDashboard CRs found in smoke-test namespaces"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  log_section "Preflight Checks"

  if ! command -v oc &>/dev/null; then
    log_fail "oc CLI not found in PATH"
    exit 1
  fi

  local user
  user="$(oc whoami 2>/dev/null || true)"
  if [[ -z "$user" ]]; then
    log_fail "Not logged into an OpenShift cluster (oc whoami failed)"
    exit 1
  fi
  log_info "Logged in as: ${user}"

  if ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
    log_fail "CRD uiplugins.observability.openshift.io not found — is COO installed?"
    exit 1
  fi
  log_info "COO CRD found"

  local operator_pods
  operator_pods="$(oc get pods -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" \
    --no-headers 2>/dev/null | grep -c Running || true)"
  if [[ "$operator_pods" -eq 0 ]]; then
    log_fail "No running operator pods in ${NAMESPACE}"
    exit 1
  fi
  log_info "Operator pods running: ${operator_pods}"

  log_info "Extracting CSV resource requests ..."
  local csv_name
  csv_name="$(oc get csv -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$csv_name" ]]; then
    log_warn "Could not find CSV in ${NAMESPACE} — will skip resource comparison"
    return
  fi
  log_info "CSV: ${csv_name}"

  local csv_deployments
  csv_deployments="$(oc get csv "${csv_name}" -n "${NAMESPACE}" \
    -o jsonpath='{range .spec.install.spec.deployments[*]}{.name}{"\t"}{range .spec.template.spec.containers[*]}{.name}{"\t"}{.resources.requests.memory}{"\t"}{.resources.limits.memory}{"\n"}{end}{end}' 2>/dev/null || true)"

  if [[ -n "$csv_deployments" ]]; then
    log_info "CSV resource requests/limits (memory):"
    while IFS=$'\t' read -r deploy container mem_req mem_lim; do
      [[ -z "$deploy" ]] && continue
      echo "  ${deploy}/${container}: request=${mem_req:-not set} limit=${mem_lim:-not set}" | tee -a "${REPORT_FILE}"
      case "$deploy" in
        *observability-operator*)
          CSV_OPERATOR_MEM_REQUEST="${mem_req}"
          CSV_OPERATOR_MEM_LIMIT="${mem_lim}"
          ;;
        *perses-operator*)
          CSV_PERSES_OP_MEM_LIMIT="${mem_lim}"
          ;;
      esac
    done <<< "$csv_deployments"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: Create namespaces and secrets
# ---------------------------------------------------------------------------
phase_create_load() {
  log_section "Phase 1: Create Cluster Load (${NUM_NS} namespaces, ${SECRETS_PER} secrets each)"

  if $SKIP_LOAD; then
    log_info "Skipping load creation (--skip-load)"
    return
  fi

  local created=0
  for i in $(seq 1 "$NUM_NS"); do
    local ns_name
    ns_name="$(printf '%s-%03d' "${NS_PFX}" "$i")"

    oc create namespace "${ns_name}" --dry-run=client -o yaml | oc apply -f - &>/dev/null

    for s in $(seq 1 "$SECRETS_PER"); do
      oc create secret generic "secret-${s}" \
        --from-literal="key-${s}=value-${s}-$(head -c 32 /dev/urandom | base64)" \
        -n "${ns_name}" --dry-run=client -o yaml | oc apply -f - &>/dev/null
    done

    cat <<PODEOF | oc apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: log-generator
  namespace: ${ns_name}
  labels:
    app: smoke-test
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: logger
    image: registry.access.redhat.com/ubi9-minimal:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      seq=0
      while true; do
        seq=\$((seq + 1))
        echo "\$(date -Iseconds) [${ns_name}] heartbeat seq=\${seq} pod=log-generator"
        sleep 30
      done
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    resources:
      requests:
        cpu: 1m
        memory: 8Mi
      limits:
        cpu: 5m
        memory: 16Mi
  restartPolicy: Always
PODEOF

    created=$((created + 1))
    if (( created % 10 == 0 )); then
      log_info "Progress: ${created}/${NUM_NS} namespaces created"
    fi
  done

  log_info "Load creation complete: ${created} namespaces, $((created * SECRETS_PER)) secrets, ${created} log-generator pods"
}

# ---------------------------------------------------------------------------
# Phase 2: Baseline measurement
# ---------------------------------------------------------------------------
phase_baseline() {
  log_section "Phase 2: Baseline Measurement"

  log_info "Node resource usage:"
  oc adm top nodes 2>/dev/null | tee -a "${REPORT_FILE}" || log_warn "oc adm top nodes failed (metrics-server may not be ready)"

  echo "" | tee -a "${REPORT_FILE}"
  log_info "Pod resource usage in ${NAMESPACE} (before UIPlugin):"
  oc adm top pods -n "${NAMESPACE}" 2>/dev/null | tee -a "${REPORT_FILE}" || log_warn "oc adm top pods failed"

  BASELINE_PERSES_OP_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep perses-operator | awk '{print $3}' | head -1 || true)"
  BASELINE_PERSES_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E '^perses-[0-9]' | awk '{print $3}' | head -1 || true)"
  log_info "Baseline perses-operator memory: ${BASELINE_PERSES_OP_MEM:-N/A}"
  log_info "Baseline perses server memory: ${BASELINE_PERSES_MEM:-N/A}"
}

# ---------------------------------------------------------------------------
# Phase 3: Deploy Monitoring UIPlugin with Perses
# ---------------------------------------------------------------------------
phase_deploy_uiplugin() {
  log_section "Phase 3: Deploy Monitoring UIPlugin (Perses enabled)"

  if $SKIP_DEPLOY; then
    log_info "Skipping UIPlugin deployment (--skip-deploy) — measuring existing pods"
    return
  fi

  cat <<EOF | oc apply -f -
apiVersion: ${UIPLUGIN_API_VERSION}
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF

  UIPLUGIN_CREATED=true
  log_info "UIPlugin/monitoring created"

  # Wait for monitoring console plugin deployment
  wait_for_deployment_ready "monitoring"

  # Wait for Perses-related pods
  log_info "Waiting for Perses pods ..."
  local elapsed=0
  while [[ $elapsed -lt $MAX_WAIT ]]; do
    local perses_pods
    perses_pods="$(oc get pods -n "${NAMESPACE}" -l 'app.kubernetes.io/part-of=Perses' \
      --no-headers 2>/dev/null | grep -c Running || true)"
    if [[ "$perses_pods" -gt 0 ]]; then
      log_info "Perses pods running: ${perses_pods} (${elapsed}s)"
      break
    fi

    # Also check for perses-related deployments by name
    local perses_deploy
    perses_deploy="$(oc get deployments -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -i perses | head -1 | awk '{print $1}' || true)"
    if [[ -n "$perses_deploy" ]]; then
      if oc wait --for=condition=Available "deployment/${perses_deploy}" \
           -n "${NAMESPACE}" --timeout=5s &>/dev/null; then
        log_info "Perses deployment ${perses_deploy} is ready (${elapsed}s)"
        break
      fi
    fi

    sleep "${POLL}"
    elapsed=$((elapsed + POLL))
  done

  if [[ $elapsed -ge $MAX_WAIT ]]; then
    log_warn "Perses pods may not be fully ready after ${MAX_WAIT}s — continuing with measurement"
  fi

  # Allow pods to stabilize
  log_info "Waiting 30s for resource usage to stabilize ..."
  sleep 30
}

# ---------------------------------------------------------------------------
# Phase 4: Create PersesDashboard load
# ---------------------------------------------------------------------------
phase_create_dashboards() {
  log_section "Phase 4: Create PersesDashboard Load"

  if $SKIP_DASHBOARDS; then
    log_info "Skipping dashboard creation (--skip-dashboards)"
    return
  fi

  if [[ -z "$DASH_DIR" ]]; then
    log_info "Skipping dashboard creation (DASHBOARDS_DIR not set)"
    return
  fi

  if [[ ! -d "$DASH_DIR" ]]; then
    log_fail "DASHBOARDS_DIR does not exist: ${DASH_DIR}"
    return
  fi

  # Discover PersesDashboard template files
  local templates=()
  local template_names=()
  for f in "${DASH_DIR}"/*.yaml; do
    [[ ! -f "$f" ]] && continue
    local kind
    kind="$(grep -m1 '^kind:' "$f" | awk '{print $2}' || true)"
    if [[ "$kind" == "PersesDashboard" ]]; then
      local dash_name
      dash_name="$(grep -A1 '^metadata:' "$f" | grep 'name:' | head -1 | awk '{print $2}' || true)"
      if [[ -n "$dash_name" ]]; then
        templates+=("$f")
        template_names+=("$dash_name")
      fi
    fi
  done

  local num_templates=${#templates[@]}
  if [[ "$num_templates" -eq 0 ]]; then
    log_fail "No PersesDashboard YAML files found in ${DASH_DIR}"
    return
  fi

  # Calculate variants per template to reach DASH_PER_NS
  local variants_per=$(( (DASH_PER_NS + num_templates - 1) / num_templates ))
  local total_per_ns=$(( num_templates * variants_per ))
  log_info "Templates found: ${num_templates} ($(printf '%s ' "${template_names[@]}"))"
  log_info "Variants per template: ${variants_per} → ${total_per_ns} dashboards per namespace"
  log_info "Total dashboards: ${total_per_ns} × ${NUM_NS} = $(( total_per_ns * NUM_NS ))"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf ${tmpdir}" RETURN

  local ns_created=0
  for i in $(seq 1 "$NUM_NS"); do
    local ns_name
    ns_name="$(printf '%s-%03d' "${NS_PFX}" "$i")"
    local combined="${tmpdir}/dashboards-${ns_name}.yaml"
    : > "$combined"

    for t_idx in $(seq 0 $(( num_templates - 1 ))); do
      local tpl="${templates[$t_idx]}"
      local base_name="${template_names[$t_idx]}"
      for v in $(seq 1 "$variants_per"); do
        local vname
        vname="$(printf '%s-%02d' "${base_name}" "$v")"
        # Replace metadata name and namespace, append as YAML document
        echo "---" >> "$combined"
        sed -e "s/^  name: ${base_name}/  name: ${vname}/" \
            -e "s/^  namespace: .*/  namespace: ${ns_name}/" \
            "$tpl" >> "$combined"
      done
    done

    if ! oc apply -f "$combined" 2>/dev/null; then
      log_warn "Failed to apply dashboards in ${ns_name}"
    fi

    ns_created=$((ns_created + 1))
    if (( ns_created % 10 == 0 )); then
      log_info "Progress: ${ns_created}/${NUM_NS} namespaces ($(( ns_created * total_per_ns )) dashboards)"
    fi
  done

  log_info "Dashboard creation complete: ${ns_created} namespaces × ${total_per_ns} = $(( ns_created * total_per_ns )) dashboards"
  DASHBOARDS_CREATED=true
}

# ---------------------------------------------------------------------------
# Phase 5: Resource measurement
# ---------------------------------------------------------------------------
phase_measure() {
  log_section "Phase 5: Resource Measurement (post-deployment)"

  log_info "Node resource usage (after deployment):"
  oc adm top nodes 2>/dev/null | tee -a "${REPORT_FILE}" || log_warn "oc adm top nodes failed"

  echo "" | tee -a "${REPORT_FILE}"
  log_info "Pod resource usage in ${NAMESPACE}:"
  oc adm top pods -n "${NAMESPACE}" 2>/dev/null | tee -a "${REPORT_FILE}" || log_warn "oc adm top pods failed"

  echo "" | tee -a "${REPORT_FILE}"
  log_info "Detailed pod resource breakdown:"

  # Operator pod
  local operator_mem
  operator_mem="$(oc adm top pods -n "${NAMESPACE}" -l "${OPERATOR_LABEL}" \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1 || true)"
  log_info "  Operator memory: ${operator_mem:-N/A}"

  # Monitoring console plugin
  local plugin_mem
  plugin_mem="$(oc adm top pods -n "${NAMESPACE}" -l 'app.kubernetes.io/instance=monitoring,app.kubernetes.io/part-of=UIPlugin' \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [[ -z "$plugin_mem" ]]; then
    plugin_mem="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | grep -E '^monitoring-' | grep -v operator | awk '{print $3}' | head -1 || true)"
  fi
  log_info "  Monitoring plugin memory: ${plugin_mem:-N/A}"

  # Perses server (StatefulSet pod perses-0)
  local perses_mem
  perses_mem="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E '^perses-[0-9]' | awk '{print $3}' | head -1 || true)"
  log_info "  Perses server (perses-0) memory: ${perses_mem:-N/A}"

  # Perses operator
  local perses_op_mem
  perses_op_mem="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep perses-operator | awk '{print $3}' | head -1 || true)"
  log_info "  Perses operator memory: ${perses_op_mem:-N/A}"

  # Export for comparison phase
  ACTUAL_OPERATOR_MEM="$operator_mem"
  ACTUAL_PLUGIN_MEM="$plugin_mem"
  ACTUAL_PERSES_MEM="$perses_mem"
  ACTUAL_PERSES_OP_MEM="$perses_op_mem"
}

# ---------------------------------------------------------------------------
# Phase 5b: Memory Recovery After Dashboard Deletion (PR #414 validation)
# ---------------------------------------------------------------------------
phase_delete_dashboards_and_remeasure() {
  log_section "Phase 5b: Memory Recovery After Dashboard Deletion"

  if ! $DASHBOARDS_CREATED; then
    log_info "Skipping memory recovery check (no dashboards were created)"
    return
  fi

  log_info "Post-creation memory: perses-operator=${ACTUAL_PERSES_OP_MEM:-N/A}, perses server=${ACTUAL_PERSES_MEM:-N/A}"

  log_info "Deleting all PersesDashboard CRs ..."
  cleanup_dashboards

  log_info "Waiting 60s for reconciliation and GC ..."
  sleep 60

  log_info "Re-measuring memory after dashboard deletion ..."
  POST_DELETE_PERSES_OP_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep perses-operator | awk '{print $3}' | head -1 || true)"
  POST_DELETE_PERSES_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E '^perses-[0-9]' | awk '{print $3}' | head -1 || true)"

  log_info "Post-deletion memory (60s): perses-operator=${POST_DELETE_PERSES_OP_MEM:-N/A}, perses server=${POST_DELETE_PERSES_MEM:-N/A}"

  log_info "Waiting ${EXTENDED_WAIT}s for extended GC and stabilization ..."
  sleep "${EXTENDED_WAIT}"

  log_info "Re-measuring memory after extended wait ..."
  EXTENDED_PERSES_OP_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep perses-operator | awk '{print $3}' | head -1 || true)"
  EXTENDED_PERSES_MEM="$(oc adm top pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -E '^perses-[0-9]' | awk '{print $3}' | head -1 || true)"

  log_info "Post-deletion memory (extended): perses-operator=${EXTENDED_PERSES_OP_MEM:-N/A}, perses server=${EXTENDED_PERSES_MEM:-N/A}"

  echo "" | tee -a "${REPORT_FILE}"
  log_info "Memory lifecycle (perses-operator):"
  printf "  %-20s %s\n" "Baseline:" "${BASELINE_PERSES_OP_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-creation:" "${ACTUAL_PERSES_OP_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-deletion (60s):" "${POST_DELETE_PERSES_OP_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-deletion (ext):" "${EXTENDED_PERSES_OP_MEM:-N/A}" | tee -a "${REPORT_FILE}"

  echo "" | tee -a "${REPORT_FILE}"
  log_info "Memory lifecycle (perses server):"
  printf "  %-20s %s\n" "Baseline:" "${BASELINE_PERSES_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-creation:" "${ACTUAL_PERSES_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-deletion (60s):" "${POST_DELETE_PERSES_MEM:-N/A}" | tee -a "${REPORT_FILE}"
  printf "  %-20s %s\n" "Post-deletion (ext):" "${EXTENDED_PERSES_MEM:-N/A}" | tee -a "${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# Phase 6: OOMKill Detection (COO-1014)
# ---------------------------------------------------------------------------
phase_check_oomkill() {
  log_section "Phase 6: OOMKill Detection (COO-1014)"

  if $SKIP_OOMKILL; then
    log_info "Skipping OOMKill detection (--skip-oomkill-check)"
    return
  fi

  log_info "Checking for OOMKilled containers in ${NAMESPACE} ..."

  local oomkill_found=false
  local pod_json
  pod_json="$(oc get pods -n "${NAMESPACE}" -o json 2>/dev/null || true)"

  if [[ -z "$pod_json" ]]; then
    log_warn "Could not retrieve pod data — skipping OOMKill check"
    return
  fi

  local oomkill_details
  oomkill_details="$(echo "$pod_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for pod in data.get("items", []):
    pod_name = pod["metadata"]["name"]
    for cs in pod.get("status", {}).get("containerStatuses", []):
        container = cs["name"]
        restart_count = cs.get("restartCount", 0)
        last_state = cs.get("lastState", {})
        terminated = last_state.get("terminated", {})
        reason = terminated.get("reason", "")
        if reason == "OOMKilled":
            finished = terminated.get("finishedAt", "unknown")
            print(f"{pod_name}\t{container}\t{restart_count}\t{finished}")
' 2>/dev/null || true)"

  if [[ -n "$oomkill_details" ]]; then
    oomkill_found=true
    log_fail "[COO-1014] OOMKilled containers detected:"
    printf "  %-40s %-25s %-10s %s\n" "Pod" "Container" "Restarts" "Last OOMKill" | tee -a "${REPORT_FILE}"
    while IFS=$'\t' read -r pod container restarts finished; do
      printf "  %-40s %-25s %-10s %s\n" "$pod" "$container" "$restarts" "$finished" | tee -a "${REPORT_FILE}"
    done <<< "$oomkill_details"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  if ! $oomkill_found; then
    log_pass "[COO-1014] No OOMKilled containers found in ${NAMESPACE}"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# Phase 7: Comparison and verdict
# ---------------------------------------------------------------------------
phase_compare() {
  log_section "Phase 7: Resource Comparison"

  # Get resource requests AND limits from running deployments
  log_info "Fetching resource requests/limits from running deployments ..."

  local deploy_resources
  deploy_resources="$(oc get deployments -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.resources.requests.memory}{"\t"}{.resources.limits.memory}{"\t"}{end}{"\n"}{end}' 2>/dev/null || true)"

  local operator_req="" plugin_req="" perses_op_req=""
  local operator_lim="" plugin_lim="" perses_op_lim=""
  while IFS=$'\t' read -r name mem_req mem_lim _rest; do
    [[ -z "$name" ]] && continue
    case "$name" in
      *observability-operator*)
        operator_req="$mem_req"
        operator_lim="$mem_lim"
        ;;
      monitoring)
        plugin_req="$mem_req"
        plugin_lim="$mem_lim"
        ;;
      perses-operator*)
        perses_op_req="$mem_req"
        perses_op_lim="$mem_lim"
        ;;
    esac
  done <<< "$deploy_resources"

  # Perses server runs as a StatefulSet, not a Deployment
  local perses_req="" perses_lim=""
  local sts_resources
  sts_resources="$(oc get statefulsets -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.resources.requests.memory}{"\t"}{.resources.limits.memory}{"\t"}{end}{"\n"}{end}' 2>/dev/null || true)"
  while IFS=$'\t' read -r name mem_req mem_lim _rest; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "perses" ]]; then
      perses_req="$mem_req"
      perses_lim="$mem_lim"
    fi
  done <<< "$sts_resources"

  # Use CSV values as fallback
  if [[ -z "$operator_req" && -n "$CSV_OPERATOR_MEM_REQUEST" ]]; then
    operator_req="$CSV_OPERATOR_MEM_REQUEST"
  fi
  if [[ -z "$operator_lim" && -n "$CSV_OPERATOR_MEM_LIMIT" ]]; then
    operator_lim="$CSV_OPERATOR_MEM_LIMIT"
  fi
  if [[ -z "$perses_op_lim" && -n "$CSV_PERSES_OP_MEM_LIMIT" ]]; then
    perses_op_lim="$CSV_PERSES_OP_MEM_LIMIT"
  fi

  # --- COO-1014: Limit adequacy check ---
  log_section "COO-1014: Memory Limit Adequacy Check (minimum ${COO1014_MIN_LIMIT_MI}Mi)"

  check_limit_adequacy "Observability Operator" "$operator_lim"
  check_limit_adequacy "Perses Operator" "$perses_op_lim"

  # --- Per-component resource comparison ---
  echo "" | tee -a "${REPORT_FILE}"
  log_section "Resource Comparison (actual vs request vs limit)"

  printf "${BOLD}%-30s %-12s %-12s %-12s %-10s${RESET}\n" "Component" "Actual" "Request" "Limit" "Status" | tee -a "${REPORT_FILE}"
  printf "%-30s %-12s %-12s %-12s %-10s\n" "---" "---" "---" "---" "---" | tee -a "${REPORT_FILE}"

  compare_component "Observability Operator" "${ACTUAL_OPERATOR_MEM}" "${operator_req}" "${operator_lim}"
  compare_component "Monitoring Console Plugin" "${ACTUAL_PLUGIN_MEM}" "${plugin_req}" "${plugin_lim}"
  compare_component "Perses Server" "${ACTUAL_PERSES_MEM}" "${perses_req}" "${perses_lim}"
  compare_component "Perses Operator" "${ACTUAL_PERSES_OP_MEM}" "${perses_op_req}" "${perses_op_lim}"

  # --- Memory recovery check (PR #414 validation) ---
  if $DASHBOARDS_CREATED && [[ -n "$POST_DELETE_PERSES_OP_MEM" && -n "$BASELINE_PERSES_OP_MEM" ]]; then
    echo "" | tee -a "${REPORT_FILE}"
    log_section "Memory Recovery Check (perses-operator)"

    local baseline_mib post_delete_mib extended_mib best_mib best_label threshold_mib
    baseline_mib="$(mem_to_mib "$BASELINE_PERSES_OP_MEM")"
    post_delete_mib="$(mem_to_mib "$POST_DELETE_PERSES_OP_MEM")"
    extended_mib="$(mem_to_mib "${EXTENDED_PERSES_OP_MEM:-0}")"
    threshold_mib=$(( baseline_mib * RECOVERY_THRESHOLD ))

    # Use the lower of the two post-deletion readings
    if [[ "$extended_mib" -gt 0 && "$extended_mib" -le "$post_delete_mib" ]]; then
      best_mib="$extended_mib"
      best_label="extended (${EXTENDED_WAIT}s)"
    else
      best_mib="$post_delete_mib"
      best_label="initial (60s)"
    fi

    if [[ "$baseline_mib" -gt 0 ]]; then
      printf "  %-25s %-12s (%sMi)\n" "Baseline:" "$BASELINE_PERSES_OP_MEM" "$baseline_mib" | tee -a "${REPORT_FILE}"
      printf "  %-25s %-12s (%sMi)\n" "Post-creation:" "${ACTUAL_PERSES_OP_MEM:-N/A}" "$(mem_to_mib "${ACTUAL_PERSES_OP_MEM:-0}")" | tee -a "${REPORT_FILE}"
      printf "  %-25s %-12s (%sMi)\n" "Post-deletion (60s):" "$POST_DELETE_PERSES_OP_MEM" "$post_delete_mib" | tee -a "${REPORT_FILE}"
      printf "  %-25s %-12s (%sMi)\n" "Post-deletion (extended):" "${EXTENDED_PERSES_OP_MEM:-N/A}" "$extended_mib" | tee -a "${REPORT_FILE}"
      printf "  %-25s %sMi (baseline × %s)\n" "Threshold:" "$threshold_mib" "$RECOVERY_THRESHOLD" | tee -a "${REPORT_FILE}"
      printf "  %-25s %sMi (%s)\n" "Best reading:" "$best_mib" "$best_label" | tee -a "${REPORT_FILE}"

      if [[ "$best_mib" -le "$threshold_mib" ]]; then
        log_pass "[PR#414] perses-operator memory recovered: ${best_mib}Mi <= ${threshold_mib}Mi threshold (${best_label})"
        PASS_COUNT=$((PASS_COUNT + 1))
      else
        log_fail "[PR#414] perses-operator memory NOT recovered: ${best_mib}Mi > ${threshold_mib}Mi threshold (leak detected)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    else
      log_warn "[PR#414] Cannot evaluate memory recovery — baseline is 0Mi"
    fi
  fi

  echo "" | tee -a "${REPORT_FILE}"
  log_section "Summary"
  log_info "Pass: ${PASS_COUNT}  Fail: ${FAIL_COUNT}"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    log_fail "SMOKE TEST FAILED — ${FAIL_COUNT} check(s) failed"
    return 1
  else
    log_pass "SMOKE TEST PASSED — all checks passed"
    return 0
  fi
}

check_limit_adequacy() {
  local name="$1" limit="$2"

  if [[ -z "$limit" ]]; then
    log_warn "[COO-1014] ${name}: memory limit not set — cannot verify adequacy"
    return
  fi

  local limit_mib
  limit_mib="$(mem_to_mib "$limit")"

  if [[ "$limit_mib" -ge "$COO1014_MIN_LIMIT_MI" ]]; then
    log_pass "[COO-1014] ${name}: memory limit ${limit} (${limit_mib}Mi) >= ${COO1014_MIN_LIMIT_MI}Mi"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    log_fail "[COO-1014] ${name}: memory limit ${limit} (${limit_mib}Mi) < ${COO1014_MIN_LIMIT_MI}Mi — OOMKill risk"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

compare_component() {
  local name="$1" actual="$2" requested="$3" limit="${4:-}"

  if [[ -z "$actual" || "$actual" == "N/A" ]]; then
    printf "%-30s %-12s %-12s %-12s %-10s\n" "$name" "N/A" "${requested:-N/A}" "${limit:-N/A}" "SKIP" | tee -a "${REPORT_FILE}"
    return
  fi
  if [[ -z "$requested" ]]; then
    printf "%-30s %-12s %-12s %-12s %-10s\n" "$name" "$actual" "N/A" "${limit:-N/A}" "SKIP" | tee -a "${REPORT_FILE}"
    return
  fi

  local actual_mib requested_mib status
  actual_mib="$(mem_to_mib "$actual")"
  requested_mib="$(mem_to_mib "$requested")"

  if [[ "$actual_mib" -le "$requested_mib" ]]; then
    status="PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    status="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # Secondary check: warn if actual exceeds limit (OOMKill territory)
  if [[ -n "$limit" && "$status" == "PASS" ]]; then
    local limit_mib
    limit_mib="$(mem_to_mib "$limit")"
    if [[ "$actual_mib" -gt "$limit_mib" ]]; then
      status="FAIL"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      PASS_COUNT=$((PASS_COUNT - 1))
    fi
  fi

  local color="$GREEN"
  [[ "$status" == "FAIL" ]] && color="$RED"
  printf "%-30s %-12s %-12s %-12s ${color}%-10s${RESET}\n" "$name" "$actual" "$requested" "${limit:-N/A}" "$status" | tee -a "${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
dry_run_summary() {
  log_section "Dry Run — Planned Actions"
  log_info "1. Preflight: verify oc, COO CRD, operator pods, extract CSV requests+limits"
  if ! $SKIP_LOAD; then
    log_info "2. Create ${NUM_NS} namespaces (prefix: ${NS_PFX}) with ${SECRETS_PER} secrets each"
  else
    log_info "2. [SKIPPED] Namespace/secret creation"
  fi
  log_info "3. Baseline: capture node + pod memory via oc adm top"
  if ! $SKIP_DEPLOY; then
    log_info "4. Deploy UIPlugin/monitoring (type: Monitoring, Perses enabled)"
    log_info "   Wait for monitoring + Perses deployments"
  else
    log_info "4. [SKIPPED] UIPlugin deployment (--skip-deploy)"
  fi
  if ! $SKIP_DASHBOARDS && [[ -n "$DASH_DIR" ]]; then
    log_info "5. Create ~${DASH_PER_NS} PersesDashboard CRs per namespace from ${DASH_DIR}"
  else
    log_info "5. [SKIPPED] Dashboard creation (--skip-dashboards or DASHBOARDS_DIR not set)"
  fi
  log_info "6. Measure pod memory in ${NAMESPACE}"
  if ! $SKIP_DASHBOARDS && [[ -n "$DASH_DIR" ]]; then
    log_info "6b. Delete dashboards, wait 60s + ${EXTENDED_WAIT}s, re-measure memory (PR#414 leak validation)"
  else
    log_info "6b. [SKIPPED] Memory recovery check (no dashboards)"
  fi
  if ! $SKIP_OOMKILL; then
    log_info "7. [COO-1014] Check for OOMKilled containers in ${NAMESPACE}"
  else
    log_info "7. [SKIPPED] OOMKill detection (--skip-oomkill-check)"
  fi
  log_info "8. [COO-1014] Verify memory limits >= ${COO1014_MIN_LIMIT_MI}Mi for operator + perses-operator"
  log_info "9. Compare actual vs declared resource requests and limits"
  if $SKIP_CLEANUP; then
    log_info "10. [SKIPPED] Cleanup"
  else
    log_info "10. Cleanup: delete UIPlugin, delete ${NS_PFX}-* namespaces"
  fi
  log_info ""
  log_info "Config: NUM_NAMESPACES=${NUM_NS} SECRETS_PER_NS=${SECRETS_PER} NAMESPACE=${NAMESPACE}"
  log_info "        DASHBOARDS_DIR=${DASH_DIR:-<not set>} DASHBOARDS_PER_NS=${DASH_PER_NS} EXTENDED_WAIT=${EXTENDED_WAIT}s"
  log_info "COO-1014: min memory limit=${COO1014_MIN_LIMIT_MI}Mi"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  START_TIME="$(date +%s)"

  log_section "COO 1.5.0 Smoke Test — Resource Consumption + COO-1014 Validation"
  log_info "Report: ${REPORT_FILE}"
  log_info "Started: $(date)"

  if $DRY_RUN; then
    dry_run_summary
    exit 0
  fi

  if $CLEANUP_ONLY; then
    log_info "Running cleanup only ..."
    SKIP_CLEANUP=false
    UIPLUGIN_CREATED=true
    cleanup
    exit 0
  fi

  trap cleanup EXIT

  preflight
  phase_create_load
  phase_baseline
  phase_deploy_uiplugin
  phase_create_dashboards
  phase_measure
  phase_delete_dashboards_and_remeasure
  phase_check_oomkill

  local exit_code=0
  phase_compare || exit_code=$?

  exit "$exit_code"
}

main "$@"
