#!/bin/bash

# Verify the runner pod's shared resource budget survives a chart render.
#
# Why this test exists: ARC's containerMode.type "dind" renders the Docker
# daemon sidecar from a hardcoded chart template with NO resources field, and
# silently FILTERS OUT any user-supplied container named "dind". Re-introducing
# containerMode.type: "dind" would therefore drop the dind memory reservation
# without any error, warning, or diff in the values file - and reintroduce the
# intermittent out-of-memory failures this configuration exists to fix.
#
# This renders deploy/dind-values.yaml with Helm and asserts the invariants.
# It needs helm, jq and network access to the chart registry; it does NOT need
# cluster access.
#
# Usage: ./test/verify-runner-resources.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
CHART_VERSION="${CHART_VERSION:-0.14.2}"
KUBE_VERSION="${KUBE_VERSION:-1.36.3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/deploy/dind-values.yaml"

# Node budget for github-runners-pool-16g (s-8vcpu-16gb).
NODE_ALLOCATABLE_MI=13639     # 13967028Ki
NODE_ALLOCATABLE_CPU_M=7880
SYSTEM_OVERHEAD_MI=694        # cilium, kube-proxy, csi, do-node-agent
SYSTEM_OVERHEAD_CPU_M=522
REQUIRED_HEADROOM_MI=2048
REQUIRED_HEADROOM_CPU_M=1000
PODS_PER_NODE=2
MAX_RUNNERS=4
POOL_MAX_NODES=2

FAILURES=0

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }

echo "======================================================"
info "Runner Resource Reservation Verification"
echo "======================================================"
echo ""

for tool in helm jq python; do
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${RED}❌ Required tool not found: $tool${NC}"
        exit 1
    fi
done

if [ ! -f "$VALUES_FILE" ]; then
    echo -e "${RED}❌ Values file not found: $VALUES_FILE${NC}"
    exit 1
fi

# --- Static check on the values file -----------------------------------------
info "Checking deploy/dind-values.yaml..."

if grep -qE '^[[:space:]]*type:[[:space:]]*"?dind"?' "$VALUES_FILE" \
   && grep -qE '^containerMode:' "$VALUES_FILE"; then
    fail "containerMode.type: dind is set - this DROPS the dind resources block"
    echo "   ARC filters out a user-supplied container named 'dind' when"
    echo "   containerMode.type is 'dind', and renders its own with no limits."
else
    pass "containerMode.type is not set to dind"
fi
echo ""

# --- Render the chart --------------------------------------------------------
info "Rendering chart ${CHART_VERSION} (kube ${KUBE_VERSION})..."

RENDER=$(helm template redducklabs-runners "$CHART" \
    --version "$CHART_VERSION" \
    --kube-version "$KUBE_VERSION" \
    -f "$VALUES_FILE" \
    --set githubConfigSecret.github_token=PLACEHOLDER \
    --set controllerServiceAccount.name=arc-gha-rs-controller \
    --set controllerServiceAccount.namespace=arc-systems 2>&1) || {
        echo -e "${RED}❌ helm template failed${NC}"
        echo "$RENDER" | tail -20
        exit 1
    }

pass "Chart rendered successfully"
echo ""

