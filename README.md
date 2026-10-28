# Red Duck Labs GitHub Actions Self-Hosted Runners

Deploy secure, scalable GitHub Actions self-hosted runners on Kubernetes with comprehensive development tools for Red Duck Labs.

## Features

- **GitHub-first deployment**: Deploy, scale, monitor, and emergency-stop runners from GitHub Actions.
- **Complete Development Environment**: Python 3.13, Node.js 22, uv, AWS CLI v2, Terraform, kubectl, Helm, and more
- **Security Tools**: kubeconform 0.8.0, kubesec 2.14.2, Trivy 0.74.0
- **Docker-in-Docker Support**: Build containers within runners under one shared Pod scheduling budget
- **Burst autoscaling**: 2 warm runners on a two-node baseline and up to 20 runners on up to 8 autoscaled burst nodes; bounds change only by a reviewed commit to `deploy/dind-values.yaml`
- **CI-reviewed configuration**: Resource limits, health checks, and monitoring
- **Dual Configuration**: Template versions for reuse and reviewed Red Duck Labs target configs
- **Security optimized**: Multi-stage build with SHA256/GPG-verified tools and a machine-enforced CVE-floor gate

## Prerequisites

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
- **Kubernetes 1.36 or newer** - deployment preflight verifies both the API
  server and eligible runner nodes. The Docker-in-Docker daemon is a *native
  sidecar* (an init container with `restartPolicy: Always`), for which 1.29 is
  the underlying Kubernetes feature floor.
- DigitalOcean Container Registry (for custom images)
- Labeled and tainted runner node pools (`node-type=github-runner`,
  `workload-type=ci-cd`, taint `github-runner=true:NoSchedule`): a fixed
  two-node baseline plus two autoscaling burst pools, two runner pods per node -
  see [docs/runbooks/node-pool-sizing.md](docs/runbooks/node-pool-sizing.md)

## Quick Start - GitHub Actions Deployment

### 1. Setup Repository Secrets
1. Go to your repository's **Settings** → **Secrets and variables** → **Actions**
2. Add required secrets:
   - `RUNNER_TOKEN`: Your PAT with required scopes
   - `DO_TOKEN`: DigitalOcean API token

### 2. Prepare the Runner Platform
1. Select **"Prepare Runner Platform"** in the Actions tab
2. Supply the exact reviewed commit SHA and confirm the platform mutation
3. Run this workflow for initial setup or a deliberate ARC controller/CRD reconciliation

The normal deployment workflow requires the namespace, an explicitly named
`kubernetes.io/dockerconfigjson` pull secret with DigitalOcean registry auth,
all four pinned ARC CRDs, and the Ready pinned controller. The scale-set chart
owns its no-permission ServiceAccount; deploy accepts a pre-existing object
only when its Helm release and namespace ownership are exact.

Deploy only upgrades an existing `redducklabs-runners` release: the pool-state
gate requires exactly one deployed release of the pinned chart before any
operation is admitted. There is no first-install bootstrap. A fresh cluster
needs a separate, reviewed bootstrap procedure, which is out of scope of the
burst design (Ruling 15 in the burst autoscaling design record).

### 3. Deploy Runners via GitHub Actions
1. Go to the **Actions** tab in your repository
2. Select **"Deploy GitHub Runners"** workflow
3. Click **"Run workflow"**
4. Choose `operation=deploy`, supply the reviewed commit's `expected_sha`, and
   accept privileged runner co-tenancy. Runner bounds are not inputs: Deploy
   renders exactly the `burst` contract committed in `deploy/dind-values.yaml`
   (`minRunners: 2`, `maxRunners: 20`). The runner image is fixed to
   `registry.digitalocean.com/redducklabs/github-runner:latest`.
5. Click **"Run workflow"** to deploy

To change the bounds, merge a reviewed change to `deploy/dind-values.yaml`
and run Deploy again; only the canonical states in the burst design are
accepted. The rollout and rollback order (Node Pool Sizing, Deploy `drain`
and `rollback`, Emergency Stop recovery) is in
[docs/runbooks/node-pool-sizing.md](docs/runbooks/node-pool-sizing.md).

### 4. Monitor Deployment
The workflow validates tokens and permissions, configures Kubernetes access,
verifies the prepared platform, deploys the runner scale set, and verifies
runner registration with GitHub.

### 5. Use in Your Workflows

