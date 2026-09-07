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
                "inputs.rollback_revision": "7",
                "inputs.min_runners": "2",
                "inputs.max_runners": max_runners,
                "inputs.expected_sha": expected_sha,
                "inputs.namespace": "arc-runners",
                "inputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "github.event.inputs.operation": "deploy",
                "github.event.inputs.accept_privileged_runner_co_tenancy": "true",
                "github.event.inputs.rollback_revision": "7",
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
                "needs.validate-inputs.outputs.rollback_revision": "7",
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
            "inputs.rollback_revision": "7",
            "inputs.min_runners": "2",
            "inputs.max_runners": max_runners,
            "inputs.expected_sha": expected_sha,
            "inputs.namespace": "arc-runners",
            "inputs.runner_image": "registry.digitalocean.com/redducklabs/github-runner:latest",
            "github.event.inputs.operation": "deploy",
            "github.event.inputs.accept_privileged_runner_co_tenancy": "true",
            "github.event.inputs.rollback_revision": "7",
            "github.event.inputs.max_runners": max_runners,
            "github.event.inputs.min_runners": "2",
            "github.event.inputs.max_nodes": max_nodes,
            "github.event.inputs.min_nodes": min_nodes,
            "github.event.inputs.apply": "true",
            "needs.validate-inputs.outputs.max_runners": max_runners,
            "needs.validate-inputs.outputs.min_runners": "2",
            "needs.validate-inputs.outputs.expected_sha": expected_sha,
            "needs.validate-inputs.outputs.operation": "deploy",
            "needs.validate-inputs.outputs.rollback_revision": "7",
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
    cat > "$FIXTURE_DIR/rollback-manifest.yaml" <<'YAML'
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: redducklabs-runners
spec:
  minRunners: 2
  maxRunners: 2
  runnerGroup: redducklabs-private-runners
  template:
    spec:
      automountServiceAccountToken: false
      containers:
        - name: runner
          resources:
            requests:
              memory: 5Gi
      initContainers:
        - name: dind
          resources:
            requests:
              memory: 5Gi