# Convert the AutoscalingRunnerSet document to JSON for assertions.
SPEC_JSON=$(printf '%s' "$RENDER" | python -c '
import sys, yaml, json
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "AutoscalingRunnerSet":
        print(json.dumps(doc))
        break
')

if [ -z "$SPEC_JSON" ]; then
    echo -e "${RED}❌ No AutoscalingRunnerSet found in rendered output${NC}"
    exit 1
fi

# --- Assertions --------------------------------------------------------------
info "Checking rendered pod spec..."

pod_resource() {  # requests|limits, cpu|memory
    printf '%s' "$SPEC_JSON" | jq -r ".spec.template.spec.resources.$1.$2 // \"\""
}

container_resource() {  # container name, containers|initContainers, requests|limits, cpu|memory
    printf '%s' "$SPEC_JSON" | jq -r \
        --arg n "$1" --arg f "$3" \
        ".spec.template.spec.$2[]? | select(.name==\$n) | .resources[\$f].$4 // \"\""
}

POD_REQ_MEM=$(pod_resource requests memory)
POD_REQ_CPU=$(pod_resource requests cpu)
POD_LIM_MEM=$(pod_resource limits memory)

if [ "$POD_REQ_MEM" = "5Gi" ]; then
    pass "pod memory request: $POD_REQ_MEM"
else
    fail "pod memory request is '$POD_REQ_MEM', expected '5Gi'"
fi
if [ "$POD_REQ_CPU" = "3" ]; then
    pass "pod CPU request:    $POD_REQ_CPU"
else
    fail "pod CPU request is '$POD_REQ_CPU', expected '3'"
fi
if [ "$POD_LIM_MEM" = "6Gi" ]; then
    pass "pod memory limit:   $POD_LIM_MEM"
else
    fail "pod memory limit is '$POD_LIM_MEM', expected '6Gi'"
fi

for container_spec in "runner containers" "dind initContainers"; do
    container_name=${container_spec%% *}
    container_list=${container_spec##* }
    for resource_type in requests limits; do
        for resource_name in cpu memory; do
            value=$(container_resource "$container_name" "$container_list" "$resource_type" "$resource_name")
            if [ -z "$value" ]; then
                pass "$container_name has no container-level $resource_type.$resource_name"
            else
                fail "$container_name has competing container-level $resource_type.$resource_name=$value; use pod-level resources"
            fi
        done
    done
done

# dind must be a native sidecar, otherwise the runner starts before dockerd.
DIND_RESTART=$(printf '%s' "$SPEC_JSON" | jq -r \
    '.spec.template.spec.initContainers[]? | select(.name=="dind") | .restartPolicy // ""')
[ "$DIND_RESTART" = "Always" ] \
    && pass "dind runs as a native sidecar (restartPolicy: Always)" \
    || fail "dind restartPolicy is '$DIND_RESTART', expected 'Always' (requires Kubernetes >= 1.29)"

# The floating docker:dind tag silently changes the Docker version under builds.
DIND_IMAGE=$(printf '%s' "$SPEC_JSON" | jq -r \
    '.spec.template.spec.initContainers[]? | select(.name=="dind") | .image // ""')
if [ "$DIND_IMAGE" = "docker:dind" ] || [ "$DIND_IMAGE" = "docker:latest" ]; then
    fail "dind image '$DIND_IMAGE' is a floating tag - pin an explicit version"
else
    pass "dind image is pinned: $DIND_IMAGE"
fi

# DOCKER_HOST is injected automatically in dind mode but is OURS in default mode.
DOCKER_HOST_SET=$(printf '%s' "$SPEC_JSON" | jq -r \
    '[.spec.template.spec.containers[]? | select(.name=="runner") | .env[]? | select(.name=="DOCKER_HOST")] | length')
[ "$DOCKER_HOST_SET" = "1" ] \
    && pass "runner has DOCKER_HOST set" \
    || fail "runner is missing DOCKER_HOST - it will not find the Docker daemon"
echo ""

# --- Two pods per node -------------------------------------------------------
info "Checking the two-pods-per-node invariant..."

to_mi() {  # accepts Gi / Mi
    case "$1" in
        *Gi) python -c "print(int(float('${1%Gi}') * 1024))" ;;
        *Mi) python -c "print(int(float('${1%Mi}')))" ;;
        *)   echo 0 ;;
    esac
}

to_millicpu() {  # accepts whole CPU or millicpu values
    case "$1" in
        *m) echo "${1%m}" ;;
        '' ) echo 0 ;;
        * )  python -c "print(int(float('$1') * 1000))" ;;
    esac
}

REQ_TOTAL_MI=$(to_mi "$POD_REQ_MEM")
REQ_TOTAL_CPU_M=$(to_millicpu "$POD_REQ_CPU")
BUDGET_MI=$(( NODE_ALLOCATABLE_MI - SYSTEM_OVERHEAD_MI ))
BUDGET_CPU_M=$(( NODE_ALLOCATABLE_CPU_M - SYSTEM_OVERHEAD_CPU_M ))
TWO_POD_MI=$(( PODS_PER_NODE * REQ_TOTAL_MI ))
TWO_POD_CPU_M=$(( PODS_PER_NODE * REQ_TOTAL_CPU_M ))
THREE_POD_MI=$(( (PODS_PER_NODE + 1) * REQ_TOTAL_MI ))
THREE_POD_CPU_M=$(( (PODS_PER_NODE + 1) * REQ_TOTAL_CPU_M ))

echo "  pod requests:         ${REQ_TOTAL_MI}Mi / ${REQ_TOTAL_CPU_M}m"
echo "  node allocatable:     ${NODE_ALLOCATABLE_MI}Mi / ${NODE_ALLOCATABLE_CPU_M}m"
echo "  usable after system:  ${BUDGET_MI}Mi / ${BUDGET_CPU_M}m"
echo "  required headroom:    ${REQUIRED_HEADROOM_MI}Mi / ${REQUIRED_HEADROOM_CPU_M}m"

