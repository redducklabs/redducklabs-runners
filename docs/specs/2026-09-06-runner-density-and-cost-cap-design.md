# Runner Density and Cost Cap Design

**Date:** 2026-09-06
**Status:** Pending Review
**Supersedes:** The one-runner-per-node resource decision in
`docs/specs/2026-08-19-runner-capacity-and-memory-design.md`.

## Problem

The August 2026 resource change gave each runner pod 10 GiB of memory requests
on nodes with 13.32 GiB allocatable. That deliberately reduced packing from two
runner pods per node to one. Although ARC's configured ceiling increased from
six to eight, reaching that ceiling now requires eight physical nodes.

During the September 2026 incident, ARC correctly created eight runners but the
DigitalOcean cluster autoscaler received HTTP 422 while expanding the sole
eligible `s-8vcpu-16gb` pool in `sfo3`. Two pods ran on the two existing nodes
and six remained Pending. The design therefore doubled cost per concurrent job
and made ordinary queue progress depend on provider scale-out capacity.

## Goals

- Run four organization-wide jobs concurrently on the existing two runner
  nodes.
- Keep the runner-node cost capped at the existing $192 monthly maximum.
- Prevent the Docker daemon from consuming unbounded memory.
- Avoid dependence on provisioning additional DigitalOcean nodes.
- Preserve the existing runner label, image, node isolation, and DinD behavior.
- Make unsupported pod-level resource configuration fail before Helm changes
  the live scale set.

## Non-goals

- Adding fallback pools, larger nodes, or other paid capacity.
- Removing either existing runner node.
- Optimizing workloads that require more than the shared per-job budget.
- Changing the custom runner image or ARC chart version.

## Decision

Use Kubernetes pod-level resources to give the runner container and restartable
DinD sidecar one shared budget:

```yaml
template:
  spec:
    resources:
      requests:
        cpu: "3"
        memory: "5Gi"
      limits:
        memory: "6Gi"
```

Remove the container-level CPU and memory requests and limits from `runner` and
`dind`. Kubernetes then schedules and constrains the two containers as one
workload. DinD remains bounded, but unused memory is available to whichever
container needs it.

Two pods request 10 GiB and 6 CPU on a node with 13.32 GiB and 7880m CPU
allocatable. After the measured 694 MiB/522m system workload, approximately
2.64 GiB and 1358m remain above the two-pod reservation. A third pod cannot fit
by memory or CPU. Each pod may use up to 6 GiB, so two jobs remain bounded to
12 GiB even when both burst simultaneously.

Set `minRunners: 2` and `maxRunners: 4`. Keep the runner node pool at exactly
two nodes (`min_nodes=2`, `max_nodes=2`). This yields two warm runners, permits
four concurrent jobs during bursts, and leaves additional jobs queued at GitHub
instead of assigning them to unschedulable pods.

The limits are enforced, not merely documented:

- deployment and scaling inputs reject `maxRunners > 4`;
- the production node-pool workflow rejects any bounds other than 2/2;
- capacity checks fail when the live runner pool is not exactly 2/2 with count
  2 before rollout;
- local scaling helpers become status-only and direct production mutation
  instructions are removed from the runbook.

## Deployment Safety

The deploy workflow renders the pinned ARC chart with the exact values and
overlays used by the subsequent Helm command. Before `helm upgrade`, it performs
two server-side dry runs:

1. the rendered `AutoscalingRunnerSet`, proving the installed ARC CRD accepts
   and preserves pod-level resources; and
2. a representative `core/v1 Pod` built from the rendered pod template,
   proving Pod admission accepts pod-level resources, the restartable DinD
   sidecar, placement constraints, and namespace policy.

The returned objects are inspected to ensure admission did not inject competing
container CPU or memory budgets. The preflight also verifies the API server and every
eligible runner node are Kubernetes 1.36.x or newer.

Before changing pool bounds, the existing Scale Runners workflow is dispatched
after the runner group is reconciled, with min/max 2/2 and
`runnerGroup=redducklabs-private-runners`. ARC preserves busy runners but stops assigning additional
work and removes unstarted Pending ephemeral runners. CI waits until the scale
set has no scale-up demand, then re-reads the runner pool and aborts unless
`count=2`, `min_nodes=2`, and both nodes are Ready. It changes only `max_nodes`
from 8 to 2 and verifies count remains 2. Quiescing ARC first closes the race in
which provider recovery could otherwise add a node between the count check and
pool update. Scale Runners pins the `gha-runner-scale-set` chart to the same
repository-managed ARC 0.14.2 version used by deployment; it must not resolve a
floating chart while creating the rollback target. After quiescing, CI verifies
the release chart version, 2/2 runner bounds, the existing isolated runner
5 GiB plus DinD 5 GiB request template, and the named private runner group
before recording that Helm revision.

