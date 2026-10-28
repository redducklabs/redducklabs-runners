# Runner Burst Autoscaling Design

**Date:** 2026-10-26
**Status:** Approved (Codex review 5)
**Supersedes:** The fixed two-node / four-runner cost cap in
`docs/specs/2026-09-06-runner-density-and-cost-cap-design.md`. The pod-level
resource budget, DinD sidecar, image, trust-boundary model, immutable
`expected_sha` checks, and the shared non-cancelling `runner-fleet-mutation`
concurrency group are retained (with two documented exceptions, Emergency Stop
and Rebalance; see "Emergency Stop" and "Job protection and idle-runner
retirement").
**Amended:** 2026-10-27, final branch review Rulings 26-29 (the `stopped`
state family, Helm history retention and the drain rollback target, Emergency
Stop and Rebalance concurrency, the Rebalance skip predicate); 2026-10-27, PR
#35 review Rulings 33-34 (the Emergency Stop fence; the rollback target is the
committed `deploy/density-values.yaml`, independent of Helm history) and the
removal of the alternate Phase B shape; 2026-10-27, PR #35 re-review Ruling 36
(the server-side Emergency Stop fence, a ValidatingAdmissionPolicy keyed on
the stop marker).

## Problem

The fleet is capped at four concurrent jobs on two fixed `s-8vcpu-16gb` nodes.
That cap is far below demand, so the heaviest private repositories moved their
CI to GitHub-hosted runners, where the organization now pays per minute.

Measured from the GitHub enhanced billing API and the Actions jobs API for
`redducklabs`:

| Period | Hosted billed minutes | Gross |
|---|---|---|
| 2026-08 | 8,282 | $50 |
| 2026-09 | 44,175 | $266 |
| 2026-10 (1st–26th) | 53,145 | $321 |
| 2026-10-19 → 2026-10-26 (7 days) | 38,696 | $232 |

The last seven days project to roughly 166,000 minutes, about $1,000, per month.
Breakdown of those seven days: `keel` 59%, `aurolegal.ai` 38%,
`superfood-shred` 2%. Actual job time was 32,550 minutes; the remaining 16% is
GitHub's per-job round-up to whole minutes (49% of jobs ran under a minute).

Concurrency profile of the same 10,058 jobs:

| Concurrent jobs ≥ | Hours per week | Share of week |
|---|---|---|
| 1 | 69.3 | 38% |
| 4 | 46.4 | 26% |
| 8 | 28.4 | 16% |
| 12 | 16.2 | 9% |
| 16 | 8.8 | 5% |
| 20 | 5.1 | 3% |

Peak concurrency was 60. The share of job-minutes that fall within a static
concurrency ceiling of N is: 4 → 42%, 8 → 67%, 12 → 82%, 16 → 90%,
20 → 95%, 24 → 98%. This is theoretical capacity coverage; it does not account
for node cold-start delay (see Performance). Load concentrates between 10:00
and 21:00 Pacific.

Self-hosted runner minutes are not billed today: the `redducklabs` repository
ran 72 workflow runs on `redducklabs-runners` in October with no minute charge
in the billing data. GitHub announced a $0.002/minute platform charge for
self-hosted usage in December 2025; it does not appear in this organization's
billing. If it is applied later, the current volume would add about $280/month,
and self-hosted would remain cheaper than hosted.

## Goals

- A static ceiling of 20 concurrent jobs (95% theoretical coverage).
- Two warm runners on baseline nodes for immediate pickup.
- Burst capacity exists only while jobs need it and returns to zero.
- Total CI spend (DigitalOcean runner nodes plus GitHub-hosted minutes) below
  the current hosted run rate.
- Every existing fail-closed safety property either retained or replaced by a
  named fail-closed equivalent.

## Non-goals

- Changing the runner image or ARC chart version.
- Migrating secret-handling jobs (`aurolegal.ai` Class B, deploy/apply jobs in
  other repositories). They remain on GitHub-hosted runners.
- Windows or macOS jobs.
- Admitting `my-review-buddy`; it has no workflows. It is admitted later under
  the same evidence process if it gains CI.

## Decision

### Node pools and the aggregate ceiling

| Pool | Size | min | max | Cost |
|---|---|---|---|---|
| `github-runners-pool-16g` (existing, baseline) | `s-8vcpu-16gb` | 2 | 2 | $192/month fixed |
| `github-runners-burst-16g` (new, primary) | `s-8vcpu-16gb` | 0 | 6 | $0.143/node-hour |
| `github-runners-burst-amd-16g` (new, fallback) | `s-8vcpu-16gb-amd` | 0 | 2 | $0.167/node-hour |

The approved burst ceiling is eight nodes in aggregate. It is enforced by the
provider's autoscaling bounds: the burst pool maxima sum to exactly 8
(`6 + 2`), so the cluster autoscaler cannot grow the burst pools past eight
nodes regardless of provisioning delay, backoff, or which pool it picks. The
billed ceiling is 10 runner nodes, worst case
`2×$96 + 6×$96 + 2×$112 = $992/month` if every node ran continuously.

