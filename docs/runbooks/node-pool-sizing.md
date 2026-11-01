# Runbook: Runner Node Pools and Burst Autoscaling

Operating contract for the GitHub Actions runner fleet after the burst design
(`docs/specs/2026-10-26-runner-burst-autoscaling-design.md`). It supersedes the
fixed two-node / four-runner cap. Every change runs through CI from a reviewed
commit, passed as `expected_sha`; nothing here is done from a workstation.

- **Cluster:** `redducklabs-cluster` (context `do-sfo3-redducklabs-cluster`, region sfo3)
- **Runner labels/taint (every runner pool):** `node-type=github-runner`,
  `workload-type=ci-cd`, single taint `github-runner=true:NoSchedule`
- **Pod budget (unchanged):** 3 CPU / 5 GiB request, 6 GiB shared limit for the
  runner and its privileged DinD sidecar; two pods fit one 16 GB node.

## Pools

| Pool | Size | min | max | Role | Cost |
|---|---|---|---|---|---|
| `github-runners-pool-16g` | `s-8vcpu-16gb` | 2 | 2 (`count=2`) | baseline, two warm runners | $192/month fixed |
| `github-runners-burst-amd-16g` | `s-8vcpu-16gb-amd` | 0 | 6 | primary burst (priority 100) | $0.16667/node-hour |
| `github-runners-burst-intel-16g` | `s-8vcpu-16gb-intel` | 0 | 2 | fallback burst (priority 50) | $0.16667/node-hour |