```yaml
jobs:
  build:
    runs-on: redducklabs-runners  # Red Duck Labs runner label
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on Red Duck Labs self-hosted runner!"
```

## Custom Runner Image

The included Dockerfile provides a comprehensive development environment optimized for Red Duck Labs workflows:

```bash
cd docker/

# Build and push (Red Duck Labs production)
./build-and-push.sh

# Or build manually
docker build -t registry.digitalocean.com/redducklabs/github-runner:latest -f Dockerfile.custom-runner .
docker push registry.digitalocean.com/redducklabs/github-runner:latest
```

## Included Tools

### Development Tools
- Python 3.13.15 with pip, black, flake8, mypy, ruff, pytest, pytest-mock
- Node.js 22.23.2 with npm, pnpm 11.5.0 (via corepack)
- uv 0.12.5 (Python package/installer manager)
- Go 1.27.0 runtime (for CI workflows that build Go)
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
- Terraform 1.15.9
- kubectl 1.36.3
- Helm 3.21.4
- doctl 1.167.0 (DigitalOcean CLI)
- AWS CLI v2 2.36.27 (GPG-verified, pinned signing key)
- Docker CLI v28.3.3+ with buildx 0.36.1 and Compose plugin (CVE-2025-54388)
- GitHub CLI

### Security & Validation
- kubeconform 0.8.0 - Kubernetes manifest validation
- kubesec 2.14.2 - Security risk analysis
- Trivy 0.74.0 - Vulnerability scanner
- Docker buildx 0.36.1

**Tool installation strategy**: kubectl, doctl, Trivy, and buildx are official
upstream **release binaries** verified against a pinned SHA256 before install
(this fixes the bogus `v0.0.0` / `0.0.0-dev` version strings the old source
builds produced). kubeconform and kubesec are **source-built** with Go 1.27.0 in
a throwaway builder stage because their upstream release binaries are built below
this image's CVE floor (and both are already at their latest release); kubesec's
`golang.org/x/crypto` is bumped (measured v0.55.0). Helm and Node install from
official release tarballs with pinned checksums (no `curl | bash`). AWS CLI v2 is
GPG-verified against a committed, fingerprint-pinned signing key. A clean Go
runtime stays for CI use.

**CVE floor (machine-enforced at build time and in CI** via
`test/verify-cve-floor.sh`**)**: every Go tool's toolchain ≥ Go 1.24.6
(CVE-2025-47907), Trivy's `hashicorp/go-getter` ≥ v1.7.9 (CVE-2025-8959), and
kubesec's `golang.org/x/crypto` ≥ v0.35.0 (CVE-2025-22869 / CVE-2024-45337).
Measured at adoption: kubectl go1.26.5, doctl go1.25.0, kubeconform go1.27.0,
kubesec go1.27.0 (x/crypto v0.55.0), trivy go1.26.6 (go-getter v1.8.6), buildx
go1.26.5. Trivy's full HIGH/CRITICAL scan runs **report-only** (SARIF to the
Security tab) because upstream release binaries and the dind base image carry
fixed CVEs we cannot remediate; the deterministic CVE-floor gate is the enforcing
check.

**PowerShell is intentionally excluded.** Consumers needing `run.ps1`-style
parity should use a Linux-equivalent shell script.

### Database Clients
- PostgreSQL client
- Redis tools

## Software Versions

These are the current pins in `docker/Dockerfile.custom-runner`.

| Tool | Version | Source / pin |
|------|---------|--------------|
| GitHub Actions Runner | 2.336.0 | official GitHub runner base image |
| Python | 3.13.15 (python-build-standalone rel 20260814) | tarball + SHA256 |
| Node.js | 22.23.2 | nodejs.org tarball + SHA256 |
| pnpm | 11.5.0 | corepack |
| uv | 0.12.5 | release tarball + SHA256 |
| Go (runtime) | 1.27.0 | go.dev tarball + SHA256 |
| Terraform | 1.15.9 | HashiCorp apt, keyring fingerprint + exact pin |
| kubectl | 1.36.3 | release binary + SHA256 |
| Helm | 3.21.4 | get.helm.sh tarball + SHA256 |
| doctl | 1.167.0 | release binary + SHA256 |
| AWS CLI | v2 2.36.27 | bundle + GPG (pinned key) |
| kubeconform | 0.8.0 | source-built (Go 1.27.0) |
| kubesec | 2.14.2 | source-built (Go 1.27.0, x/crypto v0.55.0) |
| Trivy | 0.74.0 | release tarball + SHA256 |
| buildx | 0.36.1 | release binary + SHA256 |
| Docker CLI / Compose | floating (>= 28.3.3 enforced) | Docker apt, keyring fingerprint |
| GitHub CLI | floating | GitHub apt, keyring fingerprint |

