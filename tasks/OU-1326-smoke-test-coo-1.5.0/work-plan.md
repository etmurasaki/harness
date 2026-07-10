# Plan: COO 1.5.0 Smoke Test — Resource Consumption Validation

## Problem

COO 1.5.0 introduces the Monitoring UIPlugin with Perses. Before release, we need to verify that the operator and its sub-components (Perses server,
Perses operator, monitoring console plugin) do not exceed the memory requests declared in the CSV when running under realistic cluster load. There is no
existing automated test for this — the validation requires a purpose-built script.

## Approach

Build a single self-contained bash script (`run-smoke-test.sh`) that automates the five-step process described in the Jira issue. The script uses `oc`
CLI commands exclusively, requires no additional tooling, and produces a timestamped report log for each run.

## Phases

### Phase 1: Preflight Checks

**Dependency:** None

Validate prerequisites before doing any work:

- Verify `oc` CLI is available and logged into a cluster
- Confirm `uiplugins.observability.openshift.io` CRD exists (COO is installed)
- Confirm operator pods are running in the COO namespace
- Extract memory resource requests from the CSV (`spec.install.spec.deployments[*].spec.template.spec.containers[*].resources.requests.memory`)
- Store CSV values for comparison in Phase 5

### Phase 2: Create Cluster Load

**Dependency:** Phase 1

Simulate a busy cluster by creating:

- 100 namespaces (configurable via `NUM_NAMESPACES`) with prefix `smoke-test-ns`
- 10 secrets per namespace (configurable via `SECRETS_PER_NS`) with random data
- 1 log-generator pod per namespace (UBI9 minimal, 8Mi request / 16Mi limit) that writes periodic heartbeat logs

The load generation exercises the cluster's namespace/secret/pod infrastructure without consuming significant resources itself.

### Phase 3: Baseline Measurement

**Dependency:** Phase 2

Capture pre-deployment resource usage:

- Node-level: `oc adm top nodes` (CPU cores, CPU%, memory bytes, memory%)
- Pod-level: `oc adm top pods -n <COO namespace>` for all COO pods

This establishes the memory baseline before the Monitoring UIPlugin is deployed.

### Phase 4: Deploy Monitoring UIPlugin with Perses

**Dependency:** Phase 3

- Apply the UIPlugin CR (`type: Monitoring`, `monitoring.perses.enabled: true`)
- Wait for the `monitoring` deployment to become Available (up to 300s)
- Wait for Perses pods (StatefulSet `perses-0` and `perses-operator` deployment) to reach Running state
- Allow 30s stabilization period for resource usage to settle

### Phase 5: Resource Measurement and Comparison

**Dependency:** Phase 4

Measure post-deployment resource usage:

- Repeat node-level and pod-level measurements from Phase 3
- Extract actual memory for each component:
  - Operator: by label `app.kubernetes.io/name=observability-operator`
  - Monitoring plugin: by label `app.kubernetes.io/instance=monitoring,app.kubernetes.io/part-of=UIPlugin` or name match
  - Perses server: by pod name pattern `perses-[0-9]` (StatefulSet)
  - Perses operator: by name match `perses-operator`
- Fetch memory requests from running deployments (fallback to CSV values)
- For StatefulSet resources (Perses server), query statefulset spec separately
- Compare actual vs requested for each component
- Report PASS/FAIL per component and overall verdict

### Cleanup

**Dependency:** runs as EXIT trap

- Delete the UIPlugin CR if created
- Delete all namespaces matching the smoke-test prefix
- Report total duration

## Script Design Decisions

| Decision | Rationale |
| --- | --- |
| Single bash script, no external deps | Runs anywhere with `oc` — no Python/Go/container build needed |
| `--skip-load` / `--skip-deploy` flags | Allow re-running measurement phases without recreating load or redeploying |
| `--skip-cleanup` flag | Keep resources for manual investigation when a test fails |
| `--dry-run` flag | Preview the test plan without modifying the cluster |
| Environment variable overrides | Customize namespace count, secrets per ns, timeouts without editing the script |
| Timestamped report files | Each run produces its own log for comparison across iterations |
| EXIT trap for cleanup | Ensures cleanup runs even if the script fails mid-execution |
| Label-based pod lookup with name fallback | Handles cases where labels differ between COO versions |
| Memory comparison using MiB conversion | Normalizes Gi/Mi/Ki/bytes for consistent integer comparison |
| Deployment requests as primary source, CSV as fallback | Running deployment values are more accurate than CSV which may lag |

## Verification

- Dry run produces correct plan output
- Preflight detects missing `oc`, missing login, missing CRD, missing operator pods
- Load creation creates the expected number of namespaces, secrets, and pods
- Baseline captures node and pod metrics
- UIPlugin deploys and stabilizes within timeout
- Resource comparison correctly identifies PASS (actual <= requested) and FAIL (actual > requested)
- Cleanup removes all created resources
- Report file is written with all phase details

## Phase 6: Validate perses-operator Memory Fix (PR #414)

**Dependency:** Phase 5 results (baseline failure data)

[perses/perses-operator#414](https://github.com/perses/perses-operator/pull/414) (merged 2026-06-08) addresses the
perses-operator memory growth observed during dashboard load testing. The PR includes four fixes:

1. **Metrics leak**: `ForgetObject()` now cleans up metrics when CRs are deleted — previously metrics accumulated indefinitely
2. **Client caching**: Perses API clients are cached by the factory instead of creating a new one per reconcile request
3. **Status update skip**: Status is only written when conditions actually change, reducing unnecessary API calls and allocations
4. **Cache payload trimming**: Managed fields and specs are stripped from the informer cache via `BuildCacheOptions`

### Pre-fix memory scaling (established in Phase 5 runs):

| Dashboards | Perses Operator Memory | Delta from Baseline | Result |
|---|---|---|---|
| 0 | 50-52Mi | — | PASS |
| 400 | 171Mi | +147Mi | FAIL (exceeds 128Mi request) |
| 800 | 236-319Mi | +200-300Mi | FAIL |
| 1,200 | 491Mi → OOM | +465Mi | OOMKill (exit 137) |

### Validation steps:

1. Deploy a perses-operator image built from commit `dabab8e` or later (post-PR#414). The perses-operator
   runs as a separate container image — patch the deployment to use the new image without rebuilding COO.
2. Run smoke test with 800 dashboards (same config as latest fail: 4 templates × 2 variants × 100 namespaces)
3. If 800 passes, escalate to 1,200 dashboards (the load that previously caused OOMKill)
4. Document results with direct comparison to pre-fix runs

### Expected outcome:

- Perses operator memory stays within 128Mi request at 800 dashboards (previously 236-319Mi)
- No OOMKill at 1,200 dashboards (previously exit 137)
- All 5 smoke test checks pass

## Risks

- **Metrics-server availability:** `oc adm top` requires metrics-server. If not ready, measurements return N/A and components are SKIPped.
- **Monitoring plugin and Perses server resource requests:** These components don't have memory requests declared in the CSV — they show as SKIP in
  the comparison. The test validates what it can but cannot fail on undeclared limits.
- **Deployment naming:** The monitoring console plugin deployment name changed between script iterations (`monitoring-console-plugin` vs `monitoring`).
  The script was updated to use the correct name.
- **Namespace:** The COO namespace may vary (`openshift-observability-operator` vs `openshift-cluster-observability-operator`). The script uses an
  environment variable default but the actual cluster uses the latter.
