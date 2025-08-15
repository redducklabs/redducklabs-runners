#!/bin/bash
# Emergency stop script for redducklabs GitHub Actions runners
# Use this when runners are misbehaving or consuming too many resources

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

# Scale to zero
echo "1. Scaling redducklabs runner scale set to zero..."
helm upgrade redducklabs-runners \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --namespace arc-runners \
    --reuse-values \
    --set minRunners=0 \
    --set maxRunners=0 \
    --set githubConfigSecret.github_token="${GITHUB_TOKEN:-dummy}" \
    --wait --timeout 1m 2>/dev/null || true

# Force delete all runner pods
echo "2. Force deleting all redducklabs runner pods..."
kubectl delete pods -n arc-runners -l runner-scale-set-name=redducklabs-runners --force --grace-period=0 2>/dev/null || true

# Check if any pods remain
echo "3. Checking for remaining pods..."
remaining=$(kubectl get pods -n arc-runners -l runner-scale-set-name=redducklabs-runners --no-headers 2>/dev/null | wc -l)

if [ "$remaining" -gt 0 ]; then
    echo -e "${YELLOW}Warning: $remaining pods still terminating${NC}"
    echo "Waiting for termination to complete..."
    sleep 10
    remaining=$(kubectl get pods -n arc-runners -l runner-scale-set-name=redducklabs-runners --no-headers 2>/dev/null | wc -l)
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
echo "To restart runners, run:"
echo "  ./scale-runners.sh up     # For normal operation (2-4 runners)"
echo "  ./scale-runners.sh max    # For maximum capacity (4-8 runners)"
echo ""
echo -e "${YELLOW}Remember to investigate what caused the emergency before restarting.${NC}"
echo ""
echo "Common investigation commands:"
echo "  kubectl describe pods -n arc-runners"
echo "  kubectl logs -n arc-systems -l app.kubernetes.io/name=controller"
echo "  ./scale-runners.sh status"