**Package pinning policy**: third-party apt repos (NodeSource was dropped;
HashiCorp, Docker, GitHub CLI) install via an explicit keyring whose full
fingerprint is asserted before use. The HashiCorp source and keyring are removed
after the exact Terraform package is installed so unrelated runtime apt updates
do not depend on future HashiCorp signing-key rotations. Node and Terraform are
exact-version sources (Node via nodejs.org tarball + SHA256; Terraform via apt
exact pin). Docker
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
**2027-07-01**. Expiry is enforced two ways: the Dockerfile checks it during the
AWS install layer, **and** `test/verify-aws-key-expiry.sh` runs on the host in CI
(cache-independent), so an expired key fails the build even if the Docker layer
cache would otherwise reuse the AWS layer. To rotate: replace
`docker/aws-cli-public.key` with the new key from the official AWS CLI install
guide and update the pinned fingerprint in the Dockerfile and in
`test/verify-aws-key-expiry.sh`. Locally, `--no-cache` (or bumping
`AWSCLI_VERSION`) forces the in-image check to re-run.

## Reviewed Target: Runner Capacity and Memory

This is the reviewed burst-autoscaling target
([design](docs/specs/2026-10-26-runner-burst-autoscaling-design.md)). It is
pending CI rollout and the acceptance phases A-E in
[the runbook](docs/runbooks/node-pool-sizing.md); repositories migrate only
after Phase E reports `READY_FOR_MIGRATION=true`.

| | Value |
|---|---|
| Concurrent self-hosted runners | **20** maximum, 2 warm (`minRunners: 2`, `maxRunners: 20`) |
| Pod scheduler request | **3 CPU and 5 GiB memory**, shared by the runner and DinD sidecar |
| Pod memory limit | **6 GiB shared** by the runner and privileged DinD sidecar |
| Baseline pool | `github-runners-pool-16g`: two `s-8vcpu-16gb` nodes (`min=max=count=2`), $192/month |
| Burst pools | `github-runners-burst-amd-16g` (`s-8vcpu-16gb-amd`, 0..6, priority 100) and `github-runners-burst-intel-16g` (`s-8vcpu-16gb-intel`, 0..2, priority 50); maxima sum to 8; $0.16667/node-hour each |
| Fleet cost ceiling | 10 runner nodes, **$1,088/month** only if every node ran all month |

