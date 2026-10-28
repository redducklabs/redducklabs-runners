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

verify_hosted_runner_policy_behavior() {
    # Exercise the CI policy step itself rather than duplicating its validation
    # logic here. This catches a removed, renamed, or weakened workflow guard.
    local workflow_file="${REPO_ROOT}/.github/workflows/validate-config.yml"
    local temporary_dir validator fixture_dir fixture_name output

    temporary_dir="$(mktemp -d)"
    validator="${temporary_dir}/validate-hosted-runners.sh"
    fixture_dir="${temporary_dir}/workflows"
    trap 'rm -rf "${temporary_dir}"' RETURN

    python3 - "$workflow_file" > "$validator" <<'PY'
import sys
import yaml

workflow_path = sys.argv[1]
with open(workflow_path, encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

for step in workflow["jobs"]["validate"]["steps"]:
    if step.get("name") == "Enforce GitHub-hosted runner policy":
        print(step["run"])
        break
else:
    raise SystemExit(
        "Enforce GitHub-hosted runner policy step is missing from "
        f"{workflow_path}"
    )
PY

    info "Exercising the GitHub-hosted runner policy against repository workflows..."
    WORKFLOW_DIR="${REPO_ROOT}/.github/workflows" bash "$validator"
    pass "Repository workflows use literal ubuntu-latest runners"

    mkdir -p "$fixture_dir"
    cat > "${fixture_dir}/self-hosted.yml" <<'YAML'
name: Hostile self-hosted runner fixture
on: workflow_dispatch
jobs:
  hostile:
    runs-on: self-hosted
    steps:
      - run: true
YAML
    cat > "${fixture_dir}/redducklabs-runners.yml" <<'YAML'
name: Hostile Red Duck Labs runner fixture
on: workflow_dispatch
jobs:
  hostile:
    runs-on: redducklabs-runners
    steps:
      - run: true
YAML
    cat > "${fixture_dir}/dynamic.yml" <<'YAML'
name: Hostile dynamic runner fixture
on: workflow_dispatch
jobs:
  hostile:
    runs-on: ${{ matrix.runner }}
    strategy:
      matrix:
        runner: [ubuntu-latest]
    steps:
      - run: true
YAML

    for fixture_name in self-hosted redducklabs-runners dynamic; do
        if output=$(WORKFLOW_DIR="${fixture_dir}/${fixture_name}.yml" bash "$validator" 2>&1); then
            fail "${fixture_name} runner fixture was accepted"
        elif [[ "$output" == *"expected literal 'ubuntu-latest'"* ]]; then
            pass "${fixture_name} runner fixture was rejected"
        else
            fail "${fixture_name} runner fixture did not report a runner-policy violation"
            echo "$output"
        fi
    done
}

# Node budgets. The baseline pool is s-8vcpu-16gb (measured 13967028Ki /
# 7880m on the live baseline nodes). The primary burst pool is s-8vcpu-16gb-amd
# and the fallback burst pool s-8vcpu-16gb-intel (spec Ruling 38): the same
# 16 GiB / 8 vCPU / 320 GB shape, but no node of either size has run in this
# cluster, so their allocatable below is ASSUMED equal to the measured
# s-8vcpu-16gb figure. The live pool-state gate checks headroom on every Ready
# node against its real allocatable, and acceptance Phases A (AMD) and B
# (Intel) measure it; correct these values if the measurement differs.
# The six values below are read through ${!alloc_mi_var} / ${!alloc_cpu_var}.
# shellcheck disable=SC2034
NODE_ALLOCATABLE_MI_s_8vcpu_16gb=13639     # 13967028Ki
# shellcheck disable=SC2034
NODE_ALLOCATABLE_CPU_M_s_8vcpu_16gb=7880
# shellcheck disable=SC2034
NODE_ALLOCATABLE_MI_s_8vcpu_16gb_amd=13639     # assumed, see above
# shellcheck disable=SC2034
NODE_ALLOCATABLE_CPU_M_s_8vcpu_16gb_amd=7880   # assumed, see above
# shellcheck disable=SC2034
NODE_ALLOCATABLE_MI_s_8vcpu_16gb_intel=13639   # assumed, see above
# shellcheck disable=SC2034
NODE_ALLOCATABLE_CPU_M_s_8vcpu_16gb_intel=7880 # assumed, see above
SYSTEM_OVERHEAD_MI=694        # cilium, kube-proxy, csi, do-node-agent
SYSTEM_OVERHEAD_CPU_M=522
REQUIRED_HEADROOM_MI=2048
REQUIRED_HEADROOM_CPU_M=1000
PODS_PER_NODE=2
# Burst capacity: baseline pool 2 nodes plus burst pools 6 + 2 nodes.
BASELINE_NODES=2
BURST_MAX_NODES=8
MAX_RUNNERS=20
MAX_MIN_RUNNERS=4

FAILURES=0

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }

if [ "${1:-}" = "--test-hosted-runner-policy" ]; then
    verify_hosted_runner_policy_behavior
    [ "$FAILURES" -eq 0 ]
    exit $?
fi

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

