# Runner Toolchain Refresh — Design

- Issue: redducklabs/redducklabs-runners#12
- Date: 2026-05-31
- Status: Draft (Codex review round 2)

## 1. Problem

The custom runner image (`docker/Dockerfile.custom-runner`) is stale and not a
seamless replacement for `ubuntu-latest` for Red Duck Labs workflows
(AuroLegal and four other repos). Concrete defects, from issue #12 and a
five-repo CI audit performed for this work:

1. **Bogus version metadata from source builds.** kubectl, doctl, kubeconform,
   and kubesec are compiled from source in a Go builder stage. The builds do not
   stamp release metadata, so `kubectl version` reports
   `v0.0.0-master+$Format:%H$` and `doctl version` reports `0.0.0-dev`. The
   original reason for source-building (needing a newer Go than upstream shipped,
   to fix CVE-2025-47907) is stale in 2026 — upstream release binaries now ship
   patched.
2. **Stale tool versions.** Go 1.25.9, kubectl v1.33.4, doctl v1.139.0, Helm
   v3.18.6, Terraform 1.12.2, buildx manually downgraded to v0.27.0.
3. **Missing workflow-critical tools.** No `uv` (Python package manager) and no
   AWS CLI; AuroLegal workflows call both.
4. **Missing small consumer tools.** `bc`, `libmagic1`, and `pytest-mock` are
   needed by therapy-link and aurolegal workflows and are absent, forcing
   non-root `sudo apt` installs that fail on the hardened runner.
5. **CRLF line endings.** Shell scripts and workflows are checked out CRLF on
   Windows with no `.gitattributes` guard; `test/verify-go-runtime.sh` fails on
   Linux with `pipefail\r`. (The git blobs are already LF; the missing guard is
   the durable defect.)
6. **Stale verification and docs.** `build-runner-image.yml` still asserts Go is
   absent even though the Dockerfile intentionally installs a Go runtime;
   `test/*.sh` expect old versions; README and security docs describe the old
   source-build strategy.

## 2. Goals / Non-Goals

### Goals
- Refresh the image to current, pinned, checksum/signature-verified tool
  versions (§4.2, §4.8 define the verification standard and the explicit
  floating-package policy).
- Replace source-built Go tools with official release binaries (fixes version
  metadata; removes a stale, complex build stage) **behind a CVE re-verification
  gate** (§4.7).
- Add `uv`, AWS CLI v2, `bc`, `libmagic1`, `pytest-mock`.
- Make the image a drop-in for the five consumer repos' current needs, except
  documented exclusions (PowerShell, Playwright browsers).
- Fix CRLF durably and align all verification scripts, workflows, and docs.
- Enforce the issue #12 acceptance criteria **on the PR build** (§4.6), not only
  on post-merge pushed images.

### Non-Goals
- No multi-version tool baking (no Node 20+22, no four Terraforms). One pinned
  version per tool.
- No edits to consumer repositories. Their adoption is filed as issues
  (Workstream C).
- No deployment or mutation of the live runner fleet. Deploy stays a CI/operator
  step.
- No move to Node 24, Helm 4, or other major bumps that risk consumer breakage
  (tracked as consumer-repo follow-ups instead).
- **Build-layer caching (registry pull-through mirror) is explicitly out of
  scope** and deferred to its own spec/issue (§6). Codex review round 1 showed it
  is not a minimal, additive change under ARC `containerMode: dind` and needs its
  own design (ARC-compatible daemon config, NetworkPolicy, RWO storage strategy).

## 3. Workstreams

- **A. Image toolchain refresh (this PR)** — `docker/Dockerfile.custom-runner`,
  `.trivyignore`, `.gitattributes`, `.github/workflows/build-runner-image.yml`,
  `test/*.sh`, `README.md`, `docs/*`.
- **C. Consumer adoption** — 5 GitHub issues in consumer repos, filed after this
  spec is approved so they cite final image versions. No code edits to those
  repos.

(Workstream "B / caching" from round 1 is removed here and tracked separately in
§6.)

## 4. Workstream A — Image refresh

### 4.1 Architecture change: drop the Go source-build stage

