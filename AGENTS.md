# Red Duck Labs Runners Codex Instructions

This repository's project operating rules live in `CLAUDE.md`. Treat that file
as the source of truth for repo-specific behavior.

Before making code changes, running tests, creating commits, touching GitHub,
working with Docker, Kubernetes, DigitalOcean, GitHub Actions, runner
configuration, security documentation, or deployment-sensitive code, read and
follow `CLAUDE.md` and any relevant files under `claude_help/` and `docs/`.

Codex-specific adapter rules:

- Do not modify `CLAUDE.md` or Claude-specific setup files unless the user
  explicitly asks.
- Do not deploy, scale, emergency-stop, or otherwise mutate the live runner
  fleet from the local machine unless the user explicitly asks for that exact
  operation.
- Never print or expose `.env` values, tokens, registry credentials,
  kubeconfigs, Kubernetes Secret payloads, private keys, or certificates.
- Use `gh` for GitHub operations. Verify `gh auth status` before assuming
  credentials are unavailable.
- For GitHub Actions workflow work, inspect `.github/workflows/` and keep
  workflow permissions narrowly scoped.
- For Docker image changes, read `README.md`, `docs/security/vulnerability-dismissals.md`,
  `docs/toolchain/go-runtime.md`, and `docs/toolchain/dockerfile-security-refactor.md` as
  relevant.
- For deployment or Kubernetes changes, read `docs/SETUP.md` and the relevant
  scripts/configuration under `deploy/` before editing.
- For security-related changes, read `docs/SECURITY.md`,
  `docs/security/validation-plan.md`, and `docs/security/vulnerability-dismissals.md` as
  relevant.
- Do not claim tests, builds, workflows, or deployments pass unless the relevant
  command or workflow actually ran successfully.
- MCP servers are configured in Codex user config, not in this repository. If a
  Claude MCP config is added later, keep it for Claude and register equivalent
  servers separately with `codex mcp add` / `codex mcp login`.