if [ "$REQ_TOTAL_MI" -eq 0 ] || [ "$REQ_TOTAL_CPU_M" -eq 0 ]; then
    fail "cannot prove two-pod scheduling without pod-level CPU and memory requests"
elif [ $(( TWO_POD_MI + REQUIRED_HEADROOM_MI )) -le "$BUDGET_MI" ] \
   && [ $(( TWO_POD_CPU_M + REQUIRED_HEADROOM_CPU_M )) -le "$BUDGET_CPU_M" ]; then
    pass "two pods retain at least 2Gi memory and 1000m CPU headroom"
else
    fail "two pods plus required headroom do not fit the recorded node budget"
fi

if [ "$REQ_TOTAL_MI" -eq 0 ] || [ "$REQ_TOTAL_CPU_M" -eq 0 ]; then
    fail "cannot prove that a third pod is unschedulable without pod-level resource requests"
elif [ "$THREE_POD_MI" -gt "$BUDGET_MI" ] || [ "$THREE_POD_CPU_M" -gt "$BUDGET_CPU_M" ]; then
    pass "a third pod cannot fit the recorded node budget"
else
    fail "a third pod fits the recorded node budget; packing would exceed two pods per node"
fi
echo ""

# --- Scale set vs pool coupling ---------------------------------------------
info "Checking scale set bounds..."
MAXR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.maxRunners // 0')
MINR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.minRunners // 0')
echo "  minRunners=${MINR} maxRunners=${MAXR}"
if [ "$MAXR" = "$MAX_RUNNERS" ]; then
    pass "maxRunners is capped at ${MAX_RUNNERS}"
else
    fail "maxRunners is ${MAXR}, expected ${MAX_RUNNERS}"
fi

REQUIRED_NODES=$(( (MAXR + PODS_PER_NODE - 1) / PODS_PER_NODE ))
if [ "$REQUIRED_NODES" -eq "$POOL_MAX_NODES" ]; then
    pass "maxRunners=${MAXR} maps to ${REQUIRED_NODES} nodes at ${PODS_PER_NODE} pods per node"
else
    fail "maxRunners=${MAXR} maps to ${REQUIRED_NODES} nodes, expected ${POOL_MAX_NODES}"
fi
echo ""

# --- Offline workflow fixtures ----------------------------------------------
# These run the real shell bodies embedded in the workflows with command
# doubles at their mutation boundaries. They deliberately do not inspect YAML
# text for a guard: a mismatched expected_sha must make the shell body exit
# before the mock observes Helm, doctl, kubectl, or a mutating GitHub REST call.
info "Checking offline deploy, scale, capacity, and revision guards..."

FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT
FIXTURE_ACTUAL_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

materialize_workflow_step() {  # workflow, exact step name, expected SHA, max runners, min nodes, max nodes, output file
    python - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import os
import re
import sys
import yaml

workflow, step_name, expected_sha, max_runners, min_nodes, max_nodes, output = sys.argv[1:]
with open(workflow, encoding="utf-8") as source:
    document = yaml.safe_load(source)

for job in (document.get("jobs") or {}).values():
    for step in job.get("steps") or []:
        if step.get("name") == step_name and "run" in step:
            shell = step["run"]
            replacements = {
                "github.event.inputs.action": "scale-custom",
                "github.event.inputs.apply": "true",
                "github.event.inputs.expected_sha": expected_sha,
                "github.event.inputs.max_runners": max_runners,
                "github.event.inputs.min_runners": "2",
                "github.event.inputs.max_nodes": max_nodes,
                "github.event.inputs.min_nodes": min_nodes,
                "github.event.inputs.namespace": "arc-runners",
                "github.event.inputs.pool_name": "github-runners-pool-16g",
                "github.event.inputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "needs.validate-inputs.outputs.max_runners": max_runners,
                "needs.validate-inputs.outputs.min_runners": "2",
                "needs.validate-inputs.outputs.namespace": "arc-runners",
                "needs.validate-inputs.outputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "steps.validate.outputs.max_nodes": max_nodes,
                "steps.validate.outputs.min_nodes": min_nodes,
                "steps.validate.outputs.pool_name": "github-runners-pool-16g",
                "steps.resolve.outputs.cluster_id": "fixture-cluster",
                "steps.resolve.outputs.pool_id": "fixture-pool",
                "github.repository_owner": "redducklabs",
            }
            def replace(match):
                expression = match.group(1).strip()
                if expression in replacements:
                    return replacements[expression]
                if expression.startswith("secrets."):
                    return "fixture-token"
                if expression.startswith("vars."):
                    return "fixture"
                return "fixture"
            shell = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", replace, shell)
            with open(output, "a", encoding="utf-8") as target:
                target.write(shell)
                target.write("\n")
            raise SystemExit(0)

raise SystemExit(f"workflow step not found: {step_name}")
PY
}