Remove the `go-builder` stage entirely. kubectl, doctl, kubeconform, kubesec,
and trivy become official prebuilt linux/amd64 release binaries, each verified
against an official SHA256 checksum before install. buildx likewise moves to the
current upstream release binary (already a binary today, just bumped). The clean
Go **runtime** install stays (CI workflows need `go`) and is bumped to 1.26.3.

This removal is gated on the CVE re-verification in §4.7 passing; if any tool's
release binary fails the gate, that specific tool stays source-built and the
deviation is documented.

Consequences:
- `kubectl`/`doctl` report correct release versions.
- The `.trivyignore` Go-builder machinery is reduced (§4.9).
- `DOCKERFILE-SECURITY-REFACTOR.md` and `GO-RUNTIME-FIX.md` are updated to
  describe the release-binary strategy. This is an explicit ask in issue #12.

### 4.2 Supply-chain verification standard

Every externally downloaded artifact MUST be verified before use, by one of:

- **SHA256** compared against the tool's official checksum file/value (binaries
  and tarballs).
- **GPG detached signature** against a pinned, fingerprint-checked public key
  (AWS CLI; see §4.3).
- **apt (exact pin)** — install of an **exact** package version from a repository
  whose signing key is installed as a keyring with a **verified fingerprint**
  (Node, Terraform).
- **apt (approved floating third-party exception)** — install of the repo's
  current stable version from a fingerprint-verified third-party keyring, for a
  small, **closed** list of security-sensitive tools where we deliberately want
  upstream fixes and pinning would delay CVE patches: Docker CLI `docker-ce-cli`
  and GitHub CLI `gh` only. Each requires (a) the keyring fingerprint check and
  (b) a smoke-test version floor that fails the build on regression (Docker CLI ≥
  28.3.3 for CVE-2025-54388; gh present and runnable). See §4.9.
- **apt (Ubuntu archive distro-managed runtime deps)** — install from the base
  image's trusted Ubuntu archive (already keyring-trusted in the
  actions-runner base), distro-floating, for low-CVE-sensitivity OS runtime
  libraries and small utilities with no consumer version dependency. Closed list:
  `postgresql-client`, `redis-tools`, `bc`, `libmagic1`, `gettext-base`,
  `libpq-dev`, plus the existing base runtime deps (curl, wget, git, jq, zip,
  unzip, tar, gzip, ca-certificates, gnupg, lsb-release, etc.). These are trusted
  via the Ubuntu archive keyring, not via per-package checksum. See §4.9.

Rules:
- No `curl … | bash` install scripts for versioned tools. Specifically, Helm is
  installed from the `get.helm.sh` tarball with checksum verification, **not**
  `raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3`.
- Exact-pin apt installs use the **exact** discovered package version string (e.g.
  `nodejs=22.22.3-1nodesource1`, `terraform=1.15.5-1`), never a wildcard.
- The two non-exact apt categories above (the closed third-party Docker CLI / gh
  list, and the closed Ubuntu-archive distro-managed list) are the documented
  exceptions to exact pinning and are governed by §4.9. No other package may
  float; anything not in those closed lists is exact-pinned or checksum/GPG
  verified.
- Checksums and the commands/sources used to obtain them are recorded in the
  Appendix (§7) for provenance.

### 4.3 AWS CLI v2 GPG verification and key rotation

- Install the **versioned** bundle
  `https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.34.57.zip` plus its
  signature `…-2.34.57.zip.sig`.
- **Pinned key (exact full fingerprint):**
  `FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C` (Key ID
  `A6310ACC4672475C`), sourced from the official AWS CLI v2 install guide
  (`https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html`,
  "Validating the integrity..." section). The Dockerfile embeds the ASCII-armored
  public key (committed in `docker/`, not fetched at build time from a keyserver),
  imports it, and asserts the imported fingerprint **exactly equals** the value
  above before running `gpg --verify awscli-exe…zip.sig awscli-exe…zip`. A short
  key ID alone is not acceptable; the full 40-hex fingerprint must match.