echo ""
info "Checking GitHub-hosted workflow runner policy..."
verify_hosted_runner_policy_behavior

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
AUTOMOUNT_SERVICE_ACCOUNT_TOKEN=$(printf '%s' "$SPEC_JSON" | jq -r \
    'if .spec.template.spec | has("automountServiceAccountToken")
     then (.spec.template.spec.automountServiceAccountToken | tostring)
     else "" end')

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
if [ "$AUTOMOUNT_SERVICE_ACCOUNT_TOKEN" = "false" ]; then
    pass "runner pod disables service-account token automount"
else
    fail "runner pod automountServiceAccountToken is '$AUTOMOUNT_SERVICE_ACCOUNT_TOKEN', expected 'false'"
fi

SERVICE_ACCOUNT_TOKEN_VOLUMES=$(printf '%s' "$SPEC_JSON" | jq -r '
    [.spec.template.spec.volumes[]?
     | select(any(.projected.sources[]?; has("serviceAccountToken")))] | length')
SERVICE_ACCOUNT_TOKEN_MOUNTS=$(printf '%s' "$SPEC_JSON" | jq -r '
    [(.spec.template.spec.containers[]?, .spec.template.spec.initContainers[]?)
     | .volumeMounts[]?
     | select(.mountPath == "/var/run/secrets/kubernetes.io/serviceaccount")] | length')
if [ "$SERVICE_ACCOUNT_TOKEN_VOLUMES" = "0" ] && [ "$SERVICE_ACCOUNT_TOKEN_MOUNTS" = "0" ]; then
    pass "runner template has no injected service-account token volume or mount"
else
    fail "runner template contains service-account token material (volumes=$SERVICE_ACCOUNT_TOKEN_VOLUMES mounts=$SERVICE_ACCOUNT_TOKEN_MOUNTS)"
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
if [ -z "$DIND_IMAGE" ]; then
    fail "dind image is empty - pin an explicit version"
elif [ "$DIND_IMAGE" = "docker:dind" ] || [ "$DIND_IMAGE" = "docker:latest" ] || [[ "$DIND_IMAGE" = *:latest ]]; then
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

RUNNER_SOCKET_MOUNTS=$(printf '%s' "$SPEC_JSON" | jq -r \
    '[.spec.template.spec.containers[]? | select(.name=="runner") | .volumeMounts[]? | select(.name=="dind-sock" and .mountPath=="/var/run")] | length')
DIND_SOCKET_MOUNTS=$(printf '%s' "$SPEC_JSON" | jq -r \
    '[.spec.template.spec.initContainers[]? | select(.name=="dind") | .volumeMounts[]? | select(.name=="dind-sock" and .mountPath=="/var/run")] | length')
SOCKET_VOLUME=$(printf '%s' "$SPEC_JSON" | jq -r \
    '[.spec.template.spec.volumes[]? | select(.name=="dind-sock" and has("emptyDir"))] | length')
if [ "$RUNNER_SOCKET_MOUNTS" = "1" ] && [ "$DIND_SOCKET_MOUNTS" = "1" ] && [ "$SOCKET_VOLUME" = "1" ]; then
    pass "runner and native dind share the dind-sock volume at /var/run"
else
    fail "runner/dind Docker socket wiring is incomplete (runner=$RUNNER_SOCKET_MOUNTS dind=$DIND_SOCKET_MOUNTS volume=$SOCKET_VOLUME)"
fi
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
TWO_POD_MI=$(( PODS_PER_NODE * REQ_TOTAL_MI ))
TWO_POD_CPU_M=$(( PODS_PER_NODE * REQ_TOTAL_CPU_M ))
THREE_POD_MI=$(( (PODS_PER_NODE + 1) * REQ_TOTAL_MI ))
THREE_POD_CPU_M=$(( (PODS_PER_NODE + 1) * REQ_TOTAL_CPU_M ))

for node_size in s_8vcpu_16gb s_8vcpu_16gb_amd s_8vcpu_16gb_intel; do
    size_label=${node_size//_/-}
    alloc_mi_var="NODE_ALLOCATABLE_MI_${node_size}"
    alloc_cpu_var="NODE_ALLOCATABLE_CPU_M_${node_size}"
    BUDGET_MI=$(( ${!alloc_mi_var} - SYSTEM_OVERHEAD_MI ))
    BUDGET_CPU_M=$(( ${!alloc_cpu_var} - SYSTEM_OVERHEAD_CPU_M ))

    echo "  [${size_label}] pod requests:        ${REQ_TOTAL_MI}Mi / ${REQ_TOTAL_CPU_M}m"
    echo "  [${size_label}] node allocatable:    ${!alloc_mi_var}Mi / ${!alloc_cpu_var}m"
    echo "  [${size_label}] usable after system: ${BUDGET_MI}Mi / ${BUDGET_CPU_M}m"
    echo "  [${size_label}] required headroom:   ${REQUIRED_HEADROOM_MI}Mi / ${REQUIRED_HEADROOM_CPU_M}m"

    if [ "$REQ_TOTAL_MI" -eq 0 ] || [ "$REQ_TOTAL_CPU_M" -eq 0 ]; then
        fail "${size_label}: cannot prove two-pod scheduling without pod-level CPU and memory requests"
    elif [ $(( TWO_POD_MI + REQUIRED_HEADROOM_MI )) -le "$BUDGET_MI" ] \
       && [ $(( TWO_POD_CPU_M + REQUIRED_HEADROOM_CPU_M )) -le "$BUDGET_CPU_M" ]; then
        pass "${size_label}: two pods retain at least 2Gi memory and 1000m CPU headroom"
    else
        fail "${size_label}: two pods plus required headroom do not fit the recorded node budget"
    fi

    if [ "$REQ_TOTAL_MI" -eq 0 ] || [ "$REQ_TOTAL_CPU_M" -eq 0 ]; then
        fail "${size_label}: cannot prove that a third pod is unschedulable without pod-level resource requests"
    elif [ "$THREE_POD_MI" -gt "$BUDGET_MI" ] || [ "$THREE_POD_CPU_M" -gt "$BUDGET_CPU_M" ]; then
        pass "${size_label}: a third pod cannot fit the recorded node budget"
    else
        fail "${size_label}: a third pod fits the recorded node budget; packing would exceed two pods per node"
    fi
done
echo ""

# --- Scale set vs pool coupling ---------------------------------------------
info "Checking scale set bounds..."
MAXR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.maxRunners // 0')
MINR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.minRunners // 0')
echo "  minRunners=${MINR} maxRunners=${MAXR}"
if [ "$MAXR" = "$MAX_RUNNERS" ]; then
    pass "maxRunners is ${MAX_RUNNERS}"
else
    fail "maxRunners is ${MAXR}, expected ${MAX_RUNNERS}"
fi

CEILING=$(( PODS_PER_NODE * (BASELINE_NODES + BURST_MAX_NODES) ))
if [ "$MAXR" -le "$CEILING" ]; then
    pass "maxRunners=${MAXR} fits ${PODS_PER_NODE} x (${BASELINE_NODES} baseline + ${BURST_MAX_NODES} burst) = ${CEILING} pod slots"
else
    fail "maxRunners=${MAXR} exceeds the ${CEILING} pod slots the pools can host"
fi

if [ "$MINR" -le "$MAX_MIN_RUNNERS" ]; then
    pass "minRunners=${MINR} is at most ${MAX_MIN_RUNNERS}"
else
    fail "minRunners=${MINR} exceeds ${MAX_MIN_RUNNERS}"
fi
echo ""

# --- Burst and drain contracts on the real rendered manifest -------------------
CONTRACT_TOOL="${REPO_ROOT}/scripts/validate-runner-isolation-contract.py"

render_values() {  # values file, extra helm args...
    local values_file=$1
    shift
    helm template redducklabs-runners "$CHART" \
        --version "$CHART_VERSION" \
        --kube-version "$KUBE_VERSION" \
        -f "$values_file" "$@" \
        --set githubConfigSecret.github_token=PLACEHOLDER \
        --set controllerServiceAccount.name=arc-gha-rs-controller \
        --set controllerServiceAccount.namespace=arc-systems
}

assert_burst_render() {
    if printf '%s' "$RENDER" | python -B "$CONTRACT_TOOL" \
        --contract burst --kind manifest --min-runners 2 --max-runners 20 \
        --runner-group private; then
        pass "rendered manifest satisfies the burst contract (2/20)"
    else
        fail "rendered manifest does not satisfy the burst contract (2/20)"
    fi
}

assert_drain_render() {
    local generated drain_render
    generated="$(mktemp)"
    if ! python -B "${REPO_ROOT}/scripts/render-drain-values.py" "$generated"; then
        fail "scripts/render-drain-values.py failed"
        rm -f "$generated"
        return
    fi
    if python -B "$CONTRACT_TOOL" \
        --contract drain --kind values --min-runners 2 --max-runners 4 \
        --runner-group private < "$generated"; then
        pass "generated drain values satisfy the drain contract (2/4, helm get values shape)"
    else
        fail "generated drain values do not satisfy the drain contract (2/4)"
    fi
    if ! drain_render=$(render_values "$generated" 2>&1); then
        fail "helm template with the generated drain values failed"
        rm -f "$generated"
        return
    fi
    rm -f "$generated"
    if printf '%s' "$drain_render" | python -B "$CONTRACT_TOOL" \
        --contract drain --kind manifest --min-runners 2 --max-runners 4 \
        --runner-group private; then
        pass "rendered manifest from the generated values satisfies the drain contract (2/4)"
    else
        fail "rendered manifest from the generated values does not satisfy the drain contract (2/4)"
    fi
    if printf '%s' "$drain_render" | python -B "$CONTRACT_TOOL" \
        --contract burst --kind manifest --min-runners 2 --max-runners 4 \
        --runner-group private 2>/dev/null; then
        fail "drain render is also accepted as burst; the contracts are not distinct"
    else
        pass "drain render is not accepted as burst"
    fi
}

assert_null_for_required_value_is_rejected() {
    local mutated
    mutated=$(printf '%s' "$RENDER" | python -c '
import sys
import yaml

docs = list(yaml.safe_load_all(sys.stdin))
for doc in docs:
    if doc and doc.get("kind") == "AutoscalingRunnerSet":
        doc["spec"]["template"]["spec"]["nodeSelector"] = None
sys.stdout.write(yaml.safe_dump_all(docs))
')
    if printf '%s' "$mutated" | python -B "$CONTRACT_TOOL" \
        --contract burst --kind manifest --min-runners 2 --max-runners 20 \
        --runner-group private 2>/dev/null; then
        fail "burst contract accepts a manifest with nodeSelector: null"
    else
        pass "burst contract rejects a manifest with nodeSelector: null"
    fi
}

assert_burst_render
assert_drain_render
assert_null_for_required_value_is_rejected
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
FIXTURE_POOL_MIN=2
FIXTURE_POOL_MAX=2
FIXTURE_POOL_COUNT=2

materialize_workflow_step() {  # workflow, exact step name, expected SHA, max runners, min nodes, max nodes, output file
    python - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import os
import re
import shlex
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
                "inputs.action": "scale-custom",
                "inputs.apply": "true",
                "inputs.min_nodes": min_nodes,
                "inputs.max_nodes": max_nodes,
                "inputs.pool_name": "github-runners-pool-16g",
                "inputs.operation": "deploy",
                "inputs.accept_privileged_runner_co_tenancy": "true",
                "inputs.acknowledge_emergency_stop": "false",
                "inputs.min_runners": "2",
                "inputs.max_runners": max_runners,
                "inputs.expected_sha": expected_sha,
                "inputs.namespace": "arc-runners",
                "inputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "github.event.inputs.operation": "deploy",
                "github.event.inputs.accept_privileged_runner_co_tenancy": "true",
                "github.event.inputs.acknowledge_emergency_stop": "false",
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
                "needs.validate-inputs.outputs.expected_sha": expected_sha,
                "needs.validate-inputs.outputs.operation": "deploy",
                "needs.validate-inputs.outputs.acknowledge_emergency_stop": "false",
                "needs.validate-inputs.outputs.namespace": "arc-runners",
                "needs.validate-inputs.outputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "steps.validate.outputs.max_nodes": max_nodes,
                "steps.validate.outputs.min_nodes": min_nodes,
                "steps.validate.outputs.pool_name": "github-runners-pool-16g",
                "steps.validate.outputs.apply": "true",
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
                for name, value in (step.get("env") or {}).items():
                    rendered = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", replace, str(value))
                    target.write(f"export {name}={shlex.quote(rendered)}\n")
                target.write(shell)
                target.write("\n")
            raise SystemExit(0)

raise SystemExit(f"workflow step not found: {step_name}")
PY
}

materialize_workflow_token() {  # workflow, token, expected SHA, max runners, min nodes, max nodes, output file
    python - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import re
import shlex
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
            "inputs.action": "scale-custom",
            "inputs.apply": "true",
            "inputs.min_nodes": min_nodes,
            "inputs.max_nodes": max_nodes,
            "inputs.pool_name": "github-runners-pool-16g",
            "inputs.operation": "deploy",
            "inputs.accept_privileged_runner_co_tenancy": "true",
            "inputs.acknowledge_emergency_stop": "false",
            "inputs.min_runners": "2",
            "inputs.max_runners": max_runners,
            "inputs.expected_sha": expected_sha,
            "inputs.namespace": "arc-runners",
            "inputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
            "github.event.inputs.operation": "deploy",
            "github.event.inputs.accept_privileged_runner_co_tenancy": "true",
            "github.event.inputs.acknowledge_emergency_stop": "false",
            "github.event.inputs.max_runners": max_runners,
            "github.event.inputs.min_runners": "2",
            "github.event.inputs.max_nodes": max_nodes,
            "github.event.inputs.min_nodes": min_nodes,
            "github.event.inputs.apply": "true",
            "needs.validate-inputs.outputs.max_runners": max_runners,
            "needs.validate-inputs.outputs.min_runners": "2",
            "needs.validate-inputs.outputs.expected_sha": expected_sha,
            "needs.validate-inputs.outputs.operation": "deploy",
            "needs.validate-inputs.outputs.acknowledge_emergency_stop": "false",
            "needs.validate-inputs.outputs.namespace": "arc-runners",
            "needs.validate-inputs.outputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
            "steps.validate.outputs.max_nodes": max_nodes,
            "steps.validate.outputs.min_nodes": min_nodes,
            "steps.validate.outputs.pool_name": "github-runners-pool-16g",
            "steps.validate.outputs.apply": "true",
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
            for name, value in (step.get("env") or {}).items():
                rendered = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", replace, str(value))
                target.write(f"export {name}={shlex.quote(rendered)}\n")
            target.write(shell)
            target.write("\n")
        raise SystemExit(0)

raise SystemExit(f"workflow mutation step not found for token: {token}")
PY
}

run_fixture() {  # script, mutation log, output log
    local fixture_script=$1 mutation_log=$2 output_log=$3
    : > "$FIXTURE_DIR/sha-reads"
    : > "$FIXTURE_DIR/helm-reads"
    : > "$FIXTURE_DIR/github-output"
    : > "$FIXTURE_DIR/github-summary"
    : > "$FIXTURE_DIR/pool-read-count"
    : > "$FIXTURE_DIR/cluster-read-count"
    : > "$FIXTURE_DIR/node-read-count"
    : > "$FIXTURE_DIR/helm-values-read-count"
    : > "$FIXTURE_DIR/asrs-read-count"
    rm -f "$FIXTURE_DIR/pool-updated"
    rm -f "$FIXTURE_DIR/helm-updated"
    rm -f "$FIXTURE_DIR/helm-updated-min" "$FIXTURE_DIR/helm-updated-max"
    rm -f "$FIXTURE_DIR/bootstrap-created"
    cat > "$FIXTURE_DIR/rollback-manifest.yaml" <<'YAML'
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: redducklabs-runners
spec:
  githubConfigUrl: https://github.com/redducklabs
  githubConfigSecret: redducklabs-runners-gha-rs-github-secret
  runnerScaleSetName: redducklabs-runners
  minRunners: 2
  maxRunners: 2
  runnerGroup: redducklabs-private-runners
  template:
    spec:
    automountServiceAccountToken: false
    imagePullSecrets:
      - name: do-registry-secret
    nodeSelector:
      node-type: github-runner
    tolerations:
      - effect: NoSchedule
        key: github-runner
        operator: Equal
        value: "true"
    restartPolicy: Never
    serviceAccountName: redducklabs-runners-gha-rs-no-permission
    containers:
      - name: runner
        command: [/home/runner/run.sh]
        image: registry.digitalocean.com/redducklabs/github-runner:latest
        imagePullPolicy: Always
        env:
          - name: DOCKER_HOST
            value: unix:///var/run/docker.sock
          - name: RUNNER_WAIT_FOR_DOCKER_IN_SECONDS
            value: "120"
        resources:
          limits:
            memory: 10Gi
          requests:
            cpu: "2"
            memory: 5Gi
        securityContext:
          allowPrivilegeEscalation: true
          readOnlyRootFilesystem: false
          runAsGroup: 121
          runAsUser: 1001
        volumeMounts:
          - mountPath: /home/runner/_work
            name: work
          - mountPath: /var/run
            name: dind-sock
      initContainers:
        - name: init-dind-externals
          image: registry.digitalocean.com/redducklabs/github-runner:latest
          command: [cp]
          args: [-r, /home/runner/externals/., /home/runner/tmpDir/]
          volumeMounts:
            - mountPath: /home/runner/tmpDir
              name: dind-externals
        - name: dind
          image: docker:29.7.2-dind
          args: [dockerd, --host=unix:///var/run/docker.sock, '--group=$(DOCKER_GROUP_GID)']
          env:
            - name: DOCKER_GROUP_GID
              value: "123"
          resources:
            limits:
              memory: 10Gi
            requests:
              cpu: "1"
              memory: 5Gi
          restartPolicy: Always
          securityContext:
            privileged: true
          startupProbe:
            exec:
              command: [docker, info]
            failureThreshold: 24
            initialDelaySeconds: 0
            periodSeconds: 5
          volumeMounts:
            - mountPath: /home/runner/_work
              name: work
            - mountPath: /var/run
              name: dind-sock
            - mountPath: /home/runner/externals
              name: dind-externals
    volumes:
      - emptyDir: {}
        name: work
      - emptyDir: {}
        name: dind-sock
      - emptyDir: {}
        name: dind-externals
YAML
    # Build the behavioral fixture from the committed desired values so exact
    # contract checks fail only for the mutation selected by a test case.
    python3 - deploy/dind-values.yaml "$FIXTURE_DIR/rollback-manifest.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    values = yaml.safe_load(stream)
template = values["template"]
template["spec"]["restartPolicy"] = "Never"
template["spec"]["serviceAccountName"] = "redducklabs-runners-gha-rs-no-permission"
manifest = {
    "apiVersion": "actions.github.com/v1alpha1",
    "kind": "AutoscalingRunnerSet",
    "metadata": {"name": "redducklabs-runners"},
    "spec": {
        "githubConfigUrl": "https://github.com/redducklabs",
        "githubConfigSecret": "redducklabs-runners-gha-rs-github-secret",
        "runnerScaleSetName": "redducklabs-runners",
        "minRunners": 2,
        "maxRunners": 2,
        "runnerGroup": "redducklabs-private-runners",
        "template": template,
    },
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    yaml.safe_dump(manifest, stream, sort_keys=False)
PY
    # This is independently rooted in the verbatim fa2a4df values fixture,
    # never derived by reshaping the density target.
    python3 - test/fixtures/arc-legacy-isolated-values.yaml "$FIXTURE_DIR/legacy-manifest.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    values = yaml.safe_load(stream)
template = values["template"]
template["spec"]["restartPolicy"] = "Never"
template["spec"]["serviceAccountName"] = "redducklabs-runners-gha-rs-no-permission"
manifest = {
    "apiVersion": "actions.github.com/v1alpha1",
    "kind": "AutoscalingRunnerSet",
    "metadata": {"name": "redducklabs-runners"},
    "spec": {
        "githubConfigUrl": "https://github.com/redducklabs",
        "githubConfigSecret": "redducklabs-runners-gha-rs-github-secret",
        "runnerScaleSetName": "redducklabs-runners",
        "minRunners": 2,
        "maxRunners": 8,
        "template": template,
    },
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    yaml.safe_dump(manifest, stream, sort_keys=False)
PY
    if [ "${FIXTURE_TEMPLATE_DRIFT:-none}" != none ]; then
        python3 - "$FIXTURE_DIR/rollback-manifest.yaml" "$FIXTURE_DIR/legacy-manifest.yaml" "${FIXTURE_TEMPLATE_DRIFT}" <<'PY'
import sys
import yaml

density_path, legacy_path, mutation = sys.argv[1:]
for path in (density_path, legacy_path):
    with open(path, encoding="utf-8") as stream:
        document = yaml.safe_load(stream)
    spec = document["spec"]["template"]["spec"]
    if mutation == "automount":
        spec.pop("automountServiceAccountToken", None)
    elif mutation == "placement":
        spec["nodeSelector"] = {"node-type": "worker"}
    elif mutation == "token":
        spec["volumes"].append({
            "name": "kube-api-access-fixture",
            "projected": {"sources": [{"serviceAccountToken": {"path": "token"}}]},
        })
    elif mutation == "extra":
        spec["hostNetwork"] = True
    elif mutation == "host_namespace":
        spec["hostPID"] = True
    elif mutation == "security":
        spec["containers"][0]["securityContext"]["allowPrivilegeEscalation"] = False
    else:
        raise SystemExit(f"unknown fixture template mutation: {mutation}")
    with open(path, "w", encoding="utf-8") as stream:
        yaml.safe_dump(document, stream, sort_keys=False)
PY
    fi
    (
        export GITHUB_OUTPUT="$FIXTURE_DIR/github-output"
        export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
        export RUNNER_TEMP="$FIXTURE_DIR"
        export GH_TOKEN=fixture-token
        export CLUSTER_NAME=redducklabs-cluster
        export CLUSTER_CONTEXT=do-sfo3-redducklabs-cluster
        export RELEASE_NAME=redducklabs-runners
        export RUNNER_SCALE_SET_NAME=redducklabs-runners
        export CANONICAL_RUNNER_IMAGE=registry.digitalocean.com/redducklabs/github-runner:latest
        export ARC_CHART_VERSION=0.14.2
        export FIXTURE_ACTUAL_SHA
        export FIXTURE_MUTATION_LOG="$mutation_log"
        export FIXTURE_SHA_READ_LOG="$FIXTURE_DIR/sha-reads"
        export FIXTURE_HELM_READ_LOG="$FIXTURE_DIR/helm-reads"
        export FIXTURE_ROLLBACK_MANIFEST="$FIXTURE_DIR/rollback-manifest.yaml"
        export FIXTURE_LEGACY_MANIFEST="$FIXTURE_DIR/legacy-manifest.yaml"
        export FIXTURE_ROLLBACK_INVALID="${FIXTURE_ROLLBACK_INVALID:-none}"
        export FIXTURE_POST_ROLLBACK_ASRS_DRIFT="${FIXTURE_POST_ROLLBACK_ASRS_DRIFT:-none}"
        export FIXTURE_POOL_MIN FIXTURE_POOL_MAX FIXTURE_POOL_COUNT
        export FIXTURE_POOL_SIZE="${FIXTURE_POOL_SIZE:-s-8vcpu-16gb}"
        export FIXTURE_POOL_WORKLOAD_LABEL="${FIXTURE_POOL_WORKLOAD_LABEL:-ci-cd}"
        export FIXTURE_POOL_TAINT_VALUE="${FIXTURE_POOL_TAINT_VALUE:-true}"
        export FIXTURE_POOL_TAINT_EFFECT="${FIXTURE_POOL_TAINT_EFFECT:-NoSchedule}"
        export FIXTURE_PROVIDER_TAINT_STYLE="${FIXTURE_PROVIDER_TAINT_STYLE:-lowercase}"
        export FIXTURE_POOL_EXTRA_LABEL="${FIXTURE_POOL_EXTRA_LABEL:-false}"
        export FIXTURE_POOL_EXTRA_TAINT="${FIXTURE_POOL_EXTRA_TAINT:-false}"
        export FIXTURE_NODE_WORKLOAD_LABEL="${FIXTURE_NODE_WORKLOAD_LABEL:-ci-cd}"
        export FIXTURE_NODE_TAINT_VALUE="${FIXTURE_NODE_TAINT_VALUE:-true}"
        export FIXTURE_NODE_EXTRA_BLOCKING_TAINT="${FIXTURE_NODE_EXTRA_BLOCKING_TAINT:-false}"
        export FIXTURE_READY_NODES="${FIXTURE_READY_NODES:-2}"
        export FIXTURE_SCALE_DEMAND="${FIXTURE_SCALE_DEMAND:-2}"
        export FIXTURE_PLATFORM_STATE="${FIXTURE_PLATFORM_STATE:-ready}"
        export FIXTURE_TRUST_FAILURE="${FIXTURE_TRUST_FAILURE:-false}"
        export FIXTURE_HELM_MAX="${FIXTURE_HELM_MAX:-2}"
        export FIXTURE_HELM_GROUP="${FIXTURE_HELM_GROUP:-redducklabs-private-runners}"
        export FIXTURE_HELM_POST_GROUP="${FIXTURE_HELM_POST_GROUP:-redducklabs-private-runners}"
        export FIXTURE_REVISION_GROUP="${FIXTURE_REVISION_GROUP:-redducklabs-private-runners}"
        export FIXTURE_SECOND_HELM_GROUP="${FIXTURE_SECOND_HELM_GROUP:-redducklabs-private-runners}"
        export FIXTURE_SECOND_ASRS_GROUP="${FIXTURE_SECOND_ASRS_GROUP:-redducklabs-private-runners}"
        export FIXTURE_CLUSTER_ID="${FIXTURE_CLUSTER_ID:-fixture-cluster}"
        export FIXTURE_SECOND_CLUSTER_ID="${FIXTURE_SECOND_CLUSTER_ID:-$FIXTURE_CLUSTER_ID}"
        export FIXTURE_POOL_ID="${FIXTURE_POOL_ID:-fixture-pool}"
        export FIXTURE_SECOND_POOL_ID="${FIXTURE_SECOND_POOL_ID:-$FIXTURE_POOL_ID}"
        export FIXTURE_SECOND_NODE_UID="${FIXTURE_SECOND_NODE_UID:-fixture-node-a-uid}"
        export FIXTURE_SA_STATE="${FIXTURE_SA_STATE:-absent}"
        export FIXTURE_SCALE_RELEASE_STATE="${FIXTURE_SCALE_RELEASE_STATE:-pinned}"
        export FIXTURE_SCALE_CHART_VERSION="${FIXTURE_SCALE_CHART_VERSION:-0.14.2}"
        export FIXTURE_REGISTRY_STATE="${FIXTURE_REGISTRY_STATE:-ready}"
        export FIXTURE_MISSING_CRD="${FIXTURE_MISSING_CRD:-none}"
        export FIXTURE_TEMPLATE_DRIFT="${FIXTURE_TEMPLATE_DRIFT:-none}"
        export FIXTURE_HELM_UPDATED="$FIXTURE_DIR/helm-updated"
        export FIXTURE_HELM_UPDATED_MIN="$FIXTURE_DIR/helm-updated-min"
        export FIXTURE_HELM_UPDATED_MAX="$FIXTURE_DIR/helm-updated-max"
        export FIXTURE_BOOTSTRAP_CREATED="$FIXTURE_DIR/bootstrap-created"
        export FIXTURE_POOL_RACE_COUNT="${FIXTURE_POOL_RACE_COUNT:-$FIXTURE_POOL_COUNT}"
        export FIXTURE_POOL_READ_COUNT="$FIXTURE_DIR/pool-read-count"
        export FIXTURE_CLUSTER_READ_COUNT="$FIXTURE_DIR/cluster-read-count"
        export FIXTURE_NODE_READ_COUNT="$FIXTURE_DIR/node-read-count"
        export FIXTURE_HELM_VALUES_READ_COUNT="$FIXTURE_DIR/helm-values-read-count"
        export FIXTURE_ASRS_READ_COUNT="$FIXTURE_DIR/asrs-read-count"
        export FIXTURE_POOL_UPDATED="$FIXTURE_DIR/pool-updated"
        git() {
            if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
                printf 'git %s\n' "$*" >> "$FIXTURE_SHA_READ_LOG"
                printf '%s\n' "$FIXTURE_ACTUAL_SHA"
                return 0
            fi
            command git "$@"
        }
        helm() {
            if [ "$1" = list ]; then
                if [[ " $* " == *" -n arc-systems "* ]]; then
                    echo '[{"name":"arc","chart":"gha-runner-scale-set-controller-0.14.2","status":"deployed"}]'
                elif [ "$FIXTURE_SCALE_RELEASE_STATE" = absent ]; then
                    echo '[]'
                else
                    printf '[{"name":"redducklabs-runners","chart":"gha-runner-scale-set-%s","status":"deployed"}]\n' "$FIXTURE_SCALE_CHART_VERSION"
                fi
                return 0
            fi
            if [ "$1" = history ]; then
                echo "helm $*" >> "$FIXTURE_HELM_READ_LOG"
                if [ "$FIXTURE_ROLLBACK_INVALID" = chart ]; then
                    echo '[{"revision":7,"chart":"gha-runner-scale-set-0.13.0","status":"superseded"}]'
                else
                    echo '[{"revision":7,"chart":"gha-runner-scale-set-0.14.2","status":"superseded"},{"revision":8,"chart":"gha-runner-scale-set-0.14.2","status":"deployed"}]'
                fi
                return 0
            fi
            if [ "$1" = get ] && [ "$2" = manifest ]; then
                echo "helm $*" >> "$FIXTURE_HELM_READ_LOG"
                if [ "$FIXTURE_ROLLBACK_INVALID" = manifest ]; then
                    sed 's/memory: 5Gi/memory: 4Gi/g' "$FIXTURE_ROLLBACK_MANIFEST"
                else
                    local manifest_min=2 manifest_max manifest_group base_manifest
                    manifest_max=$FIXTURE_HELM_MAX
                    manifest_group=$FIXTURE_HELM_GROUP
                    if [[ " $* " == *" --revision "* ]]; then
                        manifest_max=2
                        manifest_group=$FIXTURE_REVISION_GROUP
                    elif [ -e "$FIXTURE_HELM_UPDATED" ]; then
                        manifest_min=$(cat "$FIXTURE_HELM_UPDATED_MIN")
                        manifest_max=$(cat "$FIXTURE_HELM_UPDATED_MAX")
                        manifest_group=$FIXTURE_HELM_POST_GROUP
                    fi
                    base_manifest=$FIXTURE_ROLLBACK_MANIFEST
                    if [ "${FIXTURE_FORCE_LEGACY:-false}" = true ] || [ "$FIXTURE_HELM_MAX" = 8 ] || [[ " $* " == *" --revision "* ]] \
                      || [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        base_manifest=$FIXTURE_LEGACY_MANIFEST
                    fi
                    python3 - "$base_manifest" "$manifest_min" "$manifest_max" "$manifest_group" <<'PY'
import os
import sys
import yaml

path, minimum, maximum, group = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = yaml.safe_load(stream)
spec = manifest["spec"]
spec["minRunners"] = int(minimum)
spec["maxRunners"] = int(maximum)
if group in ("__missing__", "Default"):
    spec.pop("runnerGroup", None)
else:
    spec["runnerGroup"] = group
    if "resources" not in spec["template"]["spec"] and os.environ.get("FIXTURE_TEMPLATE_DRIFT") != "automount":
        spec["template"]["spec"]["automountServiceAccountToken"] = False
print(yaml.safe_dump(manifest, sort_keys=False))
PY
                fi
                return 0
            fi
            case " $* " in
                *" rollback "*) echo "helm $*" >> "$FIXTURE_MUTATION_LOG"; export FIXTURE_ROLLBACK_ACTIVE=true ;;
                *" upgrade "*)
                    echo "helm $*" >> "$FIXTURE_MUTATION_LOG"
                    : > "$FIXTURE_HELM_UPDATED"
                    for argument in "$@"; do
                        case "$argument" in
                            minRunners=*) printf '%s\n' "${argument#*=}" > "$FIXTURE_HELM_UPDATED_MIN" ;;
                            maxRunners=*) printf '%s\n' "${argument#*=}" > "$FIXTURE_HELM_UPDATED_MAX" ;;
                        esac
                    done
                    if [[ " $* " == *"minRunners=0"* ]] && [[ " $* " == *"maxRunners=0"* ]]; then
                        : > "$FIXTURE_BOOTSTRAP_CREATED"
                    fi
                    ;;
                *" uninstall "*) echo "helm $*" >> "$FIXTURE_MUTATION_LOG" ;;
            esac
            if [ "$1" = "get" ] && [ "$2" = "values" ]; then
                echo "helm $*" >> "$FIXTURE_HELM_READ_LOG"
                if [ "$FIXTURE_ROLLBACK_INVALID" = values ]; then
                    echo '{"minRunners":2,"maxRunners":4,"runnerGroup":"redducklabs-private-runners"}'
                else
                    local helm_min=2 helm_max=$FIXTURE_HELM_MAX helm_group=$FIXTURE_HELM_GROUP reads base_manifest
                    reads=$(wc -l < "$FIXTURE_HELM_VALUES_READ_COUNT")
                    echo read >> "$FIXTURE_HELM_VALUES_READ_COUNT"
                    if [[ " $* " == *" --revision "* ]]; then
                        helm_max=2
                        helm_group=$FIXTURE_REVISION_GROUP
                    elif [ -e "$FIXTURE_HELM_UPDATED" ]; then
                        helm_min=$(cat "$FIXTURE_HELM_UPDATED_MIN")
                        helm_max=$(cat "$FIXTURE_HELM_UPDATED_MAX")
                        helm_group=$FIXTURE_HELM_POST_GROUP
                    elif [ "$reads" -ge 1 ]; then
                        helm_group=$FIXTURE_SECOND_HELM_GROUP
                    fi
                    base_manifest=$FIXTURE_ROLLBACK_MANIFEST
                    if [ "${FIXTURE_FORCE_LEGACY:-false}" = true ] || [ "$FIXTURE_HELM_MAX" = 8 ] || [[ " $* " == *" --revision "* ]] \
                      || [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        base_manifest=$FIXTURE_LEGACY_MANIFEST
                    fi
                    python3 - "$base_manifest" "$helm_min" "$helm_max" "$helm_group" <<'PY'
import json
import os
import sys
import yaml

path, minimum, maximum, group = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = yaml.safe_load(stream)
template = manifest["spec"]["template"]["spec"]
template.pop("restartPolicy", None)
template.pop("serviceAccountName", None)
values = {"minRunners": int(minimum), "maxRunners": int(maximum), "template": {"spec": template}}
if group not in ("__missing__", "Default"):
    values["runnerGroup"] = group
    if "resources" not in template and os.environ.get("FIXTURE_TEMPLATE_DRIFT") != "automount":
        template["automountServiceAccountToken"] = False
print(json.dumps(values))
PY
                fi
            fi
            return 0
        }
        doctl() {
            case " $* " in
                *" node-pool update "*) echo "doctl $*" >> "$FIXTURE_MUTATION_LOG" ; : > "$FIXTURE_POOL_UPDATED" ; return 0 ;;
                *" cluster list "*)
                    local cluster_reads cluster_id
                    cluster_reads=$(wc -l < "$FIXTURE_CLUSTER_READ_COUNT")
                    echo read >> "$FIXTURE_CLUSTER_READ_COUNT"
                    cluster_id=$FIXTURE_CLUSTER_ID
                    if [ "$cluster_reads" -ge 1 ]; then cluster_id=$FIXTURE_SECOND_CLUSTER_ID; fi
                    printf '[{"name":"redducklabs-cluster","id":"%s"}]\n' "$cluster_id"
                    return 0
                    ;;
                *" node-pool list "*)
                    local reads max count pool_id
                    reads=$(wc -l < "$FIXTURE_POOL_READ_COUNT")
                    echo read >> "$FIXTURE_POOL_READ_COUNT"
                    max=$FIXTURE_POOL_MAX
                    count=$FIXTURE_POOL_COUNT
                    pool_id=$FIXTURE_POOL_ID
                    if [ -e "$FIXTURE_POOL_UPDATED" ]; then max=2; fi
                    if [ "$reads" -eq 1 ]; then
                        count=$FIXTURE_POOL_RACE_COUNT
                        pool_id=$FIXTURE_SECOND_POOL_ID
                    fi
                    local extra_label extra_taint taint_key taint_value_key taint_effect_key
                    extra_label=""; extra_taint=""
                    [ "$FIXTURE_POOL_EXTRA_LABEL" = true ] && extra_label=',"unexpected":"value"'
                    taint_key=key; taint_value_key=value; taint_effect_key=effect
                    if [ "$FIXTURE_PROVIDER_TAINT_STYLE" = uppercase ]; then
                        taint_key=Key; taint_value_key=Value; taint_effect_key=Effect
                    fi
                    [ "$FIXTURE_POOL_EXTRA_TAINT" = true ] && extra_taint=",{\"${taint_key}\":\"unexpected\",\"${taint_value_key}\":\"true\",\"${taint_effect_key}\":\"NoSchedule\"}"
                    printf '[{"id":"%s","name":"github-runners-pool-16g","min_nodes":%s,"max_nodes":%s,"count":%s,"size":"%s","auto_scale":true,"labels":{"node-type":"github-runner","workload-type":"%s"%s},"taints":[{"%s":"github-runner","%s":"%s","%s":"%s"}%s]}]\n' \
                      "$pool_id" "$FIXTURE_POOL_MIN" "$max" "$count" "$FIXTURE_POOL_SIZE" \
                      "$FIXTURE_POOL_WORKLOAD_LABEL" "$extra_label" "$taint_key" "$taint_value_key" \
                      "$FIXTURE_POOL_TAINT_VALUE" "$taint_effect_key" "$FIXTURE_POOL_TAINT_EFFECT" "$extra_taint" ; return 0 ;;
            esac
            return 0
        }
        kubectl() {
            case " $* " in
                *" apply "*|*" create "*|*" delete "*|*" patch "*) echo "kubectl $*" >> "$FIXTURE_MUTATION_LOG" ;;
                *" get namespace "*)
                    [ "$FIXTURE_PLATFORM_STATE" != missing ]
                    return
                    ;;
                *" get secret do-registry-secret "*)
                    if [ "$FIXTURE_PLATFORM_STATE" = missing ]; then return 1; fi
                    case "$FIXTURE_REGISTRY_STATE" in
                        ready)
                            echo '{"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"eyJhdXRocyI6eyJyZWdpc3RyeS5kaWdpdGFsb2NlYW4uY29tIjp7ImF1dGgiOiJmaXh0dXJlIn19fQ=="}}'
                            ;;
                        wrong_type)
                            echo '{"type":"Opaque","data":{".dockerconfigjson":"eyJhdXRocyI6eyJyZWdpc3RyeS5kaWdpdGFsb2NlYW4uY29tIjp7ImF1dGgiOiJmaXh0dXJlIn19fQ=="}}'
                            ;;
                        missing_auth)
                            echo '{"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"eyJhdXRocyI6e319fQ=="}}'
                            ;;
                        *) return 1 ;;
                    esac
                    return 0
                    ;;
                *" get serviceaccount redducklabs-runners-gha-rs-no-permission "*)
                    case "$FIXTURE_SA_STATE" in
                        absent)
                            if [ -e "$FIXTURE_BOOTSTRAP_CREATED" ]; then
                                echo '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"redducklabs-runners","meta.helm.sh/release-namespace":"arc-runners"}}}'
                            fi
                            ;;
                        helm)
                            echo '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"redducklabs-runners","meta.helm.sh/release-namespace":"arc-runners"}}}'
                            ;;
                        unmanaged) echo '{"metadata":{"labels":{},"annotations":{}}}' ;;
                        foreign)
                            echo '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"other-release","meta.helm.sh/release-namespace":"arc-runners"}}}'
                            ;;
                    esac
                    return 0
                    ;;
                *" get crd "*)
                    local crd_name
                    crd_name=${3:-}
                    if [ "$FIXTURE_PLATFORM_STATE" = missing ] || [ "$FIXTURE_MISSING_CRD" = "$crd_name" ]; then return 1; fi
                    echo '{"status":{"conditions":[{"type":"Established","status":"True"}]}}'
                    return 0
                    ;;
                *" get deployment "*)
                    if [ "$FIXTURE_PLATFORM_STATE" = stale ]; then
                        echo '{"items":[{"metadata":{"generation":2},"spec":{"replicas":1},"status":{"observedGeneration":1,"readyReplicas":0,"availableReplicas":0}}]}'
                    else
                        echo '{"items":[{"metadata":{"generation":1},"spec":{"replicas":1},"status":{"observedGeneration":1,"readyReplicas":1,"availableReplicas":1}}]}'
                    fi
                    return 0
                    ;;
                *" get nodes "*)
                    local node_reads first_uid
                    node_reads=$(wc -l < "$FIXTURE_NODE_READ_COUNT")
                    echo read >> "$FIXTURE_NODE_READ_COUNT"
                    first_uid='fixture-node-a-uid'
                    if [ "$node_reads" -ge 1 ]; then first_uid=$FIXTURE_SECOND_NODE_UID; fi
                    local node_extra_taint
                    node_extra_taint=""
                    [ "$FIXTURE_NODE_EXTRA_BLOCKING_TAINT" = true ] && node_extra_taint=',{"key":"maintenance","value":"true","effect":"NoSchedule"}'
                    if [ "$FIXTURE_READY_NODES" = 4 ]; then
                        printf '{"items":[{"metadata":{"uid":"%s"},"spec":{"providerID":"digitalocean://node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid"},"spec":{"providerID":"digitalocean://node-b"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-c-uid"},"spec":{"providerID":"digitalocean://node-c"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-d-uid"},"spec":{"providerID":"digitalocean://node-d"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\n' "$first_uid"
                    elif [ "$FIXTURE_READY_NODES" = 3 ]; then
                        printf '{"items":[{"metadata":{"uid":"%s"},"spec":{"providerID":"digitalocean://node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid"},"spec":{"providerID":"digitalocean://node-b"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-c-uid"},"spec":{"providerID":"digitalocean://node-c"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-d-uid"},"spec":{"providerID":"digitalocean://node-d"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}\n' "$first_uid"
                    elif [ "$FIXTURE_READY_NODES" = 2 ]; then
                        printf '{"items":[{"metadata":{"uid":"%s","labels":{"node-type":"github-runner","workload-type":"%s"}},"spec":{"providerID":"digitalocean://node-a","taints":[{"key":"github-runner","value":"%s","effect":"NoSchedule"}%s]},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid","labels":{"node-type":"github-runner","workload-type":"%s"}},"spec":{"providerID":"digitalocean://node-b","taints":[{"key":"github-runner","value":"%s","effect":"NoSchedule"}%s]},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\n' "$first_uid" "$FIXTURE_NODE_WORKLOAD_LABEL" "$FIXTURE_NODE_TAINT_VALUE" "$node_extra_taint" "$FIXTURE_NODE_WORKLOAD_LABEL" "$FIXTURE_NODE_TAINT_VALUE" "$node_extra_taint"
                    else
                        printf '{"items":[{"metadata":{"uid":"%s"},"spec":{"providerID":"digitalocean://node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid"},"spec":{"providerID":"digitalocean://node-b"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}\n' "$first_uid"
                    fi
                    return 0
                    ;;
                *" get pods "*) echo '{"items":[]}' ; return 0 ;;
                *" get autoscalingrunnersets.actions.github.com "*)
                    local asrs_reads asrs_group asrs_manifest asrs_drift
                    asrs_reads=$(wc -l < "$FIXTURE_ASRS_READ_COUNT")
                    echo read >> "$FIXTURE_ASRS_READ_COUNT"
                    asrs_group=redducklabs-private-runners
                    if [ "$asrs_reads" -ge 1 ]; then asrs_group=$FIXTURE_SECOND_ASRS_GROUP; fi
                    asrs_manifest=$FIXTURE_ROLLBACK_MANIFEST
                    if [ "${FIXTURE_FORCE_LEGACY:-false}" = true ] || [ "$FIXTURE_HELM_MAX" = 8 ] || [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        asrs_manifest=$FIXTURE_LEGACY_MANIFEST
                    fi
                    asrs_drift=none
                    if [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        asrs_drift=$FIXTURE_POST_ROLLBACK_ASRS_DRIFT
                    fi
                    python3 - "$asrs_manifest" "$asrs_group" "$([ -e "$FIXTURE_HELM_UPDATED" ] && cat "$FIXTURE_HELM_UPDATED_MIN" || echo 2)" "$([ -e "$FIXTURE_HELM_UPDATED" ] && cat "$FIXTURE_HELM_UPDATED_MAX" || echo "$FIXTURE_HELM_MAX")" "$asrs_drift" <<'PY'
import json
import os
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = yaml.safe_load(stream)
manifest["spec"]["runnerGroup"] = sys.argv[2]
manifest["spec"]["minRunners"] = int(sys.argv[3])
manifest["spec"]["maxRunners"] = int(sys.argv[4])
mutation = sys.argv[5]
if "resources" not in manifest["spec"]["template"]["spec"] and os.environ.get("FIXTURE_TEMPLATE_DRIFT") != "automount":
    manifest["spec"]["template"]["spec"]["automountServiceAccountToken"] = False
template = manifest["spec"]["template"]["spec"]
if mutation == "default":
    manifest["spec"]["runnerGroup"] = "Default"
elif mutation == "token":
    template["volumes"].append({
        "name": "kube-api-access-fixture",
        "projected": {"sources": [{"serviceAccountToken": {"path": "token"}}]},
    })
elif mutation == "placement":
    template["nodeSelector"] = {"node-type": "worker"}
elif mutation == "extra":
    template["hostNetwork"] = True
elif mutation != "none":
    raise SystemExit(f"unknown post-rollback ASRS mutation: {mutation}")
print(json.dumps({"items": [manifest]}))
PY
                    return 0
                    ;;
                *" get ephemeralrunnersets.actions.github.com "*) printf '{"items":[{"spec":{"replicas":%s}}]}\n' "$FIXTURE_SCALE_DEMAND" ; return 0 ;;
            esac
            return 0
        }
        curl() {
            case " $* " in
                *" -X POST "*|*" -X PATCH "*|*" -X PUT "*|*" -X DELETE "*) echo "curl $*" >> "$FIXTURE_MUTATION_LOG" ;;
            esac
            echo '{"id":1,"runner_groups":[],"repositories":[]}'
            return 0
        }
        gh() {
            if [ "$FIXTURE_TRUST_FAILURE" = true ] && [[ " $* " == *" runner-groups"* ]]; then
                return 1
            fi
            if [[ " $* " == *" api "* ]] \
               && { [[ " $* " == *" -X POST "* ]] || [[ " $* " == *" -X PATCH "* ]] \
                   || [[ " $* " == *" -X PUT "* ]] || [[ " $* " == *" -X DELETE "* ]] \
                   || [[ " $* " == *" --method POST "* ]] || [[ " $* " == *" --method PATCH "* ]] \
                   || [[ " $* " == *" --method PUT "* ]] || [[ " $* " == *" --method DELETE "* ]]; }; then
                echo "gh $*" >> "$FIXTURE_MUTATION_LOG"
            fi
            case "$*" in
                *'/repositories/1193238112'*) echo '{"id":1193238112,"name":"aurolegal.ai","full_name":"redducklabs/aurolegal.ai","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1025075333'*) echo '{"id":1025075333,"name":"autoduck","full_name":"redducklabs/autoduck","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1351028230'*) echo '{"id":1351028230,"name":"manager","full_name":"redducklabs/manager","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1033531555'*) echo '{"id":1033531555,"name":"platform-observability","full_name":"redducklabs/platform-observability","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1018231298'*) echo '{"id":1018231298,"name":"redducklabs","full_name":"redducklabs/redducklabs","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1154788719'*) echo '{"id":1154788719,"name":"redducklaw","full_name":"redducklabs/redducklaw","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1006277397'*) echo '{"id":1006277397,"name":"therapy-link","full_name":"redducklabs/therapy-link","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/776507734'*) echo '{"id":776507734,"name":"zipbot-internal","full_name":"redducklabs/zipbot-internal","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1037651737'*) echo '{"id":1037651737,"name":"zipbot-v2","full_name":"redducklabs/zipbot-v2","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1425956382'*) echo '{"id":1425956382,"name":"keel","full_name":"redducklabs/keel","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1418079240'*) echo '{"id":1418079240,"name":"superfood-shred","full_name":"redducklabs/superfood-shred","visibility":"private","private":true,"owner":{"login":"redducklabs"}}' ;;
                *'/actions/permissions/fork-pr-workflows-private-repos'*) echo '{"run_workflows_from_fork_pull_requests":false,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false,"require_approval_for_fork_pr_workflows":false}' ;;
                *'/repositories/1359405097'*) echo '{"id":1359405097,"name":"agent-handoff-toolkit","full_name":"redducklabs/agent-handoff-toolkit","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1271568186'*) echo '{"id":1271568186,"name":"fountainrank","full_name":"redducklabs/fountainrank","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}' ;;
                *'/repositories/1208056940'*) echo '{"id":1208056940,"name":"claude-control","full_name":"redducklabs/claude-control","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}' ;;
                *'repos/redducklabs/agent-handoff-toolkit/commits'*|*'repos/redducklabs/fountainrank/commits'*|*'repos/redducklabs/claude-control/commits'*) echo '[{"sha":"1111111111111111111111111111111111111111"}]' ;;
                *'repos/redducklabs/agent-handoff-toolkit/actions/workflows'*|*'repos/redducklabs/fountainrank/actions/workflows'*|*'repos/redducklabs/claude-control/actions/workflows'*) echo '{"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}' ;;
                *'repos/redducklabs/agent-handoff-toolkit/contents/'*|*'repos/redducklabs/fountainrank/contents/'*|*'repos/redducklabs/claude-control/contents/'*) printf '%s\n' 'jobs:' '  safe:' '    runs-on: ubuntu-latest' '    steps: []' ;;
                *'repos?type=public'*) echo '[]' ;;
                *'runner-groups?per_page=100'*)
                    if [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        echo '{"runner_groups":[{"id":777,"name":"redducklabs-private-runners","visibility":"selected","allows_public_repositories":false}]}'
                    else
                        echo '{"runner_groups":[]}'
                    fi
                    ;;
                *'--method POST'*'actions/runner-groups'*) echo '{"id":777,"name":"redducklabs-private-runners"}' ;;
                *'runner-groups/777/repositories?per_page=100'*) echo '{"repositories":[{"id":776507734,"visibility":"private","private":true},{"id":1006277397,"visibility":"private","private":true},{"id":1018231298,"visibility":"private","private":true},{"id":1025075333,"visibility":"private","private":true},{"id":1033531555,"visibility":"private","private":true},{"id":1037651737,"visibility":"private","private":true},{"id":1154788719,"visibility":"private","private":true},{"id":1193238112,"visibility":"private","private":true},{"id":1351028230,"visibility":"private","private":true},{"id":1418079240,"visibility":"private","private":true},{"id":1425956382,"visibility":"private","private":true}]}' ;;
                *'runner-groups/777'*) echo '{"id":777,"name":"redducklabs-private-runners","visibility":"selected","allows_public_repositories":false}' ;;
                *) echo '{"id":1,"runner_groups":[],"repositories":[]}' ;;
            esac
            return 0
        }
        sleep() { :; }
        export -f git helm doctl kubectl curl gh sleep
        bash -euo pipefail -c 'source "$1"' -- "$fixture_script"
    ) >"$output_log" 2>&1
}