The burst pools deliberately avoid the baseline's `s-8vcpu-16gb`: on
2026-10-28 DigitalOcean refused to create a pool of that size in `sfo3`
(spec "Burst pool sizes (Ruling 38)"). The burst maxima sum to at most 8, so
the autoscaler can never run more than 10 runner nodes (worst case
$1,088/month if every node ran all month). ARC runs
`minRunners=2`, `maxRunners=20`: two warm runners prefer baseline (weight-100
affinity) and every runner pod carries
`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so a node with a job
on it is never scaled down. Idle runners stranded on burst nodes are retired by
**Rebalance Runners** (hourly) and by Deploy `drain`.

A DOKS surge upgrade temporarily adds duplicate nodes; while one exists the
pool-state gate (cluster not `running`, or more registered nodes than a pool's
`count`) fails every fleet mutation until maintenance finishes.

## ARC contracts

| Contract | min/max | Placement | Reached by |
|---|---|---|---|
| `density` | 2/4 | no pool preference | the pre-burst release, committed as `deploy/density-values.yaml`; Deploy `rollback` |
| `burst` | 2/20 | preferred baseline, safe-to-evict | Deploy `deploy` |
| `burst-acceptance` | 8/20 or 4/20 | as `burst` | only inside Scale Runners `acceptance-phase-c` |
| `drain` | 2/4 | **required** baseline, safe-to-evict | Deploy `drain` |
| `burst-stopped` | 0/0 | the `burst` template | Emergency Stop from `burst` or `burst-acceptance` |
| `density-stopped` | 0/0 | the `density` template | Emergency Stop from `density` |
| `drain-stopped` | 0/0 | the `drain` template | Emergency Stop from `drain` |

There is no ordinary min/max scaling: bounds change only by a reviewed commit to
`deploy/dind-values.yaml` followed by Deploy. The three `stopped` states are
what Emergency Stop leaves (see "Emergency Stop" below); only the recovery
paths admit them.

## Operations

All mutating workflows verify `expected_sha` first, share the non-cancelling
`runner-fleet-mutation` concurrency group (except Emergency Stop,
`runner-emergency-stop`, and Rebalance, `runner-rebalance`; see below), admit
the live state with
`scripts/verify-runner-pool-state.sh --operation <op>`, and bracket every
mutation with the identity contract (cluster ID, baseline pool ID and baseline
node UID/providerID pairs never change; only the declared transition may).
Every Helm write passes `--history-max 100`. Rollback does not depend on Helm
history: it upgrades to the committed `deploy/density-values.yaml` (the
reviewed values of the pre-burst release), so no revision has to survive the
rollout. While an Emergency Stop marker exists, every workflow below refuses to
run except as described in "Emergency Stop".

| Workflow / input | Operation | Admits | Effect |
|---|---|---|---|
| Deploy GitHub Runners `operation=prepare-trust-boundary` (co-tenancy accepted) | trust boundary | admission evidence committed | runner group readback equals `deploy/trusted-runner-repositories.txt` |
| Scale Runners `action=record-density` | read-only | `density` | verifies the live release is density 2/4 and equals the render of `deploy/density-values.yaml` (the rollback target) |
| Node Pool Sizing `create-burst` (`apply`) | create pools closed | `density`/`burst`, 0–2 closed pools | both burst pools at `min=max=count=0` |
| Node Pool Sizing `configure-expander` (`apply`) | expander | both pools present | `--expanders priority,random` and the priority ConfigMap |
| Deploy GitHub Runners `operation=deploy` (co-tenancy accepted; `acknowledge_emergency_stop` to recover from a stop) | Emergency Stop fence and runner NetworkPolicy, then Helm to `burst` | `density`/`burst`/`burst-stopped`, pools present, expander configured | fence equals `deploy/runner-emergency-stop-fence.yaml` and runner network policy set valid (both checked before Helm); ASRS, values and manifest equal `burst` |
| Node Pool Sizing `enable-burst` (`apply`) | open pools | `burst`; stages 0/0+0/0, 0/6+0/0, 0/6+0/2; runner network policy set valid | primary 0/6, then fallback 0/2 |
| Node Pool Sizing `set-burst-maxima` (`primary_max`, `fallback_max`, `apply`) | move allowance | `burst`, both pools | lowers the donor first, reads back, then raises |
| Rebalance Runners (hourly; dispatch with `expected_sha`) | retire idle burst runners | `burst`, `drain`; the stopped states or the Emergency Stop marker (notice only); runner network policy set valid | deletes idle burst-node EphemeralRunners only; skips with a notice while any fleet mutator is queued or running |
| Scale Runners `action=acceptance-phase-c` | acceptance Phase C | `burst` (or interrupted `burst-acceptance`), burst enabled, runner network policy set valid | one lock-owning run; ends at `burst`; uploads `phase-c-evidence` |
| Deploy GitHub Runners `operation=drain` | Helm to `drain`, wait | `burst`, `burst-acceptance`, `drain`, `burst-stopped` (no stop marker) | no runner pod on a burst node; burst pools at zero nodes |
| Node Pool Sizing `remove-burst` (`apply`) | delete pools | `drain`/`drain-stopped`, or `density`/`density-stopped` with closed empty pools (also while the stop marker exists) | expanders reset; only baseline remains |
| Deploy GitHub Runners `operation=rollback` (`acknowledge_emergency_stop` to recover from a stop) | Emergency Stop fence, then Helm upgrade to `deploy/density-values.yaml` | `drain`/`drain-stopped`/`density-stopped`/`density`, burst pools absent, the committed values validate as `density` | `density` readback, trust readback |
| Emergency Stop Runners (`confirm=STOP-RUNNERS`) | stop marker, fence enforcement proof (dry-run denial), then Helm `--reuse-values` to 0/0 | any release (runs immediately, own group) | a `stopped` state and marker readback and the recovery to use; red if the fence did not deny the probe |
| Runner Acceptance Evidence (`phase`, run IDs, `expected_sha`) | read-only evidence | any | acceptance verdict; cancels only its verified probe |
| Runner Status | read-only | any | pools, burst node count per pool, ARC state |
| CI Usage Report | read-only (GitHub API only) | any | fleet vs hosted job-minutes, hosted cost estimate, fleet concurrency and queue wait |

Node Pool Sizing runs without `apply` are dry runs that print the planned calls;
run one first and read it. `scripts/runner-cost-report.sh --month YYYY-MM`
reports runner node-hours and cost per cluster and node size from the invoice,
with burst node-hours derived as runner node-hours minus two baseline nodes for
the period (DigitalOcean does not itemize per pool).

### Tuning the burst ceiling and warm floor

The weekly **CI Usage Report** (`scripts/ci-usage-report.sh`, read-only, see
the README's "CI Usage and Fleet Concurrency") measures demand on the fleet
from the GitHub jobs API. Read it before proposing a bounds change:

- **`maxRunners` (20) and the burst pool maxima.** Minutes at >= 20 concurrent
  fleet jobs are time the fleet was at its ceiling; with a high fleet queue wait
  p95 they mean jobs waited for a runner rather than a node. Minutes at >= 16
  show how close demand runs to the ceiling. Max concurrency well below 20 over
  several weeks is evidence for a lower ceiling (fewer burst nodes at the cost
  cap); repeated time at 20 is evidence for a higher one, which also needs the
  burst pool maxima and the 10-node cost cap revisited.
- **`minRunners` (2, the warm floor).** Minutes at >= 4 are time at or above the
  two baseline nodes' capacity (they hold exactly four jobs); demand beyond the
  baseline starts at 5 concurrent jobs. These count jobs, not burst-node
  residency or node-hours (the cost report measures those). A fleet queue wait p50 near the
  cold-start time (a burst node boot) means most jobs found no warm runner; a
  p50 of seconds means the warm floor absorbs typical demand. p50/p95
  concurrency is time-weighted over the whole week, idle nights and weekends
  included.
- **Hosted cost.** The estimated hosted list-price cost and the hosted minutes
  show what still runs GitHub-hosted (by design: secret-handling jobs, public
  repositories, Windows/macOS) and what moving it would save. The workflow
  publishes organization totals only (this repository is public); for the
  per-repository breakdown run `scripts/ci-usage-report.sh --per-repo` in your
  own terminal and do not paste its output into this repository's issues, PRs
  or logs.

Any bounds change is a reviewed commit to `deploy/dind-values.yaml` (and Node
Pool Sizing `set-burst-maxima` for the pools) followed by Deploy, as above.

### Failure rules

- **Asynchronous pool delete (`remove-burst`).** DOKS accepts a node-pool
  delete before the pool leaves the list. After each delete `remove-burst`
  re-reads the pool list every 10 s for up to 300 s, then runs the identity
  check (Ruling 49). A pool still listed at the deadline fails the run before
  the next pool is touched, so the fallback is left as it was; re-dispatch
  `remove-burst`, which treats already-absent pools as a no-op and continues.
- **No Helm retry.** A failed Helm upgrade inside the identity bracket fails
  the run. Read the failure, then re-dispatch the same operation: the re-run
  re-admits the live state and is a no-op on its own postcondition.
- **`STOP_FENCE`.** A Deploy, drain, Phase C or rollback run whose Helm write
  found an Emergency Stop in effect (or could not read the stop marker)
  re-applied 0/0 and failed. The fleet is stopped; recover as in "Emergency
  Stop". Do not re-dispatch the failed operation without the acknowledgement.
  With the server-side fence installed the stale write itself is usually
  denied (Helm reports `ValidatingAdmissionPolicy
  'runner-fleet-emergency-stop-fence' ... denied request`); the run still
  re-applies 0/0 and fails the same way.
- **Emergency Stop fence missing or different.** Admission fails with
  `requires the Emergency Stop fence runner-fleet-emergency-stop-fence`. Run
  Deploy `deploy` (from `density`, `burst` or `burst-stopped`) or `rollback`
  (from the drain/density states, burst pools absent); both reinstall
  `deploy/runner-emergency-stop-fence.yaml`. From `drain-stopped` run
  `remove-burst` first (it does not require the fence), then `rollback`.
- **`SCALE_TO_ZERO_REJECTED`.** If DigitalOcean refuses a closed (`0/0`) burst
  pool, `create-burst` stops and creates nothing further. Stop the rollout and
  re-plan. Never work around it with `min_nodes=1`: that is a permanent cost
  floor the design rejects. Recover with `remove-burst` if one pool was created.
- **Regional capacity (`422 ... region has insufficient capacity for requested
  worker pool for slug: <size>`).** DigitalOcean checks regional stock for the
  size even for a closed (`0/0`) pool. `create-burst` fails with `RESULT:
  failed: create closed pool <name> failed (exit 1; identities unchanged); no
  further mutation`; nothing is created by that call. Read `PLAN`/`RESULT` to
  see whether the other burst pool was created earlier in the run (recover
  with `remove-burst` if the rollout stops). Do not swap in another size from a
  workstation or a workflow input: pool sizes are fixed in
  `scripts/lib/runner_pool_state.py`, and a different size is a reviewed
  re-plan (Ruling 38 replaced `s-8vcpu-16gb` this way). Retrying the same
  run later is safe; it re-admits and is a no-op for pools that already exist.
- **`IDENTITY_DRIFT` on a closed pool's bounds (`expected=0 live=null`).**
  `doctl ... node-pool list -o json` omits zero-valued fields, so a closed
  pool has no `count`, `min_nodes` or `max_nodes` key (Ruling 39). Before the
  fix, Node Pool Sizing `create-burst` run 40721560476 created the closed
  primary `github-runners-burst-amd-16g` and then failed its readback with
  `IDENTITY_DRIFT: pools.github-runners-burst-amd-16g.max_nodes: expected=0
  live=null` (the same for `min_nodes`); the fallback was not created. Every
  reader now treats an absent key as `0`. Re-dispatch `create-burst` on a
  main that contains the fix: it admits the live state (ARC `density`,
  primary closed, fallback absent), prints `NOOP: pool
  'github-runners-burst-amd-16g' already exists closed (0/0)`, creates only
  the fallback and completes the step. Do not delete the primary by hand. An
  `IDENTITY_DRIFT` or `... is not a non-negative integer` that names an
  explicit `null` (a key that is present) is still a real provider anomaly and
  still fails closed.
- **Priority-expander ConfigMap not created yet (`configmaps
  "cluster-autoscaler-priority-expander" not found`).** DOKS creates
  `kube-system/cluster-autoscaler-priority-expander` only after the priority
  expander is enabled on the cluster (Ruling 40). Before the fix, the first
  `configure-expander` dry run (Node Pool Sizing run 40739557666, main
  `4d7134f`) failed with `ERROR: could not read ConfigMap
  kube-system/cluster-autoscaler-priority-expander`; nothing was changed.
  With the fix, the dry run prints `PLAN: wait up to 600s for DOKS to create
  ConfigMap ...` with the priorities it will write, and succeeds. The apply
  sets the expanders, prints a `WAIT:` line for each read that still finds
  no ConfigMap (every 15 s), then patches `data.priorities` and reads it back. If
  DOKS has not created it within 600 s, the run fails with `RESULT: failed:
  ConfigMap kube-system/cluster-autoscaler-priority-expander still absent
  after waiting 600s (41 reads, every 15s) ...`. The expanders are then
  `priority,random`, but both burst pools are still closed (`0/0`), so no
  burst node can start and the fleet is unchanged. Re-dispatch
  `configure-expander` (`apply`): it prints `NOOP: cluster expanders already
  priority,random`, waits again and writes the priorities. If repeated
  re-runs time out, check read-only with `kubectl get configmap
  cluster-autoscaler-priority-expander -n kube-system`. Do not create or
  rename the ConfigMap by hand, and do not remove its `doks` labels; DOKS
  manages it. Any other read error, such as `Forbidden` or an unreachable API
  server, still fails closed straight away.
- **Baseline node replacement during a shortage.** The baseline pool still
  uses `s-8vcpu-16gb`. Its two existing nodes are unaffected, but if DOKS
  replaces one (node repair, recycle or a cluster upgrade) the new droplet
  can hit the same shortage. What you see: the pool-state check (Runner Status
  and every fleet mutation) reports `baseline pool must have exactly two Ready
  nodes; found 1 Ready of ...` (or the maintenance check fails while a surge
  node is pending), so every fleet mutation fails closed; jobs keep running on the
  remaining baseline node and, while burst is open, on the AMD/Intel burst
  pools, which can absorb the warm runners that no longer fit on baseline. What
  you do: nothing in these workflows changes the baseline pool, so do not try
  to fix it with them. Check `doctl kubernetes cluster node-pool get
  redducklabs-cluster github-runners-pool-16g` (read-only) for a node that
  stays not running, and look for the same capacity text in its status. If
  the fleet must shrink while you wait, Deploy `drain` is refused by the same
  gate; use Emergency Stop. Once DigitalOcean provides the droplet the gate
  passes again. If the shortage persists, moving the baseline to another size
  is a reviewed re-plan of the spec (new pool, `count=2`, and new baseline
  identities), not a runbook action.
- **Fork-PR policy read.** `prepare-trust-boundary` re-reads
  `GET /repos/{owner}/{repo}/actions/permissions/fork-pr-workflows-private-repos`
  for every member with `RUNNER_TOKEN`, which therefore needs repository
  administration read access on every member. Without it the read fails and
  the operation fails closed with no runner-group change; grant the read and
  re-dispatch. Do not remove the check.
- **Phase C restore.** The always-run "Restore burst after Phase C" step
  re-checks release identity and the live contract before returning ARC to
  `burst`, but it does not repeat the full pool-state admission (the run already
  holds the lock and was admitted at its start). If it fails, the fleet may be
  left at `burst-acceptance`; recover with a re-run of `acceptance-phase-c`
  (which restores `burst` first) or with Deploy `drain`.
- **Fresh cluster.** The gate requires an existing ARC release
  (`redducklabs-runners`, chart `gha-runner-scale-set-0.14.2`, `deployed`) and
  controller release. A new or rebuilt cluster cannot be brought up with these
  workflows; it needs a separate, reviewed bootstrap procedure (first Helm
  install) before this runbook applies.

## Rollout order

Run every step from the same reviewed `main` commit and record it in the
Rollout record below.

1. **Verify the rollback target.** Scale Runners `action=record-density`. It
   verifies that the live release equals the render of
   `deploy/density-values.yaml`, the target Deploy `rollback` restores; if it
   fails, stop and reconcile that file by a reviewed commit first.
2. **Trust boundary.** Deploy GitHub Runners `operation=prepare-trust-boundary`,
   co-tenancy accepted.
3. **Pools.** Node Pool Sizing `create-burst` (dry run, then `apply`), then
   `configure-expander` (dry run, then `apply`).
4. **Deploy.** Deploy GitHub Runners `operation=deploy`, co-tenancy accepted,
   then Node Pool Sizing `enable-burst` with `apply`.
5. **Acceptance** phases A–E below.
6. **Migrate repositories** only after Phase E prints
   `READY_FOR_MIGRATION=true` and the Emergency Stop drill below passed, one
   PR per repository: `keel` CI,
   `aurolegal.ai` Class A workflows (and re-enable its fleet watchdog
   schedule), `superfood-shred` CI.

A rollout that failed before `deploy` (ARC `density`, pools closed) recovers
with `remove-burst` alone. One that failed after `deploy` recovers with the
Rollback sequence. Each step is a no-op on its own postcondition.

## Acceptance

The probe is `.github/workflows/runner-burst-acceptance.yml` in private
`redducklabs/aurolegal.ai`, merged to its `main` by the owner. It is always
dispatched from a **new annotated tag** on the reviewed commit and receives that
commit as `expected_workflow_sha`; it fails before any work if `github.sha`
differs. Modes: `batch` (`jobs` 1..20 entries; each waits until `jobs` entries
are in progress on distinct runners, then runs a Docker build and container and
holds 10 minutes) and `continuous` (64 entries, `max-parallel: 12`, each runs
Docker and holds 4 minutes). In `batch` mode with `network_targets` set
(Phase A), a `network-probe` job runs after the entries and checks the runner
network isolation from inside a runner pod (spec "Runner network isolation"):
DNS and HTTPS to github.com must work; the metadata service
`169.254.169.254:80`, a `worker-pool` node's kubelet (`10250`) and SSH (`22`),
a baseline runner node's kubelet on its VPC address, a runner node's public
(ExternalIP) address on `10250` and `22`, `kubernetes.default:443`, a ClusterIP
service and a pod in other namespaces must time out. It prints one
`NETWORK_PROBE_RESULT` line and fails on any mismatch.

The controller is **Runner Acceptance Evidence** in this repository. It verifies
the probe run (repository, workflow path, `headSha`, `event=workflow_dispatch`,
attempt 1, dispatch tag resolving to `expected_workflow_sha`) before reading the
cluster, captures runner PodSpecs, node and pool placement, node creation times
and events while the probe holds, evaluates `scripts/acceptance-verdict.py`, and
uploads `acceptance-<phase>.json`. On a failure or its deadline (batch 45
minutes, continuous 150, Phase C 300) it runs `gh run cancel` on the probe,
waits up to 10 minutes for `completed`, and verifies that no probe job is queued
or running and no runner is assigned to it. Its GitHub reads, the cancel, and
the trust readback use `RUNNER_TOKEN`, which needs read access to
`redducklabs/aurolegal.ai` Actions plus permission to cancel its runs.

Runner count (Ruling 43): ARC 0.14.2 targets `minRunners` plus the assigned
jobs, so a batch of N jobs runs N + 2 runner pods, two of them idle. Phase A
therefore runs 14 jobs (16 pods: 4 baseline + 12 on six primary nodes) and
Phase B 6 jobs (8 pods: 4 baseline + 4 on two fallback nodes); the placement
criteria count every runner pod of the scale set seen during the hold, probe
and idle runners alike, from the evidence run's collections whose pod read
(request to response, retries included) lies wholly inside the hold (the latest
must show the exact placement; none may list more pods or another pool), so
the evidence run must be collecting before the hold ends. The probe's barrier waits for `jobs` entries in
progress, so the two idle runners do not affect it. Do not raise the batch
sizes: 16 jobs (18 pods) overflow into the fallback and fail `A-primary-only`.
Idle runners can stay on burst nodes after a batch; Rebalance Runners retires
them (hourly, or dispatch it as below).

Exclusive fleet (Ruling 44): phases A and B need the fleet to themselves. If
another repository's CI holds a runner during the hold (any EphemeralRunner
in the evidence run's runner reads, with or without a pod), `A-shared-fleet` /
`B-shared-fleet` fail with "re-run this phase while no other repository's CI
uses the fleet". Before dispatching A or B, check that no runner holds a job
(read-only; prints nothing when the fleet is quiet):

```bash
kubectl -n arc-runners get ephemeralrunners -o json \
  | jq -r '.items[] | select(.status.jobId or .status.jobRequestId or .status.jobRepositoryName
      or .status.jobWorkflowRef or .status.workflowRunId)
      | "\(.metadata.name) \(.status.jobRepositoryName) run \(.status.workflowRunId)"'