YAML
    (
        export GITHUB_OUTPUT="$FIXTURE_DIR/github-output"
        export GITHUB_STEP_SUMMARY="$FIXTURE_DIR/github-summary"
        export RUNNER_TEMP="$FIXTURE_DIR"
        export GH_TOKEN=fixture-token
        export CLUSTER_NAME=redducklabs-cluster
        export CLUSTER_CONTEXT=do-sfo3-redducklabs-cluster
        export RELEASE_NAME=redducklabs-runners
        export RUNNER_SCALE_SET_NAME=redducklabs-runners
        export ARC_CHART_VERSION=0.14.2
        export FIXTURE_ACTUAL_SHA
        export FIXTURE_MUTATION_LOG="$mutation_log"
        export FIXTURE_SHA_READ_LOG="$FIXTURE_DIR/sha-reads"
        export FIXTURE_HELM_READ_LOG="$FIXTURE_DIR/helm-reads"
        export FIXTURE_ROLLBACK_MANIFEST="$FIXTURE_DIR/rollback-manifest.yaml"
        export FIXTURE_ROLLBACK_INVALID="${FIXTURE_ROLLBACK_INVALID:-none}"
        export FIXTURE_POOL_MIN FIXTURE_POOL_MAX FIXTURE_POOL_COUNT
        export FIXTURE_POOL_SIZE="${FIXTURE_POOL_SIZE:-s-8vcpu-16gb}"
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
        export FIXTURE_REGISTRY_STATE="${FIXTURE_REGISTRY_STATE:-ready}"
        export FIXTURE_MISSING_CRD="${FIXTURE_MISSING_CRD:-none}"
        export FIXTURE_HELM_UPDATED="$FIXTURE_DIR/helm-updated"
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
                else
                    echo '[{"name":"redducklabs-runners","chart":"gha-runner-scale-set-0.14.2","status":"deployed"}]'
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
                    local manifest_max manifest_group
                    manifest_max=$FIXTURE_HELM_MAX
                    manifest_group=$FIXTURE_HELM_GROUP
                    if [[ " $* " == *" --revision "* ]]; then
                        manifest_max=2
                        manifest_group=$FIXTURE_REVISION_GROUP
                    elif [ -e "$FIXTURE_HELM_UPDATED" ]; then
                        manifest_max=2
                        manifest_group=$FIXTURE_HELM_POST_GROUP
                    fi
                    if [ "$manifest_group" = __missing__ ]; then
                        sed \
                          -e "s/maxRunners: 2/maxRunners: $manifest_max/" \
                          -e '/runnerGroup:/d' \
                          "$FIXTURE_ROLLBACK_MANIFEST"
                    else
                        sed \
                          -e "s/maxRunners: 2/maxRunners: $manifest_max/" \
                          -e "s/runnerGroup: redducklabs-private-runners/runnerGroup: $manifest_group/" \
                          "$FIXTURE_ROLLBACK_MANIFEST"
                    fi
                fi
                return 0
            fi
            case " $* " in
                *" rollback "*) echo "helm $*" >> "$FIXTURE_MUTATION_LOG"; export FIXTURE_ROLLBACK_ACTIVE=true ;;
                *" upgrade "*) echo "helm $*" >> "$FIXTURE_MUTATION_LOG" ; : > "$FIXTURE_HELM_UPDATED" ;;
                *" uninstall "*) echo "helm $*" >> "$FIXTURE_MUTATION_LOG" ;;
            esac
            if [ "$1" = "get" ] && [ "$2" = "values" ]; then
                echo "helm $*" >> "$FIXTURE_HELM_READ_LOG"
                if [ "$FIXTURE_ROLLBACK_INVALID" = values ]; then
                    echo '{"minRunners":2,"maxRunners":4,"runnerGroup":"redducklabs-private-runners"}'
                else
                    local helm_max=$FIXTURE_HELM_MAX helm_group=$FIXTURE_HELM_GROUP reads
                    reads=$(wc -l < "$FIXTURE_HELM_VALUES_READ_COUNT")
                    echo read >> "$FIXTURE_HELM_VALUES_READ_COUNT"
                    if [[ " $* " == *" --revision "* ]]; then
                        helm_max=2
                        helm_group=$FIXTURE_REVISION_GROUP
                    elif [ -e "$FIXTURE_HELM_UPDATED" ]; then
                        helm_max=2
                        helm_group=$FIXTURE_HELM_POST_GROUP
                    elif [ "$reads" -ge 1 ]; then
                        helm_group=$FIXTURE_SECOND_HELM_GROUP
                    fi
                    if [ "$helm_group" = __missing__ ]; then
                        printf '{"minRunners":2,"maxRunners":%s,"template":{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"runner","resources":{"requests":{"memory":"5Gi"}}}],"initContainers":[{"name":"dind","resources":{"requests":{"memory":"5Gi"}}}]}}}\n' "$helm_max"
                    else
                        printf '{"minRunners":2,"maxRunners":%s,"runnerGroup":"%s","template":{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"runner","resources":{"requests":{"memory":"5Gi"}}}],"initContainers":[{"name":"dind","resources":{"requests":{"memory":"5Gi"}}}]}}}\n' "$helm_max" "$helm_group"
                    fi
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
                    printf '[{"id":"%s","name":"github-runners-pool-16g","min_nodes":%s,"max_nodes":%s,"count":%s,"size":"%s","auto_scale":true,"labels":{"node-type":"github-runner"},"taints":[{"key":"github-runner"}]}]\n' "$pool_id" "$FIXTURE_POOL_MIN" "$max" "$count" "$FIXTURE_POOL_SIZE" ; return 0 ;;
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
                        absent) return 0 ;;
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
                    first_uid=fixture-node-a-uid
                    if [ "$node_reads" -ge 1 ]; then first_uid=$FIXTURE_SECOND_NODE_UID; fi
                    if [ "$FIXTURE_READY_NODES" = 2 ]; then
                        printf '{"items":[{"metadata":{"uid":"%s"},"spec":{"providerID":"digitalocean://node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid"},"spec":{"providerID":"digitalocean://node-b"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\n' "$first_uid"
                    else
                        printf '{"items":[{"metadata":{"uid":"%s"},"spec":{"providerID":"digitalocean://node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"uid":"fixture-node-b-uid"},"spec":{"providerID":"digitalocean://node-b"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}\n' "$first_uid"
                    fi
                    return 0
                    ;;
                *" get pods "*) echo '{"items":[]}' ; return 0 ;;
                *" get autoscalingrunnersets.actions.github.com "*)
                    local asrs_reads asrs_group
                    asrs_reads=$(wc -l < "$FIXTURE_ASRS_READ_COUNT")
                    echo read >> "$FIXTURE_ASRS_READ_COUNT"
                    asrs_group=redducklabs-private-runners
                    if [ "$asrs_reads" -ge 1 ]; then asrs_group=$FIXTURE_SECOND_ASRS_GROUP; fi
                    jq -cn --arg group "$asrs_group" '{items:[{spec:{
                      minRunners:2,
                      maxRunners:2,
                      runnerGroup:$group,
                      template:{spec:{
                        automountServiceAccountToken:false,
                        containers:[{name:"runner",resources:{requests:{memory:"5Gi"}}}],
                        initContainers:[{name:"dind",resources:{requests:{memory:"5Gi"}}}]
                      }}
                    }}]}'
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
                *'repos?type=public'*) echo '[]' ;;
                *'runner-groups?per_page=100'*)
                    if [ "${FIXTURE_ROLLBACK_ACTIVE:-false}" = true ]; then
                        echo '{"runner_groups":[{"id":777,"name":"redducklabs-private-runners","visibility":"selected","allows_public_repositories":false}]}'
                    else
                        echo '{"runner_groups":[]}'
                    fi
                    ;;
                *'--method POST'*'actions/runner-groups'*) echo '{"id":777,"name":"redducklabs-private-runners"}' ;;
                *'runner-groups/777/repositories?per_page=100'*) echo '{"repositories":[{"id":776507734,"visibility":"private","private":true},{"id":1006277397,"visibility":"private","private":true},{"id":1018231298,"visibility":"private","private":true},{"id":1025075333,"visibility":"private","private":true},{"id":1033531555,"visibility":"private","private":true},{"id":1037651737,"visibility":"private","private":true},{"id":1154788719,"visibility":"private","private":true},{"id":1193238112,"visibility":"private","private":true},{"id":1351028230,"visibility":"private","private":true}]}' ;;
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
    local original_max=$FIXTURE_POOL_MAX original_count=$FIXTURE_POOL_COUNT
    FIXTURE_POOL_MAX=1
    FIXTURE_POOL_COUNT=1
    : > "$FIXTURE_DIR/mutations"
    if run_named_step .github/workflows/deploy-runners.yml 'Check node pool capacity' "$FIXTURE_ACTUAL_SHA" 4 2 2; then
        fail "Deploy accepts live runner-pool drift (fixture reports min=2, max=1, count=1)"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Deploy reached a mutation after live capacity drift"
    else
        pass "Deploy rejects live runner-pool capacity drift before mutation"
    fi
    FIXTURE_POOL_MAX=$original_max
    FIXTURE_POOL_COUNT=$original_count
}

assert_scale_capacity_gate() {
    local workflow=.github/workflows/scale-runners.yml
    local validation_step='Validate and sanitize inputs'
    local capacity_step='Check runner pool capacity'
    local script="$FIXTURE_DIR/scale-capacity-gate.sh"
    local original_max=$FIXTURE_POOL_MAX original_count=$FIXTURE_POOL_COUNT

    : > "$script"
    if ! materialize_workflow_step "$workflow" "$validation_step" "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" \
       || ! materialize_workflow_step "$workflow" "$capacity_step" "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" \
       || ! materialize_workflow_token "$workflow" 'helm upgrade' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Scale Runners has no executable capacity gate before Helm"
        return
    fi

    FIXTURE_POOL_MAX=1
    FIXTURE_POOL_COUNT=1
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Scale Runners accepts live runner-pool drift before Helm"
    elif [ -s "$FIXTURE_DIR/mutations" ]; then
        fail "Scale Runners reached Helm after live runner-pool drift"
    else
        pass "Scale Runners rejects live runner-pool drift before Helm"
    fi

    FIXTURE_POOL_MAX=$original_max
    FIXTURE_POOL_COUNT=$original_count
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
       && grep -Eq '^helm upgrade .*gha-runner-scale-set' "$FIXTURE_DIR/mutations"; then
        pass "Scale Runners reaches Helm only after a healthy fixed-capacity check"
    else
        fail "Scale Runners does not reach Helm after a healthy fixed-capacity check"
    fi
}

