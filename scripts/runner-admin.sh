#!/bin/bash
# Interactive admin interface for GitHub Actions runners
# Production version for redducklabs

set -e

# Configuration for redducklabs
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

show_menu() {
    echo -e "${BLUE}Red Duck Labs - GitHub Actions Runner Administration${NC}"
    echo "================================================="
    echo "1) Show runner status"
    echo "2) Scale to default (2-4 runners)"
    echo "3) Scale to maximum (4-8 runners)"
    echo "4) Scale to zero (maintenance)"
    echo "5) Custom scaling"
    echo "6) Force restart all runners"
    echo "7) View runner logs"
    echo "8) Check failed pods"
    echo "9) Clean up terminated pods"
    echo "10) Show GitHub registration"
    echo "0) Exit"
    echo ""
    echo -n "Select option: "
}

check_status() {
    echo -e "${BLUE}Current Status:${NC}"
    kubectl get pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME"
    echo ""
    kubectl get autoscalingrunnersets -n "$NAMESPACE" "$RELEASE_NAME"
}

scale_default() {
    echo -e "${GREEN}Scaling to default (2-4 runners)...${NC}"
    ./scale-runners.sh up
}

scale_maximum() {
    echo -e "${GREEN}Scaling to maximum (4-8 runners)...${NC}"
    ./scale-runners.sh max
}

scale_zero() {
    echo -e "${YELLOW}Scaling to zero for maintenance...${NC}"
    ./scale-runners.sh down
}

custom_scale() {
    echo -n "Enter minimum runners: "
    read min
    echo -n "Enter maximum runners: "
    read max
    ./scale-runners.sh scale $min $max
}

restart_all() {
    echo -e "${YELLOW}Restarting all redducklabs runners...${NC}"
    echo "This will force restart all runner pods. Continue? (y/N)"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        kubectl delete pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME"
        echo "Pods deleted. New ones will be created automatically."
        sleep 5
        check_status
    else
        echo "Operation cancelled"
    fi
}

view_logs() {
    echo "Available runner pods:"
    kubectl get pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME" --no-headers | awk '{print NR") " $1 " (" $3 ")"}'
    echo -n "Enter number: "
    read num
    
    pod=$(kubectl get pods -n "$NAMESPACE" -l runner-scale-set-name="$RELEASE_NAME" --no-headers | awk "NR==$num {print \$1}")
    if [ -n "$pod" ]; then
        echo -e "${BLUE}Logs for $pod:${NC}"
        kubectl logs -n "$NAMESPACE" "$pod" -c runner --tail=100
    else
        echo -e "${RED}Invalid selection${NC}"
    fi
}

check_failed() {
    echo -e "${YELLOW}Checking for failed/stuck pods...${NC}"
    kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running,status.phase!=Succeeded
    echo ""
    echo "Checking GitHub registration status..."
    if [ ! -z "$GITHUB_TOKEN" ]; then
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/orgs/redducklabs/actions/runners" | \
            jq -r '.runners[] | select(.name | startswith("redducklabs-runners")) | "\(.name): \(.status)"'
    else
        echo "GITHUB_TOKEN not set - cannot check GitHub registration"
    fi
}

cleanup_pods() {
    echo -e "${YELLOW}Cleaning up terminated pods...${NC}"
    failed_count=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Failed --no-headers | wc -l)
    succeeded_count=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Succeeded --no-headers | wc -l)
    
    if [ "$failed_count" -gt 0 ] || [ "$succeeded_count" -gt 0 ]; then
        echo "Found $failed_count failed and $succeeded_count succeeded pods"
        kubectl delete pods -n "$NAMESPACE" --field-selector=status.phase=Failed 2>/dev/null || true
        kubectl delete pods -n "$NAMESPACE" --field-selector=status.phase=Succeeded 2>/dev/null || true
        echo "Cleanup complete"
    else
        echo "No terminated pods to clean up"
    fi
}

show_github_registration() {
    echo -e "${BLUE}GitHub Registration Status:${NC}"
    if [ -z "$GITHUB_TOKEN" ]; then
        echo -e "${RED}GITHUB_TOKEN not set${NC}"
        echo "Please run: export GITHUB_TOKEN=your_token_here"
    else
        echo "Fetching runner registration from GitHub..."
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/orgs/redducklabs/actions/runners" | \
            jq -r '.runners[] | select(.name | startswith("redducklabs-runners")) | "Name: \(.name) | Status: \(.status) | Busy: \(.busy)"'
    fi
}

# Prerequisites check
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl is not installed${NC}"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}ERROR: helm is not installed${NC}"
        exit 1
    fi
}

# Main loop
check_prerequisites
clear

while true; do
    show_menu
    read option
    
    case $option in
        1) check_status ;;
        2) scale_default ;;
        3) scale_maximum ;;
        4) scale_zero ;;
        5) custom_scale ;;
        6) restart_all ;;
        7) view_logs ;;
        8) check_failed ;;
        9) cleanup_pods ;;
        10) show_github_registration ;;
        0) echo "Exiting..."; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo ""
    echo "Press Enter to continue..."
    read
    clear
done