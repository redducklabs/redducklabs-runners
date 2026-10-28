# Runner admission evidence: keel

| Field | Value |
| --- | --- |
| Repository | `redducklabs/keel` |
| Immutable ID | `1425956382` |
| Manifest entry | `1425956382:keel` in `deploy/trusted-runner-repositories.txt` |
| Runner group | `redducklabs-private-runners` (`visibility=selected`, public access disabled) |
| Evidence first gathered | 2026-10-26 |
| Evidence re-verified (read-only `gh api`) | 2026-10-27 |
| Audited `main` commit | `8cd91e7897b6867f5c29f63fcf04dfd75be4abb5` |
| Audited migration commit | `9e47bd820a0d40a904cdd107d5a38bf1651d77b8` (branch `ci/migrate-ci-to-rdl-runners`, draft PR redducklabs/keel#208) |

## Repository visibility

`GET /repositories/1425956382` returned `full_name=redducklabs/keel`,
`visibility=private`, `private=true`, owner `redducklabs`, default branch
`main`. The organization's `members_can_fork_private_repositories` is `false`.

## Fork-PR workflow policy

`GET /repos/redducklabs/keel/actions/permissions/fork-pr-workflows-private-repos`:

```json
{
  "run_workflows_from_fork_pull_requests": false,
  "send_write_tokens_to_workflows": false,
  "send_secrets_and_variables": false,
  "require_approval_for_fork_pr_workflows": false
}
```

Required value: `run_workflows_from_fork_pull_requests` is the boolean
`false`. `scripts/verify-runner-trust-boundary.sh` re-reads this policy for every
private member on each `prepare-trust-boundary` run and on each verify-only
readback, and fails closed before any runner-group request when the value is
anything other than the boolean `false`.

## Collaborators with write access

Collaborators (`GET /repos/redducklabs/keel/collaborators?affiliation=all`):

| Login | Role |
| --- | --- |
| `aronweiler` | admin (owner) |

No outside collaborators, no team grants, and no pending invitations. The
organization's default repository permission is `none`.

## Workflow trigger audit

Every file under `.github/workflows/` was read at both audited commits. The
workflow set is the same at both: `base-image-check.yml`, `ci.yml`,
`cutover-rehearsal.yml`, `infra-apply.yml`, `infra-plan.yml`, `release.yml`,
`restore-test.yml`, `waf-probe.yml`.

- `pull_request_target`: not used in any workflow.
- `workflow_run`: not used as a trigger in any workflow. (`ci.yml` reads the
  `workflow_runs` field of the Actions API to find main's last passing CI run;
  that is a read, not a trigger.)
- Reusable-workflow calls (`jobs.<id>.uses`, `workflow_call`): none.
- Local actions (`uses: ./...`): none.

Triggers: `ci.yml` runs on `pull_request`, `push`, and `merge_group`;
`infra-plan.yml` on `pull_request`; `infra-apply.yml` and `release.yml` on
`push` (and `workflow_dispatch` for release); the rest on `schedule` or
`workflow_dispatch`.

## Jobs that will select `redducklabs-runners`

From `ci.yml` at the migration commit. The workflow has top-level
`permissions: contents: read`; `Changed areas` adds `actions: read`. None of
these jobs references a repository secret, an environment, or `id-token: write`.
The only token they hold is the read-scoped `github.token`.

| Job ID | Job name |
| --- | --- |
| `changes` | Changed areas |
| `quick` | Quick checks |
| `design` | Design tokens |
| `infra-static` | Infra static checks |
| `infra-tests` | Infra tests |
| `wrapper-bash` | Terraform wrapper and web upload (bash) |
| `backend` | Backend |
| `frontend` | Frontend |
| `e2e` | End-to-end |
| `no-trackers` | No trackers |
| `result` | CI result |

Every other job stays on GitHub-hosted runners: `wrapper-powershell` (Windows)
and `lambda-image` (arm64 image build) in `ci.yml`, every job in the other seven
workflows, and so every job that holds deploy credentials (`infra-plan.yml`
`plan`, `infra-apply.yml` `apply`, `release.yml` `release`, `restore-test.yml`
`restore`, and `cutover-rehearsal.yml` `rehearse`, each with `id-token: write`
and, except `plan`, a deployment environment).

## Decision

Admitted 2026-10-26 by the repository owner. Re-evaluate before any change to
the fork-PR policy, before granting another collaborator write access, before
adding a `pull_request_target` or `workflow_run` trigger, or before moving a
job that holds deploy credentials onto the fleet.
