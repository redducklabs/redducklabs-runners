#!/bin/bash
# shellcheck shell=bash disable=SC2034 # constants are used by the scripts that source this file
#
# Shared helpers for the scripts that change the ARC runner release while a
# fleet workflow holds the runner-fleet-mutation lock
# (scripts/drain-runners.sh, scripts/acceptance-phase-c.sh). Source this file.
#
# Every Helm write goes through fleet_helm_bracket, which applies the identity
# contract from docs/specs/2026-10-26-runner-burst-autoscaling-design.md:
#   1. compare the live identities with the snapshot (transition "none", or
#      the caller's pre-transition when it must accept a known ARC state);
#   2. re-run full admission for the operation;
#   3. the Helm command;
#   4. compare again, allowing only the declared ARC transition.
# A difference stops with exit 3 (identity drift) and no further write.
#
# Clocks are injectable for tests: NOW_CMD (default "date +%s") prints epoch
# seconds and SLEEP_CMD (default "sleep") is called with a number of seconds.

FLEET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SCRIPTS_DIR="$(cd "${FLEET_LIB_DIR}/.." && pwd)"
FLEET_RELEASE="redducklabs-runners"
FLEET_NAMESPACE="arc-runners"
FLEET_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
FLEET_CHART_VERSION="0.14.2"
FLEET_RUNNER_IMAGE="registry.digitalocean.com/redducklabs/github-runner:latest"
FLEET_GATE="${FLEET_SCRIPTS_DIR}/verify-runner-pool-state.sh"
FLEET_VALIDATOR="${FLEET_SCRIPTS_DIR}/validate-runner-isolation-contract.py"
# Every ARC state the fleet workflows can classify, as contract:min/max.
# The stopped states (Ruling 26) are what Emergency Stop leaves: a base
# template with minRunners=maxRunners=0.
FLEET_ARC_STATES="burst:2/20 burst-acceptance:8/20 burst-acceptance:4/20 drain:2/4 density:2/4 burst-stopped:0/0 density-stopped:0/0 drain-stopped:0/0"

# fleet_now: prints the current epoch seconds; returns 1 if the clock fails.
fleet_now() {
    local cmd value
    read -r -a cmd <<<"${NOW_CMD:-date +%s}"
    if ! value=$("${cmd[@]}") || ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: the clock (NOW_CMD) did not print an integer epoch" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# fleet_sleep <seconds>
fleet_sleep() {
    local cmd
    read -r -a cmd <<<"${SLEEP_CMD:-sleep}"
    "${cmd[@]}" "$1"
}

# fleet_admit <operation>: full pool-state admission; prints the STATE line.
fleet_admit() {
    bash "$FLEET_GATE" --cluster-name "$CLUSTER_NAME" --operation "$1"
}

# fleet_compare <identities> <transition>: returns the gate's exit code
# (0 equal, 3 identity difference, anything else a failed read).
fleet_compare() {
    bash "$FLEET_GATE" --cluster-name "$CLUSTER_NAME" --compare-identities "$1" --transition "$2"
}

# fleet_validate <contract> <min> <max> <kind>: validator over stdin.
fleet_validate() {
    python3 "$FLEET_VALIDATOR" --contract "$1" --kind "$4" \
        --min-runners "$2" --max-runners "$3" --runner-group private
}

# fleet_readback <contract> <min> <max>: the live Helm values, Helm manifest
# and AutoscalingRunnerSet must all satisfy the contract. Values are piped
# straight into the validator and never printed.
fleet_readback() {
    local contract=$1 min=$2 max=$3
    if ! helm get values "$FLEET_RELEASE" -n "$FLEET_NAMESPACE" -o json | fleet_validate "$contract" "$min" "$max" values; then
        echo "ERROR: live Helm values are not ${contract} ${min}/${max}" >&2
        return 1
    fi
    if ! helm get manifest "$FLEET_RELEASE" -n "$FLEET_NAMESPACE" | fleet_validate "$contract" "$min" "$max" manifest; then
        echo "ERROR: live Helm manifest is not ${contract} ${min}/${max}" >&2
        return 1
    fi
    if ! kubectl get autoscalingrunnersets.actions.github.com -n "$FLEET_NAMESPACE" -o json \
        | fleet_validate "$contract" "$min" "$max" asrs-list; then
        echo "ERROR: live AutoscalingRunnerSet is not ${contract} ${min}/${max}" >&2
        return 1
    fi
}

# fleet_current_state: prints the one contract:min/max that the live values,
# manifest and AutoscalingRunnerSet all satisfy; returns 1 if none or the
# reads fail.
fleet_current_state() {
    local values manifest asrs state contract bounds min max matched=()
    if ! values=$(helm get values "$FLEET_RELEASE" -n "$FLEET_NAMESPACE" -o json) \
        || ! manifest=$(helm get manifest "$FLEET_RELEASE" -n "$FLEET_NAMESPACE") \
        || ! asrs=$(kubectl get autoscalingrunnersets.actions.github.com -n "$FLEET_NAMESPACE" -o json); then
        echo "ERROR: could not read the live ARC release state" >&2
        return 1
    fi
    for state in $FLEET_ARC_STATES; do
        contract=${state%%:*}
        bounds=${state#*:}
        min=${bounds%/*}
        max=${bounds#*/}
        if fleet_validate "$contract" "$min" "$max" values <<<"$values" 2>/dev/null \
            && fleet_validate "$contract" "$min" "$max" manifest <<<"$manifest" 2>/dev/null \
            && fleet_validate "$contract" "$min" "$max" asrs-list <<<"$asrs" 2>/dev/null; then
            matched+=("$state")
        fi
    done
    if [ "${#matched[@]}" -ne 1 ]; then
        echo "ERROR: the live ARC release matches ${#matched[@]} known contracts (expected exactly one)" >&2
        return 1
    fi
    printf '%s\n' "${matched[0]}"
}

# fleet_helm_bracket <identities> <operation|-> <pre-transition> <post-transition> <helm args...>
# Runs the identity bracket around "helm <args>". Operation "-" skips the
# re-admission (used only by cleanup paths that re-check release identity
# and contracts themselves). Returns 3 on identity drift, 1 on any other
# failure, 0 when the post-transition comparison holds.
fleet_helm_bracket() {
    local identities=$1 operation=$2 pre=$3 post=$4 rc
    shift 4
    fleet_compare "$identities" "$pre" >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check before the Helm write failed (exit ${rc}); nothing was written" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
    if [ "$operation" != - ] && ! fleet_admit "$operation"; then
        echo "ERROR: ${operation} is no longer admitted; nothing was written" >&2
        return 1
    fi
    echo "HELM: $1 ${post}"
    if ! helm "$@"; then
        echo "ERROR: helm $1 failed" >&2
        return 1
    fi
    fleet_compare "$identities" "$post" >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check after the Helm write failed (exit ${rc}); stopping" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
}
