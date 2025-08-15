#!/bin/bash
# Test redducklabs GitHub Actions runner deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}$1${NC}"
    echo "$(echo "$1" | sed 's/./=/g')"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

print_header "Testing redducklabs GitHub Actions Runner Deployment"

# Configuration
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"
EXPECTED_MIN_RUNNERS=2

echo ""
print_header "1. Prerequisites Check"

# Check kubectl
if command -v kubectl &> /dev/null; then
    print_success "kubectl is installed"
else
    print_error "kubectl is not installed"
    exit 1
fi

# Check helm
if command -v helm &> /dev/null; then
    print_success "helm is installed"
else
    print_error "helm is not installed"
    exit 1
fi

# Check GitHub token
if [ -z "$GITHUB_TOKEN" ]; then
    print_warning "GITHUB_TOKEN not set - GitHub API checks will be skipped"
else
    print_success "GITHUB_TOKEN is set"
fi

# Check cluster connection
if kubectl cluster-info &> /dev/null; then
    print_success "Connected to Kubernetes cluster"
    echo "  Cluster: $(kubectl config current-context)"
else
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

echo ""
print_header "2. Namespace and Release Check"

# Check namespace
if kubectl get namespace "$NAMESPACE" &> /dev/null; then
    print_success "Namespace '$NAMESPACE' exists"
else
    print_error "Namespace '$NAMESPACE' does not exist"
    exit 1
fi

# Check helm release
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
    print_success "Helm release '$RELEASE_NAME' is deployed"
    release_status=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r .info.status)
    echo "  Status: $release_status"
else
    print_error "Helm release '$RELEASE_NAME' not found"
    exit 1
fi

echo ""
print_header "3. Runner Scale Set Check"

# Check AutoScalingRunnerSet
if kubectl get autoscalingrunnersets "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
    print_success "AutoScalingRunnerSet '$RELEASE_NAME' exists"
    
    # Get scaling configuration
    scaling_config=$(kubectl get autoscalingrunnersets "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq '.spec | {minRunners: .minRunners, maxRunners: .maxRunners}')
    echo "  Scaling config: $scaling_config"
    
    min_runners=$(echo "$scaling_config" | jq -r .minRunners)
    max_runners=$(echo "$scaling_config" | jq -r .maxRunners)
    
    if [ "$min_runners" -ge "$EXPECTED_MIN_RUNNERS" ]; then
        print_success "Minimum runners ($min_runners) meets requirement (>= $EXPECTED_MIN_RUNNERS)"
    else
        print_warning "Minimum runners ($min_runners) below recommended ($EXPECTED_MIN_RUNNERS)"
    fi
else
    print_error "AutoScalingRunnerSet '$RELEASE_NAME' not found"
    exit 1
fi

echo ""
print_header "4. Pod Status Check"

# Get runner pods
pods=$(kubectl get pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME" --no-headers 2>/dev/null || true)

if [ -z "$pods" ]; then
    print_warning "No runner pods found - this might be normal if minRunners=0"
else
    pod_count=$(echo "$pods" | wc -l)
    print_success "Found $pod_count runner pod(s)"
    
    # Check pod status
    running_pods=$(echo "$pods" | grep -c "Running" || true)
    pending_pods=$(echo "$pods" | grep -c "Pending" || true)
    failed_pods=$(echo "$pods" | grep -c "Error\|CrashLoopBackOff\|ImagePullBackOff" || true)
    
    echo "  Running: $running_pods"
    echo "  Pending: $pending_pods"
    echo "  Failed: $failed_pods"
    
    if [ "$failed_pods" -gt 0 ]; then
        print_error "$failed_pods pod(s) in failed state"
        echo "Failed pods:"
        echo "$pods" | grep "Error\|CrashLoopBackOff\|ImagePullBackOff" || true
    fi
    
    # Test a running pod if available
    if [ "$running_pods" -gt 0 ]; then
        running_pod=$(echo "$pods" | grep "Running" | head -1 | awk '{print $1}')
        print_success "Testing tools in pod: $running_pod"
        
        # Quick tool test
        if kubectl exec -n "$NAMESPACE" "$running_pod" -c runner -- python3 --version &> /dev/null; then
            print_success "Python is working in runner"
        else
            print_error "Python test failed in runner"
        fi
        
        if kubectl exec -n "$NAMESPACE" "$running_pod" -c runner -- kubectl version --client &> /dev/null; then
            print_success "kubectl is working in runner"
        else
            print_error "kubectl test failed in runner"
        fi
    fi
fi

echo ""
print_header "5. GitHub Registration Check"

if [ ! -z "$GITHUB_TOKEN" ]; then
    github_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/redducklabs/actions/runners" 2>/dev/null || echo '{"runners":[]}')
    
    if echo "$github_response" | jq -e . &> /dev/null; then
        registered_runners=$(echo "$github_response" | jq '[.runners[] | select(.name | startswith("redducklabs-runners"))] | length')
        online_runners=$(echo "$github_response" | jq '[.runners[] | select(.name | startswith("redducklabs-runners")) | select(.status == "online")] | length')
        
        print_success "GitHub API accessible"
        echo "  Registered redducklabs runners: $registered_runners"
        echo "  Online runners: $online_runners"
        
        if [ "$online_runners" -gt 0 ]; then
            print_success "Runners are online and ready for jobs"
        else
            print_warning "No runners are currently online"
        fi
    else
        print_error "Failed to query GitHub API"
    fi
else
    print_warning "Skipping GitHub registration check (no token)"
fi

echo ""
print_header "6. Image and Security Check"

# Check if using custom image
image_info=$(kubectl get autoscalingrunnersets "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.template.spec.containers[0].image // "default"')
if [[ "$image_info" == *"redducklabs"* ]]; then
    print_success "Using custom redducklabs image: $image_info"
else
    print_warning "Not using custom redducklabs image: $image_info"
fi

# Check pull secrets
pull_secrets=$(kubectl get autoscalingrunnersets "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.spec.template.spec.imagePullSecrets[]?.name // "none"')
if [ "$pull_secrets" != "none" ]; then
    print_success "Image pull secrets configured: $pull_secrets"
else
    print_warning "No image pull secrets configured"
fi

echo ""
print_header "7. Resource Usage Check"

if [ "$pod_count" -gt 0 ]; then
    echo "Current resource usage:"
    kubectl top pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME" 2>/dev/null || print_warning "Metrics not available (metrics-server may not be installed)"
fi

echo ""
print_header "Deployment Test Summary"

if [ "$failed_pods" -eq 0 ] && [ "$min_runners" -ge 1 ]; then
    print_success "redducklabs GitHub Actions runner deployment is healthy!"
    echo ""
    echo "Next steps:"
    echo "  1. Test in a GitHub workflow with: runs-on: redducklabs-runners"
    echo "  2. Monitor with: ./scripts/scale-runners.sh status"
    echo "  3. Verify tools with: ./test/verify-tools.sh"
else
    print_warning "Deployment has some issues that may need attention"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check pod logs: kubectl logs -n $NAMESPACE <pod-name> -c runner"
    echo "  2. Check scaling: ./scripts/scale-runners.sh status"
    echo "  3. Emergency stop if needed: ./scripts/emergency-stop.sh"
fi