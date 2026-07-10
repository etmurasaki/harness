# OU-1326: [QE] Smoke test for COO 1.5.0

**Jira:** https://redhat.atlassian.net/browse/OU-1326
**Status:** To Do
**Priority:** Critical
**Assignee:** Evelyn Murasaki
**Reporter:** Gabriel Bernal
**Due:** Wed, 29 Apr 26

## Description

Prepare a cluster with many namespaces and secrets (via script), install COO, create a monitoring UI plugin with Perses enabled, and assert that memory consumption stays below requested resources (found in the COO CSV).

## Steps

1. Create a script to create many namespaces and secrets in them
2. Measure current memory consumption of the nodes (establish baseline)
3. Install COO, create a monitoring UIPlugin with Perses enabled
4. Measure resources used by COO, the console monitoring plugin, and Perses resources
5. Compare usage against the baseline
