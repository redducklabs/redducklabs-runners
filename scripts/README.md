# GitHub Actions Runner Management Scripts

This directory contains the scripts that manage the redducklabs GitHub Actions
runner fleet. Most of them are the implementation behind the fleet workflows in
`.github/workflows/` and are normally run only by those workflows; a few are
local helpers for an operator's own terminal. Each script's header comment is
the authoritative reference for its arguments, output and exit codes.

Production changes go through the reviewed GitHub Actions workflows, not a local
machine. Runner bounds are no longer changed at runtime: they change only by a
reviewed commit to `deploy/dind-values.yaml` followed by **Deploy GitHub
Runners**. See [`../docs/runbooks/node-pool-sizing.md`](../docs/runbooks/node-pool-sizing.md)
for the fleet states, workflows and recovery procedures.

## Prerequisites

Tools, depending on the script: `kubectl`, `helm`, `jq`, `python3` (with
PyYAML), `doctl` (authenticated), and `gh` (authenticated). Credentials are
per script, not global:

- `gh auth login` (or `GH_TOKEN`): `scale-runners.sh`, `ci-usage-report.sh`,
  `dismiss-base-image-vulnerabilities.sh`, `verify-runner-trust-boundary.sh`,
  `retire-idle-burst-runners.sh`, `acceptance-phase-c.sh`.
- `RUNNER_TOKEN`: `drain-runners.sh` and `rollback-density.sh` (the token the
  scale set authenticates with; Helm needs it to render the release).
- `GITHUB_TOKEN` (optional): `runner-admin.sh` and `emergency-stop.sh` use it
  for GitHub registration checks; `emergency-stop.sh` also passes it to Helm.

Only `scale-runners.sh` switches the Kubernetes context itself (to
`CLUSTER_CONTEXT`, default `do-sfo3-redducklabs-cluster`). Every other script
uses the current context, so select and confirm it first:

```bash
kubectl config use-context do-sfo3-redducklabs-cluster
kubectl config current-context
```

Scripts that take a cluster name read `--cluster-name` or `CLUSTER_NAME`
(default `redducklabs-cluster`, the DigitalOcean cluster name, which differs
from the kubeconfig context name).

Several scripts are committed without the executable bit (`git ls-files -s
scripts`). Run those with `bash scripts/<name>.sh` or `python3 scripts/<name>.py`.
The examples below run from the repository root unless noted.

## Local operator helpers

### 📊 scale-runners.sh
Read-only runner status. The former `up`, `down`, `max` and `scale`
subcommands were removed with ordinary runtime scaling; `status` is the only
argument it accepts.

```bash
bash scripts/scale-runners.sh status
```

Requires `kubectl`, `jq` and an authenticated `gh`. It switches to
`CLUSTER_CONTEXT`, then prints the AutoscalingRunnerSet min/max, the runner
pods, and the number of registered `redducklabs-runners*` runners on GitHub
(with up to ten name/status lines).

### 🎛️ runner-admin.sh
Interactive menu for runner administration. Run it from `scripts/`: it calls
`./scale-runners.sh` by relative path.

```bash
cd scripts && bash runner-admin.sh
```

Requires `kubectl` and `helm`; options 8 and 10 also need `GITHUB_TOKEN`.
Working options: show runner status (1), force restart all runner pods (6,
asks for confirmation), view a pod's runner logs (7), list failed/stuck pods
(8), delete Failed/Succeeded pods (9), show GitHub registration (10).

The scaling options (2-5) still call the removed `scale-runners.sh up/max/down/scale`
subcommands, which print its usage message and exit, ending the menu
(`set -e`). Change runner bounds through
`deploy/dind-values.yaml` and Deploy instead.

### 🚨 emergency-stop.sh
Local emergency shutdown for all runners. The **Emergency Stop Runners**
workflow (`emergency-stop.yml`, confirm with `STOP-RUNNERS`) is the preferred
path; use this script only when the workflow cannot run.

```bash
bash scripts/emergency-stop.sh
```

**USE WITH CAUTION!** It uses the current kube context and requires typing
`STOP` to confirm. Then it:
- Writes the Emergency Stop marker ConfigMap
  `arc-runners/runner-fleet-emergency-stop`, so fleet workflows refuse to run
  and any later fleet Helm write re-applies 0/0
- Checks that the server-side fence (`deploy/runner-emergency-stop-fence.yaml`)
  denies non-zero runner writes
- Runs `helm upgrade --reuse-values` with `minRunners=0`, `maxRunners=0`
  (the script hides this step's errors, so confirm the result with
  `bash scripts/scale-runners.sh status`)
- Force deletes all runner pods and reports any still terminating
- With `GITHUB_TOKEN` set, reports how many runners GitHub still shows online

It exits 1 when the fence could not be proven (the stop itself is still
applied). Restore runners only through the workflows named in the script's
closing message and in the runbook's "Emergency Stop" section.

### 🔒 dismiss-base-image-vulnerabilities.sh
Security alert dismissal script for base image vulnerabilities.

