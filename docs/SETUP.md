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

The workflows also read optional repository variables (`CLUSTER_NAME`,
`CLUSTER_CONTEXT`, `RELEASE_NAME`, `RUNNER_SCALE_SET_NAME`, `REGISTRY`,
`REPOSITORY`) and fall back to the Red Duck Labs defaults when they are unset;
see "Optional Repository Variables" in the [README](../README.md).

### Step 2: Prepare the Platform

For initial setup, or a deliberate controller/CRD reconciliation, select
**"Prepare Runner Platform"**, provide the exact reviewed SHA, and confirm the
mutation. This separate workflow owns the `arc-systems`/`arc-runners`
namespaces, an explicitly named `do-registry-secret` (a
`kubernetes.io/dockerconfigjson` secret in `arc-runners`, built from
`doctl registry docker-config` with `DO_TOKEN`), all four pinned ARC CRDs
(server-side applied from the controller chart's `crds/`), and the pinned ARC
controller (Helm release `arc` in `arc-systems`). Both use ARC chart version
`0.14.2` (`ARC_CHART_VERSION` in the workflows). The scale-set Helm chart owns
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
   - **Acknowledge emergency stop**: For `deploy` and `rollback` only - recover
     from an Emergency Stop; the run deletes the stop marker before its Helm
     write (see `docs/runbooks/node-pool-sizing.md`, "Emergency Stop")
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
`record-density` (read-only: verifies the live release equals the render of
the committed `deploy/density-values.yaml`) and `acceptance-phase-c`. Recovery
is Deploy `drain`, Node Pool Sizing `remove-burst`, then Deploy `rollback`,
which upgrades to `deploy/density-values.yaml` (validated as `density`;
independent of Helm history); the legacy-isolated rollback target is retired.
Every Helm write keeps 100 revisions (`--history-max 100`). Emergency Stop
writes the marker `arc-runners/runner-fleet-emergency-stop` before its Helm
write; while it exists the fleet workflows refuse to run (except recovery with
`acknowledge_emergency_stop=true`, Node Pool Sizing `remove-burst`, Runner
Status, and Rebalance, which then retires nothing), and every fleet Helm write
re-checks it afterwards and re-applies the stop. Deploy `deploy` and `rollback` also
install the server-side fence `deploy/runner-emergency-stop-fence.yaml` (a
ValidatingAdmissionPolicy and binding: while the marker exists the API server
denies any AutoscalingRunnerSet write that is not 0/0) before their Helm
write, and every other fleet mutator requires it to equal the file; the
deployment credential must be allowed to create cluster-scoped
`admissionregistration.k8s.io` policies and bindings. Every
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
- **Check Status**: Actions → "Runner Status" → Run workflow (also daily at 09:00 UTC)
- **Runner image**: "Build and Push Runner Image" runs on pushes to `main` that touch the image; "Runner Version Guard" (daily) opens the runner bump PR
- **Usage report**: Actions → "CI Usage Report" (weekly; dispatch with `days` 1-31)
- **metrics-server**: Actions → "Deploy Cluster Addons" (backs `kubectl top`)
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
- **Image**: Custom runner image with pre-installed tools, pulled as `:latest`
  with `imagePullPolicy: Always`, so each new runner pod picks up the newest
  image that **Build and Push Runner Image** pushed from `main`.
- **Pull Secrets**: `imagePullSecrets: do-registry-secret`, created by Prepare
  Runner Platform.

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
# 0.14.2 is ARC_CHART_VERSION in the workflows and CHART_VERSION in
# test/verify-runner-resources.sh; use the version you are upgrading to.
# The placeholder token and controller service account keep the chart from
# attempting live controller discovery.
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 --kube-version 1.36.3 \
  -f deploy/dind-values.yaml \
  --set githubConfigSecret.github_token=PLACEHOLDER \
  --set controllerServiceAccount.name=arc-gha-rs-controller \
  --set controllerServiceAccount.namespace=arc-systems
```

`bash test/verify-runner-resources.sh` runs the same render and asserts the
pod spec; Validate Config also checks that the chart version pins agree.

### Reviewed target: capacity, cost and diagnostics

Each 13.32 GiB / 7880m runner node fits two 3 CPU / 5 GiB pods; a third does
not fit (measured on the baseline size; assumed for the burst sizes until
acceptance Phases A and B measure them). The baseline pool
`github-runners-pool-16g` keeps two `s-8vcpu-16gb` nodes ($192/month). The
burst pools `github-runners-burst-amd-16g` (`s-8vcpu-16gb-amd`, 0..6) and
`github-runners-burst-intel-16g` (`s-8vcpu-16gb-intel`, 0..2), $0.16667 per
node-hour each, are opened by Node Pool Sizing `enable-burst` and scale from
zero with the cluster autoscaler, primary first (priority expander). The
billed ceiling is 10 runner nodes ($1,088/month only if all ran all month);
the estimate from measured demand is about $175/month of burst nodes. `scripts/runner-cost-report.sh --month YYYY-MM` reports measured
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
bash test/verify-tools.sh
```

This tests all pre-installed tools in the first runner pod of `arc-runners` in
the current kube context (through `kubectl exec`), and starts a throwaway
container in that pod's dind daemon to check the shared tool cache. Run it
only when a live check is explicitly wanted. Most scripts in this repository
are committed without the executable bit, so run them with `bash` or
`chmod +x` them first. The offline suites that need no cluster are listed in
the README's "Testing" section.

### 2. Test in an allow-listed private repository

This self-hosted example is for an allow-listed private repository only (one
listed in `deploy/trusted-runner-repositories.txt`). Do not copy it into a
public repository or a repository outside the selected runner group. The
reviewed target has CI deployment and live-acceptance evidence from
2026-11-01 (the "Rollout record" in `docs/runbooks/node-pool-sizing.md`).

```yaml
# .github/workflows/test-runners.yml
name: Test Self-Hosted Runners

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: redducklabs-runners
    steps:
      - uses: actions/checkout@v7
      
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

Use Runner Status for CI diagnostics. The local helper supports status only.
It needs `kubectl`, `jq` and an authenticated `gh`, and it switches the current
kube context to `CLUSTER_CONTEXT` (default `do-sfo3-redducklabs-cluster`):

```bash
# Check status regularly
bash scripts/scale-runners.sh status
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
   Run Deploy GitHub Runners `drain`, then Node Pool Sizing `remove-burst`,
   then Deploy GitHub Runners `rollback` with the reviewed `expected_sha`; it
   upgrades to the committed `deploy/density-values.yaml`. CI
   verifies the restored `density` (2/4) template and the private runner-group
   boundary.

5. **Jobs stay queued while idle runners are online**
   Check the runner version first: GitHub stops sending jobs to runners more
   than 30 days behind the latest release, silently. Merge the Runner Version
   Guard bump PR; recovery is in `docs/runbooks/node-pool-sizing.md`,
   "Jobs are assigned but no runner receives them".

6. **After an Emergency Stop**
   The release is in a `stopped` state (`burst-stopped`, `density-stopped` or
   `drain-stopped`); the Emergency Stop summary names it and the recovery that
   admits it. See `docs/runbooks/node-pool-sizing.md`, "Emergency Stop".

### Getting Help

1. Check the [troubleshooting section](../README.md#troubleshooting) in the main README
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
