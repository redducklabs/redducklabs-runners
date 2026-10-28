#!/bin/bash
# shellcheck shell=bash disable=SC2034 # constants are used by the scripts that source this file
#
# Shared helpers for the scripts that change the ARC runner release while a
# fleet workflow holds the runner-fleet-mutation lock
# (scripts/drain-runners.sh, scripts/acceptance-phase-c.sh,
# scripts/rollback-density.sh) and by Deploy GitHub Runners. Source this file.
#
# Every Helm write goes through fleet_helm_bracket, which applies the identity
# contract from docs/specs/2026-10-26-runner-burst-autoscaling-design.md:
#   1. compare the live identities with the snapshot (transition "none", or
#      the caller's pre-transition when it must accept a known ARC state);
#   2. re-run full admission for the operation;
#   3. the Helm command;
#   4. the Emergency Stop fence (Ruling 33): re-read the marker ConfigMap
#      arc-runners/runner-fleet-emergency-stop; if it exists (or cannot be
#      read), immediately re-apply 0/0 with --reuse-values and fail;
#   5. compare again, allowing only the declared ARC transition.
# A difference stops with exit 3 (identity drift) and no further write. The
# bracket also refuses to write while the marker exists, including for the
# cleanup paths that skip re-admission (operation "-").
#
# Step 4 runs only if the writing process survives its Helm call. The
# server-side fence (Ruling 36, deploy/runner-emergency-stop-fence.yaml) does
# not depend on that: while the marker exists the API server denies any
# AutoscalingRunnerSet write that is not 0/0, whoever sends it.
# fleet_fence_dry_run / fleet_install_fence install it (Deploy `deploy` and
# `rollback`); fleet_fence_probe / fleet_fence_wait observe whether it is
# enforcing (Emergency Stop, and the acknowledgement after deleting the marker).
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
# Ruling 33: written by Emergency Stop before its Helm write.
FLEET_STOP_MARKER="runner-fleet-emergency-stop"
# Ruling 34: the reviewed density values Deploy `rollback` upgrades to
# (relative to the repository root, where the workflows run).
FLEET_DENSITY_VALUES="deploy/density-values.yaml"
# Ruling 36: the server-side Emergency Stop fence (relative to the repository root).
FLEET_FENCE_NAME="runner-fleet-emergency-stop-fence"
FLEET_FENCE_FILE="deploy/runner-emergency-stop-fence.yaml"
FLEET_FENCE_CHECK="${FLEET_LIB_DIR}/runner_stop_fence.py"
# How long a fence probe waits for the API server's admission informer to
# observe a marker write or delete.
FLEET_FENCE_WAIT_SECONDS=30
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