assert_scale_workflow_static_contract() {
    if python - <<'PY'
import yaml

with open('.github/workflows/scale-runners.yml', encoding='utf-8') as source:
    workflow = yaml.safe_load(source)

env = workflow.get('env') or {}
if env.get('ARC_CHART_VERSION') != '0.14.2':
    raise SystemExit('ARC_CHART_VERSION must be pinned to 0.14.2')

capacity_steps = [
    step for job in (workflow.get('jobs') or {}).values()
    for step in (job.get('steps') or [])
    if step.get('name') == 'Check runner pool capacity'
]
if len(capacity_steps) != 1 or capacity_steps[0].get('if') != "needs.validate-inputs.outputs.action != 'status'":
    raise SystemExit('capacity gate must skip the status-only action')

scale_steps = workflow['jobs']['scale']['steps']
capacity_index = next(index for index, step in enumerate(scale_steps) if step.get('name') == 'Check runner pool capacity')
helm_steps = [step for step in scale_steps if 'helm upgrade ' in step.get('run', '')]
helm_indices = [index for index, step in enumerate(scale_steps) if 'helm upgrade ' in step.get('run', '')]
if len(helm_steps) != 5 or any('--version "${ARC_CHART_VERSION}"' not in step['run'] for step in helm_steps):
    raise SystemExit('every Scale Helm upgrade must use ARC_CHART_VERSION')
if any('--set runnerGroup=redducklabs-private-runners' not in step['run'] for step in helm_steps):
    raise SystemExit('every Scale Helm upgrade must preserve the private runner group')
if any(capacity_index >= index for index in helm_indices):
    raise SystemExit('capacity gate must run before every Scale Helm upgrade')

with open('.github/workflows/scale-runners.yml', encoding='utf-8') as source:
    if 'Max=8' in source.read():
        raise SystemExit('Scale operator output still advertises Max=8')
PY
    then
        pass "Scale workflow pins every Helm mutation and keeps status independent"
    else
        fail "Scale workflow chart pin, capacity gate, or operator-output contract is incomplete"
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
    local id=$1 name=$2 visibility=private
    if [ "${GH_SCENARIO}" = public_allowlist ] && [ "$name" = manager ]; then
        visibility=public
    fi
    if [ "${GH_SCENARIO}" = unknown_allowlist ] && [ "$name" = manager ]; then
        name=unexpected-repository
    fi
    printf '{"id":%s,"name":"%s","full_name":"redducklabs/%s","visibility":"%s","private":%s,"owner":{"login":"redducklabs"}}\n' \
        "$id" "$name" "$name" "$visibility" "$([ "$visibility" = private ] && echo true || echo false)"
}

case "$joined" in
    *"/repositories/1193238112"*) repo_json 1193238112 aurolegal.ai ;;
    *"/repositories/1025075333"*) repo_json 1025075333 autoduck ;;
    *"/repositories/1351028230"*) repo_json 1351028230 manager ;;
    *"/repositories/1033531555"*) repo_json 1033531555 platform-observability ;;
    *"/repositories/1018231298"*) repo_json 1018231298 redducklabs ;;
    *"/repositories/1154788719"*) repo_json 1154788719 redducklaw ;;
    *"/repositories/1006277397"*) repo_json 1006277397 therapy-link ;;
    *"/repositories/776507734"*) repo_json 776507734 zipbot-internal ;;
    *"/repositories/1037651737"*) repo_json 1037651737 zipbot-v2 ;;
    *"orgs/redducklabs/repos?type=public"*)
        if [ "${GH_SCENARIO}" = public_label ] || [ "${GH_SCENARIO}" = dynamic_runs_on ] \
          || [ "${GH_SCENARIO}" = workflow_schema ] || [ "${GH_SCENARIO}" = mixed_case_label ] \
          || [ "${GH_SCENARIO}" = later_page_public_label ] \
          || [ "${GH_SCENARIO}" = later_page_workflow_label ] \
          || [ "${GH_SCENARIO}" = managed_copilot ] \
          || [ "${GH_SCENARIO}" = unknown_dynamic_path ]; then
            if [ "${GH_SCENARIO}" = later_page_public_label ] && [ "$paginated" = true ]; then
                printf '[]\n[{"name":"public-repo","default_branch":"main","visibility":"public"}]\n'
            else
                if [ "${GH_SCENARIO}" = later_page_public_label ]; then
                    printf '[]\n'
                else
                    printf '[{"name":"public-repo","default_branch":"main","visibility":"public"}]\n'
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
        elif [ "${GH_SCENARIO}" = unknown_dynamic_path ]; then
            printf '{"total_count":1,"workflows":[{"path":"dynamic/agents/unrecognized","state":"active"}]}\n'
        else
            printf '{"total_count":1,"workflows":[{"path":".github/workflows/ci.yml","state":"active"}]}\n'
        fi
        ;;
    *"repos/redducklabs/public-repo/contents/.github/workflows/ci.yml"*)
        if [ "${GH_SCENARIO}" = dynamic_runs_on ]; then
            printf '%s\n' 'jobs:' '  unsafe:' '    runs-on: ${{ matrix.runner }}' '    steps: []'
        elif [ "${GH_SCENARIO}" = mixed_case_label ]; then
            printf '%s\n' 'jobs:' '  unsafe:' '    runs-on: RedDuckLabs-Runners' '    steps: []'
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
        else
            printf '{"total_count":9,"repositories":['
            printf '%s' \
              '{"id":776507734,"name":"zipbot-internal","full_name":"redducklabs/zipbot-internal","visibility":"private","private":true},' \
              '{"id":1006277397,"name":"therapy-link","full_name":"redducklabs/therapy-link","visibility":"private","private":true},' \
              '{"id":1018231298,"name":"redducklabs","full_name":"redducklabs/redducklabs","visibility":"private","private":true},' \
              '{"id":1025075333,"name":"autoduck","full_name":"redducklabs/autoduck","visibility":"private","private":true},' \
              '{"id":1033531555,"name":"platform-observability","full_name":"redducklabs/platform-observability","visibility":"private","private":true},' \
              '{"id":1037651737,"name":"zipbot-v2","full_name":"redducklabs/zipbot-v2","visibility":"private","private":true},' \
              '{"id":1154788719,"name":"redducklaw","full_name":"redducklabs/redducklaw","visibility":"private","private":true},' \
              '{"id":1193238112,"name":"aurolegal.ai","full_name":"redducklabs/aurolegal.ai","visibility":"private","private":true},' \
              '{"id":1351028230,"name":"manager","full_name":"redducklabs/manager","visibility":"private","private":true}'
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
    "orgs/redducklabs/repos?type=public&per_page=100",
    "orgs/redducklabs/actions/runner-groups?per_page=100",
]
if len(calls) != 14:
    raise SystemExit(f"expected 14 gh calls, found {len(calls)}")
