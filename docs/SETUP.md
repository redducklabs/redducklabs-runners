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
- ✅ Install Actions Runner Controller if needed
- ✅ Deploy runners with your configuration
- ✅ Verify runner registration
- ✅ Provide usage instructions

### Step 4: Manage Runners

Use the GitHub Actions workflows to manage your runners:

- **Scale Runners**: Actions → "Scale GitHub Runners" → Run workflow
- **Check Status**: Actions → "Runner Status" → Run workflow
- **Emergency Stop**: Actions → "Emergency Stop Runners" → Run workflow

## 🛠️ Method 2: Local Deployment (Alternative)

If you prefer to deploy from your local machine:

### Prerequisites

1. **Install Required Tools**:
   ```bash
   # Install kubectl
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   
   # Install Helm
   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   
   # Install doctl (for DigitalOcean)
   wget https://github.com/digitalocean/doctl/releases/latest/download/doctl-*-linux-amd64.tar.gz
   tar xf doctl-*-linux-amd64.tar.gz
   sudo mv doctl /usr/local/bin
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

Edit `.env` with your settings:
```bash
# GitHub Configuration
GITHUB_TOKEN=ghp_your_token_here
GITHUB_ORG=redducklabs

# Kubernetes Configuration
CLUSTER_CONTEXT=do-sfo3-redducklabs-cluster
NAMESPACE=arc-runners

# Registry Configuration (Red Duck Labs)
REGISTRY_URL=registry.digitalocean.com
REGISTRY_NAMESPACE=redducklabs

# Runner Configuration
RELEASE_NAME=redducklabs-runners
RUNNER_SCALE_SET_NAME=redducklabs-runners
MIN_RUNNERS=2
MAX_RUNNERS=8
```

### 3. Container Registry Setup

1. **Create registry pull secret**:
   ```bash
   kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
   
   kubectl create secret docker-registry do-registry-secret \
     --docker-server=registry.digitalocean.com \
     --docker-username=your-do-token \
     --docker-password=your-do-token \
     --namespace=arc-runners
   ```

2. **Verify secret**:
   ```bash
   kubectl get secret do-registry-secret -n arc-runners
   ```

## 🚀 Deployment

### 1. Deploy ARC Controller (First Time Only)

```bash
# Add the ARC Helm repository
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller

# Install the controller
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-systems \
  --create-namespace
```

### 2. Build Custom Runner Image (Optional)

If you want to customize the runner image:

```bash
cd docker/

# Edit Dockerfile.custom-runner as needed
# Then build and push
./build-and-push.sh
```

### 3. Deploy Runner Scale Set

```bash
cd deploy/

# Deploy with production configuration
./deploy.sh
```

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
  --version <version> --kube-version <cluster-version> \
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

### 2. Service Account Setup

Create a minimal service account for runners:

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
  resources: ["pods", "secrets"]
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

Store sensitive values in Kubernetes secrets:

```bash
# Create secret for registry access
kubectl create secret docker-registry registry-secret \
  --docker-server=registry.digitalocean.com \
  --docker-username=$DO_REGISTRY_TOKEN \
  --docker-password=$DO_REGISTRY_TOKEN \
  -n arc-runners

# Create secret for additional configuration
kubectl create secret generic runner-config \
  --from-literal=github-token=$GITHUB_TOKEN \
  -n arc-runners
```

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
   kubectl get secret do-registry-secret -n arc-runners -o yaml
   
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

1. Check the [troubleshooting section](README.md#troubleshooting) in the main README
2. Review pod logs and events
3. Use the test scripts to identify issues
4. Check GitHub Actions Runner Controller documentation

## ✅ Setup Verification Checklist

- [ ] kubectl and helm are installed
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