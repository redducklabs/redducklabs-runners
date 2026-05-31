# Codex Review Process

Read this before finalizing a spec or plan that will guide implementation, and
before merging a PR when a Codex review gate is requested or required for the
work.

Codex is an independent reviewer. It should be asked to be critical about
security, correctness, best practices, and this repository's standards. A review
is complete only when the latest review ends with:

```text
VERDICT: APPROVED
```

If the latest review ends with:

```text
VERDICT: CHANGES REQUESTED
```

address every finding by changing the work or documenting a concrete technical
justification, then request another review.

## Review Directory

All Codex review artifacts are written to:

```text
temp/codex-reviews/
```

The repository ignores `temp/`, so these files are local working artifacts and
must not be committed.

File naming convention:

| Surface | File pattern | Example |
|---|---|---|
| Spec | `temp/codex-reviews/<spec-slug>-spec-review-<N>.md` | `temp/codex-reviews/2026-05-31-runner-scaling-spec-review-1.md` |
| Plan | `temp/codex-reviews/<plan-slug>-plan-review-<N>.md` | `temp/codex-reviews/2026-05-31-runner-scaling-plan-review-1.md` |
| PR | `temp/codex-reviews/pr-<number>-review-<N>.md` | `temp/codex-reviews/pr-42-review-1.md` |

`<N>` starts at `1` and increments on every re-review.

## Path Translation

Codex often runs in WSL even when the user thinks in Windows paths. Derive paths
from the current repository root instead of hardcoding an absolute path.

Rules:

- If the current repo is shown as a Windows path, translate it to WSL for Codex
  `cwd`: `D:\repos\redducklabs-runners` becomes
  `/mnt/d/repos/redducklabs-runners`.
- If the current repo is already a WSL path, use that path as `cwd`.
- The Codex `cwd` is the only absolute path in the call.
- Put repo-relative paths in prompts and commands, such as
  `docs/specs/...`, `docs/plans/...`, and `temp/codex-reviews/...`.
- Do not put absolute Windows or WSL paths inside the review prompt body.

## Required Review Standard

Every review prompt must tell Codex to be a critical reviewer across:

- Security: secrets handling, GitHub token handling, workflow permissions,
  Kubernetes RBAC, registry credentials, image supply chain, destructive
  operations, and data exposure.
- Correctness: logic errors, workflow trigger mistakes, shell quoting, unsafe
  defaults, missing failure handling, wrong assumptions, and missing tests.
- Best practices: maintainability, least privilege, clear scripts, no silent
  error suppression, and no needless complexity.
- Project standards: conformance to `CLAUDE.md`, `AGENTS.md`, relevant
  `claude_help/` files, and project docs.

Every finding should carry one severity tag:

```text
[BLOCKER] [MAJOR] [MINOR] [NIT]
```

Treat `[BLOCKER]` and `[MAJOR]` findings as mandatory to resolve before
approval.

## Spec Or Plan Review

Specs live in:

```text
docs/specs/YYYY-MM-DD-<topic>-design.md
```

Plans live in:

```text
docs/plans/YYYY-MM-DD-<topic>.md
```

Loop:

1. Write the spec or plan.
2. Self-review it for security, production impact, and missing verification.
3. Ask Codex to review it and write
   `temp/codex-reviews/<slug>-{spec|plan}-review-1.md`.
4. Read the review file.
5. Address every finding.
6. Ask for re-review, incrementing the review filename.
7. Continue until the latest review ends with `VERDICT: APPROVED`.

Starter prompt:

```text
You are a critical reviewer. Be hard on this work and do not rubber-stamp it.

Review the {spec|plan} at <repo-relative-path>. First read CLAUDE.md,
AGENTS.md, and the relevant files under claude_help/ and docs/, and hold this
work to those project standards.

Review across security, correctness, best practices, and project standards.
Tag every finding [BLOCKER], [MAJOR], [MINOR], or [NIT].

Write your full review to temp/codex-reviews/<slug>-{spec|plan}-review-1.md.
End the file with exactly one line: VERDICT: CHANGES REQUESTED or
VERDICT: APPROVED. Approve only if there are no [BLOCKER] or [MAJOR] findings.
```

## PR Review

Codex PR review is an additional gate; it does not replace CI, Copilot, or human
review.

Loop:

1. Ensure the PR branch is checked out locally.
2. Ask Codex to fetch `origin main`, diff `origin/main...HEAD`, and review the
   PR critically.
3. Ask Codex to write `temp/codex-reviews/pr-<number>-review-1.md`, and when
   appropriate, post findings on the PR with `gh`.
4. Read the review file and PR comments.
5. Address every finding by fixing the code or replying with a concrete
   justification.
6. Re-run the relevant local checks and push if code changed.
7. Ask for re-review, incrementing the review filename.
8. Continue until the latest review ends with `VERDICT: APPROVED`.

Starter prompt:

```text
You are a critical reviewer. Be hard on this PR and do not rubber-stamp it.

Review PR #<number> in <owner>/<repo>. The branch is checked out in the
working tree. Run: git fetch origin main && git diff origin/main...HEAD.
First read CLAUDE.md, AGENTS.md, and the relevant claude_help/ and docs/ files,
and hold the change to those standards.

Review across security, correctness, best practices, and project standards.
Tag every finding [BLOCKER], [MAJOR], [MINOR], or [NIT].

Write the full review to temp/codex-reviews/pr-<number>-review-1.md. If you
post to GitHub, use gh and include a PR summary comment plus line-specific
comments where useful. End the review file with exactly one line:
VERDICT: CHANGES REQUESTED or VERDICT: APPROVED. Approve only if there are no
[BLOCKER] or [MAJOR] findings.
```

## Re-Review Prompt

Use the same conversation when possible:

```text
I addressed your previous review. Changes: <bullet list of fixes and any
justifications for findings not changed>. Re-review the updated {spec|plan|PR}.
Write the new review to <next-review-file>. End with the VERDICT line as
before.
```

## Rule

A reviewed spec, plan, or PR is not ready until the latest Codex review file
ends with `VERDICT: APPROVED`.