materialize_workflow_token() {  # workflow, token, expected SHA, max runners, min nodes, max nodes, output file
    python - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import re
import sys
import yaml

workflow, token, expected_sha, max_runners, min_nodes, max_nodes, output = sys.argv[1:]
with open(workflow, encoding="utf-8") as source:
    document = yaml.safe_load(source)

for job in (document.get("jobs") or {}).values():
    for step in job.get("steps") or []:
        shell = step.get("run", "")
        if token not in shell:
            continue
        replacements = {
            "github.event.inputs.expected_sha": expected_sha,
            "github.event.inputs.max_runners": max_runners,
            "github.event.inputs.min_runners": "2",
            "github.event.inputs.max_nodes": max_nodes,
            "github.event.inputs.min_nodes": min_nodes,
            "github.event.inputs.apply": "true",
            "needs.validate-inputs.outputs.max_runners": max_runners,
            "needs.validate-inputs.outputs.min_runners": "2",
            "needs.validate-inputs.outputs.namespace": "arc-runners",
            "needs.validate-inputs.outputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
            "steps.validate.outputs.max_nodes": max_nodes,
            "steps.validate.outputs.min_nodes": min_nodes,
            "steps.resolve.outputs.cluster_id": "fixture-cluster",
            "steps.resolve.outputs.pool_id": "fixture-pool",
        }
        def replace(match):
            expression = match.group(1).strip()
            if expression in replacements:
                return replacements[expression]
            if expression.startswith("secrets."):
                return "fixture-token"
            if expression.startswith("vars."):
                return "fixture"
            return "fixture"
        shell = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", replace, shell)
        with open(output, "a", encoding="utf-8") as target:
            target.write(shell)
            target.write("\n")
        raise SystemExit(0)

raise SystemExit(f"workflow mutation step not found for token: {token}")
PY
}

run_fixture() {  # script, mutation log, output log
    local fixture_script=$1 mutation_log=$2 output_log=$3
    (
        set -o pipefail
        export GITHUB_OUTPUT="$FIXTURE_DIR/github-output"
        export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
        export CLUSTER_NAME=redducklabs-cluster
        export CLUSTER_CONTEXT=do-sfo3-redducklabs-cluster
        export RELEASE_NAME=redducklabs-runners
        git() {
            if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
                printf '%s\n' "$FIXTURE_ACTUAL_SHA"
                return 0
            fi
            command git "$@"
        }
        helm() {
            case " $* " in
                *" upgrade "*|*" rollback "*|*" uninstall "*) echo "helm $*" >> "$mutation_log" ;;
            esac
            if [ "$1" = "get" ] && [ "$2" = "values" ]; then
                echo '{"minRunners":2,"maxRunners":4}'
            fi
            return 0
        }
        doctl() {
            case " $* " in
                *" node-pool update "*) echo "doctl $*" >> "$mutation_log" ; return 0 ;;
                *" cluster list "*) echo '[{"name":"redducklabs-cluster","id":"fixture-cluster"}]' ; return 0 ;;
                *" node-pool list "*) echo '[{"id":"fixture-pool","name":"github-runners-pool-16g","min_nodes":2,"max_nodes":1,"count":1,"size":"s-8vcpu-16gb","auto_scale":true,"labels":{"node-type":"github-runner"},"taints":[{"key":"github-runner"}]}]' ; return 0 ;;
            esac
            return 0
        }
        kubectl() {
            case " $* " in
                *" apply "*|*" create "*|*" delete "*|*" patch "*) echo "kubectl $*" >> "$mutation_log" ;;
            esac
            return 0
        }
        curl() {
            case " $* " in
                *" -X POST "*|*" -X PATCH "*|*" -X PUT "*|*" -X DELETE "*) echo "curl $*" >> "$mutation_log" ;;
            esac
            echo '{"id":1,"runner_groups":[],"repositories":[]}'
            return 0
        }
        sleep() { :; }
        source "$fixture_script"
    ) >"$output_log" 2>&1
}

run_named_step() {  # workflow, step name, expected SHA, max runners, min nodes, max nodes
    local workflow=$1 step_name=$2 expected_sha=$3 max_runners=$4 min_nodes=$5 max_nodes=$6
    local safe_step_name
    safe_step_name=$(printf '%s' "$step_name" | tr -c '[:alnum:]' '_')
    local script
    script="$FIXTURE_DIR/$(basename "$workflow").${safe_step_name}.sh"
    : > "$script"
    materialize_workflow_step "$workflow" "$step_name" "$expected_sha" "$max_runners" "$min_nodes" "$max_nodes" "$script" || return 1
    run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"
}

