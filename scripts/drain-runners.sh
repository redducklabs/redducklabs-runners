#!/bin/bash
# Deploy `drain`: move the ARC release to the drain contract and wait until the
# burst pools are empty (docs/specs/2026-10-26-runner-burst-autoscaling-design.md,
# "Rollback" step 1).
#
# Usage: RUNNER_TOKEN=<token> [CLUSTER_NAME=<cluster>] \
#        drain-runners.sh --identities FILE
#
# RUNNER_TOKEN is the GitHub token the scale set authenticates with (Helm
# needs it to render the release) and is also used, as GH_TOKEN, to read the
# organization runner list for idle-runner retirement. FILE is the identity
# snapshot written by "verify-runner-pool-state.sh --operation drain
# --emit-identities" in the calling workflow.
#
# 1. If ARC is `burst`, `burst-acceptance` or `burst-stopped` (Emergency Stop
#    from burst, Ruling 26), render the drain values with
#    scripts/render-drain-values.py, render the candidate manifest and check it
#    against the drain contract, then run "helm upgrade" with that single -f
#    file inside the identity bracket (compare none, re-admit `drain`, upgrade
#    behind a manifest-hash post-renderer, the Emergency Stop fence, compare
#    arc:drain:2/4) with --history-max 100. Rollback does not depend on Helm
#    history (Ruling 34). If ARC is already `drain`, the upgrade is skipped and
#    the wait resumes. While the Emergency Stop marker exists the bracket and
#    the gate refuse to write (Ruling 33).
# 2. Read back the drain contract from Helm values, manifest and the live
#    AutoscalingRunnerSet.
# 3. Every 120 s: stop when no runner pod is on a burst node, no burst node is
#    registered and both burst pools report count 0; otherwise run
#    scripts/retire-idle-burst-runners.sh. Busy jobs are never interrupted.
#
# The wait ends at 300 minutes after start (inside the 330-minute job limit):
# the script fails with DRAIN_DEADLINE and leaves the fleet in `drain`; a
# re-run resumes the wait. The clock is injectable (NOW_CMD, SLEEP_CMD).
#
# Exit codes: 0 drained, 1 failed or deadline reached, 2 usage error,
# 3 identity drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fleet-ops.sh
source "${SCRIPT_DIR}/lib/fleet-ops.sh"
# shellcheck source=lib/arc-identity.sh
source "${SCRIPT_DIR}/lib/arc-identity.sh"

CLUSTER_NAME="${CLUSTER_NAME:-redducklabs-cluster}"
DEADLINE_SECONDS=$((300 * 60))
POLL_SECONDS=120
IDENTITIES=""

usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 --identities FILE" >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --identities)
            [ $# -ge 2 ] || usage "--identities requires a file"
            IDENTITIES=$2
            shift 2
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done
[ -n "$IDENTITIES" ] || usage "--identities is required"
if [ ! -f "$IDENTITIES" ]; then
    echo "ERROR: identity snapshot ${IDENTITIES} does not exist; nothing was changed" >&2
    exit 1
fi
if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "ERROR: RUNNER_TOKEN is required; nothing was changed" >&2
    exit 1
fi
export CLUSTER_NAME
export GH_TOKEN="${RUNNER_TOKEN}"

if ! START=$(fleet_now); then
    exit 1
fi
DEADLINE=$((START + DEADLINE_SECONDS))

WORK=$(umask 077 && mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/drain.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

if ! verify_arc_identity; then
    echo "ERROR: ARC release or controller identity check failed; nothing was changed" >&2
    exit 1
fi
if ! STATE=$(fleet_current_state); then
    exit 1
fi

# helm_overlays: the fixed overlays the production release is rendered with.
helm_overlays() {
    printf '%s\n' \
        --namespace "$FLEET_NAMESPACE" \
        -f "${WORK}/drain-values.yaml" \
        --set "githubConfigSecret.github_token=${RUNNER_TOKEN}" \
        --set "runnerScaleSetName=${FLEET_RELEASE}" \
        --set-string "template.spec.containers[0].image=${FLEET_RUNNER_IMAGE}" \
        --set-string "template.spec.initContainers[0].image=${FLEET_RUNNER_IMAGE}" \
        --set runnerGroup=redducklabs-private-runners \
        --set controllerServiceAccount.name=arc-gha-rs-controller \
        --set controllerServiceAccount.namespace=arc-systems \
        --version "$FLEET_CHART_VERSION"
}

case "$STATE" in
    drain:2/4)
        echo "NOOP: ARC is already drain 2/4; resuming the wait"
        ;;
    burst:2/20 | burst-acceptance:8/20 | burst-acceptance:4/20 | burst-stopped:0/0)
        echo "PLAN: helm upgrade ${FLEET_RELEASE} from ${STATE} to drain 2/4"
        if ! python3 "${SCRIPT_DIR}/render-drain-values.py" "${WORK}/drain-values.yaml"; then
            echo "ERROR: could not render the drain values; nothing was changed" >&2
            exit 1
        fi
        mapfile -t OVERLAYS < <(helm_overlays)
        if ! helm template "$FLEET_RELEASE" "$FLEET_CHART" "${OVERLAYS[@]}" > "${WORK}/candidate.yaml"; then
            echo "ERROR: helm template failed; nothing was changed" >&2
            exit 1
        fi
        if ! fleet_validate drain 2 4 manifest < "${WORK}/candidate.yaml"; then
            echo "ERROR: the rendered drain candidate does not satisfy the drain contract; nothing was changed" >&2
            exit 1
        fi
        EXPECTED_HASH=$(sha256sum "${WORK}/candidate.yaml" | awk '{print $1}')
        cat > "${WORK}/hash-gate.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