assert_node_pool_operations_contract() {
    # The 8->2 / 2/2-only Node Pool Sizing workflow was replaced by the burst
    # operations (scripts/burst-pools.sh). Behavioral coverage (stateful
    # provider, expected_sha mismatch, identity races) lives in
    # test/verify-burst-autoscaling.sh; this checks the dispatch contract.
    if python3 - <<'PY'
import yaml

with open('.github/workflows/node-pool-sizing.yml', encoding='utf-8') as stream:
    workflow = yaml.safe_load(stream)
inputs = workflow.get('on', workflow.get(True))['workflow_dispatch']['inputs']
if set(inputs) != {'operation', 'primary_max', 'fallback_max', 'apply', 'expected_sha'}:
    raise SystemExit(f'unexpected Node Pool Sizing inputs: {sorted(inputs)}')
if inputs['operation'].get('options') != ['create-burst', 'configure-expander', 'enable-burst',
                                          'set-burst-maxima', 'remove-burst']:
    raise SystemExit('Node Pool Sizing operation choices are not the burst operations')
(job,) = workflow['jobs'].values()
steps = job['steps']
names = [step.get('name') for step in steps]
guard = names.index('Validate inputs and expected SHA')
if 'git rev-parse HEAD' not in steps[guard]['run'] or 'expected_sha' not in steps[guard]['run']:
    raise SystemExit('Node Pool Sizing validation does not compare expected_sha with the checkout')
gate = next(i for i, step in enumerate(steps) if 'verify-runner-pool-state.sh' in step.get('run', ''))
script = next(i for i, step in enumerate(steps) if 'scripts/burst-pools.sh' in step.get('run', ''))
if not guard < gate < script:
    raise SystemExit('Node Pool Sizing must verify expected_sha, then admit, then run burst-pools.sh')
for index, step in enumerate(steps[:guard]):
    if any(token in step.get('run', '') for token in ('doctl', 'kubectl', 'helm')):
        raise SystemExit(f'{step.get("name")} reaches the cluster before the expected_sha check')
if '--emit-identities' not in steps[gate]['run'] or '--identities' not in steps[script]['run']:
    raise SystemExit('Node Pool Sizing does not pass the admission identity snapshot to burst-pools.sh')
PY
    then
        pass "Node Pool Sizing exposes only the burst operations, SHA-guarded before admission and mutation"
    else
        fail "Node Pool Sizing burst-operation dispatch contract is incomplete"
    fi
}




assert_sha_guarded_boundary() {  # label, workflow, validation step, mutation token, mutation command label, expected mutation pattern
    local label=$1 workflow=$2 validation_step=$3 mutation_token=$4 mutation_label=$5 expected_mutation_pattern=$6
    local mismatched=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local script="$FIXTURE_DIR/${label// /_}.sh"

    : > "$script"
    if ! materialize_workflow_step "$workflow" "$validation_step" "$mismatched" 4 2 2 "$script" \
       || ! materialize_workflow_token "$workflow" "$mutation_token" "$mismatched" 4 2 2 "$script"; then
        fail "$label has no executable expected_sha guard and $mutation_label boundary"
    else
        : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "$label mismatched expected_sha fixture completed before $mutation_label"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "$label reached a mutation despite a mismatched expected_sha"
    elif ! grep -q '^git rev-parse ' "$FIXTURE_DIR/sha-reads"; then
        fail "$label did not read the checked-out SHA before stopping"
    elif ! grep -Fq "$mismatched" "$FIXTURE_DIR/output" \
      || ! grep -Fq "$FIXTURE_ACTUAL_SHA" "$FIXTURE_DIR/output"; then
        fail "$label stopped for a reason other than the mismatched expected_sha"
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
       && grep -Eq "$expected_mutation_pattern" "$FIXTURE_DIR/mutations"; then
        pass "$label matching expected_sha reaches $mutation_label"
    else
        sed -n '1,12p' "$FIXTURE_DIR/output" >&2
        fail "$label matching expected_sha does not reach the expected $mutation_label boundary"
    fi
    fi
}

write_fake_gh() {
    mkdir -p "$FIXTURE_DIR/fake-bin"
    cat > "$FIXTURE_DIR/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

joined="$*"
paginated=false
for argument in "$@"; do
    if [ "$argument" = --paginate ]; then
        paginated=true
    fi
done
body=""
if [[ " $joined " == *" --input - "* ]]; then
    body=$(cat)
fi
printf '%s\t%s\n' "$joined" "$body" >> "$GH_CALL_LOG"

repo_json() {
    local id=$1 name=$2 visibility=private identity_reads owner=redducklabs
    if [ "${GH_SCENARIO}" = public_allowlist ] && [ "$name" = manager ]; then
        visibility=public
    fi
    if [ "${GH_SCENARIO}" = unknown_allowlist ] && [ "$name" = manager ]; then
        name=unexpected-repository
    fi
    identity_reads=$(grep -c "/repositories/${id}" "$GH_CALL_LOG" || true)
    if [ "${GH_SCENARIO}" = post_readback_public ] \
      && [ "$name" = manager ] && [ "$identity_reads" -ge 2 ]; then
        visibility=public
    fi
    if [ "${GH_SCENARIO}" = post_readback_renamed ] \
      && [ "$name" = manager ] && [ "$identity_reads" -ge 2 ]; then
        name=renamed-manager
    fi
    if [ "${GH_SCENARIO}" = transferred_member ] && [ "$name" = keel ]; then
        owner=another-owner
    fi
    printf '{"id":%s,"name":"%s","full_name":"%s/%s","visibility":"%s","private":%s,"owner":{"login":"%s"}}\n' \
        "$id" "$name" "$owner" "$name" "$visibility" "$([ "$visibility" = private ] && echo true || echo false)" "$owner"
}

fork_policy_json() {
    local name=$1 target=${FORK_POLICY_TARGET:-keel}
    case "$name" in
        aurolegal.ai|autoduck|manager|platform-observability|redducklabs|redducklaw|therapy-link|zipbot-internal|zipbot-v2|keel|superfood-shred) ;;
        *)
            printf 'unexpected fork-PR policy read for %s\n' "$name" >&2
            exit 64
            ;;
    esac
    if [ "$name" != "$target" ]; then
        printf '{"run_workflows_from_fork_pull_requests":false,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false,"require_approval_for_fork_pr_workflows":false}\n'
        return
    fi
    case "${GH_SCENARIO}" in
        fork_policy_true) printf '{"run_workflows_from_fork_pull_requests":true,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false}\n' ;;
        fork_policy_missing) printf '{"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false}\n' ;;
        fork_policy_null) printf '{"run_workflows_from_fork_pull_requests":null}\n' ;;
        fork_policy_string) printf '{"run_workflows_from_fork_pull_requests":"false"}\n' ;;
        fork_policy_malformed) printf '{"run_workflows_from_fork_pull_requests":false\n' ;;
        fork_policy_array) printf '[{"run_workflows_from_fork_pull_requests":false}]\n' ;;
        fork_policy_multi) printf '{"run_workflows_from_fork_pull_requests":true}\n{"run_workflows_from_fork_pull_requests":false}\n' ;;
        fork_policy_error)
            printf '%s\n' 'HTTP 404: Not Found' >&2
            exit 1
            ;;
        *) printf '{"run_workflows_from_fork_pull_requests":false,"send_write_tokens_to_workflows":false,"send_secrets_and_variables":false,"require_approval_for_fork_pr_workflows":false}\n' ;;
    esac
}

