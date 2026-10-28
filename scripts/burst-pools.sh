#!/bin/bash
# Burst node-pool and cluster-autoscaler operations for Node Pool Sizing.
#
# Implements the Node Pool Sizing operations of
# docs/specs/2026-10-26-runner-burst-autoscaling-design.md ("Node pools and the
# aggregate ceiling", "State contract for fleet workflows", "Rollback").
#
# Usage:
#   burst-pools.sh create-burst       --cluster-name N [--apply --identities FILE]
#   burst-pools.sh configure-expander --cluster-name N [--apply --identities FILE]
#   burst-pools.sh enable-burst       --cluster-name N [--apply --identities FILE]
#   burst-pools.sh set-burst-maxima   --cluster-name N --primary-max P --fallback-max F [--apply --identities FILE]
#   burst-pools.sh remove-burst       --cluster-name N [--apply --identities FILE]
#
# Without --apply the script runs admission (read-only), prints each planned
# doctl/kubectl call as a "PLAN:" line and exits 0.
#
# With --apply, FILE is the identity snapshot written by
#   verify-runner-pool-state.sh --operation <op> --emit-identities FILE
# right after admission. The script first compares live state with it exactly,
# re-runs admission, and then brackets every mutation with:
#   1. verify-runner-pool-state.sh --compare-identities FILE --transition none
#   2. verify-runner-pool-state.sh --operation <op>   (full admission)
#   3. the doctl/kubectl mutation
#   4. verify-runner-pool-state.sh --compare-identities FILE --transition <declared>
# followed by a readback of what the mutation changed. Any difference stops the
# run with no further mutation.
#
# configure-expander --apply waits (bounded, "WAIT:" lines) for DOKS to create
# the priority-expander ConfigMap after the expander update (Ruling 40); the
# sleep between reads is injectable for tests (SLEEP_CMD, default "sleep").
#
# Output: "PLAN:"/"APPLY:"/"NOOP:" lines while running, then a summary of
# "POOL <name>: before=<min/max|absent> after=<min/max|absent>" lines, an
# "EXPANDERS:" line and one "RESULT:" line.
#
# Exit codes: 0 success (or dry run), 1 rejected / failed / readback mismatch
# (SCALE_TO_ZERO_REJECTED when the provider refuses a closed pool), 2 usage
# error, 3 identity difference.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/verify-runner-pool-state.sh"
POOL_LIB="${SCRIPT_DIR}/lib/runner_pool_state.py"
OPERATIONS="create-burst configure-expander enable-burst set-burst-maxima remove-burst"

usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 <${OPERATIONS// /|}> --cluster-name NAME [--primary-max P --fallback-max F] [--apply --identities FILE]" >&2
    exit 2
}

[ $# -ge 1 ] || usage "an operation is required"
OPERATION=$1
shift
case " ${OPERATIONS} " in
    *" ${OPERATION} "*) ;;
    *) usage "unknown operation '${OPERATION}'" ;;
esac

CLUSTER_NAME="" PRIMARY_MAX="" FALLBACK_MAX="" APPLY=false IDENTITIES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name | --primary-max | --fallback-max | --identities)
            [ $# -ge 2 ] || usage "$1 requires a value"
            case "$1" in
                --cluster-name) CLUSTER_NAME=$2 ;;
                --primary-max) PRIMARY_MAX=$2 ;;
                --fallback-max) FALLBACK_MAX=$2 ;;
                --identities) IDENTITIES=$2 ;;
            esac
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

[ -n "$CLUSTER_NAME" ] || usage "--cluster-name is required"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || usage "invalid cluster name '${CLUSTER_NAME}'"
if [ "$APPLY" = true ]; then
    [ -n "$IDENTITIES" ] || usage "--apply requires --identities (the admission snapshot)"
    [ -f "$IDENTITIES" ] || usage "identity snapshot '${IDENTITIES}' does not exist"
fi

