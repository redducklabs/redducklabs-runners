#!/bin/bash
# Scale GitHub Actions runners up or down
# Production version for redducklabs

set -e

# Configuration for redducklabs
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"
CLUSTER_NAME="${CLUSTER_NAME:-redducklabs-cluster}"
RUNNER_POOL_NAME="${RUNNER_POOL_NAME:-github-runners-pool-16g}"

# One runner pod is scheduled per node (runner 5Gi + dind 5Gi of memory requests
# exceed half of node allocatable), so concurrency is capped by the node pool's
# max_nodes as well as by maxRunners. Scaling maxRunners above max_nodes just
# leaves runners Pending. See docs/runbooks/node-pool-sizing.md.

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
    echo "  scale MIN MAX   - Scale runners (e.g., scale 2 8)"
    echo "  up              - Scale to default (2 min, 8 max)"
    echo "  down            - Scale to zero (maintenance mode)"
    echo "  max             - Scale to maximum warm capacity (4 min, 8 max)"
    echo "  get             - Get current scaling configuration"
    echo ""
    echo "Examples:"
    echo "  $0 status       # Check current status"
    echo "  $0 scale 3 6    # Scale to 3 min, 6 max"
    echo "  $0 down         # Scale to zero for maintenance"
    echo "  $0 up           # Restore default scaling"
    echo "  $0 max          # Maximum warm capacity"
    echo ""
    echo "NOTE: one runner pod runs per node, so MAX above the pool's max_nodes"
    echo "      leaves runners Pending, and MIN is billed continuously."
    echo "      Pool bounds: .github/workflows/node-pool-sizing.yml"
    echo "      Runbook:     docs/runbooks/node-pool-sizing.md"
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

    # One runner pod per node: warn if the pool cannot physically hold MAX
    # runners, or if MIN exceeds the warm node floor. Advisory only - doctl may
    # not be configured, and this script should still work without it.
    if command -v doctl &> /dev/null && command -v jq &> /dev/null; then
        local pool_json
        pool_json=$(doctl kubernetes cluster list -o json 2>/dev/null \
            | jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name==$n) | .id' 2>/dev/null \
            | xargs -r -I{} doctl kubernetes cluster node-pool list {} -o json 2>/dev/null \
            | jq -r --arg p "$RUNNER_POOL_NAME" '.[] | select(.name==$p)' 2>/dev/null)

        if [ -n "$pool_json" ]; then
            local pool_min pool_max
            pool_min=$(echo "$pool_json" | jq -r '.min_nodes')
            pool_max=$(echo "$pool_json" | jq -r '.max_nodes')

            if [[ "$pool_max" =~ ^[0-9]+$ ]] && [ "$max_runners" -gt "$pool_max" ]; then
                print_warning "MAX ($max_runners) exceeds pool max_nodes ($pool_max)."
                print_warning "Runners above $pool_max will stay Pending - resize the pool first"
                print_warning "with the 'Node Pool Sizing' workflow."
            fi
            if [[ "$pool_min" =~ ^[0-9]+$ ]] && [ "$min_runners" -gt "$pool_min" ]; then
                print_warning "MIN ($min_runners) exceeds pool min_nodes ($pool_min)."
                print_warning "Warm runners will wait on node provisioning until the pool scales up."
            fi
        fi
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
# Matches minRunners/maxRunners in deploy/dind-values.yaml.
scale_up() {
    print_info "Scaling redducklabs runners to default configuration (2 min, 8 max)..."
    scale_runners 2 8
}

# Function to scale to maximum warm capacity.
# NOTE: MIN is billed continuously - one node per warm runner. 4 warm runners
# means 4 nodes running around the clock. Use 'up' to return to the default.
scale_max() {
    print_info "Scaling redducklabs runners to maximum warm capacity (4 min, 8 max)..."
    print_warning "MIN=4 keeps 4 nodes running continuously. Run '$0 up' to revert."
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