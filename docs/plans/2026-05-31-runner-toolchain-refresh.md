# Runner Toolchain Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the custom GitHub Actions runner image to current, pinned,
verified tool versions; replace Go source-builds with official release binaries;
add uv/AWS CLI/bc/libmagic1/pytest-mock; fix CRLF durably; and enforce issue #12
acceptance on the PR build.

**Architecture:** Single-stage-plus-python-builder Dockerfile. The Go builder
stage is deleted; kubectl/doctl/kubeconform/kubesec/trivy/buildx install from
official prebuilt linux/amd64 binaries with SHA256 verification. AWS CLI v2 uses
GPG verification with a pinned, expiry-enforced key. Node/Terraform use exact apt
pins; Docker CLI/gh and a closed list of Ubuntu-archive packages float by policy.
A clean Go 1.26.3 runtime stays for CI workflows.

**Tech Stack:** Docker (multi-stage), Bash, GitHub Actions, Trivy, Python
(python-build-standalone), Node (NodeSource), apt (HashiCorp/Docker/GitHub
keyrings).

**Spec:** `docs/specs/2026-05-31-runner-toolchain-refresh-design.md`

**Branch:** `refresh/runner-toolchain-issue-12` (already created).

**Verification environment:** Docker is available locally (29.5.x). Build and
smoke-test locally before opening the PR. AuroLegal build validation is local
only and recorded in the PR (CI cannot reach `defender.ai`).

---

## Implementation deviations (recorded 2026-06-01, during execution)

Three build-driven deviations from the tasks below were made and approved during
execution; the spec (§4.1, §4.6, §4.7) was updated to match:

1. **Node installs from the nodejs.org tarball, not NodeSource apt** (Task 7
   Step 1). NodeSource's `node_22.x` apt channel is stale at 22.15.0 and cannot
   deliver 22.22.3. Node 22.22.3 is installed from the official release tarball
   with a pinned SHA256 (`c7a10d6816da8eaaa7534dd73c71c6e2b2c391dbbf845e364902d156615dd1b8`),
   consistent with the other release-binary tools. The NodeSource keyring
   fingerprint assertion is replaced by the pinned tarball checksum.