Mutable branch names are not treated as immutable deployment references. The
Scale Runners, node-pool, and deployment workflows require an `expected_sha` input and abort
unless the checked-out commit matches it. Every rollout run uses the same
recorded commit SHA and branch ref.

The rollout remains CI-only. No local `kubectl apply`, Helm upgrade, Terraform
apply, pod deletion, restart, eviction, or node removal is permitted.

## Scheduling Headroom Gate

Static validation requires two runner pods plus at least 2 GiB memory and
1000m CPU of remaining scheduling headroom after accounting for non-runner
requests. On the current 13.32 GiB nodes, the 2 GiB threshold permits up to
approximately 1.32 GiB of non-runner requests; the measured 644-694 MiB leaves
approximately 630-680 MiB of growth beyond today's system reservation.
Deployment recomputes allocatable
resources and non-runner requests on every eligible node and aborts unless each
node satisfies the same margin. Current live evidence measured approximately
2.69 GiB and 1358m remaining after two proposed pods.

## Security Decision

Each runner pod contains a privileged DinD sidecar. Two organization-wide jobs
on one node therefore share a kernel, increasing cross-job blast radius relative
to the current one-job-per-node design and restoring the same co-tenancy used
before August 2026. Deployment requires explicit acceptance of this risk and
verification that the runner group is limited to trusted repositories and does
not execute untrusted fork pull requests. Before any rollout, the scale set
explicitly selects the organization runner group
`redducklabs-private-runners`. A committed repository allow-list contains only
the current private consumers: `aurolegal.ai`, `autoduck`, `manager`,
`platform-observability`, `redducklabs`, `redducklaw`, `therapy-link`,
`zipbot-internal`, and `zipbot-v2`. The CI deployment workflow
uses the existing `RUNNER_TOKEN` and GitHub runner-group REST API to create or
reconcile that group with `visibility=selected`, public access disabled, and
exactly the committed repository IDs; it then reads the group back and fails
closed on any difference or insufficient token permission. The same preflight
enumerates all public organization repositories and fails if any workflow job
still selects `redducklabs-runners`. The requested `agent-handoff-toolkit`
migration, plus the discovered `fountainrank` and `claude-control` migrations,
are rollout prerequisites. This prevents fork-originated public code from
reaching the privileged fleet without relying on trigger-shape heuristics. The
audit records the group, policy, repository list, public-repository scan, and the
user's explicit co-tenancy acceptance. The accepted risk and controls are
recorded in `docs/security/vulnerability-dismissals.md`.

Runner-group reconciliation is exposed as an explicit
`prepare-trust-boundary` operation in Deploy GitHub Runners. It accepts and
verifies `expected_sha`, performs every read-only repository and public-workflow
check first, reconciles and reads back only the GitHub runner group, and exits
without Helm, kubectl mutation, or DigitalOcean mutation. The ordered rollout
must complete this operation successfully before dispatching Scale Runners.

## Diagnostic Trade-off

The shared pod budget supersedes the August design's separate-container OOM
attribution. An `OOMKilled` container identifies the killed process, not
necessarily the component that consumed most of the shared budget. Status and
runbook guidance must report pod aggregate use, both containers' use/restarts,
and avoid causal claims based only on the killed container.

## Validation

The resource verifier must assert from the rendered chart that:

- pod-level memory request is 5 GiB and limit is 6 GiB;
- pod-level CPU request is 3;
- runner and DinD do not define competing container-level memory budgets;
- exactly two runner pods fit within the recorded node budget;
- a third pod does not fit;
- `maxRunners` equals four and requires no more than two nodes;
- the explicit DinD sidecar, pinned image, native-sidecar restart policy, and
  Docker socket wiring remain intact.

Fixture-driven workflow tests must also prove oversized deploy/scale/node-pool
inputs fail, the exact Helm render is used by both preflight and deployment, a
failed dry run prevents Helm execution, and live-state drift is fatal. For Scale
Runners, Node Pool Sizing, Deploy, and deployment rollback, mismatched-SHA tests
must fail before the first mutating GitHub REST, Helm, kubectl, or doctl command;
matching-SHA tests must reach each mocked mutation boundary. All read-only
validation precedes runner-group reconciliation. Group creation uses the exact
repository IDs in one request. Existing-group reconciliation first narrows the
group to selected/private-only access and then replaces membership; a partial
failure halts before Helm and may leave access more restrictive, never broader,
until a later CI reconciliation succeeds.