case "$joined" in
    *"repos/redducklabs/"*"/actions/permissions/fork-pr-workflows-private-repos"*)
        if [[ " $joined " != *" --method GET "* ]]; then
            printf 'fork-PR policy read is not an explicit GET: %s\n' "$joined" >&2
            exit 64
        fi
        fork_repo=${joined#*repos/redducklabs/}
        fork_repo=${fork_repo%%/actions/permissions/fork-pr-workflows-private-repos*}
        fork_policy_json "$fork_repo"
        ;;
    *"/repositories/1193238112"*) repo_json 1193238112 aurolegal.ai ;;
    *"/repositories/1025075333"*) repo_json 1025075333 autoduck ;;
    *"/repositories/1351028230"*) repo_json 1351028230 manager ;;
    *"/repositories/1033531555"*) repo_json 1033531555 platform-observability ;;
    *"/repositories/1018231298"*) repo_json 1018231298 redducklabs ;;
    *"/repositories/1154788719"*) repo_json 1154788719 redducklaw ;;
    *"/repositories/1006277397"*) repo_json 1006277397 therapy-link ;;
    *"/repositories/776507734"*) repo_json 776507734 zipbot-internal ;;
    *"/repositories/1037651737"*) repo_json 1037651737 zipbot-v2 ;;
    *"/repositories/1425956382"*) repo_json 1425956382 keel ;;
    *"/repositories/1418079240"*) repo_json 1418079240 superfood-shred ;;
    *"/repositories/1359405097"*)
        printf '{"id":1359405097,"name":"agent-handoff-toolkit","full_name":"redducklabs/agent-handoff-toolkit","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}\n'
        ;;
    *"/repositories/1271568186"*)
        printf '{"id":1271568186,"name":"fountainrank","full_name":"redducklabs/fountainrank","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}\n'
        ;;
    *"/repositories/1208056940"*)
        printf '{"id":1208056940,"name":"claude-control","full_name":"redducklabs/claude-control","visibility":"public","private":false,"default_branch":"main","owner":{"login":"redducklabs"}}\n'
        ;;
    *"/repositories/4242"*)
        branch=main
        [ "${GH_SCENARIO}" = url_sensitive ] && branch='release/#density'
        metadata_reads=$(grep -c '/repositories/4242' "$GH_CALL_LOG" || true)
        if [ "${GH_SCENARIO}" = default_branch_drift ] && [ "$metadata_reads" -ge 2 ]; then
            branch=trunk
        fi
        printf '{"id":4242,"name":"public-repo","full_name":"redducklabs/public-repo","visibility":"public","private":false,"default_branch":"%s","owner":{"login":"redducklabs"}}\n' "$branch"
        ;;
    *"repos/redducklabs/public-repo/commits"*)
        sha=1111111111111111111111111111111111111111
        head_reads=$(grep -c 'repos/redducklabs/public-repo/commits' "$GH_CALL_LOG" || true)
        if [ "${GH_SCENARIO}" = head_drift ] && [ "$head_reads" -ge 2 ]; then
            sha=2222222222222222222222222222222222222222
        fi
        printf '[{"sha":"%s"}]\n' "$sha"
        ;;
    *"repos/redducklabs/agent-handoff-toolkit/commits"*|*"repos/redducklabs/fountainrank/commits"*|*"repos/redducklabs/claude-control/commits"*)
        printf '[{"sha":"1111111111111111111111111111111111111111"}]\n'
        ;;
    *"repos/redducklabs/agent-handoff-toolkit/actions/workflows"*|*"repos/redducklabs/fountainrank/actions/workflows"*|*"repos/redducklabs/claude-control/actions/workflows"*)
        printf '{"total_count":1,"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}\n'
        ;;
    *"repos/redducklabs/agent-handoff-toolkit/contents/.github/workflows/ci.yml"*|*"repos/redducklabs/fountainrank/contents/.github/workflows/ci.yml"*|*"repos/redducklabs/claude-control/contents/.github/workflows/ci.yml"*)
        printf '%s\n' 'jobs:' '  safe:' '    runs-on: ubuntu-latest' '    steps: []'
        ;;
    *"orgs/redducklabs/repos?type=public"*)
        if [ "${GH_SCENARIO}" = public_label ] || [ "${GH_SCENARIO}" = dynamic_runs_on ] \
          || [ "${GH_SCENARIO}" = workflow_schema ] || [ "${GH_SCENARIO}" = mixed_case_label ] \
          || [ "${GH_SCENARIO}" = later_page_public_label ] \
          || [ "${GH_SCENARIO}" = later_page_workflow_label ] \
          || [ "${GH_SCENARIO}" = managed_copilot ] \
          || [ "${GH_SCENARIO}" = managed_dependabot ] \
          || [ "${GH_SCENARIO}" = managed_codeql ] \
          || [ "${GH_SCENARIO}" = managed_dynamic_near_miss ] \
          || [ "${GH_SCENARIO}" = unknown_dynamic_path ] \
          || [ "${GH_SCENARIO}" = url_sensitive ] \
          || [ "${GH_SCENARIO}" = default_branch_drift ] \
          || [ "${GH_SCENARIO}" = absent_workflow ] \
          || [ "${GH_SCENARIO}" = absent_workflow_dir ] \
          || [ "${GH_SCENARIO}" = absent_workflow_listed ] \
          || [ "${GH_SCENARIO}" = absent_workflow_listing_error ] \
          || [ "${GH_SCENARIO}" = absent_workflow_capped ] \
          || [ "${GH_SCENARIO}" = head_drift ]; then
            if [ "${GH_SCENARIO}" = later_page_public_label ] && [ "$paginated" = true ]; then
                printf '[]\n[{"id":4242,"name":"public-repo","full_name":"redducklabs/public-repo","owner":{"login":"redducklabs"},"private":false,"default_branch":"main","visibility":"public"}]\n'
            else
                if [ "${GH_SCENARIO}" = later_page_public_label ]; then
                    printf '[]\n'
                else
                    if [ "${GH_SCENARIO}" = url_sensitive ]; then
                        printf '[{"id":4242,"name":"public-repo","full_name":"redducklabs/public-repo","owner":{"login":"redducklabs"},"private":false,"default_branch":"release/#density","visibility":"public"}]\n'
                    else
                        printf '[{"id":4242,"name":"public-repo","full_name":"redducklabs/public-repo","owner":{"login":"redducklabs"},"private":false,"default_branch":"main","visibility":"public"}]\n'
                    fi
                fi
            fi
        else
            printf '[]\n'
        fi
        ;;
    *"repos/redducklabs/public-repo/actions/workflows"*)
        if [ "${GH_SCENARIO}" = workflow_schema ]; then
            printf '{"total":1,"pipelines":[]}\n'
        elif [ "${GH_SCENARIO}" = later_page_public_label ] || [ "${GH_SCENARIO}" = later_page_workflow_label ]; then
            if [ "$paginated" = true ]; then
                printf '{"total_count":0,"workflows":[]}\n{"total_count":1,"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}\n'
            else
                printf '{"total_count":0,"workflows":[]}\n'
            fi
        elif [ "${GH_SCENARIO}" = managed_copilot ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/agents/copilot-pull-request-reviewer","state":"active"}]}\n'
        elif [ "${GH_SCENARIO}" = managed_dependabot ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/dependabot/dependabot-updates","state":"active"}]}\n'
        elif [ "${GH_SCENARIO}" = managed_codeql ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/github-code-scanning/codeql","state":"active"}]}\n'
        elif [ "${GH_SCENARIO}" = managed_dynamic_near_miss ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/dependabot/dependabot-updates-preview","state":"active"}]}\n'
        elif [ "${GH_SCENARIO}" = unknown_dynamic_path ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/agents/unrecognized","state":"active"}]}\n'
        elif [ "${GH_SCENARIO}" = url_sensitive ]; then
            printf '{"total_count":1,"workflows":[{"path":".github/workflows/density #1?.yml","state":"active"}]}\n'
        else
            printf '{"total_count":1,"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}\n'
        fi
        ;;
    *"repos/redducklabs/public-repo/contents/.github/workflows/density%20%231%3F.yml"*)
        if [[ " $joined " != *" --method GET "* ]] \
          || [[ " $joined " != *" -f ref=1111111111111111111111111111111111111111 "* ]]; then
            printf 'unsafe URL-sensitive contents request: %s\n' "$joined" >&2
            exit 64
        fi
        printf '%s\n' 'jobs:' '  safe:' '    runs-on: ubuntu-latest' '    steps: []'
        ;;
    *"repos/redducklabs/public-repo/contents/.github/workflows -f ref="*)
        if [[ " $joined " != *" --method GET "* ]] \
          || [[ " $joined " != *" -f ref=1111111111111111111111111111111111111111 "* ]]; then
            printf 'unsafe workflow directory request: %s\n' "$joined" >&2
            exit 64
        fi
        case "${GH_SCENARIO}" in
            absent_workflow)
                printf '[{"name":"release.yml","path":".github/workflows/release.yml","type":"file"}]\n'
                ;;
            absent_workflow_listed)
                printf '[{"name":"ci.yml","path":".github/workflows/ci.yml","type":"file"}]\n'
                ;;
            absent_workflow_capped)
                jq -cn '[range(1000) | {name: "w\(.).yml", path: ".github/workflows/w\(.).yml", type: "file"}]'
                ;;
            absent_workflow_dir)
                printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
                exit 1
                ;;
            *)
                printf '%s\n' 'gh: Server Error (HTTP 502)' >&2
                exit 1
                ;;
        esac
        ;;
    *"repos/redducklabs/public-repo/contents/.github/workflows/ci.yml"*)
        case "${GH_SCENARIO}" in
            absent_workflow | absent_workflow_dir | absent_workflow_listing_error)
                printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
                exit 1
                ;;
            absent_workflow_listed | absent_workflow_capped)
                printf '%s\n' 'gh: Server Error (HTTP 502)' >&2
                exit 1
                ;;
        esac
        if [ "${GH_SCENARIO}" = dynamic_runs_on ]; then
            printf '%s\n' 'jobs:' '  unsafe:' '    runs-on: ${{ matrix.runner }}' '    steps: []'
        elif [ "${GH_SCENARIO}" = mixed_case_label ]; then
            printf '%s\n' 'jobs:' '  unsafe:' '    runs-on: RedDuckLabs-Runners' '    steps: []'
        elif [ "${GH_SCENARIO}" = default_branch_drift ] || [ "${GH_SCENARIO}" = head_drift ]; then
            printf '%s\n' 'jobs:' '  safe:' '    runs-on: ubuntu-latest' '    steps: []'
        else
            printf '%s\n' 'jobs:' '  unsafe:' '    runs-on: redducklabs-runners' '    steps: []'
        fi
        ;;
    *"orgs/redducklabs/actions/runner-groups?per_page=100"*)
        if [ "${GH_SCENARIO}" = permission_failure ]; then
            printf '%s\n' 'HTTP 403: Resource not accessible by personal access token' >&2
            exit 1
        elif [ "${GH_SCENARIO}" = create ]; then
            printf '{"total_count":0,"runner_groups":[]}\n'
        elif [ "${GH_SCENARIO}" = later_page_group ]; then
            printf '{"total_count":0,"runner_groups":[]}\n{"total_count":1,"runner_groups":[{"id":777,"name":"redducklabs-private-runners","visibility":"all","allows_public_repositories":true,"restricted_to_workflows":false}]}\n'
        else
            printf '{"total_count":1,"runner_groups":[{"id":777,"name":"redducklabs-private-runners","visibility":"all","allows_public_repositories":true,"restricted_to_workflows":false}]}\n'
        fi
        ;;
    *"--method POST"*"orgs/redducklabs/actions/runner-groups"*)
        printf '{"id":777,"name":"redducklabs-private-runners"}\n'
        ;;
    *"--method PATCH"*"orgs/redducklabs/actions/runner-groups/777"*)
        printf '{"id":777,"name":"redducklabs-private-runners","visibility":"selected","allows_public_repositories":false}\n'
        ;;
    *"--method PUT"*"orgs/redducklabs/actions/runner-groups/777/repositories"*)
        if [ "${GH_SCENARIO}" = replacement_failure ]; then
            printf '%s\n' 'HTTP 403: Resource not accessible by personal access token' >&2
            exit 1
        fi
        printf '{}\n'
        ;;
    *"orgs/redducklabs/actions/runner-groups/777/repositories?per_page=100"*)
        if [ "${GH_SCENARIO}" = readback_drift ]; then
            printf '{"total_count":1,"repositories":[{"id":1193238112,"name":"aurolegal.ai","full_name":"redducklabs/aurolegal.ai","visibility":"private","private":true}]}\n'
        elif [ "${GH_SCENARIO}" = reduced_membership ]; then
            printf '{"total_count":11,"repositories":['
            printf '%s' \
              '{"id":776507734},' \
              '{"id":1006277397},' \
              '{"id":1018231298},' \
              '{"id":1025075333},' \
              '{"id":1033531555},' \
              '{"id":1037651737},' \
              '{"id":1154788719},' \
              '{"id":1193238112},' \
              '{"id":1351028230},' \
              '{"id":1418079240},' \
              '{"id":1425956382}'
            printf ']}\n'
        elif [ "${GH_SCENARIO}" = substituted_membership ] || [ "${GH_SCENARIO}" = unauthorized_addition ]; then
            printf '{"total_count":11,"repositories":['
            printf '%s' \
              '{"id":776507734},' \
              '{"id":1006277397},' \
              '{"id":1018231298},' \
              '{"id":1025075333},' \
              '{"id":1033531555},' \
              '{"id":1037651737},' \
              '{"id":1154788719},' \
              '{"id":1193238112},' \
              '{"id":1351028230},' \
              '{"id":1418079240},'
            if [ "${GH_SCENARIO}" = unauthorized_addition ]; then
                printf '%s' '{"id":1425956382},'
            fi
            printf '%s' '{"id":1334789692}'
            printf ']}\n'
        else
            printf '{"total_count":11,"repositories":['
            printf '%s' \
              '{"id":776507734,"name":"zipbot-internal","full_name":"redducklabs/zipbot-internal","visibility":"private","private":true},' \
              '{"id":1006277397,"name":"therapy-link","full_name":"redducklabs/therapy-link","visibility":"private","private":true},' \
              '{"id":1018231298,"name":"redducklabs","full_name":"redducklabs/redducklabs","visibility":"private","private":true},' \
              '{"id":1025075333,"name":"autoduck","full_name":"redducklabs/autoduck","visibility":"private","private":true},' \
              '{"id":1033531555,"name":"platform-observability","full_name":"redducklabs/platform-observability","visibility":"private","private":true},' \
              '{"id":1037651737,"name":"zipbot-v2","full_name":"redducklabs/zipbot-v2","visibility":"private","private":true},' \
              '{"id":1154788719,"name":"redducklaw","full_name":"redducklabs/redducklaw","visibility":"private","private":true},' \
              '{"id":1193238112,"name":"aurolegal.ai","full_name":"redducklabs/aurolegal.ai","visibility":"private","private":true},' \
              '{"id":1351028230,"name":"manager","full_name":"redducklabs/manager","visibility":"private","private":true},' \
              '{"id":1418079240,"name":"superfood-shred","full_name":"redducklabs/superfood-shred","visibility":"private","private":true},' \
              '{"id":1425956382,"name":"keel","full_name":"redducklabs/keel","visibility":"private","private":true}'
            printf ']}\n'
        fi
        ;;
    *"orgs/redducklabs/actions/runner-groups/777"*)
        if [ "${GH_SCENARIO}" = readback_drift ]; then
            printf '{"id":777,"name":"redducklabs-private-runners","visibility":"all","allows_public_repositories":true,"restricted_to_workflows":false}\n'
        else
            printf '{"id":777,"name":"redducklabs-private-runners","visibility":"selected","allows_public_repositories":false,"restricted_to_workflows":false}\n'
        fi
        ;;
    *)
        printf 'unexpected fake gh call: %s\n' "$joined" >&2
        exit 64
        ;;
esac
SH
    chmod +x "$FIXTURE_DIR/fake-bin/gh"
}

run_trust_fixture() {  # scenario, output, optional verifier script
    local scenario=$1 output=$2 verifier=${3:-scripts/verify-runner-trust-boundary.sh}
    : > "$FIXTURE_DIR/gh-calls"
    (
        export PATH="$FIXTURE_DIR/fake-bin:$PATH"
        export GH_SCENARIO="$scenario"
        export GH_CALL_LOG="$FIXTURE_DIR/gh-calls"
        bash "$verifier" \
          --expected-sha "$(git rev-parse HEAD)"
    ) >"$output" 2>&1
}

