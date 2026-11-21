# Test Scripts

This directory contains scripts for testing and verifying the Red Duck Labs GitHub Actions runners.

There are three kinds:

- **Offline suites** need no cluster, DigitalOcean or GitHub access and run in CI
  on every relevant pull request.
- **Image checks** run against a locally built or pushed image with Docker.
- **Live checks** `kubectl exec` into a running runner pod in `arc-runners`
  and are run by hand.

Run them from the repository root. Several are committed without the
executable bit (`git ls-files -s test`); run those with `bash test/<name>.sh`.

## What runs in CI

| Script | Workflow | When |
|--------|----------|------|
| `verify-runner-resources.sh` | Validate Config | PRs and pushes to `main` touching `deploy/`, `scripts/`, `test/`, `.github/workflows/` or `.github/actions/` |
| `verify-runner-version-guard.sh` | Validate Config | same |
| `verify-burst-autoscaling.sh` | Validate Config | same |
| `verify-acceptance.sh` | Validate Config | same |
| `verify-aws-key-expiry.sh docker/aws-cli-public.key` | Build and Push Runner Image | PR (validate) and `main` (publish) builds |
| `verify-cve-floor.sh <image>` | Build and Push Runner Image | against the PR image (`rdl-runner:pr`) and against the pushed image on `main` |

Validate Config also runs `bash -n` and `shellcheck -S error` on every
`test/*.sh`. `verify-tools.sh`, `verify-security-fixes.sh`,
`verify-docker-version.sh`, `verify-go-runtime.sh` and `test-deployment.sh`
are not run by any workflow; the image build's smoke test covers similar
ground for the image itself.

## Offline suites

### `verify-runner-resources.sh`
Renders `deploy/dind-values.yaml` with Helm (ARC chart pinned in the script's
`CHART_VERSION`) and asserts the runner pod's memory reservations, the
two-runner-pods-per-node invariant and other rollout safety boundaries, plus the
GitHub-hosted runner policy for workflows.

**Usage:**
```bash
./test/verify-runner-resources.sh
```

Needs `helm`, `jq`, `python` (the script checks for `python`, not `python3`)
with PyYAML, and network access to the chart registry. No cluster access.

### `verify-burst-autoscaling.sh`
Offline contract suite for the burst-autoscaling change: the ARC contracts
(burst, burst-acceptance, drain, density, stopped), the pool-state gate, the
fleet scripts and the fleet workflows. `doctl`, `kubectl`, `helm` and `gh` are
replaced by fakes that serve canned files from `test/fixtures/`.

**Usage:**
```bash
./test/verify-burst-autoscaling.sh
```

Needs `bash`, `python3` with PyYAML and `jq`.

### `verify-acceptance.sh`
Offline verification of the acceptance tooling: `scripts/acceptance-verdict.py`
against `test/fixtures/acceptance/` (`expected.json` names each fixture's
verdict), static contracts of `runner-acceptance-evidence.yml` and the Phase C
evidence upload in `scale-runners.yml`, and the evidence workflow run end to end
through `test/lib/actions_runner.py` with simulated CLIs from
`test/fixtures/acceptance-sim`.

**Usage:**
```bash
./test/verify-acceptance.sh
```

`verify-burst-autoscaling.sh` and `verify-acceptance.sh` refuse to run under Git
Bash/MSYS/Cygwin (exit 2): there, Python's subprocess would skip the fakes and
call the real CLIs with your credentials. On Windows, run them in WSL against
an LF clone, as described in the repository `CLAUDE.md`.

### `verify-runner-version-guard.sh`
Tests `scripts/check-runner-version.py` (`check` and `apply`) on temporary
trees and checks the Runner Version Guard workflow contract. Needs `python3`
only.

**Usage:**
```bash
./test/verify-runner-version-guard.sh
```

### `verify-aws-key-expiry.sh`
Checks the committed AWS CLI signing key: pinned fingerprint and an expiry
date in the future. CI runs it on the host so the check does not depend on a
cached Docker layer. Needs `gpg`.

**Usage:**
```bash
./test/verify-aws-key-expiry.sh [path-to-key]   # default docker/aws-cli-public.key
```

## Image checks