for call, endpoint in zip(calls[:11], expected_reads):
    if endpoint not in call or "--method" in call:
        raise SystemExit(f"unexpected read call: {call}")
if "--method POST orgs/redducklabs/actions/runner-groups" not in calls[11]:
    raise SystemExit("creation is not the first mutation")
if "runner-groups/777" not in calls[12] or "runner-groups/777/repositories" not in calls[13]:
    raise SystemExit("readback calls are missing or reordered")
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
          && grep -q '"selected_repository_ids":\[776507734,1006277397,1018231298,1025075333,1033531555,1037651737,1154788719,1193238112,1351028230\]' "$FIXTURE_DIR/gh-calls"; then
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

    if run_trust_fixture managed_copilot "$FIXTURE_DIR/trust-output" \
      && ! grep -q 'contents/dynamic/agents/copilot-pull-request-reviewer' "$FIXTURE_DIR/gh-calls" \
      && grep -Eq -- '--method (POST|PATCH|PUT)' "$FIXTURE_DIR/gh-calls"; then
        pass "Trust boundary skips only GitHub's exact managed Copilot workflow path"
    else
        fail "Trust boundary does not safely skip GitHub's exact managed Copilot workflow path"
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
if operations != ['deploy', 'prepare-trust-boundary', 'rollback']:
    raise SystemExit('deploy operation choices are incomplete or unordered')
if inputs.get('accept_privileged_runner_co_tenancy', {}).get('type') != 'boolean':
    raise SystemExit('explicit privileged co-tenancy acceptance input is missing')
if 'rollback_revision' not in inputs:
    raise SystemExit('rollback revision input is missing')

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
if "needs.validate-inputs.outputs.operation == 'deploy'" not in deploy.get('if', ''):
    raise SystemExit('prepare-trust-boundary does not stop before the deployment job')

steps = deploy.get('steps') or []
for job in jobs.values():
    for step in job.get('steps', []):
        if '${{ github.event.inputs.' in step.get('run', ''):
            raise SystemExit(f'raw workflow_dispatch input interpolation in shell step: {step.get("name")}')
preflight_index = next(i for i, step in enumerate(steps) if step.get('name') == 'Render and preflight candidate')
deploy_index = next(i for i, step in enumerate(steps) if step.get('name') == 'Deploy runners')
preflight = steps[preflight_index].get('run', '')
deploy_shell = steps[deploy_index].get('run', '')
rollback_steps = jobs.get('rollback', {}).get('steps', [])
rollback = next(step for step in rollback_steps if step.get('name') == 'Rollback runners').get('run', '')
if preflight.count('helm template ') != 1:
    raise SystemExit('candidate must be rendered exactly once')
if preflight.count('kubectl apply --server-side --dry-run=server') != 2:
    raise SystemExit('ASRS and representative Pod server dry-runs are required')
if '--post-renderer "${HASH_GATE}"' not in deploy_shell:
    raise SystemExit('Helm deployment is not guarded by the preflight manifest hash')
if preflight_index >= deploy_index:
    raise SystemExit('preflight does not precede Helm deployment')
if 'helm rollback ' not in rollback:
    raise SystemExit('CI rollback boundary is missing')

overlay_patterns = [
    r'--values deploy/dind-values\.yaml',
    r'--set githubConfigSecret\.github_token=',
    r'--set runnerScaleSetName=',
    r'--set minRunners=',
    r'--set maxRunners=',
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

assert_rollback_revision_prevalidation() {
    local script="$FIXTURE_DIR/deploy-rollback-prevalidation.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Rollback runners' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || {
        fail "Rollback prevalidation fixture could not be materialized"
        return
      }

    local invalid
    for invalid in chart values manifest; do
        : > "$FIXTURE_DIR/mutations"
        FIXTURE_ROLLBACK_INVALID="$invalid"
        export FIXTURE_ROLLBACK_INVALID
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Rollback accepts invalid revision ${invalid} metadata"
        elif grep -q '^helm rollback ' "$FIXTURE_DIR/mutations"; then
            fail "Rollback mutates before rejecting invalid revision ${invalid} metadata"
        elif ! grep -q '^helm history ' "$FIXTURE_DIR/helm-reads"; then
            fail "Rollback does not inspect revision history before ${invalid} rejection"
        else
            pass "Rollback rejects invalid revision ${invalid} metadata before mutation"
        fi
    done
    unset FIXTURE_ROLLBACK_INVALID
}

