# Execution: COO 1.5.0 Smoke Test — Resource Consumption Validation

## Phase 1: Script Development

Depends on: nothing

- [x] Create `run-smoke-test.sh` with 5-phase structure (preflight, load, baseline, deploy, measure+compare)
- [x] Add argument parsing (`--dry-run`, `--skip-cleanup`, `--skip-load`, `--skip-deploy`, `--help`)
- [x] Add environment variable overrides (`NUM_NAMESPACES`, `SECRETS_PER_NS`, `COO_NAMESPACE`, etc.)
- [x] Implement `mem_to_mib` conversion (Gi, Mi, Ki, bytes)
- [x] Implement `wait_for_deployment_ready` with configurable timeout
- [x] Implement EXIT trap cleanup (delete UIPlugin, delete smoke-test namespaces)
- [x] Implement timestamped report log (`smoke-results-YYYYMMDD-HHMMSS.log`)

## Phase 2: Iterative Testing and Bug Fixes

Depends on: Phase 1

### Run 1 — Dry run (2026-05-04 10:15)

- [x] `--dry-run` — verified plan output, config defaults (100 ns, 10 secrets/ns)
- Result: Dry run plan displayed correctly

### Run 2 — First live attempt (2026-05-04 11:12)

- [x] Run with `--skip-cleanup` — FAIL at preflight: "Not logged into an OpenShift cluster"
- Fix: logged into the cluster with `oc login`

### Run 3 — Post-login attempt (2026-05-04 11:15:09)

- [x] Run with `--skip-cleanup` — FAIL at preflight: "No running operator pods in openshift-observability-operator"
- Discovery: the actual COO namespace is `openshift-cluster-observability-operator`, not `openshift-observability-operator`

### Run 4 — Correct namespace, skip deploy (2026-05-04 11:15:29)

- [x] Run with `--skip-cleanup --skip-deploy` and correct `COO_NAMESPACE`
- [x] Load creation: 100 namespaces, 1000 secrets created successfully
- [x] CSV detected: `cluster-observability-operator.v1.4.0`
- [x] CSV memory requests: operator=256Mi, prometheus-operator=150Mi, admission-webhook=50Mi, perses-operator=128Mi
- [x] Baseline captured: 6 nodes, 10 pods in COO namespace
- [x] UIPlugin already deployed (health-analyzer, monitoring, distributed-tracing, logging plugins present)
- [x] Measurement: operator=48Mi, plugin=N/A (label mismatch), perses=54Mi, perses-operator=70Mi
- Result: **PASS** (2/2 measurable, 2 skipped — monitoring plugin label not matching, perses server no request declared)

### Run 5 — With UIPlugin deployment (2026-05-04 13:03)

- [x] Run with `--skip-cleanup` (deploy enabled)
- [x] Load creation: 100 namespaces, 1000 secrets
- [x] UIPlugin/monitoring created successfully
- [x] FAIL: `deployment/monitoring-console-plugin not ready after 300s`
- Fix: deployment name is `monitoring`, not `monitoring-console-plugin` — updated `wait_for_deployment_ready` call

### Run 6 — Interrupted (2026-05-04 13:30)

- [x] Run with `--skip-cleanup` — interrupted during load creation (only reached phase 1)

### Run 7 — Fixed deployment name (2026-05-04 13:32)

- [x] Run with `--skip-cleanup`, deployment name fixed to `monitoring`
- [x] Load creation: 100 namespaces, 1000 secrets, 100 log-generator pods (pod creation added in this iteration)
- [x] UIPlugin/monitoring created and deployment ready in <1s (already existed from run 5)
- [x] Perses deployment ready in <1s
- [x] 30s stabilization wait
- [x] Measurement: operator=50Mi, plugin=8Mi, perses=81Mi, perses-operator=81Mi
- Result: **PASS** (2/2 measurable — operator 50Mi/256Mi, perses-operator 81Mi/128Mi; monitoring plugin and perses server SKIPped due to no declared request)

### Run 8 — Final validation (2026-05-04 15:15)

- [x] Run with `--skip-cleanup --skip-load` (reuse existing namespaces from prior runs)
- [x] UIPlugin/monitoring created and ready
- [x] Perses server (perses-0) running — CPU spike at 183m during startup, stabilized
- [x] Measurement: operator=48Mi, plugin=10Mi, perses-0=51Mi, perses-operator=82Mi
- Result: **PASS** (2/2 measurable — operator 48Mi/256Mi, perses-operator 82Mi/128Mi; 2 SKIPped)

## Summary of Results

| Run | Time  | Flags                        | Result | Notes                                      |
| --- | ----- | ---------------------------- | ------ | ------------------------------------------ |
| 1   | 10:15 | `--dry-run`                  | OK     | Plan verified                              |
| 2   | 11:12 | `--skip-cleanup`             | FAIL   | Not logged in                              |
| 3   | 11:15 | `--skip-cleanup`             | FAIL   | Wrong namespace                            |
| 4   | 11:15 | `--skip-cleanup --skip-deploy` | PASS | 2/2 pass, 2 skip                          |
| 5   | 13:03 | `--skip-cleanup`             | FAIL   | Wrong deployment name (`monitoring-console-plugin`) |
| 6   | 13:30 | `--skip-cleanup`             | —      | Interrupted                                |
| 7   | 13:32 | `--skip-cleanup`             | PASS   | 2/2 pass, 2 skip; added log-generator pods |
| 8   | 15:15 | `--skip-cleanup --skip-load` | PASS   | 2/2 pass, 2 skip; final validation         |