- **Verification command shape:**
  ```
  gpg --import /tmp/aws-cli-public.key
  # 1) assert exact full fingerprint
  gpg --fingerprint A6310ACC4672475C | grep -q "FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C"
  # 2) enforce key not expired AT BUILD TIME (do not rely on gpg --verify for this)
  EXP=$(gpg --with-colons --list-keys A6310ACC4672475C | awk -F: '/^pub:/{print $7; exit}')
  [ -n "$EXP" ] && [ "$EXP" -gt "$(date +%s)" ]   # fail if expiry absent or already past
  # 3) verify the artifact signature
  gpg --verify awscli-exe-linux-x86_64-2.34.57.zip.sig awscli-exe-linux-x86_64-2.34.57.zip
  ```
- **Expiry semantics (explicit, self-enforced):** `gpg --verify` alone is NOT
  relied upon to catch expiry — GnuPG can report a good signature from a key that
  was valid when it signed but has since expired. The Dockerfile therefore parses
  the key's machine-readable expiration timestamp (`--with-colons` field 7 of the
  `pub` record) and **fails the build when that timestamp is missing or ≤ the
  current build time** (step 2 above). Combined with the signature check (step 3),
  the build fails loudly once AWS's documented 2026-07-07 expiry passes — by our
  own check, not by hoping gpg flags it. This is intended, not a regression.
- **Rotation procedure (documented in README):** when AWS publishes the next
  signing key, (1) obtain the new ASCII-armored key and its full fingerprint from
  the AWS install guide over HTTPS, (2) replace the committed key file and the
  pinned fingerprint in the Dockerfile, (3) rebuild. This is a known, one-file
  update.

### 4.4 Version matrix (checksums verified 2026-05-31; provenance in §7)

| Tool | Old | New | Source / method | SHA256 (verified) |
|------|-----|-----|-----------------|-------------------|
| Go (runtime) | 1.25.9 | 1.26.3 | go.dev/dl tarball + SHA256 | `2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556` |
| kubectl | v1.33.4 (src) | v1.36.1 | dl.k8s.io binary + `.sha256` | `629d3f410e09bf49b64ae7079f7f0bda1191efed311f7d37fdbab0ad5b0ec2b7` |
| doctl | v1.139.0 (src) | v1.160.0 | GH release tar + checksums | `b0a23eb02a213e6418e6d5b7dcd5207b6b70a5a5b15e8fcaadc0b8715ac0a735` |
| Helm | v3.18.6 (script) | v3.21.0 | get.helm.sh tar + `.sha256sum` | `0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36` |
| Terraform | 1.12.2-1 | 1.15.5-1 | HashiCorp apt, exact pin | apt keyring + exact version |
| kubeconform | v0.7.0 (src) | v0.7.0 | GH release tar + CHECKSUMS | `c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3` |
| kubesec | v2.14.2 (src) | v2.14.2 | GH release tar + checksums | `bc252e35f01bc4f133a49404315da3ccfed0209cc9baba33883eaeca0656f35c` |
| Trivy | v0.70.0 | v0.70.0 | GH release tar + checksums | `8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9` |
| buildx | v0.27.0 (manual) | v0.34.1 | GH binary + checksums | `f1332ddb9010bd0b72628266c3a906d9a6979848033df4c8d9bd2cd113bae12b` |
| Python | 3.13.13 (20260414) | 3.13.13 (20260510) | python-build-standalone + SHA256SUMS | `928d08ecda5bbf4d8851c5872e363dd9c9be938fdb90f525b6f36a8c90ff8407` |
| Node.js | 22.x (floating) | 22.22.3 (exact) | NodeSource apt, keyring + exact pin | apt keyring + exact version |
| pnpm | latest (floating) | 11.5.0 | corepack (Node-signed), pinned | corepack trust (§4.5) |
| uv | — | 0.11.17 | astral GH tar + `.sha256` | `0017ccecaeb4d431d7f93b583ebff0c5c38e00eb734fcf13d05f72ca419125fe` |
| AWS CLI v2 | — | 2.34.57 | awscli-exe + GPG `.sig` (§4.3) | GPG signature (fingerprint-pinned) |

### 4.5 pnpm verification meaning

pnpm 11.5.0 is activated via `corepack prepare pnpm@11.5.0 --activate` (pinned,
not `@latest`). "Verification" here is explicitly defined as **trust in Node's
bundled Corepack integrity check** (Corepack validates the package-manager
artifact against its built-in signed key set and the npm-registry integrity
hash). No separate SHA is managed. This is documented as the accepted model
rather than implied.