assert_trust_boundary_fixtures() {
    write_fake_gh

    : > "$FIXTURE_DIR/gh-calls"
    if (
        export PATH="$FIXTURE_DIR/fake-bin:$PATH"
        export GH_SCENARIO=create GH_CALL_LOG="$FIXTURE_DIR/gh-calls"
        bash scripts/verify-runner-trust-boundary.sh \
          --expected-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    ) >"$FIXTURE_DIR/trust-output" 2>&1; then
        fail "Trust boundary accepts a mismatched expected_sha"
    elif [ -s "$FIXTURE_DIR/gh-calls" ]; then
        fail "Trust boundary calls GitHub before rejecting expected_sha"
    else
        pass "Trust boundary rejects expected_sha before every GitHub call"
    fi

    if run_trust_fixture create "$FIXTURE_DIR/trust-output" \
      && grep -q -- '--method POST orgs/redducklabs/actions/runner-groups' "$FIXTURE_DIR/gh-calls" \
      && ! grep -q -- '--method PATCH' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
        if python3 - "$FIXTURE_DIR/gh-calls" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    calls = [line.split("\t", 1)[0] for line in source]
expected_reads = [
    "/repositories/776507734",
    "/repositories/1006277397",
    "/repositories/1018231298",
    "/repositories/1025075333",
    "/repositories/1033531555",
    "/repositories/1037651737",
    "/repositories/1154788719",
    "/repositories/1193238112",
    "/repositories/1351028230",
    "/repositories/1425956382",
    "/repositories/1418079240",
    "repos/redducklabs/zipbot-internal/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/therapy-link/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/redducklabs/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/autoduck/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/platform-observability/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/zipbot-v2/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/redducklaw/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/aurolegal.ai/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/manager/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/keel/actions/permissions/fork-pr-workflows-private-repos",
    "repos/redducklabs/superfood-shred/actions/permissions/fork-pr-workflows-private-repos",
    "orgs/redducklabs/repos?type=public&per_page=100",
    "/repositories/1359405097",
    "/repositories/1271568186",
    "/repositories/1208056940",
    "orgs/redducklabs/actions/runner-groups?per_page=100",
]
identity_reads = expected_reads[:11]
mutation_index = next(
    index for index, call in enumerate(calls)
    if "--method POST orgs/redducklabs/actions/runner-groups" in call
)
for endpoint in expected_reads:
    matches = [index for index, call in enumerate(calls) if endpoint in call]
    if not matches or min(matches) >= mutation_index:
        raise SystemExit(f"required read missing or after mutation: {endpoint}")
if "--method POST orgs/redducklabs/actions/runner-groups" not in calls[mutation_index]:
    raise SystemExit("creation is not the first mutation")
membership_index = next(
    index for index, call in enumerate(calls)
    if index > mutation_index and "runner-groups/777/repositories?per_page=100" in call
)
if not any("runner-groups/777" in call for call in calls[mutation_index + 1:]):
    raise SystemExit("readback calls are missing or reordered")
for endpoint in identity_reads:
    matches = [index for index, call in enumerate(calls) if endpoint in call]
    if len(matches) < 2 or max(matches) <= membership_index:
        raise SystemExit(f"fresh post-readback identity validation missing: {endpoint}")
PY
        then
            pass "Trust boundary creates the selected private group atomically with the exact call sequence"
        else
            fail "Trust boundary creation gh call sequence drifted"
        fi
    else
        fail "Trust boundary group-creation fixture failed"
    fi

    if run_trust_fixture existing "$FIXTURE_DIR/trust-output" \
      && grep -q -- '--method PATCH orgs/redducklabs/actions/runner-groups/777' "$FIXTURE_DIR/gh-calls" \
      && grep -q -- '--method PUT orgs/redducklabs/actions/runner-groups/777/repositories' "$FIXTURE_DIR/gh-calls"; then
        patch_line=$(grep -n -- '--method PATCH' "$FIXTURE_DIR/gh-calls" | head -1 | cut -d: -f1)
        put_line=$(grep -n -- '--method PUT' "$FIXTURE_DIR/gh-calls" | head -1 | cut -d: -f1)
        if [ "$patch_line" -lt "$put_line" ] \
          && grep -q '"visibility":"selected"' "$FIXTURE_DIR/gh-calls" \
          && grep -q '"allows_public_repositories":false' "$FIXTURE_DIR/gh-calls" \
          && grep -q '"selected_repository_ids":\[776507734,1006277397,1018231298,1025075333,1033531555,1037651737,1154788719,1193238112,1351028230,1418079240,1425956382\]' "$FIXTURE_DIR/gh-calls"; then
            pass "Trust boundary narrows access before exact membership replacement"
        else
            fail "Trust boundary existing-group mutation order or payload is unsafe"
        fi
    else
        fail "Trust boundary existing-group reconciliation fixture failed"
    fi

    local scenario expected
    for scenario in permission_failure public_allowlist unknown_allowlist readback_drift public_label mixed_case_label dynamic_runs_on workflow_schema later_page_public_label later_page_workflow_label; do
        case "$scenario" in
            permission_failure) expected='permission' ;;
            public_allowlist) expected='private' ;;
            unknown_allowlist) expected='identity' ;;
            readback_drift) expected='readback' ;;
            public_label) expected='redducklabs-runners' ;;
            mixed_case_label) expected='runner' ;;
            dynamic_runs_on) expected='dynamic runs-on' ;;
            workflow_schema) expected='schema' ;;
            later_page_public_label) expected='redducklabs-runners' ;;
            later_page_workflow_label) expected='redducklabs-runners' ;;
        esac
        if run_trust_fixture "$scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary accepts ${scenario//_/ }"
        elif ! grep -qi "$expected" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary ${scenario//_/ } failure is not diagnostic"
        elif [ "$scenario" != readback_drift ] && grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
            fail "Trust boundary mutates GitHub before rejecting ${scenario//_/ }"
        else
            pass "Trust boundary fails closed on ${scenario//_/ }"
        fi
    done

    if grep -q -- '--paginate orgs/redducklabs/repos?type=public&per_page=100' "$FIXTURE_DIR/gh-calls" \
      && grep -q -- '--paginate repos/redducklabs/public-repo/actions/workflows?per_page=100' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary paginates public repository and workflow enumeration"
    else
        fail "Trust boundary omits pagination from a public GitHub enumeration"
    fi

    local repository_mutant="$FIXTURE_DIR/trust-no-repository-pagination.sh"
    local workflow_mutant="$FIXTURE_DIR/trust-no-workflow-pagination.sh"
    python3 - scripts/verify-runner-trust-boundary.sh "$repository_mutant" "$workflow_mutant" <<'PY'
import sys

source_path, repository_path, workflow_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as stream:
    source = stream.read()
repository_needle = 'public repository enumeration" --paginate \\\n'
workflow_needle = 'workflow enumeration for ${repo_name}" --paginate \\\n'
if source.count(repository_needle) != 1 or source.count(workflow_needle) != 1:
    raise SystemExit("pagination mutation fixture could not locate both enumerations")
with open(repository_path, "w", encoding="utf-8") as stream:
    stream.write(source.replace(repository_needle, 'public repository enumeration" \\\n'))
with open(workflow_path, "w", encoding="utf-8") as stream:
    stream.write(source.replace(workflow_needle, 'workflow enumeration for ${repo_name}" \\\n'))
PY
    chmod +x "$repository_mutant" "$workflow_mutant"
    if run_trust_fixture later_page_public_label "$FIXTURE_DIR/trust-output" "$repository_mutant" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Public-repository pagination fixture hides later pages without --paginate"
    else
        fail "Public-repository pagination fake exposes later pages without --paginate"
    fi
    if run_trust_fixture later_page_workflow_label "$FIXTURE_DIR/trust-output" "$workflow_mutant" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Workflow pagination fixture hides later pages without --paginate"
    else
        fail "Workflow pagination fake exposes later pages without --paginate"
    fi

    if run_trust_fixture existing "$FIXTURE_DIR/trust-output"; then
        mutation_line=$(grep -nE -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls" | head -1 | cut -d: -f1)
        last_readonly_line=$(grep -n 'orgs/redducklabs/actions/runner-groups?per_page=100' "$FIXTURE_DIR/gh-calls" | head -1 | cut -d: -f1)
        if [ "$last_readonly_line" -lt "$mutation_line" ]; then
            pass "Trust boundary completes all read-only checks before mutation"
        else
            fail "Trust boundary begins mutation before read-only validation completes"
        fi
    else
        fail "Trust boundary read-only ordering fixture could not complete"
    fi

    if run_trust_fixture later_page_group "$FIXTURE_DIR/trust-output" \
      && grep -q -- '--paginate orgs/redducklabs/actions/runner-groups?per_page=100' "$FIXTURE_DIR/gh-calls" \
      && grep -q -- '--method PATCH orgs/redducklabs/actions/runner-groups/777' "$FIXTURE_DIR/gh-calls" \
      && ! grep -q -- '--method POST orgs/redducklabs/actions/runner-groups' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary reconciles a matching runner group from a later page"
    else
        fail "Trust boundary does not paginate runner-group enumeration"
    fi

    if run_trust_fixture replacement_failure "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary continues after exact membership replacement fails"
    elif ! grep -q -- '--method PATCH orgs/redducklabs/actions/runner-groups/777' "$FIXTURE_DIR/gh-calls" \
      || ! grep -q -- '--method PUT orgs/redducklabs/actions/runner-groups/777/repositories' "$FIXTURE_DIR/gh-calls" \
      || ! grep -Fq 'access may remain more restrictive' "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary partial-failure behavior is not restrictive and diagnostic"
    else
        pass "Trust boundary halts safely after partial reconciliation failure"
    fi

    if run_trust_fixture reduced_membership "$FIXTURE_DIR/trust-output" \
      && grep -Eq -- '--method (PATCH|PUT)' "$FIXTURE_DIR/gh-calls" \
      && [ "$(grep -c '/repositories/1351028230' "$FIXTURE_DIR/gh-calls")" -eq 2 ] \
      && grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
        pass "Trust boundary accepts reduced exact membership only after fresh private identity readback"
    else
        fail "Trust boundary cannot validate reduced exact membership with fresh private identity readback"
    fi

    : > "$FIXTURE_DIR/gh-calls"
    if (
        export PATH="$FIXTURE_DIR/fake-bin:$PATH"
        export GH_SCENARIO=reduced_membership GH_CALL_LOG="$FIXTURE_DIR/gh-calls"
        bash scripts/verify-runner-trust-boundary.sh \
          --expected-sha "$(git rev-parse HEAD)" --verify-only
    ) >"$FIXTURE_DIR/trust-output" 2>&1 \
      && ! grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls" \
      && [ "$(grep -c '/repositories/1351028230' "$FIXTURE_DIR/gh-calls")" -eq 2 ] \
      && grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
        pass "Trust boundary verify-only mode freshly validates reduced exact membership identities"
    else
        fail "Trust boundary verify-only mode does not freshly validate reduced exact membership identities"
    fi

    local post_readback_scenario
    for post_readback_scenario in post_readback_public post_readback_renamed; do
        if run_trust_fixture "$post_readback_scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary accepts ${post_readback_scenario//_/ } repository identity drift"
        elif ! grep -Eq -- '--method (PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
            fail "Trust boundary rejects ${post_readback_scenario//_/ } before reconciliation"
        elif grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary reports success after ${post_readback_scenario//_/ }"
        elif ! grep -Fqi 'post-readback repository identity' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary ${post_readback_scenario//_/ } rejection is not diagnostic"
        else
            pass "Trust boundary fails closed on ${post_readback_scenario//_/ } after reconciliation"
        fi
    done

    local absent_scenario
    for absent_scenario in absent_workflow absent_workflow_dir; do
        if run_trust_fixture "$absent_scenario" "$FIXTURE_DIR/trust-output" \
          && grep -q 'contents/.github/workflows -f ref=1111111111111111111111111111111111111111' "$FIXTURE_DIR/gh-calls" \
          && grep -Fq 'Skipping registered workflow public-repo:.github/workflows/ci.yml: absent at default-branch head' "$FIXTURE_DIR/trust-output" \
          && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls" \
          && grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
            pass "Trust boundary skips a registered workflow proven absent at head (${absent_scenario//_/ })"
        else
            fail "Trust boundary does not skip a registered workflow proven absent at head (${absent_scenario//_/ })"
        fi
    done
    for absent_scenario in absent_workflow_listed absent_workflow_listing_error absent_workflow_capped; do
        if run_trust_fixture "$absent_scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary accepts an unreadable workflow (${absent_scenario//_/ })"
        elif ! grep -Fq 'could not read public workflow public-repo:.github/workflows/ci.yml' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary unreadable workflow failure is not diagnostic (${absent_scenario//_/ })"
        elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
            fail "Trust boundary mutates GitHub before rejecting an unreadable workflow (${absent_scenario//_/ })"
        else
            pass "Trust boundary fails closed on an unreadable workflow without proven absence (${absent_scenario//_/ })"
        fi
    done

    if run_trust_fixture managed_copilot "$FIXTURE_DIR/trust-output" \
      && ! grep -q 'contents/dynamic/agents/copilot-pull-request-reviewer' "$FIXTURE_DIR/gh-calls" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary skips GitHub's exact managed Copilot workflow path"
    else
        fail "Trust boundary does not safely skip GitHub's exact managed Copilot workflow path"
    fi

    if run_trust_fixture managed_dependabot "$FIXTURE_DIR/trust-output" \
      && ! grep -q 'contents/dynamic/dependabot/dependabot-updates' "$FIXTURE_DIR/gh-calls" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary skips GitHub's exact managed Dependabot updates workflow path"
    else
        fail "Trust boundary does not safely skip GitHub's exact managed Dependabot updates workflow path"
    fi

    if run_trust_fixture managed_codeql "$FIXTURE_DIR/trust-output" \
      && ! grep -q 'contents/dynamic/github-code-scanning/codeql' "$FIXTURE_DIR/gh-calls" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary skips GitHub's exact managed CodeQL default-setup workflow path"
    else
        fail "Trust boundary does not safely skip GitHub's exact managed CodeQL default-setup workflow path"
    fi

    if run_trust_fixture managed_dynamic_near_miss "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary accepts a near-miss GitHub-managed dynamic workflow path"
    elif grep -q 'contents/dynamic/dependabot/dependabot-updates-preview' "$FIXTURE_DIR/gh-calls"; then
        fail "Trust boundary attempts a contents read for a near-miss GitHub-managed dynamic workflow path"
    elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
        fail "Trust boundary mutates before rejecting a near-miss GitHub-managed dynamic workflow path"
    elif ! grep -Fqi 'unsupported workflow path' "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary near-miss workflow-path rejection is not diagnostic"
    else
        pass "Trust boundary fails closed on near-miss GitHub-managed dynamic workflow paths"
    fi

    if run_trust_fixture unknown_dynamic_path "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary accepts an unknown non-repository workflow path"
    elif grep -q 'contents/dynamic/agents/unrecognized' "$FIXTURE_DIR/gh-calls"; then
        fail "Trust boundary attempts a contents read for an unknown non-repository workflow path"
    elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
        fail "Trust boundary mutates before rejecting an unknown non-repository workflow path"
    elif ! grep -Fqi 'unsupported workflow path' "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary unknown workflow-path rejection is not diagnostic"
    else
        pass "Trust boundary fails closed on unknown non-repository workflow paths"
    fi

    assert_trust_boundary_admission_fixtures
}

run_trust_verify_only_fixture() {  # scenario, output, optional verifier script
    local scenario=$1 output=$2 verifier=${3:-scripts/verify-runner-trust-boundary.sh}
    : > "$FIXTURE_DIR/gh-calls"
    (
        export PATH="$FIXTURE_DIR/fake-bin:$PATH"
        export GH_SCENARIO="$scenario"
        export GH_CALL_LOG="$FIXTURE_DIR/gh-calls"
        bash "$verifier" \
          --expected-sha "$(git rev-parse HEAD)" --verify-only
    ) >"$output" 2>&1
}

# Every private member's fork-PR policy is read with an explicit GET before the
# first runner-group mutation (and in verify-only mode, before readback).
assert_fork_policy_reads_precede_mutation() {  # gh call log
    python3 - "$1" <<'PY'
import sys

members = [
    "zipbot-internal", "therapy-link", "redducklabs", "autoduck",
    "platform-observability", "zipbot-v2", "redducklaw", "aurolegal.ai",
    "manager", "superfood-shred", "keel",
]
with open(sys.argv[1], encoding="utf-8") as source:
    calls = [line.split("\t", 1)[0] for line in source]
mutations = [
    index for index, call in enumerate(calls)
    if any(f"--method {verb}" in call for verb in ("POST", "PATCH", "PUT", "DELETE"))
]
boundary = min(mutations) if mutations else len(calls)
readback = [index for index, call in enumerate(calls) if "runner-groups/777" in call]
if readback:
    boundary = min(boundary, min(readback))
for member in members:
    endpoint = f"repos/redducklabs/{member}/actions/permissions/fork-pr-workflows-private-repos"
    matches = [index for index, call in enumerate(calls) if endpoint in call]
    if len(matches) != 1:
        raise SystemExit(f"fork-PR policy for {member} read {len(matches)} times")
    if matches[0] >= boundary:
        raise SystemExit(f"fork-PR policy for {member} read after runner-group mutation or readback")
    if "--method GET" not in calls[matches[0]]:
        raise SystemExit(f"fork-PR policy for {member} is not an explicit GET")
PY
}

assert_trust_boundary_admission_fixtures() {
    if run_trust_fixture existing "$FIXTURE_DIR/trust-output" \
      && assert_fork_policy_reads_precede_mutation "$FIXTURE_DIR/gh-calls" \
      && grep -q -- '--method PUT orgs/redducklabs/actions/runner-groups/777/repositories' "$FIXTURE_DIR/gh-calls" \
      && grep -q '"selected_repository_ids":\[776507734,1006277397,1018231298,1025075333,1033531555,1037651737,1154788719,1193238112,1351028230,1418079240,1425956382\]' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'repositories=11' "$FIXTURE_DIR/trust-output"; then
        pass "Trust boundary reconciles the eleven-member group only after every fork-PR policy read"
    else
        fail "Trust boundary eleven-member reconcile does not read every fork-PR policy before mutation"
    fi

    if run_trust_verify_only_fixture existing "$FIXTURE_DIR/trust-output" \
      && assert_fork_policy_reads_precede_mutation "$FIXTURE_DIR/gh-calls" \
      && ! grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'repositories=11' "$FIXTURE_DIR/trust-output"; then
        pass "Trust boundary verify-only mode checks every fork-PR policy and the eleven-member readback"
    else
        fail "Trust boundary verify-only mode skips fork-PR policy checks or the eleven-member readback"
    fi

    local scenario target mode status
    for scenario in fork_policy_true fork_policy_missing fork_policy_null fork_policy_string \
      fork_policy_malformed fork_policy_array fork_policy_multi fork_policy_error; do
        for target in keel superfood-shred manager; do
            for mode in reconcile verify-only; do
                export FORK_POLICY_TARGET="$target"
                if [ "$mode" = reconcile ]; then
                    run_trust_fixture "$scenario" "$FIXTURE_DIR/trust-output" && status=0 || status=$?
                else
                    run_trust_verify_only_fixture "$scenario" "$FIXTURE_DIR/trust-output" && status=0 || status=$?
                fi
                unset FORK_POLICY_TARGET
                if [ "$status" -eq 0 ]; then
                    fail "Trust boundary accepts ${scenario//_/ } for ${target} (${mode})"
                elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
                    fail "Trust boundary mutates the runner group before rejecting ${scenario//_/ } for ${target} (${mode})"
                elif grep -q 'runner-groups' "$FIXTURE_DIR/gh-calls"; then
                    fail "Trust boundary reaches the runner group before rejecting ${scenario//_/ } for ${target} (${mode})"
                elif grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
                    fail "Trust boundary reports success after ${scenario//_/ } for ${target} (${mode})"
                elif ! grep -Fq "fork-PR" "$FIXTURE_DIR/trust-output" \
                  || ! grep -Fq "$target" "$FIXTURE_DIR/trust-output"; then
                    fail "Trust boundary ${scenario//_/ } rejection for ${target} (${mode}) is not diagnostic"
                else
                    pass "Trust boundary fails closed on ${scenario//_/ } for ${target} (${mode})"
                fi
            done
        done
    done

    if run_trust_fixture transferred_member "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary accepts a transferred admitted repository"
    elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
        fail "Trust boundary mutates before rejecting a transferred admitted repository"
    elif ! grep -Fq '1425956382:keel' "$FIXTURE_DIR/trust-output"; then
        fail "Trust boundary transferred-repository rejection is not diagnostic"
    else
        pass "Trust boundary fails closed on a transferred admitted repository"
    fi

    for scenario in substituted_membership unauthorized_addition; do
        if run_trust_fixture "$scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary accepts ${scenario//_/ } in the runner-group readback"
        elif grep -Fq 'Trust boundary verified' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary reports success after ${scenario//_/ } in the runner-group readback"
        elif ! grep -Fq 'selected membership is not exact' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary ${scenario//_/ } readback rejection is not diagnostic"
        else
            pass "Trust boundary fails closed on ${scenario//_/ } in the runner-group readback"
        fi
        if run_trust_verify_only_fixture "$scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary verify-only mode accepts ${scenario//_/ }"
        elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
            fail "Trust boundary verify-only mode mutates on ${scenario//_/ }"
        elif ! grep -Fq 'selected membership is not exact' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary verify-only ${scenario//_/ } rejection is not diagnostic"
        else
            pass "Trust boundary verify-only mode fails closed on ${scenario//_/ }"
        fi
    done

    # Manifest mutants: the verifier must reject a duplicated, omitted, or
    # unauthorized added identity before any GitHub call.
    local manifest_case manifest_file mutant
    for manifest_case in duplicate omission addition; do
        manifest_file="$FIXTURE_DIR/trusted-${manifest_case}.txt"
        mutant="$FIXTURE_DIR/trust-manifest-${manifest_case}.sh"
        case "$manifest_case" in
            duplicate)
                sed '$d' deploy/trusted-runner-repositories.txt > "$manifest_file"
                tail -n 1 "$manifest_file" >> "$manifest_file"
                ;;
            omission)
                grep -v ':keel$' deploy/trusted-runner-repositories.txt > "$manifest_file"
                ;;
            addition)
                cp deploy/trusted-runner-repositories.txt "$manifest_file"
                printf '%s\n' '1334789692:my-review-buddy' >> "$manifest_file"
                ;;
        esac
        if ! python3 - scripts/verify-runner-trust-boundary.sh "$mutant" "$manifest_file" <<'PY'
import sys

source_path, mutant_path, manifest_path = sys.argv[1:]
source = open(source_path, encoding="utf-8").read()
needle = 'TRUSTED_REPOSITORIES_FILE="${REPO_ROOT}/deploy/trusted-runner-repositories.txt"\n'
if source.count(needle) != 1:
    raise SystemExit("manifest mutation fixture could not locate the manifest path")
with open(mutant_path, "w", encoding="utf-8") as stream:
    stream.write(source.replace(needle, f'TRUSTED_REPOSITORIES_FILE="{manifest_path}"\n'))
PY
        then
            fail "Trust boundary manifest ${manifest_case} fixture could not be materialized"
            continue
        fi
        if run_trust_fixture existing "$FIXTURE_DIR/trust-output" "$mutant"; then
            fail "Trust boundary accepts a manifest with an ${manifest_case} identity"
        elif [ -s "$FIXTURE_DIR/gh-calls" ]; then
            fail "Trust boundary calls GitHub before rejecting a manifest ${manifest_case}"
        elif ! grep -Eq 'duplicate identity|exactly eleven identities' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary manifest ${manifest_case} rejection is not diagnostic"
        else
            pass "Trust boundary rejects a manifest ${manifest_case} before any GitHub call"
        fi
    done
}

run_autoscaler_fixture() {  # fixture text or MISSING, output
    local fixture=$1 output=$2 script="$FIXTURE_DIR/autoscaler-diagnostics.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/runner-status.yml \
      'Report autoscaler diagnostics' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || return 1
    (
        export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
        export FIXTURE_AUTOSCALER_STATUS="$fixture"
        kubectl() {
            if [ "$FIXTURE_AUTOSCALER_STATUS" = MISSING ]; then
                return 1
            fi
            printf '%s\n' "$FIXTURE_AUTOSCALER_STATUS"
        }
        export -f kubectl
        bash -euo pipefail -c 'source "$1"' -- "$script"
    ) >"$output" 2>&1
}

assert_autoscaler_diagnostic_fixtures() {
    local healthy backoff changed
    healthy=$'health:\n  status: Healthy\nscaleUp:\n  status: NoActivity'
    backoff=$'health:\n  status: Healthy\nscaleUp:\n  status: Backoff\n  errorCode: cloudProviderError\n  errorMessage: No capacity in pool pool-123 for cluster do-sfo3-secret; requestId=req-deadbeef https://cloud.digitalocean.com/kubernetes/clusters/secret'
    changed=$'Health:\n  state: providerPassword=do-not-print'

    if run_autoscaler_fixture "$healthy" "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'health.status: Healthy' "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'scaleUp.status: NoActivity' "$FIXTURE_DIR/autoscaler-output"; then
        pass "Runner Status parses healthy/no-activity autoscaler diagnostics"
    else
        fail "Runner Status healthy autoscaler diagnostic fixture failed"
    fi

    if run_autoscaler_fixture "$backoff" "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'scaleUp.status: Backoff' "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'scaleUp.errorCode: cloudProviderError' "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'scaleUp.errorMessage:' "$FIXTURE_DIR/autoscaler-output" \
      && ! grep -Eq 'pool-123|do-sfo3-secret|req-deadbeef|https://' "$FIXTURE_DIR/autoscaler-output"; then
        pass "Runner Status reports provider backoff with identifiers redacted"
    else
        fail "Runner Status provider-backoff diagnostic fixture failed"
    fi

    if run_autoscaler_fixture MISSING "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'Autoscaler diagnostics unavailable' "$FIXTURE_DIR/autoscaler-output" \
      && run_autoscaler_fixture "$changed" "$FIXTURE_DIR/autoscaler-output" \
      && grep -Fq 'Autoscaler diagnostics unavailable' "$FIXTURE_DIR/autoscaler-output" \
      && ! grep -Fq 'do-not-print' "$FIXTURE_DIR/autoscaler-output"; then
        pass "Runner Status degrades safely for missing or changed diagnostics"
    else
        fail "Runner Status does not degrade diagnostics safely"
    fi
}

assert_deploy_operation_and_preflight_contract() {
    if python3 - <<'PY'
import re
import yaml

with open('.github/workflows/deploy-runners.yml', encoding='utf-8') as source:
    workflow = yaml.safe_load(source)

inputs = workflow[True]['workflow_dispatch']['inputs']
operations = inputs.get('operation', {}).get('options', [])
if operations != ['deploy', 'prepare-trust-boundary', 'drain', 'rollback']:
    raise SystemExit('deploy operation choices are incomplete or unordered')
if inputs.get('accept_privileged_runner_co_tenancy', {}).get('type') != 'boolean':
    raise SystemExit('explicit privileged co-tenancy acceptance input is missing')
if 'rollback_revision' in inputs:
    raise SystemExit('rollback no longer takes a Helm revision (Ruling 34)')
if inputs.get('acknowledge_emergency_stop', {}).get('type') != 'boolean' \
        or inputs['acknowledge_emergency_stop'].get('default') is not False:
    raise SystemExit('acknowledge_emergency_stop must be a boolean input defaulting to false (Ruling 33)')

jobs = workflow.get('jobs') or {}
trust = jobs.get('trust-boundary')
deploy = jobs.get('deploy')
if not trust or not deploy:
    raise SystemExit('trust-boundary and deploy jobs must both exist')
trust_shell = '\n'.join(step.get('run', '') for step in trust.get('steps', []))
if 'scripts/verify-runner-trust-boundary.sh' not in trust_shell:
    raise SystemExit('trust job does not execute the committed verifier')
if any(token in trust_shell for token in ('kubectl ', 'helm ', 'doctl ')):
    raise SystemExit('prepare-trust-boundary job has a cluster/provider command')
if 'trust-boundary' not in ([deploy.get('needs')] if isinstance(deploy.get('needs'), str) else deploy.get('needs', [])):
    raise SystemExit('deployment does not depend on trust reconciliation')
if 'min_runners' in inputs or 'max_runners' in inputs:
    raise SystemExit('Deploy must not take runner bounds as input')
if "needs.validate-inputs.outputs.operation == 'deploy'" not in deploy.get('if', ''):
    raise SystemExit('prepare-trust-boundary does not stop before the deployment job')

steps = deploy.get('steps') or []
for job in jobs.values():
    for step in job.get('steps', []):
        if '${{ github.event.inputs.' in step.get('run', ''):
            raise SystemExit(f'raw workflow_dispatch input interpolation in shell step: {step.get("name")}')
render_index = next(i for i, step in enumerate(steps) if step.get('name') == 'Render and validate candidate')
preflight_index = next(i for i, step in enumerate(steps) if step.get('name') == 'Server-side preflight candidate')
deploy_index = next(i for i, step in enumerate(steps) if step.get('name') == 'Deploy runners')
preflight = steps[render_index].get('run', '') + steps[preflight_index].get('run', '')
if '--dry-run=server' in steps[render_index].get('run', '') or not render_index < preflight_index:
    raise SystemExit('the render step must be local and precede the server-side preflight')
deploy_shell = steps[deploy_index].get('run', '')
rollback_steps = jobs.get('rollback', {}).get('steps', [])
rollback = next(step for step in rollback_steps if step.get('name') == 'Roll back to committed density values').get('run', '')
if preflight.count('helm template ') != 1:
    raise SystemExit('candidate must be rendered exactly once')
if preflight.count('kubectl apply --server-side --force-conflicts --dry-run=server') != 2:
    raise SystemExit('ASRS and representative Pod server dry-runs are required')
if '--post-renderer "${HASH_GATE}"' not in deploy_shell:
    raise SystemExit('Helm deployment is not guarded by the preflight manifest hash')
if preflight_index >= deploy_index:
    raise SystemExit('preflight does not precede Helm deployment')
if './scripts/rollback-density.sh --identities' not in rollback:
    raise SystemExit('CI rollback boundary is missing')
if '--contract burst --kind manifest' not in preflight:
    raise SystemExit('rendered candidate is not checked against the burst contract before Helm')
if "safe-to-evict" not in preflight or '"annotations"' not in preflight:
    raise SystemExit('preflight does not carry and verify the safe-to-evict annotation')

overlay_patterns = [
    r'--values deploy/dind-values\.yaml',
    r'--set githubConfigSecret\.github_token=',
    r'--set runnerScaleSetName=',
    r'--set-string "template\.spec\.containers\[0\]\.image=',
    r'--set-string "template\.spec\.initContainers\[0\]\.image=',
    r'--set runnerGroup=',
    r'--set controllerServiceAccount\.name=arc-gha-rs-controller',
    r'--set controllerServiceAccount\.namespace=arc-systems',
    r'--version "\$\{ARC_CHART_VERSION\}"',
]
for pattern in overlay_patterns:
    if not re.search(pattern, preflight) or not re.search(pattern, deploy_shell):
        raise SystemExit(f'preflight/deploy overlay drift: {pattern}')

for index, step in enumerate(steps):
    if index >= preflight_index:
        break
    shell = step.get('run', '')
    if re.search(r'helm (upgrade|rollback|uninstall)|kubectl (apply|create|delete|patch)|node-pool update', shell):
        raise SystemExit(f'mutation step precedes compatibility preflight: {step.get("name")}')
PY
    then
        pass "Deploy exposes isolated trust preparation, exact preflight overlays, and CI rollback"
    else
        fail "Deploy operation, preflight, trust isolation, or rollback contract is incomplete"
    fi
}

assert_hostile_inputs_are_data() {
    local script="$FIXTURE_DIR/deploy-hostile-input.sh"
    local sentinel="$FIXTURE_DIR/hostile-input-executed"
    local payload='$(touch '"$sentinel"')'
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Validate and sanitize inputs' "$payload" 4 2 2 "$script" || {
        fail "Hostile input fixture could not be materialized"
        return
      }
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a hostile expected_sha"
    elif [ -e "$sentinel" ]; then
        fail "Deploy executes workflow_dispatch expected_sha as shell code"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy reaches mutation while rejecting hostile expected_sha"
    elif ! grep -Fq 'expected_sha must be a 40-character commit SHA' "$FIXTURE_DIR/output"; then
        fail "Deploy hostile expected_sha rejection is not diagnostic"
    else
        pass "Deploy treats hostile expected_sha as inert data"
    fi
}

assert_deploy_requires_cotenancy_acceptance() {
    local script="$FIXTURE_DIR/deploy-cotenancy.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/deploy-runners.yml \
        'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Deploy co-tenancy acceptance fixture could not be materialized"
        return
    fi
    sed -i 's/export INPUT_ACCEPT_CO_TENANCY=true/export INPUT_ACCEPT_CO_TENANCY=false/' "$script"
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts privileged runner co-tenancy without explicit consent"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy mutates state before rejecting missing co-tenancy consent"
    elif ! grep -Fq 'must be explicitly accepted' "$FIXTURE_DIR/output"; then
        fail "Deploy co-tenancy rejection is not diagnostic"
    else
        pass "Deploy requires explicit privileged runner co-tenancy acceptance"
    fi
}


run_deploy_preflight_fixture() {  # dry-run fail, memory Mi, CPU m, admission mutation, request shape, server major/minor, deploy drift, output, field ownership
    local fail_dry_run=$1 system_memory_mi=$2 system_cpu_m=$3 admission_mutation=$4
    local request_shape=$5 server_major=$6 server_minor=$7 deploy_drift=$8 output=$9
    local existing_field_ownership=${10:-false}
    local script="$FIXTURE_DIR/deploy-preflight.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Render and validate candidate' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || return 1
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Server-side preflight candidate' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || return 1
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Deploy runners' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || return 1
    : > "$FIXTURE_DIR/preflight-calls"
    printf '%s\n' "$RENDER" > "$FIXTURE_DIR/preflight-render.yaml"
    (
        export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
        export RUNNER_TEMP="$FIXTURE_DIR"
        export FIXTURE_FAIL_DRY_RUN="$fail_dry_run"
        export FIXTURE_SYSTEM_MEMORY_MI="$system_memory_mi"
        export FIXTURE_SYSTEM_CPU_M="$system_cpu_m"
        export FIXTURE_ADMISSION_MUTATION="$admission_mutation"
        export FIXTURE_REQUEST_SHAPE="$request_shape"
        export FIXTURE_SERVER_MAJOR="$server_major"
        export FIXTURE_SERVER_MINOR="$server_minor"
        export FIXTURE_DEPLOY_DRIFT="$deploy_drift"
        export FIXTURE_EXISTING_FIELD_OWNERSHIP="$existing_field_ownership"
        export FIXTURE_CALL_LOG="$FIXTURE_DIR/preflight-calls"
        export FIXTURE_RENDER_FILE="$FIXTURE_DIR/preflight-render.yaml"
        export RELEASE_NAME=redducklabs-runners
        export RUNNER_SCALE_SET_NAME=redducklabs-runners
        export ARC_CHART_VERSION=0.14.2
        helm() {
            if [ "$1" = template ]; then
                printf 'helm %s\n' "$*" >> "$FIXTURE_CALL_LOG"
                command cat "$FIXTURE_RENDER_FILE"
            elif [ "$1" = upgrade ]; then
                local previous='' post_renderer=''
                for arg in "$@"; do
                    if [ "$previous" = --post-renderer ]; then post_renderer=$arg; break; fi
                    previous=$arg
                done
                if [ -z "$post_renderer" ]; then
                    echo 'missing Helm post-renderer hash gate' >&2
                    return 90
                fi
                if [ "$FIXTURE_DEPLOY_DRIFT" = true ]; then
                    if ! { command cat "$FIXTURE_RENDER_FILE"; printf '\n# second-render drift\n'; } | "$post_renderer" >/dev/null; then
                        return 1
                    fi
                else
                    if ! "$post_renderer" < "$FIXTURE_RENDER_FILE" >/dev/null; then
                        return 1
                    fi
                fi
                printf 'helm %s\n' "$*" >> "$FIXTURE_CALL_LOG"
            else
                printf 'helm %s\n' "$*" >> "$FIXTURE_CALL_LOG"
            fi
        }
        kubectl() {
            printf 'kubectl %s\n' "$*" >> "$FIXTURE_CALL_LOG"
            case " $* " in
                *" version -o json "*)
                    printf '{"serverVersion":{"major":"%s","minor":"%s"}}\n' "$FIXTURE_SERVER_MAJOR" "$FIXTURE_SERVER_MINOR"
                    ;;
                *" get nodes "*)
                    printf '{"items":[{"metadata":{"name":"runner-a"},"status":{"allocatable":{"memory":"13639Mi","cpu":"7880m"},"nodeInfo":{"kubeletVersion":"v1.36.3"},"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"runner-b"},"status":{"allocatable":{"memory":"13639Mi","cpu":"7880m"},"nodeInfo":{"kubeletVersion":"v1.36.3"},"conditions":[{"type":"Ready","status":"True"}]}}]}\n'
                    ;;
                *" get pods -A "*)
                    python3 - <<'PY'
import json
import os

shape = os.environ['FIXTURE_REQUEST_SHAPE']
memory = os.environ['FIXTURE_SYSTEM_MEMORY_MI'] + 'Mi'
cpu = os.environ['FIXTURE_SYSTEM_CPU_M'] + 'm'

def spec(node):
    value = {"nodeName": node, "containers": [{"resources": {"requests": {"memory": memory, "cpu": cpu}}}]}
    if shape == 'pod_level':
        value = {"nodeName": node, "resources": {"requests": {"memory": "1500Mi", "cpu": "500m"}}, "containers": [{}]}
    elif shape == 'restartable_sidecar':
        value = {"nodeName": node, "containers": [{}], "initContainers": [{"restartPolicy": "Always", "resources": {"requests": {"memory": "1500Mi", "cpu": "500m"}}}]}
    elif shape == 'regular_init_peak':
        value = {"nodeName": node, "containers": [{}], "initContainers": [{"resources": {"requests": {"memory": "1500Mi", "cpu": "500m"}}}]}
    elif shape == 'overhead':
        value["overhead"] = {"memory": "1001Mi", "cpu": "1m"}
    elif shape == 'alternate_valid':
        value = {"nodeName": node, "containers": [{"resources": {"requests": {"memory": "536870912", "cpu": "500000u"}}}]}
    elif shape == 'malformed':
        value = {"nodeName": node, "containers": [{"resources": {"requests": {"memory": "not-a-quantity", "cpu": "500m"}}}]}
    return value

print(json.dumps({"items": [
    {"metadata": {"name": "system-a", "namespace": "kube-system", "labels": {}}, "spec": spec("runner-a")},
    {"metadata": {"name": "system-b", "namespace": "kube-system", "labels": {}}, "spec": spec("runner-b")},
]}))
PY
                    ;;
                *" apply --server-side --dry-run=server "*|*" apply --server-side --force-conflicts --dry-run=server "*)
                    if [ "$FIXTURE_EXISTING_FIELD_OWNERSHIP" = true ] \
                      && [[ " $* " != *" --force-conflicts "* ]]; then
                        return 42
                    fi
                    if [ "$FIXTURE_FAIL_DRY_RUN" = true ]; then
                        return 1
                    fi
                    local previous='' file=''
                    for arg in "$@"; do
                        if [ "$previous" = -f ]; then file=$arg; break; fi
                        previous=$arg
                    done
                    python3 - "$file" <<'PY'
import json, os, sys, yaml
with open(sys.argv[1], encoding='utf-8') as source:
    document = yaml.safe_load(source)
mutation = os.environ.get('FIXTURE_ADMISSION_MUTATION')
if (os.environ.get('FIXTURE_EXISTING_FIELD_OWNERSHIP') == 'true'
        and document.get('kind') == 'AutoscalingRunnerSet'
        and document.get('metadata', {}).get('name') == 'redducklabs-runners'):
    template = document['spec']['template']['spec']
    by_name = {
        item.get('name'): item
        for item in template.get('containers', []) + template.get('initContainers', [])
    }
    for name in ('runner', 'dind'):
        by_name[name]['resources'] = {
            'requests': {'memory': '5Gi'},
            'limits': {'memory': '10Gi'},
        }
if mutation != 'none':
    spec = document.get('spec', {})
    if document.get('kind') == 'AutoscalingRunnerSet':
        spec = spec.get('template', {}).get('spec', {})
    containers = spec.get('containers', [])
    init_containers = spec.get('initContainers', [])
    if mutation == 'resources':
        next(item for item in containers if item.get('name') == 'runner')['resources'] = {'requests': {'cpu': '1'}}
    elif mutation == 'group' and document.get('kind') == 'AutoscalingRunnerSet':
        document['spec']['runnerGroup'] = 'wrong-group'
    elif mutation == 'placement':
        spec['nodeSelector'] = {'node-type': 'worker'}
    elif mutation == 'image':
        next(item for item in containers if item.get('name') == 'runner')['image'] = 'untrusted.invalid/runner:latest'
    elif mutation == 'privileged':
        next(item for item in init_containers if item.get('name') == 'dind')['securityContext']['privileged'] = False
    elif mutation == 'unexpected_container':
        containers.append({'name': 'injected', 'image': 'injected:latest'})
    elif mutation == 'wiring':
        next(item for item in containers if item.get('name') == 'runner')['volumeMounts'] = []
    elif mutation == 'restart':
        next(item for item in init_containers if item.get('name') == 'dind')['restartPolicy'] = 'Never'
    elif mutation == 'annotation_removed':
        if document.get('kind') == 'Pod':
            document['metadata'].get('annotations', {}).pop('cluster-autoscaler.kubernetes.io/safe-to-evict', None)
        else:
            document['spec']['template']['metadata']['annotations'].pop('cluster-autoscaler.kubernetes.io/safe-to-evict', None)
    elif mutation == 'annotation_true':
        if document.get('kind') == 'Pod':
            document['metadata'].setdefault('annotations', {})['cluster-autoscaler.kubernetes.io/safe-to-evict'] = 'true'
        else:
            document['spec']['template']['metadata']['annotations']['cluster-autoscaler.kubernetes.io/safe-to-evict'] = 'true'
    elif mutation == 'pod_annotation_removed':
        if document.get('kind') == 'Pod':
            document['metadata'].get('annotations', {}).pop('cluster-autoscaler.kubernetes.io/safe-to-evict', None)
    elif mutation == 'host_network':
        spec['hostNetwork'] = True
    elif mutation == 'host_pid':
        spec['hostPID'] = True
    elif mutation == 'host_ipc':
        spec['hostIPC'] = True
    elif mutation == 'unknown_top_level':
        spec['unapprovedSecurityField'] = {'enabled': True}
    elif mutation == 'service_account_token':
        spec.setdefault('volumes', []).append({
            'name': 'kube-api-access-fixture',
            'projected': {
                'defaultMode': 420,
                'sources': [
                    {'serviceAccountToken': {'expirationSeconds': 3607, 'path': 'token'}},
                    {'configMap': {
                        'name': 'kube-root-ca.crt',
                        'items': [{'key': 'ca.crt', 'path': 'ca.crt'}],
                    }},
                    {'downwardAPI': {'items': [{
                        'path': 'namespace',
                        'fieldRef': {
                            'apiVersion': 'v1', 'fieldPath': 'metadata.namespace',
                        },
                    }]}},
                ],
            },
        })
        for item in containers + init_containers:
            item.setdefault('volumeMounts', []).append({
                'name': 'kube-api-access-fixture',
                'mountPath': '/var/run/secrets/kubernetes.io/serviceaccount',
                'readOnly': True,
            })
    elif mutation == 'api_defaults' and document.get('kind') == 'Pod':
        spec.update({
            'dnsPolicy': 'ClusterFirst',
            'enableServiceLinks': True,
            'hostUsers': True,
            'preemptionPolicy': 'PreemptLowerPriority',
            'priority': 0,
            'schedulerName': 'default-scheduler',
            'securityContext': {},
            'serviceAccount': spec['serviceAccountName'],
            'terminationGracePeriodSeconds': 30,
        })
        spec['tolerations'].extend([
            {'key': 'node.kubernetes.io/not-ready', 'operator': 'Exists',
             'effect': 'NoExecute', 'tolerationSeconds': 300},
            {'key': 'node.kubernetes.io/unreachable', 'operator': 'Exists',
             'effect': 'NoExecute', 'tolerationSeconds': 300},
        ])
        for item in containers + init_containers:
            item.setdefault('resources', {})
            image = item.get('image', '')
            reference = image.rsplit('/', 1)[-1]
            item['imagePullPolicy'] = (
                'Always' if ':' not in reference or reference.endswith(':latest')
                else 'IfNotPresent'
            )
            item['terminationMessagePath'] = '/dev/termination-log'
            item['terminationMessagePolicy'] = 'File'
        dind_probe = next(
            item for item in init_containers if item.get('name') == 'dind'
        )['startupProbe']
        dind_probe.pop('initialDelaySeconds', None)
        dind_probe['successThreshold'] = 1
        dind_probe['timeoutSeconds'] = 1
print(json.dumps(document))
PY
                    ;;
            esac
        }
        sleep() { :; }
        # Deploy runners re-checks expected_sha in-job; the fixture checkout
        # is at FIXTURE_ACTUAL_SHA.
        git() {
            if [ "$1" = rev-parse ] && [ "$2" = HEAD ]; then
                printf '%s\n' "$FIXTURE_ACTUAL_SHA"
                return 0
            fi
            command git "$@"
        }
        export FIXTURE_ACTUAL_SHA
        export -f helm kubectl sleep git
        bash -euo pipefail -c 'source "$1"' -- "$script"
    ) >"$output" 2>&1
}

