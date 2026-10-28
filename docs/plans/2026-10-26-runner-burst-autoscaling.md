# Runner Burst Autoscaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed 2-node / 4-runner fleet with 2 baseline nodes plus up to 8 autoscaled burst nodes (20 runners), with fail-closed CI-only mutation, idle-runner retirement, drain/rollback, and live acceptance.

**Architecture:** New logic lives in standalone, fixture-testable scripts under `scripts/` that the workflows call; workflows keep only input validation, credentials, and orchestration. One operation-aware gate (`scripts/verify-runner-pool-state.sh`) replaces the fixed two-node checks in every fleet workflow. A new test driver `test/verify-burst-autoscaling.sh` runs all new fixtures with fake `doctl`, `kubectl`, `helm`, and `gh` binaries on `PATH`, following the fake-binary pattern already used by `test/verify-runner-resources.sh`.

**Tech Stack:** Bash, jq, Python 3 + PyYAML, Helm 3 (chart `gha-runner-scale-set` 0.14.2), kubectl, doctl, gh, GitHub Actions.

**Spec:** `docs/specs/2026-10-26-runner-burst-autoscaling-design.md` (Codex-approved, review 5). Read it in full before any task.

## Global Constraints

- Baseline pool `github-runners-pool-16g`, `s-8vcpu-16gb`, `min=max=count=2`.
- Burst pools: `github-runners-burst-16g` (`s-8vcpu-16gb`, 0..6) and `github-runners-burst-amd-16g` (`s-8vcpu-16gb-amd`, 0..2); `sum(max) ≤ 8`; both created closed at `min=max=0`.
- Every runner pool: labels exactly `node-type=github-runner`, `workload-type=ci-cd`; single taint `github-runner=true:NoSchedule`.
- ARC contracts: `density` (2/4, existing), `burst` (2/20), `burst-acceptance` (8/20 or 4/20), `drain` (2/4, required baseline affinity). Runner group `redducklabs-private-runners`. Pod budget unchanged: 3 CPU / 5Gi request, 6Gi limit.
- `burst` adds pod annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` and preferred (weight 100) node affinity `doks.digitalocean.com/node-pool In [github-runners-pool-16g]`; `drain` makes that affinity required.
- Expander: cluster `--expanders priority,random`; ConfigMap `kube-system/cluster-autoscaler-priority-expander` `data.priorities` = primary pool ID at 100, fallback pool ID at 50, `.*` at 1; keep `doks.digitalocean.com/managed` labels.
- Node headroom after two runner reservations + non-runner requests: ≥ 2 GiB memory and ≥ 1000m CPU. Kubernetes ≥ 1.36 on every Ready eligible node.
- A burst node NotReady is tolerated for 15 minutes after creation. Cluster status must be `running`; registered nodes per pool ≤ provider `count`.
- Every mutating workflow: `expected_sha` verified before first mutation; concurrency group `runner-fleet-mutation`, `cancel-in-progress: false`; `permissions: contents: read`.
- Every mutation (Helm, `doctl ... create|update|delete`, `kubectl delete|patch`) is bracketed by the identity contract (Task 3): a snapshot after admission; an exact comparison immediately before the mutation; and after it, a comparison that permits only that mutation's declared transition. Immutable identities (cluster ID, baseline pool ID, baseline node UID/providerID pairs, IDs of pools the mutation does not touch) must never change. A difference aborts with no further mutation.
- ARC release identity: release `redducklabs-runners` in `arc-runners`, status `deployed`, chart `gha-runner-scale-set-0.14.2`, exactly one match; and controller release `arc` in `arc-systems`, status `deployed`, chart `gha-runner-scale-set-controller-0.14.2`, exactly one match, whose controller Deployment has `observedGeneration == metadata.generation` and `availableReplicas == replicas ≥ 1`. Retirement depends on the 0.14.2 controller's finalizer behavior, so both checks gate every EphemeralRunner deletion. Reuse the existing prepared-platform check logic from `deploy-runners.yml` (moved into the gate, not duplicated).
- GitHub-hosted job ceiling is 6 hours: drain run deadline 300 minutes (job `timeout-minutes: 330`); Phase C run deadline 270 minutes (job `timeout-minutes: 300`). Internal deadlines use an injectable clock (`NOW_CMD`, default `date +%s`) so fixtures can drive them.
- Fleet-management workflows in this repo run on `ubuntu-latest` (public repo; enforced by `validate-config.yml`).
- Never print secrets; never read Kubernetes Secret payloads.
- Acceptance thresholds: warm pickup p95 ≤ 90 s; cold pickup p95 ≤ 8 min.
- New allow-list members: `1425956382:keel`, `1418079240:superfood-shred`.

## Review Focus

- A DOKS API response where taints use capitalized keys (`Key/Value/Effect`), as the existing `verify_pool` already accepts — the new pool-state gate must accept both encodings (Task 3 fixture `taint-capitalized`).
- `doctl` returning a pool list in which a burst pool exists but has `auto_scale=false` after a failed create — must fail closed, not be "reconciled" by widening (Task 5 fixture `burst-autoscale-off`).
- An EphemeralRunner whose pod is already gone (deleted or evicted) — retirement must skip it without error (Task 4 fixture `pod-missing`).
- A GitHub runners API page boundary (more than 100 org runners) — retirement must paginate before deciding `busy` (Task 4 fixture `runners-paginated`).
- A `doctl invoice get` that returns items for droplets from other clusters with the same name prefix pattern — the cost report must match the full pool-name prefix plus `-` only (Task 8 fixture `foreign-prefix`).

---

### Task 1: ARC contract validator — `burst`, `burst-acceptance`, `drain`

**Files:**
- Modify: `scripts/validate-runner-isolation-contract.py`
- Create: `test/fixtures/arc-burst-values.yaml`, `test/fixtures/arc-drain-values.yaml`
- Create: `test/verify-burst-autoscaling.sh` (driver; later tasks append sections)
- Modify: `.github/workflows/validate-config.yml` (run the new driver after `verify-runner-resources.sh`)

**Interfaces:**
- Produces: CLI `validate-runner-isolation-contract.py --contract {legacy-isolated,density,burst,burst-acceptance,drain} --kind {values,manifest,asrs-list} --min-runners N --max-runners N --runner-group {default,private}`; exit 0 = match, 1 = mismatch with `ERROR:` on stderr.
- Produces: functions `burst_template(rendered: bool) -> dict`, `drain_template(rendered: bool) -> dict`, `burst_metadata() -> dict` (returns `{"annotations": {"cluster-autoscaler.kubernetes.io/safe-to-evict": "false"}}`).
- Produces: driver helpers in `test/verify-burst-autoscaling.sh`: `pass`, `fail`, `with_fakes <fixture-dir> <command...>` (prepends a temp dir of fake binaries reading canned JSON from the fixture dir), and a final non-zero exit when any `fail` ran.

- [ ] **Step 1: Write failing tests** in the driver, function `assert_burst_contracts`:
  - `burst` values fixture (2/20, private) → exit 0.
  - same fixture checked as `burst` with 2/4 → exit 1.
  - `burst-acceptance` accepts 8/20 and 4/20; rejects 2/20, 6/20, 8/10.
  - `burst` with the annotation removed → exit 1; with affinity weight 50 → exit 1; with `requiredDuringScheduling` instead of preferred → exit 1.
  - `drain` fixture (2/4, required affinity, annotation) → exit 0; `drain` with preferred affinity → exit 1; `drain` 2/20 → exit 1.
  - `density` checks of the existing deployed shape still pass (regression).
- [ ] **Step 2: Run** `bash test/verify-burst-autoscaling.sh` → FAIL (unknown contract choice).
- [ ] **Step 3: Implement.** Bounds per contract: `burst` exactly (2,20); `burst-acceptance` (8,20) or (4,20); `drain` exactly (2,4); all require `private`. Compare `template.metadata` to `burst_metadata()` for the three new contracts (and require no `metadata` key difference for `density`). `affinity.nodeAffinity` shape: preferred = `{"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "preference": {"matchExpressions": [{"key": "doks.digitalocean.com/node-pool", "operator": "In", "values": ["github-runners-pool-16g"]}]}}]}`; required = `{"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [<same expression>]}]}}`.
- [ ] **Step 4: Run** the driver → PASS; run `bash test/verify-runner-resources.sh` → PASS (no regression).
- [ ] **Step 5: Commit** `feat: add burst, burst-acceptance and drain runner contracts`.

### Task 2: Scale-set values for `burst`

**Files:**
- Modify: `deploy/dind-values.yaml` (`maxRunners: 20`; `template.metadata.annotations`; `template.spec.affinity` preferred), `deploy/dind-values.template.yaml` (same)
- Create: `scripts/render-drain-values.py` (Ruling 3: generates the full drain values file from `deploy/dind-values.yaml`: `maxRunners: 4`, required affinity replacing preferred)
- Modify: `test/verify-runner-resources.sh` (replace the max-4 / two-node invariants with the spec's: render passes `burst` contract; render of the generated drain values passes `drain`; two pods fit with ≥2 GiB/1000m headroom on both `s-8vcpu-16gb` and `s-8vcpu-16gb-amd` published allocatable; `maxRunners ≤ 2×(2+8)`; `minRunners ≤ 4`)

**Interfaces:**
- Consumes: Task 1 contracts.
- Produces: `scripts/render-drain-values.py OUTPUT` used by Task 6 Deploy `drain`.

- [ ] **Step 1: Write failing tests**: in `verify-runner-resources.sh`, `assert_burst_render` (rendered manifest validates as `burst` 2/20) and `assert_drain_render` (render of generated drain values validates as `drain` 2/4); update `assert_node_pool_bounds` and related max-4 assertions to the new invariants.
- [ ] **Step 2: Run** `bash test/verify-runner-resources.sh` → FAIL on the new asserts.
- [ ] **Step 3: Implement** the values changes. Update the header comment in `dind-values.yaml` to reference this spec and drop the "maxRunners must remain four" text.
- [ ] **Step 4: Run** both drivers → PASS. Existing fixtures that assert the retired 2/2 legacy path or ordinary scaling are updated or removed in Tasks 5–6; if they fail here, mark them in the task notes and fix them in their owning task, not by weakening.
- [ ] **Step 5: Commit** `feat: render runner scale set for burst capacity`.

### Task 3: Operation-aware pool-state gate

**Files:**
- Create: `scripts/verify-runner-pool-state.sh`
- Create: `scripts/lib/arc-identity.sh` (sourced function `verify_arc_identity`: scale-set and controller release identity plus controller readiness; returns non-zero with a reason on stderr)
- Create: `test/fixtures/pool-state/<scenario>/{cluster.json,pools.json,nodes.json,helm-values.json,helm-manifest.yaml,asrs.json,pods.json}` per scenario
- Modify: `test/verify-burst-autoscaling.sh` (`assert_pool_state_gate`)

**Interfaces:**
- Produces: `scripts/verify-runner-pool-state.sh --operation <op> --cluster-name <name>` (admission) and two snapshot modes:
  - `--emit-identities <file>` writes the single authoritative snapshot schema: `{"immutable": {"cluster_id", "baseline_pool_id", "baseline_nodes": [{"uid","providerID"}]}, "pools": {"<name>": {"id", "size", "auto_scale", "min_nodes", "max_nodes", "labels", "taints"}}, "arc": {"contract", "minRunners", "maxRunners", "values_sha256", "manifest_sha256", "asrs_generation"}}`. Taints are normalized to lower-case keys before hashing/comparison. Dynamic values (provider `count`, registered nodes, runner pods) are deliberately not in the snapshot.
  - `--compare-identities <file> --transition <t>` compares live state to the snapshot. `<t>` is `none` (exact equality of every snapshot field) or one declared transition with its exact target: `pool-created:<name>:<size>:<min>/<max>` (exactly that pool added, with the canonical labels, single taint, `auto_scale=true`, and the declared size and bounds; only then is its entry written back into the snapshot as trusted), `pool-deleted:<name>` (exactly that pool's entry removed), `pool-bounds:<name>:<min>/<max>` (same ID and configuration; bounds equal the declared target), `arc:<contract>:<min>/<max>` (ARC moves to exactly that state; hashes and generation may change). Everything not named by the transition must equal the snapshot. Exit 3 on any difference.
  - Immediately before every mutation the caller runs, in order: `--compare-identities <file> --transition none`, then the full operation admission again (`--operation <op>`), which re-evaluates the operation's dynamic prerequisites against live state (for `remove-burst`: provider `count == 0`, zero registered nodes, and zero runner pods in the pool being deleted; for `drain`/`rebalance` deletions: the candidate is still idle). Burst counts may legitimately differ from earlier observations; they must satisfy the operation's current conditions.
  - Callers re-snapshot only through a successful `--transition` comparison, so a multi-step run (create both pools; remove both pools; Phase C's 2→8→4→2) chains declared transitions and never refreshes from unverified live state.
- The gate checks ARC release and controller identity first (Global Constraints), then values, manifest, live ASRS. `<op>` ∈ `status, rebalance, acceptance-phase-c, record-density, set-burst-maxima, create-burst, configure-expander, deploy, enable-burst, drain, remove-burst, rollback`. Reads live state via `doctl` (cluster list/get, node-pool list), `kubectl` (nodes, pods in `arc-runners`, ASRS), `helm` (values/manifest), calling the Task 1 validator for ARC state. Exit 0 = admitted. Prints one `STATE: arc=<contract> pools=<none|primary|fallback|both> burst=<closed|open>` line.
- Admission table: exactly the spec's "ARC states admitted per operation" table.

- [ ] **Step 1: Write failing fixtures/tests** (each scenario → expected exit and, for exit 0, expected `STATE:` line): `valid-density-no-burst` (create-burst ✓, deploy ✗ without pools), `valid-burst-mixed` (nodes in all three pools; status/rebalance/drain ✓), `unknown-eligible-pool` ✗, `wrong-size` ✗, `missing-taint` ✗, `extra-noschedule-taint` ✗, `taint-capitalized` ✓, `burst-max-over-pool` (primary 7) ✗, `burst-sum-over-8` ✗, `burst-min-nonzero` ✗, `baseline-drift` (count 3) ✗, `notready-burst-16min` ✗, `notready-burst-10min` ✓, `node-no-pool-label` ✗, `cluster-upgrading` ✗, `surge-underfilled` (primary count 1, 2 registered) ✗, `provisioning-unregistered` ✓, `headroom-short` (1.5 GiB left) ✗, `kube-1.35-node` ✗, `drain-for-remove` ✓, `density-closed-pools-remove` ✓, `density-open-pools-remove` ✗, `rollback-with-pools` ✗, `acceptance-8-from-drain` ✗, `unknown-operation` ✗, `release-wrong-chart` (0.14.1) ✗, `release-failed` ✗, `release-pending-upgrade` ✗, `release-ambiguous` (two releases) ✗. Controller fixtures (valid scale-set release in each): controller chart 0.14.1, controller release missing, controller release `failed`, `pending-upgrade`, controller Deployment unavailable, stale `observedGeneration` → exit 1. Identity-drift fixtures (ported from `assert_node_pool_no_removal_contract`, which is removed only after these pass): with `--transition none`, changed cluster ID, baseline pool ID, baseline node UID, baseline providerID, Helm values hash, ASRS generation, and 8/20 vs 4/20 → exit 3. Same-ID drift fixtures with `--transition none`: pool `max_nodes`, `min_nodes`, `auto_scale`, size, a label, or the taint changed → 3. Late dynamic-race fixtures through `burst-pools.sh remove-burst`: provider count becomes 1 between the second observation and the deletion call, a node registers, or a runner pod schedules into the pool → no `doctl ... delete` call. Declared-transition fixtures: `pool-created` whose new pool has `max_nodes=6` instead of 0, a missing label, or `auto_scale=false` → 3 and the ID is not trusted; `pool-bounds:github-runners-burst-16g:0/6` when live is 0/5 → 3; `pool-created` with an extra unexpected pool → 3; `pool-deleted` where a different pool vanished → 3; `arc:burst:2/20` when live is 4/20 → 3; and successful chains through the real comparator: create primary then fallback; delete both; `density → burst → drain → density`; `burst 2/20 → burst-acceptance 8/20 → 4/20 → burst 2/20`.
- [ ] **Step 2: Run** → FAIL (script missing).
- [ ] **Step 3: Implement.** Pool identity via `doks.digitalocean.com/node-pool` node label. "Registered nodes" = Kubernetes Node objects for the pool. Node age from `metadata.creationTimestamp`. Headroom: sum non-runner pod requests per node from `kubectl get pods -A --field-selector spec.nodeName=<node>` excluding `arc-runners` runner pods.
- [ ] **Step 4: Run** → PASS; `shellcheck -S error scripts/verify-runner-pool-state.sh` → clean.
- [ ] **Step 5: Commit** `feat: add operation-aware runner pool state gate`.

### Task 4: Idle burst-runner retirement

**Files:**
- Create: `scripts/retire-idle-burst-runners.sh`
- Create: `test/fixtures/retire/<scenario>/{ephemeralrunners.json,pods.json,nodes.json,gh-runners-*.json}`
- Modify: `test/verify-burst-autoscaling.sh` (`assert_retirement`)

**Interfaces:**
- Produces: `scripts/retire-idle-burst-runners.sh [--dry-run]`; env `GH_TOKEN` (org runner read). Prints `RETIRED=<n> CANDIDATES=<m> FREE_BASELINE_SLOTS=<k>` as its last line; exit 0 unless an API read fails (exit 1, no deletions).
- Precondition: callers run the Task 3 gate (`rebalance` or `drain`) immediately before; the script itself re-reads both the scale-set and controller release identity and controller readiness (sourcing the gate's check function, `scripts/lib/arc-identity.sh`) and aborts with zero deletions on any mismatch.
- Behavior: free baseline slots = `2 × Ready baseline nodes − runner pods on baseline`; candidates = EphemeralRunners whose pod is on a burst-pool node, `status.jobRequestId` empty/0, and GitHub runner (matched by `status.runnerName`) `busy=false`, with the GitHub read after the Kubernetes read; delete `min(candidates, free slots)` oldest first via `kubectl delete ephemeralrunner -n arc-runners <name> --wait=false`.

- [ ] **Step 1: Write failing fixtures**: `idle-on-burst` (1 deleted), `busy-on-burst` (0), `jobid-set-gh-idle` (0), `baseline-full` (0 deleted, candidates 2), `two-idle-one-slot` (1 deleted, the oldest), `pod-missing` (skipped, exit 0), `runners-paginated` (busy flag on page 2 respected), `gh-api-error` (exit 1, 0 deletions), `release-wrong-chart`, `controller-wrong-chart`, `controller-missing`, `controller-failed`, `controller-unavailable` (each exit 1, 0 deletions, scale-set release valid). Fake `kubectl delete` appends to a mutation log the test asserts on.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** (`gh api --paginate orgs/redducklabs/actions/runners`).
- [ ] **Step 4: Run** → PASS; shellcheck clean.
- [ ] **Step 5: Commit** `feat: retire idle runners from burst nodes`.

### Task 5: Node Pool Sizing operations

**Files:**
- Create: `scripts/burst-pools.sh`
- Modify: `.github/workflows/node-pool-sizing.yml` (inputs: `operation` choice `create-burst|configure-expander|enable-burst|set-burst-maxima|remove-burst`, `primary_max`, `fallback_max` (only for `set-burst-maxima`), `apply`, `expected_sha`; drop `min_nodes/max_nodes/pool_name`; call gate then script)
- Create: `test/fixtures/burst-pools/<scenario>/...`
- Modify: `test/verify-burst-autoscaling.sh` (`assert_burst_pools`), `test/verify-runner-resources.sh` (remove `assert_node_pool_no_removal_contract` and other 8→2-only assertions only after their race cases are ported to Task 3 and to this task's behavioral fixtures)

**Interfaces:**
- Consumes: Task 3 gate (`--operation <op> --emit-identities`).
- Produces: `scripts/burst-pools.sh <operation> --cluster-name N [--primary-max P --fallback-max F] [--apply]`. Without `--apply` prints the planned `doctl`/`kubectl` calls and exits 0.
  - `create-burst`: create missing pools with `--auto-scale --min-nodes 0 --max-nodes 0 --count 0 --label node-type=github-runner --label workload-type=ci-cd --taint github-runner=true:NoSchedule`; an existing pool with wrong size/labels/taint or `auto_scale=false` → exit 1; existing correct closed pool → no-op. If the API rejects `min/max/count 0`, exit 1 with `SCALE_TO_ZERO_REJECTED` (spec: stop and re-plan).
  - `configure-expander`: `doctl kubernetes cluster update <id> --expanders priority,random`; write priorities ConfigMap via `kubectl patch configmap cluster-autoscaler-priority-expander -n kube-system --type merge` (data only; labels untouched); read back both.
  - `enable-burst`: stage-aware. From both closed: update primary to 0/6 (`--transition pool-bounds:github-runners-burst-16g:0/6`), re-run admission (now admits the middle stage), update fallback to 0/2 (`--transition pool-bounds:github-runners-burst-amd-16g:0/2`), re-run admission. From the middle stage: only the fallback update. From both open: no-op.
  - `set-burst-maxima`: validate P∈0..6, F∈0..2, P+F≤8; apply the lowering change first, read back, then the raising change, read back.
  - `remove-burst`: gate-observe twice (identities equal), then `--expanders ""`, then delete each present burst pool; read back that only baseline + worker pools remain.
  - Every operation re-checks baseline identities from the gate file before and after mutation.

- [ ] **Step 1: Write failing fixtures**: create from none; create with one existing correct pool (creates only the other); `burst-autoscale-off` (exit 1); `scale-to-zero-rejected` (exit 1, message); expander write + readback mismatch (exit 1); enable from closed through the real gate, comparator, and orchestration against stateful fakes (closed → primary-open/fallback-closed → both-open); retry from the middle stage (only the fallback update is issued); rejection of unexpected bounds (primary 0/5 with fallback 0/0, or fallback open while primary closed) with no update call; set-burst-maxima 0/2 from 6/2 (order: primary lowered first); set 7/1 rejected; set 6/3 rejected; remove-burst with a node present (exit 1, no delete call); remove-burst after one pool already deleted (deletes the other); mismatched `expected_sha` in the workflow step (no `doctl` mutation in the log); identity drift between snapshot and pre-mutation compare for each operation (no mutation); identity drift detected after mutation (exit non-zero, summary reports it). Partial-rollout sequences run through the real gate and script against stateful fakes: `density`+one closed pool → `remove-burst` → baseline only; `density`+two closed pools+expander → `remove-burst`; each re-run on its postcondition is a no-op.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** script and workflow wiring; summary step lists before/after for each pool.
- [ ] **Step 4: Run** both drivers → PASS; `actionlint .github/workflows/node-pool-sizing.yml` clean.
- [ ] **Step 5: Commit** `feat: manage burst node pools and autoscaler priority from CI`.

### Task 6: Deploy and Scale Runners operations

**Files:**
- Modify: `.github/workflows/deploy-runners.yml` (operations `deploy|prepare-trust-boundary|drain|rollback`; the representative-Pod builder copies `template.metadata.annotations` from the rendered ASRS into the Pod, and the admitted-Pod comparison requires `cluster-autoscaler.kubernetes.io/safe-to-evict == "false"` in addition to the existing PodSpec, token-injection, candidate-hash and resource checks; every Helm mutation bracketed by the identity contract; replace the two-node pool/headroom gates at the cited lines with `verify-runner-pool-state.sh --operation <op>`; headroom evaluated by the gate over every Ready eligible node; `deploy` admits `density`/`burst` and validates readback as `burst`; `drain` = `helm upgrade` with the single `-f` produced by `scripts/render-drain-values.py`, readback `drain`, then loop `retire-idle-burst-runners.sh` every 120 s until no runner pod on a burst node and burst pool node counts are 0, job `timeout-minutes: 330` and a 300-minute loop deadline driven by `NOW_CMD`; `rollback` validates the target revision against `density`, requires burst pools absent, and is a no-op on `density`; the public input stays `rollback_revision`)
- Create: `scripts/acceptance-phase-c.sh`
- Modify: `.github/workflows/scale-runners.yml` (actions `record-density|acceptance-phase-c` only; `record-density` validates live release as `density` 2/4 and emits `rollback_revision` output; `acceptance-phase-c` job `timeout-minutes: 300`, calls the script, and has a final cleanup step with `if: always() && steps.admit.outputs.cleanup_eligible == 'true'`. `cleanup_eligible` is written only after the SHA check and the gate admitted `acceptance-phase-c` (from `burst`, or from interrupted `burst-acceptance` 8/20 or 4/20). Cleanup re-runs the gate's release-identity and contract checks, sets `minRunners=2`, validates `burst`, and fails the run if restoration fails)
- Modify: `scripts/scale-runners.sh` usage text if it references retired actions.
- Modify: `test/verify-runner-resources.sh` (retire legacy-isolated rollback, `rollout-quiesce`, and ordinary-scale assertions; add static checks that each operation calls the gate with its own name)
- Modify: `test/verify-burst-autoscaling.sh` (`assert_deploy_ops`, `assert_phase_c`)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `scripts/acceptance-phase-c.sh --max-cycles 3` with env `GH_TOKEN`; uses `helm upgrade --reuse-values --set minRunners=<n>` and the Task 1 validator for each transition; prints `PHASE_C_RESULT=retired|fixture-only` and the evidence path `phase-c-evidence.json`; exit 1 on any failed assertion.
- Produces: Scale Runners output `rollback_revision` (consumed by the rollout record and Deploy's existing `rollback_revision` input).

- [ ] **Step 1: Write failing tests**: Deploy rejects non-canonical values (2/10, 4/20) before Helm; `drain` loop reaches empty with an idle burst runner and no demand (fake kubectl state advances per call); `drain` timeout leaves `drain` (no rollback attempted); `rollback` refuses with pools present; `rollback` on `density` is a no-op; mismatched SHA → no `helm`/`kubectl` mutation for each operation; Phase C sequencing fixture: success (final always-step verified no-op), failure at the 8-runner wait (cleanup restores 2), interruption at 8/20 and at 4/20 (re-run restores `burst`; Deploy `drain` admits both), cancellation between 4 and 2; cleanup-eligibility fixtures with zero Helm writes for wrong SHA, failed gate/API read, entry from `drain`, and entry from a non-canonical state; cancellation after each authorized transition (2→8, 8→4, 4→2) restores `burst`; restoration failure propagates as a failed run. Deadline fixtures with a fake clock: drain at 300 minutes exits non-zero leaving `drain`; Phase C at 270 minutes triggers cleanup. Preflight fixtures through the fake admission webhook: annotation removed → no Helm upgrade; annotation changed to `"true"` → no Helm upgrade; existing PodSpec normalization, token injection, hash, and resource fixtures still pass.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both drivers and `actionlint` → PASS.
- [ ] **Step 5: Commit** `feat: deploy, drain and acceptance operations for burst fleet`.

### Task 7: Rebalance workflow

**Files:**
- Create: `.github/workflows/rebalance-runners.yml` (`schedule: cron '17 * * * *'` and `workflow_dispatch` with required input `expected_sha`; on `workflow_dispatch` the run aborts unless `expected_sha == git rev-parse HEAD`; on `schedule` it checks out `github.sha` and aborts unless `git rev-parse HEAD == github.sha` and `github.ref == refs/heads/main`, so scheduled runs execute only reviewed `main` code; `ubuntu-latest`; `runner-fleet-mutation` group; gate `--operation rebalance`; then `scripts/retire-idle-burst-runners.sh`; uses existing `DO_TOKEN` and the org-runner-read token already used by trust-boundary verification)
- Modify: `test/verify-runner-resources.sh` (`assert_shared_fleet_concurrency` includes the new workflow)

**Interfaces:** Consumes Tasks 3–4.

- [ ] **Step 1: Write failing tests**: static (shared group, `cancel-in-progress: false`, `contents: read`, hosted runner, gate called with `rebalance`); behavioral via step materialization (the existing `materialize_workflow_step` helper): dispatch SHA mismatch → no `kubectl delete` in the mutation log; schedule with `github.ref` not `main` → no deletion; gate failure → no deletion.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; actionlint clean.
- [ ] **Step 5: Commit** `feat: schedule idle runner rebalancing`.

### Task 8: Status and cost reporting

**Files:**
- Modify: `.github/workflows/runner-status.yml` (gate `--operation status`; per-pool node counts and bounds; expander readback; remove "exactly 2 nodes" drift error; keep the autoscaler-diagnostic allow-list)
- Create: `scripts/runner-cost-report.sh`
- Create: `test/fixtures/cost/<scenario>/...`
- Modify: `test/verify-burst-autoscaling.sh` (`assert_cost_report`)

**Interfaces:**
- Produces: `scripts/runner-cost-report.sh --month YYYY-MM` → table per pool (hours, USD) from `doctl invoice list`/`doctl invoice get <uuid> -o json` items whose description starts with `<pool-name>-`; for the current month prints `doctl balance get` month-to-date as `ACCOUNT-WIDE`; missing invoice → `cost data unavailable`, exit 0, never `0`.

- [ ] **Step 1: Write failing fixtures**: `deleted-nodes` (items for droplets that no longer exist are counted), `foreign-prefix` (`github-runners-burst-16gx-...` and other clusters excluded), `missing-invoice`, `current-month`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Confirm the invoice item JSON field names against a real `doctl invoice get -o json` (read-only) and record the sample shape (redacted of amounts) in the fixture.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: report runner pool cost from invoices`.

