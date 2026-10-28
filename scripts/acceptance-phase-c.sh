#!/bin/bash
# Acceptance Phase C: idle-runner retirement and return to zero burst nodes,
# run as one lock-owning operation (docs/specs/2026-10-26-runner-burst-autoscaling-design.md,
# "Phase C is one lock-owning operation" and "Acceptance", row C).
#
# Usage:
#   GH_TOKEN=<org runner read> [CLUSTER_NAME=<cluster>] \
#     acceptance-phase-c.sh --max-cycles N --identities FILE [--evidence PATH]
#   [CLUSTER_NAME=<cluster>] acceptance-phase-c.sh --restore --identities FILE
#
# FILE is the identity snapshot the calling workflow wrote with
# "verify-runner-pool-state.sh --operation acceptance-phase-c --emit-identities".
#
# A cycle:
#   1. minRunners=8 (burst-acceptance 8/20); wait up to 20 minutes for 8 Ready
#      idle runners; assert 4 on baseline and 4 on burst nodes; run retirement
#      and assert it deleted nothing (baseline is full).
#   2. minRunners=4 (burst-acceptance 4/20); wait up to 20 minutes for ARC to
#      remove the surplus; record whether an idle runner survived on a burst
#      node, run retirement, and require it to retire such a survivor.
#   3. minRunners=2 (burst 2/20); wait up to 60 minutes for both burst pools
#      to reach zero nodes, running retirement every 2 minutes.
# Cycles repeat (up to N) until a burst survivor was retired. Every Helm write
# is "helm upgrade --reuse-values --set minRunners=<n>" inside the identity
# bracket (scripts/lib/fleet-ops.sh) and is read back with the contract
# validator. The writes deliberately omit --wait: a run cancelled during a
# waiting upgrade can leave the release in status "failed", which the ARC
# identity check (and so every fleet workflow) then rejects; readiness is
# covered by the occupancy polling and the contract readback instead. A run
# that finds ARC at burst-acceptance (an interrupted run) first restores burst.
#
# The run stops at 270 minutes (PHASE_C_DEADLINE) so the workflow's cleanup
# step still fits in the 300-minute job limit. The clock is injectable
# (NOW_CMD, SLEEP_CMD).
#
# On success the last two stdout lines are
#   PHASE_C_EVIDENCE=<path>   (default ./phase-c-evidence.json)
#   PHASE_C_RESULT=retired|fixture-only
# "fixture-only" means no cycle left an idle runner on a burst node, so
# retirement of a burst survivor was exercised only by fixtures.
#
# --restore is the workflow's always-run cleanup: it re-checks release
# identity and the live contract, and returns ARC from burst-acceptance to
# burst (minRunners=2). On burst it is a verified no-op.
#
# Exit codes: 0 success, 1 failed assertion, read or write, 2 usage error,
# 3 identity drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fleet-ops.sh
source "${SCRIPT_DIR}/lib/fleet-ops.sh"
# shellcheck source=lib/arc-identity.sh
source "${SCRIPT_DIR}/lib/arc-identity.sh"

CLUSTER_NAME="${CLUSTER_NAME:-redducklabs-cluster}"
DEADLINE_SECONDS=$((270 * 60))
RUNNER_WAIT_SECONDS=$((20 * 60))
POOLS_ZERO_SECONDS=$((60 * 60))
RUNNER_POLL_SECONDS=30
RETIRE_POLL_SECONDS=120
MAX_CYCLES=""
IDENTITIES=""
EVIDENCE="phase-c-evidence.json"
RESTORE=false

usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 --max-cycles N --identities FILE [--evidence PATH]" >&2
    echo "       $0 --restore --identities FILE" >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --max-cycles | --identities | --evidence)
            [ $# -ge 2 ] || usage "$1 requires a value"
            case "$1" in
                --max-cycles) MAX_CYCLES=$2 ;;
                --identities) IDENTITIES=$2 ;;
                --evidence) EVIDENCE=$2 ;;
            esac
            shift 2
            ;;
        --restore) RESTORE=true; shift ;;
        *) usage "unknown argument '$1'" ;;
    esac
done
[ -n "$IDENTITIES" ] || usage "--identities is required"
if [ "$RESTORE" = true ]; then
    [ -z "$MAX_CYCLES" ] || usage "--restore does not take --max-cycles"
else
    [[ "$MAX_CYCLES" =~ ^[1-3]$ ]] || usage "--max-cycles must be 1, 2 or 3"