assert_deploy_preflight_fixtures() {
    if run_deploy_preflight_fixture true 500 500 none container 1 36 false "$FIXTURE_DIR/preflight-output"; then
        fail "Deploy continues after a server-side dry-run failure"
    elif [ ! -e "$FIXTURE_DIR/preflight-calls" ]; then
        fail "Deploy dry-run failure fixture could not be materialized"
    elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
        fail "Deploy reaches Helm after a server-side dry-run failure"
    else
        pass "Server-side dry-run failure prevents Helm deployment"
    fi

    if run_deploy_preflight_fixture false 500 500 none container 1 36 false \
      "$FIXTURE_DIR/preflight-output" true \
      && grep -q '^helm upgrade redducklabs-runners ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Existing Helm field ownership does not block a non-persisting server dry-run"
    else
        fail "Existing Helm field ownership blocks the deployment preflight"
    fi

    if run_deploy_preflight_fixture false 500 500 none container 1 36 false "$FIXTURE_DIR/preflight-output" \
      && [ "$(grep -c '^helm template ' "$FIXTURE_DIR/preflight-calls")" -eq 1 ] \
      && [ "$(grep -c '^kubectl apply --server-side --force-conflicts --dry-run=server ' "$FIXTURE_DIR/preflight-calls")" -eq 2 ] \
      && grep -q '^helm upgrade redducklabs-runners ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Compatible ASRS and Pod dry-runs reach the Helm boundary after one render"
    else
        sed -n '1,20p' "$FIXTURE_DIR/preflight-output" >&2
        fail "Healthy live compatibility preflight does not reach Helm"
    fi

    # Node headroom moved to scripts/verify-runner-pool-state.sh, which
    # evaluates every Ready eligible node (request-shape fixtures in
    # test/verify-burst-autoscaling.sh, assert_gate_request_shapes). The
    # preflight no longer reads nodes or pods.
    if run_deploy_preflight_fixture false 1500 1000 none container 1 36 false "$FIXTURE_DIR/preflight-output" \
      && ! grep -Eq '^kubectl get (nodes|pods)' "$FIXTURE_DIR/preflight-calls"; then
        pass "Deploy preflight leaves node headroom to the pool-state gate"
    else
        fail "Deploy preflight still reads nodes/pods for a fixed two-node headroom check"
    fi

    local mutation
    for mutation in resources group placement image privileged unexpected_container wiring restart host_network host_pid host_ipc unknown_top_level service_account_token annotation_removed annotation_true pod_annotation_removed; do
        if run_deploy_preflight_fixture false 500 500 "$mutation" container 1 36 false "$FIXTURE_DIR/preflight-output"; then
            fail "Deploy accepts unsafe admission mutation: ${mutation}"
        elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
            fail "Deploy reaches Helm after unsafe admission mutation: ${mutation}"
        else
            pass "Admission mutation is rejected: ${mutation}"
        fi
    done

    if run_deploy_preflight_fixture false 500 500 api_defaults container 1 36 false "$FIXTURE_DIR/preflight-output" \
      && grep -q '^helm upgrade redducklabs-runners ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Canonical admission comparison permits only documented API defaults"
    else
        fail "Canonical admission comparison rejects documented API defaults"
    fi

    if run_deploy_preflight_fixture false 500 500 none container 2 0 false "$FIXTURE_DIR/preflight-output" \
      && grep -q '^helm upgrade redducklabs-runners ' "$FIXTURE_DIR/preflight-calls"; then
        pass "API server version gate compares the full major/minor tuple"
    else
        fail "API server version gate compares only the minor version"
    fi

    if run_deploy_preflight_fixture false 500 500 none container 1 36 true "$FIXTURE_DIR/preflight-output"; then
        fail "Helm accepts a second render that differs from the preflight candidate"
    elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
        fail "Helm mutation begins despite a preflight candidate hash mismatch"
    elif ! grep -Fqi 'candidate manifest hash mismatch' "$FIXTURE_DIR/preflight-output"; then
        fail "Helm post-render hash mismatch is not diagnostic"
    else
        pass "Helm post-renderer blocks second-render drift before mutation"
    fi
}