### 4.6 PR-time verification (acceptance enforcement)

The current workflow only smoke-tests and Trivy-scans **pushed** images, and
`build-push-action` does not push on PRs — so today the acceptance criteria are
not enforced on a PR. A locally `load`-ed image lives only on the runner that
built it and is **not** visible to a separate `needs:`-chained job. The fix
therefore specifies the job topology explicitly:

- **PR builds run build + smoke + Trivy in a single job** (`pull_request` event).
  That job: builds with `load: true` and a local tag (`push: false`), then runs
  the smoke test (§4.8) and the Trivy scan against that same local image, in the
  same job so the loaded image is in scope. No artifact passing, no second job.
- **Push/merge builds keep the existing two-job shape** (`build-and-push` then
  `security-scan` pulling the pushed registry image), unchanged in topology.
- **Registry login is gated to events that push or scan the registry image.** The
  DigitalOcean `docker login` step (and any `secrets.DO_TOKEN` use) runs only when
  `github.event_name != 'pull_request'`. PR builds are fully local and never touch
  the registry or secrets (secrets are unavailable on fork PRs anyway).
- **Least-privilege permissions.** PR builds must not write packages. The
  `packages: write` permission is scoped to the push/merge job only; the PR job
  gets `contents: read` (plus `pull-requests: write` only if PR commenting is
  retained, and `security-events: write` only for the Trivy SARIF upload). No
  single job carries both `packages: write` and the PR path.
- The Trivy scan on PRs enforces "no fixed HIGH/CRITICAL except documented
  accepted base-image risks" using the reduced `.trivyignore` (§4.9).
- The "verify Go is absent" steps are removed (Go runtime is intentionally
  present).

### 4.7 CVE re-verification gate (before deleting source builds)

Switching kubectl/doctl/kubeconform/kubesec/trivy/buildx to release binaries must
not silently regress the CVE posture the current docs claim. Gate:

1. For each release binary, inspect embedded build metadata
   (`go version -m <binary>`) and record the Go compiler version and any
   security-relevant module versions (notably go-getter for Trivy, x/crypto for
   kubesec).
2. Require each recorded Go toolchain to be at or above the version the current
   docs cite for the accepted CVEs (CVE-2025-47907 etc.). If a binary is built
   with an older toolchain, do not adopt it — keep that tool source-built and
   document why.
3. **Missing/insufficient metadata blocks adoption (hard rule).** If
   `go version -m` is absent, stripped, or does not expose a module version needed
   to prove a documented CVE fix (e.g. go-getter for Trivy, x/crypto for kubesec),
   the release binary is **not** adopted on the strength of "recorded what was
   available." Adoption then requires one of: (a) a primary-source proof of the
   same fact — upstream SBOM, signed provenance/SLSA attestation, or the release
   build log naming the toolchain/module versions; or (b) keeping that specific
   tool source-built as a fallback. Soft absence is never sufficient.
4. The PR Trivy scan (§4.6) must pass with the reduced `.trivyignore` (§4.9). A
   new fixed HIGH/CRITICAL that the old source build suppressed blocks the change.
5. README/security-doc CVE claims are rewritten to match what is actually
   verified (cite measured toolchain/module versions and the proof source, not the
   removed build stage).

### 4.8 Smoke-test tool list

`node`, `pnpm`, `python3`, `uv`, `go`, `terraform`, `kubectl`, `helm`, `doctl`,
`docker`, `docker buildx`, `docker compose`, `gh`, `aws`, `trivy`, `kubeconform`,
`kubesec`, `psql`, `redis-cli`, `bc`; plus Python import of `pytest_mock`.
kubectl/doctl/kubesec must report non-`0.0.0` release versions. Docker CLI
version is asserted ≥ the CVE-2025-54388 minimum (28.3.3).

### 4.9 .trivyignore and floating-package policy

- **`.trivyignore`:** remove the `/tmp/unified-go-build` and `/go/pkg/mod`
  entries (no builder stage remains). Re-examine every remaining broad ignore
  (docs, examples, markdown, text, node_modules, vendor) and keep only those with
  a documented reason. **Reconsider `/usr/local/go/**`:** Go is now a first-class
  runtime dependency whose CVEs matter; the goal is to scan the Go runtime, not
  blanket-ignore it. If a narrow ignore is still required to suppress a specific
  false positive, document the exact reason; otherwise drop it.
