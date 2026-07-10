# Spec

## Related jira tickets:
https://redhat.atlassian.net/browse/COO-1883
https://redhat.atlassian.net/browse/COO-1878
https://redhat.atlassian.net/browse/COO-1881
https://redhat.atlassian.net/browse/COO-1889
https://redhat.atlassian.net/browse/COO-1890

## Related projects and branches:
- perses-operator: branch `release-coo-1.5` (rhobs/perses-operator fork)

## Description:
These CVEs were fixed as part of a previous task already implemented, however the testing part was not yet performed. We need 2 shell scripts, one to test it statically against the code and other dynamically to test perses-operator deployed in a running cluster, through observability-operator. 