fi
if [ ! -f "$IDENTITIES" ]; then
    echo "ERROR: identity snapshot ${IDENTITIES} does not exist; nothing was changed" >&2
    exit 1
fi
export CLUSTER_NAME

# set_min <n> <pre-transition> <operation|->: one bracketed Helm write and its readback.
set_min() {
    local n=$1 pre=$2 operation=$3 contract max=20 rc
    case "$n" in
        8 | 4) contract=burst-acceptance ;;
        2) contract=burst ;;
        *) echo "ERROR: minRunners ${n} is not a Phase C state" >&2; return 1 ;;
    esac
    fleet_helm_bracket "$IDENTITIES" "$operation" "$pre" "arc:${contract}:${n}/${max}" \
        upgrade "$FLEET_RELEASE" "$FLEET_CHART" --namespace "$FLEET_NAMESPACE" \
        --version "$FLEET_CHART_VERSION" --reuse-values --set "minRunners=${n}" --history-max 100
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if ! fleet_readback "$contract" "$n" "$max"; then
        return 1
    fi
    echo "READBACK: ARC is ${contract} ${n}/${max}"
}

# restore: return ARC to burst 2/20, or confirm it is already there.
restore() {
    local state rc
    if ! verify_arc_identity; then
        echo "ERROR: RESTORE: ARC release or controller identity check failed; nothing was changed" >&2
        return 1
    fi
    state=$(fleet_current_state) || return 1
    case "$state" in
        burst:2/20)
            fleet_readback burst 2 20 || return 1
            echo "RESTORE: ARC is already burst 2/20 (verified no-op)"
            ;;
        burst-acceptance:8/20 | burst-acceptance:4/20)
            # The snapshot may predate the last authorized write (a run
            # cancelled between "helm upgrade" and its readback), so the
            # pre-write comparison accepts exactly the live ARC state while
            # every other identity must still match.
            set_min 2 "arc:${state}" -
            rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "ERROR: RESTORE: could not return ARC to burst 2/20" >&2
                return "$rc"
            fi
            echo "RESTORE: ARC returned from ${state} to burst 2/20"
            ;;
        *)
            echo "ERROR: RESTORE: ARC state ${state} is not a Phase C state; nothing was changed" >&2
            return 1
            ;;
    esac
}

if [ "$RESTORE" = true ]; then
    restore
    exit $?
fi

if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN (organization runner read) is required; nothing was changed" >&2
    exit 1
fi
if ! START=$(fleet_now); then
    exit 1
fi
DEADLINE=$((START + DEADLINE_SECONDS))

check_deadline() {
    local now
    now=$(fleet_now) || exit 1
    if [ "$now" -ge "$DEADLINE" ]; then
        echo "ERROR: PHASE_C_DEADLINE: 270 minutes elapsed; stopping so cleanup can restore burst" >&2
        exit 1
    fi
}

# occupancy: sets OCC to the fleet_occupancy JSON.
occupancy() {
    if ! OCC=$(python3 "${SCRIPT_DIR}/lib/fleet_occupancy.py" --cluster-name "$CLUSTER_NAME"); then
        echo "ERROR: could not read runner placement" >&2
        exit 1
    fi
}

# retire: runs retirement and sets RETIRED from its summary line.
retire() {
    local output last
    if ! output=$(bash "${SCRIPT_DIR}/retire-idle-burst-runners.sh" --identities "$IDENTITIES"); then
        printf '%s\n' "$output"
        echo "ERROR: idle-runner retirement failed" >&2
        exit 1
    fi
    printf '%s\n' "$output"
    last=$(tail -n 1 <<<"$output")
    if ! [[ "$last" =~ ^RETIRED=([0-9]+)\ CANDIDATES=[0-9]+\ FREE_BASELINE_SLOTS=[0-9]+$ ]]; then
        echo "ERROR: retirement printed no summary line" >&2
        exit 1
    fi
    RETIRED=${BASH_REMATCH[1]}
}

# wait_until <description> <timeout-seconds> <poll-seconds> <jq predicate> [retire]
wait_until() {
    local description=$1 timeout=$2 poll=$3 predicate=$4 with_retire=${5:-} began now
    began=$(fleet_now) || exit 1
    while :; do
        occupancy
        if jq -e "$predicate" <<<"$OCC" >/dev/null; then
            echo "WAIT: ${description}: reached ($(jq -c . <<<"$OCC"))"
            return 0
        fi
        check_deadline
        now=$(fleet_now) || exit 1
        if [ $((now - began)) -ge "$timeout" ]; then
            echo "ERROR: ${description}: not reached within $((timeout / 60)) minutes ($(jq -c . <<<"$OCC"))" >&2
            exit 1
        fi
        if [ -n "$with_retire" ]; then
            retire
        fi
        fleet_sleep "$poll"
    done
}

