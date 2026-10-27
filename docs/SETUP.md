# Setup Guide - Red Duck Labs GitHub Actions Runners

This guide provides detailed setup instructions for deploying GitHub Actions self-hosted runners for Red Duck Labs.

## 🚀 GitHub Actions deployment

Runner trust preparation, deployment, node-pool changes, and rollback are
CI-only operations. The local status helper is read-only; it does not deploy,
scale, or roll back the runner fleet.

### Step 1: Configure Repository Secrets

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Add the following secrets:

#### Required Secrets:

| Secret Name | Description | How to Get |
|------------|-------------|------------|
| `RUNNER_TOKEN` | Personal Access Token for runner registration | [Create here](https://github.com/settings/tokens/new?scopes=admin:org,repo,workflow) with scopes: `admin:org`, `repo`, `workflow` |
| `DO_TOKEN` | DigitalOcean API token | [DigitalOcean Control Panel](https://cloud.digitalocean.com/account/api/tokens) → Generate New Token |

### Step 2: Prepare the Platform

For initial setup, or a deliberate controller/CRD reconciliation, select
**"Prepare Runner Platform"**, provide the exact reviewed SHA, and confirm the
mutation. This separate workflow owns the `arc-systems`/`arc-runners`
namespaces, an explicitly named `do-registry-secret`, all four pinned ARC CRDs,
and the pinned ARC controller. The scale-set Helm chart owns
`redducklabs-runners-gha-rs-no-permission`; platform preparation must not create
that ServiceAccount.

Normal deploy and rollback runs never create or upgrade these platform
prerequisites. Deploy validates the registry secret type, Docker config, and
non-empty `registry.digitalocean.com` auth without logging credential data. A
pre-existing no-permission ServiceAccount is accepted only with exact Helm
ownership for release `redducklabs-runners` in `arc-runners`. Missing, stale,
foreign-owned, or malformed prerequisites fail closed before Helm.

Deploy only upgrades an existing `redducklabs-runners` release. The pool-state
gate admits an operation only when exactly one deployed release of the pinned
chart exists, so there is no first-install bootstrap: a fresh cluster needs a
separate, reviewed bootstrap procedure, which is out of scope of the burst
design (Ruling 15 in the burst autoscaling design record).

### Step 3: Deploy Runners

1. Go to the **Actions** tab in your repository
2. Select **"Deploy GitHub Runners"** workflow from the left sidebar
3. Click **"Run workflow"** button
4. Configure deployment options:
   - **Operation**: `deploy` (also `prepare-trust-boundary`, `drain`, `rollback`)
   - **Expected SHA**: Exact reviewed commit SHA
   - **Accept privileged runner co-tenancy**: Required for trust preparation or deployment
   - **Rollback revision**: For `drain` and `rollback` only - the `density`
     Helm revision recorded by Scale Runners `record-density`
   - **Runner image**: Fixed canonical value `registry.digitalocean.com/redducklabs/github-runner:latest`; deployment rejects alternatives so every deploy validates the same lifecycle contract.
   - **Namespace**: Kubernetes namespace (default: `arc-runners`)
5. Click **"Run workflow"** to start deployment

Runner bounds are not inputs. Deploy renders exactly the `burst` contract
committed in `deploy/dind-values.yaml` (`minRunners: 2`, `maxRunners: 20`).

`arc-runners` is the only accepted runner namespace. Helm ownership annotations
and prepared platform resources use that canonical namespace, so deploy and
rollback input validation rejects any other value before mutation.

### Step 4: Monitor Deployment

The reviewed workflow validates the expected SHA, reconciles the private runner
group, performs server-side dry-runs of the rendered `AutoscalingRunnerSet` and
representative Pod, checks live node capacity, then deploys only when those
gates pass. The `prepare-trust-boundary` operation performs the runner-group
and public-workflow checks without Helm, Kubernetes, or DigitalOcean mutation.
Ordinary min/max scaling is retired: runner bounds change only through a
reviewed commit to `deploy/dind-values.yaml` followed by Deploy, which renders
and reads back exactly the `burst` contract. Scale Runners keeps only
`record-density` (records the `density` rollback revision) and
`acceptance-phase-c`. Recovery is Deploy `drain` (with the recorded `density`
revision as `rollback_revision`, verified before the drain upgrade), Node Pool
Sizing `remove-burst`, then Deploy `rollback` to that revision; the
legacy-isolated rollback target is retired. Every Helm write keeps 100
revisions (`--history-max 100`), so the recorded revision is not pruned. Every
operation is admitted by `scripts/verify-runner-pool-state.sh` under its own
name. Deploy also installs the runner NetworkPolicy
(`deploy/runner-network-policy.yaml`) before its Helm upgrade, and
`enable-burst`, `rebalance` and `acceptance-phase-c` are admitted only while
`scripts/verify-runner-network-policy.sh` validates the runner network policy
set (see `docs/SECURITY.md`, "Network Policies").

### Step 5: Manage Runners

Use the GitHub Actions workflows to manage your runners:

- **Prepare trust boundary / deploy / rollback**: Actions → "Deploy GitHub Runners" → Run workflow
- **Initial platform/controller preparation**: Actions → "Prepare Runner Platform" → Run workflow
- **Burst node pools**: Actions → "Node Pool Sizing" → Run workflow (`operation` = `create-burst`, `configure-expander`, `enable-burst`, `set-burst-maxima` or `remove-burst`; the baseline pool stays `min=max=count=2`)
- **Idle burst runners**: Actions → "Rebalance Runners" (hourly; dispatch with `expected_sha`)
- **Acceptance**: Actions → "Runner Acceptance Evidence" (phases A-E; see the runbook)
- **Check Status**: Actions → "Runner Status" → Run workflow
- **Emergency Stop**: Actions → "Emergency Stop Runners" → Run workflow. It
  runs immediately (its own `runner-emergency-stop` concurrency group, not the
  shared fleet lock) and leaves a `stopped` state; recovery is in
  `docs/runbooks/node-pool-sizing.md`, "Emergency Stop"

## 🔧 Configuration Details

### Runner Scale Set Configuration

The `deploy/dind-values.yaml` file contains the main configuration:

Abridged - see `deploy/dind-values.yaml` for the full file and the reasoning
comments.

```yaml
# GitHub configuration
githubConfigUrl: "https://github.com/redducklabs"
runnerScaleSetName: "redducklabs-runners"

# Scaling settings
minRunners: 2
maxRunners: 20
runnerGroup: "redducklabs-private-runners"

# NOTE: containerMode.type is deliberately NOT "dind" - see below.
template:
  spec:
    resources:                         # shared scheduler budget for the pod
      requests:
        cpu: "3"
        memory: "5Gi"
      limits:
        memory: "6Gi"
    initContainers:
    - name: init-dind-externals
      # ... copies runner externals into a shared volume
    - name: dind                      # Docker daemon, as a native sidecar
      image: docker:29.7.2-dind
      restartPolicy: Always
      securityContext:
        privileged: true

    containers:
    - name: runner
      image: registry.digitalocean.com/redducklabs/github-runner:latest
```

### Key Configuration Options

- **minRunners / maxRunners**: 2 warm runners and a maximum of 20 (two pods on
  each of up to 10 runner nodes). Warm runners prefer the baseline pool; runner
  pods carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`.
- **pod resources**: the scheduler reserves 3 CPU and 5 GiB for the whole pod;
  the runner and DinD sidecar share its 6 GiB memory limit. Neither container
  defines a competing CPU or memory budget.
- **runner group**: `redducklabs-private-runners`, reconciled by CI to selected
  private repositories only. Public repositories must not select this label.
- **Kubernetes API token**: runner Pods set
  `automountServiceAccountToken: false`; admission must not inject an API token
  volume or mount.
- **Image**: Custom runner image with pre-installed tools.
- **Pull Secrets**: For accessing private registries.

### Why the Docker sidecar is declared manually

ARC's built-in `containerMode.type: "dind"` renders the Docker daemon sidecar
from a hardcoded chart template and filters a user-supplied container named
`dind` out of values. The explicit native sidecar is retained so the repository
owns the Docker socket, startup wiring, pinned image, and the pod template that
receives the shared pod-level resource budget.

Declaring the sidecar explicitly (the chart's "default" container mode) keeps
the pod template under repository control. The spec in `deploy/dind-values.yaml`
reproduces the required Docker wiring and adds the shared pod-level resources
and a pinned image.

**On chart upgrades, re-render and diff the pod spec**, because we now own
pieces the chart used to manage:

```bash
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version <version> --kube-version <cluster-version> \
  -f deploy/dind-values.yaml
```

### Reviewed target: capacity, cost and diagnostics

Each 13.32 GiB / 7880m runner node fits two 3 CPU / 5 GiB pods; a third does
not fit. The baseline pool `github-runners-pool-16g` keeps two `s-8vcpu-16gb`
nodes ($192/month). The burst pools `github-runners-burst-16g` (0..6) and
`github-runners-burst-amd-16g` (0..2) are opened by Node Pool Sizing
`enable-burst` and scale from zero with the cluster autoscaler, primary first
(priority expander). The billed ceiling is 10 runner nodes ($992/month only if
all ran all month); the estimate from measured demand is about $150/month of
burst nodes. `scripts/runner-cost-report.sh --month YYYY-MM` reports measured
runner node-hours and cost from the DigitalOcean invoice. Runner Status reports
burst node counts per pool and sanitized DOKS autoscaler `Backoff` diagnostics
when its known provider text format is available; it reports diagnostics
unavailable for missing or changed provider data and never treats those
diagnostics as a capacity gate.

An OOM kill identifies the killed container but does not attribute aggregate
shared-budget consumption. Diagnose from pod aggregate use, both containers'
use and restart counts, node headroom, and events.

See `docs/runbooks/node-pool-sizing.md`.

## 🧪 Testing Setup

### 1. Verify Tools Installation

```bash
./test/verify-tools.sh
```

This tests all pre-installed tools in the runners.

### 2. Test in an allow-listed private repository

This self-hosted example is for an allow-listed private repository only, after
the reviewed target has CI deployment and external live-acceptance evidence. Do
not copy it into a public repository or a repository outside the selected runner
group.

```yaml
# .github/workflows/test-runners.yml
name: Test Self-Hosted Runners

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: redducklabs-runners
    steps:
      - uses: actions/checkout@v4
      
      - name: Test Python
        run: |
          python3 --version
          pip --version
      
      - name: Test Node.js
        run: |
          node --version
          npm --version
      
      - name: Test Infrastructure Tools
        run: |
          kubectl version --client
          helm version
          terraform version
          docker --version
      
      - name: Test Docker-in-Docker
        run: |
          docker run --rm hello-world
```

For a public repository, keep the job on GitHub-hosted infrastructure:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
```

The trust-boundary verifier scans every public repository at an immutable
default-branch head SHA and rechecks the branch and head before any runner-group
mutation. The committed repository identities for `agent-handoff-toolkit`,
`fountainrank`, and `claude-control` are always resolved and scanned even if an
enumeration response omits them.

## 🛠️ Status monitoring

Use Runner Status for CI diagnostics. The local helper supports status only:

```bash
# Check status regularly
./scripts/scale-runners.sh status

```

## 🔒 Security Setup

Runner pods include privileged DinD. The accepted co-tenancy risk and
compensating controls are recorded in
[`docs/security/vulnerability-dismissals.md`](security/vulnerability-dismissals.md).
The CI trust-boundary step uses `RUNNER_TOKEN` to reconcile the named runner
group, selected visibility, disabled public access, and the committed private
repository allow-list. It reads each allow-listed repository's fork-PR workflow
policy and fails closed unless workflows from fork pull requests are disabled.
It scans every public organization workflow and fails closed on a direct or
dynamic self-hosted runner selector.

## 🚨 Troubleshooting Setup

### Common Setup Issues

1. **Trust or preflight failure**
   Review the failed CI gate. It fails before Helm mutation for a bad expected
   SHA, runner-group policy drift, public workflow selection, unsupported
   server-side admission, or insufficient capacity/headroom.

2. **Provider capacity signal**
   Run **Runner Status**. It reports allow-listed, redacted autoscaler Backoff
   diagnostics when available and otherwise reports diagnostics unavailable.

3. **Memory/OOM signal**
   An `OOMKilled` container is not causal attribution under the shared 6 GiB
   pod budget. Use Runner Status aggregate and per-container diagnostics.

4. **Rollback**
   Run Deploy GitHub Runners `drain` with the `density` revision recorded by
   Scale Runners `record-density` as `rollback_revision` (verified before the
   drain upgrade), then Node Pool Sizing `remove-burst`, then Deploy GitHub
   Runners `rollback` with that revision and the reviewed `expected_sha`. CI
   verifies the restored `density` (2/4) template and the private runner-group
   boundary.

5. **After an Emergency Stop**
   The release is in a `stopped` state (`burst-stopped`, `density-stopped` or
   `drain-stopped`); the Emergency Stop summary names it and the recovery that
   admits it. See `docs/runbooks/node-pool-sizing.md`, "Emergency Stop".

### Getting Help

1. Check the [troubleshooting section](README.md#troubleshooting) in the main README
2. Review pod logs and events
3. Use the test scripts to identify issues
4. Check GitHub Actions Runner Controller documentation

## ✅ Setup Verification Checklist

- [ ] `RUNNER_TOKEN` and `DO_TOKEN` repository secrets are configured
- [ ] `prepare-trust-boundary` completed with explicit co-tenancy acceptance
- [ ] Prepare Runner Platform produced the typed `do-registry-secret`, all four
  Established ARC CRDs, and the Ready pinned controller
- [ ] Runner Status shows the baseline pool at `min_nodes=max_nodes=count=2`
- [ ] Deploy preflight and deployment completed from the same `expected_sha`
- [ ] Runner Status reports an admitted pool state (the `STATE:` line), the per-pool node counts and bounds, and no `EXPANDER drift` line
