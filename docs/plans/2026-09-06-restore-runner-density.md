# Restore Runner Density Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore four-runner concurrency on the existing two-node runner pool
without increasing cost or reintroducing unbounded DinD memory use.

**Architecture:** Kubernetes pod-level resources provide one 5 GiB request and
6 GiB shared memory limit to the runner and DinD containers. ARC is capped at four runners,
and the DigitalOcean pool is capped at two nodes. CI validates the rendered
resource locally and performs a live server-side dry run before rollout.

**Tech Stack:** ARC Helm chart 0.14.2, Kubernetes 1.36.3, Bash, GitHub Actions,
DigitalOcean DOKS.

**Spec:** `docs/specs/2026-09-06-runner-density-and-cost-cap-design.md`

## Global Constraints

- Do not add paid capacity or remove existing nodes.
- Do not mutate the cluster from the workstation.
- Preserve `redducklabs-runners`, `arc-runners`, and the dedicated runner-pool
  labels and taints.
- Deploy only through GitHub Actions and do not merge the pull request.
- Do not claim success until the CI-deployed configuration passes live queue
  verification.
- Do not deploy until the user explicitly accepts privileged cross-job
  co-tenancy on the same runner node.
- Do not deploy until `agent-handoff-toolkit`, `fountainrank`, and
  `claude-control` have no workflow jobs selecting `redducklabs-runners`.

---

### Task 1: Encode the two-pods-per-node invariant

**Files:**
- Modify: `test/verify-runner-resources.sh`

**Interfaces:**
- Consumes: the rendered `AutoscalingRunnerSet` from `deploy/dind-values.yaml`.
- Produces: a failing check against the current one-pod-per-node configuration,
  then a verifier for shared pod-level resources and four-runner/two-node
  capacity.

- [ ] Change the verifier to read pod-level requests and limits from
  `.spec.template.spec.resources` and reject runner/DinD container-level CPU or
  memory requests and limits.
- [ ] Assert two pods plus 2 GiB memory/1000m CPU headroom fit the recorded node
  budget and a third pod does not.
- [ ] Assert `maxRunners=4` maps to two nodes at two pods per node.
- [ ] Add fixture-driven checks that reject deploy/scale `maxRunners > 4`,
  reject production node-pool bounds other than 2/2, and reject live capacity
  drift.
- [ ] Add offline mismatched-SHA negative cases for Scale Runners, Node Pool
  Sizing, Deploy, and rollback; assert each exits before its mocked mutation
  command, including mutating GitHub runner-group REST calls. Add matching-SHA
  positive cases that reach every mocked boundary.
- [ ] Run `bash test/verify-runner-resources.sh` and record the expected failure
  against the current values.

### Task 2: Apply the shared pod budget and fixed capacity ceiling

**Files:**
- Modify: `deploy/dind-values.yaml`
- Modify: `deploy/dind-values.template.yaml`
- Create: `deploy/trusted-runner-repositories.txt`
- Modify: `.github/workflows/deploy-runners.yml`
- Modify: `.github/workflows/scale-runners.yml`
- Modify: `.github/workflows/node-pool-sizing.yml`
- Modify: `scripts/scale-runners.sh`

**Interfaces:**
- Consumes: the invariants enforced by Task 1.
- Produces: 5 GiB/3 CPU shared pod requests, a 6 GiB pod memory limit,
  `minRunners=2`, `maxRunners=4`, and two-node defaults/validation.

- [ ] Add pod-level resources and remove runner/DinD container resource blocks.
- [ ] Set `runnerGroup: redducklabs-private-runners` and commit the exact private
  repository allow-list used by CI: `aurolegal.ai`, `autoduck`, `manager`,
  `platform-observability`, `redducklabs`, `redducklaw`, `therapy-link`,
  `zipbot-internal`, and `zipbot-v2`. Reject blank, duplicate, nonexistent, or
  public entries.
- [ ] Change production runner maximums and normal/max scale profiles to four.
- [ ] Change node-pool defaults and capacity arithmetic to two pods per node and
  a two-node ceiling.
- [ ] Make capacity mismatches fatal, make local scaling status-only, and remove
  direct production resizing from the runbook.
- [ ] Add executable negative tests for CPU and memory container-resource
  reintroduction and every oversized mutation input.
- [ ] Run `bash test/verify-runner-resources.sh` and record a passing result.

### Task 3: Add a live API compatibility preflight and diagnostics

**Files:**
- Modify: `.github/workflows/deploy-runners.yml`
- Modify: `.github/workflows/runner-status.yml`
- Modify: `.github/workflows/validate-config.yml`
- Create: `scripts/verify-runner-trust-boundary.sh`

**Interfaces:**
- Consumes: the pinned Helm chart, live ARC CRD, and autoscaler status ConfigMap.
- Produces: a server-side dry-run gate before Helm deployment and visible
  provider-backoff diagnostics in Runner Status.

- [ ] Render the candidate with the exact Helm overlays used by deployment;
  server-side dry-run both the `AutoscalingRunnerSet` and a representative
  `core/v1 Pod`, and inspect returned objects for admission mutations.
- [ ] Add a live per-node gate requiring two proposed pods plus at least 2 GiB
  memory and 1000m CPU after non-runner requests.
- [ ] Make Runner Status report autoscaler backoff/error details without reading
  secrets.
- [ ] Read only `kube-system/cluster-autoscaler-status` key `status` as text;
  parse the sanitized 2026-09-06 DOKS fixture with lower-case `health:` and
  `scaleUp:` sections, allow-listed Healthy/NoCandidates/NoActivity/Backoff
  states, `errorCode: cloudProviderError`, and capacity-related `errorMessage:`
  text; redact URLs plus cluster, pool, and request identifiers. Embed both a
  healthy/no-activity and provider-backoff fixture in the existing verifier and
  report diagnostics unavailable when absent or changed.