assert_rejects_oversized_max() {  # label, workflow, validation step
    : > "$FIXTURE_DIR/mutations"
    if run_named_step "$2" "$3" "$FIXTURE_ACTUAL_SHA" 5 2 2; then
        fail "$1 accepts maxRunners=5; it must reject values above $MAX_RUNNERS"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "$1 reached a mutation while rejecting maxRunners=5"
    else
        pass "$1 rejects maxRunners=5 before mutation"
    fi
}

assert_node_pool_bounds() {
    local workflow=.github/workflows/node-pool-sizing.yml
    local step='Validate inputs against deploy/dind-values.yaml'
    : > "$FIXTURE_DIR/mutations"
    if ! run_named_step "$workflow" "$step" "$FIXTURE_ACTUAL_SHA" 4 2 2; then
        fail "Node Pool Sizing rejects the required 2/2 production bounds"
    elif run_named_step "$workflow" "$step" "$FIXTURE_ACTUAL_SHA" 4 1 2 \
      || run_named_step "$workflow" "$step" "$FIXTURE_ACTUAL_SHA" 4 2 3; then
        fail "Node Pool Sizing accepts bounds other than 2/2"
    else
        pass "Node Pool Sizing accepts only production bounds 2/2"
    fi
}

assert_live_capacity_drift_fails() {
    : > "$FIXTURE_DIR/mutations"
    if run_named_step .github/workflows/deploy-runners.yml 'Check node pool capacity' "$FIXTURE_ACTUAL_SHA" 4 2 2; then
        fail "Deploy accepts live runner-pool drift (fixture reports min=2, max=1, count=1)"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy reached a mutation after live capacity drift"
    else
        pass "Deploy rejects live runner-pool capacity drift before mutation"
    fi
}

assert_sha_guarded_boundary() {  # label, workflow, validation step, mutation token, mutation command label
    local label=$1 workflow=$2 validation_step=$3 mutation_token=$4 mutation_label=$5
    local mismatched=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local script="$FIXTURE_DIR/${label// /_}.sh"

    : > "$script"
    if ! materialize_workflow_step "$workflow" "$validation_step" "$mismatched" 4 2 2 "$script" \
       || ! materialize_workflow_token "$workflow" "$mutation_token" "$mismatched" 4 2 2 "$script"; then
        fail "$label has no executable expected_sha guard and $mutation_label boundary"
    else
        : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
       || [ -s "$FIXTURE_DIR/mutations" ] \
       || ! grep -qiE 'expected[_ -]?sha|checkout.*sha' "$FIXTURE_DIR/output"; then
        fail "$label does not reject a mismatched expected_sha before $mutation_label"
    else
        pass "$label mismatched expected_sha stops before $mutation_label"
    fi
    fi

    : > "$script"
    if ! materialize_workflow_step "$workflow" "$validation_step" "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" \
       || ! materialize_workflow_token "$workflow" "$mutation_token" "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "$label matching-SHA fixture could not be materialized"
    else
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
       && [ -s "$FIXTURE_DIR/mutations" ]; then
        pass "$label matching expected_sha reaches $mutation_label"
    else
        fail "$label matching expected_sha does not reach $mutation_label"
    fi
    fi
}

assert_rejects_oversized_max 'Scale Runners' .github/workflows/scale-runners.yml 'Validate and sanitize inputs'
assert_rejects_oversized_max 'Deploy' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs'
assert_node_pool_bounds
assert_live_capacity_drift_fails

assert_sha_guarded_boundary 'Scale Runners' .github/workflows/scale-runners.yml 'Validate and sanitize inputs' 'helm upgrade' Helm
assert_sha_guarded_boundary 'Node Pool Sizing' .github/workflows/node-pool-sizing.yml 'Validate inputs against deploy/dind-values.yaml' 'node-pool update' doctl
assert_sha_guarded_boundary 'Deploy' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'helm upgrade --install arc' Helm
assert_sha_guarded_boundary 'Deploy runner-group REST' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'actions/runner-groups' 'GitHub runner-group REST mutation'
assert_sha_guarded_boundary 'Deploy rollback' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'helm rollback' 'Helm rollback'
echo ""

echo "======================================================"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}✅ All runner resource checks passed${NC}"
    echo "======================================================"
    exit 0
else
    echo -e "${RED}❌ ${FAILURES} check(s) failed${NC}"
    echo "======================================================"
    exit 1
fi
