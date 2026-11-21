# Test Scripts

This directory contains scripts for testing and verifying the Red Duck Labs GitHub Actions runners.

Most scripts are committed without the executable bit (only
`verify-aws-key-expiry.sh` and `verify-cve-floor.sh` have it), so on Linux/macOS
run them with `bash <path>` (for example `bash test/verify-tools.sh`) or
`chmod +x` them first.

## Available Tests

### Runner pod checks (need cluster access and deployed runners)

### `verify-tools.sh`
Comprehensive verification of all tools installed in the runner image.

**Usage:**
```bash
./test/verify-tools.sh
```

**What it tests** (runs each command in the first runner pod via `kubectl exec`):
- Programming languages (Python 3.13, Node.js 22)
- Package managers (npm, pnpm, uv)
- Infrastructure tools (Terraform, kubectl, Helm, doctl, AWS CLI)
- Security tools (Trivy, kubesec, kubeconform)
- Development tools (Git, Docker CLI, Docker Compose, GitHub CLI, curl, jq, bc)
- Database clients (PostgreSQL, Redis)
- Python packages (black, flake8, mypy, ruff, pytest, pytest-mock, requests, boto3, yaml)
- WeasyPrint native libraries (pango, pangoft2, harfbuzz, fontconfig, cairo, ffi)
- Chromium runtime libraries used by Playwright (libnss3, libatk, libcups, libgbm, libasound, libX*, and others)

### `verify-security-fixes.sh`
Security-focused verification of Trivy in a runner pod.

**Usage:**
```bash
./test/verify-security-fixes.sh
```

**What it tests:**
- Trivy is present and runs (`trivy --version`, reported under CVE-2025-8959)
- Trivy functionality (a sample scan of `alpine:latest`)
- Report-only HIGH/CRITICAL scan of the runner pod's image

The go-getter >= v1.7.9 fix for CVE-2025-8959 is enforced by `verify-cve-floor.sh`,
not by this script.

### `test-deployment.sh`
Tests the deployment process and runner functionality.

**Usage:**
```bash
./test/test-deployment.sh
```

**What it tests:**
- kubectl, helm and cluster access
- `arc-runners` namespace and `redducklabs-runners` helm release status
- AutoscalingRunnerSet scaling (warns if `minRunners` < 2)
- Runner pod status, and `python3` / `kubectl` inside a running runner
- GitHub registration (needs `GITHUB_TOKEN`)
- Runner image and image pull secret

### Image checks (need Docker, no cluster)

### `verify-cve-floor.sh`
Machine-enforced CVE floor gate, run inside the image.

**Usage:**
```bash
./test/verify-cve-floor.sh <image-ref>
```

**What it tests** (fails closed):
- Every Go toolchain in kubectl, doctl, kubeconform, kubesec, trivy and docker-buildx is >= Go 1.24.6 (CVE-2025-47907)
- Trivy's `hashicorp/go-getter` is >= v1.7.9 (CVE-2025-8959)
- kubesec's `golang.org/x/crypto` is >= v0.35.0 (CVE-2025-22869 / CVE-2024-45337)

### `verify-go-runtime.sh`
Verifies the clean Go runtime in the image. Expects a local image tagged
`redducklabs/custom-runner:latest`, and asserts an exact Go version that must
match `GO_VERSION` in `docker/Dockerfile.custom-runner`.

**Usage:**
```bash
./test/verify-go-runtime.sh
```

**What it tests:**
- `go` on PATH and the exact Go version
- `GOROOT=/usr/local/go` and `GOPATH=/home/runner/go`
- `go run` of a small program
- `/home/runner/go` is writable by the `runner` user
- `go mod init`
- No `testdata`, `*_test.go`, `*.pem` or `*.key` files under `/usr/local/go`

### `verify-docker-version.sh`
Docker CLI checks for CVE-2025-54388. Runs against the `docker` on the current
PATH (for example inside a runner), not via `kubectl`.

**Usage:**
```bash
./test/verify-docker-version.sh
```