if ! verify_arc_identity; then
    echo "ERROR: ARC release or controller identity check failed; nothing was changed" >&2
    exit 1
fi
STATE=$(fleet_current_state) || exit 1
case "$STATE" in
    burst:2/20) ;;
    burst-acceptance:8/20 | burst-acceptance:4/20)
        echo "PLAN: interrupted Phase C left ${STATE}; restoring burst first"
        set_min 2 none acceptance-phase-c
        rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        ;;
    *)
        echo "ERROR: Phase C does not start from ARC state ${STATE}; nothing was changed" >&2
        exit 1
        ;;
esac

CYCLES="[]"
RESULT=fixture-only
for cycle in $(seq 1 "$MAX_CYCLES"); do
    echo "CYCLE ${cycle}/${MAX_CYCLES}"
    check_deadline
    set_min 8 none acceptance-phase-c
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    wait_until "8 Ready idle runners" "$RUNNER_WAIT_SECONDS" "$RUNNER_POLL_SECONDS" \
        '(.ready_idle.baseline + .ready_idle.burst) >= 8'
    BASELINE=$(jq -r '.ready_idle.baseline' <<<"$OCC")
    BURST=$(jq -r '.ready_idle.burst' <<<"$OCC")
    if [ "$BASELINE" != 4 ] || [ "$BURST" != 4 ]; then
        echo "ERROR: expected 4 idle runners on baseline and 4 on burst nodes; found ${BASELINE} and ${BURST}" >&2
        exit 1
    fi
    retire
    if [ "$RETIRED" != 0 ]; then
        echo "ERROR: retirement deleted ${RETIRED} runner(s) while baseline was full" >&2
        exit 1
    fi

    check_deadline
    set_min 4 none acceptance-phase-c
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    wait_until "ARC removed surplus runners" "$RUNNER_WAIT_SECONDS" "$RUNNER_POLL_SECONDS" \
        '.runners <= 4 and (.runner_pods.baseline + .runner_pods.burst + .runner_pods.other + .runner_pods.unscheduled) <= 4'
    if [ "$(jq -r '.ready_idle.burst' <<<"$OCC")" -gt 0 ]; then
        SURVIVOR=true
    else
        SURVIVOR=false
    fi
    retire
    AFTER4_RETIRED=$RETIRED
    if [ "$SURVIVOR" = true ] && [ "$AFTER4_RETIRED" -lt 1 ]; then
        echo "ERROR: an idle runner survived on a burst node but retirement did not retire it" >&2
        exit 1
    fi

    check_deadline
    set_min 2 none acceptance-phase-c
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    wait_until "both burst pools at zero nodes" "$POOLS_ZERO_SECONDS" "$RETIRE_POLL_SECONDS" \
        '.runner_pods.burst == 0 and .burst_nodes == 0
         and ((.burst_pool_counts | to_entries | map(.value // 0) | add) == 0)' retire
    NOW=$(fleet_now) || exit 1
    ZERO_AT=$(date -u -d "@${NOW}" +%Y-%m-%dT%H:%M:%SZ)
    CYCLES=$(jq -c --argjson baseline "$BASELINE" --argjson burst "$BURST" \
        --argjson survivor "$SURVIVOR" --argjson retired "$AFTER4_RETIRED" --arg zero "$ZERO_AT" \
        '. + [{"min8": {"baseline": $baseline, "burst": $burst, "retired": 0},
               "after4": {"survivor_on_burst": $survivor, "retired": $retired},
               "pools_zero_at": $zero}]' <<<"$CYCLES")
    if [ "$SURVIVOR" = true ]; then
        RESULT=retired
        break
    fi
    echo "CYCLE ${cycle}: no idle runner survived on a burst node"
done

# This script does not observe jobs, so it does not claim a jobs_killed
# count (Ruling 17); runner-acceptance-evidence measures it.
if ! jq -n --argjson cycles "$CYCLES" --arg result "$RESULT" \
    '{"cycles": $cycles, "result": $result, "jobs_killed": null,
      "jobs_killed_note": "not measured by acceptance-phase-c.sh; measured by runner-acceptance-evidence"}' > "$EVIDENCE"; then
    echo "ERROR: could not write ${EVIDENCE}" >&2
    exit 1
fi
echo "PHASE_C_EVIDENCE=${EVIDENCE}"
echo "PHASE_C_RESULT=${RESULT}"
