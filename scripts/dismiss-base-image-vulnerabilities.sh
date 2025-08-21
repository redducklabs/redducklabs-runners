#!/bin/bash
# Security Alert Dismissal Script
# 
# This script dismisses base image vulnerabilities that cannot be fixed
# without breaking GitHub Actions runner compatibility.
#
# Vulnerabilities covered:
# - CVE-2025-47907: Container runtime components (alerts 11,10,8,6,5,4,3)  
# - CVE-2024-21538: Node.js cross-spawn vulnerability (alert 2)
#
# See SECURITY-DISMISSALS.md for full risk assessment and justification.

set -e

# Configuration
REPO="redducklabs/redducklabs-runners"
BASE_COMMENT_CVE_47907="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."
BASE_COMMENT_CVE_21538="Risk accepted - Node.js runtime dependency from GitHub Actions runner base image (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking workflow compatibility. Workflow-level risk mitigated by runner isolation and ephemeral execution model. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Security Alert Dismissal Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: GitHub CLI (gh) is not installed or not in PATH${NC}"
    echo "Please install GitHub CLI: https://cli.github.com/"
    exit 1
fi

# Check if user is authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with GitHub CLI${NC}"
    echo "Please run: gh auth login"
    exit 1
fi

echo -e "${YELLOW}Repository:${NC} ${REPO}"
echo -e "${YELLOW}Documentation:${NC} SECURITY-DISMISSALS.md"
echo ""

# Confirmation prompt
echo -e "${YELLOW}Warning:${NC} This will dismiss 8 security alerts as 'Won't Fix'"
echo "These are base image vulnerabilities that cannot be remediated without"
echo "breaking GitHub Actions runner compatibility."
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 0
fi

echo ""

# Function to dismiss an alert
dismiss_alert() {
    local alert_id=$1
    local comment=$2
    local description=$3
    
    echo -e "${BLUE}Dismissing alert #${alert_id}:${NC} ${description}"
    
    if gh api repos/${REPO}/code-scanning/alerts/${alert_id} \
        --method PATCH \
        --field state=dismissed \
        --field dismissed_reason=won_t_fix \
        --field dismissed_comment="${comment}" \
        --silent; then
        echo -e "${GREEN}✓ Alert #${alert_id} dismissed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to dismiss alert #${alert_id}${NC}"
        return 1
    fi
    
    sleep 1  # Rate limiting courtesy
}

echo -e "${YELLOW}Phase 1: Dismissing CVE-2025-47907 alerts (container runtime components)${NC}"
echo ""

# CVE-2025-47907 alerts - Container runtime components
declare -A cve_47907_alerts=(
    ["11"]="CVE-2025-47907 in /usr/bin/runc"
    ["10"]="CVE-2025-47907 in /usr/bin/dockerd"
    ["8"]="CVE-2025-47907 in /usr/bin/docker-proxy"
    ["6"]="CVE-2025-47907 in /usr/bin/docker"
    ["5"]="CVE-2025-47907 in /usr/bin/ctr"
    ["4"]="CVE-2025-47907 in /usr/bin/containerd-shim-runc-v2"
    ["3"]="CVE-2025-47907 in /usr/bin/containerd"
)

failed_alerts=()

for alert_id in "${!cve_47907_alerts[@]}"; do
    if ! dismiss_alert "$alert_id" "$BASE_COMMENT_CVE_47907" "${cve_47907_alerts[$alert_id]}"; then
        failed_alerts+=("$alert_id")
    fi
done

echo ""
echo -e "${YELLOW}Phase 2: Dismissing CVE-2024-21538 alert (Node.js cross-spawn)${NC}"
echo ""

# CVE-2024-21538 alert - Node.js cross-spawn
if ! dismiss_alert "2" "$BASE_COMMENT_CVE_21538" "CVE-2024-21538 in /home/runner/externals/node20 (cross-spawn)"; then
    failed_alerts+=("2")
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Dismissal Summary${NC}"
echo -e "${BLUE}========================================${NC}"

if [ ${#failed_alerts[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All 8 security alerts dismissed successfully!${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "1. Review SECURITY-DISMISSALS.md for risk assessment details"
    echo "2. Ensure compensating controls are properly configured"
    echo "3. Schedule quarterly risk review"
    echo "4. Monitor for GitHub base image security updates"
    echo ""
    echo -e "${YELLOW}Quarterly Review Reminder:${NC}"
    echo "Next review scheduled for: $(date -d '+3 months' '+%B %Y')"
else
    echo -e "${RED}✗ Failed to dismiss ${#failed_alerts[@]} alert(s):${NC}"
    for alert_id in "${failed_alerts[@]}"; do
        echo -e "${RED}  - Alert #${alert_id}${NC}"
    done
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "1. Check GitHub CLI authentication: gh auth status"
    echo "2. Verify repository access permissions"
    echo "3. Check if alert IDs are still valid: gh api repos/${REPO}/code-scanning/alerts"
    echo "4. Retry individual alerts using manual commands in SECURITY-DISMISSALS.md"
    exit 1
fi

# Verification step
echo -e "${BLUE}Verification:${NC}"
echo "Checking dismissed alerts..."
echo ""

dismissed_count=$(gh api repos/${REPO}/code-scanning/alerts --jq '[.[] | select(.state == "dismissed")] | length' 2>/dev/null || echo "Unable to verify")

if [[ "$dismissed_count" =~ ^[0-9]+$ ]]; then
    echo -e "${GREEN}Current dismissed alerts in repository: ${dismissed_count}${NC}"
else
    echo -e "${YELLOW}Unable to verify dismissed alert count (API access issue)${NC}"
fi

echo ""
echo -e "${GREEN}Security alert dismissal process completed!${NC}"
echo ""
echo -e "${YELLOW}Important Reminders:${NC}"
echo "• These dismissals are based on informed risk acceptance"
echo "• Compensating security controls are documented and must remain active"  
echo "• Regular monitoring for GitHub base image updates is required"
echo "• Emergency procedures are available in scripts/emergency-stop.sh"
echo ""
echo -e "${BLUE}Documentation: ${NC}SECURITY-DISMISSALS.md"
echo -e "${BLUE}Security Guide: ${NC}docs/SECURITY.md"