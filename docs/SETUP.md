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

### Step 2: Deploy Runners

1. Go to the **Actions** tab in your repository
2. Select **"Deploy GitHub Runners"** workflow from the left sidebar
3. Click **"Run workflow"** button
4. Configure deployment options:
   - **Min runners**: Minimum number of runners (default: 2)
    - **Max runners**: Maximum number of runners (default and ceiling: 4)
    - **Expected SHA**: Exact reviewed commit SHA
    - **Accept privileged runner co-tenancy**: Required for trust preparation or deployment
   - **Runner image**: Docker image to use (default: `registry.digitalocean.com/redducklabs/github-runner:latest`)
   - **Namespace**: Kubernetes namespace (default: `arc-runners`)
5. Click **"Run workflow"** to start deployment

### Step 3: Monitor Deployment

The reviewed workflow validates the expected SHA, reconciles the private runner
group, performs server-side dry-runs of the rendered `AutoscalingRunnerSet` and
representative Pod, checks live node capacity, then deploys only when those
gates pass. The `prepare-trust-boundary` operation performs the runner-group
and public-workflow checks without Helm, Kubernetes, or DigitalOcean mutation.

### Step 4: Manage Runners

Use the GitHub Actions workflows to manage your runners:

- **Prepare trust boundary / deploy / rollback**: Actions → "Deploy GitHub Runners" → Run workflow
- **Node-pool bounds**: Actions → "Node Pool Sizing" → Run workflow (`min_nodes=2`, `max_nodes=2`)
- **Check Status**: Actions → "Runner Status" → Run workflow
- **Emergency Stop**: Actions → "Emergency Stop Runners" → Run workflow

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
maxRunners: 4
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

- **minRunners / maxRunners**: 2 warm runners and a fixed maximum of 4.
- **pod resources**: the scheduler reserves 3 CPU and 5 GiB for the whole pod;
  the runner and DinD sidecar share its 6 GiB memory limit. Neither container
  defines a competing CPU or memory budget.
- **runner group**: `redducklabs-private-runners`, reconciled by CI to selected
  private repositories only. Public repositories must not select this label.
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

### Capacity and diagnostic model

Two 3 CPU / 5 GiB pods fit on each measured 13.32 GiB / 7880m dedicated node;
a third does not. The production pool is fixed at two $96 nodes, so the four
self-hosted runner ceiling is also the $192 monthly cost cap. Runner Status
reports sanitized DOKS autoscaler `Backoff` diagnostics when its known provider
text format is available. It reports diagnostics unavailable for missing or
changed provider data and never treats those diagnostics as a capacity gate.

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

### 2. Test in GitHub Workflow

Create a test workflow in your repository:

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
repository allow-list. It scans every public organization workflow and fails
closed on a direct or dynamic self-hosted runner selector.

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
   Use Deploy GitHub Runners' `rollback` operation with the recorded
   post-quiesce Helm revision and the reviewed `expected_sha`. CI verifies the
   restored isolated 2/2 runner template and the private runner-group boundary.

### Getting Help

1. Check the [troubleshooting section](README.md#troubleshooting) in the main README
2. Review pod logs and events
3. Use the test scripts to identify issues
4. Check GitHub Actions Runner Controller documentation

## ✅ Setup Verification Checklist

- [ ] `RUNNER_TOKEN` and `DO_TOKEN` repository secrets are configured
- [ ] `prepare-trust-boundary` completed with explicit co-tenancy acceptance
- [ ] Node Pool Sizing confirms `min_nodes=max_nodes=count=2`
- [ ] Deploy preflight and deployment completed from the same `expected_sha`
- [ ] Runner Status reports the expected four-runner/two-node contract