run_deploy_preflight_fixture() {  # dry-run fail, memory Mi, CPU m, admission mutation, request shape, server major/minor, deploy drift, output
    local fail_dry_run=$1 system_memory_mi=$2 system_cpu_m=$3 admission_mutation=$4
    local request_shape=$5 server_major=$6 server_minor=$7 deploy_drift=$8 output=$9
    local script="$FIXTURE_DIR/deploy-preflight.sh"
    : > "$script"
    materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Render and preflight candidate' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" || return 1
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
                *" apply --server-side --dry-run=server "*)
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
print(json.dumps(document))
PY
                    ;;
            esac
        }
        sleep() { :; }
        export -f helm kubectl sleep
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

    if run_deploy_preflight_fixture false 500 500 none container 1 36 false "$FIXTURE_DIR/preflight-output" \
      && [ "$(grep -c '^helm template ' "$FIXTURE_DIR/preflight-calls")" -eq 1 ] \
      && [ "$(grep -c '^kubectl apply --server-side --dry-run=server ' "$FIXTURE_DIR/preflight-calls")" -eq 2 ] \
      && grep -q '^helm upgrade --install ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Compatible ASRS and Pod dry-runs reach the Helm boundary after one render"
    else
        sed -n '1,20p' "$FIXTURE_DIR/preflight-output" >&2
        fail "Healthy live compatibility preflight does not reach Helm"
    fi

    if run_deploy_preflight_fixture false 1500 500 none container 1 36 false "$FIXTURE_DIR/preflight-output"; then
        fail "Deploy accepts a node without two-pod memory headroom"
    elif [ ! -e "$FIXTURE_DIR/preflight-calls" ]; then
        fail "Deploy node-headroom fixture could not be materialized"
    elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
        fail "Deploy reaches Helm after live node headroom drift"
    else
        pass "Live per-node two-pod plus headroom drift prevents Helm"
    fi

    if run_deploy_preflight_fixture false 500 1000 none container 1 36 false "$FIXTURE_DIR/preflight-output"; then
        fail "Deploy accepts a node without two-pod CPU headroom"
    elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
        fail "Deploy reaches Helm after live node CPU headroom drift"
    else
        pass "Live per-node CPU headroom drift prevents Helm"
    fi

    local mutation
    for mutation in resources group placement image privileged unexpected_container wiring restart host_network host_pid host_ipc unknown_top_level service_account_token; do
        if run_deploy_preflight_fixture false 500 500 "$mutation" container 1 36 false "$FIXTURE_DIR/preflight-output"; then
            fail "Deploy accepts unsafe admission mutation: ${mutation}"
        elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
            fail "Deploy reaches Helm after unsafe admission mutation: ${mutation}"
        else
            pass "Admission mutation is rejected: ${mutation}"
        fi
    done

    if run_deploy_preflight_fixture false 500 500 api_defaults container 1 36 false "$FIXTURE_DIR/preflight-output" \
      && grep -q '^helm upgrade --install ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Canonical admission comparison permits only documented API defaults"
    else
        fail "Canonical admission comparison rejects documented API defaults"
    fi

    local shape
    for shape in pod_level restartable_sidecar regular_init_peak overhead malformed; do
        if run_deploy_preflight_fixture false 500 500 none "$shape" 1 36 false "$FIXTURE_DIR/preflight-output"; then
            fail "Deploy ignores non-runner request shape: ${shape}"
        elif grep -q '^helm upgrade ' "$FIXTURE_DIR/preflight-calls"; then
            fail "Deploy reaches Helm after unsafe request shape: ${shape}"
        else
            pass "Capacity gate accounts for request shape: ${shape}"
        fi
    done

    if run_deploy_preflight_fixture false 500 500 none alternate_valid 1 36 false "$FIXTURE_DIR/preflight-output" \
      && grep -q '^helm upgrade --install ' "$FIXTURE_DIR/preflight-calls"; then
        pass "Capacity gate accepts alternate valid Kubernetes quantities"
    else
        fail "Capacity gate rejects alternate valid Kubernetes quantities"
    fi

    if run_deploy_preflight_fixture false 500 500 none container 2 0 false "$FIXTURE_DIR/preflight-output" \
      && grep -q '^helm upgrade --install ' "$FIXTURE_DIR/preflight-calls"; then
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
.github/workflows/node-pool-sizing.yml|Validate inputs against deploy/dind-values.yaml|Node Pool Sizing
CASES
}

assert_scale_output_record_injection_is_blocked() {
    local validation="$FIXTURE_DIR/scale-output-injection-validation.sh"
    local exploit="$FIXTURE_DIR/scale-output-injection-exploit.sh"
    local payload parsed_action parsed_min parsed_max
    payload=$'4\r\naction=scale-custom\r\nmax_runners=99'
    : > "$validation"
    if ! materialize_workflow_step .github/workflows/scale-runners.yml \
      'Validate and sanitize inputs' "$FIXTURE_ACTUAL_SHA" "$payload" 2 2 "$validation"; then
        fail "Scale output-injection validation fixture could not be materialized"
        return
    fi
    sed -i 's/export INPUT_ACTION=scale-custom/export INPUT_ACTION=scale-up/' "$validation"
    : > "$FIXTURE_DIR/mutations"
    if ! run_fixture "$validation" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        if [ -s "$FIXTURE_DIR/mutations" ]; then
            fail "Scale rejects multiline input only after reaching a mutation"
        else
            pass "Scale rejects multiline output-record injection before mutation"
        fi
        return
    fi

    readarray -t parsed < <(python3 - "$FIXTURE_DIR/github-output" <<'PY'
import sys

values = {}
with open(sys.argv[1], encoding='utf-8', newline=None) as stream:
    for line in stream:
        line = line.rstrip('\r\n')
        if '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
print(values.get('action', ''))
print(values.get('min_runners', ''))
print(values.get('max_runners', ''))
PY
    )
    parsed_action=${parsed[0]:-}
    parsed_min=${parsed[1]:-}
    parsed_max=${parsed[2]:-}
    if [ "$parsed_action" = scale-up ] && [ "$parsed_min" = 2 ] && [ "$parsed_max" = 4 ]; then
        pass "Scale emits canonical fixed outputs for non-custom actions"
        return
    fi

    : > "$exploit"
    if [ "$parsed_action" = scale-custom ] \
      && [[ "$parsed_max" =~ ^[0-9]+$ ]] \
      && [ "$parsed_max" -gt 4 ] \
      && materialize_workflow_step .github/workflows/scale-runners.yml \
        'Custom scaling' "$FIXTURE_ACTUAL_SHA" "$parsed_max" "$parsed_min" 2 "$exploit"; then
        : > "$FIXTURE_DIR/mutations"
        run_fixture "$exploit" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" || true
        if grep -Eq '^helm upgrade .*--set maxRunners="?([5-9]|[1-9][0-9]+)"?' "$FIXTURE_DIR/mutations"; then
            fail "Scale multiline output injection overwrites action/max_runners and reaches Helm above four"
            return
        fi
    fi
    fail "Scale non-custom outputs are not canonical and bounded"
}