```bash
bash scripts/dismiss-base-image-vulnerabilities.sh
```

**Purpose:** Dismisses code-scanning alerts that originate from the official
GitHub Actions runner base image (`ghcr.io/actions/actions-runner`, pinned by
`ACTIONS_RUNNER_BASE` in `docker/Dockerfile.custom-runner`) and cannot be fixed
without breaking runner compatibility.

**Covered Vulnerabilities:**
- CVE-2025-47907: Container runtime components (alerts 11,10,8,6,5,4,3)
- CVE-2024-21538: Node.js cross-spawn vulnerability (alert 2)

**Features:**
- Interactive confirmation prompt
- Batch dismissal of multiple alerts
- Detailed dismissal comments with risk justification
- Verification of dismissal success
- Links to comprehensive risk assessment in
  [`../docs/security/vulnerability-dismissals.md`](../docs/security/vulnerability-dismissals.md)

**Requirements:**
- GitHub CLI (`gh`) installed and authenticated
- Repository admin permissions for security alert management
- Review and approval of risk acceptance in
  [`../docs/security/vulnerability-dismissals.md`](../docs/security/vulnerability-dismissals.md)

### launch-codex.sh
Starts `codex` in the repository root, passing all arguments through
(`bash scripts/launch-codex.sh exec ...`). See
[`../claude_help/codex-review-process.md`](../claude_help/codex-review-process.md).

## Read-only reports

| Script | Usage | What it reports | Run by |
|--------|-------|-----------------|--------|
| `report-runner-pools.sh` | `--cluster-name NAME` | One `POOL` line per runner pool (provider count, min/max, autoscale, registered and ready nodes) and an `EXPANDER` line. Reports drift; never rejects. | Runner Status |
| `runner-cost-report.sh` | `--month YYYY-MM [--cluster-name NAME]` | Runner and worker node-hours and cost from the DigitalOcean invoice, and burst node-hours; month-to-date account usage for the current month. Prints `cost data unavailable: <reason>` rather than a zero. Needs `doctl`. | Local only |
| `ci-usage-report.sh` | `[--org ORG] [--days N] [--end TIME] [--json PATH] [--per-repo]` | Fleet vs GitHub-hosted job-minutes, estimated hosted cost, fleet concurrency profile and queue wait over N days (default 7, max 31). Organization totals only; `--per-repo` is refused when `GITHUB_ACTIONS=true`. Needs `gh` with read access to the org's Actions runs. | CI Usage Report (weekly) |
| `read-live-runner-versions.sh` | `<expected version>` | Whether every Running pod uses an image proven to report the expected Actions runner version. Prints `VERSIONS=` and `OK=`. | Runner Version Guard |

## Runner version

`check-runner-version.py` compares the pinned base image
(`ARG ACTIONS_RUNNER_BASE` in `docker/Dockerfile.custom-runner`) with upstream
releases. GitHub rejects runners more than 30 days behind the latest release.

```bash
gh api 'repos/actions/runner/releases?per_page=50' > /tmp/releases.json
python3 scripts/check-runner-version.py check --releases /tmp/releases.json
python3 scripts/check-runner-version.py apply --version X.Y.Z
```

`check` prints `PINNED=`, `LATEST=`, `STATUS=` (and `AGE_DAYS=`/`DEADLINE=`
when an update exists); exit 1 means overdue, 2 unreadable data. `apply`
rewrites the pin in the Dockerfile, `README.md` and
`docs/toolchain/dockerfile-security-refactor.md`. The **Runner Version Guard**
workflow runs both and opens the bump PR.

## Fleet operations (CI only)

These scripts mutate production and are designed to run inside their workflow,
after the workflow verifies `expected_sha` and holds the
`runner-fleet-mutation` lock. Do not run them locally unless you have been
explicitly asked to perform that exact operation. Each `--apply` or Helm write
runs inside an identity bracket against a snapshot written by
`verify-runner-pool-state.sh --emit-identities`.

