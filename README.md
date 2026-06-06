# Red Duck Labs GitHub Actions Self-Hosted Runners

Deploy secure, scalable GitHub Actions self-hosted runners on Kubernetes with comprehensive development tools for Red Duck Labs.

## 🚀 Features

- **GitHub-First Deployment**: Deploy and manage runners directly from GitHub Actions - no local setup required!
- **Complete Development Environment**: Python 3.13, Node.js 22, uv, AWS CLI v2, Terraform, kubectl, Helm, and more
- **Security Tools**: kubeconform 0.7.0, kubesec 2.14.2, Trivy 0.70.0
- **Docker-in-Docker Support**: Build containers within runners
- **Auto-scaling**: Configurable min/max runner instances (2-4 default, 4-8 maximum)
- **Production Ready**: Resource limits, health checks, and monitoring
- **GitHub Workflows**: Deploy, scale, monitor, and emergency stop - all from GitHub UI
- **Dual Configuration**: Template versions for reuse and production configs for Red Duck Labs
- **🛡️ Security Optimized**: Multi-stage build with SHA256/GPG-verified tools and a machine-enforced CVE-floor gate

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
- Python 3.13.13 with pip, black, flake8, mypy, ruff, pytest, pytest-mock
- Node.js 22.22.3 with npm, pnpm 11.5.0 (via corepack)
- uv 0.11.17 (Python package/installer manager)
- Go 1.26.3 runtime (for CI workflows that build Go)
- Git, curl, wget, jq, zip, unzip, bc, libmagic1
- WeasyPrint native libs (libpango, libpangoft2, libharfbuzz, libfontconfig,
  libcairo2, libffi8) so consumer CI jobs that `import weasyprint` (PDF
  rendering) can load them via ctypes
- Playwright Chromium system libraries (libnss3, libnspr4, libatk*, libcups,
  libgbm, libasound, libxkbcommon, the libX* set, …) installed via Playwright
  `install-deps` so consumer E2E jobs can `playwright install chromium`
  (without `--with-deps`) and launch headless Chromium — the non-root,
  no-new-privileges runner pod cannot `sudo apt-get` them at job time. The
  browser binary itself is downloaded per-run by the consumer, matching its own
  `@playwright/test` version.

### Infrastructure Tools
- Terraform 1.15.5
- kubectl 1.36.1
- Helm 3.21.0
- doctl 1.160.0 (DigitalOcean CLI)
- AWS CLI v2 2.34.57 (GPG-verified, pinned signing key)
- Docker CLI v28.3.3+ with buildx 0.34.1 and Compose plugin (CVE-2025-54388)
- GitHub CLI

### Security & Validation
- kubeconform 0.7.0 - Kubernetes manifest validation
- kubesec 2.14.2 - Security risk analysis
- Trivy 0.70.0 - Vulnerability scanner
- Docker buildx 0.34.1

**Tool installation strategy**: kubectl, doctl, Trivy, and buildx are official
upstream **release binaries** verified against a pinned SHA256 before install
(this fixes the bogus `v0.0.0` / `0.0.0-dev` version strings the old source
builds produced). kubeconform and kubesec are **source-built** with Go 1.26.3 in
a throwaway builder stage because their upstream release binaries are built below
this image's CVE floor (and both are already at their latest release); kubesec's
`golang.org/x/crypto` is bumped (measured v0.52.0). Helm and Node install from
official release tarballs with pinned checksums (no `curl | bash`). AWS CLI v2 is
GPG-verified against a committed, fingerprint-pinned signing key. A clean Go
runtime stays for CI use.

