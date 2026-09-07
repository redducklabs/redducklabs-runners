# Runbook: Runner Node Pool Sizing

Operational contract for the fixed GitHub Actions runner pool.

- **Cluster:** `redducklabs-cluster` (context `do-sfo3-redducklabs-cluster`, region sfo3)
- **Pool:** `github-runners-pool-16g`
- **Node size:** `s-8vcpu-16gb` — 8 vCPU, 16 GB, **$96/node/month**
- **Pool labels/taints:** `node-type=github-runner`, `workload-type=ci-cd`,
  taint `github-runner=true:NoSchedule`

## Current invariant: two runner pods per node

The August one-pod-per-node design is superseded. The runner and privileged DinD
sidecar now share a pod-level request of **3 CPU / 5 GiB memory** and a shared
**6 GiB memory limit**. Neither container has a competing CPU or memory budget.

On a measured node with 13.32 GiB and 7880m allocatable, two pods reserve 10
GiB and 6 CPU. A third pod does not fit. Two $96 nodes therefore provide four
self-hosted jobs with a fixed **$192 monthly cap**.

The pool and scale set are intentionally fixed:

```
minRunners=2  maxRunners=4
min_nodes=2   max_nodes=2   count=2
```

`deploy/dind-values.yaml` is the source of truth. The CI workflows reject
larger runner bounds, node-pool values other than 2/2, and live-capacity drift.

## Current configuration

| Setting | Value | Where it lives |
|---|---|---|
| `minRunners` | 2 | `deploy/dind-values.yaml` |
| `maxRunners` | 4 | `deploy/dind-values.yaml` |
| `min_nodes` | 2 | node pool (applied by the workflow below) |
| `max_nodes` | 2 | node pool (applied by the workflow below) |
| Per pod | 3 CPU / 5 GiB request; 6 GiB shared memory limit | `deploy/dind-values.yaml` |

**Cost floor and ceiling: $192/month** (two fixed nodes).

The recorded GitHub-hosted comparison is 3,000 Team-plan included private
minutes plus $0.006 per standard Linux private minute. $192 equals 35,000
private hosted minutes per month. The `admin:org` credential could not retrieve
organization billing totals, so this does not measure actual usage. Standard
GitHub-hosted minutes for public repositories are free.

## CI-only change and rollback path

Do not resize the runner pool, alter runner bounds, or change the memory budget
from a workstation. The local `scripts/scale-runners.sh` helper accepts only
`status`. CI uses the reviewed commit's `expected_sha` for all mutation paths:

1. Run Deploy GitHub Runners with `operation=prepare-trust-boundary` and explicit
   privileged co-tenancy acceptance. It reconciles and reads back the private
   runner group without Helm, Kubernetes, or DigitalOcean mutation.
2. Run Scale Runners and Node Pool Sizing from that same SHA. Node Pool Sizing
   accepts only 2/2 and verifies two Ready runner nodes.
3. Run Deploy GitHub Runners from the same SHA. It runs server-side dry-runs of
   the rendered scale set and representative Pod before Helm mutation, and
   records the post-quiesce pre-density Helm revision as the rollback target.
4. Use Deploy GitHub Runners with `operation=rollback`, that recorded revision,
   and the same SHA to restore the isolated 2/2 runner template. CI reads back
   the runner group and public-workflow scan after rollback.

The trust boundary is `redducklabs-private-runners`, `visibility=selected`,
public access disabled, and exactly `aurolegal.ai`, `autoduck`, `manager`,
`platform-observability`, `redducklabs`, `redducklaw`, `therapy-link`,
`zipbot-internal`, and `zipbot-v2`. CI scans all public organization workflows;
any direct or unresolved dynamic use of `redducklabs-runners` fails closed.

## Deterministic acceptance and end-of-feature audit

Acceptance begins only after trust preparation and the fixed-capacity deployment
complete from the same reviewed SHA. The private
`redducklabs/aurolegal.ai` workflow is dispatched from a unique annotated tag
whose target is the reviewed workflow SHA, accepts that SHA as
`expected_workflow_sha`, and proves four overlapping jobs on four distinct
ephemeral runners with 2+2 placement across the two existing nodes. The
migrated toolkit workflow is dispatched from its reviewed tag and SHA, checks
out source `f042c7192797e59b9c10ab034a4d4c2bbcaee1ca`, and runs its four-version
matrix on GitHub-hosted runners. The controller verifies each run's `headSha`;
the toolkit workload must not use ARC.

The end-of-feature audit records the user’s explicit privileged co-tenancy
acceptance; runner group name, selected/private-only policy, and exact
repository list; public-workflow scan results; reviewed and dispatched SHAs;
the rollback Helm revision; four-runner overlap and 2+2 placement; actual
PodSpecs; workload results; node count; OOM, restart, eviction, and scheduling
events from deployment through completion.

## Diagnostics and shared-budget OOM investigation

Run **Runner Status** first. It reports pod and container metrics, restarts,
OOM kills, evictions, node headroom, fixed-capacity drift, and provider-capacity
diagnostics. Its provider data is an allow-listed, redacted subset of the DOKS
autoscaler ConfigMap: `Healthy`, `NoCandidates`, `NoActivity`, or `Backoff`,
with a capacity-related `cloudProviderError` only. Missing or changed provider
text produces `Autoscaler diagnostics unavailable` and does not bypass the hard
capacity gates.

An `OOMKilled` result identifies the killed process, not the component that
used most of the shared 6 GiB budget. Attribute an incident only after reviewing
aggregate pod use, both containers' use and restarts, headroom, and events.

## Security trade-off

Two jobs share each runner node while each pod includes privileged DinD. That
restores cross-job co-tenancy and its larger kernel-level blast radius. The
explicit user acceptance, selected-repository trust boundary, public-workflow
scan, and CI-only rollout records are required controls; see
[`docs/security/vulnerability-dismissals.md`](../security/vulnerability-dismissals.md).