# Pool names, sizes, caps, labels, taint and expander settings come from the
# gate's helper so the two can never disagree.
CONSTANTS=$(python3 -B - "$POOL_LIB" <<'PY'
import importlib.util
import json
import shlex
import sys

spec = importlib.util.spec_from_file_location("runner_pool_state", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
taint = lib.RUNNER_TAINT
values = {
    "BASELINE": lib.BASELINE,
    "PRIMARY": lib.PRIMARY,
    "FALLBACK": lib.FALLBACK,
    "PRIMARY_SIZE": lib.RUNNER_POOL_SIZES[lib.PRIMARY],
    "FALLBACK_SIZE": lib.RUNNER_POOL_SIZES[lib.FALLBACK],
    "PRIMARY_CAP": str(lib.BURST_CAPS[lib.PRIMARY]),
    "FALLBACK_CAP": str(lib.BURST_CAPS[lib.FALLBACK]),
    "BURST_SUM_CAP": str(lib.BURST_SUM_CAP),
    "EXPANDERS": ",".join(lib.EXPANDERS),
    "EXPANDER_NAMESPACE": lib.EXPANDER_CONFIGMAP[0],
    "EXPANDER_CONFIGMAP": lib.EXPANDER_CONFIGMAP[1],
    "EXPANDER_MANAGED_LABEL": lib.EXPANDER_MANAGED_LABEL,
    "RUNNER_LABELS_JSON": json.dumps(lib.RUNNER_LABELS, sort_keys=True),
    "RUNNER_TAINT_JSON": json.dumps(taint, sort_keys=True),
}
for name, value in values.items():
    print(f"{name}={shlex.quote(value)}")
flags = []
for key, value in lib.RUNNER_LABELS.items():
    flags += ["--label", f"{key}={value}"]
flags += ["--taint", f"{taint['key']}={taint['value']}:{taint['effect']}"]
print(f"POOL_FLAGS=({shlex.join(flags)})")
PY
) || { echo "ERROR: could not load pool constants from ${POOL_LIB}" >&2; exit 1; }
eval "$CONSTANTS"

if [ "$OPERATION" = set-burst-maxima ]; then
    [[ "$PRIMARY_MAX" =~ ^[0-9]+$ ]] || usage "--primary-max must be an integer 0..${PRIMARY_CAP}"
    [[ "$FALLBACK_MAX" =~ ^[0-9]+$ ]] || usage "--fallback-max must be an integer 0..${FALLBACK_CAP}"
    PRIMARY_MAX=$((10#$PRIMARY_MAX)) FALLBACK_MAX=$((10#$FALLBACK_MAX))
    [ "$PRIMARY_MAX" -le "$PRIMARY_CAP" ] || usage "--primary-max ${PRIMARY_MAX} exceeds ${PRIMARY_CAP}"
    [ "$FALLBACK_MAX" -le "$FALLBACK_CAP" ] || usage "--fallback-max ${FALLBACK_MAX} exceeds ${FALLBACK_CAP}"
    [ $((PRIMARY_MAX + FALLBACK_MAX)) -le "$BURST_SUM_CAP" ] \
        || usage "burst maxima ${PRIMARY_MAX}+${FALLBACK_MAX} exceed the aggregate ceiling ${BURST_SUM_CAP}"
elif [ -n "$PRIMARY_MAX" ] || [ -n "$FALLBACK_MAX" ]; then
    usage "--primary-max/--fallback-max are only valid for set-burst-maxima"
fi

RESULT=""
CLUSTER_ID="" CLUSTER_JSON="" POOLS_JSON=""
BEFORE_PRIMARY="unknown" BEFORE_FALLBACK="unknown" BEFORE_EXPANDERS="unknown"

# --------------------------------------------------------------------------
# Reads
# --------------------------------------------------------------------------

read_state() {
    local matches
    CLUSTER_JSON=$(doctl kubernetes cluster list -o json) || return 1
    matches=$(jq -r --arg n "$CLUSTER_NAME" '[.[] | select(.name == $n) | .id] | if length == 1 then .[0] else empty end' <<<"$CLUSTER_JSON") || return 1
    [ -n "$matches" ] || { echo "ERROR: cluster '${CLUSTER_NAME}' does not resolve to exactly one cluster" >&2; return 1; }
    if [ -n "$CLUSTER_ID" ] && [ "$matches" != "$CLUSTER_ID" ]; then
        echo "ERROR: cluster '${CLUSTER_NAME}' changed ID from ${CLUSTER_ID} to ${matches}" >&2
        return 1
    fi
    CLUSTER_ID=$matches
    POOLS_JSON=$(doctl kubernetes cluster node-pool list "$CLUSTER_ID" -o json) || return 1
    jq -e 'type == "array"' <<<"$POOLS_JSON" > /dev/null || { echo "ERROR: node-pool list is not a JSON array" >&2; return 1; }
    # Ruling 39: doctl omits zero-valued fields (godo omitempty), so a closed
    # pool has no count/min_nodes/max_nodes key. Restore ABSENT keys as zero
    # (auto_scale false, nodes []) before anything reads the list; a present
    # key, including an explicit null, is kept as read and still fails closed.
    # Mirrors normalize_pool_list in scripts/lib/runner_pool_state.py.
    POOLS_JSON=$(jq -c 'map(if type == "object" then {count: 0, min_nodes: 0, max_nodes: 0, auto_scale: false, nodes: []} + . else . end)' <<<"$POOLS_JSON") \
        || { echo "ERROR: node-pool list could not be normalized" >&2; return 1; }
}

pool_json() {  # name -> the single pool object, or nothing
    jq -c --arg n "$1" '[.[] | select(.name == $n)] | if length == 1 then .[0] elif length == 0 then empty else error("duplicate pool") end' <<<"$POOLS_JSON"
}

pool_bounds() {  # name -> "min/max" or "absent"
    local pool
    pool=$(pool_json "$1") || return 1
    if [ -z "$pool" ]; then echo absent; else jq -r '"\(.min_nodes)/\(.max_nodes)"' <<<"$pool"; fi
}

pool_max() { jq -r '.max_nodes' <<<"$(pool_json "$1")"; }
pool_id() { jq -r '.id' <<<"$(pool_json "$1")"; }

cluster_expanders() {  # comma-joined expander list ("" when unset)
    jq -r --arg id "$CLUSTER_ID" '.[] | select(.id == $id) | (.cluster_autoscaler_configuration.expanders // []) | join(",")' <<<"$CLUSTER_JSON"
}

# pool_matches <name> <size> <min> <max>: exact size, labels, single taint
# (provider key case normalized), autoscaling, and bounds.
pool_matches() {
    local pool
    pool=$(pool_json "$1") || return 1
    [ -n "$pool" ] || return 1
    jq -e --arg size "$2" --argjson min "$3" --argjson max "$4" \
        --argjson labels "$RUNNER_LABELS_JSON" --argjson taint "$RUNNER_TAINT_JSON" '
        .size == $size and .auto_scale == true
        and .min_nodes == $min and .max_nodes == $max
        and (.labels // {}) == $labels
        and ([(.taints // [])[] | with_entries(.key |= ascii_downcase)] == [$taint])
    ' <<<"$pool" > /dev/null
}

pool_structure_ok() {  # name size: everything but the bounds
    local pool
    pool=$(pool_json "$1") || return 1
    jq -e --arg size "$2" --argjson labels "$RUNNER_LABELS_JSON" --argjson taint "$RUNNER_TAINT_JSON" '
        .size == $size and .auto_scale == true
        and (.labels // {}) == $labels
        and ([(.taints // [])[] | with_entries(.key |= ascii_downcase)] == [$taint])
    ' <<<"$pool" > /dev/null
}

render_priorities() {  # primary-id fallback-id
    printf '100:\n  - %s\n50:\n  - %s\n1:\n  - .*\n' "$1" "$2"
}

# configmap_state <primary-id> <fallback-id>: prints "priorities=<equal|differ>
# managed=<yes|no>" for the live priority-expander ConfigMap. Returns 2 and
# prints nothing when the ConfigMap does not exist (DOKS creates it only after
# the priority expander is enabled, Ruling 40); returns 1 on any other read
# failure, which the callers treat as fatal.
configmap_state() {
    local configmap
    configmap=$(kubectl get configmap "$EXPANDER_CONFIGMAP" -n "$EXPANDER_NAMESPACE" --ignore-not-found -o json) || return 1
    [ -n "${configmap//[[:space:]]/}" ] || return 2
    CONFIGMAP_JSON=$configmap python3 -B - "$1" "$2" "$EXPANDER_MANAGED_LABEL" <<'PY' || return 1
import json
import os
import sys

import yaml

primary, fallback, managed = sys.argv[1:]
configmap = json.loads(os.environ["CONFIGMAP_JSON"])
try:
    priorities = yaml.safe_load(((configmap.get("data") or {}).get("priorities")) or "")
except yaml.YAMLError:
    priorities = None
labels = (configmap.get("metadata") or {}).get("labels") or {}
equal = priorities == {100: [primary], 50: [fallback], 1: [".*"]}
print(f"priorities={'equal' if equal else 'differ'} managed={'yes' if managed in labels else 'no'}")
PY
}

# --------------------------------------------------------------------------
# Failure handling and summary
# --------------------------------------------------------------------------

fail_run() {  # message [exit code]
    RESULT="failed: $1"
    echo "ERROR: $1" >&2
    exit "${2:-1}"
}

summary() {
    local rc=$? after_primary="unknown" after_fallback="unknown" after_expanders="unknown"
    set +e
    if read_state 2> /dev/null; then
        after_primary=$(pool_bounds "$PRIMARY" 2> /dev/null || echo unknown)
        after_fallback=$(pool_bounds "$FALLBACK" 2> /dev/null || echo unknown)
        after_expanders=$(cluster_expanders 2> /dev/null || echo unknown)
    fi
    echo ""
    echo "POOL ${PRIMARY}: before=${BEFORE_PRIMARY} after=${after_primary}"
    echo "POOL ${FALLBACK}: before=${BEFORE_FALLBACK} after=${after_fallback}"
    echo "EXPANDERS: before=${BEFORE_EXPANDERS:-default} after=${after_expanders:-default}"
    if [ -z "$RESULT" ]; then
        if [ "$rc" -eq 0 ]; then
            if [ "$APPLY" = true ]; then RESULT="${OPERATION} applied"; else RESULT="${OPERATION} dry run, nothing changed"; fi
        else
            RESULT="failed (exit ${rc})"
        fi
    fi
    echo "RESULT: ${RESULT}"
    exit "$rc"
}

# --------------------------------------------------------------------------
# Gate wrappers and the mutation bracket
# --------------------------------------------------------------------------

admit() {  # context
    bash "$GATE" --cluster-name "$CLUSTER_NAME" --operation "$OPERATION" \
        || fail_run "operation '${OPERATION}' not admitted ($1)"
}

compare() {  # transition context
    local rc=0
    bash "$GATE" --cluster-name "$CLUSTER_NAME" --compare-identities "$IDENTITIES" --transition "$1" || rc=$?
    case "$rc" in
        0) ;;
        3)
            RESULT="identity drift ${2}: live state differs from the admission snapshot (transition '$1')"
            echo "ERROR: IDENTITY_DRIFT ${2}; no further mutation" >&2
            exit 3
            ;;
        *) fail_run "identity comparison ${2} could not complete (exit ${rc})" ;;
    esac
}

# identity_report <transition>: after a failed mutation, says whether live
# identities moved, without exiting.
identity_report() {
    local rc=0
    bash "$GATE" --cluster-name "$CLUSTER_NAME" --compare-identities "$IDENTITIES" --transition none > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "identities unchanged"
        return
    fi
    if [ "$1" != none ]; then
        rc=0
        bash "$GATE" --cluster-name "$CLUSTER_NAME" --compare-identities "$IDENTITIES" --transition "$1" > /dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "the declared transition '$1' took effect despite the error"
            return
        fi
    fi
    echo "IDENTITIES MOVED: live state differs from the snapshot (compare exit ${rc})"
}

# scale_to_zero_refusal <output>: a 422/validation response that names the
# pool bounds (min_nodes, max_nodes, a count field) or scale-to-zero. A
# droplet-limit error, or "count" inside a word like "account", never matches.
scale_to_zero_refusal() {
    grep -Eqi '(^|[^0-9])422([^0-9]|$)|unprocessable|validation' <<<"$1" || return 1
    ! grep -Eqi 'droplet limit' <<<"$1" || return 1
    grep -Eqi '(^|[^a-z_])(min_nodes|max_nodes|min-nodes|max-nodes|node_count)([^a-z_]|$)|scale[ -]to[ -]zero|(^|[^a-z_])count[ ]+(must|should|cannot|can.t|is invalid|is not)' <<<"$1"
}

# mutate <transition> <description> <command...>
mutate() {
    local transition=$1 description=$2 output rc=0 moved
    shift 2
    if [ "$APPLY" != true ]; then
        echo "PLAN: ${description}: $*"
        return 0
    fi
    compare none "before ${description}"
    admit "before ${description}"
    echo "APPLY: ${description}: $*"
    output=$("$@" 2>&1) || rc=$?
    [ -z "$output" ] || printf '%s\n' "$output"
    if [ "$rc" -ne 0 ]; then
        moved=$(identity_report "$transition")
        echo "ERROR: after the failed ${description}: ${moved}" >&2
        if [ "$1 $2 $3 $4" = "doctl kubernetes cluster node-pool" ] && [ "$5" = create ] \
            && scale_to_zero_refusal "$output"; then
            RESULT="SCALE_TO_ZERO_REJECTED: the provider refused a closed (0/0, count 0) burst pool (${moved}); stop the rollout and re-plan"
            echo "ERROR: SCALE_TO_ZERO_REJECTED: ${description} was refused; nothing further is created" >&2
            exit 1
        fi
        fail_run "${description} failed (exit ${rc}; ${moved}); no further mutation"
    fi
    compare "$transition" "after ${description}"
}

# cluster_projection: every cluster field an expander update must not change.
cluster_projection() {
    jq -cS --arg id "$CLUSTER_ID" '.[] | select(.id == $id) | {
        name, auto_upgrade, surge_upgrade, ha, tags, control_plane_firewall, routing_agent,
        maintenance_policy: (.maintenance_policy | if . == null then null else {day, start_time, duration} end),
        autoscaler_other: ((.cluster_autoscaler_configuration // {}) | del(.expanders))
    }' <<<"$CLUSTER_JSON"
}

# cluster_update <description> <expanders>: doctl always sends a maintenance
# window on "cluster update" (default any=00:00), so the live window is passed
# back explicitly, kubeconfig is left alone, and the cluster object is diffed
# before and after: only cluster_autoscaler_configuration.expanders may change.
cluster_update() {
    local description=$1 expanders=$2 window surge before after
    reread
    window=$(jq -r --arg id "$CLUSTER_ID" '.[] | select(.id == $id) | .maintenance_policy
        | if (type == "object") and ((.day | type) == "string") and (.day != "")
             and ((.start_time | type) == "string") and (.start_time != "")
          then "\(.day)=\(.start_time)" else empty end' <<<"$CLUSTER_JSON")
    [ -n "$window" ] \
        || fail_run "cluster '${CLUSTER_NAME}' has no readable maintenance_policy (day, start_time); refusing 'doctl kubernetes cluster update', which would reset the window to any=00:00"
    surge=$(jq -r --arg id "$CLUSTER_ID" '.[] | select(.id == $id) | (.surge_upgrade // false) | tostring' <<<"$CLUSTER_JSON")
    case "$surge" in true | false) ;; *) fail_run "cluster surge_upgrade '${surge}' is not a boolean" ;; esac
    before=$(cluster_projection)
    mutate none "$description" \
        doctl kubernetes cluster update "$CLUSTER_ID" --expanders "$expanders" \
        --maintenance-window "$window" --surge-upgrade="$surge" --update-kubeconfig=false
    [ "$APPLY" = true ] || return 0
    reread
    after=$(cluster_projection)
    if [ "$before" != "$after" ]; then
        echo "ERROR: cluster fields before: ${before}" >&2
        echo "ERROR: cluster fields after:  ${after}" >&2
        fail_run "${description} changed cluster settings other than the expanders (see before/after above)"
    fi
    echo "READBACK: maintenance window ${window}, surge_upgrade ${surge} and other cluster settings unchanged"
}

# Called after every operation's own readback: the final state must still be
# admitted and must equal the (transition-updated) snapshot exactly.
final_check() {
    [ "$APPLY" = true ] || return 0
    admit "final readback"
    compare none "at final readback"
}

reread() {
    read_state || fail_run "readback could not read cluster state"
}

verify_pool() {  # name size min max
    [ "$APPLY" = true ] || return 0
    reread
    pool_matches "$1" "$2" "$3" "$4" \
        || fail_run "readback: pool '$1' is not ${2} ${3}/${4} with the runner labels, taint and autoscaling"
    echo "READBACK: pool '$1' is ${3}/${4}"
}

update_bounds_command() {  # name max -> prints nothing; sets UPDATE_CMD array
    UPDATE_CMD=(doctl kubernetes cluster node-pool update "$CLUSTER_ID" "$(pool_id "$1")"
        --auto-scale --min-nodes 0 --max-nodes "$2" "${POOL_FLAGS[@]}")
}

size_of() {
    if [ "$1" = "$PRIMARY" ]; then echo "$PRIMARY_SIZE"; else echo "$FALLBACK_SIZE"; fi
}

# --------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------

op_create_burst() {
    local name size bounds
    for name in "$PRIMARY" "$FALLBACK"; do
        size=$(size_of "$name")
        bounds=$(pool_bounds "$name")
        if [ "$bounds" = absent ]; then
            mutate "pool-created:${name}:${size}:0/0" "create closed pool ${name}" \
                doctl kubernetes cluster node-pool create "$CLUSTER_ID" --name "$name" --size "$size" \
                --count 0 --auto-scale --min-nodes 0 --max-nodes 0 "${POOL_FLAGS[@]}"
        else
            pool_structure_ok "$name" "$size" \
                || fail_run "existing pool '${name}' has the wrong size, labels, taint or autoscaling; remove it first"
            if [ "$(pool_max "$name")" != 0 ]; then
                update_bounds_command "$name" 0
                mutate "pool-bounds:${name}:0/0" "narrow pool ${name} to 0/0" "${UPDATE_CMD[@]}"
            else
                echo "NOOP: pool '${name}' already exists closed (0/0)"
                continue
            fi
        fi
        verify_pool "$name" "$size" 0 0
    done
    final_check
}

# Ruling 40: DOKS creates kube-system/cluster-autoscaler-priority-expander
# (with its doks.digitalocean.com labels and a starter "1: [.*]") only after
# the priority expander is enabled on the cluster, and DigitalOcean does not
# document how long that takes. After the expander update, apply reads it
# every EXPANDER_CONFIGMAP_POLL_SECONDS for up to EXPANDER_CONFIGMAP_WAIT_SECONDS
# (every 15 s for 10 minutes, 41 reads, well inside the 30-minute job
# timeout), then fails. configure-expander never changes pool bounds; during
# the rollout both burst pools are closed (0/0), so a timeout leaves no burst
# capacity, only the expander list changed. A re-run continues the wait.
EXPANDER_CONFIGMAP_POLL_SECONDS=15
EXPANDER_CONFIGMAP_WAIT_SECONDS=600
EXPANDER_CONFIGMAP_POLLS=$((EXPANDER_CONFIGMAP_WAIT_SECONDS / EXPANDER_CONFIGMAP_POLL_SECONDS + 1))

burst_sleep() {  # seconds; SLEEP_CMD (default "sleep") is the test seam
    local cmd
    read -r -a cmd <<<"${SLEEP_CMD:-sleep}"
    "${cmd[@]}" "$1"
}

# wait_for_configmap <primary-id> <fallback-id>: sets CONFIGMAP_STATE once the
# ConfigMap exists; any read error other than NotFound fails the run.
wait_for_configmap() {
    local poll=1 rc
    while :; do
        rc=0
        CONFIGMAP_STATE=$(configmap_state "$1" "$2") || rc=$?
        case "$rc" in
            0)
                [ "$poll" -eq 1 ] \
                    || echo "READBACK: DOKS created ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} (read ${poll})"
                return 0
                ;;
            2) ;;
            *) fail_run "could not read ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} (a read error other than NotFound)" ;;
        esac
        [ "$poll" -lt "$EXPANDER_CONFIGMAP_POLLS" ] \
            || fail_run "ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} still absent after waiting ${EXPANDER_CONFIGMAP_WAIT_SECONDS}s (${EXPANDER_CONFIGMAP_POLLS} reads, every ${EXPANDER_CONFIGMAP_POLL_SECONDS}s); DOKS creates it after the priority expander is enabled (expanders are '$(cluster_expanders)'); pool bounds were not changed; re-run configure-expander to continue"
        echo "WAIT: ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} not created by DOKS yet (read ${poll}/${EXPANDER_CONFIGMAP_POLLS}); next read in ${EXPANDER_CONFIGMAP_POLL_SECONDS}s"
        burst_sleep "$EXPANDER_CONFIGMAP_POLL_SECONDS"
        poll=$((poll + 1))
    done
}

op_configure_expander() {
    local primary_id fallback_id state patch rc
    primary_id=$(pool_id "$PRIMARY")
    fallback_id=$(pool_id "$FALLBACK")
    patch=$(jq -cn --arg p "$(render_priorities "$primary_id" "$fallback_id")" '{data: {priorities: $p}}')
    if [ "$(cluster_expanders)" != "$EXPANDERS" ]; then
        cluster_update "set cluster expanders to ${EXPANDERS}" "$EXPANDERS"
    else
        echo "NOOP: cluster expanders already ${EXPANDERS}"
    fi
    if [ "$APPLY" = true ]; then
        # Re-read after the update: expanders already set (re-run) and just
        # set both wait here for DOKS to create the ConfigMap.
        reread
        [ "$(cluster_expanders)" = "$EXPANDERS" ] \
            || fail_run "cluster expanders are '$(cluster_expanders)', expected '${EXPANDERS}'; not waiting for the ConfigMap"
        wait_for_configmap "$primary_id" "$fallback_id"
        state=$CONFIGMAP_STATE
    else
        rc=0
        state=$(configmap_state "$primary_id" "$fallback_id") || rc=$?
        case "$rc" in
            0) ;;
            2)
                # Dry run: nothing was changed, so DOKS has not created it yet.
                echo "PLAN: wait up to ${EXPANDER_CONFIGMAP_WAIT_SECONDS}s for DOKS to create ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} (it does so only after the priority expander is enabled), then write priorities 100: ${primary_id} (${PRIMARY}), 50: ${fallback_id} (${FALLBACK}), 1: .*: kubectl patch configmap ${EXPANDER_CONFIGMAP} -n ${EXPANDER_NAMESPACE} --type merge -p ${patch}"
                final_check
                return 0
                ;;
            *) fail_run "could not read ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} (a read error other than NotFound)" ;;
        esac
    fi
    if [[ "$state" != priorities=equal* ]]; then
        # A JSON merge patch replaces data.priorities only; metadata (the
        # DOKS-managed name and doks labels) is left as DOKS created it.
        mutate none "write priority expander ConfigMap" \
            kubectl patch configmap "$EXPANDER_CONFIGMAP" -n "$EXPANDER_NAMESPACE" --type merge -p "$patch"
    else
        echo "NOOP: priority expander ConfigMap already ranks ${PRIMARY}=100, ${FALLBACK}=50, .*=1"
    fi
    if [ "$APPLY" = true ]; then
        reread
        [ "$(cluster_expanders)" = "$EXPANDERS" ] \
            || fail_run "readback: cluster expanders are '$(cluster_expanders)', expected '${EXPANDERS}'"
        rc=0
        state=$(configmap_state "$primary_id" "$fallback_id") || rc=$?
        [ "$rc" -eq 0 ] \
            || fail_run "readback could not read ConfigMap ${EXPANDER_NAMESPACE}/${EXPANDER_CONFIGMAP} (exit ${rc}; 2 = absent)"
        [ "$state" = "priorities=equal managed=yes" ] \
            || fail_run "readback: priority expander ConfigMap mismatch (${state}); expected ${PRIMARY}=100, ${FALLBACK}=50, .*=1 and the ${EXPANDER_MANAGED_LABEL} label"
        echo "READBACK: expanders ${EXPANDERS}; ConfigMap priorities and managed label verified"
    fi
    final_check
}

open_pool() {  # name cap
    update_bounds_command "$1" "$2"
    mutate "pool-bounds:${1}:0/${2}" "open pool ${1} to 0/${2}" "${UPDATE_CMD[@]}"
    verify_pool "$1" "$(size_of "$1")" 0 "$2"
    # The next stage must itself be admitted by enable-burst.
    [ "$APPLY" != true ] || admit "after opening ${1}"
}

op_enable_burst() {
    local stage
    stage="$(pool_max "$PRIMARY")/$(pool_max "$FALLBACK")"
    case "$stage" in
        "0/0")
            open_pool "$PRIMARY" "$PRIMARY_CAP"
            open_pool "$FALLBACK" "$FALLBACK_CAP"
            ;;
        "${PRIMARY_CAP}/0")
            echo "NOOP: ${PRIMARY} already open (middle stage); opening ${FALLBACK} only"
            open_pool "$FALLBACK" "$FALLBACK_CAP"
            ;;
        "${PRIMARY_CAP}/${FALLBACK_CAP}")
            echo "NOOP: both burst pools already open (0/${PRIMARY_CAP}, 0/${FALLBACK_CAP})"
            ;;
        *) fail_run "burst maxima ${stage} are not an enable-burst stage" ;;
    esac
    final_check
}

