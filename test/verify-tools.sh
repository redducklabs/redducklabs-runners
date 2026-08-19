#!/bin/bash
# Verify all tools are installed in the redducklabs runners

set -e

echo "Verifying tools in redducklabs GitHub Actions runners..."
echo "====================================================="

# Get a runner pod
RUNNER_POD=$(kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners --no-headers | head -1 | awk '{print $1}')

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
test_tool "Python 3.13.13" "python3 --version"
test_tool "Node.js 22.22.3" "node --version"
test_tool "npm" "npm --version"
test_tool "pnpm" "pnpm --version"
test_tool "uv" "uv --version"
test_tool "Terraform 1.15.5" "terraform version -json | jq -r .terraform_version"
test_tool "kubectl 1.36.1" "kubectl version --client -o json | jq -r .clientVersion.gitVersion"
test_tool "Helm 3.21.0" "helm version --short"
test_tool "doctl 1.160.1" "doctl version"
test_tool "AWS CLI" "aws --version"
test_tool "Docker CLI" "docker --version"
test_tool "Docker Compose" "docker compose version"
test_tool "GitHub CLI" "gh --version | head -1"
test_tool "PostgreSQL client" "psql --version"
test_tool "Redis CLI" "redis-cli --version"
test_tool "Git" "git --version"
test_tool "curl" "curl --version | head -1"
test_tool "jq" "jq --version"
test_tool "bc" "bc --version | head -1"

# Test Python packages
echo -e "${BLUE}Testing Python packages:${NC}"
kubectl exec -n arc-runners "$RUNNER_POD" -c runner -- python3 -c "
import black, flake8, mypy, ruff, pytest, pytest_mock, requests, boto3, yaml
print('✓ All Python packages available')
"
echo ""

# Test WeasyPrint native libraries (consumer CI jobs that import weasyprint load
# these shared objects via ctypes; without them import fails at collection).
echo -e "${BLUE}Testing WeasyPrint native libraries:${NC}"
kubectl exec -n arc-runners "$RUNNER_POD" -c runner -- python3 -c "
import ctypes
for so in ('libpango-1.0.so.0', 'libpangoft2-1.0.so.0', 'libharfbuzz.so.0', 'libfontconfig.so.1', 'libcairo.so.2', 'libffi.so.8'):
    ctypes.CDLL(so)
print('✓ WeasyPrint native libraries loadable')
"
echo ""

# Test Chromium runtime libraries (the consumer Playwright E2E job downloads the
# browser binary per-run but relies on these shared objects being baked into the
# image — the no-new-privileges fleet pod cannot apt-install them at job time).
echo -e "${BLUE}Testing Chromium runtime libraries:${NC}"
kubectl exec -n arc-runners "$RUNNER_POD" -c runner -- python3 -c "
import ctypes
for so in ('libnss3.so', 'libnspr4.so', 'libatk-1.0.so.0', 'libatk-bridge-2.0.so.0', 'libatspi.so.0', 'libcups.so.2', 'libdrm.so.2', 'libdbus-1.so.3', 'libxkbcommon.so.0', 'libxcb.so.1', 'libXcomposite.so.1', 'libXdamage.so.1', 'libXfixes.so.3', 'libXrandr.so.2', 'libgbm.so.1', 'libasound.so.2'):
    ctypes.CDLL(so)
print('✓ Chromium runtime libraries loadable')
"
echo ""

# Test security tools
test_tool "kubeconform 0.7.0" "kubeconform -v"
test_tool "kubesec 2.14.2" "kubesec version"
test_tool "Trivy 0.70.0" "trivy version | grep Version"

echo "====================================================="
echo -e "${GREEN}All tools verified successfully in redducklabs runners!${NC}"
echo ""
echo "Runner pod tested: $RUNNER_POD"
echo "Total tools verified: 20+"
echo ""
echo "For security verification, run:"
echo "  ./test/verify-security-fixes.sh"
