#!/bin/bash
# Retire idle EphemeralRunners that landed on burst-pool nodes.
#
# Cluster-autoscaler never drains a node that holds a runner pod
# (safe-to-evict: "false"), so an idle warm runner created on a burst node keeps
# that node alive. This script deletes such idle runners, oldest first, never
# more than the free baseline slots, so the EphemeralRunnerSet replaces them on
# baseline (docs/specs/2026-10-26-runner-burst-autoscaling-design.md, "Job
# protection and idle-runner retirement").
#
# Usage: GH_TOKEN=<org runner read token> [CLUSTER_NAME=<cluster>] \
#        retire-idle-burst-runners.sh --identities FILE [--dry-run]
#
# FILE is the identity snapshot the calling workflow wrote with
# "verify-runner-pool-state.sh --emit-identities". It is required unless
# --dry-run. Immediately before EACH deletion, and once more after the last,
# the script runs "verify-runner-pool-state.sh --compare-identities FILE
# --transition none" and (before each deletion) verify_arc_identity; any
# non-zero result stops the run with exit 1 and no further deletion.
#
# Callers run scripts/verify-runner-pool-state.sh (operation rebalance or
# drain) immediately before. This script additionally re-checks the scale-set
# release, the controller release and controller readiness
# (scripts/lib/arc-identity.sh) before anything else, because retirement relies
# on the 0.14.2 controller's finalizer: a job assigned after the check keeps
# the pod until the job finishes.
#
# A runner is deleted only if its pod is on a burst node, EphemeralRunner
# status records no job, and the GitHub runner of the same name is not busy,
# read after the Kubernetes reads. Unknown state means keep.
#
# Last stdout line: RETIRED=<n> CANDIDATES=<m> FREE_BASELINE_SLOTS=<k>
# Exit codes: 0 done (including nothing to do), 1 a read, identity check or
# deletion failed (a failed read means zero deletions), 2 usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="arc-runners"

CLUSTER_NAME="${CLUSTER_NAME:-redducklabs-cluster}"
DRY_RUN=false
IDENTITIES=""
usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 --identities FILE [--dry-run]" >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --identities)
            [ $# -ge 2 ] || usage "--identities requires a file"
            IDENTITIES=$2
            shift 2
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN (organization runner read) is required" >&2
    exit 1
fi

if [ "$DRY_RUN" = false ] && { [ -z "$IDENTITIES" ] || [ ! -f "$IDENTITIES" ]; }; then
    echo "ERROR: --identities FILE (an existing identity snapshot) is required unless --dry-run; nothing was deleted" >&2
    exit 1
fi

# compare_identities: live identities must equal the snapshot exactly.
compare_identities() {
    bash "${SCRIPT_DIR}/verify-runner-pool-state.sh" --cluster-name "$CLUSTER_NAME" \
        --compare-identities "$IDENTITIES" --transition none >/dev/null
}

# shellcheck source=lib/arc-identity.sh
source "${SCRIPT_DIR}/lib/arc-identity.sh"
if ! verify_arc_identity; then
    echo "ERROR: ARC release or controller identity check failed; nothing was deleted" >&2
    exit 1
fi

if ! plan=$(python3 "${SCRIPT_DIR}/lib/retire_idle_runners.py"); then
    echo "ERROR: could not read cluster or GitHub state; nothing was deleted" >&2
    exit 1
fi

if ! free=$(jq -er '.free_baseline_slots' <<<"$plan") \
    || ! candidates=$(jq -er '.candidates | length' <<<"$plan") \
    || ! selected_names=$(jq -er '.select | join("\n")' <<<"$plan"); then
    echo "ERROR: could not parse the retirement plan; nothing was deleted" >&2
    exit 1
fi

retired=0
status=0
while IFS= read -r runner; do
    [ -n "$runner" ] || continue
    if [ "$DRY_RUN" = true ]; then
        echo "dry-run: would delete EphemeralRunner ${runner}"
        continue
    fi
    if ! compare_identities || ! verify_arc_identity; then
        echo "ERROR: identity check failed before deleting ${runner}; stopping" >&2
        status=1
        break
    fi
    echo "Deleting idle burst EphemeralRunner ${runner}"
    if kubectl delete ephemeralrunner -n "$NAMESPACE" "$runner" --wait=false; then
        retired=$((retired + 1))
    else
        echo "ERROR: could not delete EphemeralRunner ${runner}; stopping" >&2
        status=1
        break
    fi
done <<<"$selected_names"

if [ "$DRY_RUN" = false ] && [ "$status" -eq 0 ] && ! compare_identities; then
    echo "ERROR: identity check failed after the deletions" >&2
    status=1
fi

echo "RETIRED=${retired} CANDIDATES=${candidates} FREE_BASELINE_SLOTS=${free}"
exit "$status"