assert_rollout_quiesce_contract() {
    if python3 - <<'PY'
import yaml

with open('.github/workflows/scale-runners.yml', encoding='utf-8') as stream:
    workflow = yaml.safe_load(stream)
options = (workflow.get('on') or workflow[True])['workflow_dispatch']['inputs']['action']['options']
if 'rollout-quiesce' not in options:
    raise SystemExit('rollout-quiesce action is missing')
steps = workflow['jobs']['scale']['steps']
step = next(item for item in steps if item.get('name') == 'Quiesce rollout and record rollback revision')
shell = step['run']
required = [
    '--version "${ARC_CHART_VERSION}"', '--set minRunners=2', '--set maxRunners=2',
    '--set runnerGroup=redducklabs-private-runners', 'ephemeralrunnersets.actions.github.com',
    'Pending', 'helm history', 'rollback_revision=',
]
missing = [item for item in required if item not in shell]
if missing:
    raise SystemExit(f'quiesce step missing: {missing}')
capacity = next(item for item in steps if item.get('name') == 'Check runner pool capacity')['run']
if 's-8vcpu-16gb' not in capacity or 'rollout-quiesce' not in capacity:
    raise SystemExit('quiesce transition is not admitted by the exact-size capacity gate')
PY
    then
        pass "Scale Runners exposes a pinned quiesce transition and rollback revision"
    else
        fail "Scale Runners lacks the executable rollout-quiesce transition"
    fi

    local script="$FIXTURE_DIR/rollout-quiesce.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/scale-runners.yml \
      'Check runner pool capacity' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" \
      || ! materialize_workflow_step .github/workflows/scale-runners.yml \
      'Quiesce rollout and record rollback revision' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Rollout-quiesce functional fixture could not be materialized"
        return
    fi
    sed -i 's/export ACTION=fixture/export ACTION=rollout-quiesce/' "$script"
    local original_max=$FIXTURE_POOL_MAX
    local case_max case_group
    while IFS='|' read -r case_max case_group; do
        FIXTURE_POOL_MAX=$case_max
        FIXTURE_HELM_MAX=$case_max
        FIXTURE_HELM_GROUP=$case_group
        FIXTURE_HELM_POST_GROUP=redducklabs-private-runners
        FIXTURE_REVISION_GROUP=redducklabs-private-runners
        export FIXTURE_POOL_MAX FIXTURE_HELM_MAX FIXTURE_HELM_GROUP
        export FIXTURE_HELM_POST_GROUP FIXTURE_REVISION_GROUP
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
          && grep -Eq '^helm upgrade .*--set minRunners=2 .*--set maxRunners=2 .*--set runnerGroup=redducklabs-private-runners' "$FIXTURE_DIR/mutations" \
          && grep -q '^rollback_revision=' "$FIXTURE_DIR/github-output"; then
            pass "Rollout-quiesce accepts recognized ${case_group} 2/${case_max} prestate and emits a private rollback revision"
        else
            fail "Rollout-quiesce rejects recognized ${case_group} 2/${case_max} prestate"
        fi
    done <<'CASES'
8|Default
2|redducklabs-private-runners
CASES

    local invalid_group
    for invalid_group in __missing__ arbitrary-runner-group; do
        FIXTURE_POOL_MAX=8
        FIXTURE_HELM_MAX=8
        FIXTURE_HELM_GROUP=$invalid_group
        export FIXTURE_POOL_MAX FIXTURE_HELM_MAX FIXTURE_HELM_GROUP
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Rollout-quiesce accepts ${invalid_group/__missing__/missing} prestate runner group"
        elif grep -q '^helm upgrade ' "$FIXTURE_DIR/mutations"; then
            fail "Rollout-quiesce reaches Helm with ${invalid_group/__missing__/missing} prestate runner group"
        else
            pass "Rollout-quiesce rejects ${invalid_group/__missing__/missing} prestate runner group before Helm"
        fi
    done

    FIXTURE_POOL_MAX=2
    FIXTURE_HELM_MAX=2
    FIXTURE_HELM_GROUP=redducklabs-private-runners
    FIXTURE_HELM_POST_GROUP=redducklabs-private-runners
    FIXTURE_REVISION_GROUP=foreign-runner-group
    export FIXTURE_POOL_MAX FIXTURE_HELM_MAX FIXTURE_HELM_GROUP
    export FIXTURE_HELM_POST_GROUP FIXTURE_REVISION_GROUP
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Rollout-quiesce emits a rollback revision whose exact private poststate was not validated"
    elif grep -q '^rollback_revision=' "$FIXTURE_DIR/github-output"; then
        fail "Rollout-quiesce writes an unvalidated rollback revision output"
    else
        pass "Rollout-quiesce rejects a rollback revision with non-private state"
    fi

    FIXTURE_POOL_MAX=$original_max FIXTURE_HELM_MAX=2
    unset FIXTURE_HELM_GROUP FIXTURE_HELM_POST_GROUP FIXTURE_REVISION_GROUP
}

