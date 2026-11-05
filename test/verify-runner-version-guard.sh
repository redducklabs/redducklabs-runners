#!/usr/bin/env bash
# Verifies scripts/check-runner-version.py and the Runner Version Guard
# workflow contract. Needs python3 only: no network or cluster access.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${ROOT}/scripts/check-runner-version.py"
WORKFLOW="${ROOT}/.github/workflows/runner-version-guard.yml"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
FAILS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

make_tree() {
    local tree="${WORK}/tree"
    rm -rf "${tree}"
    mkdir -p "${tree}/docker" "${tree}/docs/toolchain"
    printf 'ARG X=1\nARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:%s\n' "$1" \
        >"${tree}/docker/Dockerfile.custom-runner"
    printf 'ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:%s\n' "$1" \
        >"${tree}/docs/toolchain/dockerfile-security-refactor.md"
    printf '| GitHub Actions Runner | %s | base image |\n' "$1" >"${tree}/README.md"
    echo "${tree}"
}

RELEASES="${WORK}/releases.json"
cat >"${RELEASES}" <<'JSON'
[
  {"tag_name": "v2.340.0", "published_at": "2026-12-01T12:00:00Z", "prerelease": true, "draft": false},
  {"tag_name": "v2.339.0", "published_at": "2026-11-10T12:00:00Z", "prerelease": false, "draft": false},
  {"tag_name": "v2.338.2", "published_at": "2026-10-26T14:45:12Z", "prerelease": false, "draft": false},
  {"tag_name": "v2.338.0", "published_at": "2026-10-06T13:55:11Z", "prerelease": false, "draft": false}
]
JSON

# expect_check <name> <pin> <now> <exit> <text in output>
expect_check() {
    local name=$1 pin=$2 now=$3 want_exit=$4 want_text=$5 tree out status=0
    tree=$(make_tree "${pin}")
    out=$(python3 "${SCRIPT}" --root "${tree}" check --releases "${RELEASES}" --now "${now}" 2>&1) || status=$?
    if [ "${status}" -eq "${want_exit}" ] && grep -qF "${want_text}" <<<"${out}"; then
        pass "${name}"
    else
        fail "${name}: exit ${status}, output: ${out}"
    fi
}

expect_check "latest pin is current" 2.339.0 2026-11-11T00:00:00Z 0 "STATUS=current"
expect_check "prereleases are ignored" 2.339.0 2026-12-20T00:00:00Z 0 "LATEST=2.339.0"
expect_check "a new release inside the window is not overdue" 2.338.2 2026-11-12T00:00:00Z 0 "STATUS=update-available"
expect_check "seven days behind is overdue" 2.338.2 2026-11-17T12:00:00Z 1 "STATUS=overdue"
expect_check "the clock starts at the oldest newer release" 2.338.0 2026-11-05T00:00:00Z 1 "DEADLINE=2026-11-25"
expect_check "the Nov 5 outage state would have been overdue" 2.336.0 2026-10-13T14:00:00Z 1 "DEADLINE=2026-11-05"

echo '{"message": "rate limited"}' >"${WORK}/bad.json"
status=0
out=$(python3 "${SCRIPT}" --root "$(make_tree 2.338.2)" check --releases "${WORK}/bad.json" 2>/dev/null) || status=$?
if [ "${status}" -eq 2 ] && grep -qF "STATUS=unavailable" <<<"${out}"; then
    pass "malformed releases are unavailable, not current"
else
    fail "malformed releases: exit ${status}, output: ${out}"
fi

tree=$(make_tree 2.338.2)
printf 'ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:2.1.0\n' >>"${tree}/docker/Dockerfile.custom-runner"
status=0
python3 "${SCRIPT}" --root "${tree}" check --releases "${RELEASES}" >/dev/null 2>&1 || status=$?
[ "${status}" -eq 2 ] && pass "an ambiguous pin is rejected" || fail "ambiguous pin: exit ${status}"

tree=$(make_tree 2.338.2)
if python3 "${SCRIPT}" --root "${tree}" apply --version 2.339.0 &&
    [ "$(grep -rl '2\.339\.0' "${tree}" | wc -l)" -eq 3 ] &&
    ! grep -rq '2\.338\.2' "${tree}"; then
    pass "apply updates every pinned file"
else
    fail "apply did not update all three files"
fi

tree=$(make_tree 2.338.2)
for version in 2.338.2 2.1.0 'v2.339.0' '2.339.0;x'; do
    if python3 "${SCRIPT}" --root "${tree}" apply --version "${version}" 2>/dev/null; then
        fail "apply accepted ${version}"
    else
        pass "apply rejects ${version}"
    fi
done

tree=$(make_tree 2.338.2)
rm "${tree}/README.md"
touch "${tree}/README.md"
if python3 "${SCRIPT}" --root "${tree}" apply --version 2.339.0 2>/dev/null; then
    fail "apply accepted a file with no pin"
elif grep -q '2\.339\.0' "${tree}/docker/Dockerfile.custom-runner"; then
    fail "apply left a partial update"
else
    pass "apply changes nothing when a file has no pin"
fi

# The real repository must still parse, so a moved pin fails here, not at 06:00.
if python3 "${SCRIPT}" --root "${ROOT}" check --releases "${RELEASES}" --now 2026-11-06T00:00:00Z | grep -q '^PINNED='; then
    pass "the repository pin parses"
else
    fail "the repository pin does not parse"
fi

for needle in "cron:" "RUNNER_TOKEN" "persist-credentials: false" "runs-on: ubuntu-latest" \
    "scripts/check-runner-version.py" "build-runner-image.yml"; do
    if grep -qF "${needle}" "${WORKFLOW}"; then
        pass "workflow contains ${needle}"
    else
        fail "workflow is missing ${needle}"
    fi
done

if [ "${FAILS}" -ne 0 ]; then
    echo "${FAILS} check(s) failed"
    exit 1
fi
echo "All runner version guard checks passed"
