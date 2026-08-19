# Red Duck Labs Runners Project Instructions

This repository manages Red Duck Labs GitHub Actions self-hosted runners on
Kubernetes, including the custom runner image, ARC runner scale set deployment,
GitHub Actions workflows, operational scripts, and security documentation.

## Operating Principles

- Prefer GitHub Actions workflows for deployment and runner management. Do not
  deploy, scale, emergency-stop, or mutate the live Kubernetes runner fleet from
  a local machine unless the user explicitly asks for that exact operation.
- Treat this as infrastructure code. Changes that affect Docker images,
  Kubernetes manifests, GitHub Actions workflows, DigitalOcean registry access,
  runner tokens, or production scripts require security-minded review.
- Never print, commit, or expose tokens, registry credentials, kubeconfigs,
  `.env` values, private keys, certificates, or secrets.
- Do not create or modify `.env` files unless the user explicitly asks for that
  exact file change. Use `.env.example` for documented configuration defaults.
- Preserve existing production defaults unless the user asks to change them:
  organization `redducklabs`, namespace `arc-runners`, runner label
  `redducklabs-runners`, release name `redducklabs-runners`, and DigitalOcean
  registry namespace `redducklabs`.
- Do not weaken security scans, permissions, confirmation prompts, or secret
  handling to make checks pass. Fix the root cause or document the accepted risk
  in the established security docs.

## Repository Map

- `.github/workflows/` - GitHub Actions workflows for building images,
  deploying runners, scaling, status checks, and emergency stop.
- `.github/actions/setup-tools/` - shared workflow action for installing tools.
- `docker/` - custom runner Dockerfile and image build scripts.
- `deploy/` - ARC runner scale set configuration and deployment scripts.
- `scripts/` - local operational helpers for scaling, admin actions, emergency
  stop, and vulnerability alert dismissal.
- `test/` - shell-based verification scripts for deployment, tools, Docker, Go,
  and security fixes.
- `docs/` - setup, security, contribution, and implementation documentation.
- `claude_help/` - project operating process docs for Claude/Codex workflows.

## Development Commands

Run commands from the repository root unless the script documentation says
otherwise.

```bash
# Verify runner image tools in a running pod or test environment
./test/verify-tools.sh

# Deployment verification
./test/test-deployment.sh

# Runner memory reservations and the one-pod-per-node invariant.
# Renders deploy/dind-values.yaml with Helm; needs no cluster access.
./test/verify-runner-resources.sh

# Security and runtime verification
./test/verify-docker-version.sh
./test/verify-go-runtime.sh
./test/verify-security-fixes.sh

# Local runner operations, only when explicitly requested
./scripts/scale-runners.sh status
./scripts/runner-admin.sh
./scripts/emergency-stop.sh
```

For Docker image work:

```bash
cd docker
docker build -t test-runner -f Dockerfile.custom-runner .
```

For workflow and YAML-only changes, inspect the affected workflow syntax and
prefer a targeted local validation command if available. Do not claim GitHub
Actions workflows pass unless they have actually run successfully.

## GitHub And Deployment

- Use `gh` for GitHub operations. Run `gh auth status` before assuming
  credentials are unavailable.
- Do not merge PRs with failing checks.
- Do not deploy from the local machine when the expected path is CI/CD.
- Do not trigger production deployment, scale, or emergency-stop workflows
  unless the user explicitly asks.
- For workflow changes, verify the changed workflow names and triggers under
  `.github/workflows/` and keep permissions scoped to the minimum needed.

## Kubernetes And DigitalOcean

- Do not run state-mutating `kubectl`, `helm`, or `doctl` commands against the
  production cluster unless explicitly requested.
- Read-only inspection commands are acceptable for investigation, but avoid
  printing secret data. Do not run commands that reveal Kubernetes Secret
  payloads.
- The production cluster context documented in this repo is
  `do-sfo3-redducklabs-cluster`; do not assume the current kube context is safe.
- Any changes to `deploy/dind-values.yaml`, `deploy/deploy.sh`,
  `.github/workflows/deploy-runners.yml`, or emergency/scale workflows require
  careful review for production impact.

## Docker Image And Toolchain

- The custom runner image is expected to include Python, Node.js, Terraform,
  kubectl, Helm, doctl, Docker CLI/buildx, GitHub CLI, Trivy, kubeconform, and
  kubesec as documented in `README.md`.
- When changing `docker/Dockerfile.custom-runner`, preserve the security intent
  documented in `docs/security/vulnerability-dismissals.md`, `docs/toolchain/go-runtime.md`, and
  `docs/toolchain/dockerfile-security-refactor.md`.
- Do not downgrade tool versions or switch away from source builds used to
  address documented CVEs unless the user explicitly accepts the risk and the
  docs are updated.
- Keep scripts non-interactive where they are used by CI. Interactive
  confirmation is appropriate for destructive local scripts such as emergency
  stop.

## Testing And Verification

- Do not say tests pass unless the relevant test or workflow actually ran and
  passed.
- For Dockerfile changes, run at least a local Docker build when Docker is
  available. If Docker is unavailable, state that clearly.
- For script changes, run shell syntax checks and the most targeted safe command
  available. Avoid commands that mutate production unless explicitly requested.
- For deployment manifest changes, validate YAML and templates with available
  tooling; use Kubernetes dry-run or kubeconform when safe and applicable.
- For security changes, update and run the relevant scripts under `test/` where
  possible.

## Documentation

- Update `README.md`, `docs/SETUP.md`, `docs/SECURITY.md`, or related docs when
  behavior, commands, required secrets, versions, or operational workflows
  change.
- Design specs and implementation plans, when needed, should live in:
  - `docs/specs/YYYY-MM-DD-<topic>-design.md`
  - `docs/plans/YYYY-MM-DD-<topic>.md`
- Codex review artifacts are working files under `temp/codex-reviews/` and must
  not be committed.

## Source Control

- Keep changes scoped to the request.
- Do not revert unrelated user changes in a dirty worktree.
- Use conventional commit prefixes when asked to commit: `feat:`, `fix:`,
  `docs:`, `chore:`, `test:`, `ci:`.
- Do not add AI attribution to commits, PR titles, PR bodies, changelogs, or
  project documentation.

## Codex Reviews

Codex is used as an independent critical reviewer for significant specs, plans,
and PRs. Read `claude_help/codex-review-process.md` before finalizing a spec or
plan that will guide implementation, and before merging a PR when a Codex review
gate is requested or required for the work.

Reviews should be critical across security, correctness, best practices, and
project standards. Address every finding by changing the work or documenting a
concrete justification.
