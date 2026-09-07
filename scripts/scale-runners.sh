#!/bin/bash
# Display GitHub Actions runner status without changing runner capacity.

set -euo pipefail

# Configuration for redducklabs
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-do-sfo3-redducklabs-cluster}"

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
    echo "Usage: $0 status"
    echo ""
    echo "This local helper is status-only. Use the reviewed GitHub Actions"
    echo "workflows for runner or node-pool configuration changes."
    exit 1
}

# Function to check prerequisites
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed"
        exit 1
    fi
    if ! command -v gh &> /dev/null; then
        print_error "gh is not installed"
        exit 1
    fi
    if ! gh auth status &> /dev/null; then
        print_error "GitHub CLI authentication is required to read runner status"
        exit 1
    fi
}

configure_context() {
    print_info "Verifying Kubernetes context..."
    kubectl config current-context
    kubectl config use-context "$CLUSTER_CONTEXT"
    kubectl config current-context
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
    local current_config
    current_config=$(kubectl get autoscalingrunnersets -n "$NAMESPACE" "$RELEASE_NAME" -o json 2>/dev/null | jq '.spec | {minRunners: .minRunners, maxRunners: .maxRunners}' 2>/dev/null || echo "{}")
    if [ "$current_config" != "{}" ]; then
        echo "$current_config" | jq .
    else
        echo "Unable to retrieve scaling configuration"
    fi
    echo ""
    
    # Get pod status
    echo "Runner Pods:"
    kubectl get pods -n "$NAMESPACE" -l actions.github.com/scale-set-name="$RELEASE_NAME" 2>/dev/null || echo "No runner pods found"
    echo ""
    
    # Get GitHub registration status
    echo "GitHub Registration:"
    gh api 'orgs/redducklabs/actions/runners' --paginate \
        --jq '[.runners[] | select(.name | startswith("redducklabs-runners"))] | length' \
        | xargs -I{} echo "Registered runners: {}"
    
    # Show online/offline status
    gh api 'orgs/redducklabs/actions/runners' --paginate \
        --jq '.runners[] | select(.name | startswith("redducklabs-runners")) | "\(.name): \(.status)"' \
        | head -10
}

# Main script logic
main() {
    if [ "${1:-}" != "status" ] || [ "$#" -ne 1 ]; then
        show_usage
    fi

    check_prerequisites
    configure_context
    get_status
}

# Run main function
main "$@"