`kube-system/cluster-autoscaler-status` is a DOKS-managed observational
ConfigMap, not a stable Kubernetes API. Runner Status treats `data.status` as
untrusted diagnostic text and emits only allow-listed lines matching the
observed 2026-09-06 DOKS grammar. The sanitized fixture includes lower-case
`health:`/`scaleUp:` sections; healthy `status: Healthy`, `status: NoCandidates`,
and `status: NoActivity` values; and the affected group with `errorCode:
cloudProviderError`, a capacity-related `errorMessage:`, and `status: Backoff`.
Only those allow-listed keys and values are emitted, with URLs, cluster/pool IDs,
and provider request identifiers removed. Missing objects or schema changes are
reported as diagnostics unavailable and do not bypass the separate hard
capacity gates. Both healthy/no-activity and provider-backoff fixtures are
covered by local tests.

Workflow/YAML parsing, actionlint, shell syntax checks, shellcheck, Helm render,
and the repository validation workflow remain required.

## Live Acceptance

The ordered rollout is:

1. record the reviewed branch commit and dispatch Deploy GitHub Runners'
   `prepare-trust-boundary` operation with that `expected_sha`; require its
   runner-group readback and public-workflow scan to pass;
2. pass the same `expected_sha` to the Scale Runners workflow, set ARC min/max
   2/2 with the named group, wait for scale-up demand to quiesce,
   then record the resulting Helm revision as the rollback target. Before the
   pool update, require `count=2`, `min_nodes=2`, and two Ready nodes;
3. dispatch Node Pool Sizing from the reviewed branch with `expected_sha`, 2/2
   bounds, and verify no node was added or removed. Before runner deployment,
   require `count=min_nodes=max_nodes=2`, autoscaling enabled, and two Ready
   nodes;
4. dispatch Deploy GitHub Runners from the same commit;
5. dispatch the pinned `runner-density-acceptance.yml` workflow in private
   `redducklabs/aurolegal.ai`. Its four-job matrix publishes per-runner markers,
   waits at an artifact/API barrier until all four distinct runner identities
   are active, exercises Docker, then remains active for placement evidence
   collection. It is dispatched using a unique annotated tag whose target is
   the reviewed workflow commit, accepts that commit as
   `expected_workflow_sha`, fails before the workload if `github.sha` differs,
   and the controller verifies the resulting run's `headSha` equals the expected
   commit before acceptance;
6. dispatch the migrated toolkit workflow on its reviewed default-branch
   revision with source input `f042c7192797e59b9c10ab034a4d4c2bbcaee1ca`.
   It is dispatched using a unique annotated tag targeting the reviewed
   migration commit, accepts that commit as `expected_workflow_sha`, fails if
   `github.sha` differs, explicitly checks out the original source commit, and
   runs the same four-version matrix on GitHub-hosted runners. The controller
   verifies the resulting run's `headSha` before accepting it; and
7. collect evidence from deployment start through workload completion.

Acceptance requires:

- two idle runners before load, then four overlapping jobs on four distinct
  ephemeral runners with 2+2 placement on the two existing nodes;
- GitHub reports the expected runners Online;
- all four private acceptance jobs overlap on the self-hosted scale set, and
  the cited toolkit workflow begins on GitHub-hosted runners;
- no runner pod remains unschedulable for memory or provider-capacity reasons;
- actual PodSpecs preserve the pod-level 3 CPU/5 GiB requests and 6 GiB memory
  limit, with no runner or DinD container-level CPU or memory budgets;
- all four private acceptance jobs and all toolkit matrix jobs complete successfully;
- no new OOM, eviction, restart, or scheduling failure appears for the workload
  pod UIDs or in events since deployment began;
- the runner pool remains at two nodes and does not exceed the $192 cap.

## Rollback

Read-only preflight failure aborts before mutation; runner-group reconciliation
is an explicit mutation phase that completes and is read back before Helm.
Deployment, registration, scheduling,
OOM, or acceptance-workload failure triggers the deployment workflow's explicit
CI rollback mode using the recorded post-quiesce, pre-density-change Helm
revision. The workflow requires the same `expected_sha`, performs
`helm rollback`, verifies `minRunners=2,maxRunners=2`, and verifies the restored
template has runner 5 GiB plus DinD 5 GiB requests. The node pool remains at
2/2, the cost cap remains $192, and concurrency returns to two. Runner Status
and the same live checks verify the rollback, including
`runnerGroup=redducklabs-private-runners`, exact selected-repository membership,
public access disabled, and no public workflow using the label. No local Helm command or node-pool
expansion is used.