## Script Fixes Applied During Execution

| Issue | Run | Fix |
| --- | --- | --- |
| Default namespace wrong | 3 | Set `COO_NAMESPACE=openshift-cluster-observability-operator` |
| Deployment name wrong | 5 | Changed `monitoring-console-plugin` to `monitoring` in `wait_for_deployment_ready` |
| No log-generator pods | 4-5 | Added UBI9 log-generator pod creation in Phase 1 |
| Monitoring plugin label mismatch | 4 | Added fallback name-based grep when label-based lookup returns empty |
| Perses server missing from comparison | 4 | Added StatefulSet query for perses resource requests |
| Perses detection too broad | 7 | `perses-operator` detected as Perses deployment instead of perses-0; refined pod name regex to `perses-[0-9]` |

## Observations

- **Operator memory is well within limits:** 48-50Mi actual vs 256Mi requested (~19% utilization).
- **Perses operator is within limits:** 70-82Mi actual vs 128Mi requested (~55-64% utilization).
- **Monitoring console plugin** has no declared memory request in the CSV — actual usage is low (8-10Mi).
- **Perses server (perses-0)** has no declared memory request in the CSV — actual usage is moderate (51-54Mi) with CPU spikes during startup (183m).
- **Cluster load impact:** creating 100 namespaces with 1000 secrets and 100 pods did not noticeably increase COO component memory — the operator
  memory stayed stable at 47-50Mi across all runs.

## Phase 3: Dashboard Load Testing (COO 1.5.0 as-shipped)

### Run 9 — 800 dashboards, no cleanup (2026-06-08)

- [x] Run with `DASHBOARDS_PER_NS=8` but `DASHBOARDS_DIR` not set — dashboards skipped
- [x] 100 namespaces, 1000 secrets, 100 log-generator pods created
- [x] UIPlugin/monitoring deployed, Perses ready
- [x] Measurement: operator=60Mi, plugin=9Mi, perses-0=59Mi, perses-operator=52Mi
- Result: **PASS** (5/5) — no dashboards, so perses-operator stayed at baseline

### Run 10 — 800 dashboards with 4 templates (2026-06-09)

- [x] Run with `DASHBOARDS_PER_NS=8`, `DASHBOARDS_DIR` with 4 symlinked templates
- [x] Templates: `openshift-cluster-sample-dashboard`, `perses-dashboard-sample`, `prometheus-overview`, `thanos-compact-overview`
- [x] 4 templates × 2 variants = 8 dashboards/ns × 100 namespaces = 800 total dashboards
- [x] 100 namespaces, 1000 secrets, 100 log-generator pods
- [x] UIPlugin/monitoring deployed, Perses ready
- [x] Dashboard creation: 800 PersesDashboard CRs created successfully
- [x] Measurement: operator=62Mi, plugin=31Mi, **perses-0=143Mi**, **perses-operator=236Mi**
- [x] OOMKill: none
- [x] COO-1014 limits: operator 512Mi ✓, perses-operator 512Mi ✓
- Result: **FAIL** (4 pass, 1 fail) — perses-operator 236Mi exceeds 128Mi request (but within 512Mi limit)
- Report: `smoke-results-20260609-072156.log`

### Memory scaling trend (all pre-fix runs):

| Run | Dashboards | Perses Operator | Delta | Result |
|---|---|---|---|---|
| 8 | 0 | 82Mi | — | PASS |
| 10 | 800 | 236Mi | +154Mi | FAIL |
| 7 (prior) | 400 | 171Mi | +147Mi | FAIL |
| 6 (prior) | 800 | 319Mi | +300Mi | FAIL |
| 5 (prior) | 1,200 | 491Mi → OOM | +465Mi | OOMKill |

## Phase 4: Validate perses-operator Memory Fix (PR #414)

[perses/perses-operator#414](https://github.com/perses/perses-operator/pull/414) (merged 2026-06-08, commit `dabab8e`)
addresses the memory growth with four fixes: metrics leak cleanup, client caching, status-update-only-on-change,
and cache payload trimming (managed fields + specs removed from informer cache).

- [ ] Build perses-operator image from post-PR#414 code (commit `dabab8e` or later)
- [ ] Patch perses-operator deployment on test cluster with new image
- [ ] Run smoke test with 800 dashboards (same config as Run 10)
- [ ] If 800 passes, run with 1,200 dashboards (same config that previously OOMKilled)
- [ ] Document results with before/after comparison
- [ ] Create formatted report (`smoke-results-*.md`)

## Open Items

- [ ] Monitoring console plugin and Perses server need CSV-declared memory requests to enable automated validation
- [ ] Deploy and validate perses-operator with PR #414 fix
- [ ] Update Jira OU-1326 with final results