On the measured 13.32 GiB / 7880m allocatable baseline node, two pods reserve
10 GiB and 6 CPU; a third does not fit. The burst sizes have the same
16 GiB / 8 vCPU shape; their allocatable is assumed equal until acceptance
Phases A and B measure it live.
The burst pools do not use the baseline's `s-8vcpu-16gb`: DigitalOcean refused
to create a pool of that size in `sfo3` for lack of regional capacity
(2026-10-28; spec "Burst pool sizes (Ruling 38)"). Warm runners prefer baseline; burst nodes exist only
while jobs need them. Runner pods carry
`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so a node running a
job is never scaled down, and **Rebalance Runners** retires idle runners left on
burst nodes so the pools return to zero.

The 6 GiB limit is one pod-wide budget, not independent container limits. An
`OOMKilled` status identifies where the kernel enforced that shared budget; it
does not establish which container consumed most of it. Review pod aggregate
use, both containers' use and restart counts, node headroom, and events.

The August one-pod-per-node design is historical and superseded by this shared
pod-budget design; see [the superseded design record](docs/specs/2026-08-19-runner-capacity-and-memory-design.md).

### Trust boundary and hosted-runner placement

Every self-hosted runner pod includes privileged DinD. Two jobs on one node
therefore share a kernel and increase the cross-job blast radius. The reviewed
target limits the fleet to the organization runner group
`redducklabs-private-runners`, with
`visibility=selected`, public access disabled, and exactly these private
repositories: `aurolegal.ai`, `autoduck`, `keel`, `manager`,
`platform-observability`, `redducklabs`, `redducklaw`, `superfood-shred`,
`therapy-link`, `zipbot-internal`, and `zipbot-v2`. Admission evidence for the
newest members is under `docs/security/runner-admission/`. CI fails closed if
any member's fork-PR workflow policy allows workflows from fork pull requests.

Before deployment, CI enumerates public organization repositories and fails if
any workflow job selects `redducklabs-runners`; public workflows use free
standard GitHub-hosted runners. CI also requires explicit acceptance of the
privileged co-tenancy risk, reconciles and reads back the runner-group policy,
and rejects repository-membership drift.

### Cost model

Measured demand (October 2026) was about 542 job-hours per week. The baseline
covers four concurrent jobs; the rest is about 240 burst node-hours per week
including boot and scale-down idle time, priced at the burst sizes'
$0.16667/node-hour (16.7% above the baseline size's $0.14286).

| Item | Monthly |
|---|---|
| Baseline nodes | $192 |
| Burst nodes (estimated) | ~$175 |
| Remaining GitHub-hosted (secret-handling jobs, Windows, deploys) | ~$25-40 |
| **Total** | **~$390-410**, against a ~$1,000/month hosted run rate |

Actual cost is measured from the DigitalOcean invoice with
`scripts/runner-cost-report.sh` (see [Runner Node Cost](#runner-node-cost)).

Deployment performs server-side dry-runs of both the rendered
`AutoscalingRunnerSet` and a representative Pod before Helm mutation. The
preflight rejects unsupported pod-level resources, admission drift, incompatible
Kubernetes versions, and insufficient per-node headroom. **Runner Status** also
reports sanitized provider-capacity diagnostics from the DOKS autoscaler when
their known format is available; otherwise it reports that diagnostics are
unavailable. See [node-pool sizing](docs/runbooks/node-pool-sizing.md).

### Acceptance

Live acceptance runs after the rollout steps, from reviewed commits only. The
probe `runner-burst-acceptance.yml` in private `redducklabs/aurolegal.ai` is
dispatched from a unique annotated tag on its reviewed commit and checks
`expected_workflow_sha`; **Runner Acceptance Evidence** in this repository
verifies the probe run's repository, workflow path, `headSha`, event, attempt
and tag before it reads the cluster, captures runner placement, node creation
times and events, and evaluates `scripts/acceptance-verdict.py`: phases A
(primary burst from zero), B (fallback from zero), C (idle retirement and return
to zero), D (drain under continuing load) and E (restore, ready for migration),
with warm pickup p95 <= 90 s and cold pickup p95 <= 8 minutes. A failure or
deadline cancels the probe and verifies that nothing of it is left running.

## GitHub Actions Management

Use GitHub Actions for normal runner fleet operations. Local scripts are
available for investigation and explicitly requested operations.

### Available Workflows

| Workflow | Description | Trigger |
|----------|-------------|---------|
| **Prepare Runner Platform** | Explicit initial namespace, CRD, controller, and registry preparation | Manual (`workflow_dispatch`) |
| **Deploy GitHub Runners** | CI-only trust preparation, deployment, and rollback | Manual (`workflow_dispatch`) |
| **Scale GitHub Runners** | `record-density` (read-only check of the committed density rollback target) and acceptance `acceptance-phase-c` | Manual (`workflow_dispatch`) |
| **Node Pool Sizing** | Burst pools: `create-burst`, `configure-expander`, `enable-burst`, `set-burst-maxima`, `remove-burst` | Manual (`workflow_dispatch`) |
| **Rebalance Runners** | Retires idle runners stranded on burst nodes | Hourly + manual |
| **Runner Acceptance Evidence** | Read-only acceptance controller for phases A-E; cancels only its verified probe | Manual (`workflow_dispatch`) |
| **Deploy Cluster Addons** | Deploy metrics-server (`kubectl top`) | Manual (`workflow_dispatch`) |
| **Runner Status** | Read-only pool-state admission, per-pool node counts and bounds, expander readback, runner health, registration, memory headroom, OOM kills | Manual + Daily at 9 AM UTC |
| **Emergency Stop Runners** | Emergency shutdown with recovery info | Manual (requires confirmation) |
| **Build Custom Runner Image** | Build and push Docker image | Push to Dockerfile or manual |

### CI-only runner changes

Runner-group preparation, runner deployment, node-pool changes, and rollback
run only through GitHub Actions with the reviewed commit supplied as
`expected_sha`. Deploy first runs `prepare-trust-boundary`, which performs the
read-only public-workflow checks and runner-group reconciliation without Helm,
Kubernetes, or DigitalOcean mutation. A deployment or rollback uses the same
recorded SHA. Recovery is Deploy `drain`, Node Pool Sizing `remove-burst`, then
Deploy `rollback`, which upgrades to the committed
`deploy/density-values.yaml` (validated as `density`, retaining the private
runner group; independent of Helm history). Scale Runners `record-density`
verifies that the live release equals that render before a rollout. Every Helm
write keeps 100 revisions (`--history-max 100`). Emergency Stop writes the
marker `arc-runners/runner-fleet-emergency-stop` before its Helm write; while it
exists the fleet workflows refuse to run, except Deploy `deploy`/`rollback`
with `acknowledge_emergency_stop=true`, and every fleet Helm write re-checks it
afterwards and re-applies the stop. The marker is also the parameter of the
server-side fence `deploy/runner-emergency-stop-fence.yaml` (a
ValidatingAdmissionPolicy installed by Deploy `deploy` and `rollback`): while
it exists the API server denies any runner scale set write that is not 0/0, so
a cancelled stale run cannot reopen the fleet. Emergency Stop proves the
denial before its own write and fails red if the fence does not enforce.
The workflows that mutate fleet capacity or its prerequisites (Deploy, Scale
Runners, Node Pool Sizing, Prepare Runner Platform, Deploy Cluster Addons)
share the non-cancelling `runner-fleet-mutation` concurrency group, so their
mutations do not overlap. Two documented exceptions use their own
non-cancelling groups: Emergency Stop (`runner-emergency-stop`) runs
immediately instead of waiting behind a drain or Phase C, and Rebalance
(`runner-rebalance`) skips with a notice while any fleet mutation is queued or
running.

### Monitoring via GitHub Actions

1. Go to **Actions** → **Runner Status**
2. Run workflow to get:
   - Current deployment configuration
   - Pod status and counts
   - GitHub registration status
   - Resource usage metrics

### Emergency Stop via GitHub Actions

1. Go to **Actions** → **Emergency Stop Runners**
2. Type `STOP-RUNNERS` to confirm
3. Workflow will:
   - Record the current configuration and Helm revision
   - Scale runners to zero (`minRunners=maxRunners=0`, same chart and template)
   - Read back the resulting `stopped` state (`burst-stopped`,
     `density-stopped` or `drain-stopped`) and print the recovery path that
     admits it

Emergency Stop does not wait for a running Deploy `drain` or Phase C; that run
fails closed at its next identity check. Recovery is described in
[docs/runbooks/node-pool-sizing.md](docs/runbooks/node-pool-sizing.md#emergency-stop).

## Local status

The local helper is read-only and accepts only `status`:

```bash
./scripts/scale-runners.sh status
```

## Testing

### Focused Checks

```bash
./test/verify-tools.sh
./test/test-deployment.sh
./test/verify-runner-resources.sh   # pod-level resources, two-pods-per-node, trust/preflight fixtures (no cluster needed)
./test/verify-cve-floor.sh <image>
./test/verify-aws-key-expiry.sh docker/aws-cli-public.key
./test/verify-docker-version.sh
./test/verify-go-runtime.sh
./test/verify-security-fixes.sh
```

## Security Best Practices

1. **Never commit secrets** - Use environment variables or Kubernetes secrets
2. **Token Management** - Rotate GitHub tokens regularly
3. **Registry Authentication** - Uses DigitalOcean registry pull secrets
4. **Resource Limits** - Always set CPU/memory limits
5. **Network Policies** - Runner pods are isolated by `deploy/runner-network-policy.yaml` (no ingress; egress only to cluster DNS and the public internet), installed by Deploy and validated by `scripts/verify-runner-network-policy.sh` (see `docs/SECURITY.md`)
6. **Emergency Stop fence** - `deploy/runner-emergency-stop-fence.yaml` (a ValidatingAdmissionPolicy and binding keyed on the stop marker) makes the API server enforce an Emergency Stop; installed by Deploy `deploy`/`rollback` and required by every other fleet mutator (see `docs/SECURITY.md`)
7. **RBAC** - Use minimal permissions for service accounts

### Security Documentation

| Document | Purpose |
|----------|---------|
| [Security Guide](docs/SECURITY.md) | Security practices, monitoring, and incident response |
| [Vulnerability Dismissals](docs/security/vulnerability-dismissals.md) | Risk acceptance for reviewed base-image vulnerabilities |
| [Security Validation Plan](docs/security/validation-plan.md) | Security validation commands and rollout checks |
| [Dockerfile Security Refactor](docs/toolchain/dockerfile-security-refactor.md) | Runner image supply-chain and multi-stage build design |
| [Go Runtime Notes](docs/toolchain/go-runtime.md) | Why the final image keeps a clean Go runtime |

### Security Fixes

**CVE-2025-54388 (MEDIUM)** - Fixed Docker firewalld vulnerability:
- **Issue**: Moby's firewalld reload makes container ports accessible by removing iptables rules
- **Impact**: Docker versions before 28.3.3 fail to recreate rules that block external access to containers
- **Fix**: Updated Docker CLI to v28.3.3+ from official Docker repository (was v27.5.1 from Ubuntu packages)
- **Components**: Docker CLI with buildx integration

**CVE-2025-47907 (HIGH)** - Go stdlib vulnerability (database/sql, Postgres):
- Enforced via the CVE-floor gate: every Go tool's toolchain must be ≥ Go 1.24.6.
- Measured: kubectl go1.26.5, doctl go1.25.0, kubeconform go1.27.0, kubesec
  go1.27.0, trivy go1.26.6, buildx go1.26.5 — all above the floor.

**CVE-2025-55199 & CVE-2025-55198 (MEDIUM)** - Fixed Helm vulnerabilities:
- **CVE-2025-55199**: Helm Chart JSON Schema Denial of Service vulnerability
- **CVE-2025-55198**: Helm YAML Parsing Panic vulnerability
- **Helm**: Updated to v3.21.4 (tarball + pinned SHA256).

**CVE-2025-8959** - go-getter vulnerability in Trivy:
- **Fix**: Trivy 0.74.0's release binary embeds `hashicorp/go-getter` v1.8.6
  (≥ v1.7.9). Verified by the CVE-floor gate; no source build needed.

**CVE-2025-22869 / CVE-2024-45337** - golang.org/x/crypto (SSH) in kubesec:
- **Fix**: kubesec is source-built with `x/crypto` bumped to v0.55.0
  (≥ v0.35.0). Verified by the CVE-floor gate.

The CVE-floor gate (`test/verify-cve-floor.sh`) enforces these specific CVE
fixes deterministically at build time and in CI. Trivy's broad HIGH/CRITICAL scan
is report-only (see "Included Tools").

## Troubleshooting

### Check Runner Status
```bash
./scripts/scale-runners.sh status
```

### Runner Node Cost
Cost is measured from the DigitalOcean invoice, not inferred. Run it with `doctl`
authenticated (read-only):

```bash
./scripts/runner-cost-report.sh --month 2026-09
```

DigitalOcean bills DOKS nodes as "Kubernetes Clusters" items aggregated per
cluster and node size, not per droplet or pool. For a completed month the report
therefore has per-cluster, per-size granularity: node-hours and USD for the
16 GB / 8 vCPU runner shape, the 8 GB / 4 vCPU worker size reported separately
as not runner cost, and the cluster's other items (volumes, load balancers).
The baseline (`s-8vcpu-16gb`), primary burst (`s-8vcpu-16gb-amd`) and fallback
burst (`s-8vcpu-16gb-intel`) sizes all have the 16 GB / 8 vCPU shape, and how
DigitalOcean words an AMD or Intel invoice line is not documented, so every
line of that shape is runner cost: a line that says AMD is shown as the primary
burst size, one that says Intel as the fallback burst size, and an unmarked
line as the baseline (plus burst nodes, if the invoice does not mark them).
Burst node-hours are derived as runner node-hours minus two baseline nodes for
every hour of the period (floor 0), and the burst cost is estimated at the
average runner price per node-hour, which understates it because the burst
sizes cost more than the baseline size (more so when the baseline reaches its
monthly price cap); marked AMD/Intel invoice lines show the measured burst cost.
The cluster defaults to `redducklabs-cluster`; use `--cluster-name` to override.
Deleted nodes are included because invoice items persist. DigitalOcean does not
itemize the month in progress, so for it the script prints the account-wide
month-to-date usage, labeled `ACCOUNT-WIDE`. Missing or unparseable invoice data,
or no runner-size line, prints `cost data unavailable` and never a zero. Runner
Status reports current node counts per pool, not node-hours.

### Verify GitHub Registration
```bash
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/orgs/redducklabs/actions/runners
```

### Diagnosing Out-Of-Memory Failures

The runner container and Docker daemon share the pod's 6 GiB memory limit. An
OOM kill names the killed container, not the component that consumed most of
the shared budget. Use **Runner Status** for aggregate pod and per-container
metrics, restart counts, node headroom, events, and sanitized provider-capacity
diagnostics.

```bash
Actions -> Runner Status -> Run workflow
```

### Common Issues

- **Pods stuck in Init**: Check image pull secrets and registry access
- **Runners not appearing**: Verify GitHub token has correct scopes
- **Build failures**: Ensure Docker-in-Docker is properly configured
- **Scaling issues**: Check AutoScalingRunnerSet status
- **Runners stuck `Pending`**: inspect **Runner Status** for the pool-state
  admission result, per-pool node counts and bounds, priority-expander drift,
  and provider-capacity diagnostics. Do not change the pool
  locally; use the CI gates documented in
  [docs/runbooks/node-pool-sizing.md](docs/runbooks/node-pool-sizing.md).
- **`kubectl top` says "Metrics API not available"**: run the
  **Deploy Cluster Addons** workflow to install metrics-server

## Security & Optimization

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
1. **Go Builder Stage**: source-builds kubeconform and kubesec with Go 1.27.0
   (their upstream release binaries are below the CVE floor).
2. **Python Builder Stage**: Installs Python development tools in isolation.
3. **Final Runtime Stage**: installs release binaries (kubectl, doctl, Trivy,
   buildx, Node, Helm, uv, AWS CLI) and copies the two source-built Go tools.

For detailed technical information, see
[docs/toolchain/dockerfile-security-refactor.md](docs/toolchain/dockerfile-security-refactor.md).

## Architecture

This solution uses GitHub's Actions Runner Controller (ARC) to dynamically provision runners:

1. **ARC Controller**: Manages runner lifecycle
2. **Runner Scale Set**: Auto-scales based on job queue
3. **Docker-in-Docker**: Enables container builds
4. **Custom Image**: Pre-installed development tools
5. **DigitalOcean Integration**: Registry and cluster integration

## Repository Structure

```
redducklabs-runners/
├── docker/                    # Docker configurations
│   ├── Dockerfile.custom-runner
│   ├── build-and-push.sh      # Production script
│   └── build-and-push.template.sh
├── deploy/                    # Deployment configurations
│   ├── deploy.sh              # Legacy local helper; CI is the production path
│   ├── deploy.template.sh
│   ├── dind-values.yaml       # Reviewed target values
│   └── dind-values.template.yaml
├── scripts/                   # Local operational helpers
│   ├── scale-runners.sh       # Status-only helper
│   ├── runner-admin.sh        # Legacy interactive helper
│   ├── emergency-stop.sh      # Legacy local helper
│   └── README.md
├── test/                      # Testing scripts
│   ├── verify-tools.sh        # Tool verification
│   ├── verify-cve-floor.sh    # Enforcing CVE-floor gate
│   ├── verify-aws-key-expiry.sh
│   └── test-deployment.sh     # Deployment testing
├── docs/
│   ├── SETUP.md               # Deployment setup guide
│   ├── SECURITY.md            # Security guide
│   ├── CONTRIBUTING.md
│   ├── security/              # Security runbooks and risk records
│   └── toolchain/             # Runner image implementation notes
├── .github/workflows/         # CI/CD workflows
└── README.md                  # This file
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](docs/CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Resources

- [Actions Runner Controller Documentation](https://github.com/actions/actions-runner-controller)
- [GitHub Actions Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [DigitalOcean Kubernetes](https://docs.digitalocean.com/products/kubernetes/)

## Reviewed Red Duck Labs Target Configuration

This repository records the reviewed target configuration, pending CI deployment
and external live acceptance:

- **Cluster**: `do-sfo3-redducklabs-cluster`
- **Registry**: `registry.digitalocean.com/redducklabs`
- **Namespace**: `arc-runners`
- **Runner Label**: `redducklabs-runners`
- **Scaling**: 2 warm runners, 20 maximum runners; two baseline nodes plus up to eight burst nodes

Template versions (`.template.*` files) are provided for reuse by other organizations.