op_set_burst_maxima() {
    local current_primary current_fallback current name target pass
    current_primary=$(pool_max "$PRIMARY")
    current_fallback=$(pool_max "$FALLBACK")
    # Lower first, read back, then raise: the aggregate never exceeds the cap.
    for pass in lower raise; do
        for name in "$PRIMARY" "$FALLBACK"; do
            if [ "$name" = "$PRIMARY" ]; then
                target=$PRIMARY_MAX current=$current_primary
            else
                target=$FALLBACK_MAX current=$current_fallback
            fi
            [[ "$current" =~ ^[0-9]+$ ]] || fail_run "burst pool '${name}' is absent or has no integer max_nodes"
            if { [ "$pass" = lower ] && [ "$target" -lt "$current" ]; } \
                || { [ "$pass" = raise ] && [ "$target" -gt "$current" ]; }; then
                update_bounds_command "$name" "$target"
                mutate "pool-bounds:${name}:0/${target}" "${pass} pool ${name} from 0/${current} to 0/${target}" "${UPDATE_CMD[@]}"
                verify_pool "$name" "$(size_of "$name")" 0 "$target"
            fi
        done
    done
    [ "$current_primary/$current_fallback" != "$PRIMARY_MAX/$FALLBACK_MAX" ] \
        || echo "NOOP: burst maxima already 0/${PRIMARY_MAX} and 0/${FALLBACK_MAX}"
    final_check
}