| Script | Usage | Purpose | Run by |
|--------|-------|---------|--------|
| `verify-runner-pool-state.sh` | `--cluster-name N --operation OP [--emit-identities F] [--acknowledge-emergency-stop]`, or `--cluster-name N --compare-identities F --transition T` | Read-only pool-state gate. Admits or rejects an operation and prints `STATE: arc=... pools=... burst=...`. `--operation status` is safe to run locally. | Every fleet workflow |
| `burst-pools.sh` | `create-burst\|configure-expander\|enable-burst\|set-burst-maxima\|remove-burst --cluster-name N [--primary-max P --fallback-max F] [--apply --identities F]` | Burst node pools and the cluster-autoscaler expander. Without `--apply` it prints `PLAN:` lines only. | Node Pool Sizing |
| `drain-runners.sh` | `--identities F` (needs `RUNNER_TOKEN`) | Deploy `drain`: moves ARC to the drain contract and waits for the burst pools to empty. | Deploy GitHub Runners |
| `render-drain-values.py` | `OUTPUT_PATH` | Writes the drain values derived from `deploy/dind-values.yaml`. | `drain-runners.sh` |
| `rollback-density.sh` | `--identities F [--acknowledge-emergency-stop]`, or `--verify-live` (needs `RUNNER_TOKEN`) | Deploy `rollback` to the committed `deploy/density-values.yaml` (2/4); `--verify-live` is the read-only Scale Runners `record-density` check. | Deploy GitHub Runners, Scale GitHub Runners |
| `retire-idle-burst-runners.sh` | `--identities F [--dry-run]` (needs `GH_TOKEN`) | Deletes idle EphemeralRunners on burst nodes, never more than the free baseline slots, so they come back on baseline. | Rebalance Runners (hourly), `drain-runners.sh`, `acceptance-phase-c.sh` |
| `verify-runner-network-policy.sh` | `[--policy-file FILE]` | Read-only check that the runner NetworkPolicy set matches `deploy/runner-network-policy.yaml`. | Deploy, pool-state gate |
| `validate-runner-isolation-contract.py` | `--contract C --kind values\|manifest\|asrs-list --min-runners N --max-runners N --runner-group default\|private` (input on stdin) | Validates Helm values, a rendered manifest or a live AutoscalingRunnerSet against a named ARC contract. | Deploy GitHub Runners, `scripts/lib/fleet-ops.sh` |
| `verify-runner-trust-boundary.sh` | `--expected-sha SHA [--verify-only]` | Reconciles the `redducklabs-private-runners` runner group to exactly the repositories in `deploy/trusted-runner-repositories.txt`, then reads it back. Without `--verify-only` it creates or updates the group. Needs `gh` with org admin rights and a checkout at `SHA`. | Deploy GitHub Runners (`deploy`, `prepare-trust-boundary`) |

`scripts/lib/` holds the shared helpers these scripts source or call
(`fleet-ops.sh`, `arc-identity.sh`, `runner_pool_state.py`,
`runner_stop_fence.py`, `runner_network_policy.py`, `fleet_occupancy.py`,
`retire_idle_runners.py`, `runner_cost_report.py`, `ci_usage_report.py`). They
are not entry points.

## Acceptance (CI only)

Burst-rollout acceptance, described in
`docs/specs/2026-10-26-runner-burst-autoscaling-design.md` ("Acceptance"):

| Script | Usage | Run by |
|--------|-------|--------|
| `acceptance-phase-c.sh` | `--max-cycles N --identities F [--evidence PATH]`, or `--restore --identities F` | Scale GitHub Runners `acceptance-phase-c` |
| `acceptance-evidence.py` | `verify-probe\|verify-anchors\|watch\|finalize\|cleanup --state F ...` | Runner Acceptance Evidence |
| `acceptance-verdict.py` | `--phase A\|B\|C\|D\|E EVIDENCE [--out PATH]` | Runner Acceptance Evidence (pure function over evidence; safe locally) |

## Common Operations

### Check runner health
```bash
bash scripts/scale-runners.sh status
bash scripts/verify-runner-pool-state.sh --cluster-name redducklabs-cluster --operation status
```

### Change runner bounds
Edit `minRunners`/`maxRunners` in `deploy/dind-values.yaml`, get it reviewed and
merged, then dispatch **Deploy GitHub Runners** with `operation=deploy`.

### Stop all runners
Dispatch **Emergency Stop Runners**; fall back to `scripts/emergency-stop.sh`
only if the workflow cannot run.

### Restart stuck runners
```bash
kubectl delete pod <pod-name> -n arc-runners
# New pod will be created automatically
```

## Troubleshooting

### Runners not scaling up
- Check the scale set's GitHub token is valid
- Verify namespace exists: `kubectl get ns arc-runners`
- Check controller logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-rs-controller`

### Stuck runners
- Force delete: `kubectl delete pod <name> -n arc-runners --force`
- Use Emergency Stop if multiple are stuck

### Jobs not being picked up
- Verify runners are online: `bash scripts/scale-runners.sh status`
- Check workflow uses: `runs-on: redducklabs-runners`
- Check the runner version first: GitHub silently stops assigning jobs to
  runners more than 30 days behind the latest release (see "Runner version")

## Production Configuration

All scripts are configured for redducklabs production environment:
- Namespace: `arc-runners`
- Release name: `redducklabs-runners`
- Cluster context: `do-sfo3-redducklabs-cluster`
- DigitalOcean cluster name: `redducklabs-cluster`
- Runner label: `redducklabs-runners`

## Security Notes

- Never commit GitHub tokens to git
- Fleet scripts read live state before and after every mutation and stop on
  any difference; destructive local scripts ask for confirmation
- Emergency stop requires explicit confirmation
- Reports that run in CI print organization totals only, because this
  repository's Actions logs are public

## Notes

- Scaling changes apply asynchronously through ARC and Kubernetes
- Runners are ephemeral - they restart after each job
- Docker-in-Docker pods show as 2/2 (runner + dind sidecar)
- Production bounds are `minRunners: 2`, `maxRunners: 20` (burst), on at most
  10 runner nodes; see `deploy/dind-values.yaml` and the runbook