```

Dispatch at a quiet time and re-run the phase if a job arrived anyway.
`A-priority` / `B-priority` read the cluster-autoscaler's `TriggeredScaleUp`
and `ScaledUpGroup` events, aggregated "(combined from similar events): "
messages included. In A (Ruling 45) every fallback scale-up must come strictly
after a primary scale-up to 6 of 6; fallback nodes without runner pods are
reported as a cost signal and do not fail A (a from-zero burst can add up to
two extra fallback nodes for ten minutes or more while the primary nodes boot).
Only runner node groups are judged (Ruling 46): a scale-up of a pool that
cannot host runner pods (for example `worker-pool`) is noted as unrelated
demand, while one naming the baseline or an unknown node group ID fails.
In B every scale-up must name only the fallback, and an aggregated
"(combined from similar events): " event fails `B-priority` (its earlier
occurrences may have named the primary); re-run Phase B if it happens. The
extra fallback nodes' cost is read from their measured lifetime in the Runner
Cost Report.

Pickup thresholds for phases A, B and E: warm pickup p95 ≤ 90 s, cold pickup
p95 ≤ 8 minutes (a job is cold when its runner's node was created after the job
was queued). Phase D has no pickup criterion: the drain caps the fleet at four
runners by design. Every phase also fails if a runner container was OOMKilled,
restarted or evicted (container statuses and events). The record keeps every
runner PodSpec with literal env values redacted.

Dispatch pattern (replace the tag, SHAs and run IDs; `$AURO` is the reviewed
aurolegal.ai commit, `$SHA` this repository's reviewed commit):

```bash
# Phase A network probe targets (read-only lookups; addresses only):
# a worker-pool node's VPC address, a baseline runner node's VPC and public
# addresses, the metrics-server ClusterIP service, and the metrics-server pod
# on its container port. Do not use a kube-dns pod: the runner policy allows
# egress to kube-dns, and the verdict rejects it as a forbidden target.
WORKER=$(kubectl get nodes -l doks.digitalocean.com/node-pool=worker-pool \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
RUNNER_NODE=$(kubectl get nodes -l doks.digitalocean.com/node-pool=github-runners-pool-16g \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
RUNNER_PUBLIC=$(kubectl get nodes -l doks.digitalocean.com/node-pool=github-runners-pool-16g \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
SERVICE=$(kubectl get service metrics-server -n kube-system -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')
POD=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server \
  -o jsonpath='{.items[0].status.podIP}:{.items[0].spec.containers[0].ports[0].containerPort}')
TARGETS="worker_node=${WORKER} runner_node=${RUNNER_NODE} runner_node_public=${RUNNER_PUBLIC} service=${SERVICE} pod=${POD}"

TAG=runner-burst-acceptance-$(date -u +%Y%m%d-%H%M%S)
git -C aurolegal.ai tag -a "$TAG" "$AURO" -m "runner burst acceptance"
git -C aurolegal.ai push origin "$TAG"
gh workflow run runner-burst-acceptance.yml -R redducklabs/aurolegal.ai --ref "$TAG" \
  -f expected_workflow_sha="$AURO" -f mode=batch -f jobs=14 -f network_targets="$TARGETS"
PROBE=$(gh run list -R redducklabs/aurolegal.ai -w runner-burst-acceptance.yml -b "$TAG" \
  -L 1 --json databaseId -q '.[0].databaseId')
gh workflow run runner-acceptance-evidence.yml -R redducklabs/redducklabs-runners \
  -f phase=A -f probe_run_id="$PROBE" -f dispatch_tag="$TAG" \
  -f expected_workflow_sha="$AURO" -f expected_sha="$SHA"
```

Dispatch the evidence workflow immediately after the probe; it must observe the
probe while it holds. Use a new tag for every probe run (set `TAG`, push it, and
look up `PROBE` as above before each phase). Shared variables:

```bash
FLEET=redducklabs/redducklabs-runners
AURO_REPO=redducklabs/aurolegal.ai
probe() {  # mode [jobs]
  gh workflow run runner-burst-acceptance.yml -R "$AURO_REPO" --ref "$TAG" \
    -f expected_workflow_sha="$AURO" -f mode="$1" -f jobs="${2:-14}"
}
latest() {  # workflow file in $FLEET -> newest run ID
  gh run list -R "$FLEET" -w "$1" -L 1 --json databaseId -q '.[0].databaseId'
}
```

Phase B (fallback from zero):

```bash
# First wait until no fleet job is running and both burst pools show 0 nodes
# (dispatch Rebalance Runners if idle runners hold burst nodes). DigitalOcean
# rejects a maximum below the pool's current node count with 422 "number of
# nodes out of min/max range", so lowering the primary while it still has
# nodes fails; burst-pools.sh then changes nothing. Wait and re-run it.
gh workflow run node-pool-sizing.yml -R "$FLEET" -f operation=set-burst-maxima \
  -f primary_max=0 -f fallback_max=2 -f apply=true -f expected_sha="$SHA"
# wait for that run to succeed and both burst pools to still show 0 nodes, then:
probe batch 6    # 8 runner pods; then set PROBE as above
gh workflow run runner-acceptance-evidence.yml -R "$FLEET" -f phase=B \
  -f probe_run_id="$PROBE" -f dispatch_tag="$TAG" -f expected_workflow_sha="$AURO" -f expected_sha="$SHA"
# when the probe run completes (the evidence run waits up to 30 minutes):
gh workflow run node-pool-sizing.yml -R "$FLEET" -f operation=set-burst-maxima \
  -f primary_max=6 -f fallback_max=2 -f apply=true -f expected_sha="$SHA"
```

Phase C (idle retirement; no probe):

```bash
gh workflow run scale-runners.yml -R "$FLEET" -f action=acceptance-phase-c -f expected_sha="$SHA"
PHASE_C=$(latest scale-runners.yml)
gh workflow run runner-acceptance-evidence.yml -R "$FLEET" -f phase=C \
  -f phase_c_run_id="$PHASE_C" -f expected_sha="$SHA"
```

Phase D (drain under continuing load):

```bash
probe continuous    # then set PROBE as above; wait until about 12 entries run
gh workflow run deploy-runners.yml -R "$FLEET" -f operation=drain -f expected_sha="$SHA"
DRAIN=$(latest deploy-runners.yml)
gh workflow run runner-acceptance-evidence.yml -R "$FLEET" -f phase=D \
  -f probe_run_id="$PROBE" -f drain_run_id="$DRAIN" -f dispatch_tag="$TAG" \
  -f expected_workflow_sha="$AURO" -f expected_sha="$SHA"
```

Phase E (restore and ready-for-migration): after Phase D, run Node Pool Sizing
`remove-burst` (`apply=true`), Deploy `rollback`, then rollout steps 3–4.

```bash
gh workflow run deploy-runners.yml -R "$FLEET" -f operation=rollback -f expected_sha="$SHA"
ROLLBACK=$(latest deploy-runners.yml)   # wait for it to succeed, then rollout steps 3-4
BASELINE_RUN=<the passing Phase A Runner Acceptance Evidence run ID>
probe batch 8    # 10 runner pods; then set PROBE as above
gh workflow run runner-acceptance-evidence.yml -R "$FLEET" -f phase=E \
  -f probe_run_id="$PROBE" -f rollback_run_id="$ROLLBACK" -f baseline_run_id="$BASELINE_RUN" \
  -f dispatch_tag="$TAG" -f expected_workflow_sha="$AURO" -f expected_sha="$SHA"
# when the probe run completes, retire the two idle runners left on burst
# nodes (the evidence run waits up to 30 minutes for two warm runners on baseline):
gh workflow run rebalance-runners.yml -R "$FLEET" -f expected_sha="$SHA"
```

After Phases A and B the two idle runners can also hold burst nodes. Phase C
needs both burst pools at 0 nodes, so dispatch Rebalance Runners the same way
after the evidence run completes instead of waiting for the hourly run.

The evidence run verifies the probe first and marks it for cleanup, then the
anchor runs; a rejected anchor run still cancels the verified probe, and the
cleanup still gets cluster access to prove no runner is left assigned to it.

| Phase | Setup | Probe | Evidence dispatch | Pass criteria |
|---|---|---|---|---|
| A. Primary burst from zero | burst pools at 0 nodes; expander configured; runner network policy set valid | `batch`, `jobs=14` (16 runner pods), `network_targets` | `phase=A`, probe | 14 distinct concurrent runners; during the hold, of every runner pod of the scale set (probe and idle), exactly 4 on baseline and 12 on the primary pool, none elsewhere, and no runner pod on the fallback in any in-hold collection (fallback nodes alone are a reported cost, Ruling 45); no other run's job on the fleet during the hold (`A-shared-fleet`); every fallback scale-up strictly after a primary scale-up to 6 of 6 (`A-priority`); `A-compatibility`: a passing pool-state check (compatibility, headroom) covering every primary node, the first live measurement of `s-8vcpu-16gb-amd` allocatable; no burst node predates the probe; expander readback; pickup thresholds; `A-network`: the `network-probe` job succeeded on a fleet runner, every allowed target connected and every forbidden target timed out, and the evidence workflow resolved the targets in the cluster (a `worker-pool` node's InternalIP, a baseline node's InternalIP, a runner node's ExternalIP, the `default/kubernetes` ClusterIP, a declared port of a ClusterIP service and of a pod outside `arc-runners` that is not a kube-dns pod) |
| B. Fallback from zero | `set-burst-maxima primary_max=0 fallback_max=2`; both at 0 nodes | `batch`, `jobs=6` (8 runner pods) | `phase=B`, probe; **after the probe completes, run `set-burst-maxima primary_max=6 fallback_max=2`** (the evidence run waits up to 30 minutes for it) | 6 distinct concurrent runners; during the hold, of every runner pod of the scale set, exactly 4 on baseline and 4 on exactly two new fallback nodes, none on the primary and none unscheduled; no other run's job on the fleet during the hold (`B-shared-fleet`); every cluster-autoscaler scale-up event names only the fallback (`B-priority`); a passing pool-state check (compatibility, headroom) covering both fallback nodes, the first live measurement of `s-8vcpu-16gb-intel` allocatable; primary back at 0/6; pickup thresholds |
| C. Idle retirement and return to zero | after A, pools at 0 nodes | none | dispatch Scale Runners `acceptance-phase-c`, then `phase=C`, `phase_c_run_id` | every cycle 4 baseline + 4 burst at minRunners=8 with nothing retired; a burst survivor retired (or three cycles recorded `fixture-only`, which passes with a tracked follow-up); burst pools at zero nodes within 60 minutes; `jobs_killed=0` (fleet jobs, on `redducklabs-runners-*` runners, cancelled or failed with `completed_at` inside the Phase C run, in every attempt of every workflow run created up to 65 days before it, measured by the evidence workflow); ARC `burst` |
| D. Drain under continuing load | after C | `continuous` | start the probe, wait until about 12 entries run, dispatch Deploy `drain`, then `phase=D`, probe, `drain_run_id` | drain run is this repository's Deploy `drain` at `$SHA`, success; ≥ 8 entries in progress when its "Drain runners" step started; ≥ 1 in progress throughout until it completed, except gaps of at most 90 s (the warm pickup threshold) while ARC replaces ephemeral runners at the drain cap, reported as `max_gap_seconds` (Ruling 48); entries still queued or running when it completed; every entry succeeded; every scheduled runner pod created after the drain READBACK is on baseline (pods never seen scheduled are reported, not failed); no `TriggeredScaleUp` for a runner pod after it; burst pools at zero nodes; ARC `drain` |
| E. Restore and ready-for-migration | after D: `remove-burst`, Deploy `rollback`, then rollout steps 3–4 | `batch`, `jobs=8` (10 runner pods) | `phase=E`, probe, `rollback_run_id`, `baseline_run_id`; **after the probe completes, dispatch Rebalance Runners** (the evidence run waits up to 30 minutes for two warm runners on baseline) | rollback run succeeded with its density readback and completed before the smoke probe was created; ARC `burst`; baseline 2/2/2, primary 0/6, fallback 0/2 with three distinct IDs and the baseline pool ID equal to the Phase A record's (that evidence run at the reviewed SHA or a commit before it, Ruling 50); expander readback; trust readback; exactly two warm runners, both on baseline, observed in the evidence workflow's final collection (`latest_collection_at`): Running, Ready, not terminating and idle; smoke run passes; prints `READY_FOR_MIGRATION=true` |

Phase B note: there is no alternate Phase B shape. `create-burst` already
created both pools at `max_nodes=0`, so DigitalOcean accepts a closed primary. A
rejection while the primary still has nodes ("number of nodes out of min/max
range") is a setup-order error, not this case: wait for 0 nodes and re-run. If
the `set-burst-maxima primary_max=0` run is rejected with the primary at 0
nodes, stop acceptance: Phase B needs a reviewed change to this procedure and to
`scripts/acceptance-verdict.py` (which accepts only primary 0/0, six jobs and
4 baseline + 4 fallback runner pods) before it is re-run. A provider 422/backoff is
not reproduced live; that path is covered by fixtures and the documented
autoscaler behavior and is recorded as untested live.

Phase C note: ARC chooses which surplus runners to remove. If no idle runner is
left on a burst node in three cycles, the result is `fixture-only`; record it
and track a follow-up. Phase C never passes on node scale-down alone without
recording which path occurred.

Phase A network probe: the evidence workflow reads the `network-probe` job log
(`NETWORK_PROBE_RESULT`) and checks the targets read-only (`kubectl get nodes`,
`kubectl get services -A`, and the pod by `status.podIP`). A forbidden
connection that succeeds or is refused (the path is open) fails `A-network`, as
does a target that does not resolve to the kind of object the spec names.

**Emergency Stop drill (after Phase E, before any migration).** Prove the
server-side fence (Ruling 36) live while only the acceptance probe uses the
fleet (no probe running):

```bash
# Read-only: the fence Deploy installed equals the committed file.
python3 -B scripts/lib/runner_stop_fence.py verify --require-type-checked
gh workflow run emergency-stop.yml -R "$FLEET" -f confirm=STOP-RUNNERS \
  -f reason="acceptance drill: server-side stop fence"
STOP=$(latest emergency-stop.yml)
gh run watch "$STOP" -R "$FLEET" --exit-status
gh run view "$STOP" -R "$FLEET" --log | grep -E 'STOP_FENCE_PROBE|API server denies'
# Recover: burst-stopped -> burst.
gh workflow run deploy-runners.yml -R "$FLEET" -f operation=deploy \
  -f accept_privileged_runner_co_tenancy=true -f acknowledge_emergency_stop=true -f expected_sha="$SHA"
```

The drill passes only if the Emergency Stop run is green, its "Verify stop
fence" step logs `STOP_FENCE_PROBE: a dry-run maxRunners=1 write is denied` and
"The API server denies non-zero runner writes while the stop marker exists",
Runner Status shows `burst-stopped` with the marker, and the acknowledged
Deploy then restores `burst` (its log shows `STOP_FENCE_PROBE: ... allowed`
after the marker delete). Record both run IDs in the Rollout record. A red
"Report fence failure" step fails the drill: stop, fix the fence by a reviewed
change, and repeat the drill.

Only Phase E's `READY_FOR_MIGRATION=true`, followed by a passing Emergency Stop
drill, authorizes repository migration. A successful Phase D proves recovery
and leaves the fleet drained. If any phase fails, run Rollback before any
migration PR merges.

## Rollback

Ordered CI recovery; each step reads back its postcondition before the next.

1. Deploy GitHub Runners `operation=drain`. It moves ARC to `drain` (max 4,
   required baseline affinity), retires idle burst runners every 2 minutes and
   waits until no runner pod is on a burst node and both burst pools report zero
   nodes. Busy jobs are never interrupted. A run waits at most 300 minutes; on
   timeout it fails and leaves `drain`; re-dispatch to resume the wait.
2. Node Pool Sizing `remove-burst` with `apply`. It observes zero nodes and no
   runner pods in both burst pools twice, resets the expanders to the default
   and deletes the pools.
3. Deploy GitHub Runners `operation=rollback`. It validates the committed
   `deploy/density-values.yaml` as the `density` contract (values and rendered
   manifest) and upgrades the release to exactly that render, independent of
   Helm history. With the burst pools gone, the `density` template can only
   schedule on baseline.

Migrated repositories revert their `runs-on` PRs.

## Emergency Stop

**Emergency Stop Runners** (`confirm=STOP-RUNNERS`) first writes the stop
marker, the ConfigMap `arc-runners/runner-fleet-emergency-stop` (the run id and
the time), then sets the release to `minRunners=maxRunners=0` with
`--reuse-values` on the pinned chart, so the template is unchanged and the gate
classifies the result as `burst-stopped`, `density-stopped` or `drain-stopped`.
ARC deletes idle runners at once; a busy runner finishes its job first. The run
reads the stopped state and the marker back and its summary names the recovery
below. If the marker write fails, the stop is still applied and the run fails;
re-dispatch Emergency Stop.

It uses its own non-cancelling concurrency group, `runner-emergency-stop`, and
does not wait for a running Deploy `drain` or Scale Runners Phase C (both hold
`runner-fleet-mutation` for hours). The marker fences them (Ruling 33):

- While the marker exists, every fleet workflow is refused at admission,
  except Runner Status and Rebalance (both report the stop; Rebalance retires
  nothing), Node Pool Sizing `remove-burst` (it deletes only empty closed pools
  and is the first recovery step from `drain-stopped`), and Deploy `deploy` or
  `rollback` dispatched with `acknowledge_emergency_stop=true`.
- An acknowledging run deletes the marker inside its identity bracket before
  its first write; if a newer stop rewrote the marker in between, the delete
  fails and the fleet stays stopped.
- Every fleet Helm write re-reads the marker afterwards. A run interrupted by
  the stop that still reaches Helm sees it, re-applies 0/0 and fails with
  `STOP_FENCE`. A run that reaches its next identity comparison or admission
  first fails there and changes nothing further; its always-run Phase C cleanup
  also refuses.
- **Server-side fence (Ruling 36).** The marker is also the parameter of the
  ValidatingAdmissionPolicy `runner-fleet-emergency-stop-fence`
  (`deploy/runner-emergency-stop-fence.yaml`). While it exists the API server
  denies every AutoscalingRunnerSet write that is not 0/0, so a run cancelled
  (or whose runner is lost) right after a stale Helm write cannot leave the
  fleet reopened. Deploy `deploy` and `rollback` install the fence before
  their Helm write; every other fleet workflow except Runner Status,
  `record-density` and `remove-burst` refuses to run while it is missing or
  differs from the file (an absent fence is tolerated while ARC is `density`
  or `density-stopped`, before the first burst deploy). Emergency Stop, after
  writing the marker and before its Helm write, proves the fence enforces (a
  server-side dry-run patch to `maxRunners=1` must be denied, retried for up
  to 30 s). If it is missing or not enforcing the stop is still applied and
  the run fails at "Report fence failure": run Deploy `deploy` (or `rollback`)
  with `acknowledge_emergency_stop=true` to install it, then re-dispatch
  Emergency Stop if the fleet must stay stopped. An acknowledging run waits up
  to 30 s after deleting the marker until the fence allows writes; if it
  still denies, the run fails before writing: re-dispatch it (the marker is
  gone, so no acknowledgement is needed).
- **Order of an acknowledged Deploy `deploy`.** The fence judges server-side
  dry runs like real writes, so the nonzero ASRS compatibility preflight
  cannot run while the marker exists. The run therefore does every local check
  first ("Render and validate candidate": render, burst-contract validation,
  manifest hash; the admission and `expected_sha` checks before it), then
  "Acknowledge Emergency Stop" (preconditioned delete and the wait above),
  then "Server-side preflight candidate", then the fence and NetworkPolicy
  steps, the re-admission and Helm. Rollback renders and validates locally
  before its acknowledgement and has no ASRS server dry run. Without the
  acknowledgement the order is the same with the acknowledgement skipped.
- **Stopped without a marker.** If anything after the acknowledgement fails
  before the Helm write (the server-side preflight, the fence or NetworkPolicy
  steps, a re-admission or identity comparison), nothing was written to the
  release: the fleet stays at its stopped state (0/0) but the marker is gone,
  so the server-side fence no longer holds it. Runner Status shows the
  `*-stopped` state with no `STOP:` line. Fix the cause, then re-dispatch the
  same recovery (Deploy `deploy` from `burst-stopped`, `rollback` from
  `drain-stopped`/`density-stopped`); `acknowledge_emergency_stop` is not
  needed and is a no-op without a marker. If the fleet must stay stopped
  until then, re-dispatch Emergency Stop, which writes a new marker.

Treat those failures as expected and recover from the stopped state:

| Stopped state | Recovery (CI only, reviewed `expected_sha`) |
|---|---|
| `burst-stopped` | Deploy `operation=deploy`, `acknowledge_emergency_stop=true`, restores `burst` (2/20). To leave burst afterwards: Deploy `operation=drain`, then `remove-burst`, then Deploy `rollback`. |
| `drain-stopped` (stopped during a drain) | Node Pool Sizing `remove-burst` once both burst pools have zero nodes (busy jobs finish first), then Deploy `operation=rollback`, `acknowledge_emergency_stop=true`. Deploy `drain` does not admit `drain-stopped`. |
| `density-stopped` | `remove-burst` if closed burst pools exist, then Deploy `operation=rollback`, `acknowledge_emergency_stop=true` (restores `deploy/density-values.yaml`). |

```bash
gh workflow run deploy-runners.yml -R "$FLEET" -f operation=rollback \
  -f acknowledge_emergency_stop=true -f expected_sha="$SHA"
```

Rebalance treats a stopped state or the marker as nothing to rebalance. Every
other operation rejects them. If the stop itself fails part-way, re-dispatch
Emergency Stop; it is idempotent on a stopped release.

Rebalance Runners uses its own group, `runner-rebalance`, so an hourly run never
queues behind (or displaces a pending run of) a fleet mutation. Each run first
lists queued and running Deploy, Scale Runners, Node Pool Sizing and Emergency
Stop runs and ends with a "nothing to rebalance" notice if any exists.

## Diagnostics

Run **Runner Status** first: pod and container metrics, restarts, OOM kills,
evictions, node headroom, pool state, burst node count per pool, and redacted
autoscaler status (`Healthy`, `NoCandidates`, `NoActivity`, `Backoff`). An
`OOMKilled` result names the killed process, not the component that used most of
the shared 6 GiB budget; attribute it only after reviewing both containers' use,
restarts, headroom and events.

## Security trade-off

Two jobs share each runner node while each pod includes privileged DinD. The
explicit co-tenancy acceptance, the selected-repository trust boundary with
re-read fork-PR policies, the public-workflow scan and CI-only rollout records
are the required controls; see
[`docs/security/vulnerability-dismissals.md`](../security/vulnerability-dismissals.md).

## Rollout record

One row per CI run. Record the reviewed SHA, the run URL and the result before
starting the next step.

| Date (UTC) | Step | Workflow / operation | `expected_sha` | Run URL | Result / notes |
|---|---|---|---|---|---|
| | 1 | Scale Runners `record-density` | | | live release equals `deploy/density-values.yaml` |
| | 2 | Deploy `prepare-trust-boundary` | | | |
| | 3 | Node Pool Sizing `create-burst` | | | |
| | 3 | Node Pool Sizing `configure-expander` | | | |
| | 4 | Deploy `deploy` | | | |
| | 4 | Node Pool Sizing `enable-burst` | | | |
| 2026-11-01 | 5A | Acceptance A (probe tag / evidence run) | `6be69b6` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41270237200 | pass (attempt 4): 4 baseline + 12 primary; warm p95 13 s (n=4), cold p95 156 s (n=10); network probe passed |
| 2026-11-01 | 5B | Acceptance B + `set-burst-maxima` restore | `6be69b6` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41273100458 | pass: 4 baseline + 4 fallback; warm p95 13 s (n=4), cold p95 160 s (n=2); restore 6/2 run 41273981232 |
| 2026-11-01 | 5C | Scale Runners `acceptance-phase-c` + evidence | `d0851f2` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41278522596 | pass: result `retired` (cycle 1), `jobs_killed=0`; Phase C run 41278515350 |
| 2026-11-01 | 5D | Deploy `drain` + evidence | `a6e9e12` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41293538915 | pass (attempt 2): drain 41293531020; widest in-drain gap 9 s |
| 2026-11-01 | 5E | `remove-burst`, `rollback`, steps 3–4, evidence | `ca8e2d5` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41305468700 | pass (attempt 2): rollback 41304723978; `READY_FOR_MIGRATION=true` |
| 2026-11-01 | ES | Emergency Stop drill + acknowledged Deploy `deploy` | `ca8e2d5` | https://github.com/redducklabs/redducklabs-runners/actions/runs/41306946906 | pass: fence denied the dry-run write; Runner Status 41307007638 `burst-stopped`; Deploy 41307059244 deleted the marker, probe allowed; Runner Status 41307266616 `burst` |

2026-10-28, first attempt at main `badfb93`: steps 1 and 2 passed; step 3
`create-burst` apply failed twice (Node Pool Sizing runs 40647394663 and
40647530519) with the regional-capacity 422 for `s-8vcpu-16gb`; nothing was
created and ARC stayed `density`. The burst sizes were re-planned (Ruling 38).
Start again from step 1 at the new reviewed commit.

2026-10-28, second attempt at main `8344e81`: step 3 `create-burst` apply
(Node Pool Sizing run 40721560476) created the closed primary
`github-runners-burst-amd-16g`, then failed with `IDENTITY_DRIFT:
pools.github-runners-burst-amd-16g.max_nodes: expected=0 live=null` because
doctl omits zero-valued pool fields (Ruling 39). The fallback was not created
and ARC stayed `density`. Re-run step 3 `create-burst` at the reviewed commit
that contains the Ruling 39 fix; it creates only the fallback.

2026-10-28, at main `4d7134f`: step 3 `create-burst` apply (run 40739372104)
created the closed fallback `github-runners-burst-intel-16g` (primary NOOP);
both pools are present and closed. The `configure-expander` dry run (run
40739557666) failed with `configmaps "cluster-autoscaler-priority-expander"
not found` because DOKS creates that ConfigMap only after the expander update
(Ruling 40). Nothing was changed; ARC stayed `density`. Continue step 3 with
`configure-expander` (dry run, then `apply`) at the reviewed commit that
contains the Ruling 40 fix.

2026-10-28, at main `5186a64`: the `configure-expander` dry run (run
40768526948) planned the update and the wait. The apply (run 40768656384) set
the cluster expanders to `priority,random` (DOKS then created the starter
ConfigMap), and stopped before writing priorities: the cluster diff saw
`scale_down_utilization_threshold: 0` and `scale_down_unneeded_time: ""`
appear, zero values the API fills in once the autoscaler configuration exists
(Ruling 41). Pools stayed closed. Re-run `configure-expander` (`apply`) at the
reviewed commit that contains the Ruling 41 fix: the expanders are a `NOOP`
and it writes the priorities. Phase C proves that scale-down still works with
these zero values.

2026-10-29, at main `18f6d50`: rollout steps 1-4 done. Phase A attempt 1:
probe run 40797434260 (16 jobs) succeeded, but its evidence run 40797455827
failed reading the network-probe log (terminal escape sequences, Ruling 42),
and the probe created six primary and two fallback nodes because ARC ran
16 + 2 runners (Ruling 43). Re-run Phase A with `jobs=14` at the reviewed
commit that contains both fixes, once both burst pools are back at 0 nodes
(dispatch Rebalance Runners to retire idle runners still holding burst nodes).

2026-10-29, at main `8529ed0`: Phase A attempt 2: probe run 40830762762
succeeded; evidence run 40830774010 failed only `A-primary-only`: a
`redducklabs/therapy-link` job shared the fleet (17 runner pods) and the
autoscaler added one fallback node. Pickup and the network probe passed.
Re-run Phase A on a quiet fleet at the reviewed commit that contains the
Ruling 44 fix.

2026-10-31, at main `bab889a`: Phase A attempt 3: probe run 40897316886
succeeded; evidence run 40897337833 placed 4 baseline + 12 primary runner pods
but failed `A-primary-only` (two fallback nodes registered, no runner pod on
them) and `A-priority` (an aggregated "(combined from similar events): "
message did not parse, and fallback scale-ups failed the old rule). The
fallback was raised only after the primary was at 6 of 6 (Ruling 45). Re-run
Phase A at the reviewed commit that contains the Ruling 45 fix.

2026-11-01, Phase A attempt 4 at main `6be69b6` passed, then Phase B (after
the PR #46 runbook ordering fix: wait for the primary to reach 0 nodes
before `set-burst-maxima primary_max=0`). Phase C's first run (41275139366)
failed at its first Helm write without changing the fleet (reused values are
float64, `--set` values int64; Ruling 47) and passed at `d0851f2`. Phase D
attempt 1 (evidence 41281069997) failed only on an 18 s gap while ARC replaced
ephemeral runners at the drain cap (Ruling 48); the restore before its re-run
stopped with `IDENTITY_DRIFT` in `remove-burst` run 41288902410 because DOKS
deletes pools asynchronously (Ruling 49). Phase D passed at `a6e9e12`. Phase E
attempt 1 (evidence 41298984154) was rejected at its anchors: the Phase A
record predates the later fixes, and cleanup had no cluster access after the
rejection (Ruling 50); it passed at `ca8e2d5` after a drain and restore. The
Emergency Stop drill passed at `ca8e2d5`. Repository migration is authorized.
