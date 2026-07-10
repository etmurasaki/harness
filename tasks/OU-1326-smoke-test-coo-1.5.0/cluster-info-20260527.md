# Cluster Configuration — COO 1.5.0 Smoke Test (2026-05-27)

## Cluster

| Property | Value |
|---|---|
| API URL | `https://api.emurasak-1626.qe.devcluster.openshift.com:6443` |
| OpenShift Version | 4.16.0-0.nightly-2026-05-24-203906 |
| Kubernetes Version | v1.29.14+41c4e9b |
| Channel | eus-4.16 |
| Platform | AWS |
| Region | us-east-2 |
| Control Plane Topology | HighlyAvailable |
| Infrastructure Topology | HighlyAvailable |

## Nodes (6x m6i.xlarge)

All nodes: 4 vCPU, ~15.3 GiB RAM, amd64, RHCOS 416.94.202605221110-0

| Node | Role | CPU Usage | Memory Usage |
|---|---|---|---|
| ip-10-0-10-223 | control-plane | 2249m (64%) | 10131Mi (69%) |
| ip-10-0-26-171 | worker | 392m (11%) | 5925Mi (40%) |
| ip-10-0-32-107 | control-plane | 3154m (90%) | 11335Mi (77%) |
| ip-10-0-38-247 | worker | 615m (17%) | 6876Mi (47%) |
| ip-10-0-74-222 | worker | 366m (10%) | 3708Mi (25%) |
| ip-10-0-94-41 | control-plane | 3511m (100%) | 12327Mi (84%) |

## COO Installation

| Property | Value |
|---|---|
| COO Version | 1.5.0 |
| CSV | cluster-observability-operator.v1.5.0 |
| CSV Phase | Installing |
| Subscription Channel | stable |
| Catalog Source | `quay.io/redhat-user-workloads/cluster-observabilit-tenant/cluster-observability-operator/coo-fbc-v4-16@sha256:445287eb...` |
| Install Plan Approval | Automatic |
| Namespace | openshift-cluster-observability-operator |

### Co-installed Operators

| Operator | Version |
|---|---|
| Loki Operator | 5.9.15 |
| OpenTelemetry Operator | 0.144.0-3 |
| Tempo Operator | 0.20.0-3 |

## UIPlugins

| Name | Type | Perses Enabled |
|---|---|---|
| monitoring | Monitoring | true |
| distributed-tracing | DistributedTracing | - |
| logging | Logging | - |

## COO CSV Resource Declarations (v1.5.0)

| Deployment | Container | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|---|
| observability-operator | operator | 100m | 400m | 256Mi | 512Mi |
| perses-operator | perses-operator | 100m | 500m | 128Mi | 512Mi |
| obo-prometheus-operator | prometheus-operator | 5m | 100m | 150Mi | 500Mi |
| obo-prometheus-operator-admission-webhook | admission-webhook | 50m | 200m | 50Mi | 200Mi |

## COO Pods at Test Time

| Pod | Status | Restarts | Node | Image |
|---|---|---|---|---|
| observability-operator-54b5d6c656-xb69r | Running | 0 | ip-10-0-38-247 | `registry.redhat.io/.../cluster-observability-rhel9-operator@sha256:4ba153df...` |
| perses-operator-9cdcfb74c-frg7h | Running | **16** | ip-10-0-26-171 | `registry.redhat.io/.../perses-rhel9-operator@sha256:677ae1cb...` |
| perses-0 | Running | 0 | ip-10-0-74-222 | `quay.io/openshift-observability-ui/perses:v0.54.0` |
| monitoring-7f49856c97-zwlct | Running | 0 | ip-10-0-38-247 | `quay.io/rh-ee-pyurkovi/monitoring-plugin:OU-1275-4.15` |
| obo-prometheus-operator-645d4c879d-bplwl | Running | 0 | ip-10-0-38-247 | `registry.redhat.io/.../obo-prometheus-rhel9-operator@sha256:58419ab5...` |
| obo-prometheus-operator-admission-webhook-857574474-crs8x | Running | 0 | ip-10-0-26-171 | `registry.redhat.io/.../obo-prometheus-operator-admission-webhook-rhel9@sha256:0dd457a9...` |
| obo-prometheus-operator-admission-webhook-857574474-h2ht2 | Running | 0 | ip-10-0-38-247 | (same as above) |
| distributed-tracing-6c64994754-krmxg | Running | 0 | ip-10-0-38-247 | `registry.redhat.io/.../distributed-tracing-console-plugin-pf5-rhel9@sha256:d12a59a1...` |
| logging-7b44c9ccf8-zh7st | Running | 0 | ip-10-0-38-247 | `quay.io/rh-ee-pyurkovi/logging-view-plugin:ou-1280-4.15` |

## Test Load Applied

| Resource | Count |
|---|---|
| Smoke-test namespaces | 72 (of 100 targeted; creation interrupted at ns-072 on first run) |
| Secrets per namespace | 10 |
| Log-generator pods per namespace | 1 |
| PersesDashboard CRs per namespace | 52 (4 templates × 13 variants) |
| Total PersesDashboard CRs on cluster | 1,000 (dashboards only created in namespaces that existed) |

Dashboard templates used:
- `openshift-cluster-sample-dashboard` (1041 lines)
- `perses-dashboard-sample` (564 lines)
- `prometheus-overview` (461 lines)
- `thanos-compact-overview` (1421 lines)

## OOMKill Finding (COO-1014)

| Property | Value |
|---|---|
| Affected Pod | perses-operator-9cdcfb74c-frg7h |
| Container | perses-operator |
| Memory Limit | 512Mi |
| Restart Count | 16 |
| Last OOMKill | 2026-05-27T17:04:48Z |
| Exit Code | 137 (SIGKILL) |
| Pod Uptime Before Last OOMKill | 13 seconds (started 17:04:35, killed 17:04:48) |

The perses-operator is being OOMKilled repeatedly while reconciling ~1,000 PersesDashboard CRs across 72 namespaces. The 512Mi limit (COO-1014 fix) is insufficient under this dashboard load.

## Test Execution

| Property | Value |
|---|---|
| Script | `run-smoke-test.sh` |
| Jira Tickets | OU-1326 (smoke test), COO-1014 (OOMKill fix) |
| Tester | Evelyn Murasaki |
| Date | 2026-05-27 |
| Flags | `--skip-load --skip-deploy --skip-cleanup` |
| Result | **FAIL** (1 check failed: OOMKill detected on perses-operator) |
| Report Log | `smoke-results-20260527-122621.log` |