2. **kubeconform and kubesec are source-built, not release binaries** (Tasks 2,
   3). The CVE-floor gate (Task 9) caught their upstream release binaries below
   the floor (kubeconform Go 1.24.2; kubesec Go 1.23.1 + x/crypto v0.29.0); both
   are at their latest release. A minimal `go-builder` stage compiles just these
   two with Go 1.26.3 (kubesec's x/crypto bumped to v0.52.0). kubectl, doctl,
   trivy, buildx remain verified release binaries.
3. **Trivy runs report-only; the CVE-floor gate is the enforcing CI gate**
   (Task 12). An enforcing HIGH/CRITICAL Trivy gate is not satisfiable (upstream
   Go binaries and the dind base image carry fixed CVEs we cannot remediate). The
   §4.7 floor check is extracted to `test/verify-cve-floor.sh` and run as a
   build-failing step on both the PR-loaded and pushed images; Trivy uploads SARIF
   for visibility only (`exit-code: 0`).

---

## Verified facts (do not re-derive; confirmed 2026-05-31)

Pinned versions and SHA256 (linux/amd64):

| Tool | Version | SHA256 |
|------|---------|--------|
| Go | 1.26.3 | `2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556` |
| kubectl | v1.36.1 | `629d3f410e09bf49b64ae7079f7f0bda1191efed311f7d37fdbab0ad5b0ec2b7` |
| doctl | v1.160.0 | `b0a23eb02a213e6418e6d5b7dcd5207b6b70a5a5b15e8fcaadc0b8715ac0a735` (tar `doctl-1.160.0-linux-amd64.tar.gz`) |
| Helm | v3.21.0 | `0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36` (`helm-v3.21.0-linux-amd64.tar.gz`) |
| kubeconform | v0.7.0 | `c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3` (`kubeconform-linux-amd64.tar.gz`) |
| kubesec | v2.14.2 | `bc252e35f01bc4f133a49404315da3ccfed0209cc9baba33883eaeca0656f35c` (`kubesec_linux_amd64.tar.gz`) |
| Trivy | v0.70.0 | `8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9` (`trivy_0.70.0_Linux-64bit.tar.gz`) |
| buildx | v0.34.1 | `f1332ddb9010bd0b72628266c3a906d9a6979848033df4c8d9bd2cd113bae12b` (`buildx-v0.34.1.linux-amd64`) |
| uv | 0.11.17 | `0017ccecaeb4d431d7f93b583ebff0c5c38e00eb734fcf13d05f72ca419125fe` (`uv-x86_64-unknown-linux-gnu.tar.gz`) |
| Python (PBS) | 3.13.13 / rel 20260510 | `928d08ecda5bbf4d8851c5872e363dd9c9be938fdb90f525b6f36a8c90ff8407` (`cpython-3.13.13+20260510-x86_64-unknown-linux-gnu-install_only.tar.gz`) |

apt exact pins (confirm exact strings with `apt-cache madison` at build time):
- Node: `nodejs=22.22.3-1nodesource1` (NodeSource setup_22.x)
- Terraform: `terraform=1.15.5-1` (HashiCorp apt)

apt floating (policy, §4.9): `docker-ce-cli`, `docker-compose-plugin`, `gh`
(third-party, fingerprint-verified, with smoke floor); `postgresql-client`,
`redis-tools`, `bc`, `libmagic1`, `gettext-base`, `libpq-dev` + base runtime deps
(Ubuntu archive).

AWS CLI v2:
- Bundle: `https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.34.57.zip`
- Sig: same URL + `.sig`
- Key full fingerprint: `FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C`
  (Key ID `A6310ACC4672475C`), documented expiry 2026-07-07.

---

## File Structure

- **Modify** `docker/Dockerfile.custom-runner` — remove go-builder stage; install
  release binaries; add uv/aws/bc/libmagic1; exact-pin Node/Terraform; pin
  Python release; add pytest-mock to python-builder.
- **Create** `docker/aws-cli-public.key` — committed AWS CLI v2 ASCII-armored
  signing key (verified at implementation time).
- **Modify** `.trivyignore` — remove go-builder/`/go/pkg/mod` entries; reconsider
  `/usr/local/go/**`; keep only documented ignores.
- **Create** `.gitattributes` — LF enforcement + binary list (§4.12).
- **Modify** `.github/workflows/build-runner-image.yml` — single-job PR
  build+smoke+Trivy with `load:true`; gate registry login/secrets/permissions
  away from PRs; drop Go-absent checks; extend smoke list.
- **Modify** `test/verify-tools.sh` — version expectations + uv/aws/bc.
- **Modify** `test/verify-go-runtime.sh` — Go 1.26.3.
- **Modify** `test/verify-docker-version.sh` — unchanged floor (28.3.3) but verify
  still correct.
- **Modify** `test/verify-security-fixes.sh` — align CVE narrative to measured.
- **Modify** `README.md` — tool list/versions, strategy, floating policy, AWS key
  rotation, pwsh exclusion, last-checked date.
- **Modify** `docs/DOCKERFILE-SECURITY-REFACTOR.md`, `docs/GO-RUNTIME-FIX.md` —
  release-binary strategy + measured CVE claims.

Each task below is committed independently. Commit messages use the repo's
conventional prefixes.

---

## Task 1: Add `.gitattributes` and renormalize line endings

**Files:**
- Create: `.gitattributes`
- Renormalize: all tracked text files (blobs already LF; this guards future)

- [ ] **Step 1: Create `.gitattributes`**

```
* text=auto eol=lf
*.sh   text eol=lf
*.bash text eol=lf
*.yml  text eol=lf
*.yaml text eol=lf
# binaries / fixtures — never normalize
*.png  binary
*.jpg  binary
*.jpeg binary
*.ico  binary
*.pdf  binary
*.gz   binary
*.tgz  binary
*.tar  binary
*.zip  binary
*.pem  binary
*.crt  binary
*.key  binary
# The AWS CLI public signing key is ASCII-armored text; keep it LF, not binary.
docker/aws-cli-public.key text eol=lf
```

- [ ] **Step 2: Renormalize**

Run:
```bash
git add .gitattributes
git add --renormalize .
```

- [ ] **Step 3: Verify all scripts/workflows are LF in the index**

Run:
```bash
git ls-files --eol test/*.sh scripts/*.sh docker/*.sh deploy/*.sh .github/workflows/*.yml docker/aws-cli-public.key 2>/dev/null | grep -v 'i/lf' || echo "ALL LF OK"
```
Expected: `ALL LF OK` (no non-LF lines). Note: `docker/aws-cli-public.key` does
not exist yet (Task 5) — that's fine here.

- [ ] **Step 4: Verify no binary/cert fixture got normalized**

Run:
```bash
git diff --cached --stat
```
Expected: only `.gitattributes` added and (if any) CRLF→LF normalization of text
files. No content change to any `*.png/*.zip/*.pem/*.crt/*.key`.

- [ ] **Step 5: Syntax-check all shell scripts post-normalization**

Run:
```bash
for f in test/*.sh scripts/*.sh docker/*.sh deploy/*.sh; do bash -n "$f" && echo "OK $f" || echo "FAIL $f"; done
```
Expected: every line `OK …`, no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git commit -m "chore: add .gitattributes to enforce LF on scripts and workflows"
```

---

## Task 2: Drop the Go builder stage and bump the Go runtime to 1.26.3

This task removes the entire `go-builder` stage and the Stage-2 numbering, and
bumps the clean Go runtime. The release binaries that replace the builder outputs
are added in Tasks 3–4. **After this task the image will not yet have
kubectl/doctl/kubeconform/kubesec — that is expected; Tasks 3–4 add them before
any build is attempted. Do not build between Task 2 and Task 4.**

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Update the ARG block at the top of the Dockerfile**

Replace the existing top ARG block (lines ~1–23) with:

```dockerfile
# Multi-stage build: python-builder + final runtime. Go tools install as
# official release binaries (no source build). See
# docs/specs/2026-05-31-runner-toolchain-refresh-design.md.
ARG GO_VERSION=1.26.3
ARG GO_SHA256=2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556
ARG TRIVY_VERSION=v0.70.0
ARG TRIVY_SHA256=8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9
ARG KUBECTL_VERSION=v1.36.1
ARG KUBECTL_SHA256=629d3f410e09bf49b64ae7079f7f0bda1191efed311f7d37fdbab0ad5b0ec2b7
ARG DOCTL_VERSION=v1.160.0
ARG DOCTL_SHA256=b0a23eb02a213e6418e6d5b7dcd5207b6b70a5a5b15e8fcaadc0b8715ac0a735
ARG KUBECONFORM_VERSION=v0.7.0
ARG KUBECONFORM_SHA256=c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3
ARG KUBESEC_VERSION=v2.14.2
ARG KUBESEC_SHA256=bc252e35f01bc4f133a49404315da3ccfed0209cc9baba33883eaeca0656f35c
ARG HELM_VERSION=v3.21.0
ARG HELM_SHA256=0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36
ARG TERRAFORM_VERSION=1.15.5-1
ARG BUILDX_VERSION=v0.34.1
ARG BUILDX_SHA256=f1332ddb9010bd0b72628266c3a906d9a6979848033df4c8d9bd2cd113bae12b
ARG UV_VERSION=0.11.17
ARG UV_SHA256=0017ccecaeb4d431d7f93b583ebff0c5c38e00eb734fcf13d05f72ca419125fe
ARG AWSCLI_VERSION=2.34.57
ARG PYTHON_VERSION=3.13
ARG PYTHON_BUILD_RELEASE=20260510
ARG PYTHON_FULL_VERSION=3.13.13
ARG PYTHON_TARBALL_SHA256=928d08ecda5bbf4d8851c5872e363dd9c9be938fdb90f525b6f36a8c90ff8407
ARG NODE_VERSION=22.x
ARG NODE_PKG_VERSION=22.22.3-1nodesource1
ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:2.334.0
```

- [ ] **Step 2: Delete the entire `go-builder` stage**

Remove everything from `# Stage 1: Go builder` (the `FROM golang:${GO_VERSION}-alpine AS go-builder` line) through the end of that stage's final `RUN … echo "Go tools build completed successfully"` block — i.e. the whole stage that clones and builds kubectl/doctl/kubeconform/kubesec. The next stage (`python-builder`) becomes Stage 1.

- [ ] **Step 3: Renumber stage comments**

Change `# Stage 2: Python builder` to `# Stage 1: Python builder` and
`# Stage 3: Final image` to `# Stage 2: Final image`.

- [ ] **Step 4: Remove the `COPY --from=go-builder` line and its chmod**

Delete:
```dockerfile
COPY --from=go-builder /tmp/binaries/* /usr/local/bin/
RUN chmod +x /usr/local/bin/kubectl /usr/local/bin/doctl /usr/local/bin/kubeconform /usr/local/bin/kubesec
```
(Replacements are added in Tasks 3–4.)

- [ ] **Step 5: Add GO_SHA256 verification to the Go runtime install**

Find the "Install clean Go runtime" RUN block and replace it with:

```dockerfile
# Install clean Go runtime for CI workflows (no module cache or test fixtures)
RUN set -eux && \
    GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz" && \
    cd /tmp && \
    wget -q "https://go.dev/dl/${GO_TARBALL}" && \
    echo "${GO_SHA256}  ${GO_TARBALL}" | sha256sum -c - && \
    tar -C /usr/local -xzf "${GO_TARBALL}" && \
    rm -f "${GO_TARBALL}" && \
    /usr/local/go/bin/go version
```

Also re-declare the new ARGs needed in the final stage. In the final stage's
`ARG` re-declaration block (after `FROM ${ACTIONS_RUNNER_BASE}`), ensure these
are present: `GO_VERSION GO_SHA256 TRIVY_VERSION TRIVY_SHA256 KUBECTL_VERSION
KUBECTL_SHA256 DOCTL_VERSION DOCTL_SHA256 KUBECONFORM_VERSION KUBECONFORM_SHA256
KUBESEC_VERSION KUBESEC_SHA256 PYTHON_VERSION NODE_VERSION NODE_PKG_VERSION
HELM_VERSION HELM_SHA256 TERRAFORM_VERSION BUILDX_VERSION BUILDX_SHA256
UV_VERSION UV_SHA256 AWSCLI_VERSION`.

- [ ] **Step 6: Sanity-check the Dockerfile parses (no build yet)**

Run:
```bash
docker build --check -f docker/Dockerfile.custom-runner ./docker 2>&1 | head -30 || true
```
Expected: no syntax/parse errors reported by `--check` (warnings about missing
binaries are fine; we have not added Tasks 3–4 yet). Do not run a full build.

- [ ] **Step 7: Commit**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "refactor: drop Go builder stage; bump Go runtime to 1.26.3 with checksum"
```

---

## Task 3: Install kubectl, doctl, kubeconform, kubesec from release binaries

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Add the release-binary install block**

Insert this RUN block in the final stage at the location where the old
`COPY --from=go-builder` lines used to be (after the Go runtime install, before
the trivy install):

```dockerfile
# Install kubectl, doctl, kubeconform, kubesec from official release binaries
# (verified SHA256). Replaces the removed source-build stage; fixes the bogus
# version metadata that source builds produced.
RUN set -eux && \
    cd /tmp && \
    # kubectl
    wget -q "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    echo "${KUBECTL_SHA256}  kubectl" | sha256sum -c - && \
    install -m 0755 kubectl /usr/local/bin/kubectl && \
    # doctl
    wget -q "https://github.com/digitalocean/doctl/releases/download/${DOCTL_VERSION}/doctl-${DOCTL_VERSION#v}-linux-amd64.tar.gz" -O doctl.tgz && \
    echo "${DOCTL_SHA256}  doctl.tgz" | sha256sum -c - && \
    tar -xzf doctl.tgz && install -m 0755 doctl /usr/local/bin/doctl && \
    # kubeconform
    wget -q "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" -O kubeconform.tgz && \
    echo "${KUBECONFORM_SHA256}  kubeconform.tgz" | sha256sum -c - && \
    tar -xzf kubeconform.tgz && install -m 0755 kubeconform /usr/local/bin/kubeconform && \
    # kubesec
    wget -q "https://github.com/controlplaneio/kubesec/releases/download/${KUBESEC_VERSION}/kubesec_linux_amd64.tar.gz" -O kubesec.tgz && \
    echo "${KUBESEC_SHA256}  kubesec.tgz" | sha256sum -c - && \
    tar -xzf kubesec.tgz && install -m 0755 kubesec /usr/local/bin/kubesec && \
    # cleanup
    rm -f /tmp/kubectl /tmp/doctl /tmp/doctl.tgz /tmp/kubeconform /tmp/kubeconform.tgz /tmp/kubesec /tmp/kubesec.tgz && \
    # verify meaningful (non-0.0.0) versions
    kubectl version --client -o json | grep -q '"gitVersion": "v1.36' && \
    doctl version | grep -q '1.160' && \
    kubeconform -v && \
    kubesec version
```

Note on doctl tar layout: the `doctl-<ver>-linux-amd64.tar.gz` contains a single
`doctl` binary at the archive root. If a future version nests it, adjust the
`tar`/`install` accordingly.

- [ ] **Step 2: Commit**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "feat: install kubectl/doctl/kubeconform/kubesec from verified release binaries"
```

---

## Task 4: Update Trivy, buildx, Helm; verify they remain checksum-pinned

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Update the Trivy install to use the ARG checksum**

Replace the existing Trivy RUN block with:

```dockerfile
# Download pre-built trivy binary (verified SHA256)
RUN set -eux && \
    TRIVY_NUM="${TRIVY_VERSION#v}" && \
    cd /tmp && \
    wget -q "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_NUM}_Linux-64bit.tar.gz" -O trivy.tgz && \
    echo "${TRIVY_SHA256}  trivy.tgz" | sha256sum -c - && \
    tar -xzf trivy.tgz trivy && \
    install -m 0755 trivy /usr/local/bin/trivy && \
    rm -f /tmp/trivy /tmp/trivy.tgz && \
    trivy --version
```

- [ ] **Step 2: Update the Helm install to use the tarball (not the get-helm-3 script)**

Replace the existing Helm RUN block (the `get-helm-3` one) with:

```dockerfile
# Install Helm from the official release tarball with checksum verification
# (no curl|bash get-helm-3 script).
RUN set -eux && \
    cd /tmp && \
    wget -q "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -O helm.tgz && \
    echo "${HELM_SHA256}  helm.tgz" | sha256sum -c - && \
    tar -xzf helm.tgz && \
    install -m 0755 linux-amd64/helm /usr/local/bin/helm && \
    rm -rf /tmp/helm.tgz /tmp/linux-amd64 && \
    helm version --short
```

- [ ] **Step 3: Update the buildx install to use the ARG checksum**

Replace the existing buildx RUN block with:

```dockerfile
# Install Docker buildx (verified SHA256)
RUN set -eux && \
    cd /tmp && \
    wget -q "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" -O docker-buildx && \
    echo "${BUILDX_SHA256}  docker-buildx" | sha256sum -c - && \
    install -m 0755 docker-buildx /usr/local/bin/docker-buildx && \
    mkdir -p /usr/local/lib/docker/cli-plugins && \
    cp /usr/local/bin/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx && \
    rm -f /tmp/docker-buildx && \
    docker buildx version
```

- [ ] **Step 4: Commit**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "feat: pin Trivy/Helm/buildx to verified release artifacts (Helm via tarball)"
```

---

## Task 5: Add AWS CLI v2 with GPG verification and expiry enforcement

**Files:**
- Create: `docker/aws-cli-public.key`
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Obtain and commit the AWS CLI signing public key (official source only)**

The key is the ASCII-armored AWS CLI v2 signing key published in the official
install guide:
`https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html`
("To install the AWS CLI" → "Validating the integrity..."). Copy the
`-----BEGIN PGP PUBLIC KEY BLOCK-----` … `-----END…-----` block verbatim from that
page into `docker/aws-cli-public.key`. **Do not** fetch it from a public
keyserver (the spec requires the committed, install-guide source).

Then assert the fingerprint before trusting the file:
```bash
gpg --show-keys --with-colons docker/aws-cli-public.key \
  | awk -F: '/^fpr:/{print $10; exit}' \
  | grep -qx "FB5DB77FD5C118B80511ADA8A6310ACC4672475C" \
  && echo "FINGERPRINT OK" || echo "FINGERPRINT MISMATCH"
```
Expected: `FINGERPRINT OK`. If MISMATCH, stop — do not commit a wrong key.

- [ ] **Step 2: Add the AWS CLI install block to the Dockerfile**

Insert after the Terraform/database-tools layers (it needs `unzip`, already
installed, and `gnupg`, already installed):

```dockerfile
# Install AWS CLI v2 with GPG signature verification and build-time expiry
# enforcement. Key fingerprint is pinned; see docs/specs for rotation procedure.
COPY aws-cli-public.key /tmp/aws-cli-public.key
RUN set -eux && \
    cd /tmp && \
    gpg --import /tmp/aws-cli-public.key && \
    gpg --fingerprint A6310ACC4672475C | tr -d ' \n' | grep -q "FB5DB77FD5C118B80511ADA8A6310ACC4672475C" && \
    EXP="$(gpg --with-colons --list-keys A6310ACC4672475C | awk -F: '/^pub:/{print $7; exit}')" && \
    [ -n "$EXP" ] && [ "$EXP" -gt "$(date +%s)" ] && \
    wget -q "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -O awscliv2.zip && \
    wget -q "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip.sig" -O awscliv2.zip.sig && \
    gpg --verify awscliv2.zip.sig awscliv2.zip && \
    unzip -q awscliv2.zip && \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli && \
    rm -rf /tmp/aws /tmp/awscliv2.zip /tmp/awscliv2.zip.sig /tmp/aws-cli-public.key && \
    aws --version
```

- [ ] **Step 3: Commit**

```bash
git add docker/aws-cli-public.key docker/Dockerfile.custom-runner
git commit -m "feat: add AWS CLI v2 with pinned-key GPG verification and expiry enforcement"
```

---

## Task 6: Add uv, bc, libmagic1, and pytest-mock

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Add bc and libmagic1 to the runtime-deps apt layer**

In the first `apt-get install -y --no-install-recommends` block (runtime deps),
add `bc` and `libmagic1` to the package list (alongside `libpq-dev gettext-base`):

```dockerfile
    curl wget git \
    libpq-dev gettext-base \
    bc libmagic1 \
    ca-certificates gnupg lsb-release \
    software-properties-common \
    apt-transport-https \
    jq zip unzip tar gzip \
    sudo && \
```

- [ ] **Step 2: Add pytest-mock to the python-builder pip line**

In Stage 1 (python-builder), update the pip install to include `pytest-mock`:

```dockerfile
RUN pip install --no-cache-dir --target /tmp/python-packages \
    black flake8 mypy ruff pytest pytest-cov pytest-mock \
    requests boto3 pyyaml
```

- [ ] **Step 3: Add the uv install block**

Insert after the AWS CLI block:

```dockerfile
# Install uv (Python package manager) from the official release tarball
# (verified SHA256).
RUN set -eux && \
    cd /tmp && \
    wget -q "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" -O uv.tgz && \
    echo "${UV_SHA256}  uv.tgz" | sha256sum -c - && \
    tar -xzf uv.tgz && \
    install -m 0755 uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && \
    install -m 0755 uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx && \
    rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu && \
    uv --version
```

- [ ] **Step 4: Commit**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "feat: add uv, bc, libmagic1, and pytest-mock to runner image"
```

---

## Task 7: apt installs with keyring fingerprint assertions (Node exact-pin, Terraform exact-pin, Docker CLI + compose + gh floating)

Every apt third-party repo key MUST be installed as a keyring and its full
fingerprint asserted before use (spec §4.2). Authoritative fingerprints
(confirmed 2026-05-31):

| Repo | Fingerprint |
|------|-------------|
| NodeSource | `6F71F525282841EEDAF851B42F59B5F99B1BE0B4` |
| HashiCorp | `798AEC654E5C15428C8E42EEAA16FCBCA621E701` |
| Docker | `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` |
| GitHub CLI | `2C6106201985B60E6C7AC87323F3D4EA75716059` |

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Replace the NodeSource install (no curl|bash) with keyring + fingerprint + exact pin**

Replace the existing Node RUN block with:

```dockerfile
# Install Node.js from NodeSource via an explicit keyring (no curl|bash),
# asserting the key fingerprint, then exact-pin the package. pnpm via corepack.
RUN set -eux && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    gpg --show-keys --with-colons /usr/share/keyrings/nodesource.gpg | \
        awk -F: '/^fpr:/{print $10; exit}' | grep -qx "6F71F525282841EEDAF851B42F59B5F99B1BE0B4" && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION} nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y "nodejs=${NODE_PKG_VERSION}" && \
    node --version && \
    corepack enable && \
    corepack prepare pnpm@11.5.0 --activate && \
    pnpm --version && \
    rm -rf /var/lib/apt/lists/*
```

If `nodejs=${NODE_PKG_VERSION}` fails because NodeSource advanced the
`-1nodesource1` revision, run `apt-cache madison nodejs` in the layer to find the
exact current `22.22.3-*` string and update `NODE_PKG_VERSION`. Do not switch to
a floating `nodejs` install.

- [ ] **Step 2: Add HashiCorp fingerprint assertion + exact-pin Terraform**

Replace the Terraform RUN block with:

```dockerfile
# Install Terraform (exact pin) from HashiCorp apt with key fingerprint assertion.
RUN set -eux && \
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    gpg --show-keys --with-colons /usr/share/keyrings/hashicorp-archive-keyring.gpg | \
        awk -F: '/^fpr:/{print $10; exit}' | grep -qx "798AEC654E5C15428C8E42EEAA16FCBCA621E701" && \
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list && \
    apt-get update && \
    apt-get install -y terraform=${TERRAFORM_VERSION} && \
    terraform version && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Add Docker (CLI + compose) and gh fingerprint assertions; install docker-compose-plugin**

Replace the combined database-tools / Docker CLI / GitHub CLI RUN block with one
that asserts both fingerprints and installs `docker-ce-cli`,
`docker-buildx-plugin` is NOT used (we pin buildx in Task 4), `docker-compose-plugin`,
and `gh` (Docker CLI/gh/compose float per policy §4.9, but keys are
fingerprint-verified):

```dockerfile
# Database tools (Ubuntu archive), Docker CLI + Compose (floating, key-verified),
# GitHub CLI (floating, key-verified). docker-compose-plugin provides
# `docker compose`. Docker CLI floor (>=28.3.3) is enforced by the smoke test.
RUN set -eux && \
    apt-get update && \
    apt-get install -y postgresql-client redis-tools && \
    # Docker apt repo + fingerprint
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    gpg --show-keys --with-colons /usr/share/keyrings/docker-archive-keyring.gpg | \
        awk -F: '/^fpr:/{print $10; exit}' | grep -qx "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    # GitHub CLI apt repo + fingerprint
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    gpg --show-keys --with-colons /usr/share/keyrings/githubcli-archive-keyring.gpg | \
        awk -F: '/^fpr:/{print $10; exit}' | grep -qx "2C6106201985B60E6C7AC87323F3D4EA75716059" && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-compose-plugin gh && \
    docker --version && docker compose version && gh --version && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 4: Commit**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "feat: exact-pin Node 22.22.3/Terraform 1.15.5, add docker compose, assert apt key fingerprints"
```

---

## Task 8: Update Python release pin (python-build-standalone)

**Files:**
- Modify: `docker/Dockerfile.custom-runner`

- [ ] **Step 1: Confirm the python-build-standalone install uses the new ARGs**

The existing PBS install block references `PYTHON_BUILD_RELEASE`,
`PYTHON_FULL_VERSION`, `PYTHON_TARBALL_SHA256`. Task 2 already set these to
`20260510` / `3.13.13` / the new SHA. Verify the block still reads:

```dockerfile
    PYTHON_TARBALL="cpython-${PYTHON_FULL_VERSION}+${PYTHON_BUILD_RELEASE}-x86_64-unknown-linux-gnu-install_only.tar.gz" && \
    ...
    echo "${PYTHON_TARBALL_SHA256}  ${PYTHON_TARBALL}" | sha256sum -c - && \
```
No code change expected if the ARGs are correct; if the block hardcodes an old
value, replace with the variable form above.

- [ ] **Step 2: Confirm `pytest_mock` will be importable**

The python-builder copies packages into the standalone site-packages. Task 6
added `pytest-mock` to the builder pip line, so it is copied by the existing
`COPY --from=python-builder` line. No change needed; this step is verification
only.

- [ ] **Step 3: Commit (only if a change was needed)**

```bash
git add docker/Dockerfile.custom-runner
git commit -m "chore: refresh python-build-standalone to release 20260510 (3.13.13)" || echo "no change needed"
```

---

## Task 9: Build the image locally and run the CVE re-verification gate

This is the §4.7 gate. Do not proceed to PR if it fails.

**Files:** none (verification only)

- [ ] **Step 1: Full local build**

Run:
```bash
docker build -f docker/Dockerfile.custom-runner -t rdl-runner:verify ./docker
```
Expected: build completes successfully (all checksum/GPG/version assertions pass
inside the build).

- [ ] **Step 2: Machine-enforced CVE gate (exits non-zero on any failure)**

Run this script; it **fails closed** — missing toolchain metadata, a toolchain
below the floor, or missing go-getter/x-crypto evidence each cause a non-zero
exit. Do not proceed past a non-zero exit.

```bash
docker run --rm rdl-runner:verify bash -lc '
set -euo pipefail
FLOOR_MAJOR=1; FLOOR_MINOR=24; FLOOR_PATCH=6   # Go 1.24.6 floor (CVE-2025-47907)
ge_floor() { # arg: go1.X.Y -> 0 if >= floor
  v="${1#go}"; IFS=. read -r a b c <<<"$v"; c="${c:-0}"
  [ "$a" -gt "$FLOOR_MAJOR" ] && return 0
  [ "$a" -lt "$FLOOR_MAJOR" ] && return 1
  [ "$b" -gt "$FLOOR_MINOR" ] && return 0
  [ "$b" -lt "$FLOOR_MINOR" ] && return 1
  [ "$c" -ge "$FLOOR_PATCH" ]
}
fail=0
for b in /usr/local/bin/kubectl /usr/local/bin/doctl /usr/local/bin/kubeconform \
         /usr/local/bin/kubesec /usr/local/bin/trivy /usr/local/bin/docker-buildx; do
  echo "== $b =="
  meta="$(go version -m "$b" 2>/dev/null || true)"
  tv="$(printf "%s\n" "$meta" | awk "/^$/{next} NR==1{print \$2}")"   # e.g. go1.26.3
  if ! printf "%s" "$tv" | grep -qE "^go1\.[0-9]+"; then
    echo "FAIL: no Go toolchain metadata for $b"; fail=1; continue
  fi
  if ge_floor "$tv"; then echo "OK toolchain $tv"; else echo "FAIL: $tv below floor"; fail=1; fi
done
# Trivy must show go-getter >= v1.7.9
gg="$(go version -m /usr/local/bin/trivy | awk "/hashicorp\/go-getter/{print \$3}" | head -1)"
echo "trivy go-getter: ${gg:-MISSING}"
case "$gg" in
  v1.7.9|v1.7.1[0-9]|v1.8.*|v1.9.*|v2.*) echo "OK go-getter";;
  *) echo "FAIL: trivy go-getter ${gg:-missing} < v1.7.9"; fail=1;;
