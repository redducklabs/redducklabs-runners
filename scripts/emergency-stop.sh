#!/bin/bash
# Emergency stop script for redducklabs GitHub Actions runners
# Use this when runners are misbehaving or consuming too many resources

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}EMERGENCY RUNNER SHUTDOWN - RED DUCK LABS${NC}"
echo "=========================================="
echo ""
echo -e "${YELLOW}This will immediately stop ALL redducklabs GitHub Actions runners!${NC}"
echo "Use this only in emergency situations."
echo ""
echo "This script will:"
echo "1. Scale runners to zero"
echo "2. Force delete all runner pods"
echo "3. Cancel any stuck jobs"
echo ""
echo -e "${RED}Are you sure? Type 'STOP' to confirm:${NC} "
read -r confirmation

if [ "$confirmation" != "STOP" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo -e "${YELLOW}Emergency stop initiated for redducklabs runners...${NC}"

# Check for GitHub token
if [ -z "$GITHUB_TOKEN" ]; then
    echo -e "${YELLOW}Warning: GITHUB_TOKEN not set. Cannot check GitHub job status.${NC}"
fi

# Stop fence (Ruling 33): the marker is written before the Helm write, so any
# fleet workflow Helm write that lands after this stop re-applies 0/0 and fails.
echo "0. Writing the Emergency Stop marker arc-runners/runner-fleet-emergency-stop..."
if ! jq -n --arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{
        apiVersion: "v1", kind: "ConfigMap",
        metadata: {name: "runner-fleet-emergency-stop", namespace: "arc-runners",
                   labels: {"app.kubernetes.io/managed-by": "redducklabs-emergency-stop"}},
        data: {"run-id": "local-script", time: $time}}' \
    | kubectl apply --server-side --force-conflicts --field-manager=redducklabs-emergency-stop -f -; then
    echo -e "${RED}Could not write the stop marker; continuing with the stop. An in-flight fleet workflow could reopen runners: dispatch the Emergency Stop workflow too.${NC}"
    MARKER_FAILED=true
fi

# Server-side fence (Ruling 36): before the Helm write, prove the API server
# denies non-zero runner writes while the marker exists (a dry-run patch to
# maxRunners=1 must be denied, retried for up to 30 s). Never blocks the stop.
FENCE_OK=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/fleet-ops.sh disable=SC1091
if [ "${MARKER_FAILED:-false}" != true ] \
    && (cd "$REPO_DIR" && python3 -B scripts/lib/runner_stop_fence.py verify) \
    && (cd "$REPO_DIR" && source scripts/lib/fleet-ops.sh && fleet_fence_wait denied); then
    FENCE_OK=true
fi

# Scale to zero
echo "1. Scaling redducklabs runner scale set to zero..."
helm upgrade redducklabs-runners \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --namespace arc-runners \
    --version 0.14.2 \
    --reuse-values \
    --set minRunners=0 \
    --set maxRunners=0 \
    --history-max 100 \
    --set githubConfigSecret.github_token="${GITHUB_TOKEN:-dummy}" \
    --wait --timeout 1m 2>/dev/null || true

# Force delete all runner pods
echo "2. Force deleting all redducklabs runner pods..."
kubectl delete pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners --force --grace-period=0 2>/dev/null || true

# Check if any pods remain
echo "3. Checking for remaining pods..."
remaining=$(kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners --no-headers 2>/dev/null | wc -l)

if [ "$remaining" -gt 0 ]; then
    echo -e "${YELLOW}Warning: $remaining pods still terminating${NC}"
    echo "Waiting for termination to complete..."
    sleep 10
    remaining=$(kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners --no-headers 2>/dev/null | wc -l)
    if [ "$remaining" -gt 0 ]; then
        echo -e "${YELLOW}$remaining pods still terminating - they will finish shortly${NC}"
    fi
else
    echo -e "${GREEN}All redducklabs runner pods stopped${NC}"
fi

# Show GitHub status if token available
if [ ! -z "$GITHUB_TOKEN" ]; then
    echo "4. Checking GitHub runner status..."
    active_runners=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/redducklabs/actions/runners" | \
        jq '[.runners[] | select(.name | startswith("redducklabs-runners")) | select(.status == "online")] | length')
    echo "Active runners on GitHub: $active_runners"
fi

echo ""
echo -e "${GREEN}Emergency stop complete for redducklabs runners!${NC}"
echo ""
echo "The release is now in a stopped state (its base template at 0/0). Restore"
echo "runners only through the reviewed GitHub Actions workflows, as described in"
echo "docs/runbooks/node-pool-sizing.md (\"Emergency Stop\"):"
echo "While the stop marker exists every fleet workflow refuses to run except"
echo "Deploy deploy/rollback with acknowledge_emergency_stop=true (and remove-burst):"
echo "  burst-stopped:   Deploy GitHub Runners operation=deploy acknowledge_emergency_stop=true"
echo "  drain-stopped:   Node Pool Sizing remove-burst, then Deploy operation=rollback acknowledge_emergency_stop=true"
echo "  density-stopped: Deploy GitHub Runners operation=rollback acknowledge_emergency_stop=true"
echo ""
if [ "$FENCE_OK" != true ]; then
    echo -e "${RED}The stop was applied, but the server-side fence (deploy/runner-emergency-stop-fence.yaml) did not prove it enforces it: a stale fleet run could still reopen runners. Dispatch the Emergency Stop workflow after Deploy has installed the fence.${NC}"
fi
echo -e "${YELLOW}Remember to investigate what caused the emergency before restarting.${NC}"
echo ""
echo "Common investigation commands:"
echo "  kubectl describe pods -n arc-runners"
echo "  kubectl logs -n arc-systems -l app.kubernetes.io/name=controller"
echo "  ./scale-runners.sh status"
# The run ends red when the fence was not proven (the stop itself was applied).
[ "$FENCE_OK" = true ] || exit 1
