# Codex Setup

Use this guide when onboarding Codex for this repository.

## Concepts

| Claude Code | Codex |
|---|---|
| Repo `CLAUDE.md` | Repo `AGENTS.md` |
| User-level `CLAUDE.md` | User-level `~/.codex/AGENTS.md` |
| `.mcp.json` | `codex mcp add` entries in Codex user config |
| Claude MCP auth | MCP-specific Codex login commands |

Codex does not read `.mcp.json`. Keep any Claude MCP config for Claude and
register the same MCP servers separately for Codex.

## Repo Instructions

This repo uses:

```text
CLAUDE.md
AGENTS.md
claude_help/codex-review-process.md
```

`CLAUDE.md` is the source of truth for project rules. `AGENTS.md` is a thin
Codex adapter that points Codex at those rules and adds Codex-specific notes.

## Register MCP Servers

Configure shared documentation and browser automation MCP servers if you use
those workflows:

```bash
codex mcp add context7 -- npx -y @upstash/context7-mcp@latest
codex mcp add playwright -- npx -y @playwright/mcp@latest --browser firefox
codex mcp list
```

Configure ClickUp only if this workspace uses ClickUp MCP:

```bash
codex mcp add clickup --url https://mcp.clickup.com/mcp
codex mcp login clickup
codex mcp list
```

This repository does not require a project-specific Postgres MCP server.

## Launch Codex From The Repo

Use the launcher so Codex starts from the repository root:

```bash
./scripts/launch-codex.sh
```

The launcher forwards all arguments to `codex`:

```bash
./scripts/launch-codex.sh --search
```

Restart Codex after changing MCP configuration.

## Install GitHub CLI

Codex workflows that need GitHub access should use `gh`.

Ubuntu's default package may lag behind GitHub CLI releases. In WSL on Ubuntu,
the distro package can authenticate but still miss newer commands such as
`gh project`. Prefer GitHub CLI's official apt repository.

From this repo, run:

```bash
./docs/codex/update-gh-cli.sh
```

The script adds the official signed GitHub CLI apt repository, installs or
updates `gh`, and then checks:

```bash
gh --version
gh auth status
gh project list --owner redducklabs
```

If doing the setup manually:

```bash
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install -y gh
```

Authenticate in the same WSL environment where Codex runs:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth status
```

Authenticate with scopes needed for private repos, workflows, organizations,
and Projects:

```bash
gh auth refresh --hostname github.com --scopes project
gh auth status
```

Expected scopes include:

```text
gist, project, read:org, repo, workflow
```

Verify Projects support:

```bash
gh project list --owner redducklabs
```

If `gh project` is unknown, the old distro package is still installed or first
on `PATH`; rerun `./docs/codex/update-gh-cli.sh` and check `command -v gh`.

## Configure Git Hooks In WSL

If this repo later enables local Git hooks, install them inside the same WSL
environment where Codex runs. Hooks installed from Windows can contain Windows
paths or CRLF line endings and fail from WSL with:

```text
fatal: cannot run .git/hooks/pre-commit: No such file or directory
```

Do not commit `.git/hooks/*`; Git hooks are local repository metadata.

## Install Global Codex Instructions

Codex global instructions live at:

```text
~/.codex/AGENTS.md
```

Required adaptations from a Claude baseline:

- Rename Claude-specific framing to Codex and `AGENTS.md`.
- Replace Claude-only tool names with Codex equivalents.
- Do not assume Claude sub-agent names exist in Codex.
- Keep the core safety rules: honest verification, no secrets, no AI
  attribution, no unsolicited time estimates, secure defaults, and technical
  pushback.
- Keep GitHub guidance as `gh`-first.
- Use available MCP/docs tools and official current sources for versioned APIs,
  libraries, cloud services, and platform behavior.

After writing `~/.codex/AGENTS.md`, restart Codex.

## Verify

From this repo:

```bash
codex mcp list
gh auth status
test -f CLAUDE.md
test -f AGENTS.md
test -f ~/.codex/AGENTS.md
```

Then start Codex from the repo root:

```bash
cd /mnt/h/repos/redducklabs-runners
./scripts/launch-codex.sh
```