- **Floating vs pinned apt packages (explicit policy):** Docker CLI
  (`docker-ce-cli`) and GitHub CLI (`gh`) are installed from their official apt
  repos and are intentionally **distro-floating to the repo's current stable**,
  because they are security-sensitive and we want upstream fixes; the smoke test
  asserts the Docker CLI CVE-2025-54388 minimum so a regression fails the build.
  `postgresql-client`, `redis-tools`, `bc`, `libmagic1`, `gettext-base`,
  `libpq-dev` are Ubuntu-archive packages left distro-floating (low CVE
  sensitivity, no consumer version dependency). This policy is stated in README.

### 4.10 New tools added

- `uv` 0.11.17 — astral release tarball into `/usr/local/bin`, SHA256-verified.
- AWS CLI v2 2.34.57 — `awscli-exe` bundle, GPG-verified (§4.3).
- `bc`, `libmagic1` — apt, in the existing runtime-deps layer.
- `pytest-mock` — added to the python-builder pip install line.

### 4.11 PowerShell

Not installed. Documented as an intentional exclusion in README. The AuroLegal
consumer issue notes that any `run.ps1` parity should be a Linux-equivalent shell
script in that repo, not pwsh in the image.

### 4.12 CRLF fix

Add `.gitattributes` at repo root:
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
```
Then `git add --renormalize .`. Verify with `git ls-files --eol` that every
`test/*.sh`, `scripts/*.sh`, `docker/*.sh`, `deploy/*.sh`, and
`.github/workflows/*.yml` shows `i/lf`, and that no binary/cert fixture was
accidentally normalized. Run `bash -n` on all shell scripts post-normalization.

### 4.13 Workflow, test, and doc updates

- `build-runner-image.yml`: §4.6 changes (load+local-tag, PR smoke+Trivy, drop
  Go-absent checks).
- `test/verify-tools.sh`, `test/verify-go-runtime.sh`,
  `test/verify-docker-version.sh`, `test/verify-security-fixes.sh`: update
  expected versions (Go 1.26.3, kubectl 1.36.1, etc.); add `uv`, `aws`, `bc`,
  `pytest-mock`.
- `README.md`: tool list + versions, "last version check 2026-05-31", the
  release-binary strategy, uv/AWS CLI (incl. key-rotation note), pwsh exclusion,
  the floating-package policy (§4.9).
- `docs/DOCKERFILE-SECURITY-REFACTOR.md`, `docs/GO-RUNTIME-FIX.md`: rewrite to the
  release-binary approach + Go 1.26.3 runtime; CVE claims reflect §4.7 measured
  results, not the removed source-build stage.

### 4.14 Verification (Workstream A)

Docker is available locally (29.5.2). Before opening the PR:
1. `docker build -f docker/Dockerfile.custom-runner ./docker` succeeds locally.
2. Local in-image smoke test (§4.8) passes, including meaningful versions and the
   §4.7 `go version -m` inspection.
3. `bash -n` on all shell scripts after CRLF normalization; `git ls-files --eol`
   check.
4. Local Trivy scan of the built image with the reduced `.trivyignore`.
5. CI green on the PR: build + **PR smoke test** + **PR Trivy scan** (§4.6).

AuroLegal backend/frontend image builds from inside the runner image (an
acceptance criterion) need the `defender.ai` repo and a socket-mounted run.
This is performed as an explicit local validation step and recorded in the PR
description with the exact commands run and observed result; it is reported
honestly and not asserted from CI (CI cannot access that repo). The
implementation plan provides a copy-paste command template; expected shape:

```
# from the runner image, with the host docker socket mounted and defender.ai checked out
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v <path-to>/defender.ai:/work -w /work \
  registry.digitalocean.com/redducklabs/github-runner:<pr-tag> \
  bash -lc 'docker build -f backend/Dockerfile -t aurolegal-backend:verify backend/ \
            && docker build -f frontend/Dockerfile -t aurolegal-frontend:verify frontend/'
```

Success = both `docker build` invocations exit 0 and produce the two images. The
exact Dockerfile paths/build args are confirmed against the defender.ai repo at
implementation time and the final command + output pasted into the PR note.

## 5. Risks

- **Terraform 1.15.5 vs consumer pins.** Mitigated by not changing consumer
  repos here; their issues instruct keeping `setup-terraform` pins. The image's
  terraform is a convenience default only.
- **AWS CLI key expiry (2026-07-07).** Handled by §4.3 fingerprint pin + rotation
  doc; fail-loud on expiry is intended.
- **Release binary CVE regression.** Caught by the §4.7 gate + PR Trivy scan
  before the source build is removed.
- **Local-only AuroLegal validation.** Reported honestly with commands/results in
  the PR; CI cannot run it.

## 6. Deferred: build-layer caching (separate spec/issue)

A build-layer cache (in-cluster Docker registry pull-through mirror) is deferred
to its own design and PR. Round-1 review established it is not minimal under ARC
`containerMode: dind`: it requires an ARC-compatible way to set the dind daemon
config (daemon.json via ConfigMap mount into the dind sidecar, or a full dind
template override), a NetworkPolicy restricting an otherwise-unauthenticated
in-cluster `registry:2` to runner/dind pods, a `Recreate` Deployment strategy and
sized `do-block-storage` RWO PVC, a pinned registry image digest, and no upstream
Docker Hub credentials. A separate issue will track it; this image refresh neither
depends on nor blocks it.

## 7. Appendix — checksum provenance

All versions/checksums confirmed 2026-05-31 via official sources:
- Go: `https://go.dev/dl/?mode=json` (linux-amd64 sha256).
- kubectl: `https://dl.k8s.io/release/stable.txt` + `…/kubectl.sha256`.
- doctl: `gh release download v1.160.0 --repo digitalocean/doctl --pattern
  doctl-1.160.0-checksums.sha256`.
- Helm: `https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz.sha256sum`.
- kubeconform: `gh release download v0.7.0 --repo yannh/kubeconform --pattern
  CHECKSUMS`.
- kubesec: `gh release download v2.14.2 --repo controlplaneio/kubesec --pattern
  kubesec_checksums.txt`.
- Trivy: `gh release download v0.70.0 --repo aquasecurity/trivy --pattern
  trivy_0.70.0_checksums.txt`.
- buildx: `gh release download v0.34.1 --repo docker/buildx --pattern
  checksums.txt`.
- uv: `gh release download 0.11.17 --repo astral-sh/uv --pattern
  uv-x86_64-unknown-linux-gnu.tar.gz.sha256`.
- python-build-standalone: `gh release download 20260510 --repo
  astral-sh/python-build-standalone --pattern SHA256SUMS`.
- Node/Terraform: exact apt package versions and keyring fingerprints discovered
  at implementation time and recorded in the Dockerfile (exact-pin).
- Docker CLI / gh: keyring fingerprints recorded in the Dockerfile; package
  versions are approved-floating (§4.2, §4.9) with a smoke-test version floor.
- AWS CLI v2: bundle `https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.34.57.zip`,
  signature `…-2.34.57.zip.sig`; public key from the AWS CLI install guide
  (`https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html`);
  pinned full fingerprint
  `FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C` (Key ID `A6310ACC4672475C`),
  confirmed 2026-05-31. Documented expiry 2026-07-07 (§4.3).

## 8. Acceptance criteria (from issue #12)

- [ ] Local Docker build of `docker/Dockerfile.custom-runner` succeeds.
- [ ] Smoke test (§4.8) verifies node, pnpm, python3, uv, go, terraform, kubectl,
      helm, doctl, docker, docker buildx, docker compose, gh, aws, trivy,
      kubeconform, kubesec, psql, redis-cli (plus bc, pytest-mock) — enforced on
      the PR build (§4.6).
- [ ] kubectl, doctl, kubesec report meaningful release versions.
- [ ] AuroLegal backend and frontend images build from inside the runner image
      (local validation recorded in PR; §4.14).
- [ ] Trivy scan: no fixed HIGH/CRITICAL except documented accepted base-image
      risks — enforced on the PR build.
- [ ] Test scripts run on Linux without CRLF failures; `.gitattributes` guards
      future reintroduction.
- [ ] README, security docs, and verification scripts match actual installed
      versions and the release-binary strategy (CVE claims reflect §4.7).