op_remove_burst() {
    local name
    # Second observation (the first was the initial admission), with an
    # identity check between the two.
    [ "$APPLY" != true ] || compare none "between the two observations"
    admit "second observation"
    reread
    if [ -n "$(cluster_expanders)" ]; then
        cluster_update "reset cluster expanders to the DigitalOcean default" ""
    else
        echo "NOOP: cluster expanders already default"
    fi
    for name in "$PRIMARY" "$FALLBACK"; do
        if [ "$(pool_bounds "$name")" = absent ]; then
            echo "NOOP: pool '${name}' already absent"
            continue
        fi
        mutate "pool-deleted:${name}" "delete pool ${name}" \
            doctl kubernetes cluster node-pool delete "$CLUSTER_ID" "$(pool_id "$name")" --force
    done
    if [ "$APPLY" = true ]; then
        reread
        [ -z "$(cluster_expanders)" ] || fail_run "readback: cluster expanders are '$(cluster_expanders)', expected the default"
        jq -e --arg b "$BASELINE" --arg p "$PRIMARY" --arg f "$FALLBACK" '
            [.[] | select(.name == $p or .name == $f
                or ((.labels // {})["node-type"] == "github-runner" and .name != $b))] | length == 0' \
            <<<"$POOLS_JSON" > /dev/null || fail_run "readback: runner pools other than ${BASELINE} remain"
        echo "READBACK: only ${BASELINE} remains among runner pools; expanders default"
    fi
    final_check
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

trap summary EXIT

if [ "$APPLY" = true ]; then
    # The snapshot was taken by the workflow's admission step: nothing may
    # have changed since.
    compare none "between the admission snapshot and this run"
fi
admit "initial"
read_state || fail_run "could not read cluster state"
BEFORE_PRIMARY=$(pool_bounds "$PRIMARY")
BEFORE_FALLBACK=$(pool_bounds "$FALLBACK")
BEFORE_EXPANDERS=$(cluster_expanders)

case "$OPERATION" in
    create-burst) op_create_burst ;;
    configure-expander) op_configure_expander ;;
    enable-burst) op_enable_burst ;;
    set-burst-maxima) op_set_burst_maxima ;;
    remove-burst) op_remove_burst ;;
esac