That bound covers autoscaling, not provider maintenance. DOKS surge upgrades
temporarily create duplicate worker nodes during a cluster upgrade;
DigitalOcean documents those duplicates as carrying no additional charge. A
surge node carries its pool's labels, so while one exists the pool-state
maintenance check (cluster status not `running`, or more registered nodes than
the pool's provider `count`) fails, and every fleet mutation workflow fails
closed until maintenance finishes. No
absolute physical-node ceiling beyond that is claimed.

Every guard enforces: baseline exactly `min=max=count=2`; each burst pool
`min=0`; primary `max ≤ 6`; fallback `max ≤ 2`; and
`sum(burst max) ≤ 8`. Moving allowance between the two burst pools is a
separate reviewed change, applied by Node Pool Sizing in one serialized run
that lowers the donor first, reads it back, then raises the recipient.

Pool selection is explicit. The cluster autoscaler's default expander picks
randomly among pools that can fit a Pending pod, so "primary" and "fallback"
would otherwise be names only. Node Pool Sizing operation
`configure-expander` sets the cluster expanders to `priority,random`
(`doctl kubernetes cluster update --expanders priority,random`) and writes the
DOKS-managed `kube-system/cluster-autoscaler-priority-expander` ConfigMap's
`data.priorities` to pool IDs resolved at run time:

```yaml
100:
  - <github-runners-burst-16g pool id>
50:
  - <github-runners-burst-amd-16g pool id>
1:
  - .*
```

The ConfigMap keeps its `doks.digitalocean.com/managed` labels. The operation
reads back both the cluster expander list and the ConfigMap and fails on any
difference. The autoscaler excludes a node group in backoff from expansion
options, so a primary pool failing with a provider error yields to the
fallback. `worker-pool` matches only the priority-1 catch-all and no runner pod
fits it, so its behavior is unchanged. Undo is `--expanders ""`, which restores
DigitalOcean's default.

The fallback pool uses a different droplet size because the September 2026
incident showed the DOKS autoscaler receiving HTTP 422 while growing the sole
eligible `s-8vcpu-16gb` pool. The account droplet limit is 100 with 15 in use,
so the limit was not the cause; the root cause is unproven. The fallback gives
the autoscaler a second node group while the primary is in backoff. It is
deliberately small: fallback capacity covers four extra jobs, not a full burst.

All three pools carry exactly the labels `node-type=github-runner`,
`workload-type=ci-cd` and the single taint `github-runner=true:NoSchedule`.
The pool name is distinguishable through the DOKS node label
`doks.digitalocean.com/node-pool`.

Scale-to-zero (`min_nodes=0`) is documented for DOKS autoscaling pools; the
DigitalOcean release notes still describe it as preview. If the API rejects
`min_nodes=0`, the run fails, creates nothing further, and the rollout stops
for re-planning. It never falls back to a `min_nodes=1` cost floor.

### Runner bounds and placement

```yaml
minRunners: 2
maxRunners: 20
```

The pod budget stays 3 CPU / 5 GiB request, 6 GiB limit. `maxRunners = 20`
equals two pods on each of the 10 possible nodes. Guards reject
`maxRunners > 20` and `minRunners > 4`.

The runner pod template adds a **preferred** node affinity (weight 100) for
`doks.digitalocean.com/node-pool=github-runners-pool-16g`. New runner pods,
including warm-floor replacements, land on baseline whenever it has room.

### Job protection and idle-runner retirement

Runner pods get `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so
the autoscaler never drains a node with a runner pod on it. Because that
also protects **idle** runners, affinity alone does not free burst nodes: an
idle warm runner created on a burst node during a burst stays there until it
receives a job.

Idle retirement is a script, `scripts/retire-idle-burst-runners.sh`, so any
workflow that already holds the `runner-fleet-mutation` lock runs it in
process instead of waiting on another workflow. A scheduled **Rebalance
Runners** workflow in this repository runs it hourly on a GitHub-hosted runner
(this repository is public, so those minutes are free). The script:

1. Lists EphemeralRunners in `arc-runners` whose pod is on a burst-pool node.
2. Selects only those with no assigned job: EphemeralRunner
   `status.jobRequestId` empty **and** the GitHub runner `busy=false` from the
   organization runners API, read after the Kubernetes read.
3. Deletes at most the selected runners, oldest first, and never more than the
   number of free baseline slots, so the warm floor is replaced on baseline.

ARC 0.14.2's EphemeralRunner finalizer removes the runner from GitHub before
deleting the pod. If a job was assigned between the check and the delete, the
service returns `JobStillRunningError`, the controller requeues every 30 s,
and the pod is deleted only after the job finishes
(`controllers/actions.github.com/ephemeralrunner_controller.go`, tag
`gha-runner-scale-set-0.14.2`). A race therefore delays retirement; it does not
kill a job. The EphemeralRunnerSet replaces the deleted runner, and the
affinity places it on baseline.

Rebalance uses its own non-cancelling concurrency group, `runner-rebalance`
(amended by Ruling 28; it originally shared `runner-fleet-mutation`, where an
hourly run queued behind multi-hour mutations and could displace a pending
Emergency Stop). Every run, scheduled or dispatched, first lists the queued,
in-progress, waiting, pending and requested runs of Deploy, Scale Runners, Node
Pool Sizing and Emergency Stop (read-only `gh api`, `actions: read`) and ends
with a "nothing to rebalance" notice if any exists; a failed read fails the
run. Otherwise it still takes the gate, and the retirement script compares
identities before every deletion, so a mutation that starts during a
Rebalance run stops it fail-closed. It reads its kubeconfig through the
existing DigitalOcean token and makes no change other than EphemeralRunner
deletion. Deploy `drain` runs the same script inside its own run while it
holds the lock.

A scheduled Rebalance ends with a "nothing to rebalance" notice only when the
read-only status shows ARC `density` (any burst pools) or `drain` with no
burst pools (Ruling 29, correcting Ruling 19). Every other state goes to the
rebalance gate, whose rejection fails the run; `burst` with no burst pools,
for example, fails. When the gate admits a `stopped` state, the run ends with a
notice and retires nothing.

### State contract for fleet workflows

The existing gates that require exactly two runner nodes, exactly two Ready
nodes, and ARC bounds of 2/2 or 2/4 are replaced by one shared check,
`scripts/verify-runner-pool-state.sh`, used by Node Pool Sizing, Deploy, Scale
Runners, Rebalance, and Runner Status:

- **Eligible pools:** every node pool carrying `node-type=github-runner` must
  be one of the three named pools with its exact size, labels, and single
  taint. An unknown eligible pool fails closed.
- **Node membership:** every node labeled `node-type=github-runner` must
  belong to one of the three pools through `doks.digitalocean.com/node-pool`,
  carry both labels and the taint, and have no other `NoSchedule`/`NoExecute`
  taint.
- **Baseline stability:** the baseline pool has `count=min=max=2` and exactly
  two Ready nodes. Mutating operations record the baseline cluster ID, pool ID,
  and node UID/providerID pairs and require them unchanged before and after
  mutation, as today.
- **Burst state:** each burst pool satisfies its bounds and
  `count ≤ max_nodes`. Burst nodes may be present. A burst node that is not
  Ready is tolerated for 15 minutes after creation (provisioning) and fails the
  check after that.
- **Node compatibility:** every Ready eligible node runs Kubernetes 1.36.x or
  newer, and after two runner reservations plus its non-runner requests keeps
  at least 2 GiB memory and 1000m CPU of headroom, the retained September
  standard. Deploy's headroom preflight evaluates every Ready eligible node,
  not a fixed list of two.
- **Maintenance:** the cluster's DigitalOcean status is `running` (not
  `upgrading` or any other state), and no pool has more registered nodes than
  its provider `count`. A surge-upgrade duplicate raises the registered node
  count above `count` even in an underfilled burst pool; a node that is still
  provisioning does not, because `count` already includes it.
- **ARC state:** the live AutoscalingRunnerSet, Helm values, and manifest match
  one of the contracts the calling operation admits (table below). The check
  takes the operation name as an argument; an unknown operation or a state the
  operation does not admit fails closed.

`scripts/validate-runner-isolation-contract.py` gains three contracts:

- `burst`: the `density` template plus the preferred baseline affinity and the
  safe-to-evict annotation, with `minRunners=2`, `maxRunners=20`, and the
  private group.
- `drain`: the `burst` template with `maxRunners=4`, and the preferred
  baseline affinity replaced by a **required** node affinity for the baseline
  pool. New runner pods can only schedule on baseline; existing pods on burst
  nodes keep running with their safe-to-evict protection. Four runners fit
  the baseline, so no new runner pod is left Pending to trigger scale-up.
- `burst-acceptance`: the `burst` template, group, and `maxRunners=20` with
  `minRunners` of 8 or 4. It is admitted only for the operations listed
  below; Deploy never renders it and rejects 8/20 and 4/20 as input.

It also gains the `stopped` state family (Ruling 26), which is what Emergency
Stop leaves: `helm upgrade --reuse-values --set minRunners=0 --set
maxRunners=0` on the pinned chart keeps the release's template. Each member is
a base template, exactly, with `minRunners=maxRunners=0` and the private group,
and records which base it is:

- `burst-stopped`: the `burst` template at 0/0 (also what an Emergency Stop
  during Phase C leaves, since `burst-acceptance` has the `burst` template).
- `density-stopped`: the `density` template at 0/0.
- `drain-stopped`: the `drain` template at 0/0.

ARC states admitted per operation:

| Operation | Admitted ARC states | Admitted burst pools |
|---|---|---|
| Runner Status (read-only) | `density`, `burst`, `burst-acceptance`, `drain`, `burst-stopped`, `density-stopped`, `drain-stopped`; reports the Emergency Stop marker | any valid subset |
| Rebalance | `burst`, `drain` (retires idle burst runners); `burst-stopped`, `density-stopped`, `drain-stopped`, or any state while the Emergency Stop marker exists (admitted; ends with a notice, retires nothing) | both present; any valid subset for a stopped state or under the marker |
| Scale Runners `acceptance-phase-c` | `burst` on entry and exit; `burst-acceptance` (8/20 or 4/20) inside the run and on a re-run after interruption, which first restores `burst` | both present, enabled |
| Scale Runners `record-density` (read-only; verifies the live release equals the render of `deploy/density-values.yaml`) | `density` | none |
| Node Pool Sizing `set-burst-maxima` | `burst` | both present; requested maxima within 0..6 and 0..2 with sum ≤ 8; lowers before raises, reading back each |
| Node Pool Sizing `create-burst` | `density`, `burst` | none, one, or both at `max_nodes=0` (reconcile) |
| Node Pool Sizing `configure-expander` | `density`, `burst` | both present |
| Deploy `deploy` | `density`, `burst`, `burst-stopped` (restores `burst` after Emergency Stop; with the marker present only when dispatched with `acknowledge_emergency_stop=true`) | both present, expander configured |
| Node Pool Sizing `enable-burst` | `burst` | exactly one of three stages: both closed (0/0, 0/0); primary open and fallback closed (0/6, 0/0); both open (0/6, 0/2). It opens the primary first, so a retry from the middle stage opens only the fallback; any other combination fails |
| Deploy `drain` | `burst`, `burst-acceptance` (interrupted Phase C), `drain` (retry), `burst-stopped` (only without the Emergency Stop marker) | both present |
| Node Pool Sizing `remove-burst` | `drain` or `drain-stopped` with any pools; or `density` or `density-stopped` with every present burst pool at `max_nodes=0` and zero nodes (also while the Emergency Stop marker exists) | both, one, or none |
| Deploy `rollback` | `drain`, `drain-stopped` or `density-stopped` (Helm upgrade to the committed `deploy/density-values.yaml`, validated as `density`); `density` (no-op re-run); with the marker present only when dispatched with `acknowledge_emergency_stop=true` | none |

Every other operation rejects the stopped states. `remove-burst` admits
`drain-stopped` and `density-stopped` under the same pool conditions as `drain`
and `density`, so the rollback path (`remove-burst`, then `rollback`) still
works after an Emergency Stop during a drain.

**No ordinary runtime scaling.** The September design's Scale Runners min/max
action is retired in the burst design. Runner bounds change only by a reviewed
commit to `deploy/dind-values.yaml` followed by Deploy, whose contract
validators recognize exactly the canonical states above. This removes every
non-canonical min/max pair from the reachable state space. Emergency Stop's
0/0 is the canonical `stopped` state family above (Ruling 26).

**Emergency Stop.** Emergency Stop first writes the marker ConfigMap
`arc-runners/runner-fleet-emergency-stop` (data: the run id and the time), then
sets `minRunners=maxRunners=0` with `--reuse-values` on the pinned chart
(`--version 0.14.2`), reads back the resulting `stopped` state and the marker
with the read-only gate, and prints the recovery path that admits it. It uses
its own non-cancelling concurrency group, `runner-emergency-stop`, not
`runner-fleet-mutation` (Ruling 28), so it runs immediately instead of waiting
behind a drain (up to 300 minutes) or Phase C (up to 270 minutes). A failed
marker write does not delay the stop; the run fails afterwards.

**Emergency Stop fence (Ruling 33).** A separate concurrency group alone lets
an older run that passed its final admission write after a completed stop and
reopen the fleet (PR #35 review finding 1). The marker closes that window:

- While the marker exists the pool-state gate refuses every fleet mutator.
  Runner Status and Rebalance report it as a stopped condition (Rebalance ends
  with a notice). Node Pool Sizing `remove-burst` stays admitted: it deletes
  only empty, closed burst pools and cannot start a runner, and without it the
  recovery from `drain-stopped` with pools present could not run. Deploy
  `deploy` and `rollback` are admitted only when dispatched with
  `acknowledge_emergency_stop=true`; they then delete the marker inside the
  identity bracket (compare, acknowledged admission, delete, compare) before
  their first write. The delete carries the uid and resourceVersion that were
  read as preconditions, so a newer stop that rewrote the marker in between
  makes it fail instead of being acknowledged unseen. Every later admission in
  that run is made without the acknowledgement.
- After every Helm write (Deploy, drain and Phase C through the shared
  bracket, rollback) the run re-reads the marker, whether or not Helm reported
  success. If it exists (a marker the run itself acknowledged was deleted
  before the write, so any marker now belongs to a newer stop), or cannot be
  read, the run immediately re-applies 0/0 with `--reuse-values
  --history-max 100` and fails red. The shared bracket also refuses to write
  while the marker exists, including on cleanup paths that skip re-admission.

Because the marker precedes the stop's Helm write, a mutator write before the
stop's write is overwritten by the stop, and a mutator write after it sees the
marker and re-stops, provided the writing process survives its Helm call; the
server-side fence below covers a writer that does not. Recovery:
`burst-stopped` by Deploy `deploy` with the acknowledgement (back to `burst`;
to leave burst, then `drain`); `drain-stopped` by `remove-burst`, then Deploy
`rollback` with the acknowledgement; `density-stopped` by `remove-burst` if
closed burst pools exist, then Deploy `rollback` with the acknowledgement.

**Server-side Emergency Stop fence (Ruling 36).** The post-write re-check
above runs in the writing process after `helm` returns. A stale run that is
cancelled, or loses its runner, after its Helm write and before that re-check
leaves the fleet reopened (PR #35 re-review finding 1): the ConfigMap alone
constrains nothing and no reconciler restores 0/0. The fence is therefore
enforced by the API server:

- `deploy/runner-emergency-stop-fence.yaml` defines the
  `admissionregistration.k8s.io/v1` ValidatingAdmissionPolicy
  `runner-fleet-emergency-stop-fence` (`paramKind` v1 ConfigMap,
  `failurePolicy: Fail`; CREATE and UPDATE of `actions.github.com/v1alpha1`
  `autoscalingrunnersets`, the only version ARC 0.14.2 serves, in namespace
  `arc-runners`, `matchPolicy: Equivalent`) with the validation
  `has(object.spec.maxRunners) && object.spec.maxRunners == 0 &&
  (!has(object.spec.minRunners) || object.spec.minRunners == 0)`, and a
  binding of the same name (`paramRef` name `runner-fleet-emergency-stop`,
  namespace `arc-runners`, `parameterNotFoundAction: Allow`;
  `validationActions: [Deny]`; the same namespace selector). With no marker
  the binding passes every request; while the marker exists every write of an
  AutoscalingRunnerSet that is not 0/0 is denied, whoever sends it.
  Emergency Stop's own 0/0 write is allowed. The rule `autoscalingrunnersets`
  does not match the status subresource, and DELETE is not matched. The file
  is written in its defaulted form (`matchPolicy`, `objectSelector`, `scope`).
- Deploy `deploy` (the bootstrap path) and `rollback` install it before their
  Helm write, as the runner NetworkPolicy is installed: a server-side dry run
  whose returned specs must equal the file (any defaulting difference fails
  before anything is applied), then a server-side apply inside the identity
  bracket (compare, re-admission, apply, compare), then a readback that the
  live specs equal the file and that the policy's `status.typeChecking` for
  its current generation carries no expression warnings.
- Every other fleet mutator (Rebalance retirement, Scale Runners Phase C,
  Deploy `drain`, Node Pool Sizing `create-burst`, `configure-expander`,
  `enable-burst`, `set-burst-maxima`) is admitted only when the live policy
  and binding exist with exactly the committed specs; missing or different
  rejects with an error naming the fence and the recovery. While ARC is
  `density` or `density-stopped` an absent fence is tolerated (the rollout
  steps before the first Deploy `deploy`, and the recovery of a rollout that
  failed before it); a present but different fence never is. Runner Status,
  `record-density` (read-only) and `remove-burst` (for the reason it is
  admitted under the marker: it deletes only empty closed pools and must stay
  available to recover from `drain-stopped`) do not require it.
- Emergency Stop, after writing the marker and before its Helm write, proves
  the fence enforces: the policy and binding must equal the file, and a
  server-side dry-run merge patch of the AutoscalingRunnerSet to
  `maxRunners: 1` must be denied by this policy, retried for up to 30 seconds
  while the API server's admission informer catches up with the marker.
  Proving it before its own write means every write that lands after the
  stop's 0/0 is denied. If the fence is absent or not enforcing, the stop is
  still applied (the check never blocks it and delays it by at most those 30
  seconds) and the run fails with an explicit message.
- An acknowledging Deploy `deploy`/`rollback` deletes the marker and then
  polls the same dry-run probe (up to 30 seconds) until it is allowed, before
  any write, so its Helm write is not denied by a stale admission view. If the
  fence still denies after 30 seconds the run fails before writing; the marker
  is gone, so the operator re-dispatches without the acknowledgement. Polling
  was chosen over letting the Helm write fail: a denied Helm upgrade inside
  the bracket is a failed write that needs review, while a dry-run poll writes
  nothing.
- The client-side post-write re-check above stays as defense in depth.

Residual risks: while the marker exists the API server also denies the ARC
controller's own updates (finalizers, annotations) of an AutoscalingRunnerSet
that is not yet 0/0; that is only the seconds between the marker write and the
stop's own write. A credential that can delete the policy can remove the
fence; the next admission of a mutator that requires it, and the next
Emergency Stop, then fail red.

**Helm history and the rollback target (Ruling 34).** Every Helm write in
this repository passes `--history-max 100` (Ruling 27). A finite retention cap
cannot preserve a designated revision (PR #35 review finding 2), so rollback
does not use Helm history at all. Its target is the committed
`deploy/density-values.yaml`: the reviewed values of the pre-burst release,
byte-for-byte the `deploy/dind-values.yaml` that is live before the rollout,
also used as the test suites' density fixture. Deploy `rollback` validates the
file as the `density` contract, renders it with the same token handling and
fixed overlays as Deploy, validates the rendered manifest as density 2/4, and
upgrades to exactly that render (manifest-hash post-renderer,
`--history-max 100`) inside the identity bracket with transition
`arc:density:2/4`. `record-density` is a read-only check that the live release
is density 2/4 and that its manifest (Secret payloads excluded) equals that
render. Deploy `drain` no longer takes a `rollback_revision`.

**Burst pools are created closed.** `create-burst` creates both pools with
`min_nodes=0, max_nodes=0`, so no burst node can exist until `enable-burst`
raises the maxima to 6 and 2 after the `burst` deployment and expander readback
succeed. A rollout that fails at any point before `enable-burst` leaves either
`density` with zero, one, or two closed pools, or `burst` with closed pools.
The first is recovered by `remove-burst` directly (no runner pod can be on a
node that cannot exist; the operation still observes zero nodes twice); the
second by the normal `drain → remove-burst → rollback` path.

**Phase C is one lock-owning operation.** Scale Runners action
`acceptance-phase-c` runs the whole Phase C cycle inside one workflow run that
holds `runner-fleet-mutation`: set `minRunners=8` (`burst-acceptance`), wait up
to 20 minutes for 8 Ready idle runners, assert 4 are on baseline and 4 on burst
nodes, run `retire-idle-burst-runners.sh` and assert it deleted nothing, set
`minRunners=4`, wait for ARC to remove surplus runners, run retirement and
record whether a burst survivor was retired, set `minRunners=2` and read back
`burst`, then wait up to 60 minutes for both burst pools to reach zero nodes
while running retirement every 2 minutes. Up to three cycles run in the same
operation if no survivor appears. A final step with `if: always()` sets
`minRunners=2` and reads back `burst` whether the run succeeded, failed, or was
cancelled; on the success path it is a verified no-op. `burst-acceptance` is
reachable only inside this run; an interrupted run that leaves it is admitted
by Deploy `drain` and by a re-run of the same action, which first restores
`burst`. Eight idle runners need at most the four baseline slots plus two
burst nodes, within the approved ceiling.

Operation contract:

| Operation | Precondition | Mutation | Postcondition |
|---|---|---|---|
| `prepare-trust-boundary` | admission evidence committed | runner group only | group readback equals allow-list |
| Node Pool Sizing `create-burst` | pool state valid with zero, one, or two closed burst pools; ARC `density` or `burst` | create/reconcile burst pools | readback of all three pools; baseline identity unchanged |
| Deploy `deploy` | pool state valid; server-side dry runs pass | Emergency Stop fence and runner NetworkPolicy, then Helm upgrade to `burst` | fence specs equal the file; ASRS/values/manifest equal `burst` |
| Rebalance | pool state valid | delete idle burst-node EphemeralRunners | none required |
| Node Pool Sizing `enable-burst` | ARC `burst` readback; expander readback | raise burst maxima to 6 and 2 | pools read back at 0/6 and 0/2 |
| Scale Runners `acceptance-phase-c` | ARC `burst` or interrupted `burst-acceptance`; burst enabled | whole Phase C cycle in one run | ARC `burst` readback |
| Node Pool Sizing `configure-expander` | pool state valid; both burst pools exist | cluster expanders and priority ConfigMap | readback equals expected |
| Deploy `drain` | pool state valid; no Emergency Stop marker | Helm upgrade to `drain`; retire idle burst runners in process and wait | `drain` readback; no runner pod on a burst node; burst pools at zero nodes |
| Node Pool Sizing `remove-burst` | ARC `drain`/`drain-stopped`, or `density`/`density-stopped` with only closed burst pools; no runner pods and zero nodes in burst pools, observed twice | reset expanders; delete burst pools | only baseline pool remains |
| Deploy `rollback` | ARC `drain`, `drain-stopped`, `density-stopped` or `density`; burst pools absent; `deploy/density-values.yaml` validates as `density` (values and render) | Helm upgrade to the committed density values | `density` readback |
| Emergency Stop | none (runs immediately in its own group) | stop marker, fence enforcement proof (dry run, Ruling 36), then Helm upgrade `--reuse-values` to 0/0 | a `stopped` state and marker readback; red if the fence did not deny the probe |

Every operation verifies `expected_sha` before its first mutating call, is
idempotent when re-run on its own postcondition, and treats a partially
created burst pool (exists with wrong size, labels, taint, or bounds) as a
reconcile target when the change only narrows it, and as a fatal error
otherwise.

### Cost model

Measured demand is 542 job-hours/week. The baseline covers four concurrent
jobs. Job time above four concurrent jobs is about 58% of job-minutes, or 315
job-hours/week, which is 158 burst node-hours at two jobs per node. With a 1.5×
allowance for boot and scale-down idle time, about 240 node-hours/week, or
about $150/month.

| Item | Monthly |
|---|---|
| Baseline nodes | $192 |
| Burst nodes (estimated) | ~$150 |
| Remaining GitHub-hosted (Class B, Windows, deploys) | ~$25–40 |
| **Total** | **~$370–380** vs ~$1,000 hosted run rate |

Cost is measured, not inferred, from the DigitalOcean monthly invoice: a new
`scripts/runner-cost-report.sh` reads `doctl invoice get` items. DigitalOcean
bills DOKS nodes as "Kubernetes Clusters" items aggregated per cluster and node
size (for example `8 nodes - 16 GB / 8 vCPU / 320 GB SSD`, grouped under the
cluster name, with node-hours in `duration`), not per droplet or pool. The
report therefore sums runner-size node-hours and cost for this cluster and
derives burst node-hours as runner node-hours minus two baseline nodes for the
whole period. Invoice items persist after node deletion, so deleted burst
nodes are counted. The
month in progress is not itemized by DigitalOcean; for it the script reports
account month-to-date usage from `doctl balance get` and labels it
account-wide. Missing or unparseable invoice data produces an explicit
"cost data unavailable" result, never a zero. Runner Status reports current
burst node count per pool; it does not claim node-hours.

### Performance

Each job gets 3 vCPU / 5–6 GiB versus the 2 vCPU GitHub-hosted private-repo
runner. Two queue-delay metrics are measured separately and both have
acceptance thresholds:

- **Warm pickup** (a runner with room on an existing node): job queued to job
  started p95 ≤ 90 s.
- **Cold pickup** (requires a new burst node): job queued to job started
  p95 ≤ 8 minutes.

Exceeding either threshold fails acceptance. The likely mitigation for cold
pickup is pinning the runner image by digest and setting
`imagePullPolicy: IfNotPresent`. That change is planned as a follow-up.

## Trust boundary and admission evidence

The runner group `redducklabs-private-runners` stays `visibility=selected`
with public access disabled. The allow-list adds the private repositories
`keel` and `superfood-shred` only after their admission evidence is committed
under `docs/security/runner-admission/<repo>.md`:

- repository visibility (private) and the repository fork-PR workflow policy
  from `GET /repos/{owner}/{repo}/actions/permissions/fork-pr-workflows-private-repos`.
  Required: `run_workflows_from_fork_pull_requests=false`. Observed
  2026-10-26 for both: `false`, with write tokens and secrets to forks also
  `false`;
- the list of collaborators with write access (observed 2026-10-26:
  `keel` owner only; `superfood-shred` owner plus one write collaborator,
  who is accepted as a trusted co-tenant);
- an audit of every workflow at a recorded commit SHA for
  `pull_request_target`, `workflow_run`, and reusable-workflow calls that could
  check out untrusted code (observed 2026-10-26: none in either repository);
- the list of jobs that will select `redducklabs-runners`, all of which must be
  jobs that hold no deploy credentials.

`scripts/verify-runner-trust-boundary.sh` is extended to re-read the fork-PR
policy for every private member at `prepare-trust-boundary` time and fail
closed when any member allows fork-PR workflows. A fixture test covers the
failing case. `docs/security/vulnerability-dismissals.md` AOR-2 is updated with
the new members, the evidence location, and the user's co-tenancy acceptance.

## Rollout

All infrastructure mutation runs through CI. Each run records its
`expected_sha` and its run URL in the rollout log
(`docs/runbooks/node-pool-sizing.md`, "Rollout record").

1. **Verify the rollback target.** Scale Runners `record-density` reads the
   current release (`density`, 2/4, private group), verifies it against the
   `density` contract, and verifies that it equals the render of the committed
   `deploy/density-values.yaml`, which Deploy `rollback` restores (Ruling 34).
   This replaces the legacy-isolated 2/2 rollback target, which is retired.
2. **Trust boundary.** `prepare-trust-boundary` with the expanded allow-list.
3. **Pools.** Node Pool Sizing `create-burst` creates both burst pools closed
   (`min=max=0`), then `configure-expander` sets the priority order.
4. **Deploy.** Deploy `deploy` to the `burst` contract behind the existing
   server-side dry runs, then Node Pool Sizing `enable-burst` opens the burst
   pools to 0/6 and 0/2.
5. **Acceptance** (below), ending in the ready-for-migration check.
6. **Migrate repositories** only after the ready-for-migration check passes, one PR per repository:
   `keel` CI, `aurolegal.ai` Class A workflows (and re-enable its fleet
   watchdog schedule), `superfood-shred` CI.

## Acceptance

Acceptance runs the `runner-burst-acceptance.yml` workflow in private
`redducklabs/aurolegal.ai`. It is dispatched from a unique annotated tag that
targets the reviewed workflow commit, receives that commit as
`expected_workflow_sha`, fails before any work if `github.sha` differs, and the
controller in this repository verifies the run's `headSha`. Each matrix job
writes a marker artifact, waits at an API barrier until N distinct runner
names are active (bounded by a timeout that fails the run), runs a Docker build
and container, and holds for evidence collection. The controller workflow
`runner-acceptance-evidence.yml` in this repository captures, while the jobs
hold, every runner PodSpec, its node and pool, node creation times, and
events. After completion it captures OOM, restart, eviction, and scheduling
events. Failure or timeout cancels the probe run and proceeds to cleanup
verification.

| Phase | Setup | Pass criteria |
|---|---|---|
| A. Primary burst from zero | burst pools at 0 nodes; priority expander configured; N=16 | 16 distinct runners concurrent; 4 on baseline; all burst nodes from the primary pool (proves priority order); warm and cold pickup within thresholds |
| B. Fallback from zero | Node Pool Sizing `set-burst-maxima` sets primary 0/0, fallback 0/2, both at 0 nodes; N=8 | 4 runners on baseline, 4 on two fallback nodes created from zero; fallback nodes pass node compatibility; primary restored to 0/6 afterwards |
| C. Idle retirement and return to zero | after A; Scale Runners `acceptance-phase-c` sets `minRunners=8` (4 idle runners must land on burst nodes because baseline holds 4); retirement runs with zero free baseline slots; then `minRunners` returns to 4 and then 2 | retirement deletes nothing while baseline is full; once ARC removes surplus runners, any idle runner left on a burst node is retired and replaced on baseline; both burst pools reach 0 nodes within 60 minutes; no job killed |
| D. Drain under continuing load | a probe that keeps 12 jobs in flight, submitting a new job as each finishes, while Deploy `drain` runs | in-flight jobs on burst nodes complete; every runner pod created after `drain` is on baseline; no Pending runner pod triggers scale-up; burst pools reach zero nodes |
| E. Restore and ready-for-migration | after D: Node Pool Sizing `remove-burst`, Deploy `rollback`, then rollout steps 3–4 again | `density` readback after rollback; then `burst` readback, three pools with expected IDs and bounds, expander readback, trust-boundary readback, two warm runners on baseline; an N=8 smoke run passes |

DigitalOcean permits `min_nodes=max_nodes=0` on an autoscaling pool; Phase B
uses that to make the fallback the only eligible burst group. There is no
alternate Phase B shape (PR #35 review finding 3): `create-burst` already
requires closed (0/0) pools, so a provider that rejected primary
`max_nodes=0` would have stopped the rollout there (`SCALE_TO_ZERO_REJECTED`).
If `set-burst-maxima` is nevertheless rejected, acceptance stops and Phase B
needs a reviewed change to the procedure and to `scripts/acceptance-verdict.py`
before it is re-run. Phase B does not reproduce a provider 422/backoff; that
path is covered by an autoscaler-status fixture and the documented upstream
behavior that backed-off groups are excluded from expansion, and is recorded as
untested live.

In Phase C the order in which ARC removes surplus idle runners is not
controllable. If a cycle ends with no idle runner on a burst node, it is
repeated up to three times; if retirement of a burst-node survivor is still not
observed, the acceptance record says retirement was exercised only by fixtures
and a follow-up is tracked. Phase C never passes on node scale-down alone
without recording which path occurred.

Only Phase E's ready-for-migration result authorizes repository migration. A
successful Phase D proves recovery and leaves the fleet drained.

## Rollback

Ordered CI recovery, each step reading back its postcondition before the next:

1. Deploy `drain`: Helm upgrade to the `drain` contract (max 4, required
   baseline affinity, safe-to-evict retained). In the same run, while holding
   the lock, it runs `retire-idle-burst-runners.sh` every 2 minutes and waits
   until no runner pod is on a burst node and both burst pools report zero
   nodes. Each drain run waits at most 300 minutes, inside GitHub-hosted
   runners' six-hour job limit; on timeout it fails, leaves the fleet in
   `drain`, and a re-run resumes the wait. Total drain time is unbounded by
   design: busy jobs are never interrupted.
2. Node Pool Sizing `remove-burst` observes zero nodes and no runner pods in
   both burst pools twice, with identity checks between the observations,
   resets the expanders to the default, and deletes the pools.
3. Deploy `rollback` upgrades to the committed `deploy/density-values.yaml`
   (validated as `density`; independent of Helm history, Ruling 34). With the
   burst pools gone, its unrestricted node selector can only match baseline.

A rollout that failed after `deploy` recovers by the same sequence; each step
is a no-op when its postcondition already holds. A rollout that failed before
`deploy` (ARC still `density`, burst pools closed) recovers with
`remove-burst` alone. If acceptance fails, rollback runs
before any repository migration PR merges. Migrated repositories revert their
`runs-on` PRs.

## Validation

- `test/verify-runner-resources.sh` asserts the `burst` contract: bounds,
  affinity, annotation, unchanged pod budget and DinD wiring, and two pods with
  the required headroom on both burst sizes' published allocatable.
- `verify-runner-pool-state.sh` fixtures: unknown eligible pool, wrong size,
  wrong label, missing or extra taint, burst max over the per-pool or aggregate
  limit, burst `min ≠ 0`, baseline drift, a burst node not Ready beyond 15
  minutes, a node with no pool label, and a valid mixed state with nodes in
  all three pools.
- Retirement fixtures: idle runner on burst (deleted), busy runner on burst
  (kept), `jobRequestId` set but GitHub `busy=false` (kept), baseline full
  (nothing deleted).
- Drain fixtures: `drain` contract rendering (required affinity, max 4,
  annotation), in-process retirement loop with idle burst runners and no new
  demand reaching empty pools, timeout leaving `drain` in place, and
  `rollback` refusing to run while burst pools exist.
- Shared-gate transition fixtures, each run through
  `verify-runner-pool-state.sh` with its operation argument as well as the
  template validator: `burst → drain → remove-burst → density`; a drain
  timeout followed by a drain retry; `remove-burst` retried after only one
  burst pool was deleted; `rollback` re-run on `density`; Deploy rejecting any
  non-canonical min/max pair (for example 2/10 or 4/20); `acceptance-phase-c`
  from `drain` rejected; an unknown operation rejected; recovery from a
  failed rollout after the first closed pool is created (`density` + one
  pool → `remove-burst`), after both pools and the expander but before Deploy
  (`density` + two pools → `remove-burst`), and after Deploy but before
  `enable-burst` (`burst` + closed pools → `drain → remove-burst →
  rollback`), each repeated on its own postcondition as a no-op.
- Phase C sequencing fixture: the `acceptance-phase-c` orchestration script
  run against mocked Helm, kubectl, and GitHub APIs, covering the success path
  (cleanup is a verified no-op), a failure at the 8-runner wait (cleanup
  restores `burst`), interruption while at 8/20 and while at 4/20 (a re-run
  restores `burst`; Deploy `drain` admits both), and a cancellation between
  the 4 and 2 steps.
- Maintenance fixtures: cluster status `upgrading`; an underfilled primary
  pool (`count=1`) with two registered nodes; a provisioning node not yet
  registered (accepted).
- Expander fixtures: ConfigMap rendered from resolved pool IDs, readback
  mismatch failing, managed labels preserved.
- Node Pool Sizing fixtures for create, reconcile, allowance transfer ordering,
  `remove-burst` refusing non-empty pools, and mismatched `expected_sha`
  failing before any mutating call.
- Trust-boundary fixture: a member that allows fork-PR workflows fails.
- Cost report fixtures: deleted-node invoice items, missing invoice.
- Emergency Stop fence fixtures (Ruling 36): the exact manifest contract;
  Deploy installing it before Helm after a dry-run comparison (defaulted,
  failed or drifted results stop before Helm); mutator admission refusing a
  missing or different fence; Emergency Stop's denial probe passing, absorbing
  informer lag, and failing red with the stop still applied; an acknowledged
  deploy waiting out informer lag; and a stale writer terminated right after a
  Helm write that the fake API server denies, leaving the fleet at 0/0 (with a
  control run where the server does not enforce, which reopens it).
- actionlint, shellcheck, YAML parsing, Helm render, and `validate-config.yml`
  pass.

## Runner network isolation

Added after an automated security review of the migration branches. The
`arc-runners` namespace has no NetworkPolicy today, so runner pods, which
include privileged DinD, can reach production pods and services in the same
cluster, node kubelets, and the VPC (`10.124.0.0/20`, including managed
databases). The DigitalOcean metadata service is already blocked for
non-exempt pods by a DOKS-managed policy (below). Adding
repositories and burst capacity widens that exposure, so isolation is a
prerequisite for repository migration.

`deploy/runner-network-policy.yaml` defines one `networking.k8s.io/v1`
NetworkPolicy, `redducklabs-runner-isolation`, in `arc-runners` selecting
`actions.github.com/scale-set-name=redducklabs-runners`, with
`policyTypes: [Ingress, Egress]`:

- Ingress: none allowed.
- Egress allowed only to:
  - kube-dns pods (`namespaceSelector` `kubernetes.io/metadata.name=kube-system`,
    `podSelector` `k8s-app=kube-dns`) on UDP and TCP 53;
  - `ipBlock` `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`,
    `192.168.0.0/16`, `100.64.0.0/10`, and `169.254.0.0/16`. Those ranges
    cover the pod CIDR `10.244.0.0/16`, the service CIDR `10.245.0.0/16`,
    the VPC, and node addresses.

DigitalOcean already blocks the metadata service for non-exempt pods: the
DOKS-managed CiliumClusterwideNetworkPolicy `deny-imds-egress`
(`doks.digitalocean.com/managed=true`) has `egressDeny` to
`169.254.169.254/32` for all endpoints not labeled
`doks.digitalocean.com/allow-imds-egress=true`. Cilium deny rules take
precedence over allows. The runner policy's `169.254.0.0/16` exception is
defense in depth; the gate additionally requires that no runner pod carries the
`allow-imds-egress` label.

Jobs keep internet access for GitHub, registries, and package mirrors. The
cluster's CNI is Cilium, which enforces NetworkPolicy, and service ClusterIP
translation happens before policy evaluation, so DNS through the kube-dns
service is admitted by the pod-selector rule. Runner pods already have no
Kubernetes API credentials (`automountServiceAccountToken: false`).

Kubernetes and Cilium policies are additive for allows, so the exact
readback of one object does not establish the boundary. The gate validates the
complete applicable policy set:

- NetworkPolicies in `arc-runners`: exactly one, named
  `redducklabs-runner-isolation`, whose `spec` equals the file.
- CiliumNetworkPolicies in `arc-runners`: none.
- CiliumClusterwideNetworkPolicies: each must be deny-only (no `egress`,
  `ingress`, or `enableDefaultDeny` set to `false` paired with allow rules;
  only `egressDeny`/`ingressDeny`), or the gate fails. The DOKS-managed
  `deny-imds-egress` satisfies this. A clusterwide allow policy anywhere
  fails the gate because its selector could match runner pods.
- The CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy CRDs not being
  installed counts as zero objects; any other API error fails the gate.

Deploy `deploy` admission does not require the policy, because Deploy
installs it: Deploy applies it with a server-side dry run, then
`kubectl apply --server-side`, then re-runs the full policy-set validation and
aborts before the Helm upgrade if it fails. The policy-set validation is
required on admission for `enable-burst`, `rebalance`, and
`acceptance-phase-c`, and as Deploy's postcondition. `drain` and `rollback`
leave the policy in place. It applies to the `density` fleet as well, which is
the current exposure.

Acceptance Phase A adds a network probe job (one batch entry) that must:
resolve `github.com` and fetch it over HTTPS; fail to connect to
`169.254.169.254:80`, to a `worker-pool` node's VPC address on `10250`
(kubelet) and `22`, to a baseline runner node's VPC address on `10250`, to the
`kubernetes.default` service on 443, to one ClusterIP service in another
namespace, and to one pod IP in another namespace. Any successful forbidden connection fails acceptance.