INPUT=\$(mktemp "${WORK}/postrender.XXXXXX")
trap 'rm -f "\${INPUT}"' EXIT
cat > "\${INPUT}"
ACTUAL=\$(sha256sum "\${INPUT}" | awk '{print \$1}')
if [ "\${ACTUAL}" != "${EXPECTED_HASH}" ]; then
    echo "ERROR: drain manifest hash mismatch: expected ${EXPECTED_HASH}, got \${ACTUAL}" >&2
    exit 1
fi
cat "\${INPUT}"
SH
        chmod 0700 "${WORK}/hash-gate.sh"
        fleet_helm_bracket "$IDENTITIES" drain none arc:drain:2/4 \
            upgrade "$FLEET_RELEASE" "$FLEET_CHART" "${OVERLAYS[@]}" \
            --post-renderer "${WORK}/hash-gate.sh" --history-max 100 --wait --timeout 300s
        rc=$?
        if [ "$rc" -ne 0 ]; then
            exit "$rc"
        fi
        ;;
    *)
        echo "ERROR: drain does not start from ARC state ${STATE}; nothing was changed" >&2
        exit 1
        ;;
esac

if ! fleet_readback drain 2 4; then
    exit 1
fi
echo "READBACK: ARC is drain 2/4"

while :; do
    if ! NOW=$(fleet_now); then
        exit 1
    fi
    if ! OCCUPANCY=$(python3 "${SCRIPT_DIR}/lib/fleet_occupancy.py" --cluster-name "$CLUSTER_NAME"); then
        echo "ERROR: could not read runner placement; the fleet is left in drain" >&2
        exit 1
    fi
    if ! read -r ON_BURST BURST_NODES PRIMARY_COUNT FALLBACK_COUNT < <(jq -r '
        [.runner_pods.burst, .burst_nodes,
         (.burst_pool_counts["github-runners-burst-16g"] // 0),
         (.burst_pool_counts["github-runners-burst-amd-16g"] // 0)] | @tsv' <<<"$OCCUPANCY"); then
        echo "ERROR: could not parse runner placement; the fleet is left in drain" >&2
        exit 1
    fi
    echo "WAIT: elapsed=$(((NOW - START) / 60))m runner_pods_on_burst=${ON_BURST} burst_nodes=${BURST_NODES} pool_counts=${PRIMARY_COUNT}/${FALLBACK_COUNT}"
    if [ "$ON_BURST" = 0 ] && [ "$BURST_NODES" = 0 ] && [ "$PRIMARY_COUNT" = 0 ] && [ "$FALLBACK_COUNT" = 0 ]; then
        break
    fi
    if [ "$NOW" -ge "$DEADLINE" ]; then
        echo "ERROR: DRAIN_DEADLINE: burst pools are not empty after 300 minutes; the fleet is left in drain and a re-run resumes the wait" >&2
        exit 1
    fi
    if ! bash "${SCRIPT_DIR}/retire-idle-burst-runners.sh" --identities "$IDENTITIES"; then
        echo "ERROR: idle-runner retirement failed; the fleet is left in drain" >&2
        exit 1
    fi
    fleet_sleep "$POLL_SECONDS"
done

fleet_compare "$IDENTITIES" none >/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "ERROR: identities changed during the drain wait (exit ${rc})" >&2
    [ "$rc" -eq 3 ] && exit 3
    exit 1
fi
if ! fleet_admit drain >/dev/null || ! fleet_readback drain 2 4; then
    echo "ERROR: final drain readback failed" >&2
    exit 1
fi
echo "DRAIN_COMPLETE: no runner pod on a burst node; both burst pools at zero nodes"