**CVE floor (machine-enforced at build time and in CI** via
`test/verify-cve-floor.sh`**)**: every Go tool's toolchain ≥ Go 1.24.6
(CVE-2025-47907), Trivy's `hashicorp/go-getter` ≥ v1.7.9 (CVE-2025-8959), and
kubesec's `golang.org/x/crypto` ≥ v0.35.0 (CVE-2025-22869 / CVE-2024-45337).
Measured at adoption: kubectl go1.26.2, doctl go1.25.0, kubeconform go1.26.3,
kubesec go1.26.3 (x/crypto v0.52.0), trivy go1.25.9 (go-getter v1.8.6), buildx
go1.26.3. Trivy's full HIGH/CRITICAL scan runs **report-only** (SARIF to the
Security tab) because upstream release binaries and the dind base image carry
fixed CVEs we cannot remediate; the deterministic CVE-floor gate is the enforcing
check.

**PowerShell is intentionally excluded.** Consumers needing `run.ps1`-style
parity should use a Linux-equivalent shell script.

### Database Clients
- PostgreSQL client
- Redis tools

## 📦 Software Versions

**Last version check: 2026-05-31.**

| Tool | Version | Source / pin |
|------|---------|--------------|
| Python | 3.13.13 (python-build-standalone rel 20260510) | tarball + SHA256 |
| Node.js | 22.22.3 | nodejs.org tarball + SHA256 |
| pnpm | 11.5.0 | corepack |
| uv | 0.11.17 | release tarball + SHA256 |
| Go (runtime) | 1.26.3 | go.dev tarball + SHA256 |
| Terraform | 1.15.5 | HashiCorp apt, keyring fingerprint + exact pin |
| kubectl | 1.36.1 | release binary + SHA256 |
| Helm | 3.21.0 | get.helm.sh tarball + SHA256 |
| doctl | 1.160.0 | release binary + SHA256 |
| AWS CLI | v2 2.34.57 | bundle + GPG (pinned key) |
| kubeconform | 0.7.0 | source-built (Go 1.26.3) |
| kubesec | 2.14.2 | source-built (Go 1.26.3, x/crypto v0.52.0) |
| Trivy | 0.70.0 | release tarball + SHA256 |
| buildx | 0.34.1 | release binary + SHA256 |
| Docker CLI / Compose | floating (>= 28.3.3 enforced) | Docker apt, keyring fingerprint |
| GitHub CLI | floating | GitHub apt, keyring fingerprint |