esac
# kubesec golang.org/x/crypto must be >= v0.35.0 (CVE-2025-22869; also covers
# CVE-2024-45337 < v0.31.0). Presence alone is insufficient.
xc="$(go version -m /usr/local/bin/kubesec | awk "/golang.org\/x\/crypto/{print \$3}" | head -1)"
echo "kubesec x/crypto: ${xc:-MISSING}"
if [ -z "$xc" ]; then
  echo "FAIL: kubesec x/crypto metadata missing"; fail=1
else
  # compare against floor v0.35.0 using sort -V (lowest must be the floor)
  low="$(printf "%s\n%s\n" "${xc#v}" "0.35.0" | sort -V | head -1)"
  if [ "$low" = "0.35.0" ]; then echo "OK x/crypto $xc"; else echo "FAIL: x/crypto $xc < v0.35.0 (CVE-2025-22869)"; fail=1; fi
fi
exit $fail'
```
Expected: every binary `OK toolchain go1.x`, `OK go-getter`, x/crypto present,
overall exit 0. **If exit is non-zero (§4.7):** the offending tool is not adopted
as a release binary — either document a primary-source proof (upstream SBOM /
signed provenance / release build log naming the toolchain & module versions) in
the PR, or revert that specific tool to a source build. Soft absence is not
acceptable.

- [ ] **Step 3: Record gate results**

Write the measured toolchain/module versions into the PR description draft (and
they will feed the doc updates in Task 14). Keep the raw output for the PR note.

- [ ] **Step 4: No commit (verification only)**

---

## Task 10: In-image smoke test (§4.8) locally

**Files:** none (verification only)

- [ ] **Step 1: Run the full tool smoke test**

Run:
```bash
docker run --rm rdl-runner:verify bash -lc '
set -e
node --version
pnpm --version
python3 --version
uv --version
go version
terraform version
kubectl version --client -o json | grep gitVersion
helm version --short
doctl version
docker --version
docker buildx version
docker compose version
gh --version | head -1
aws --version
trivy --version
kubeconform -v
kubesec version
psql --version
redis-cli --version
bc --version | head -1
python3 -c "import pytest_mock; print(\"pytest_mock\", pytest_mock.__version__)"
echo ALL_TOOLS_OK'
```
Expected: ends with `ALL_TOOLS_OK`; kubectl shows `v1.36.1`, doctl `1.160.0`,
kubesec a real version (not `0.0.0`).

- [ ] **Step 2: Assert the Docker CLI CVE floor (28.3.3) — fail if below**

Run (fails non-zero if below 28.3.3 via `sort -V`):
```bash
docker run --rm rdl-runner:verify bash -lc '
  v="$(docker --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)"
  echo "Docker CLI: $v"
  low="$(printf "%s\n28.3.3\n" "$v" | sort -V | head -1)"
  [ "$low" = "28.3.3" ] || { echo "FAIL: $v < 28.3.3 (CVE-2025-54388)"; exit 1; }
  echo "OK Docker CLI floor"'
```
Expected: `OK Docker CLI floor`.

- [ ] **Step 3: Local Trivy scan with the (about-to-be-updated) .trivyignore**

Defer the actual scan to after Task 11 (which updates `.trivyignore`). This step
is a placeholder pointer; the scan is run in Task 11 Step 3.

- [ ] **Step 4: No commit (verification only)**

---

## Task 11: Trim `.trivyignore` and run the local scan

**Files:**
- Modify: `.trivyignore`

- [ ] **Step 1: Rewrite `.trivyignore`**

Replace the file with only the entries that still correspond to something in the
image (no builder stage exists anymore):

```
# Trivy ignore file. The Go source-build stage has been removed; Go tools are
# now official release binaries, so the former /tmp/unified-go-build and
# /go/pkg/mod test-fixture ignores no longer apply and have been deleted.

# Base-image vulnerabilities we cannot control without breaking ARC
# compatibility. Tracked and risk-accepted in SECURITY-DISMISSALS.md.
CVE-2025-47907  # Container runtime tools in the actions-runner base image
```

Note: `/usr/local/go/**` is intentionally NOT blanket-ignored anymore — Go is a
first-class runtime and its CVEs should surface. If the scan in Step 3 produces a
specific, justified false positive, add a narrow, commented ignore for exactly
that finding; do not re-add a blanket path ignore.

- [ ] **Step 2: Rebuild not required; reuse `rdl-runner:verify` from Task 9**

(If Tasks 9–10 image is stale because of later commits, rebuild first:
`docker build -f docker/Dockerfile.custom-runner -t rdl-runner:verify ./docker`.)

- [ ] **Step 3: Run the local Trivy scan against the image tarball (matches CI)**

A container has no access to the host Docker daemon's image store, so scan an
exported tarball with `--input` (Trivy reads the tar directly; no socket needed).
This command mounts the repo and passes `--ignorefile` so it matches CI's
`trivyignores: '.trivyignore'` exactly, and it **preserves the failure exit code**
(no piping through `tail`, which would mask a non-zero Trivy status):

```bash
docker save rdl-runner:verify -o /tmp/rdl-runner-verify.tar
docker run --rm -v /tmp:/scan -v "$PWD":/repo rdl-runner:verify \
  trivy image --input /scan/rdl-runner-verify.tar --ignorefile /repo/.trivyignore \
  --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --timeout 30m
rc=$?
rm -f /tmp/rdl-runner-verify.tar
echo "trivy exit: $rc"
[ "$rc" -eq 0 ] || { echo "FAIL: fixed HIGH/CRITICAL findings (or scan error)"; exit 1; }
```
(`rdl-runner:verify` carries Trivy 0.70.0, so it can scan itself from the tar.
Alternatively use a host `trivy` with the same flags.) Expected: `trivy exit: 0`.
If non-zero, a fixed HIGH/CRITICAL is present that `.trivyignore` does not accept
— the §4.7 gate fails; investigate before continuing. If you must view the report
body, write it to a file and `tail` the file afterward — never pipe the scan
itself through `tail` (that discards Trivy's exit status).

- [ ] **Step 4: Commit**

```bash
git add .trivyignore
git commit -m "chore: trim .trivyignore to remove obsolete Go builder ignores"
```

---

## Task 12: Update workflow for PR-time verification

**Files:**
- Modify: `.github/workflows/build-runner-image.yml`

- [ ] **Step 1: Set least-privilege permissions and gate registry login away from PRs**

GitHub `permissions` are job/workflow-scoped, not per-step, so we cannot "move
`packages: write` to push only" with a step conditional. Instead:
- Set the `build-and-push` job `permissions` to the union actually needed, and
  rely on event gating for the privileged *actions*:
  ```yaml
      permissions:
        contents: read
        pull-requests: write     # PR comment (same-repo only; no-op on forks)
        security-events: write   # PR/-push Trivy SARIF upload
  ```
  Note: `packages: write` is **removed** — the image is pushed to the DigitalOcean
  registry via `docker login`, which needs no GitHub Packages permission. (If a
  future change pushes to GHCR, add it then.)
- The "Log in to DigitalOcean Container Registry" step gets
  `if: github.event_name != 'pull_request'` (PRs never touch `secrets.DO_TOKEN`;
  fork PRs have no secrets anyway).
- The PR-comment step (if retained) is gated same-repo only:
  `if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository`.
- The build step gets two modes:
  - PR: `push: false`, `load: true`, `tags: rdl-runner:pr`.
  - push/merge: existing `push: true` with the metadata tags.

Concretely, change the build step to:

```yaml
      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./docker
          file: ./docker/Dockerfile.custom-runner
          push: ${{ github.event_name != 'pull_request' }}
          load: ${{ github.event_name == 'pull_request' }}
          tags: ${{ github.event_name == 'pull_request' && 'rdl-runner:pr' || steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          no-cache: ${{ github.event.inputs.force_rebuild == 'true' }}
          platforms: linux/amd64
```

- [ ] **Step 2: Add a PR smoke-test step (same job, runs only on PRs)**

Add after the build step:

```yaml
      - name: Smoke test PR image
        if: github.event_name == 'pull_request'
        run: |
          set -e
          IMG=rdl-runner:pr
          docker run --rm "$IMG" bash -lc '
            set -e
            node --version; pnpm --version; python3 --version; uv --version
            go version; terraform version
            kubectl version --client -o json | grep gitVersion
            helm version --short; doctl version
            docker --version; docker buildx version; docker compose version
            gh --version | head -1; aws --version; trivy --version
            kubeconform -v; kubesec version; psql --version; redis-cli --version
            bc --version | head -1
            python3 -c "import pytest_mock"
            echo ALL_TOOLS_OK'
          docker run --rm "$IMG" doctl version | grep -q 1.160
          docker run --rm "$IMG" kubectl version --client -o json | grep -q '"gitVersion": "v1.36'
          docker run --rm "$IMG" kubesec version | grep -vq '0.0.0'
          DV=$(docker run --rm "$IMG" docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
          echo "Docker CLI: $DV"
          LOW=$(printf '%s\n28.3.3\n' "$DV" | sort -V | head -1)
          [ "$LOW" = "28.3.3" ] || { echo "FAIL: Docker CLI $DV < 28.3.3 (CVE-2025-54388)"; exit 1; }
          echo "OK Docker CLI floor"
```

- [ ] **Step 3: Add a PR Trivy scan that FAILS the build on fixed HIGH/CRITICAL**

The enforcing scan (`exit-code: '1'`) is the gate and runs independent of any
SARIF/reporting permission, so fork PRs still fail on real findings. SARIF upload
is a separate, best-effort reporting step gated to contexts where
`security-events: write` is actually available (same-repo PRs).

```yaml
      - name: Trivy scan PR image (enforcing gate)
        if: github.event_name == 'pull_request'
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: rdl-runner:pr
          format: table
          exit-code: '1'
          severity: 'CRITICAL,HIGH'
          ignore-unfixed: true
          timeout: '30m'
          trivyignores: '.trivyignore'

      - name: Trivy SARIF (reporting, same-repo PRs only)
        # Forks get a read-only token; skip SARIF there so reporting-permission
        # failures never mask or replace the enforcing gate above.
        if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: rdl-runner:pr
          format: sarif
          output: trivy-results.sarif
          severity: 'CRITICAL,HIGH'
          ignore-unfixed: true
          timeout: '30m'
          trivyignores: '.trivyignore'

      - name: Upload PR Trivy SARIF
        if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif
```

Also update the existing push-path `security-scan` job's Trivy step to add
`exit-code: '1'` (currently it only emits SARIF and never fails the build), so
the gate is enforced on merge too. Keep its SARIF upload.

- [ ] **Step 4: Remove the "verify Go is absent" steps**

In the `security-scan` job (push path), delete the steps/lines that assert
`which go` fails, that `/usr/local/go` is removed, and that `/go` is removed.
Replace the "all tools functional" checks with the §4.8 list (keep the existing
`kubectl/doctl/kubeconform/kubesec/trivy` checks; they now report real versions).

- [ ] **Step 5: Update the push-path smoke checks to assert meaningful versions**

In the `security-scan` (or `Verify image`) steps, ensure the doctl/kubectl/kubesec
checks assert non-`0.0.0` versions, mirroring Step 2.

- [ ] **Step 6: Validate workflow YAML and Actions semantics**

YAML syntax:
```bash
docker run --rm -v "$PWD":/w -w /w rdl-runner:verify bash -lc 'python3 -c "import yaml,sys; yaml.safe_load(open(\".github/workflows/build-runner-image.yml\"))" && echo YAML_OK'
```
Expected: `YAML_OK`.

Actions semantics (catches the ternary tag expression, bad permissions, action
input typos that PyYAML cannot). Run actionlint via its pinned container:
```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7 -color
```
Expected: no errors. If Docker-in-Docker pull is unavailable locally, note that
actionlint runs in CI and record that only YAML syntax was checked locally.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build-runner-image.yml
git commit -m "ci: enforce smoke test and Trivy on PR-built image; drop Go-absent checks"
```

---

## Task 13: Update test scripts

**Files:**
- Modify: `test/verify-tools.sh`, `test/verify-go-runtime.sh`,
  `test/verify-security-fixes.sh`, `test/verify-docker-version.sh`

- [ ] **Step 1: `test/verify-tools.sh` — bump expected versions and add tools**

Update the `test_tool` lines: Terraform `1.15.5`, kubectl `1.36.1`, Helm
`3.21.0`, doctl `1.160.0`, Trivy `0.70.0`. Add:
```bash
test_tool "uv" "uv --version"
test_tool "AWS CLI" "aws --version"
test_tool "bc" "bc --version | head -1"
```
And add `pytest_mock` to the Python package import check line:
```bash
import black, flake8, mypy, ruff, pytest, pytest_mock, requests, boto3, yaml
```

- [ ] **Step 2: `test/verify-go-runtime.sh` — Go 1.26.3**

Change `GO_VERSION_EXPECTED="1.24.6"` to `GO_VERSION_EXPECTED="1.26.3"`.

- [ ] **Step 3: `test/verify-security-fixes.sh` — align narrative**

Update the CVE narrative comments to state Go tools are now release binaries with
toolchain ≥ the documented floor (measured in Task 9), not source builds. Keep
the functional Trivy checks.

- [ ] **Step 4: `test/verify-docker-version.sh` — confirm floor unchanged**

No version change (floor stays 28.3.3 for CVE-2025-54388). Verify the script
still runs `bash -n` clean.

- [ ] **Step 5: Syntax-check**

Run:
```bash
for f in test/*.sh; do bash -n "$f" && echo "OK $f"; done
```
Expected: all `OK`.

- [ ] **Step 6: Commit**

```bash
git add test/*.sh
git commit -m "test: align verification scripts with refreshed tool versions"
```

---

## Task 14: Update README and security docs

**Files:**
- Modify: `README.md`, `docs/DOCKERFILE-SECURITY-REFACTOR.md`,
  `docs/GO-RUNTIME-FIX.md`

- [ ] **Step 1: README — tool list, versions, strategy, policies**

Update the "Included Tools" section to: Python 3.13.13, Node 22.22.3, pnpm
11.5.0, Terraform 1.15.5, kubectl 1.36.1, Helm 3.21.0, doctl 1.160.0, Go 1.26.3,
Trivy 0.70.0, kubeconform 0.7.0, kubesec 2.14.2, buildx 0.34.1, **uv 0.11.17**,
**AWS CLI v2 2.34.57**, plus bc, libmagic1, pytest-mock. Add:
- A "Software Versions" subsection with "Last version check: 2026-05-31".
- A note that Go tools are official release binaries (not source builds), with
  the measured toolchain versions from Task 9.
- The floating-package policy (§4.9): docker-ce-cli/docker-compose-plugin/gh
  float (fingerprint-verified, with smoke floor); listed Ubuntu-archive packages
  float; everything else pinned.
- AWS CLI key fingerprint `A6310ACC4672475C` and the rotation procedure
  (replace `docker/aws-cli-public.key` + the pinned fingerprint when AWS rotates
  the key, expiry 2026-07-07).
- PowerShell intentionally excluded; consumers needing `run.ps1` parity should
  use a Linux-equivalent script.

- [ ] **Step 2: `docs/DOCKERFILE-SECURITY-REFACTOR.md` — release-binary strategy**

Rewrite the sections that describe the 5-tool Go source build and the
`golang:1.24.6-alpine` builder to describe the current approach: a python-builder
stage plus a final stage installing official release binaries with SHA256/GPG
verification. Update CVE claims to cite the measured toolchain versions from
Task 9 rather than "built from source with Go 1.24.6".

- [ ] **Step 3: `docs/GO-RUNTIME-FIX.md` — Go 1.26.3 runtime**

Update references from Go 1.24.6 to Go 1.26.3 and note the source-build stage no
longer exists; the doc now only concerns the clean Go runtime install.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/DOCKERFILE-SECURITY-REFACTOR.md docs/GO-RUNTIME-FIX.md
git commit -m "docs: document release-binary strategy, new versions, and policies"
```

---

## Task 15: AuroLegal local build validation (acceptance criterion)

**Files:** none (validation recorded in PR)

- [ ] **Step 1: Locate AuroLegal Dockerfiles**

Set `AUROLEGAL` to wherever the defender.ai repo is checked out, then locate the
Dockerfiles. In this environment Codex/WSL sees it under `/mnt/d/...` and the
host git-bash under `D:/...`; use whichever your shell resolves. WSL-first:
```bash
AUROLEGAL="${AUROLEGAL:-/mnt/d/repos/defender.ai}"   # or D:/repos/defender.ai in git-bash
ls "$AUROLEGAL"/backend/Dockerfile "$AUROLEGAL"/frontend/Dockerfile 2>/dev/null || \
  find "$AUROLEGAL" -maxdepth 3 -name Dockerfile 2>/dev/null
```
Record the actual backend/frontend Dockerfile paths and any required build args.

- [ ] **Step 2: Build AuroLegal images from inside the runner image**

Run (Linux/WSL socket path). Adjust the `-f`/context paths to Step 1's findings:
```bash
AUROLEGAL="${AUROLEGAL:-/mnt/d/repos/defender.ai}"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$AUROLEGAL":/work -w /work \
  rdl-runner:verify \
  bash -lc 'docker build -f backend/Dockerfile -t aurolegal-backend:verify backend/ \
            && docker build -f frontend/Dockerfile -t aurolegal-frontend:verify frontend/'
```
Expected: both builds exit 0. Capture the tail of the output.

(Windows Docker Desktop note: if running from PowerShell rather than WSL, use
`-v //var/run/docker.sock:/var/run/docker.sock` and a `D:/repos/defender.ai`
host path. Prefer the WSL form above.)

- [ ] **Step 3: Record the result for the PR**

Paste the exact commands and the observed success/failure into the PR
description. If a build fails for an image-toolchain reason (missing tool),
treat it as a finding and address in the image; if it fails for an
AuroLegal-specific reason (e.g. needs build secrets), note that honestly as
out-of-scope for the image.

- [ ] **Step 4: No commit (validation only)**

---

## Task 16: Push branch, open PR, run Codex PR review and CI to green

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
git push -u origin refresh/runner-toolchain-issue-12
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base main --title "Refresh runner image toolchain (issue #12)" \
  --body-file <(cat <<'EOF'
Resolves #12.

Refreshes the custom runner image toolchain. See
docs/specs/2026-05-31-runner-toolchain-refresh-design.md.

## Changes
- Drop the Go source-build stage; install kubectl/doctl/kubeconform/kubesec/
  trivy/buildx as official release binaries with verified SHA256. Fixes the
  bogus v0.0.0 / 0.0.0-dev version strings.
- Bump: Go 1.26.3, kubectl 1.36.1, doctl 1.160.0, Helm 3.21.0, Terraform 1.15.5,
  buildx 0.34.1, Python 3.13.13.
- Add uv 0.11.17, AWS CLI v2 2.34.57 (GPG-verified, expiry-enforced), bc,
  libmagic1, pytest-mock.
- Pin Node 22.22.3, pnpm 11.5.0.
- .gitattributes enforces LF; CRLF reproducibility fixed.
- PR build now runs smoke test + Trivy on the locally-loaded image.

## CVE re-verification gate (measured)
<paste Task 9 Step 2 output: toolchain per binary, go-getter/x-crypto versions>

## AuroLegal local validation
<paste Task 15 commands + result>
EOF
)
```

- [ ] **Step 3: Codex PR review loop**

Per `claude_help/codex-review-process.md`, ask Codex (cwd
`/mnt/h/repos/redducklabs-runners`) to fetch origin main, diff
`origin/main...HEAD`, review critically, and write
`temp/codex-reviews/pr-<number>-review-1.md` ending with the VERDICT line.
Address every BLOCKER/MAJOR; re-review (increment N) until `VERDICT: APPROVED`.

- [ ] **Step 4: Monitor CI to green**

```bash
gh pr checks --watch
```
Expected: all checks green. Investigate and fix any failure (push fixes; CI
re-runs). Do not merge with red checks.

- [ ] **Step 5: Do not merge automatically**

Leave the PR for human merge once Codex `VERDICT: APPROVED` and CI is green,
unless the user explicitly asks to merge.

---

## Task 17: File consumer adoption issues and the deferred caching issue

**Files:** none (GitHub issues)

- [ ] **Step 1: File the deferred caching issue (this repo)**

`gh issue create --repo redducklabs/redducklabs-runners` titled "Build-layer
caching: in-cluster Docker registry pull-through mirror", body summarizing §6 of
the spec (ARC daemon.json-via-ConfigMap or full dind template override,
NetworkPolicy restricting the unauthenticated registry, Recreate strategy, RWO
do-block-storage PVC, pinned registry digest, no upstream creds).

- [ ] **Step 2: File 5 consumer adoption issues**

One per repo, from the audit reports, each citing the final image versions:
- `redducklabs/aurolegal.ai` — phased migration ubuntu-latest →
  redducklabs-runners; keep setup-terraform (1.14.8 vs 1.15.5) and
  pnpm/action-setup (10 vs 11) pins; Playwright e2e + services:postgres under
  DinD; pytest-mock now provided by image.
- `redducklabs/redducklaw` — pin Terraform 1.15.5; slim torch/unstructured on
  4Gi; Python 3.12 vs 3.13.
- `redducklabs/zipbot-v2` — Terraform 1.12.0 vs 1.15.5; fix
  upload-artifact@v3→v4; review --set-current-context shared state.
- `redducklabs/therapy-link` — replace sudo apt libmagic1 with image-provided
  libmagic1; bc now provided; Python 3.11/3.12 vs 3.13; pnpm 10 vs 11; TF state.
- `redducklabs/redducklabs` — pin unpinned Terraform to 1.15.5; replace
  kubeval+sudo with kubeconform; decide whether dns-security-monitor stays
  GitHub-hosted.

Each issue states: keep version-pinning setup-* steps where the pinned version
differs from the image (especially Terraform — state forward-incompat); only drop
setup-* where the image version is an accepted match.

- [ ] **Step 3: No commit (issues only)**

---

## Self-review notes (author)

- Spec coverage: §4.1 (Task 2–3), §4.2/§4.9 policy (Tasks 5,7,11,14), §4.3 AWS
  (Task 5), §4.4 versions (Tasks 2–8), §4.5 pnpm (Task 7), §4.6 PR CI (Task 12),
  §4.7 CVE gate (Task 9), §4.8 smoke (Tasks 10,12), §4.10 new tools (Task 6),
  §4.11 pwsh (Task 14), §4.12 CRLF (Task 1), §4.13 docs/tests (Tasks 13,14),
  §4.14 AuroLegal (Task 15), §6 deferred caching (Task 17), Workstream C (Task 17).
- Ordering note: Tasks 2→4 leave the image temporarily without Go tools between
  Task 2 and Task 3; no build is attempted until Task 9, after all installs.
- Floating-pin reconciliation matches spec §4.2's three apt categories.
```