### `verify-cve-floor.sh`
The enforcing CVE-floor gate. Runs `go version -m` inside the image on kubectl,
doctl, kubeconform, kubesec, trivy and docker-buildx and fails if any Go
toolchain is below Go 1.24.6 (CVE-2025-47907), Trivy's `hashicorp/go-getter`
is below v1.7.9 (CVE-2025-8959), or kubesec's `golang.org/x/crypto` is below
v0.35.0 (CVE-2025-22869 / CVE-2024-45337).

**Usage:**
```bash
./test/verify-cve-floor.sh <image-ref>
```

Needs Docker and the image.

### `verify-go-runtime.sh`
Checks the clean Go runtime in the image: `go` on `PATH`, the Go version,
`GOROOT=/usr/local/go`, `GOPATH=/home/runner/go`, `go run` of a small program,
a writable `/home/runner/go` for the `runner` user, `go mod init`, and that
`/usr/local/go` holds no `testdata`, `*_test.go`, `*.pem` or `*.key` files.

**Usage:**
```bash
cd docker && docker build -t redducklabs/custom-runner:latest -f Dockerfile.custom-runner . && cd ..
bash test/verify-go-runtime.sh
```

It runs a container from the local tag `redducklabs/custom-runner:latest`,
which no build script produces, so tag the image yourself as above. (Its error
message suggests `docker/build-and-push.sh`, which builds a different tag and
pushes it to the production registry; don't use it for this.) The expected Go
version is a literal in the script: compare it with `ARG GO_VERSION` in
`docker/Dockerfile.custom-runner` before trusting a result.

### `verify-docker-version.sh`
Checks the Docker CLI in the environment it runs in: version 28.3.3 or later
(CVE-2025-54388), `docker-buildx` installed and working as a plugin, the CLI
coming from the `docker-ce-cli` package, and `docker version` working. Run it
inside the runner image or a runner pod, not on your workstation.

**Usage:**
```bash
bash test/verify-docker-version.sh
```

## Live checks (running runner pod)

These pick the first pod labelled
`actions.github.com/scale-set-name=redducklabs-runners` in `arc-runners` and
`kubectl exec` into its `runner` container. They use your current kube context.

### `verify-tools.sh`
Verification of the tools installed in the runner image.

**Usage:**
```bash
bash test/verify-tools.sh
```

**What it tests:**
- Programming languages (Python 3.13, Node.js 22)
- Package managers (npm, pnpm, uv)
- Infrastructure tools (Terraform, kubectl, Helm, doctl, AWS CLI), and that
  Terraform's HashiCorp apt source and keyring were removed
- Security tools (Trivy, kubesec, kubeconform)
- Development tools (Git, Docker CLI, Docker Compose, GitHub CLI, curl, jq, bc)
- Database clients (PostgreSQL, Redis)
- Python packages (black, flake8, mypy, ruff, pytest, pytest-mock, requests, boto3, yaml)
- WeasyPrint and Playwright Chromium native libraries (loaded with `ctypes`)
- zstd, and the shared tool cache (burst/drain pods): writable in the runner,
  and writable from a non-root container started through dind
  (`docker run --user 1001:121 -v "$RUNNER_TOOL_CACHE:/__t" busybox:1.37 ...`).
  The second check starts a throwaway container in the inspected pod's dind
  daemon. Run it only when a live check is explicitly wanted. Density pods
  have no shared tool cache, so both tool-cache checks fail there.

Each check passes when its command succeeds. The versions in the check names
are labels: the script prints the reported version but does not compare it.
It stops at the first failing check.

#### Post-merge live check: non-root container-job tool cache

After the tool-cache change is deployed (burst contract), run a job like this
from a private repository whose workflows already use the fleet. It checks the
tool cache from both a runner step and a non-root job container, and it
exercises an uncached `setup-node`:

```yaml
jobs:
  tool-cache-probe:
    runs-on: redducklabs-runners
    steps:
      - run: test "$RUNNER_TOOL_CACHE" = /opt/hostedtoolcache && touch "$RUNNER_TOOL_CACHE/probe"
      - uses: actions/setup-python@v7
        with:
          python-version: '3.12'
      - run: python -c "import ssl, sys; print(sys.prefix)"
  container-tool-cache-probe:
    runs-on: redducklabs-runners
    container:
      image: node:22-bookworm
      options: --user 1001:121
    steps:
      - run: touch "$RUNNER_TOOL_CACHE/probe" && ls -ld "$RUNNER_TOOL_CACHE"
      - uses: actions/setup-node@v7
        with:
          node-version: '20'
      - run: node --version
```

Expected: both jobs pass. `sys.prefix` is under `/opt/hostedtoolcache/Python/`.
In the container job, `RUNNER_TOOL_CACHE` is `/__t` and is writable by uid 1001.

### `verify-security-fixes.sh`
Live security checks in a runner pod.

**Usage:**
```bash
bash test/verify-security-fixes.sh
```

**What it tests:**
- That `trivy --version` runs (labelled CVE-2025-8959; the go-getter version
  itself is enforced by `verify-cve-floor.sh`, not here)
- Trivy functionality: a scan of `alpine:latest` (needs registry access from the pod)
- A HIGH/CRITICAL Trivy scan of the pod's own image (report-only)

### `test-deployment.sh`
Tests the deployment and runner functionality.

**Usage:**
```bash
bash test/test-deployment.sh
```

**What it tests:**
- `kubectl`, `helm` and cluster connectivity
- The `arc-runners` namespace and the `redducklabs-runners` Helm release
- The AutoscalingRunnerSet exists and `minRunners` is at least 2
- Runner pod states, and Python and kubectl in a running pod
- GitHub registration of `redducklabs-runners*` runners (only with `GITHUB_TOKEN` set)
- The runner image and image pull secrets, and `kubectl top` usage

## Prerequisites

Live checks need:

1. **Kubernetes cluster access:**
   ```bash
   kubectl config use-context do-sfo3-redducklabs-cluster
   kubectl config current-context
   kubectl get pods -n arc-runners
   ```

2. **Runners are deployed:**
   ```bash
   kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners
   ```

3. **Required tools on local machine:**
   - kubectl
   - jq (for JSON parsing)
   - helm (`test-deployment.sh`)

## Running All Tests

```bash
# Offline suites (no cluster access)
./test/verify-runner-resources.sh
./test/verify-runner-version-guard.sh
./test/verify-burst-autoscaling.sh
./test/verify-acceptance.sh
./test/verify-aws-key-expiry.sh

# Image check
./test/verify-cve-floor.sh <image-ref>

# Live checks against a running runner pod
bash test/verify-tools.sh
bash test/verify-security-fixes.sh
bash test/test-deployment.sh
```

## Test Output

Most tests use color-coded output:
- 🟢 **Green**: Test passed
- 🔴 **Red**: Test failed
- 🔵 **Blue**: Test description/info
- 🟡 **Yellow**: Warning/note

`verify-runner-version-guard.sh`, `verify-cve-floor.sh` and
`verify-aws-key-expiry.sh` print plain `PASS:`/`OK`/`FAIL:` lines. The offline
suites count failures and exit non-zero if there are any.

## Troubleshooting

### No runner pods found
```bash
# Check if runners are deployed
kubectl get pods -n arc-runners

# Check runner scale set
kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners
```

If no pods exist, check whether the fleet is stopped (an Emergency Stop marker
`arc-runners/runner-fleet-emergency-stop`) and deploy through the **Deploy
GitHub Runners** workflow; see `docs/runbooks/node-pool-sizing.md`.

### Tool version mismatches
`verify-tools.sh` does not compare versions. `verify-go-runtime.sh` hardcodes
its expected Go version; if you've updated the Dockerfile with newer versions,
update that script too. The image build's smoke test compares kubectl and
doctl with the Dockerfile ARGs.

### Security test failures
If security tests fail:
1. Check that the container image was built with the latest Dockerfile
2. Run `./test/verify-cve-floor.sh <image-ref>` against that image
3. Rebuild and redeploy through the workflows if necessary

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

3. For checks that must gate CI, add them to an offline suite or to
   `verify-cve-floor.sh`, which the workflows run.

For more information, see the main [SECURITY.md](../docs/SECURITY.md) documentation.