assert_hostile_dispatch_inputs_are_data() {
    local workflow step label script sentinel payload
    sentinel="$FIXTURE_DIR/hostile-final-wave-executed"
    payload='$(touch '"$sentinel"')'
    while IFS='|' read -r workflow step label; do
        script="$FIXTURE_DIR/hostile-$(basename "$workflow").sh"
        : > "$script"
        rm -f "$sentinel"
        materialize_workflow_step "$workflow" "$step" "$payload" 4 2 2 "$script" || {
            fail "$label hostile input fixture could not be materialized"
            continue
        }
        : > "$FIXTURE_DIR/mutations"
        run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" || true
        if [ -e "$sentinel" ]; then
            fail "$label executes hostile expected_sha input as shell code"
        elif [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "$label reaches mutation while rejecting hostile expected_sha"
        else
            pass "$label treats hostile expected_sha as inert data"
        fi
    done <<'CASES'
.github/workflows/scale-runners.yml|Validate and sanitize inputs|Scale Runners
.github/workflows/node-pool-sizing.yml|Validate inputs and expected SHA|Node Pool Sizing
CASES
}



assert_prepared_platform_prerequisites() {
    local script="$FIXTURE_DIR/prepared-platform.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Verify prepared platform prerequisites' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Prepared-platform fixture could not be materialized"
        return
    fi

    local state
    FIXTURE_SA_STATE=absent FIXTURE_REGISTRY_STATE=ready FIXTURE_MISSING_CRD=none
    FIXTURE_SCALE_RELEASE_STATE=absent
    export FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE FIXTURE_MISSING_CRD FIXTURE_SCALE_RELEASE_STATE
    for state in missing stale; do
        FIXTURE_PLATFORM_STATE=$state
        export FIXTURE_PLATFORM_STATE
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Deploy accepts ${state} platform prerequisites"
        elif [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "Deploy mutates while rejecting ${state} platform prerequisites"
        else
            pass "Deploy rejects ${state} platform prerequisites before ASRS preflight"
        fi
    done

    FIXTURE_PLATFORM_STATE=ready
    export FIXTURE_PLATFORM_STATE
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a platform without the runner release and its chart-owned ServiceAccount"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy mutates while rejecting an absent runner release"
    else
        pass "Deploy rejects an absent runner release/ServiceAccount (no first-install path in the burst design)"
    fi

    local collision
    for collision in unmanaged foreign; do
        FIXTURE_SCALE_RELEASE_STATE=pinned
        FIXTURE_SA_STATE=$collision
        export FIXTURE_SA_STATE FIXTURE_SCALE_RELEASE_STATE
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Deploy accepts a ${collision} chart ServiceAccount collision"
        elif [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "Deploy mutates while rejecting a ${collision} chart ServiceAccount collision"
        else
            pass "Deploy rejects a ${collision} chart ServiceAccount collision before Helm"
        fi
    done

    FIXTURE_SA_STATE=helm
    FIXTURE_SCALE_RELEASE_STATE=pinned
    export FIXTURE_SA_STATE FIXTURE_SCALE_RELEASE_STATE
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
      && [ ! -s "$FIXTURE_DIR/mutations" ]; then
        pass "Deploy accepts the chart ServiceAccount only with exact Helm ownership"
    else
        fail "Deploy rejects the correctly Helm-owned chart ServiceAccount"
    fi

    FIXTURE_PLATFORM_STATE=stale
    export FIXTURE_PLATFORM_STATE
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a stale ARC controller with a Helm-owned ServiceAccount"
    elif ! grep -Fq 'ARC controller Deployment' "$FIXTURE_DIR/output"; then
        fail "Deploy stale-controller rejection does not come from scripts/lib/arc-identity.sh"
    else
        pass "Deploy rejects a stale ARC controller through the shared identity library"
    fi
    FIXTURE_PLATFORM_STATE=ready
    export FIXTURE_PLATFORM_STATE

    FIXTURE_SA_STATE=helm
    local registry_state
    for registry_state in wrong_type missing_auth; do
        FIXTURE_REGISTRY_STATE=$registry_state
        export FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Deploy accepts registry secret with ${registry_state//_/ }"
        elif [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "Deploy mutates while rejecting registry secret with ${registry_state//_/ }"
        else
            pass "Deploy rejects registry secret with ${registry_state//_/ } before Helm"
        fi
    done

    FIXTURE_REGISTRY_STATE=ready
    FIXTURE_MISSING_CRD=ephemeralrunners.actions.github.com
    export FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE FIXTURE_MISSING_CRD
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a platform missing one of the four pinned ARC CRDs"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy mutates while rejecting an incomplete pinned ARC CRD set"
    else
        pass "Deploy requires all four pinned ARC CRDs to be Established"
    fi
    unset FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE FIXTURE_MISSING_CRD FIXTURE_SCALE_RELEASE_STATE
}

assert_shared_fleet_concurrency() {
    if python3 - <<'PY'
import glob
import yaml

shared = {'group': 'runner-fleet-mutation', 'cancel-in-progress': False}
# Ruling 28 exceptions, each in its own non-cancelling group:
#   Emergency Stop must run immediately, not wait behind a multi-hour drain
#   or Phase C; in-flight mutations then fail closed at their next identity
#   compare or admission.
#   Rebalance must never queue behind (or displace a pending) fleet mutation;
#   it skips while any fleet mutator is queued or running and still takes
#   the gate otherwise.
exceptions = {
    '.github/workflows/emergency-stop.yml': {'group': 'runner-emergency-stop', 'cancel-in-progress': False},
    '.github/workflows/rebalance-runners.yml': {'group': 'runner-rebalance', 'cancel-in-progress': False},
}
mutators = [
    '.github/workflows/deploy-runners.yml',
    '.github/workflows/scale-runners.yml',
    '.github/workflows/node-pool-sizing.yml',
    '.github/workflows/prepare-runner-platform.yml',
    '.github/workflows/deploy-cluster-addons.yml',
]
for path in mutators:
    with open(path, encoding='utf-8') as stream:
        workflow = yaml.safe_load(stream)
    if workflow.get('concurrency') != shared:
        raise SystemExit(f'{path} does not use the exact shared non-cancelling fleet concurrency group')
for path, expected in exceptions.items():
    with open(path, encoding='utf-8') as stream:
        workflow = yaml.safe_load(stream)
    if workflow.get('concurrency') != expected:
        raise SystemExit(f'{path} does not use its documented exception group {expected}')
# No other workflow may take the shared group without being listed above.
for path in sorted(glob.glob('.github/workflows/*.yml')):
    with open(path, encoding='utf-8') as stream:
        workflow = yaml.safe_load(stream)
    if workflow.get('concurrency') == shared and path not in mutators:
        raise SystemExit(f'{path} joins the fleet group but is not a listed fleet mutator')
PY
    then
        pass "Every runner-fleet mutator shares one non-cancelling group; Emergency Stop and Rebalance use their documented own groups"
    else
        fail "Runner-fleet mutation workflows do not share the exact concurrency contract"
    fi
}

assert_platform_ownership_and_registry_generation() {
    if python3 - <<'PY'
import yaml

with open('.github/workflows/prepare-runner-platform.yml', encoding='utf-8') as stream:
    workflow = yaml.safe_load(stream)
shell = '\n'.join(
    step.get('run', '')
    for job in workflow.get('jobs', {}).values()
    for step in job.get('steps', [])
)
if 'kubectl create serviceaccount redducklabs-runners-gha-rs-no-permission' in shell:
    raise SystemExit('platform preparation still creates the scale-set chart ServiceAccount')
for token in (
    'doctl registry docker-config',
    'kubectl create secret generic do-registry-secret',
    '--type=kubernetes.io/dockerconfigjson',
    '--from-file=.dockerconfigjson=',
    '--namespace arc-runners',
):
    if token not in shell:
        raise SystemExit(f'platform registry-secret generation missing {token}')
PY
    then
        pass "Platform preparation leaves the chart ServiceAccount to Helm and explicitly generates the registry secret"
    else
        fail "Platform preparation ownership or registry-secret generation contract is incomplete"
    fi
}

assert_review_fix_trust_snapshots() {
    write_fake_gh

    if run_trust_fixture url_sensitive "$FIXTURE_DIR/trust-output" \
      && grep -Fq 'contents/.github/workflows/density%20%231%3F.yml' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq -- '--method GET' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq -- '-f ref=1111111111111111111111111111111111111111' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary scans URL-sensitive workflow paths at an encoded immutable ref"
    else
        fail "Trust boundary does not safely scan a URL-sensitive workflow path/default branch"
    fi

    local scenario
    for scenario in default_branch_drift head_drift; do
        if run_trust_fixture "$scenario" "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary accepts ${scenario//_/ } during a public-workflow scan"
        elif grep -Eq -- '--method (POST|PATCH|PUT|DELETE)' "$FIXTURE_DIR/gh-calls"; then
            fail "Trust boundary mutates after ${scenario//_/ } during a public-workflow scan"
        elif ! grep -Eqi 'default branch|head.*changed|changed.*head' "$FIXTURE_DIR/trust-output"; then
            fail "Trust boundary ${scenario//_/ } rejection is not diagnostic"
        else
            pass "Trust boundary aborts on ${scenario//_/ } before mutation"
        fi
    done

    if run_trust_fixture create "$FIXTURE_DIR/trust-output" \
      && grep -Fq '/repositories/1359405097' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq '/repositories/1271568186' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq '/repositories/1208056940' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'repos/redducklabs/agent-handoff-toolkit/actions/workflows' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'repos/redducklabs/fountainrank/actions/workflows' "$FIXTURE_DIR/gh-calls" \
      && grep -Fq 'repos/redducklabs/claude-control/actions/workflows' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary scans all three committed migration identities independently"
    else
        fail "Trust boundary does not independently scan all three required migration repositories"
    fi
}

assert_emergency_reason_is_inert() {
    local sentinel="$FIXTURE_DIR/emergency-reason-executed"
    local backtick_sentinel="$FIXTURE_DIR/emergency-backtick-executed"
    local payload='$(touch '"$sentinel"') "quoted reason" `touch '"$backtick_sentinel"'`'
    local step script output
    for step in 'Scale to zero' 'Create recovery instructions' 'Send notification'; do
        script="$FIXTURE_DIR/emergency-${step// /-}.sh"
        output="$FIXTURE_DIR/emergency-${step// /-}.out"
        python3 - .github/workflows/emergency-stop.yml "$step" "$payload" "$script" <<'PY'
import re
import shlex
import sys
import yaml

_, workflow_path, step_name, reason, output = sys.argv
with open(workflow_path, encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
step = next(
    item
    for job in workflow["jobs"].values()
    for item in job.get("steps", [])
    if item.get("name") == step_name
)
replacements = {
    "needs.validate-inputs.outputs.reason": reason,
    "needs.validate-inputs.outputs.namespace": "arc-runners",
    "steps.backup.outputs.deployment_exists": "true",
    "steps.backup.outputs.current_min": "2",
    "steps.backup.outputs.current_max": "4",
    "steps.backup.outputs.pod_count": "2",
    "github.actor": "fixture-user",
    "job.status": "success",
}
def render(value):
    return re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda match: replacements.get(match.group(1), "fixture"), str(value))
with open(output, "w", encoding="utf-8") as target:
    for name, value in (step.get("env") or {}).items():
        target.write(f"export {name}={shlex.quote(render(value))}\n")
    target.write(render(step["run"]))
    target.write("\n")
PY
        rm -f "$sentinel" "$backtick_sentinel"
        if ! (
            export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
            export RELEASE_NAME=redducklabs-runners ARC_CHART_VERSION=0.14.2
            helm() { :; }
            sleep() { :; }
            export -f helm sleep
            bash -euo pipefail "$script"
        ) >"$output" 2>&1; then
            fail "Emergency Stop cannot handle shell-active quoted reason in ${step}"
        elif [ -e "$sentinel" ] || [ -e "$backtick_sentinel" ]; then
            fail "Emergency Stop executes a validated reason in ${step}"
        elif ! grep -Fq 'quoted reason' "$output" && [ "$step" != 'Create recovery instructions' ]; then
            fail "Emergency Stop loses the validated reason in ${step}"
        else
            pass "Emergency Stop treats the validated reason as inert data in ${step}"
        fi
    done
}

assert_deploy_unused_revision_cannot_route() {
    # Ruling 34 removed rollback_revision; the remaining routing-adjacent input
    # is acknowledge_emergency_stop, which must be exactly true or false and can
    # never inject another workflow output.
    local script="$FIXTURE_DIR/deploy-unused-revision.sh"
    local payload=$'false\noperation=rollback'
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || {
        fail "Deploy acknowledgement routing fixture could not be materialized"
        return
      }
    python3 - "$script" "$payload" <<'PY'
import shlex
import sys

path, payload = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    source = stream.read()
if "export INPUT_ACKNOWLEDGE_STOP=false" not in source:
    raise SystemExit("acknowledgement input export not found")
source = source.replace("export INPUT_ACKNOWLEDGE_STOP=false", f"export INPUT_ACKNOWLEDGE_STOP={shlex.quote(payload)}", 1)
with open(path, "w", encoding="utf-8") as stream:
    stream.write(source)
PY
    : > "$FIXTURE_DIR/mutations"
    : > "$FIXTURE_DIR/github-output"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a multi-line acknowledge_emergency_stop value"
        return
    fi
    if ! grep -q '^operation=rollback' "$FIXTURE_DIR/github-output" \
        && grep -Fq 'acknowledge_emergency_stop must be true or false' "$FIXTURE_DIR/output"; then
        pass "Deploy rejects a malformed acknowledge_emergency_stop before emitting any routing output"
    else
        fail "Deploy acknowledgement input can inject routing outputs"
    fi
}



assert_registry_temp_and_oidc_hardening() {
    local script="$FIXTURE_DIR/registry-temp-symlink.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Verify prepared platform prerequisites' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || {
        fail "Registry temporary-file fixture could not be materialized"
        return
      }
    printf 'do-not-overwrite\n' > "$FIXTURE_DIR/registry-target"
    rm -f "$FIXTURE_DIR/do-registry-config.json"
    ln -s "$FIXTURE_DIR/registry-target" "$FIXTURE_DIR/do-registry-config.json"
    FIXTURE_PLATFORM_STATE=ready FIXTURE_SA_STATE=helm FIXTURE_REGISTRY_STATE=ready
    export FIXTURE_PLATFORM_STATE FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE
    : > "$FIXTURE_DIR/mutations"
    run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" || true
    if grep -Fxq 'do-not-overwrite' "$FIXTURE_DIR/registry-target"; then
        pass "Deploy registry validation uses a protected unpredictable temporary file"
    else
        fail "Deploy registry validation follows a predictable temporary-file path"
    fi
    rm -f "$FIXTURE_DIR/do-registry-config.json"

    if python3 - <<'PY'
import yaml
for path in (
    '.github/workflows/deploy-runners.yml',
    '.github/workflows/scale-runners.yml',
    '.github/workflows/emergency-stop.yml',
):
    with open(path, encoding='utf-8') as stream:
        workflow = yaml.safe_load(stream)
    if (workflow.get('permissions') or {}).get('id-token') == 'write':
        raise SystemExit(f'unused OIDC permission remains in {path}')
PY
    then
        pass "Runner mutation workflows do not grant unused OIDC token permission"
    else
        fail "Runner mutation workflows retain unused id-token: write permission"
    fi
}

assert_distinct_legacy_and_density_contracts() {
    local legacy_values=test/fixtures/arc-legacy-isolated-values.yaml
    local legacy_manifest="$FIXTURE_DIR/legacy-isolated-manifest.yaml"
    local literal_default="$FIXTURE_DIR/legacy-literal-default.yaml"
    local private_legacy="$FIXTURE_DIR/legacy-private-2x2.yaml"
    python3 - "$legacy_values" "$literal_default" "$private_legacy" <<'PY'
import copy
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    legacy = yaml.safe_load(stream)
literal = copy.deepcopy(legacy)
literal["runnerGroup"] = "Default"
private = copy.deepcopy(legacy)
private["minRunners"] = 2
private["maxRunners"] = 2
private["runnerGroup"] = "redducklabs-private-runners"
private["template"]["spec"]["automountServiceAccountToken"] = False
for path, value in ((sys.argv[2], literal), (sys.argv[3], private)):
    with open(path, "w", encoding="utf-8") as stream:
        yaml.safe_dump(value, stream, sort_keys=False)
PY
    if ! python -B scripts/validate-runner-isolation-contract.py \
      --contract legacy-isolated --kind values --min-runners 2 --max-runners 8 \
      --runner-group default < "$legacy_values"; then
        fail "Validator rejects the real legacy Default 2/8 isolated values"
    elif ! helm template redducklabs-runners "$CHART" \
      --version "$CHART_VERSION" --kube-version "$KUBE_VERSION" \
      -f "$legacy_values" --set githubConfigSecret.github_token=PLACEHOLDER \
      --set controllerServiceAccount.name=arc-gha-rs-controller \
      --set controllerServiceAccount.namespace=arc-systems > "$legacy_manifest" \
      || ! python -B scripts/validate-runner-isolation-contract.py \
        --contract legacy-isolated --kind manifest --min-runners 2 --max-runners 8 \
        --runner-group default < "$legacy_manifest"; then
        fail "Validator rejects the real rendered legacy Default contract"
    else
        pass "Validator accepts real legacy values with absent Default group semantics"
    fi

    if ! python -B scripts/validate-runner-isolation-contract.py \
      --contract legacy-isolated --kind values --min-runners 2 --max-runners 8 \
      --runner-group default < "$literal_default" \
      || ! python -B scripts/validate-runner-isolation-contract.py \
        --contract legacy-isolated --kind values --min-runners 2 --max-runners 2 \
        --runner-group private < "$private_legacy"; then
        fail "Validator rejects literal Default or private 2/2 legacy isolation semantics"
    else
        pass "Validator accepts literal Default and private 2/2 legacy isolation semantics"
    fi

    if python -B scripts/validate-runner-isolation-contract.py \
      --contract density --kind values --min-runners 2 --max-runners 2 \
      --runner-group private < "$private_legacy"; then
        fail "Density validator accepts the legacy isolated template"
    else
        pass "Density and legacy isolation contracts are not conflated"
    fi
}


assert_exact_deploy_namespace() {
    local script="$FIXTURE_DIR/deploy-noncanonical-namespace.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || {
        fail "Deploy namespace fixture could not be materialized"
        return
      }
    sed -i 's/export INPUT_NAMESPACE=arc-runners/export INPUT_NAMESPACE=other-runners/' "$script"
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Deploy accepts a noncanonical namespace that conflicts with Helm ownership checks"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy rejects a noncanonical namespace only after mutation"
    else
        pass "Deploy rejects a noncanonical namespace before mutation"
    fi
}



assert_rollback_ignores_deploy_only_inputs() {
    local script="$FIXTURE_DIR/rollback-input-isolation.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Rollback input-isolation fixture could not be materialized"
        return
    fi
    sed -i \
      -e 's/export INPUT_OPERATION=deploy/export INPUT_OPERATION=rollback/' \
      -e 's/export INPUT_MAX_RUNNERS=4/export INPUT_MAX_RUNNERS=not-a-deploy-count/' \
      -e 's#export INPUT_RUNNER_IMAGE=.*#export INPUT_RUNNER_IMAGE=not-a-deploy-image#' \
      "$script"
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
      && [ ! -s "$FIXTURE_DIR/mutations" ]; then
        pass "Rollback validation depends only on rollback inputs"
    else
        fail "Deploy-only runner inputs can block rollback validation"
    fi
}

assert_final_review_regressions() {
    if python3 - <<'PY'
from pathlib import Path

expected = [
    "776507734:zipbot-internal",
    "1006277397:therapy-link",
    "1018231298:redducklabs",
    "1025075333:autoduck",
    "1033531555:platform-observability",
    "1037651737:zipbot-v2",
    "1154788719:redducklaw",
    "1193238112:aurolegal.ai",
    "1351028230:manager",
    "1418079240:superfood-shred",
    "1425956382:keel",
]
manifest = Path("deploy/trusted-runner-repositories.txt").read_text(encoding="utf-8").splitlines()
if manifest != expected:
    raise SystemExit("trusted repository manifest is not the exact eleven identity-bearing entries")
if "1334789692:my-review-buddy" in manifest or any(entry.endswith(":my-review-buddy") for entry in manifest):
    raise SystemExit("my-review-buddy is not admitted to the private runner group")
for repo in ("keel", "superfood-shred"):
    evidence = Path(f"docs/security/runner-admission/{repo}.md")
    if not evidence.is_file():
        raise SystemExit(f"admitted repository {repo} has no committed admission evidence")
    text = evidence.read_text(encoding="utf-8")
    for token in (
        "fork-pr-workflows-private-repos",
        "run_workflows_from_fork_pull_requests",
        "pull_request_target",
        "workflow_run",
        "Collaborators",
        "redducklabs-runners",
    ):
        if token not in text:
            raise SystemExit(f"admission evidence for {repo} omits {token}")
script = Path("scripts/verify-runner-trust-boundary.sh").read_text(encoding="utf-8")
for token in (
    "TRUSTED_REPOSITORIES_FILE=",
    "deploy/trusted-runner-repositories.txt",
    "read_trusted_repositories",
    "fork-pr-workflows-private-repos",
):
    if token not in script:
        raise SystemExit(f"trust verifier does not consume the committed manifest ({token})")
if "'776507734:zipbot-internal'" in script:
    raise SystemExit("trust verifier retains an independent hard-coded trusted repository list")
PY
    then
        pass "Trust verifier consumes the exact committed identity-bearing repository manifest"
    else
        fail "Trusted repository manifest is not the enforced trust source of truth"
    fi

    local image_script="$FIXTURE_DIR/deploy-noncanonical-runner-image.sh"
    : > "$image_script"
    if ! materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$image_script"; then
        fail "Deploy canonical-image regression fixture could not be materialized"
    else
        sed -i 's#export INPUT_RUNNER_IMAGE=registry.digitalocean.com/redducklabs/github-runner:latest#export INPUT_RUNNER_IMAGE=registry.digitalocean.com/redducklabs/github-runner:alternate#' "$image_script"
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$image_script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Deploy accepts a noncanonical runner image that ordinary scaling rejects"
        elif [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "Deploy rejects a noncanonical runner image only after mutation"
        elif ! grep -Fq 'fixed canonical image' "$FIXTURE_DIR/output"; then
            fail "Deploy noncanonical-image rejection is not diagnostic"
        else
            pass "Deploy rejects a noncanonical runner image before mutation"
        fi
    fi

    if python3 - <<'PY'
from pathlib import Path

runbook = " ".join(Path("docs/runbooks/node-pool-sizing.md").read_text(encoding="utf-8").split())
# Burst rollout order (spec "Rollout"): verify the committed density rollback
# target, trust boundary, pools, deploy, then acceptance; rollback restores the
# committed density values (Ruling 34).
required = [
    "**Verify the rollback target.** Scale Runners `action=record-density`",
    "`deploy/density-values.yaml`, the target Deploy `rollback` restores",
    "**Trust boundary.** Deploy GitHub Runners `operation=prepare-trust-boundary`",
    "**Pools.** Node Pool Sizing `create-burst`",
    "**Deploy.** Deploy GitHub Runners `operation=deploy`",
    "**Acceptance** phases A–E",
    "Deploy GitHub Runners `operation=rollback`. It validates the committed `deploy/density-values.yaml`",
]
positions = []
for text in required:
    position = runbook.find(text)
    if position < 0:
        raise SystemExit(f"runbook is missing required rollout instruction: {text}")
    positions.append(position)
if positions != sorted(positions):
    raise SystemExit("runbook rollout instructions are not ordered record -> trust -> pools -> deploy -> acceptance -> rollback")
for retired in ("rollout-quiesce", "legacy-isolated 2/2", "Node Pool Sizing accepts only 2/2"):
    if retired in runbook:
        raise SystemExit(f"runbook retains the retired step: {retired}")
if "Deploy GitHub Runners from the same SHA. It runs server-side dry-runs of the rendered scale set and representative Pod before Helm mutation, and records" in runbook:
    raise SystemExit("runbook incorrectly assigns rollback-revision capture to Deploy")
# Rulings 26-28 and 33-34: drain takes no revision; Emergency Stop has its own
# section covering the stopped states, the stop marker, its own lock and recovery.
for text in (
    "-f operation=drain -f expected_sha=\"$SHA\"",
    "1. Deploy GitHub Runners `operation=drain`. It moves ARC to `drain`",
    "runner-fleet-emergency-stop", "acknowledge_emergency_stop=true",
    "## Emergency Stop",
    "does not wait for a running Deploy `drain` or Scale Runners Phase C",
    "`burst-stopped`", "`drain-stopped`", "`density-stopped`",
    "`runner-emergency-stop`", "`runner-rebalance`", "--history-max 100",
):
    if text not in runbook:
        raise SystemExit(f"runbook is missing: {text}")
if "Emergency Stop is unchanged" in runbook:
    raise SystemExit("runbook still says Emergency Stop is unchanged")

values = Path("deploy/dind-values.yaml").read_text(encoding="utf-8")
if "the cluster is 1.33" in values:
    raise SystemExit("values file retains stale Kubernetes 1.33 statement")
if "Kubernetes API server and eligible runner nodes must be 1.36 or newer" not in values:
    raise SystemExit("values file does not state the supported Kubernetes version invariant")
PY
    then
        pass "Runbook sequencing and Kubernetes-version documentation match the executable rollout contract"
    else
        fail "Runbook sequencing or Kubernetes-version documentation is stale"
    fi
}

assert_scale_workflow_static_contract() {
    # Ordinary min/max scaling and rollout-quiesce are retired (burst spec,
    # "No ordinary runtime scaling"). Behavioral coverage for record-density
    # and acceptance-phase-c lives in test/verify-burst-autoscaling.sh.
    if python3 - <<'PY'
import yaml

with open('.github/workflows/scale-runners.yml', encoding='utf-8') as source:
    workflow = yaml.safe_load(source)
env = workflow.get('env') or {}
if env.get('ARC_CHART_VERSION') != '0.14.2':
    raise SystemExit('ARC_CHART_VERSION must be pinned to 0.14.2')
inputs = (workflow.get('on') or workflow[True])['workflow_dispatch']['inputs']
if set(inputs) != {'action', 'expected_sha'}:
    raise SystemExit(f'Scale Runners inputs must be action and expected_sha only: {sorted(inputs)}')
if inputs['action'].get('options') != ['record-density', 'acceptance-phase-c']:
    raise SystemExit('Scale Runners actions must be exactly record-density and acceptance-phase-c')
(job,) = workflow['jobs'].values()
steps = job['steps']
names = [step.get('name') for step in steps]
guard = names.index('Validate and sanitize inputs')
for step in steps[:guard]:
    if any(token in step.get('run', '') for token in ('doctl', 'kubectl', 'helm')):
        raise SystemExit(f'{step.get("name")} reaches the cluster before the expected_sha check')
for step in steps:
    run = step.get('run', '')
    if 'helm upgrade' in run or 'helm rollback' in run:
        raise SystemExit(f'{step.get("name")} writes to Helm directly; Phase C writes only through scripts/acceptance-phase-c.sh')
PY
    then
        pass "Scale Runners exposes only record-density and acceptance-phase-c, SHA-guarded, with no direct Helm writes"
    else
        fail "Scale Runners still exposes ordinary scaling or an unguarded Helm write"
    fi
}

assert_ordinary_scaling_retired() {
    # Replaces the ordinary scale-up/down/max/custom density prestate/result
    # fixtures and the rollout-quiesce / legacy-isolated rollback fixtures:
    # those paths no longer exist. Each fleet operation is admitted by the
    # pool-state gate under its own name.
    if python3 - <<'PY'
import re
from pathlib import Path

import yaml


def load(path):
    with open(path, encoding='utf-8') as stream:
        return yaml.safe_load(stream)


scale_text = Path('.github/workflows/scale-runners.yml').read_text(encoding='utf-8')
deploy_text = Path('.github/workflows/deploy-runners.yml').read_text(encoding='utf-8')
for token in ('scale-up', 'scale-down', 'scale-max', 'scale-custom', 'rollout-quiesce',
              '--set maxRunners', 'min_runners', 'max_runners'):
    if token in scale_text:
        raise SystemExit(f'Scale Runners still contains retired ordinary scaling ({token})')
for token in ('min_runners', 'max_runners', '--set minRunners', '--set maxRunners', 'legacy-isolated'):
    if token in deploy_text:
        raise SystemExit(f'Deploy still contains a runner-bound input or legacy-isolated path ({token})')

deploy = load('.github/workflows/deploy-runners.yml')
scale = load('.github/workflows/scale-runners.yml')
expected = {'deploy': 'deploy', 'drain': 'drain', 'rollback': 'rollback'}
for job_name, operation in expected.items():
    runs = '\n'.join(step.get('run', '') for step in deploy['jobs'][job_name]['steps'])
    operations = set(re.findall(r'--operation ([a-z-]+)', runs))
    if operations != {operation}:
        raise SystemExit(f'Deploy {job_name} calls the gate with {operations or "no operation"}, expected {operation}')
(job,) = scale['jobs'].values()
admit = next(step for step in job['steps'] if step.get('id') == 'admit')['run']
for action in ('record-density', 'acceptance-phase-c'):
    if f'{action}) OPERATION={action} ;;' not in admit:
        raise SystemExit(f'Scale Runners {action} is not admitted under its own gate operation')
if '--operation "${OPERATION}"' not in admit:
    raise SystemExit('Scale Runners admission does not pass the mapped operation to the gate')

steps = deploy['jobs']['deploy']['steps']
names = [step['name'] for step in steps]
if not (names.index('Admit pool state and record identities')
        < names.index('Validate committed burst values')
        < names.index('Render and validate candidate')
        < names.index('Server-side preflight candidate')
        < names.index('Deploy runners')):
    raise SystemExit('Deploy does not admit and validate the committed burst values before Helm')
values_step = steps[names.index('Validate committed burst values')]['run']
if '--contract burst --kind values' not in values_step or '--min-runners 2 --max-runners 20' not in values_step:
    raise SystemExit('Deploy does not validate deploy/dind-values.yaml as exactly burst 2/20')
PY
    then
        pass "Ordinary scaling, rollout-quiesce and legacy-isolated rollback are retired; each operation uses its own gate name"
    else
        fail "Retired ordinary scaling/quiesce/legacy rollback paths or per-operation gate names are not enforced"
    fi
}

assert_scale_input_injection_is_blocked() {
    local script="$FIXTURE_DIR/scale-input-injection.sh" payload action
    local shown
    for payload in 'scale-custom' $'record-density\naction=acceptance-phase-c' 'acceptance-phase-c'; do
        shown=${payload//$'\n'/ NL }
        : > "$script"
        if ! materialize_workflow_step .github/workflows/scale-runners.yml \
          'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
            fail "Scale input-injection fixture could not be materialized"
            return
        fi
        python3 - "$script" "$payload" <<'PY'
import shlex
import sys

path, payload = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    source = stream.read()
source = source.replace("export INPUT_ACTION=scale-custom", f"export INPUT_ACTION={shlex.quote(payload)}", 1)
with open(path, "w", encoding="utf-8") as stream:
    stream.write(source)
PY
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            action=$(grep -c '^action=' "$FIXTURE_DIR/github-output")
            if [ "$payload" = acceptance-phase-c ] && [ "$action" = 1 ] \
              && grep -qx 'action=acceptance-phase-c' "$FIXTURE_DIR/github-output"; then
                pass "Scale accepts acceptance-phase-c and emits exactly one action record"
            else
                fail "Scale accepts action input '${shown}'"
            fi
        elif [ -s "$FIXTURE_DIR/mutations" ] || [ -s "$FIXTURE_DIR/github-output" ]; then
            fail "Scale rejects action '${shown}' only after writing outputs or mutating"
        else
            pass "Scale rejects action input '${shown}' before any output or mutation"
        fi
    done
}

assert_final_workflow_graph_and_prerequisites() {
    if python3 - <<'PY'
import pathlib
import yaml

def load(path):
    with open(path, encoding='utf-8') as stream:
        return yaml.safe_load(stream)

scale = load('.github/workflows/scale-runners.yml')
pool = load('.github/workflows/node-pool-sizing.yml')
deploy = load('.github/workflows/deploy-runners.yml')
platform = load('.github/workflows/prepare-runner-platform.yml')
for path, workflow in (
    ('scale-runners.yml', scale), ('node-pool-sizing.yml', pool),
):
    for job in workflow['jobs'].values():
        for step in job.get('steps', []):
            if '${{ github.event.inputs.' in step.get('run', '') or '${{ inputs.' in step.get('run', ''):
                raise SystemExit(f'{path} contains raw dispatch input interpolation in {step.get("name")}')

trust = deploy['jobs']['trust-boundary']
trust_if = str(trust.get('if', ''))
if "operation == 'deploy'" not in trust_if or "operation == 'prepare-trust-boundary'" not in trust_if \
        or 'rollback' in trust_if or 'drain' in trust_if:
    raise SystemExit('trust reconciliation must run only for deploy and prepare-trust-boundary')
rollback = deploy['jobs'].get('rollback')
if not rollback or rollback.get('needs') != 'validate-inputs':
    raise SystemExit('rollback must be a separate job needing only validated inputs')
if 'trust-boundary' in str(rollback.get('needs')):
    raise SystemExit('rollback depends on trust mutation')
rollback_steps = rollback.get('steps', [])
rollback_index = next(i for i, item in enumerate(rollback_steps) if item.get('name') == 'Roll back to committed density values')
post_index = next(i for i, item in enumerate(rollback_steps) if item.get('name') == 'Verify trust boundary after rollback')
if rollback_index >= post_index:
    raise SystemExit('post-recovery checks precede Helm rollback')
before_rollback = '\n'.join(item.get('run', '') for item in rollback_steps[:rollback_index])
if 'verify-runner-trust-boundary.sh' in before_rollback:
    raise SystemExit('trust health can block rollback')
if '--operation rollback' not in before_rollback:
    raise SystemExit('rollback is not admitted by the pool-state gate')
with open('scripts/rollback-density.sh', encoding='utf-8') as stream:
    rollback_script = stream.read()
if 'fleet_helm_bracket "$IDENTITIES" rollback none arc:density:2/4' not in rollback_script:
    raise SystemExit('rollback is not identity-bracketed by the pool-state gate')
deploy_job = deploy['jobs']['deploy']
if "operation == 'deploy'" not in str(deploy_job.get('if', '')):
    raise SystemExit('deployment job is not deploy-only')
steps = deploy_job['steps']
pre = next(i for i, item in enumerate(steps) if item.get('name') == 'Verify prepared platform prerequisites')
render = next(i for i, item in enumerate(steps) if item.get('name') == 'Server-side preflight candidate')
if pre >= render:
    raise SystemExit('prepared-platform checks do not precede ASRS dry-run')
pre_shell = steps[pre]['run']
for token in ('get namespace', 'CRDS=(',
              'autoscalinglisteners.actions.github.com',
              'autoscalingrunnersets.actions.github.com',
              'ephemeralrunners.actions.github.com',
              'ephemeralrunnersets.actions.github.com',
              'meta.helm.sh/release-name', 'meta.helm.sh/release-namespace',
              'scripts/lib/arc-identity.sh', 'verify_arc_identity',
              'kubernetes.io/dockerconfigjson', 'registry.digitalocean.com'):
    if token not in pre_shell:
        raise SystemExit(f'platform prerequisite missing: {token}')
if 'gha-rs-controller' in pre_shell or 'helm list' in pre_shell:
    raise SystemExit('prepared-platform step duplicates the ARC identity library inline')
library = pathlib.Path('scripts/lib/arc-identity.sh').read_text(encoding='utf-8')
for token in ('gha-runner-scale-set-controller-', 'readyReplicas', 'availableReplicas', 'observedGeneration'):
    if token not in library:
        raise SystemExit(f'ARC identity library lacks {token}')
for step in steps:
    if step.get('name') in {'Create namespace if not exists', 'Sync ARC CRDs',
                            'Install or upgrade ARC controller', 'Configure registry access'}:
        raise SystemExit(f'deploy still mutates platform prerequisite: {step.get("name")}')

platform_shell = '\n'.join(
    step.get('run', '') for job in platform['jobs'].values()
    for step in job.get('steps', [])
)
for token in ('kubectl apply --server-side --force-conflicts',
              'gha-runner-scale-set-controller', 'helm upgrade --install arc'):
    if token not in platform_shell:
        raise SystemExit(f'explicit platform preparation path missing: {token}')
platform_steps = platform['jobs']['prepare-platform']['steps']
platform_guard = next(i for i, item in enumerate(platform_steps)
                      if item.get('name') == 'Revalidate expected SHA')
platform_mutation = next(i for i, item in enumerate(platform_steps)
                         if 'kubectl apply' in item.get('run', '')
                         or 'helm upgrade' in item.get('run', ''))
if platform_guard >= platform_mutation:
    raise SystemExit('platform preparation mutation is not SHA guarded')

status_text = pathlib.Path('.github/workflows/runner-status.yml').read_text(encoding='utf-8')
if 'gh api --paginate --slurp "orgs/${ORG}/actions/runners?per_page=100"' not in status_text:
    raise SystemExit('Runner Status registration enumeration is not paginated/slurped')
local_text = pathlib.Path('scripts/scale-runners.sh').read_text(encoding='utf-8')
if '--paginate --slurp' not in local_text or '| head -10' in local_text:
    raise SystemExit('local status runner aggregation is pagination/pipefail unsafe')
readme = pathlib.Path('README.md').read_text(encoding='utf-8')
if '8 maximum by default' in readme or 'dedicated memory reservation for the Docker daemon' in readme:
    raise SystemExit('README retains superseded runner capacity/resource claims')
PY
    then
        pass "Workflow graph, prepared-platform boundary, pagination, and docs are aligned"
    else
        fail "Final workflow graph, prerequisite, pagination, or documentation contract is incomplete"
    fi
}

assert_node_pool_operations_contract
assert_scale_workflow_static_contract

printf '#!/usr/bin/env bash\ncat\n' > "$FIXTURE_DIR/runner-candidate-hash-gate.sh"
chmod 0700 "$FIXTURE_DIR/runner-candidate-hash-gate.sh"
assert_sha_guarded_boundary 'Deploy' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' '--post-renderer "${HASH_GATE}"' Helm '^helm upgrade redducklabs-runners '
assert_sha_guarded_boundary 'Deploy runner-group REST' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'actions/runner-groups' 'GitHub runner-group REST mutation' '^(curl|gh) .*actions/runner-groups'
# Deploy rollback no longer runs an inline Helm command (Ruling 34): its write is
# scripts/rollback-density.sh inside the identity bracket. Its expected_sha
# guards are exercised end to end by test/verify-burst-autoscaling.sh
# ("deploy rollback: mismatched expected_sha stops before any doctl, kubectl or
# helm call" and "rollback with the checkout moved after validation").
assert_trust_boundary_fixtures
assert_autoscaler_diagnostic_fixtures
assert_deploy_operation_and_preflight_contract
assert_hostile_inputs_are_data
assert_deploy_requires_cotenancy_acceptance
assert_deploy_preflight_fixtures
assert_hostile_dispatch_inputs_are_data
assert_scale_input_injection_is_blocked
assert_prepared_platform_prerequisites
assert_shared_fleet_concurrency
assert_platform_ownership_and_registry_generation
assert_review_fix_trust_snapshots
assert_emergency_reason_is_inert
assert_deploy_unused_revision_cannot_route
assert_registry_temp_and_oidc_hardening
assert_distinct_legacy_and_density_contracts
assert_ordinary_scaling_retired
assert_exact_deploy_namespace
assert_rollback_ignores_deploy_only_inputs
assert_final_review_regressions
assert_final_workflow_graph_and_prerequisites
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
