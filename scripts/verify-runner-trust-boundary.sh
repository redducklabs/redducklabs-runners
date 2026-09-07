#!/usr/bin/env bash
set -euo pipefail

ORG=redducklabs
GROUP_NAME=redducklabs-private-runners
RUNNER_LABEL=redducklabs-runners
EXPECTED_SHA=""
VERIFY_ONLY=false

usage() {
    echo "Usage: $0 --expected-sha <40-character SHA> [--verify-only]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --expected-sha)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            EXPECTED_SHA=$2
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

ACTUAL_SHA=$(git rev-parse HEAD)
if ! [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: expected_sha must be a 40-character lower-case commit SHA" >&2
    exit 1
fi
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "ERROR: expected_sha ${EXPECTED_SHA} does not match checked-out SHA ${ACTUAL_SHA}" >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
TRUSTED_REPOSITORIES_FILE="${REPO_ROOT}/deploy/trusted-runner-repositories.txt"

for tool in gh jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool is unavailable: ${tool}" >&2
        exit 1
    fi
done

# `deploy/trusted-runner-repositories.txt` is the sole committed source of
# truth for private repositories allowed to schedule this privileged runner
# group. It is identity-bearing so a rename, transfer, deletion, duplicate, or
# visibility change fails closed before any runner-group mutation.
TRUSTED_REPOSITORIES=()

read_trusted_repositories() {
    local entry repo_id repo_name
    declare -A seen_ids=() seen_names=()

    if [ ! -f "${TRUSTED_REPOSITORIES_FILE}" ]; then
        echo "ERROR: trusted repository manifest is missing: ${TRUSTED_REPOSITORIES_FILE}" >&2
        return 1
    fi
    while IFS= read -r entry || [ -n "${entry}" ]; do
        if ! [[ "${entry}" =~ ^([0-9]+):([a-z0-9][a-z0-9.-]*)$ ]]; then
            echo "ERROR: trusted repository manifest contains an invalid identity entry" >&2
            return 1
        fi
        repo_id=${BASH_REMATCH[1]}
        repo_name=${BASH_REMATCH[2]}
        if [[ -n "${seen_ids[${repo_id}]+x}" || -n "${seen_names[${repo_name}]+x}" ]]; then
            echo "ERROR: trusted repository manifest contains a duplicate identity" >&2
            return 1
        fi
        seen_ids[${repo_id}]=1
        seen_names[${repo_name}]=1
        TRUSTED_REPOSITORIES+=("${entry}")
    done < "${TRUSTED_REPOSITORIES_FILE}"

    if [ "${#TRUSTED_REPOSITORIES[@]}" -ne 9 ]; then
        echo "ERROR: trusted repository manifest must contain exactly nine identities" >&2
        return 1
    fi
}

read_trusted_repositories || exit 1

# These public repositories are rollout prerequisites even when GitHub's public
# repository enumeration is incomplete or changes shape. Their committed IDs
# prevent a rename or transfer from silently changing what is audited.
REQUIRED_PUBLIC_MIGRATIONS=(
    '1359405097:agent-handoff-toolkit'
    '1271568186:fountainrank'
    '1208056940:claude-control'
)

EXPECTED_IDS_JSON=$(printf '%s\n' "${TRUSTED_REPOSITORIES[@]}" \
    | cut -d: -f1 | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')

github_read() {
    local description=$1
    shift
    local output
    if ! output=$(gh api "$@"); then
        echo "ERROR: GitHub read failed (${description}); verify RUNNER_TOKEN permission" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

encode_url_component() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

encode_url_path() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

parts = sys.argv[1].split("/")
if any(part in ("", ".", "..") for part in parts):
    raise SystemExit("workflow path contains an unsafe path segment")
print("/".join(quote(part, safe="") for part in parts))
PY
}

resolve_branch_head() {
    local repo_name=$1 default_branch=$2 encoded_org encoded_repo commits
    encoded_org=$(encode_url_component "$ORG")
    encoded_repo=$(encode_url_component "$repo_name")
    commits=$(github_read "default-branch head for ${repo_name}" --method GET \
        "repos/${encoded_org}/${encoded_repo}/commits" \
        -f "sha=${default_branch}" -f per_page=1) || return 1
    if ! jq -e 'type == "array" and length == 1 and (.[0].sha | test("^[0-9a-f]{40}$"))' \
        <<<"$commits" >/dev/null; then
        echo "ERROR: could not resolve one immutable default-branch head for ${repo_name}" >&2
        return 1
    fi
    jq -r '.[0].sha' <<<"$commits"
}

validate_public_identity() {
    local repository=$1 expected_id=$2 expected_name=$3 expected_branch=${4:-}
    jq -e --argjson id "$expected_id" --arg owner "$ORG" \
        --arg name "$expected_name" --arg branch "$expected_branch" '
        .id == $id
        and .owner.login == $owner
        and .name == $name
        and .full_name == ($owner + "/" + $name)
        and .visibility == "public"
        and .private == false
        and (.default_branch | type == "string" and length > 0)
        and ($branch == "" or .default_branch == $branch)
    ' <<<"$repository" >/dev/null
}

echo "Validating committed private repository identities..."
for entry in "${TRUSTED_REPOSITORIES[@]}"; do
    repo_id=${entry%%:*}
    repo_name=${entry#*:}
    repo_json=$(github_read "repository ${repo_name}" "/repositories/${repo_id}") || exit 1
    if ! jq -e \
        --argjson id "$repo_id" \
        --arg owner "$ORG" \
        --arg name "$repo_name" \
        '.id == $id
         and .owner.login == $owner
         and .name == $name
         and .full_name == ($owner + "/" + $name)
         and .visibility == "private"
         and .private == true' \
        <<<"$repo_json" >/dev/null; then
        echo "ERROR: committed repository identity ${repo_id}:${repo_name} is unknown, transferred, renamed, or not private" >&2
        exit 1
    fi
done

echo "Scanning public organization workflows for privileged runner selection..."
public_pages=$(github_read "public repository enumeration" --paginate \
    "orgs/${ORG}/repos?type=public&per_page=100") || exit 1
if ! public_repos=$(jq -sc 'add // []' <<<"$public_pages"); then
    echo "ERROR: public repository enumeration returned an unrecognized schema" >&2
    exit 1
fi
if ! jq -e --arg owner "$ORG" '
    type == "array"
    and all(.[].id; type == "number")
    and ([.[].id] | unique | length) == length
    and all(.[];
        .owner.login == $owner
        and .full_name == ($owner + "/" + .name)
        and .visibility == "public"
        and .private == false
        and (.name | type == "string" and length > 0)
        and (.default_branch | type == "string" and length > 0))
' \
    <<<"$public_repos" >/dev/null; then
    echo "ERROR: public repository enumeration returned an unrecognized schema" >&2
    exit 1
fi

required_public='[]'
for entry in "${REQUIRED_PUBLIC_MIGRATIONS[@]}"; do
    repo_id=${entry%%:*}
    repo_name=${entry#*:}
    repo_json=$(github_read "required migration repository ${repo_name}" \
        "/repositories/${repo_id}") || exit 1
    if ! validate_public_identity "$repo_json" "$repo_id" "$repo_name"; then
        echo "ERROR: required migration identity ${repo_id}:${repo_name} is unknown, transferred, renamed, or not public" >&2
        exit 1
    fi
    required_public=$(jq -c --argjson repo "$repo_json" '. + [$repo]' \
        <<<"$required_public")
done

audit_repos=$(jq -cn --argjson enumerated "$public_repos" \
    --argjson required "$required_public" \
    '$enumerated + $required | unique_by(.id)')

while IFS=$'\t' read -r repo_id repo_name enumerated_branch; do
    [ -n "$repo_name" ] || continue
    initial_repo=$(github_read "repository snapshot for ${repo_name}" \
        "/repositories/${repo_id}") || exit 1
    if ! validate_public_identity "$initial_repo" "$repo_id" "$repo_name" \
      "$enumerated_branch"; then
        echo "ERROR: public repository identity/default branch changed before scan for ${repo_name}" >&2
        exit 1
    fi
    default_branch=$(jq -r '.default_branch' <<<"$initial_repo")
    head_sha=$(resolve_branch_head "$repo_name" "$default_branch") || exit 1
    workflow_pages=$(github_read "workflow enumeration for ${repo_name}" --paginate \
        "repos/$(encode_url_component "$ORG")/$(encode_url_component "$repo_name")/actions/workflows?per_page=100") || exit 1
    if ! jq -se '
        all(.[];
            type == "object"
            and (.workflows | type == "array")
            and all(.workflows[];
                (.path | type == "string") and (.state | type == "string")))
    ' <<<"$workflow_pages" >/dev/null; then
        echo "ERROR: workflow enumeration for ${repo_name} returned an unrecognized schema" >&2
        exit 1
    fi
    workflows=$(jq -sc '[.[].workflows[]]' <<<"$workflow_pages")

    while IFS= read -r workflow_path; do
        [ -n "$workflow_path" ] || continue
        if [ "$workflow_path" = "dynamic/agents/copilot-pull-request-reviewer" ]; then
            echo "Skipping GitHub-managed Copilot pull-request reviewer workflow for ${repo_name}"
            continue
        fi
        case "$workflow_path" in
            .github/workflows/*) ;;
            *)
                echo "ERROR: unsupported workflow path ${repo_name}:${workflow_path}; failing closed" >&2
                exit 1
                ;;
        esac
        workflow_file=$(mktemp)
        encoded_workflow_path=$(encode_url_path "$workflow_path")
        if ! gh api -H 'Accept: application/vnd.github.raw+json' \
            --method GET \
            "repos/$(encode_url_component "$ORG")/$(encode_url_component "$repo_name")/contents/${encoded_workflow_path}" \
            -f "ref=${head_sha}" >"$workflow_file"; then
            rm -f "$workflow_file"
            echo "ERROR: could not read public workflow ${repo_name}:${workflow_path}; failing closed" >&2
            exit 1
        fi

        parser_status=0
        python3 - "$workflow_file" "$RUNNER_LABEL" <<'PY' || parser_status=$?
import sys

import yaml

path, forbidden_label = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        document = yaml.safe_load(source)
except Exception:
    raise SystemExit(3)

if not isinstance(document, dict):
    raise SystemExit(3)
jobs = document.get("jobs", {})
if not isinstance(jobs, dict):
    raise SystemExit(3)

def values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from values(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from values(item)
    else:
        raise ValueError("unrecognized runs-on value")

for job_name, job in jobs.items():
    if not isinstance(job, dict) or "runs-on" not in job:
        continue
    try:
        selectors = list(values(job["runs-on"]))
    except ValueError:
        raise SystemExit(3)
    if any("${{" in selector for selector in selectors):
        print(f"dynamic runs-on expression in job {job_name}")
        raise SystemExit(2)
    if any(selector.strip().casefold() == forbidden_label.casefold() for selector in selectors):
        print(f"forbidden runner label {forbidden_label} in job {job_name}")
        raise SystemExit(2)
PY
        if [ "$parser_status" -ne 0 ]; then
            rm -f "$workflow_file"
            if [ "$parser_status" -eq 2 ]; then
                echo "ERROR: public workflow ${repo_name}:${workflow_path} selects ${RUNNER_LABEL} or has an unresolved dynamic runs-on expression" >&2
            else
                echo "ERROR: public workflow ${repo_name}:${workflow_path} could not be parsed safely" >&2
            fi
            exit 1
        fi
        rm -f "$workflow_file"
    done < <(jq -r '.[].path' <<<"$workflows")

    final_repo=$(github_read "repository readback for ${repo_name}" \
        "/repositories/${repo_id}") || exit 1
    if ! validate_public_identity "$final_repo" "$repo_id" "$repo_name" \
      "$default_branch"; then
        echo "ERROR: public repository identity/default branch changed during scan for ${repo_name}" >&2
        exit 1
    fi
    final_head=$(resolve_branch_head "$repo_name" "$default_branch") || exit 1
    if [ "$final_head" != "$head_sha" ]; then
        echo "ERROR: public repository default-branch head changed during scan for ${repo_name}" >&2
        exit 1
    fi
done < <(jq -r '.[] | [.id, .name, .default_branch] | @tsv' <<<"$audit_repos")

group_pages=$(github_read "runner-group enumeration" --paginate \
    "orgs/${ORG}/actions/runner-groups?per_page=100") || exit 1
if ! jq -se 'all(.[]; type == "object" and (.runner_groups | type == "array"))' \
    <<<"$group_pages" >/dev/null; then
    echo "ERROR: runner-group enumeration returned an unrecognized schema" >&2
    exit 1
fi
group_matches=$(jq -sc --arg name "$GROUP_NAME" '[.[].runner_groups[] | select(.name == $name)]' <<<"$group_pages")
group_count=$(jq 'length' <<<"$group_matches")
if [ "$group_count" -gt 1 ]; then
    echo "ERROR: multiple runner groups named ${GROUP_NAME}; refusing ambiguous mutation" >&2
    exit 1
fi

group_id=""
if [ "$group_count" -eq 1 ]; then
    group_id=$(jq -r '.[0].id' <<<"$group_matches")
    if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
        echo "ERROR: runner-group enumeration returned an invalid group identity" >&2
        exit 1
    fi
fi

if [ "$VERIFY_ONLY" = true ]; then
    if [ -z "$group_id" ]; then
        echo "ERROR: runner-group readback failed: ${GROUP_NAME} does not exist" >&2
        exit 1
    fi
elif [ -z "$group_id" ]; then
    create_payload=$(jq -cn \
        --arg name "$GROUP_NAME" \
        --argjson ids "$EXPECTED_IDS_JSON" \
        '{name:$name,visibility:"selected",allows_public_repositories:false,selected_repository_ids:$ids}')
    if ! create_response=$(gh api --method POST "orgs/${ORG}/actions/runner-groups" --input - <<<"$create_payload"); then
        echo "ERROR: runner-group creation failed; no cluster or provider mutation was attempted" >&2
        exit 1
    fi
    group_id=$(jq -r '.id // empty' <<<"$create_response")
    if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
        echo "ERROR: runner-group creation returned no readable group ID" >&2
        exit 1
    fi
else
    narrow_payload=$(jq -cn --arg name "$GROUP_NAME" \
        '{name:$name,visibility:"selected",allows_public_repositories:false}')
    if ! gh api --method PATCH "orgs/${ORG}/actions/runner-groups/${group_id}" \
        --input - <<<"$narrow_payload" >/dev/null; then
        echo "ERROR: runner-group permission narrowing failed; no Helm, cluster, or provider mutation was attempted" >&2
        exit 1
    fi

    membership_payload=$(jq -cn --argjson ids "$EXPECTED_IDS_JSON" \
        '{selected_repository_ids:$ids}')
    if ! gh api --method PUT "orgs/${ORG}/actions/runner-groups/${group_id}/repositories" \
        --input - <<<"$membership_payload" >/dev/null; then
        echo "ERROR: exact repository replacement failed; access may remain more restrictive until the next successful CI reconciliation" >&2
        exit 1
    fi
fi

group_json=$(github_read "runner-group readback" \
    "orgs/${ORG}/actions/runner-groups/${group_id}") || exit 1
repositories_json=$(github_read "runner-group repository readback" --paginate \
    "orgs/${ORG}/actions/runner-groups/${group_id}/repositories?per_page=100") || exit 1

if ! jq -e \
    --arg name "$GROUP_NAME" \
    '.name == $name and .visibility == "selected" and .allows_public_repositories == false' \
    <<<"$group_json" >/dev/null; then
    echo "ERROR: runner-group readback drift: visibility or public access is unsafe" >&2
    exit 1
fi

if ! actual_ids=$(jq -sc '[.[].repositories[]?.id] | sort' <<<"$repositories_json"); then
    echo "ERROR: runner-group repository readback returned an unrecognized schema" >&2
    exit 1
fi
expected_sorted=$(jq -c 'sort' <<<"$EXPECTED_IDS_JSON")
if [ "$actual_ids" != "$expected_sorted" ]; then
    echo "ERROR: runner-group repository readback drift: selected membership is not exact" >&2
    exit 1
fi
if ! jq -se 'all(.[].repositories[]?; .visibility == "private" and .private == true)' \
    <<<"$repositories_json" >/dev/null; then
    echo "ERROR: runner-group repository readback contains a non-private repository" >&2
    exit 1
fi

echo "Trust boundary verified: group=${GROUP_NAME}, visibility=selected, public=false, repositories=9, public workflows audited"