**Package pinning policy**: third-party apt repos (NodeSource was dropped;
HashiCorp, Docker, GitHub CLI) install via an explicit keyring whose full
fingerprint is asserted before use. Node and Terraform are exact-version sources
(Node via nodejs.org tarball + SHA256; Terraform via apt exact pin). Docker
CLI/Compose-plugin and GitHub CLI **float** (key-verified; Docker CLI has a smoke
floor of 28.3.3). Ubuntu-archive packages (`postgresql-client`, `redis-tools`,
`bc`, `libmagic1`, `gettext-base`, `libpq-dev`, the WeasyPrint native libs
`libpango-1.0-0`/`libpangoft2-1.0-0`/`libharfbuzz0b`/`libfontconfig1`/`libcairo2`/`libffi8`,
the Playwright Chromium libs resolved by `playwright@${PLAYWRIGHT_VERSION}
install-deps chromium`, base runtime deps) float as distro-managed. The
Playwright CLI used to resolve that apt list is version-pinned (`PLAYWRIGHT_VERSION`,
tracking the consumer's `@playwright/test` minor) but not SHA-pinned, like the
`pnpm`/`pip` package installs. Everything else is pinned + checksum/GPG-verified.

**AWS CLI signing key rotation**: the AWS CLI v2 signing key (fingerprint
`A6310ACC4672475C`, full `FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C`) is
committed at `docker/aws-cli-public.key` and its documented expiry is
**2026-07-07**. Expiry is enforced two ways: the Dockerfile checks it during the
AWS install layer, **and** `test/verify-aws-key-expiry.sh` runs on the host in CI
(cache-independent), so an expired key fails the build even if the Docker layer
cache would otherwise reuse the AWS layer. To rotate: replace
`docker/aws-cli-public.key` with the new key from the official AWS CLI install
guide and update the pinned fingerprint in the Dockerfile and in
`test/verify-aws-key-expiry.sh`. Locally, `--no-cache` (or bumping
`AWSCLI_VERSION`) forces the in-image check to re-run.

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

### 📄 Security Documentation

- **[Security Guide](docs/SECURITY.md)** - Comprehensive security practices, monitoring, and incident response
- **[Security Dismissals](SECURITY-DISMISSALS.md)** - Risk assessment for accepted base image vulnerabilities
- **[Security Validation Plan](SECURITY-VALIDATION-PLAN.md)** - Testing procedures for security controls

### 🛡️ Security Fixes

**CVE-2025-54388 (MEDIUM)** - Fixed Docker firewalld vulnerability:
- **Issue**: Moby's firewalld reload makes container ports accessible by removing iptables rules
- **Impact**: Docker versions before 28.3.3 fail to recreate rules that block external access to containers
- **Fix**: Updated Docker CLI to v28.3.3+ from official Docker repository (was v27.5.1 from Ubuntu packages)
- **Components**: Docker CLI with buildx integration

**CVE-2025-47907 (HIGH)** - Go stdlib vulnerability (database/sql, Postgres):
- Enforced via the CVE-floor gate: every Go tool's toolchain must be ≥ Go 1.24.6.
- Measured: kubectl go1.26.2, doctl go1.25.0, kubeconform go1.26.3, kubesec
  go1.26.3, trivy go1.25.9, buildx go1.26.3 — all above the floor.

**CVE-2025-55199 & CVE-2025-55198 (MEDIUM)** - Fixed Helm vulnerabilities:
- **CVE-2025-55199**: Helm Chart JSON Schema Denial of Service vulnerability
- **CVE-2025-55198**: Helm YAML Parsing Panic vulnerability
- **Helm**: Updated to v3.21.0 (tarball + pinned SHA256).

**CVE-2025-8959** - go-getter vulnerability in Trivy:
- **Fix**: Trivy 0.70.0's release binary embeds `hashicorp/go-getter` v1.8.6
  (≥ v1.7.9). Verified by the CVE-floor gate; no source build needed.

**CVE-2025-22869 / CVE-2024-45337** - golang.org/x/crypto (SSH) in kubesec:
- **Fix**: kubesec is source-built with `x/crypto` bumped to v0.52.0
  (≥ v0.35.0). Verified by the CVE-floor gate.

The CVE-floor gate (`test/verify-cve-floor.sh`) enforces these specific CVE
fixes deterministically at build time and in CI. Trivy's broad HIGH/CRITICAL scan
is report-only (see "Included Tools").

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

## 🛡️ Security & Optimization

### Multi-Stage Docker Build

The runner image uses a comprehensive multi-stage build process to eliminate security false positives and optimize size:

**Security Improvements:**
- **Verified supply chain**: release binaries are SHA256-pinned; apt third-party
  repos use keyrings with asserted fingerprints; AWS CLI is GPG-verified.
- **Clean Final Image**: the Go builder is a throwaway stage; its module cache and
  source trees never reach the final image.
- **CVE-floor gate**: Go toolchains, go-getter, and x/crypto are enforced at build
  time and in CI (`test/verify-cve-floor.sh`).

**Build Stages:**
1. **Go Builder Stage**: source-builds kubeconform and kubesec with Go 1.26.3
   (their upstream release binaries are below the CVE floor).
2. **Python Builder Stage**: Installs Python development tools in isolation.
3. **Final Runtime Stage**: installs release binaries (kubectl, doctl, Trivy,
   buildx, Node, Helm, uv, AWS CLI) and copies the two source-built Go tools.

For detailed technical information, see [docs/DOCKERFILE-SECURITY-REFACTOR.md](docs/DOCKERFILE-SECURITY-REFACTOR.md).

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