# fleet_admit <operation> [--acknowledge-emergency-stop]: full pool-state
# admission; prints the STATE line (after a STOP line while the marker exists).
fleet_admit() {
    bash "$FLEET_GATE" --cluster-name "$CLUSTER_NAME" --operation "$@"
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
    local identities=$1 operation=$2 pre=$3 post=$4 rc helm_rc
    shift 4
    if ! fleet_refuse_if_stopped; then
        return 1
    fi
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
    helm_rc=0
    helm "$@" || helm_rc=$?
    # The fence runs whether or not Helm reported success: a failed write may
    # still have changed the release.
    if ! fleet_stop_fence; then
        return 1
    fi
    if [ "$helm_rc" -ne 0 ]; then
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

# fleet_stop_marker: prints the Emergency Stop marker ConfigMap as JSON, or
# nothing when it is absent; returns 1 when the read fails.
fleet_stop_marker() {
    kubectl get configmap "$FLEET_STOP_MARKER" -n "$FLEET_NAMESPACE" --ignore-not-found -o json
}

# fleet_restop: Emergency Stop's own write, 0/0 on the pinned chart with
# --reuse-values (the template is kept, so the gate classifies a stopped state).
fleet_restop() {
    echo "HELM: upgrade stopped:0/0 (re-applying the Emergency Stop)" >&2
    helm upgrade "$FLEET_RELEASE" "$FLEET_CHART" --namespace "$FLEET_NAMESPACE" --version "$FLEET_CHART_VERSION" \
        --reuse-values --set minRunners=0 --set maxRunners=0 --history-max 100 >&2
}

# fleet_stop_fence: runs immediately after every Helm write (Ruling 33). The
# marker is written before Emergency Stop's Helm write, so a write of this run
# that landed after a stop began (or completed) sees it here. A marker this run
# acknowledged was deleted before the write, so any marker present now belongs
# to a newer stop. Present or unreadable: re-apply 0/0 and return 1.
fleet_stop_fence() {
    local marker
    if ! marker=$(fleet_stop_marker); then
        echo "ERROR: STOP_FENCE: the Emergency Stop marker ${FLEET_NAMESPACE}/${FLEET_STOP_MARKER} could not be read after the Helm write; re-applying 0/0 (fail closed)" >&2
        fleet_restop || echo "ERROR: STOP_FENCE: re-applying 0/0 failed; dispatch Emergency Stop now" >&2
        return 1
    fi
    if [ -n "$marker" ]; then
        echo "ERROR: STOP_FENCE: an Emergency Stop (marker ${FLEET_NAMESPACE}/${FLEET_STOP_MARKER}) is in effect after this run's Helm write; re-applied 0/0 and failing" >&2
        fleet_restop || echo "ERROR: STOP_FENCE: re-applying 0/0 failed; dispatch Emergency Stop now" >&2
        return 1
    fi
}

# fleet_refuse_if_stopped: returns 1 (nothing written) while the marker exists
# or cannot be read.
fleet_refuse_if_stopped() {
    local marker
    if ! marker=$(fleet_stop_marker); then
        echo "ERROR: the Emergency Stop marker could not be read; nothing was written" >&2
        return 1
    fi
    if [ -n "$marker" ]; then
        echo "ERROR: an Emergency Stop (marker ${FLEET_NAMESPACE}/${FLEET_STOP_MARKER}) is in effect; nothing was written" >&2
        return 1
    fi
}

# fleet_acknowledge_stop <identities> <operation>: Deploy `deploy`/`rollback`
# dispatched with acknowledge_emergency_stop=true (Ruling 33). Deletes the
# marker inside the identity bracket: compare none, admission with the
# acknowledgement, the delete, compare none. The delete carries the uid and
# resourceVersion that were read, so a newer Emergency Stop that rewrote the
# marker in between makes it fail (HTTP 409) instead of being acknowledged
# unseen. No marker: a no-op.
fleet_acknowledge_stop() {
    local identities=$1 operation=$2 marker uid version run_id body rc
    if ! marker=$(fleet_stop_marker); then
        echo "ERROR: the Emergency Stop marker could not be read; nothing was changed" >&2
        return 1
    fi
    if [ -z "$marker" ]; then
        echo "STOP_MARKER: none (no Emergency Stop to acknowledge)"
        return 0
    fi
    if ! uid=$(jq -er '.metadata.uid | strings' <<<"$marker") \
        || ! version=$(jq -er '.metadata.resourceVersion | strings' <<<"$marker"); then
        echo "ERROR: the Emergency Stop marker has no uid or resourceVersion; nothing was changed" >&2
        return 1
    fi
    run_id=$(jq -r '.data["run-id"] // "unknown" | tostring | gsub("[^0-9A-Za-z._:-]"; "")' <<<"$marker")
    fleet_compare "$identities" none >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check before deleting the Emergency Stop marker failed (exit ${rc}); nothing was changed" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
    if ! fleet_admit "$operation" --acknowledge-emergency-stop >/dev/null; then
        echo "ERROR: ${operation} is no longer admitted; the Emergency Stop marker was kept" >&2
        return 1
    fi
    body=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/stop-ack.XXXXXX") || return 1
    jq -n --arg uid "$uid" --arg version "$version" \
        '{kind: "DeleteOptions", apiVersion: "v1", preconditions: {uid: $uid, resourceVersion: $version}}' > "$body"
    if ! kubectl delete --raw "/api/v1/namespaces/${FLEET_NAMESPACE}/configmaps/${FLEET_STOP_MARKER}" -f "$body" >/dev/null; then
        rm -f "$body"
        echo "ERROR: could not delete the Emergency Stop marker of run ${run_id} (a newer stop changed it, or the delete failed); the fleet stays stopped" >&2
        return 1
    fi
    rm -f "$body"
    # Ruling 36: the API server's admission informer may still hold the marker
    # for a moment. Wait (dry runs only) until the fence allows a non-zero
    # write, so the Helm write is not denied by that stale view.
    if ! fleet_fence_wait allowed; then
        echo "ERROR: the Emergency Stop marker of run ${run_id} was deleted, but the fence still denies writes; nothing was written. Re-dispatch (the marker is gone, so no acknowledgement is needed)" >&2
        return 1
    fi
    fleet_compare "$identities" none >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check after deleting the Emergency Stop marker failed (exit ${rc}); stopping" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
    echo "STOP_MARKER: acknowledged and deleted the marker of Emergency Stop run ${run_id}"
}

# fleet_fence_probe: a server-side dry-run patch of the AutoscalingRunnerSet
# to maxRunners=1 (nothing is written). Prints "denied" when the fence denied
# it and "allowed" when the API server accepted it; returns 1 when the probe
# could not run or failed for any other reason.
fleet_fence_probe() {
    local asrs name out rc
    if ! asrs=$(kubectl get autoscalingrunnersets.actions.github.com -n "$FLEET_NAMESPACE" -o json) \
        || ! name=$(jq -er 'if (.items | length) == 1 then .items[0].metadata.name | strings else error("not exactly one") end' <<<"$asrs"); then
        echo "ERROR: STOP_FENCE_PROBE: could not read exactly one AutoscalingRunnerSet in ${FLEET_NAMESPACE}" >&2
        return 1
    fi
    rc=0
    out=$(kubectl patch autoscalingrunnersets.actions.github.com "$name" -n "$FLEET_NAMESPACE" \
        --type merge -p '{"spec":{"maxRunners":1}}' --dry-run=server -o name 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo allowed
        return 0
    fi
    if grep -qF "ValidatingAdmissionPolicy '${FLEET_FENCE_NAME}'" <<<"$out" && grep -qF "denied request" <<<"$out"; then
        echo denied
        return 0
    fi
    echo "ERROR: STOP_FENCE_PROBE: the dry-run patch failed for another reason: $(head -c 300 <<<"$out")" >&2
    return 1
}

# fleet_fence_wait <denied|allowed>: probes until the result is the wanted one,
# for up to FLEET_FENCE_WAIT_SECONDS (the admission informer's lag after a
# marker write or delete). Returns 1 on timeout or a failed probe.
fleet_fence_wait() {
    local want=$1 now deadline result
    now=$(fleet_now) || return 1
    deadline=$((now + FLEET_FENCE_WAIT_SECONDS))
    while :; do
        result=$(fleet_fence_probe) || return 1
        if [ "$result" = "$want" ]; then
            echo "STOP_FENCE_PROBE: a dry-run maxRunners=1 write is ${want}"
            return 0
        fi
        now=$(fleet_now) || return 1
        if [ "$now" -ge "$deadline" ]; then
            echo "ERROR: STOP_FENCE_PROBE: a dry-run maxRunners=1 write is still ${result} after ${FLEET_FENCE_WAIT_SECONDS}s (expected ${want})" >&2
            return 1
        fi
        fleet_sleep 2
    done
}

# fleet_fence_dry_run: server-side dry run of the committed fence. The objects
# the API server would store must carry exactly the file's specs, so a spec
# the server would default or rewrite fails here, before anything is applied.
fleet_fence_dry_run() {
    local work rc=0
    work=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fence-dry-run.XXXXXX") || return 1
    if ! kubectl apply --server-side --dry-run=server -f "$FLEET_FENCE_FILE" \
        --field-manager=redducklabs-runner-deploy -o json > "$work"; then
        echo "ERROR: the server-side dry run of ${FLEET_FENCE_FILE} failed; nothing was applied" >&2
        rm -f "$work"
        return 1
    fi
    python3 -B "$FLEET_FENCE_CHECK" compare-dry-run "$work" || rc=$?
    rm -f "$work"
    return "$rc"
}

# fleet_install_fence <identities> <operation>: applies the committed fence
# server-side inside the identity bracket (compare none, re-admit <operation>,
# the apply, compare none; the fence is not part of the identity snapshot),
# then requires the live specs to equal the file and the policy to report type
# checking of its current generation without expression warnings (polled for
# FLEET_FENCE_WAIT_SECONDS). Run fleet_fence_dry_run first. No retry: a second
# apply would run outside the bracket.
fleet_install_fence() {
    local identities=$1 operation=$2 rc now deadline
    fleet_compare "$identities" none >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check before applying the Emergency Stop fence failed (exit ${rc}); nothing was applied" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
    if ! fleet_admit "$operation" >/dev/null; then
        echo "ERROR: ${operation} is no longer admitted; the Emergency Stop fence was not applied" >&2
        return 1
    fi
    if ! kubectl apply --server-side -f "$FLEET_FENCE_FILE" --field-manager=redducklabs-runner-deploy; then
        echo "ERROR: applying ${FLEET_FENCE_FILE} failed" >&2
        return 1
    fi
    fleet_compare "$identities" none >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: identity check after applying the Emergency Stop fence failed (exit ${rc}); stopping" >&2
        [ "$rc" -eq 3 ] && return 3
        return 1
    fi
    now=$(fleet_now) || return 1
    deadline=$((now + FLEET_FENCE_WAIT_SECONDS))
    while :; do
        rc=0
        python3 -B "$FLEET_FENCE_CHECK" verify --require-type-checked || rc=$?
        [ "$rc" -eq 0 ] && return 0
        [ "$rc" -eq 75 ] || return 1
        now=$(fleet_now) || return 1
        if [ "$now" -ge "$deadline" ]; then
            echo "ERROR: the ValidatingAdmissionPolicy ${FLEET_FENCE_NAME} did not report type checking within ${FLEET_FENCE_WAIT_SECONDS}s" >&2
            return 1
        fi
        fleet_sleep 2
    done
}

# fleet_density_overlays <values-file> <token>:the fixed overlays the
# production release is rendered with (as Deploy and drain), one per line.
fleet_density_overlays() {
    printf '%s\n' \
        --namespace "$FLEET_NAMESPACE" \
        --values "$1" \
        --set "githubConfigSecret.github_token=$2" \
        --set "runnerScaleSetName=${FLEET_RELEASE}" \
        --set-string "template.spec.containers[0].image=${FLEET_RUNNER_IMAGE}" \
        --set-string "template.spec.initContainers[0].image=${FLEET_RUNNER_IMAGE}" \
        --set runnerGroup=redducklabs-private-runners \
        --set controllerServiceAccount.name=arc-gha-rs-controller \
        --set controllerServiceAccount.namespace=arc-systems \
        --version "$FLEET_CHART_VERSION"
}

# fleet_render_density <work-dir>: validates deploy/density-values.yaml as the
# density contract (2/4), renders it with the production overlays (RUNNER_TOKEN
# is required, as for Deploy) into <work-dir>/density-candidate.yaml and
# validates that manifest as density 2/4. Run from the repository root.
# Returns 1, having written nothing to the cluster, on any failure.
fleet_render_density() {
    local work=$1 overlays
    if [ -z "${RUNNER_TOKEN:-}" ]; then
        echo "ERROR: RUNNER_TOKEN is required to render ${FLEET_DENSITY_VALUES}; nothing was changed" >&2
        return 1
    fi
    if ! fleet_validate density 2 4 values < "$FLEET_DENSITY_VALUES"; then
        echo "ERROR: ${FLEET_DENSITY_VALUES} is not the density contract (2/4); nothing was changed" >&2
        return 1
    fi
    mapfile -t overlays < <(fleet_density_overlays "$FLEET_DENSITY_VALUES" "$RUNNER_TOKEN")
    if ! helm template "$FLEET_RELEASE" "$FLEET_CHART" "${overlays[@]}" > "${work}/density-candidate.yaml"; then
        echo "ERROR: helm template of ${FLEET_DENSITY_VALUES} failed; nothing was changed" >&2
        return 1
    fi
    if ! fleet_validate density 2 4 manifest < "${work}/density-candidate.yaml"; then
        echo "ERROR: the rendered ${FLEET_DENSITY_VALUES} manifest is not the density contract (2/4); nothing was changed" >&2
        return 1
    fi
}