### Task 9: Trust boundary expansion

**Files:**
- Modify: `deploy/trusted-runner-repositories.txt` (add `1425956382:keel`, `1418079240:superfood-shred`)
- Modify: `scripts/verify-runner-trust-boundary.sh` (cardinality check 9 → 11; for each private member, before any runner-group POST/PATCH/PUT, `GET repos/{owner}/{repo}/actions/permissions/fork-pr-workflows-private-repos` and require a JSON object whose `run_workflows_from_fork_pull_requests` is the literal boolean `false` (jq `.run_workflows_from_fork_pull_requests == false and (.run_workflows_from_fork_pull_requests|type) == "boolean"`); anything else, including missing, null, string, malformed body, or API error, fails closed; verify-only mode applies the same check)
- Create: `docs/security/runner-admission/keel.md`, `docs/security/runner-admission/superfood-shred.md` (evidence per spec, with the audited workflow commit SHA, collaborator list, trigger audit, and the jobs that will select the fleet)
- Modify: `docs/security/vulnerability-dismissals.md` (AOR-2 members, evidence location, co-tenancy acceptance dated 2026-10-26)
- Modify: `test/verify-runner-resources.sh`: `assert_final_review_regressions` exact expected membership becomes the 11 identities; fake GitHub fixture responses gain the two repos (private, correct IDs) and a fork-policy response per member; `assert_trust_boundary_fixtures` adds a positive 11-member reconcile and verify-only case, and negative fork-policy cases `true`, missing, `null`, `"false"` (string), malformed JSON, API error — each asserting no POST/PATCH/PUT to the runner group; existing duplicate, rename, transfer, privacy, omission, substitution, and unauthorized-addition fixtures retained and passing with 11 members

