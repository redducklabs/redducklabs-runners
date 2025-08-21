#!/bin/bash

# Script to verify Docker installation and CVE-2025-54388 fix
# This script validates that Docker CLI v28.3.3+ is installed

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================================"
echo -e "${YELLOW}Docker Security Verification - CVE-2025-54388 Fix${NC}"
echo "======================================================"
echo ""

# Function to check Docker version
check_docker_version() {
    echo -e "${YELLOW}Checking Docker CLI version...${NC}"
    
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}❌ Docker CLI not found${NC}"
        exit 1
    fi
    
    DOCKER_VERSION=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "Docker CLI version: $DOCKER_VERSION"
    
    # Convert version to comparable format (major.minor.patch)
    DOCKER_MAJOR=$(echo $DOCKER_VERSION | cut -d. -f1)
    DOCKER_MINOR=$(echo $DOCKER_VERSION | cut -d. -f2)
    DOCKER_PATCH=$(echo $DOCKER_VERSION | cut -d. -f3)
    
    # Check if version is 28.3.3 or higher
    if [[ $DOCKER_MAJOR -gt 28 ]] || \
       [[ $DOCKER_MAJOR -eq 28 && $DOCKER_MINOR -gt 3 ]] || \
       [[ $DOCKER_MAJOR -eq 28 && $DOCKER_MINOR -eq 3 && $DOCKER_PATCH -ge 3 ]]; then
        echo -e "${GREEN}✅ Docker CLI v$DOCKER_VERSION is secure (CVE-2025-54388 fixed)${NC}"
        return 0
    else
        echo -e "${RED}❌ Docker CLI v$DOCKER_VERSION is vulnerable to CVE-2025-54388${NC}"
        echo -e "${RED}   Required: v28.3.3 or higher${NC}"
        return 1
    fi
}

# Function to check docker-buildx
check_docker_buildx() {
    echo -e "${YELLOW}Checking docker-buildx installation...${NC}"
    
    if ! command -v docker-buildx &> /dev/null; then
        echo -e "${RED}❌ docker-buildx not found${NC}"
        return 1
    fi
    
    # Check if buildx is available as Docker plugin
    if docker buildx version &> /dev/null; then
        BUILDX_VERSION=$(docker buildx version | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo -e "${GREEN}✅ docker-buildx available: $BUILDX_VERSION${NC}"
        return 0
    else
        echo -e "${RED}❌ docker-buildx plugin not properly installed${NC}"
        return 1
    fi
}

# Function to verify Docker installation source
check_docker_source() {
    echo -e "${YELLOW}Verifying Docker installation source...${NC}"
    
    if dpkg -l | grep -q "docker-ce-cli"; then
        INSTALLED_VERSION=$(dpkg -l | grep docker-ce-cli | awk '{print $3}')
        echo -e "${GREEN}✅ Docker installed from official Docker repository: $INSTALLED_VERSION${NC}"
        return 0
    elif dpkg -l | grep -q "docker.io"; then
        INSTALLED_VERSION=$(dpkg -l | grep docker.io | awk '{print $3}')
        echo -e "${RED}❌ Docker installed from Ubuntu repository (vulnerable): $INSTALLED_VERSION${NC}"
        echo -e "${RED}   This version is vulnerable to CVE-2025-54388${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠️  Unable to determine Docker installation source${NC}"
        return 1
    fi
}

# Function to test Docker functionality
test_docker_functionality() {
    echo -e "${YELLOW}Testing basic Docker functionality...${NC}"
    
    if docker version --format '{{.Client.Version}}' &> /dev/null; then
        echo -e "${GREEN}✅ Docker CLI functioning correctly${NC}"
        return 0
    else
        echo -e "${RED}❌ Docker CLI not functioning properly${NC}"
        return 1
    fi
}

# Main execution
echo "Starting Docker security verification..."
echo ""

OVERALL_STATUS=0

check_docker_version || OVERALL_STATUS=1
echo ""

check_docker_buildx || OVERALL_STATUS=1
echo ""

check_docker_source || OVERALL_STATUS=1
echo ""

test_docker_functionality || OVERALL_STATUS=1
echo ""

echo "======================================================"
if [[ $OVERALL_STATUS -eq 0 ]]; then
    echo -e "${GREEN}🎉 All Docker security checks passed!${NC}"
    echo -e "${GREEN}   CVE-2025-54388 has been successfully addressed${NC}"
else
    echo -e "${RED}❌ Docker security verification failed${NC}"
    echo -e "${RED}   CVE-2025-54388 may still be present${NC}"
fi
echo "======================================================"

exit $OVERALL_STATUS