- [ ] Extend fixture/static validation to prove dry-run failure prevents Helm,
  exact overlays are shared, and cost/capacity drift fails.
- [ ] Reconcile `redducklabs-private-runners` through the GitHub runner-group
  REST API with `visibility=selected`, public access disabled, and exactly the
  committed private repository IDs; read it back and fail closed on drift or
  insufficient permissions. Enumerate all public organization repositories and
  parse their workflow jobs, failing if any `runs-on` selects
  `redducklabs-runners`. This must prove the `agent-handoff-toolkit`,
  `fountainrank`, and `claude-control` migrations are complete before rollout;
  unresolved dynamic `runs-on` expressions in public workflows fail closed.
- [ ] Add mocked functional tests for the trust-boundary script covering group
  creation, existing-group reconciliation, exact repository replacement,
  permission failure, public/unknown allow-list rejection, readback drift, and
  public workflow label detection. Assert the fake `gh` call sequence and
  resulting exit status/output without network or cluster access.
- [ ] Order all read-only validation before GitHub mutation. Create a missing
  group with exact repository IDs atomically; for an existing group, narrow it
  to selected/private-only before replacing membership. On partial failure,
  halt before Helm and report that access may remain more restrictive until the
  next successful CI reconciliation.
- [ ] Add an explicit `prepare-trust-boundary` operation to Deploy GitHub
  Runners. It verifies `expected_sha`, runs all read-only trust checks, reconciles
  and reads back only the runner group, and exits without any Helm, kubectl, or
  DigitalOcean mutation. Task 5 must dispatch this operation successfully before
  Scale Runners.

### Task 4: Update operating documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/SETUP.md`
- Modify: `docs/runbooks/node-pool-sizing.md`
- Modify: `docs/specs/2026-08-19-runner-capacity-and-memory-design.md`
- Modify: `docs/security/vulnerability-dismissals.md`

**Interfaces:**
- Consumes: Tasks 1-3 behavior.
- Produces: accurate concurrency, resource, cost, failure-mode, and rollback
  guidance.

- [ ] Mark the August one-pod-per-node decision as superseded.
- [ ] Document four-runner/two-node capacity, pod-level 3 CPU/5 GiB scheduler
  requests, and the shared 6 GiB memory limit.
- [ ] Document server-side preflight and provider-capacity diagnostics.
- [ ] Record the privileged co-tenancy risk/trust controls and replace causal
  container-only OOM attribution with shared-budget diagnostics.
- [ ] Record the exact group, policy, private repository list, public-workflow
  scan, and explicit user co-tenancy acceptance in the end-of-feature audit.

### Task 5: Verify, review, and deliver through CI

**Files:**
- Review all branch changes.
- Write review artifacts only under ignored `temp/codex-reviews/`.

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: a reviewed pull request, green checks, CI deployment, and live
  acceptance evidence.

- [ ] Run YAML parsing, actionlint, `bash -n`, shellcheck, Helm render/resource
  verification, and `git diff --check`.
- [ ] Obtain independent security/correctness review and resolve findings.
- [ ] Commit without AI attribution, push, and open a pull request.
- [ ] Monitor all pull-request checks until green; do not enable auto-merge.
- [ ] Record one commit SHA before any mutation and pass it as `expected_sha`
  to Deploy's `prepare-trust-boundary` operation, Scale Runners, Node Pool
  Sizing, and deployment runs dispatched from the same branch. Complete and
  verify the trust-boundary operation first. Quiesce ARC at 2/2, wait for no
  scale-up demand, then record the
  resulting Helm revision as the rollback target. Scale Runners must use the
  repository-pinned ARC 0.14.2 chart, and the recorded revision must be verified
  to contain that chart version, 2/2 runner bounds, and the old isolated runner
  5 GiB plus DinD 5 GiB requests and named private runner group. Abort on
  checkout mismatch or pool count other than two.
- [ ] Require a reviewed, pinned `runner-density-acceptance.yml` in private repo
  `redducklabs/aurolegal.ai`: four matrix jobs publish runner-identity markers,
  wait at an artifact/API barrier for four distinct identities, exercise Docker,
  and remain active for placement collection. Dispatch it from a unique
  annotated tag targeting the reviewed workflow commit, require an
  `expected_workflow_sha` input checked against `github.sha`, and verify the
  resulting run `headSha` before acceptance. Record its SHA,
  overlap, distinct runners, 2+2 placement, actual PodSpecs, completion, events,
  restarts, OOMs, and node count. Separately dispatch the migrated toolkit
  workflow from its reviewed default-branch revision with source input
  `f042c7192797e59b9c10ab034a4d4c2bbcaee1ca`. Dispatch from a unique annotated
  tag targeting the reviewed migration commit, require and verify
  `expected_workflow_sha`, and verify the run `headSha`; verify it checks out that source,
  runs the same four-version matrix on GitHub-hosted runners, and completes
  without consuming ARC.
- [ ] On any failure, use the deployment workflow's CI rollback mode with the
  recorded post-quiesce Helm revision and `expected_sha`, then verify the old
  runner 5 GiB + DinD 5 GiB requests, isolated min/max 2/2 runners, named private
  runner group with exact membership/public access disabled, public workflow
  scan, and pool 2/2.
- [ ] Rerun Runner Status and verify registrations, queue movement, toolkit
  completion, node count, OOMs, evictions, and scheduling events.
- [ ] Create the end-of-feature audit record with commands, outputs, URLs, and
  the final continuation section.