- [ ] **Step 1: Write failing fixtures.**
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**; gather evidence with read-only `gh api` calls at the time of writing and record the SHAs.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: admit keel and superfood-shred to the private runner group`.

### Task 10: Acceptance workflows

**Files:**
- Create: `scripts/acceptance-verdict.py` — pure function over captured evidence JSON: `verdict(phase: str, evidence: dict) -> dict` returning `{"phase", "pass": bool, "failures": [str], "ready_for_migration": bool}`; `ready_for_migration` is true only for phase E with every E criterion met. Criteria are exactly the spec's A–E pass criteria plus the pickup thresholds. Evidence schema: `{"phase", "probe": {"workflow_path", "dispatch_tag", "expected_workflow_sha", "drain": {"run_id", "head_sha", "started", "completed", "conclusion"}, "run": {"id", "attempt", "head_sha", "mode", "jobs": [{"name", "runner_name", "created_at", "started_at", "completed_at", "conclusion"}]}}, "pods": [{"uid", "runner_name", "node", "pool", "created_at", "annotations"}], "nodes": [{"name", "pool", "created_at", "ready_at"}], "events": [...], "pools_before", "pools_after", "arc_contract_after", "phase_c": <acceptance-phase-c.sh evidence or null>, "trust_readback", "expander_readback"}`.
- Create: `test/fixtures/acceptance/<phase>-<case>.json` with one passing and at least one deliberately violating fixture per criterion (e.g. A with a fallback-pool node, B with only one fallback node or primary not restored, C with a killed job, D with a post-drain pod on a burst node or a failed in-flight job, E missing expander readback or smoke failure, any phase with cold p95 of 9 minutes).
- Create: `.github/workflows/runner-acceptance-evidence.yml` (this repo; `workflow_dispatch` inputs `phase` A|B|C|D|E, `probe_run_id` (single run; both modes are one run), `drain_run_id` (phase D only: the Deploy `drain` run in this repository), `dispatch_tag`, `expected_workflow_sha`, `expected_sha`; verifies the probe run's repository (`redducklabs/aurolegal.ai`), workflow path, `headSha`, `event == workflow_dispatch`, attempt, and that the tag resolves to `expected_workflow_sha`; on any failure or the evidence deadline (batch 45 minutes, continuous 150 minutes) it runs `gh run cancel <id>`, waits until the run's status is `completed` (bounded 10 minutes; failure to reach it fails cleanup), then verifies no job of that run is queued or in progress and no runner pod is assigned one of its job IDs, and records cleanup status; while the probe holds, captures runner PodSpecs, node/pool placement, node creation times, events; after completion captures OOM/restart/eviction/scheduling events; computes warm/cold pickup p95 (a job is cold when its runner pod's node was created after the job's `created_at`); runs `acceptance-verdict.py` and fails unless `pass`; for phase E writes `READY_FOR_MIGRATION=true|false` to the job summary and output; uploads `acceptance-<phase>.json`)
- In `D:/repos/aurolegal.ai` worktree (branch `ci/runner-burst-acceptance`): create `.github/workflows/runner-burst-acceptance.yml` with `workflow_dispatch` inputs `expected_workflow_sha`, `mode` (`batch|continuous`), `jobs` (batch: 1..20), and two protocols in one workflow run, so the run ID is the complete lineage and `gh run cancel <id>` cancels every queued and running job:
  - `batch`: a matrix of `jobs` entries; each uploads a marker, waits at the distinct-runner barrier (poll the run's jobs until `jobs` are `in_progress` on distinct runner names; 15-minute timeout → fail), runs `docker build` of a two-line Dockerfile and `docker run`, then holds 10 minutes. Used by phases A, B, E-smoke.
  - `continuous`: a matrix of 64 entries with `strategy.max-parallel: 12` and no barrier; each runs Docker then holds 4 minutes. GitHub starts the next queued entry as each finishes, so up to 12 are in flight and new work keeps arriving; when the fleet drains to four runners, entries keep running four at a time. Used by phase D. No controller or re-dispatch.
  - Both modes fail first if `github.sha != inputs.expected_workflow_sha`. Follow aurolegal.ai's CLAUDE.md runner rules and update its runner contract tests to allow this workflow on `redducklabs-runners`.
- Modify: `docs/runbooks/node-pool-sizing.md` (rewrite for the burst contract: pools, operations table, rollout order, acceptance phases A–E with dispatch commands, rollback, "Rollout record" table)
- Modify: `README.md`, `docs/SETUP.md`, `docs/SECURITY.md` (capacity, cost model, commands)

- [ ] **Step 1: Write failing tests** in the driver: every acceptance fixture produces its expected verdict (passing fixtures pass; each violating fixture fails naming the violated criterion; only E-pass yields `ready_for_migration`); static checks that the evidence workflow verifies `headSha` and the tag, is SHA-guarded, makes no cluster mutation (no `kubectl delete|apply|patch`, no `helm upgrade`, no `doctl ... create|update|delete`), uses `ubuntu-latest`; behavioral checks via step materialization: a verdict failure triggers `gh run cancel` and waits for `completed`; a run that never completes fails cleanup; a probe run from another workflow path, repository, SHA, or event is rejected before evidence collection. Phase D anchors: the evidence workflow reads the drain run (`gh run view <drain_run_id> --json jobs`), verifies it is this repository's Deploy workflow with `operation=drain` at the reviewed SHA and conclusion `success`, and takes `drain_started` = start of its Helm upgrade step and `drain_completed` = completion of its wait step. Phase D passes only if at least 8 probe entries are in progress at `drain_started`, at least one probe entry is in progress at every instant in `[drain_started, drain_completed]`, and the probe run has entries still queued or running at `drain_completed`; a probe that exhausts its matrix before `drain_completed` fails. Phase D fixtures: valid overlapping run with 12 in flight dropping to 4 → pass; every entry succeeded before `drain_completed` → fail; probe started after `drain_started` → fail; fewer than 8 in flight at `drain_started` → fail; any entry `cancelled`/`failure` → fail; a zero-in-flight gap inside the drain interval → fail; drain run from another workflow or a failed drain run → fail.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** both workflows and the docs.
- [ ] **Step 4: Run** drivers + actionlint (both repos) → PASS; aurolegal.ai's own workflow contract tests → PASS.
- [ ] **Step 5: Commit** in each repo (`feat: add runner burst acceptance evidence workflow`; in aurolegal.ai `ci: add runner burst acceptance probe`), push, open PRs; aurolegal.ai PR is merged only with the owner's review since it lands on `main` for dispatch.

### Task 11: Whole-branch verification and PR

- [ ] (After Task 12.) Run `bash test/verify-runner-resources.sh`, `bash test/verify-burst-autoscaling.sh`, `actionlint`, `shellcheck -S error scripts/*.sh test/*.sh deploy/*.sh`, `helm template` render from `CLAUDE.md` → all pass.
- [ ] Open the PR; Codex PR review loop until `VERDICT: APPROVED`; CI green.
- [ ] The rollout (spec "Rollout" steps 1–6 and acceptance A–E) runs after merge, from `main`'s merge SHA, one workflow dispatch at a time, recording each run URL in the runbook's Rollout record.

### Task 12: Runner network isolation

**Files:**
- Create: `deploy/runner-network-policy.yaml` (exact policy from the spec "Runner network isolation")
- Modify: `.github/workflows/deploy-runners.yml` (`deploy`: `kubectl apply --server-side --dry-run=server -f deploy/runner-network-policy.yaml`, then apply, then `verify-runner-network-policy.sh` must pass before the Helm upgrade; bracketed by the identity contract)
- Create: `scripts/verify-runner-network-policy.sh` (validates the complete applicable policy set per the spec: exactly one NetworkPolicy `redducklabs-runner-isolation` in `arc-runners` with `spec` equal to the file; zero CiliumNetworkPolicies in `arc-runners`; every CiliumClusterwideNetworkPolicy deny-only; a missing Cilium CRD counts as zero objects, any other API error fails; no runner pod labeled `doks.digitalocean.com/allow-imds-egress=true`)
- Modify: `scripts/verify-runner-pool-state.sh` (calls the policy-set validator on admission for `enable-burst`, `rebalance`, `acceptance-phase-c`; not on `deploy` admission)
- Modify: `aurolegal.ai` `runner-burst-acceptance.yml` (Task 10): `network-probe` job in batch mode with the spec's allowed/forbidden checks; it fails on any forbidden connection succeeding
- Modify: `scripts/acceptance-verdict.py` (phase A requires `network_probe.pass == true`)
- Modify: `test/verify-burst-autoscaling.sh` (`assert_network_policy`)
- Modify: `docs/security/vulnerability-dismissals.md`, `docs/SECURITY.md` (record the isolation control)

**Interfaces:**
- Consumes: Task 3 gate, Task 6 deploy wiring, Task 10 verdict schema (adds `"network_probe": {"pass": bool, "results": [{"target", "expected", "observed"}]}`).

- [ ] **Step 1: Write failing tests**: policy file parses and equals the spec (selector, both policy types, no ingress rules, exact DNS rule, exact `except` list); policy-set fixtures — valid set (ours + DOKS `deny-imds-egress`) passes; ours unchanged plus a second NetworkPolicy in `arc-runners` allowing egress to `10.124.0.0/20` → fail; plus a second policy allowing ingress → fail; a CiliumNetworkPolicy in `arc-runners` → fail; a clusterwide policy with an `egress` allow rule → fail; Cilium CRDs absent → treated as zero; CRD list API error → fail; a runner pod labeled `allow-imds-egress=true` → fail; our policy with an extra egress rule → fail. Gate fixtures: `netpol-missing` rejected for `enable-burst`/`rebalance`/`acceptance-phase-c` but admitted for `deploy`. Deploy bootstrap fixtures: first deploy with no policy installs it and proceeds to Helm; policy dry-run failure → no apply, no Helm; policy-set validation failing after apply → no Helm. Verdict fixture with any forbidden connection succeeding → phase A fails.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** drivers and actionlint → PASS.
- [ ] **Step 5: Commit** `feat: isolate runner pod network egress`.

### Task 13: Docker Hub pull-through mirror for the DinD sidecar

Added by controller Ruling 18: anonymous Docker Hub pulls are limited to 100 per 6 hours per IP, and a single keel CI run makes about 25-30 Docker Hub pulls, so 20 concurrent jobs on a handful of node IPs would hit the limit.

**Files:**
- Modify: `deploy/dind-values.yaml`, `deploy/dind-values.template.yaml` (dind args add `--registry-mirror=https://mirror.gcr.io`)
- Modify: `scripts/validate-runner-isolation-contract.py` (the dind container args in the burst, burst-acceptance and drain templates include the mirror flag; density and legacy-isolated unchanged so rollback targets still validate)
- Modify: `test/fixtures/arc-burst-values.yaml`, `test/fixtures/arc-drain-values.yaml`, `scripts/render-drain-values.py` output expectations, `test/verify-runner-resources.sh`, `test/verify-burst-autoscaling.sh`
- Modify: `docs/SECURITY.md` (mirror is a public Google-operated cache; pulls still verified by digest where pinned)

- [ ] **Step 1: Write failing tests**: rendered burst and drain manifests carry exactly the dind args `dockerd --host=unix:///var/run/docker.sock --group=$(DOCKER_GROUP_GID) --registry-mirror=https://mirror.gcr.io`; density fixture without the flag still validates as density; burst without the flag fails burst.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites → PASS.
- [ ] **Step 5: Commit** `feat: pull Docker Hub images through mirror.gcr.io`.