**What it tests:**
- Docker CLI >= 28.3.3
- `docker buildx` plugin is installed
- Docker CLI comes from the `docker-ce-cli` package (not Ubuntu's `docker.io`)
- Docker CLI responds to `docker version`

### Repository checks (no cluster, no image)

### `verify-aws-key-expiry.sh`
Host-side check of the committed AWS CLI signing key, independent of the Docker
layer cache. Requires `gpg`.

**Usage:**
```bash
./test/verify-aws-key-expiry.sh [path-to-key]   # default: docker/aws-cli-public.key
```

**What it tests:**
- Key fingerprint is `FB5DB77FD5C118B80511ADA8A6310ACC4672475C`
- Key has an expiry date and has not expired

### `verify-runner-resources.sh`
Renders `deploy/dind-values.yaml` with Helm and asserts the runner pod's memory
invariants. Needs `helm`, `jq` and network access to the chart registry; does
not need cluster access. `CHART_VERSION` (default `0.14.2`) and `KUBE_VERSION`
(default `1.36.3`) can be overridden via the environment.

**Usage:**
```bash
./test/verify-runner-resources.sh
```

**What it tests:**
- `containerMode.type` is not `dind` (which would drop the dind resources block)
- dind and runner containers both have memory requests and limits
- dind runs as a native sidecar (`restartPolicy: Always`)
- dind image is pinned (not a floating tag)
- runner has `DOCKER_HOST` set
- Memory requests allow exactly one runner pod per node and fit the node budget
- Prints the `minRunners`/`maxRunners` bounds the node pool must allow (informational, not asserted)

## Prerequisites

The runner pod checks (`verify-tools.sh`, `verify-security-fixes.sh`,
`test-deployment.sh`) need the following. The other scripts list their own
requirements above.

1. **Kubernetes cluster access:**
   ```bash
   kubectl config current-context
   kubectl get pods -n arc-runners
   ```

2. **Runners are deployed:**
   ```bash
   kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners
   ```

3. **Required tools on local machine:**
   - kubectl
   - helm (for `test-deployment.sh`)
   - jq (for JSON parsing)

## Running All Tests

To run a complete verification:

```bash
# Test tools and functionality
./test/verify-tools.sh

# Test security fixes
./test/verify-security-fixes.sh

# Test deployment (if needed)
./test/test-deployment.sh

# Image checks
./test/verify-cve-floor.sh <image-ref>
./test/verify-go-runtime.sh

# Repository checks
./test/verify-aws-key-expiry.sh
./test/verify-runner-resources.sh
```

## Test Output

All tests use color-coded output:
- 🟢 **Green**: Test passed
- 🔴 **Red**: Test failed
- 🔵 **Blue**: Test description/info
- 🟡 **Yellow**: Warning/note

## Troubleshooting

### No runner pods found
```bash
# Check if runners are deployed
kubectl get pods -n arc-runners

# Check runner scale set
kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners

# If no pods exist, deploy runners first
cd deploy && ./deploy.sh
```

### Tool version mismatches
`verify-tools.sh` labels show the pinned versions but only check that each command runs. `verify-go-runtime.sh` asserts an exact Go version and must be updated when `GO_VERSION` changes in the Dockerfile.

### Security test failures
If security tests fail:
1. Check that the container image was built with the latest Dockerfile
2. Verify the image includes the security fixes
3. Rebuild and redeploy if necessary

## Adding New Tests

To add new tool verification:

1. Add to `verify-tools.sh`:
   ```bash
   test_tool "Tool Name Version" "command --version"
   ```

2. For security fixes, add to `verify-security-fixes.sh`:
   ```bash
   test_security_fix "CVE-ID" "Description" "test_command" "expected_result"
   ```

## Integration with CI/CD

These scripts run in CI:

- `.github/workflows/build-runner-image.yml`: `bash test/verify-aws-key-expiry.sh docker/aws-cli-public.key` and `bash test/verify-cve-floor.sh <image>` (PR image and main image)
- `.github/workflows/validate-config.yml`: `./test/verify-runner-resources.sh`

The Docker CLI >= 28.3.3 floor and the tool smoke checks run inline in
`build-runner-image.yml`, not through `verify-docker-version.sh` or
`verify-tools.sh`. `verify-tools.sh`, `verify-security-fixes.sh`,
`test-deployment.sh` and `verify-go-runtime.sh` are not run in CI.

For more information, see the main [SECURITY.md](../docs/SECURITY.md) documentation.
