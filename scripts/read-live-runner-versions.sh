#!/usr/bin/env bash
# Proves which Actions runner version the live fleet runs. Read-only: lists
# pods, reads logs and the Emergency Stop marker.
#
# Usage: read-live-runner-versions.sh <expected version>
#
# Every Running pod must use an image proven to report the expected version.
# Evidence is per image digest because a long job's log rotation can remove a
# pod's startup line while another pod on the same digest still has it.
#
# Prints VERSIONS=<comma list, "stopped", or "none"> and OK=<true|false>. Pod
# log text is never printed: this runs in a public repository's Actions logs.
set -euo pipefail

NAMESPACE=arc-runners
STOP_MARKER=runner-fleet-emergency-stop
ATTEMPTS=${RUNNER_VERSION_ATTEMPTS:-3}
RETRY_SECONDS=${RUNNER_VERSION_RETRY_SECONDS:-20}

EXPECTED=${1:?usage: read-live-runner-versions.sh <expected version>}

report() {
    echo "VERSIONS=$1"
    echo "OK=$2"
    exit 0
}

# An intentional stop has no runners to read. Unexplained zero pods still fail.
marker=$(kubectl get configmap "${STOP_MARKER}" -n "${NAMESPACE}" --ignore-not-found -o name)
[ -z "${marker}" ] || report stopped true

read_pod_version() {
    { kubectl logs -n "${NAMESPACE}" "$1" -c runner 2>/dev/null || true; } |
        sed -n "s/.*Current runner version: '\([0-9.]*\)'.*/\1/p" |
        { head -n 1; cat >/dev/null; }
}

collect() {
    local listing pods digest name version unresolved=0
    local -A digest_version=()
    # collect runs under `if`, so set -e is off here: check each failure.
    listing=$(kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running -o json) || return 1
    pods=$(jq -r '.items[] | .metadata.name as $name
            | [.status.containerStatuses[]? | select(.name == "runner")][0] as $runner
            | "\($runner.imageID // "unknown") \($name)"' <<<"${listing}") || return 1
    [ -n "${pods}" ] || return 1

    while read -r digest name; do
        [ -z "${digest_version[${digest}]:-}" ] || continue
        version=$(read_pod_version "${name}")
        [ -z "${version}" ] || digest_version["${digest}"]=${version}
    done <<<"${pods}"

    while read -r digest name; do
        if [ "${digest}" = "unknown" ] || [ -z "${digest_version[${digest}]:-}" ]; then
            unresolved=1
        fi
    done <<<"${pods}"

    VERSIONS=$(printf '%s\n' "${digest_version[@]}" | sort -u | paste -sd, -)
    [ "${unresolved}" -eq 0 ]
}

VERSIONS=""
for attempt in $(seq 1 "${ATTEMPTS}"); do
    if collect; then
        [ "${VERSIONS}" = "${EXPECTED}" ] && report "${VERSIONS}" true
        report "${VERSIONS}" false
    fi
    [ "${attempt}" -eq "${ATTEMPTS}" ] || sleep "${RETRY_SECONDS}"
done

report "${VERSIONS:-none}${VERSIONS:+,unproven}" false