assert_node_pool_no_removal_contract() {
    local script="$FIXTURE_DIR/node-pool-no-removal.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/node-pool-sizing.yml \
      'Reduce pool maximum without node removal' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Node-pool no-removal functional fixture could not be materialized"
        return
    fi

    local original_max=$FIXTURE_POOL_MAX original_count=$FIXTURE_POOL_COUNT
    FIXTURE_POOL_MAX=8 FIXTURE_POOL_COUNT=2 FIXTURE_POOL_SIZE=s-8vcpu-16gb
    FIXTURE_READY_NODES=2 FIXTURE_SCALE_DEMAND=2 FIXTURE_POOL_RACE_COUNT=2
    FIXTURE_SECOND_CLUSTER_ID=fixture-cluster FIXTURE_SECOND_POOL_ID=fixture-pool
    FIXTURE_SECOND_NODE_UID=fixture-node-a-uid
    FIXTURE_SECOND_HELM_GROUP=redducklabs-private-runners
    FIXTURE_SECOND_ASRS_GROUP=redducklabs-private-runners
    export FIXTURE_POOL_MAX FIXTURE_POOL_COUNT FIXTURE_POOL_SIZE FIXTURE_READY_NODES FIXTURE_SCALE_DEMAND FIXTURE_POOL_RACE_COUNT
    export FIXTURE_SECOND_CLUSTER_ID FIXTURE_SECOND_POOL_ID FIXTURE_SECOND_NODE_UID
    export FIXTURE_SECOND_HELM_GROUP FIXTURE_SECOND_ASRS_GROUP
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
      && grep -Eq '^doctl .*node-pool update .*--max-nodes 2' "$FIXTURE_DIR/mutations"; then
        pass "Node Pool Sizing changes only max_nodes for a safe 2/8 to 2/2 transition"
    else
        fail "Node Pool Sizing cannot perform the safe max8 transition"
    fi

    local scenario variable value
    while IFS='|' read -r scenario variable value; do
        FIXTURE_POOL_MAX=8 FIXTURE_POOL_COUNT=2 FIXTURE_POOL_SIZE=s-8vcpu-16gb
        FIXTURE_READY_NODES=2 FIXTURE_SCALE_DEMAND=2 FIXTURE_POOL_RACE_COUNT=2
        FIXTURE_SECOND_CLUSTER_ID=fixture-cluster FIXTURE_SECOND_POOL_ID=fixture-pool
        FIXTURE_SECOND_NODE_UID=fixture-node-a-uid
        FIXTURE_SECOND_HELM_GROUP=redducklabs-private-runners
        FIXTURE_SECOND_ASRS_GROUP=redducklabs-private-runners
        printf -v "$variable" '%s' "$value"
        export FIXTURE_POOL_MAX FIXTURE_POOL_COUNT FIXTURE_POOL_SIZE FIXTURE_READY_NODES FIXTURE_SCALE_DEMAND FIXTURE_POOL_RACE_COUNT
        export FIXTURE_SECOND_CLUSTER_ID FIXTURE_SECOND_POOL_ID FIXTURE_SECOND_NODE_UID
        export FIXTURE_SECOND_HELM_GROUP FIXTURE_SECOND_ASRS_GROUP
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Node Pool Sizing accepts unsafe ${scenario}"
        elif grep -q '^doctl .*node-pool update ' "$FIXTURE_DIR/mutations"; then
            fail "Node Pool Sizing mutates despite unsafe ${scenario}"
        else
            pass "Node Pool Sizing rejects unsafe ${scenario} before mutation"
        fi
    done <<'CASES'
count drift|FIXTURE_POOL_COUNT|3
NotReady node|FIXTURE_READY_NODES|1
ARC demand|FIXTURE_SCALE_DEMAND|3
pool size|FIXTURE_POOL_SIZE|s-16vcpu-32gb
pre-mutation count race|FIXTURE_POOL_RACE_COUNT|3
CASES

    while IFS='|' read -r scenario variable value; do
        FIXTURE_POOL_MAX=8 FIXTURE_POOL_COUNT=2 FIXTURE_POOL_SIZE=s-8vcpu-16gb
        FIXTURE_READY_NODES=2 FIXTURE_SCALE_DEMAND=2 FIXTURE_POOL_RACE_COUNT=2
        FIXTURE_SECOND_CLUSTER_ID=fixture-cluster FIXTURE_SECOND_POOL_ID=fixture-pool
        FIXTURE_SECOND_NODE_UID=fixture-node-a-uid
        FIXTURE_SECOND_HELM_GROUP=redducklabs-private-runners
        FIXTURE_SECOND_ASRS_GROUP=redducklabs-private-runners
        printf -v "$variable" '%s' "$value"
        export FIXTURE_POOL_MAX FIXTURE_POOL_COUNT FIXTURE_POOL_SIZE FIXTURE_READY_NODES FIXTURE_SCALE_DEMAND FIXTURE_POOL_RACE_COUNT
        export FIXTURE_SECOND_CLUSTER_ID FIXTURE_SECOND_POOL_ID FIXTURE_SECOND_NODE_UID
        export FIXTURE_SECOND_HELM_GROUP FIXTURE_SECOND_ASRS_GROUP
        : > "$FIXTURE_DIR/mutations"
        if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
            fail "Node Pool Sizing accepts ${scenario} between safety observations"
        elif grep -q '^doctl .*node-pool update ' "$FIXTURE_DIR/mutations"; then
            fail "Node Pool Sizing mutates despite ${scenario} between safety observations"
        else
            pass "Node Pool Sizing rejects ${scenario} between safety observations"
        fi
    done <<'CASES'
cluster identity drift|FIXTURE_SECOND_CLUSTER_ID|replacement-cluster
pool identity drift|FIXTURE_SECOND_POOL_ID|replacement-pool
node identity drift|FIXTURE_SECOND_NODE_UID|replacement-node-uid
Helm state drift|FIXTURE_SECOND_HELM_GROUP|foreign-runner-group
live ASRS state drift|FIXTURE_SECOND_ASRS_GROUP|foreign-runner-group
CASES
    FIXTURE_POOL_MAX=$original_max FIXTURE_POOL_COUNT=$original_count
    unset FIXTURE_SECOND_CLUSTER_ID FIXTURE_SECOND_POOL_ID FIXTURE_SECOND_NODE_UID
    unset FIXTURE_SECOND_HELM_GROUP FIXTURE_SECOND_ASRS_GROUP
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
    export FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE FIXTURE_MISSING_CRD
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
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
      && [ ! -s "$FIXTURE_DIR/mutations" ]; then
        pass "Deploy accepts a prepared and Ready platform when the chart-owned ServiceAccount is absent"
    else
        fail "Deploy rejects healthy prepared-platform prerequisites"
    fi

    local collision
    for collision in unmanaged foreign; do
        FIXTURE_SA_STATE=$collision
        export FIXTURE_SA_STATE
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
    export FIXTURE_SA_STATE
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output" \
      && [ ! -s "$FIXTURE_DIR/mutations" ]; then
        pass "Deploy accepts the chart ServiceAccount only with exact Helm ownership"
    else
        fail "Deploy rejects the correctly Helm-owned chart ServiceAccount"
    fi

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
    unset FIXTURE_SA_STATE FIXTURE_REGISTRY_STATE FIXTURE_MISSING_CRD
}

