# Spec: Smoke test for COO 1.5.0 — Resource Consumption Validation

## Related projects and branches

- cluster-observability-operator: version 1.5.0 (CSV reports v1.4.0)
- OpenShift cluster: 4.13+ with cluster-admin access (us-east-2, 6-node cluster)

## Jira

- **Issue:** [OU-1326](https://redhat.atlassian.net/browse/OU-1326)
- **Priority:** Critical
- **Assignee:** Evelyn Murasaki
- **Reporter:** Gabriel Bernal
- **Due:** 2026-04-29

## Description

Validate that the Cluster Observability Operator (COO) 1.5.0, when deployed with the Monitoring UIPlugin (Perses enabled), keeps memory consumption
within the resource requests declared in the operator's ClusterServiceVersion (CSV). The test simulates realistic cluster load by creating many
namespaces with secrets and log-generating pods, then measures actual memory usage of all COO-related components and compares against their declared
resource requests.

## Acceptance criteria

- A reusable smoke test script exists that can be run against any OpenShift cluster with COO installed.
- The script creates realistic cluster load: 100 namespaces, each with 10 secrets and a log-generator pod.
- Baseline node and pod memory is captured before deploying the Monitoring UIPlugin.
- The Monitoring UIPlugin with Perses enabled is deployed and waits for all components to stabilize.
- Post-deployment memory consumption is measured for all COO components:
  - Observability Operator
  - Monitoring Console Plugin
  - Perses Server (StatefulSet)
  - Perses Operator
- Each component's actual memory is compared against its CSV-declared memory request.
- The test passes if all measurable components consume memory at or below their declared requests.
- The test produces a timestamped report log with full details of each phase.
- Cluster resources are cleaned up after the test (unless explicitly skipped).

## Components under test

| Component                  | Deployment Type | CSV Memory Request |
| -------------------------- | --------------- | ------------------ |
| Observability Operator     | Deployment      | 256Mi              |
| Prometheus Operator (OBO)  | Deployment      | 150Mi              |
| Prometheus Admission WH    | Deployment      | 50Mi               |
| Perses Operator            | Deployment      | 128Mi              |
| Perses Server              | StatefulSet     | N/A (not in CSV)   |
| Monitoring Console Plugin  | Deployment      | N/A (not in CSV)   |

## Out of scope

- Functional testing of dashboards, alerting, or Perses UI features.
- Performance/load testing beyond memory consumption validation.
- Testing COO upgrade paths (this is a fresh-install smoke test).
- CPU consumption validation (measured but not compared against limits).
