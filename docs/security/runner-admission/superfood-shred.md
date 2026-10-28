# Runner admission evidence: superfood-shred

| Field | Value |
| --- | --- |
| Repository | `redducklabs/superfood-shred` |
| Immutable ID | `1418079240` |
| Manifest entry | `1418079240:superfood-shred` in `deploy/trusted-runner-repositories.txt` |
| Runner group | `redducklabs-private-runners` (`visibility=selected`, public access disabled) |
| Evidence first gathered | 2026-10-26 |
| Evidence re-verified (read-only `gh api`) | 2026-10-27 |
| Audited `main` commit | `0e5799ae37973dbfcd91112231910bb69a99dde8` |
| Audited migration commit | `a01d5b55491903df404b160278b726c8826394b9` (branch `ci/migrate-ci-to-rdl-runners`) |

## Repository visibility

`GET /repositories/1418079240` returned `full_name=redducklabs/superfood-shred`,
`visibility=private`, `private=true`, owner `redducklabs`, default branch
`main`. The organization's `members_can_fork_private_repositories` is `false`.

## Fork-PR workflow policy

`GET /repos/redducklabs/superfood-shred/actions/permissions/fork-pr-workflows-private-repos`:

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

Collaborators (`GET /repos/redducklabs/superfood-shred/collaborators?affiliation=all`):

| Login | Role |
| --- | --- |
| `aronweiler` | admin (owner) |
| one write collaborator besides the owner (accepted by the owner as a trusted co-tenant on 2026-10-26) | write (organization member) |

No outside collaborators, no team grants, and no pending invitations. The
organization's default repository permission is `none`.

The write collaborator can push branches whose workflows run on the fleet. The
owner accepted that collaborator as a trusted co-tenant of the privileged runner
nodes on 2026-10-26. That acceptance is recorded in
`docs/security/vulnerability-dismissals.md` (AOR-2).

## Workflow trigger audit

Every file under `.github/workflows/` was read at both audited commits. The
workflow set is the same at both: `ci.yml`, `deploy.yml`,
`mobile-store-release.yml`, `terraform.yml`.

- `pull_request_target`: not used in any workflow.
- `workflow_run`: not used in any workflow.
- Reusable-workflow calls (`jobs.<id>.uses`, `workflow_call`): none.
- Local actions (`uses: ./...`): none.

Triggers: `ci.yml` runs on `push` and `pull_request`; `terraform.yml` on
`pull_request` and `workflow_dispatch`; `deploy.yml` and
`mobile-store-release.yml` on `push` and `workflow_dispatch`.

## Jobs that will select `redducklabs-runners`

From the migration commit. Both workflows have top-level
`permissions: contents: read`. None of these jobs references a repository
secret or an environment.

| Workflow | Job ID | Notes |
| --- | --- | --- |
| `ci.yml` | `backend` | no secrets |
| `ci.yml` | `workspace` | no secrets |
| `terraform.yml` | `validate` | `pull_request` only; `terraform init -backend=false`; no secrets |

Every other job stays on GitHub-hosted runners, including every job that holds
deploy credentials: `terraform.yml` `apply` (DigitalOcean token and Spaces
keys, `production` environment), `deploy.yml` `build-push` and `deploy`
(`production` environment), and `mobile-store-release.yml` `android` and `ios`
(`production` environment). `mobile-store-release.yml` `release-notes` also
stays hosted.

## Decision

Admitted 2026-10-26 by the repository owner, with the one write collaborator
besides the owner accepted as a trusted co-tenant. Re-evaluate before any change to the fork-PR policy, before
granting another collaborator write access, before adding a
`pull_request_target` or `workflow_run` trigger, or before moving a job that
holds deploy credentials onto the fleet.
