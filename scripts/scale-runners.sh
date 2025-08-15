#!/bin/bash
# Scale GitHub Actions runners up or down
# Production version for redducklabs

set -e

# Configuration for redducklabs
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"
VALUES_FILE="../deploy/dind-values.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${BLUE}INFO:${NC} $1"; }
print_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
print_warning() { echo -e "${YELLOW}WARNING:${NC} $1"; }
print_error() { echo -e "${RED}ERROR:${NC} $1"; }

# Function to show usage
show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status          - Show current runner status"
    echo "  scale MIN MAX   - Scale runners (e.g., scale 2 4)"
    echo "  up              - Scale to default (2 min, 4 max)"
    echo "  down            - Scale to zero (maintenance mode)"
    echo "  max             - Scale to maximum capacity (4 min, 8 max)"
    echo "  get             - Get current scaling configuration"
    echo ""
    echo "Examples:"
    echo "  $0 status       # Check current status"
    echo "  $0 scale 3 6    # Scale to 3 min, 6 max"
    echo "  $0 down         # Scale to zero for maintenance"
    echo "  $0 up           # Restore default scaling"
    echo "  $0 max          # Maximum capacity"
    exit 1
}

# Function to check prerequisites
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        print_error "helm is not installed"
        exit 1
    fi
    
    if [ -z "$GITHUB_TOKEN" ]; then
        print_error "GITHUB_TOKEN environment variable is not set"
        echo "Please run: export GITHUB_TOKEN=your_token_here"
        exit 1
    fi
}

# Function to get current status
get_status() {
    print_info "Checking runner status for redducklabs..."
    echo ""
    
    # Get runner scale set status
    echo "Runner Scale Set Configuration:"
    kubectl get autoscalingrunnersets -n "$NAMESPACE" "$RELEASE_NAME" 2>/dev/null | tail -1 || echo "No runner scale set found"
    echo ""
    
    # Get current scaling values
    echo "Current Scaling:"
    local current_config=$(kubectl get autoscalingrunnersets -n "$NAMESPACE" "$RELEASE_NAME" -o json 2>/dev/null | jq '.spec | {minRunners: .minRunners, maxRunners: .maxRunners}' 2>/dev/null || echo "{}")
    if [ "$current_config" != "{}" ]; then
        echo "$current_config" | jq .
    else
        echo "Unable to retrieve scaling configuration"
    fi
    echo ""
    
    # Get pod status
    echo "Runner Pods:"
    kubectl get pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME" 2>/dev/null || echo "No runner pods found"
    echo ""
    
    # Get GitHub registration status
    echo "GitHub Registration:"
    local runner_count=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/redducklabs/actions/runners" | \
        jq '[.runners[] | select(.name | startswith("redducklabs-runners"))] | length')
    echo "Registered runners: $runner_count"
    
    # Show online/offline status
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/redducklabs/actions/runners" | \
        jq -r '.runners[] | select(.name | startswith("redducklabs-runners")) | "\(.name): \(.status)"' | head -10
}

# Function to scale runners
scale_runners() {
    local min_runners=$1
    local max_runners=$2
    
    if [ -z "$min_runners" ] || [ -z "$max_runners" ]; then
        print_error "Both MIN and MAX values are required"
        show_usage
    fi
    
    if [ "$min_runners" -gt "$max_runners" ]; then
        print_error "MIN ($min_runners) cannot be greater than MAX ($max_runners)"
        exit 1
    fi
    
    print_info "Scaling redducklabs runners to MIN=$min_runners, MAX=$max_runners..."
    
    helm upgrade "$RELEASE_NAME" \
        oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
        --namespace "$NAMESPACE" \
        --reuse-values \
        --set minRunners="$min_runners" \
        --set maxRunners="$max_runners" \
        --set githubConfigSecret.github_token="$GITHUB_TOKEN" \
        --wait --timeout 2m
    
    if [ $? -eq 0 ]; then
        print_success "Runners scaled successfully!"
        echo ""
        sleep 5
        get_status
    else
        print_error "Failed to scale runners"
        exit 1
    fi
}

# Function to scale down to zero
scale_down() {
    print_warning "Scaling redducklabs runners down to ZERO (maintenance mode)..."
    echo "This will stop all runners. Continue? (y/N)"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        scale_runners 0 0
        print_warning "Runners scaled to zero. Remember to scale up when maintenance is complete!"
    else
        print_info "Operation cancelled"
    fi
}

# Function to scale to default
scale_up() {
    print_info "Scaling redducklabs runners to default configuration (2 min, 4 max)..."
    scale_runners 2 4
}

# Function to scale to maximum
scale_max() {
    print_info "Scaling redducklabs runners to maximum capacity (4 min, 8 max)..."
    scale_runners 4 8
}

# Function to get current configuration
get_config() {
    print_info "Current redducklabs runner configuration:"
    helm get values "$RELEASE_NAME" -n "$NAMESPACE" | grep -E "minRunners|maxRunners" || echo "No configuration found"
}

# Main script logic
main() {
    check_prerequisites
    
    case "${1:-}" in
        status)
            get_status
            ;;
        scale)
            scale_runners "$2" "$3"
            ;;
        down)
            scale_down
            ;;
        up)
            scale_up
            ;;
        max)
            scale_max
            ;;
        get)
            get_config
            ;;
        *)
            show_usage
            ;;
    esac
}

# Run main function
main "$@"