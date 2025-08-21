# Red Duck Labs GitHub Actions Self-Hosted Runners

Deploy secure, scalable GitHub Actions self-hosted runners on Kubernetes with comprehensive development tools for Red Duck Labs.

## 🚀 Features

- **GitHub-First Deployment**: Deploy and manage runners directly from GitHub Actions - no local setup required!
- **Complete Development Environment**: Python 3.13, Node.js 22, Terraform, kubectl, Helm, and more
- **Security Tools**: kubeconform 0.7.0, kubesec 2.14.2, Trivy 0.65.0
- **Docker-in-Docker Support**: Build containers within runners
- **Auto-scaling**: Configurable min/max runner instances (2-4 default, 4-8 maximum)
- **Production Ready**: Resource limits, health checks, and monitoring
- **GitHub Workflows**: Deploy, scale, monitor, and emergency stop - all from GitHub UI
- **Dual Configuration**: Template versions for reuse and production configs for Red Duck Labs

## 📋 Prerequisites

### Required GitHub Secrets
Configure these secrets in your repository settings (`Settings → Secrets and variables → Actions`):

1. **`RUNNER_TOKEN`** (Required)
   - Personal Access Token for runner registration
   - Required scopes: `admin:org`, `repo`, `workflow`
   - [Create token here](https://github.com/settings/tokens/new?scopes=admin:org,repo,workflow)

2. **`DO_TOKEN`** (Required for Red Duck Labs)
   - DigitalOcean API token for Kubernetes and registry access
   - [Create in DigitalOcean Control Panel](https://cloud.digitalocean.com/account/api/tokens)

### Infrastructure Requirements
- Kubernetes cluster (1.24+) - Red Duck Labs uses DigitalOcean
- DigitalOcean Container Registry (for custom images)

## 🎯 Quick Start - GitHub Actions Deployment (Recommended)

### 1. Setup Repository Secrets
1. Go to your repository's **Settings** → **Secrets and variables** → **Actions**
2. Add required secrets:
   - `RUNNER_TOKEN`: Your PAT with required scopes
   - `DO_TOKEN`: DigitalOcean API token

### 2. Deploy Runners via GitHub Actions
1. Go to the **Actions** tab in your repository
2. Select **"Deploy GitHub Runners"** workflow
3. Click **"Run workflow"**
4. Configure options (or use defaults):
   - Min runners: 2
   - Max runners: 4
   - Runner image: `registry.digitalocean.com/redducklabs/github-runner:latest`
5. Click **"Run workflow"** to deploy

### 3. Monitor Deployment
The workflow will:
- ✅ Validate tokens and permissions
- ✅ Configure Kubernetes access
- ✅ Install ARC controller if needed
- ✅ Deploy runners with your configuration
- ✅ Verify runner registration with GitHub

### 4. Use in Your Workflows

```yaml
jobs:
  build:
    runs-on: redducklabs-runners  # Red Duck Labs runner label
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on Red Duck Labs self-hosted runner!"
```

## 🐳 Custom Runner Image

The included Dockerfile provides a comprehensive development environment optimized for Red Duck Labs workflows:

```bash
cd docker/

# Build and push (Red Duck Labs production)
./build-and-push.sh

# Or build manually
docker build -t registry.digitalocean.com/redducklabs/github-runner:latest -f Dockerfile.custom-runner .
docker push registry.digitalocean.com/redducklabs/github-runner:latest
```

## 🔧 Included Tools

### Development Tools
- Python 3.13.6 with pip, black, flake8, mypy, ruff, pytest
- Node.js 22.x with npm 11.5.2, pnpm
- Git, curl, wget, jq, zip, unzip

### Infrastructure Tools
- Terraform 1.12.2
- kubectl 1.33.3
- Helm 3.18.6
- doctl 1.139.0 (DigitalOcean CLI)
- Docker CLI v28.3.3+ with buildx (Security Update - fixes CVE-2025-54388)
- GitHub CLI

### Security & Validation
- kubeconform 0.7.0 - Kubernetes manifest validation
- kubesec 2.14.2 - Security risk analysis (built with Go 1.24.6+)
- Trivy (source build) - Vulnerability scanner with go-getter v1.7.9 security fix
- Docker buildx - Latest version (built with Go 1.24.6+)

**Security Note**: All Go-based tools are compiled from source using Go 1.24.6 to address CVE-2025-47907 and related stdlib vulnerabilities.

### Database Clients
- PostgreSQL client
- Redis tools

## 🎮 GitHub Actions Management

All runner management can be done directly from GitHub Actions - no local access required!

### Available Workflows

| Workflow | Description | Trigger |
|----------|-------------|---------|
| **Deploy GitHub Runners** | Initial deployment or updates | Manual (`workflow_dispatch`) |
| **Scale GitHub Runners** | Scale up/down/custom | Manual (`workflow_dispatch`) |
| **Runner Status** | Check runner health and registration | Manual + Daily at 9 AM UTC |
| **Emergency Stop Runners** | Emergency shutdown with recovery info | Manual (requires confirmation) |
| **Build Custom Runner Image** | Build and push Docker image | Push to Dockerfile or manual |

### 📈 Scaling via GitHub Actions

1. Go to **Actions** → **Scale GitHub Runners**
2. Choose scaling action:
   - `status`: Check current configuration
   - `scale-up`: Scale to default (2-4 runners)
   - `scale-down`: Minimal configuration (0-1 runners)
   - `scale-max`: Maximum capacity (4-8 runners)
   - `scale-custom`: Custom min/max values

### 📊 Monitoring via GitHub Actions

1. Go to **Actions** → **Runner Status**
2. Run workflow to get:
   - Current deployment configuration
   - Pod status and counts
   - GitHub registration status
   - Resource usage metrics

### 🛑 Emergency Stop via GitHub Actions

1. Go to **Actions** → **Emergency Stop Runners**
2. Type `STOP-RUNNERS` to confirm
3. Workflow will:
   - Save current configuration
   - Scale runners to zero
   - Provide recovery instructions

## 📊 Local Management (Alternative)

If you prefer command-line management:

### Quick Scaling

```bash
cd scripts/

# Check current status
./scale-runners.sh status

# Scale to default (2-4 runners)
./scale-runners.sh up

# Scale to maximum (4-8 runners)
./scale-runners.sh max

# Scale to zero for maintenance
./scale-runners.sh down

# Custom scaling
./scale-runners.sh scale 3 6
```

### Interactive Administration

```bash
# Run interactive admin menu
./scripts/runner-admin.sh
```

### Emergency Stop

```bash
# Emergency shutdown (requires typing 'STOP')
./scripts/emergency-stop.sh
```

## 🧪 Testing

### Verify Tools Installation

```bash
# Test all tools in a running pod
./test/verify-tools.sh
```

### Test Deployment

```bash
# Comprehensive deployment test
./test/test-deployment.sh
```

## 🔒 Security Best Practices

1. **Never commit secrets** - Use environment variables or Kubernetes secrets
2. **Token Management** - Rotate GitHub tokens regularly
3. **Registry Authentication** - Uses DigitalOcean registry pull secrets
4. **Resource Limits** - Always set CPU/memory limits
5. **Network Policies** - Implement Kubernetes network policies (recommended)
6. **RBAC** - Use minimal permissions for service accounts

### 🛡️ Security Fixes

**CVE-2025-54388 (MEDIUM)** - Fixed Docker firewalld vulnerability:
- **Issue**: Moby's firewalld reload makes container ports accessible by removing iptables rules
- **Impact**: Docker versions before 28.3.3 fail to recreate rules that block external access to containers
- **Fix**: Updated Docker CLI to v28.3.3+ from official Docker repository (was v27.5.1 from Ubuntu packages)
- **Components**: Docker CLI with buildx integration

**CVE-2025-47907 (HIGH)** - Fixed Go stdlib vulnerabilities in database/sql Postgres operations:
- **Trivy**: Built from source with Go 1.24.6+ (was stdlib v1.24.4)
- **kubesec**: Built from source with Go 1.24.6+ (was stdlib v1.23.1)  
- **docker-buildx**: Built from source with Go 1.24.6+ (was stdlib v1.24.5)

**CVE-2025-55199 & CVE-2025-55198 (MEDIUM)** - Fixed Helm vulnerabilities:
- **CVE-2025-55199**: Helm Chart JSON Schema Denial of Service vulnerability
- **CVE-2025-55198**: Helm YAML Parsing Panic vulnerability
- **Helm**: Updated to v3.18.6 (from v3.18.4) to address memory exhaustion and panic issues

**CVE-2025-8959 (TBD)** - Fixed go-getter vulnerability in Trivy:
- **Issue**: go-getter v1.7.8 contains security vulnerability CVE-2025-8959
- **Impact**: Security vulnerability in HashiCorp's go-getter library used by Trivy
- **Fix**: Build Trivy from source using PR #9361 branch with go-getter v1.7.9 update
- **Status**: Temporary source build until official Trivy release includes the fix
- **Components**: Trivy vulnerability scanner

All Go-based security tools now use the latest Go compiler to ensure no vulnerable stdlib versions are present.

## 🐛 Troubleshooting

### Check Runner Status
```bash
./scripts/scale-runners.sh status
kubectl get pods -n arc-runners
kubectl logs -n arc-runners <pod-name> -c runner
```

### Verify GitHub Registration
```bash
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/orgs/redducklabs/actions/runners
```

### Common Issues

- **Pods stuck in Init**: Check image pull secrets and registry access
- **Runners not appearing**: Verify GitHub token has correct scopes
- **Build failures**: Ensure Docker-in-Docker is properly configured
- **Scaling issues**: Check AutoScalingRunnerSet status

## 📚 Architecture

This solution uses GitHub's Actions Runner Controller (ARC) to dynamically provision runners:

1. **ARC Controller**: Manages runner lifecycle
2. **Runner Scale Set**: Auto-scales based on job queue
3. **Docker-in-Docker**: Enables container builds
4. **Custom Image**: Pre-installed development tools
5. **DigitalOcean Integration**: Registry and cluster integration

## 📁 Repository Structure

```
redducklabs-runners/
├── docker/                    # Docker configurations
│   ├── Dockerfile.custom-runner
│   ├── build-and-push.sh      # Production script
│   └── build-and-push.template.sh
├── deploy/                    # Deployment configurations
│   ├── deploy.sh              # Production script
│   ├── deploy.template.sh
│   ├── dind-values.yaml       # Production values
│   └── dind-values.template.yaml
├── scripts/                   # Management scripts
│   ├── scale-runners.sh       # Main scaling script
│   ├── runner-admin.sh        # Interactive admin
│   ├── emergency-stop.sh      # Emergency shutdown
│   └── README.md
├── test/                      # Testing scripts
│   ├── verify-tools.sh        # Tool verification
│   └── test-deployment.sh     # Deployment testing
├── docs/                      # Additional documentation
├── .github/workflows/         # CI/CD workflows
└── README.md                  # This file
```

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](docs/CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Resources

- [Actions Runner Controller Documentation](https://github.com/actions/actions-runner-controller)
- [GitHub Actions Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [DigitalOcean Kubernetes](https://docs.digitalocean.com/products/kubernetes/)

## ⚠️ Red Duck Labs Configuration

This repository is configured for Red Duck Labs production environment:

- **Cluster**: `do-sfo3-redducklabs-cluster`
- **Registry**: `registry.digitalocean.com/redducklabs`
- **Namespace**: `arc-runners`
- **Runner Label**: `redducklabs-runners`
- **Scaling**: 2-4 runners (default), 4-8 runners (maximum)

Template versions (`.template.*` files) are provided for reuse by other organizations.