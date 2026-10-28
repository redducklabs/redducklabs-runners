#!/bin/bash
# Operation-aware runner pool-state gate.
#
# Every fleet workflow (Node Pool Sizing, Deploy, Scale Runners, Rebalance,
# Runner Status) runs this read-only check before it mutates production. It
# implements the "State contract for fleet workflows" section of
# docs/specs/2026-10-26-runner-burst-autoscaling-design.md.
#
# Usage:
#   verify-runner-pool-state.sh --cluster-name NAME --operation OP [--emit-identities FILE]
#                               [--acknowledge-emergency-stop]
#   verify-runner-pool-state.sh --cluster-name NAME --compare-identities FILE --transition T
#
# OP is one of: status, rebalance, acceptance-phase-c, record-density,
# set-burst-maxima, create-burst, configure-expander, deploy, enable-burst,
# drain, remove-burst, rollback.
#
# Admission checks ARC release and controller identity first
# (scripts/lib/arc-identity.sh), then cluster status, eligible pools, node
# membership, maintenance, node compatibility and headroom, and the ARC state
# of the Helm values, Helm manifest and live AutoscalingRunnerSet against the
# operation's admitted contracts. enable-burst, rebalance and
# acceptance-phase-c also require a valid runner network policy set
# (scripts/verify-runner-network-policy.sh). On success it prints one line,
#   STATE: arc=<contract> pools=<none|primary|fallback|both> burst=<closed|open>
# and, with --emit-identities, writes the identity snapshot to FILE. <contract>
# is density, burst, burst-acceptance, drain, or one of the stopped states
# Emergency Stop leaves (burst-stopped, density-stopped, drain-stopped: the
# base template at minRunners=maxRunners=0).
#
# Emergency Stop fence (Ruling 33): admission also reads the ConfigMap
# arc-runners/runner-fleet-emergency-stop that Emergency Stop writes before its
# Helm write. While it exists every operation is refused except status and
# rebalance (both report it, rebalance as a stopped condition), remove-burst
# (deletes only empty closed pools), and deploy or rollback with
# --acknowledge-emergency-stop (they then delete the marker, bracketed, before
# their Helm write). When present on an admitted run the gate prints
#   STOP: Emergency Stop marker arc-runners/runner-fleet-emergency-stop present (run <id> at <time>)
# before the STATE line. A failed marker read fails closed.
#
# Server-side fence (Ruling 36): every operation except status, record-density,
# deploy, rollback (the last two install it before their Helm write) and
# remove-burst also requires the ValidatingAdmissionPolicy and binding
# runner-fleet-emergency-stop-fence to exist with exactly the specs of
# deploy/runner-emergency-stop-fence.yaml (scripts/lib/runner_stop_fence.py).
# Missing or different rejects, except that an absent fence is tolerated while
# ARC is density or density-stopped (no deploy has installed it yet). A failed
# read fails closed.
#
# --compare-identities compares live identities with FILE. T is "none" (exact
# equality) or exactly one declared transition:
#   pool-created:<name>:<size>:<min>/<max>   pool-deleted:<name>
#   pool-bounds:<name>:<min>/<max>           arc:<contract>:<min>/<max>
# A verified transition is written back into FILE; nothing else ever is.
#
# Exit codes: 0 admitted / identical, 1 rejected or a read failed,
# 2 usage error, 3 identity difference. The clock is injectable for tests
# through NOW_CMD (default "date +%s").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATIONS="status rebalance acceptance-phase-c record-density set-burst-maxima create-burst configure-expander deploy enable-burst drain remove-burst rollback"

usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 --cluster-name NAME --operation OP [--emit-identities FILE] [--acknowledge-emergency-stop]" >&2
    echo "       $0 --cluster-name NAME --compare-identities FILE --transition T" >&2
    exit 2
}

CLUSTER_NAME="" OPERATION="" EMIT="" COMPARE="" TRANSITION="" ACKNOWLEDGE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --acknowledge-emergency-stop) ACKNOWLEDGE=true; shift; continue ;;
        --cluster-name | --operation | --emit-identities | --compare-identities | --transition)
            [ $# -ge 2 ] || usage "$1 requires a value"
            case "$1" in
                --cluster-name) CLUSTER_NAME=$2 ;;
                --operation) OPERATION=$2 ;;
                --emit-identities) EMIT=$2 ;;
                --compare-identities) COMPARE=$2 ;;
                --transition) TRANSITION=$2 ;;
            esac
            shift 2
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

[ -n "$CLUSTER_NAME" ] || usage "--cluster-name is required"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || usage "invalid cluster name '${CLUSTER_NAME}'"

if [ -n "$COMPARE" ]; then
    [ -z "$OPERATION" ] && [ -z "$EMIT" ] && [ "$ACKNOWLEDGE" = false ] || usage "--compare-identities cannot be combined with --operation, --emit-identities or --acknowledge-emergency-stop"
    [ -n "$TRANSITION" ] || usage "--compare-identities requires --transition"
    exec python3 "${SCRIPT_DIR}/lib/runner_pool_state.py" compare \
        --cluster-name "$CLUSTER_NAME" --compare-identities "$COMPARE" --transition "$TRANSITION"
fi

[ -n "$OPERATION" ] || usage "--operation or --compare-identities is required"
[ -z "$TRANSITION" ] || usage "--transition is only valid with --compare-identities"
if [ "$ACKNOWLEDGE" = true ] && [ "$OPERATION" != deploy ] && [ "$OPERATION" != rollback ]; then
    usage "--acknowledge-emergency-stop is valid only for deploy and rollback"
fi
case " ${OPERATIONS} " in
    *" ${OPERATION} "*) ;;
    *) usage "unknown operation '${OPERATION}'" ;;
esac

# shellcheck source=lib/arc-identity.sh
source "${SCRIPT_DIR}/lib/arc-identity.sh"
if ! verify_arc_identity; then
    echo "REJECTED: operation '${OPERATION}' not admitted: ARC release or controller identity check failed" >&2
    exit 1
fi

# Runner network isolation is required before burst capacity opens or runners
# are moved: the full policy set is validated on admission for these
# operations. Deploy `deploy` admission does not require it, because Deploy
# installs the policy and validates the set as its postcondition.
case "$OPERATION" in
    enable-burst | rebalance | acceptance-phase-c)
        if ! bash "${SCRIPT_DIR}/verify-runner-network-policy.sh" > /dev/null; then
            echo "REJECTED: operation '${OPERATION}' not admitted: runner network policy set is not valid" >&2
            exit 1
        fi
        ;;
esac

ARGS=(admit --operation "$OPERATION" --cluster-name "$CLUSTER_NAME")
[ -z "$EMIT" ] || ARGS+=(--emit-identities "$EMIT")
[ "$ACKNOWLEDGE" = false ] || ARGS+=(--acknowledge-emergency-stop)
exec python3 "${SCRIPT_DIR}/lib/runner_pool_state.py" "${ARGS[@]}"
