#!/bin/bash

# Verify the runner pod's memory reservations survive a chart render.
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

# Node budget for github-runners-pool-16g (s-8vcpu-16gb).
NODE_ALLOCATABLE_MI=13639     # 13967028Ki
SYSTEM_OVERHEAD_MI=694        # cilium, kube-proxy, csi, do-node-agent

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

mem_of() {  # container_name, list_path, field (requests|limits)
    printf '%s' "$SPEC_JSON" | jq -r \
        --arg n "$1" --arg f "$3" \
        ".spec.template.spec.$2[]? | select(.name==\$n) | .resources[\$f].memory // \"\""
}

DIND_REQ=$(mem_of dind initContainers requests)
DIND_LIM=$(mem_of dind initContainers limits)
RUNNER_REQ=$(mem_of runner containers requests)
RUNNER_LIM=$(mem_of runner containers limits)

[ -n "$DIND_REQ" ] && pass "dind memory request:   $DIND_REQ" \
                  || fail "dind has NO memory request - Docker builds will contend for unreserved node memory"
[ -n "$DIND_LIM" ] && pass "dind memory limit:     $DIND_LIM" \
                  || fail "dind has NO memory limit - a runaway Docker build can take down the node"
[ -n "$RUNNER_REQ" ] && pass "runner memory request: $RUNNER_REQ" \
                    || fail "runner has NO memory request"
[ -n "$RUNNER_LIM" ] && pass "runner memory limit:   $RUNNER_LIM" \
                    || fail "runner has NO memory limit"

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

# --- One pod per node --------------------------------------------------------
info "Checking the one-pod-per-node invariant..."

to_mi() {  # accepts Gi / Mi
    case "$1" in
        *Gi) python -c "print(int(float('${1%Gi}') * 1024))" ;;
        *Mi) python -c "print(int(float('${1%Mi}')))" ;;
        *)   echo 0 ;;
    esac
}

REQ_TOTAL_MI=$(( $(to_mi "$DIND_REQ") + $(to_mi "$RUNNER_REQ") ))
BUDGET_MI=$(( NODE_ALLOCATABLE_MI - SYSTEM_OVERHEAD_MI ))
HALF_ALLOCATABLE_MI=$(( NODE_ALLOCATABLE_MI / 2 ))

echo "  pod memory requests:  ${REQ_TOTAL_MI}Mi"
echo "  node allocatable:     ${NODE_ALLOCATABLE_MI}Mi"
echo "  usable after system:  ${BUDGET_MI}Mi"

if [ "$REQ_TOTAL_MI" -gt "$HALF_ALLOCATABLE_MI" ]; then
    pass "Requests exceed half of allocatable - exactly one runner pod per node"
else
    fail "Requests (${REQ_TOTAL_MI}Mi) allow two pods per node (half = ${HALF_ALLOCATABLE_MI}Mi)"
    echo "   Two runner pods on a node reintroduces Docker-build contention."
fi

if [ "$REQ_TOTAL_MI" -le "$BUDGET_MI" ]; then
    pass "Requests fit within the node budget (${REQ_TOTAL_MI}Mi <= ${BUDGET_MI}Mi)"
else
    fail "Requests (${REQ_TOTAL_MI}Mi) exceed the node budget (${BUDGET_MI}Mi) - pods will not schedule"
fi
echo ""

# --- Scale set vs pool coupling ---------------------------------------------
info "Checking scale set bounds..."
MAXR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.maxRunners // 0')
MINR=$(printf '%s' "$SPEC_JSON" | jq -r '.spec.minRunners // 0')
echo "  minRunners=${MINR} maxRunners=${MAXR}"
echo "  -> node pool must allow min_nodes >= ${MINR} and max_nodes >= ${MAXR}"
echo "     (one runner pod per node; see docs/runbooks/node-pool-sizing.md)"
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
