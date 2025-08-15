#!/bin/bash
# Verify all tools are installed in the redducklabs runners

set -e

echo "Verifying tools in redducklabs GitHub Actions runners..."
echo "====================================================="

# Get a runner pod
RUNNER_POD=$(kubectl get pods -n arc-runners -l runner-scale-set-name=redducklabs-runners --no-headers | head -1 | awk '{print $1}')

if [ -z "$RUNNER_POD" ]; then
    echo "Error: No redducklabs runner pods found!"
    echo "Make sure runners are deployed and running:"
    echo "  kubectl get pods -n arc-runners"
    exit 1
fi

echo "Testing pod: $RUNNER_POD"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

test_tool() {
    local tool_name="$1"
    local command="$2"
    
    echo -e "${BLUE}Testing $tool_name:${NC}"
    if kubectl exec -n arc-runners "$RUNNER_POD" -c runner -- bash -c "$command" 2>/dev/null; then
        echo -e "${GREEN}✓ $tool_name is working${NC}"
    else
        echo "✗ $tool_name failed"
        return 1
    fi
    echo ""
}

# Test each tool
test_tool "Python 3.13" "python3 --version"
test_tool "Node.js 22" "node --version"
test_tool "npm" "npm --version"
test_tool "pnpm" "pnpm --version"
test_tool "Terraform 1.12.2" "terraform version -json | jq -r .terraform_version"
test_tool "kubectl 1.33.0" "kubectl version --client -o json | jq -r .clientVersion.gitVersion"
test_tool "Helm 3.17.4" "helm version --short"
test_tool "doctl 1.138.0" "doctl version"
test_tool "Docker CLI" "docker --version"
test_tool "GitHub CLI" "gh --version | head -1"
test_tool "PostgreSQL client" "psql --version"
test_tool "Redis CLI" "redis-cli --version"
test_tool "Git" "git --version"
test_tool "curl" "curl --version | head -1"
test_tool "jq" "jq --version"

# Test Python packages
echo -e "${BLUE}Testing Python packages:${NC}"
kubectl exec -n arc-runners "$RUNNER_POD" -c runner -- python3 -c "
import black, flake8, mypy, ruff, pytest, requests, boto3, yaml
print('✓ All Python packages available')
"
echo ""

# Test security tools
test_tool "kubeconform 0.7.0" "kubeconform -v"
test_tool "kubesec 2.14.2" "kubesec version"
test_tool "Trivy 0.65.0" "trivy version | grep Version"

echo "====================================================="
echo -e "${GREEN}All tools verified successfully in redducklabs runners!${NC}"
echo ""
echo "Runner pod tested: $RUNNER_POD"
echo "Total tools verified: 20+"