# Setup Guide - Red Duck Labs GitHub Actions Runners

This guide provides detailed setup instructions for deploying GitHub Actions self-hosted runners for Red Duck Labs.

## 🚀 Method 1: GitHub Actions Deployment (Recommended)

The easiest way to deploy runners is directly from GitHub Actions - no local setup required!

### Step 1: Configure Repository Secrets

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Add the following secrets:

#### Required Secrets:

| Secret Name | Description | How to Get |
|------------|-------------|------------|
| `RUNNER_TOKEN` | Personal Access Token for runner registration | [Create here](https://github.com/settings/tokens/new?scopes=admin:org,repo,workflow) with scopes: `admin:org`, `repo`, `workflow` |
| `DO_TOKEN` | DigitalOcean API token | [DigitalOcean Control Panel](https://cloud.digitalocean.com/account/api/tokens) → Generate New Token |

#### Optional Repository Variables:

The workflows read these repository variables (**Settings** → **Secrets and variables** → **Actions** → **Variables**) and fall back to the production defaults when unset: `CLUSTER_NAME` (`redducklabs-cluster`), `CLUSTER_CONTEXT` (`do-sfo3-redducklabs-cluster`), `RELEASE_NAME` and `RUNNER_SCALE_SET_NAME` (`redducklabs-runners`), `REGISTRY` (`registry.digitalocean.com`), `REPOSITORY` (`redducklabs/github-runner`).

#### Other Prerequisites:

- **Runner node pool**: the node pool `github-runners-pool-16g` (`s-8vcpu-16gb`, autoscaling) must already exist with label `node-type=github-runner` and taint `github-runner=true:NoSchedule`. `deploy/dind-values.yaml` pins runners to it, and the "Node Pool Sizing" workflow only updates an existing pool. See [the node pool sizing runbook](runbooks/node-pool-sizing.md).
- **Runner image**: the default image `registry.digitalocean.com/redducklabs/github-runner:latest` must exist before the first deploy. Run the "Build and Push Runner Image" workflow once if it has not been published yet.
- **Build cache package access (one-time)**: after the first `main` build publishes `github-runner-buildcache`, go to Org → Packages → `github-runner-buildcache` → Settings → Manage Actions access, and add this repository with role **Admin**. Without it, the scheduled "Prune Build Cache" runs fail.

### Step 2: Deploy Runners

1. Go to the **Actions** tab in your repository
2. Select **"Deploy GitHub Runners"** workflow from the left sidebar
3. Click **"Run workflow"** button
4. Configure deployment options:
   - **Min runners**: Minimum number of runners (default: 2)
   - **Max runners**: Maximum number of runners (default: 8)
   - **Runner image**: Docker image to use (default: `registry.digitalocean.com/redducklabs/github-runner:latest`)
   - **Namespace**: Kubernetes namespace (default: `arc-runners`)
5. Click **"Run workflow"** to start deployment

### Step 3: Monitor Deployment

The workflow will automatically:
- ✅ Validate your GitHub token
- ✅ Configure Kubernetes access
- ✅ Check node pool capacity against maxRunners
- ✅ Create the registry pull secret if missing
- ✅ Sync ARC CRDs and install/upgrade the ARC controller to the pinned chart (0.14.2)
- ✅ Deploy runners with your configuration
- ✅ Verify runner registration
- ✅ Provide usage instructions

### Step 4: Manage Runners

Use the GitHub Actions workflows to manage your runners:

- **Scale Runners**: Actions → "Scale GitHub Runners" → Run workflow
- **Check Status**: Actions → "Runner Status" → Run workflow
- **Emergency Stop**: Actions → "Emergency Stop Runners" → Run workflow
- **Build Runner Image**: Actions → "Build and Push Runner Image" → Run workflow (also runs automatically on pushes to `main` that change the Dockerfile or its build inputs)
- **Resize Node Pool**: Actions → "Node Pool Sizing" → Run workflow (dry run unless `apply` is checked; defaults 2/8 on `github-runners-pool-16g`). Required before raising maxRunners above the pool's `max_nodes`
- **Cluster Addons**: Actions → "Deploy Cluster Addons" → Run workflow (installs metrics-server, which `kubectl top` needs)
- **Prune Build Cache**: Actions → "Prune Build Cache" (runs weekly; manual runs are dry runs unless `dry_run` is unchecked)
- **Validate Config**: Actions → "Validate Config" (runs automatically on pull requests and pushes to `main` that touch `deploy/`, `scripts/`, `test/`, or `.github/`)

## 🛠️ Method 2: Local Deployment (Alternative)

If you prefer to deploy from your local machine:

### Prerequisites

1. **Install Required Tools**:
   ```bash
   # Install kubectl (matches the cluster version, 1.36.3)
   curl -LO "https://dl.k8s.io/release/v1.36.3/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   
   # Install Helm
   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   
   # Install doctl (for DigitalOcean)
   DOCTL_VERSION=1.167.0
   wget https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz
   tar xf doctl-${DOCTL_VERSION}-linux-amd64.tar.gz
   sudo mv doctl /usr/local/bin

   # Install jq (used by the scripts in scripts/ and test/)
   sudo apt-get install -y jq
   ```

2. **Create GitHub Token**:
   - Go to [GitHub Settings → Personal access tokens](https://github.com/settings/tokens/new)
   - Create token with scopes: `admin:org`, `repo`, `workflow`
   - Save the token:
     ```bash
     export GITHUB_TOKEN=ghp_your_token_here
     ```

### Kubernetes Cluster Access

1. **Authenticate with DigitalOcean**:
   ```bash
   doctl auth init
   ```

2. **Get cluster credentials**:
   ```bash
   # List available clusters
   doctl kubernetes cluster list
   
   # Get credentials for Red Duck Labs cluster.
   # NOTE: pass the cluster NAME (redducklabs-cluster), not the context name.
   # doctl creates/selects the context do-sfo3-redducklabs-cluster from it.
   doctl kubernetes cluster kubeconfig save redducklabs-cluster
   ```

3. **Verify access**:
   ```bash
   kubectl cluster-info
   kubectl get nodes
   ```

## 🏗️ Initial Setup

### 1. Clone Repository

```bash
git clone https://github.com/redducklabs/redducklabs-runners.git
cd redducklabs-runners
```

### 2. Environment Configuration

Create environment file:
```bash
cp .env.example .env
```

Only `GITHUB_TOKEN` (required) and `IMAGE_TAG` (optional, image build) are read, and only when exported:

```bash
set -a; source .env; set +a
```

Cluster context, namespace and release name are fixed in `deploy/deploy.sh`; scaling bounds come from `deploy/dind-values.yaml`.

### 3. Container Registry Setup

1. **Create registry pull secret**:
   ```bash
   kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
   
   doctl auth init   # with the DigitalOcean API token
   doctl registry kubernetes-manifest --name do-registry-secret --namespace arc-runners \
     | kubectl apply -f -
   ```

2. **Verify secret**:
   ```bash
   kubectl get secret do-registry-secret -n arc-runners
   ```

## 🚀 Deployment

### 1. Deploy ARC Controller (First Time Only)

```bash
# Install the controller (same chart version CI pins)
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.2 \
  --namespace arc-systems \
  --create-namespace

# Sync the CRDs. Helm installs a chart's crds/ only on first install and never
# updates them on upgrade, so apply them explicitly (server-side, because the
# CRDs exceed the client-side apply annotation size limit).
helm pull oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --version 0.14.2 --untar --untardir /tmp/arc
kubectl apply --server-side --force-conflicts -f /tmp/arc/gha-runner-scale-set-controller/crds
```

### 2. Build Custom Runner Image (Optional)

If you want to customize the runner image (edit `docker/Dockerfile.custom-runner` as needed first):

```bash
# Log in to the DigitalOcean registry, then build and push
doctl registry login
(cd docker && ./build-and-push.sh)
```

### 3. Deploy Runner Scale Set

```bash
# Deploy with production configuration
(cd deploy && ./deploy.sh)
```

Note: `deploy/deploy.sh` does not pass `--version`, so Helm uses the newest `gha-runner-scale-set` chart rather than the 0.14.2 that CI pins. Prefer the "Deploy GitHub Runners" workflow for production.

The deployment script will:
- Switch to the correct Kubernetes context
- Create the namespace if needed
- Deploy the runner scale set with your configuration
- Wait for deployment to complete
- Show initial status

### 4. Verify Deployment

```bash
# Check pod status
kubectl get pods -n arc-runners

# Check scale set
kubectl get autoscalingrunnersets -n arc-runners

# Check GitHub registration
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/orgs/redducklabs/actions/runners

# Run comprehensive test
./test/test-deployment.sh
```

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
maxRunners: 8

# NOTE: containerMode.type is deliberately NOT "dind" - see below.
template:
  spec:
    initContainers:
    - name: init-dind-externals
      # ... copies runner externals into a shared volume
    - name: dind                      # Docker daemon, as a native sidecar
      image: docker:29.7.2-dind
      restartPolicy: Always
      securityContext:
        privileged: true
      resources:                      # memory for everything run IN Docker
        requests:
          cpu: "1"
          memory: "5Gi"
        limits:
          memory: "10Gi"

    containers:
    - name: runner
      image: registry.digitalocean.com/redducklabs/github-runner:latest
      resources:                      # memory for work run ON the runner
        requests:
          cpu: "2"
          memory: "5Gi"
        limits:
          memory: "10Gi"              # no CPU limit: one pod per node
```

### Key Configuration Options

- **minRunners**: Always-on runners. One node per warm runner, billed
  continuously (recommendation: 2).
- **maxRunners**: Maximum concurrent runners. Must not exceed the node pool's
  `max_nodes`, or the surplus runners sit `Pending` forever.
- **runner resources**: Memory for work run *directly* on the runner (npm, jest,
  pytest, go build).
- **dind resources**: Memory for work run *inside Docker* (`docker build`,
  compose, testcontainers). These are separate budgets - an OOM names which
  container overran.
- **Image**: Custom runner image with pre-installed tools.
- **Pull Secrets**: For accessing private registries.

### Why the Docker sidecar is declared manually

ARC's built-in `containerMode.type: "dind"` renders the Docker daemon sidecar
from a hardcoded chart template with no `resources` field, and a user-supplied
container named `dind` is filtered out of values. That leaves dockerd with no
memory request and no memory limit, so every `docker build` competes for
whatever node memory happens to be unreserved - the cause of intermittent,
hard-to-attribute out-of-memory failures.

Declaring the sidecar explicitly (the chart's "default" container mode) is the
only way to give dockerd a memory reservation. The spec in
`deploy/dind-values.yaml` reproduces exactly what `containerMode: "dind"`
generated, plus resources and a pinned image.

**On chart upgrades, re-render and diff the pod spec**, because we now own
pieces the chart used to manage:

```bash
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 --kube-version 1.36.3 \
  -f deploy/dind-values.yaml
```

### Capacity model

One runner pod is scheduled per node: the pod requests 10Gi of memory
(runner 5Gi + dind 5Gi) against ~13.32Gi of node allocatable, so two pods cannot
share a node. Concurrency is therefore bounded by the node pool's `max_nodes` as
well as by `maxRunners`, and the two must be changed together.

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

## 🛠️ Management Setup

### 1. Management Scripts

All management scripts are in the `scripts/` directory:

```bash
# Make scripts executable (if not already)
chmod +x scripts/*.sh

# Add to PATH for easy access (optional)
export PATH=$PATH:$(pwd)/scripts
```

### 2. Monitoring Setup

Set up monitoring for your runners:

```bash
# Check status regularly
./scripts/scale-runners.sh status

# Set up automated monitoring (example cron job)
# Check runner health every 5 minutes
# */5 * * * * /path/to/redducklabs-runners/scripts/scale-runners.sh status > /tmp/runner-status.log
```

## 🔒 Security Setup

### 1. Network Policies (Recommended)

Create network policies to restrict runner communication:

```yaml
# network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: runner-network-policy
  namespace: arc-runners
spec:
  podSelector:
    matchLabels:
      actions.github.com/scale-set-name: redducklabs-runners
  policyTypes:
  - Ingress
  - Egress
  egress:
  - {} # Allow all egress (required for GitHub API)
  ingress: [] # No ingress required
```

```bash
kubectl apply -f network-policy.yaml
```

### 2. Service Account Setup (Optional)

Optional, and not deployed by this repository. A minimal service account for
runners can be created as below; it only takes effect if you also set
`template.spec.serviceAccountName: runner-service-account` in
`deploy/dind-values.yaml`.

```yaml
# service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: runner-service-account
  namespace: arc-runners
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: runner-role
  namespace: arc-runners
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: runner-role-binding
  namespace: arc-runners
subjects:
- kind: ServiceAccount
  name: runner-service-account
  namespace: arc-runners
roleRef:
  kind: Role
  name: runner-role
  apiGroup: rbac.authorization.k8s.io
```

### 3. Secret Management

- **Registry pull secret**: runner pods pull with `do-registry-secret`
  (`deploy/dind-values.yaml`), created in
  [Container Registry Setup](#3-container-registry-setup) or by the "Deploy
  GitHub Runners" workflow. No other registry secret is needed.
- **GitHub token**: never commit it. It reaches ARC through
  `--set githubConfigSecret.github_token=...` at deploy time
  (`deploy/deploy.sh` and the "Deploy GitHub Runners" workflow), and ARC stores
  it in a Kubernetes secret itself. No separate secret is needed.

## 🚨 Troubleshooting Setup

### Common Setup Issues

1. **Cluster Access Denied**
   ```bash
   # Re-authenticate with DigitalOcean
   doctl auth init
   # Pass the cluster NAME (not the context); doctl derives the
   # do-sfo3-redducklabs-cluster context from it.
   doctl kubernetes cluster kubeconfig save redducklabs-cluster
   ```

2. **Image Pull Errors**
   ```bash
   # Verify registry secret
   kubectl get secret do-registry-secret -n arc-runners
   
   # Test image pull
   kubectl run test-pod --image=registry.digitalocean.com/redducklabs/github-runner:latest --rm -it --restart=Never -n arc-runners
   ```

3. **GitHub Token Issues**
   ```bash
   # Test token scopes
   curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user
   curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/orgs/redducklabs/actions/runners
   ```

4. **Pod Startup Failures**
   ```bash
   # Check pod logs
   kubectl logs -n arc-runners <pod-name> -c runner
   
   # Check events
   kubectl get events -n arc-runners --sort-by='.lastTimestamp'
   ```

### Getting Help

1. Check the [troubleshooting section](../README.md#troubleshooting) in the main README
2. Review pod logs and events
3. Use the test scripts to identify issues
4. Check GitHub Actions Runner Controller documentation

## ✅ Setup Verification Checklist

- [ ] kubectl, helm, and jq are installed
- [ ] DigitalOcean CLI (doctl) is configured
- [ ] Kubernetes cluster access is working
- [ ] GitHub token is created with correct scopes
- [ ] Container registry access is configured
- [ ] ARC controller is deployed
- [ ] Runner scale set is deployed
- [ ] Runners appear in GitHub
- [ ] Test workflow runs successfully
- [ ] Management scripts work
- [ ] Monitoring is set up

Congratulations! Your Red Duck Labs GitHub Actions runners are now ready for use.