assert_shared_fleet_concurrency() {
    if python3 - <<'PY'
import yaml

paths = [
    '.github/workflows/deploy-runners.yml',
    '.github/workflows/scale-runners.yml',
    '.github/workflows/node-pool-sizing.yml',
    '.github/workflows/emergency-stop.yml',
    '.github/workflows/prepare-runner-platform.yml',
    '.github/workflows/deploy-cluster-addons.yml',
]
for path in paths:
    with open(path, encoding='utf-8') as stream:
        workflow = yaml.safe_load(stream)
    expected = {'group': 'runner-fleet-mutation', 'cancel-in-progress': False}
    if workflow.get('concurrency') != expected:
        raise SystemExit(f'{path} does not use the exact shared non-cancelling fleet concurrency group')
PY
    then
        pass "All runner-fleet mutation workflows share one non-cancelling concurrency group"
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

assert_rollback_recovery_route() {
    local script="$FIXTURE_DIR/rollback-recovery-route.sh"
    : > "$script"
    if ! materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Rollback runners' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script" \
      || ! materialize_workflow_step .github/workflows/deploy-runners.yml \
      'Verify trust and pool after rollback' "$FIXTURE_ACTUAL_SHA" 4 2 2 "$script"; then
        fail "Rollback recovery-route fixture could not be materialized"
        return
    fi

    FIXTURE_TRUST_FAILURE=true FIXTURE_READY_NODES=1
    export FIXTURE_TRUST_FAILURE FIXTURE_READY_NODES
    : > "$FIXTURE_DIR/mutations"
    if run_fixture "$script" "$FIXTURE_DIR/mutations" "$FIXTURE_DIR/output"; then
        fail "Rollback post-verification fixture unexpectedly succeeds"
    elif grep -q '^helm rollback ' "$FIXTURE_DIR/mutations"; then
        pass "Trust API and node-health failures occur only after Helm rollback"
    else
        fail "Trust API or node-health failure prevents Helm rollback"
    fi
    FIXTURE_TRUST_FAILURE=false FIXTURE_READY_NODES=2
    export FIXTURE_TRUST_FAILURE FIXTURE_READY_NODES
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
if "operation == 'rollback'" in str(trust.get('if', '')) or "operation != 'rollback'" not in str(trust.get('if', '')):
    raise SystemExit('trust reconciliation is not limited away from rollback')
rollback = deploy['jobs'].get('rollback')
if not rollback or rollback.get('needs') != 'validate-inputs':
    raise SystemExit('rollback must be a separate job needing only validated inputs')
if 'trust-boundary' in str(rollback.get('needs')):
    raise SystemExit('rollback depends on trust mutation')
rollback_steps = rollback.get('steps', [])
rollback_index = next(i for i, item in enumerate(rollback_steps) if item.get('name') == 'Rollback runners')
post_index = next(i for i, item in enumerate(rollback_steps) if item.get('name') == 'Verify trust and pool after rollback')
if rollback_index >= post_index:
    raise SystemExit('post-recovery checks precede Helm rollback')
before_rollback = '\n'.join(item.get('run', '') for item in rollback_steps[:rollback_index])
if any(token in before_rollback for token in
       ('verify-runner-trust-boundary.sh', 'get nodes', 'node-pool list')):
    raise SystemExit('trust or capacity health can block rollback')
deploy_job = deploy['jobs']['deploy']
if "operation == 'deploy'" not in str(deploy_job.get('if', '')):
    raise SystemExit('deployment job is not deploy-only')
steps = deploy_job['steps']
pre = next(i for i, item in enumerate(steps) if item.get('name') == 'Verify prepared platform prerequisites')
render = next(i for i, item in enumerate(steps) if item.get('name') == 'Render and preflight candidate')
if pre >= render:
    raise SystemExit('prepared-platform checks do not precede ASRS dry-run')
pre_shell = steps[pre]['run']
for token in ('get namespace', 'CRDS=(',
              'autoscalinglisteners.actions.github.com',
              'autoscalingrunnersets.actions.github.com',
              'ephemeralrunners.actions.github.com',
              'ephemeralrunnersets.actions.github.com',
              'meta.helm.sh/release-name', 'meta.helm.sh/release-namespace',
              'helm list -n arc-systems', 'gha-runner-scale-set-controller-',
              'readyReplicas', 'kubernetes.io/dockerconfigjson',
              'registry.digitalocean.com'):
    if token not in pre_shell:
        raise SystemExit(f'platform prerequisite missing: {token}')
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

assert_rejects_oversized_max 'Scale Runners' .github/workflows/scale-runners.yml 'Validate and sanitize inputs'
assert_rejects_oversized_max 'Deploy' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs'
assert_node_pool_bounds
assert_live_capacity_drift_fails
assert_scale_capacity_gate
assert_scale_workflow_static_contract

assert_sha_guarded_boundary 'Scale Runners' .github/workflows/scale-runners.yml 'Validate and sanitize inputs' 'helm upgrade' Helm '^helm upgrade .*gha-runner-scale-set'
FIXTURE_POOL_MAX=8
assert_sha_guarded_boundary 'Node Pool Sizing' .github/workflows/node-pool-sizing.yml 'Validate inputs against deploy/dind-values.yaml' 'node-pool update' doctl '^doctl kubernetes cluster node-pool update '
FIXTURE_POOL_MAX=2
printf '#!/usr/bin/env bash\ncat\n' > "$FIXTURE_DIR/runner-candidate-hash-gate.sh"
chmod 0700 "$FIXTURE_DIR/runner-candidate-hash-gate.sh"
assert_sha_guarded_boundary 'Deploy' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'helm upgrade --install "${RELEASE_NAME}"' Helm '^helm upgrade --install redducklabs-runners '
assert_sha_guarded_boundary 'Deploy runner-group REST' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'actions/runner-groups' 'GitHub runner-group REST mutation' '^(curl|gh) .*actions/runner-groups'
assert_sha_guarded_boundary 'Deploy rollback' .github/workflows/deploy-runners.yml 'Validate and sanitize inputs' 'helm rollback' 'Helm rollback' '^helm rollback '
assert_trust_boundary_fixtures
assert_autoscaler_diagnostic_fixtures
assert_deploy_operation_and_preflight_contract
assert_hostile_inputs_are_data
assert_deploy_requires_cotenancy_acceptance
assert_rollback_revision_prevalidation
assert_deploy_preflight_fixtures
assert_hostile_dispatch_inputs_are_data
assert_scale_output_record_injection_is_blocked
assert_rollout_quiesce_contract
assert_node_pool_no_removal_contract
assert_prepared_platform_prerequisites
assert_shared_fleet_concurrency
assert_platform_ownership_and_registry_generation
assert_rollback_recovery_route
assert_rollback_ignores_deploy_only_inputs
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
