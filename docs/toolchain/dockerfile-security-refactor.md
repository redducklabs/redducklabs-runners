# Dockerfile Security Refactor - Multi-Stage Build Implementation

## Current architecture (2026 toolchain refresh — authoritative)

> The 2026 toolchain refresh changed the tool-installation strategy. **This
> section is authoritative**; the historical sections below describe the earlier
> five-tool source-build approach and are retained for context only.

- **Release binaries (SHA256-pinned):** `kubectl`, `doctl`, `trivy`, `buildx`,
  plus Node.js, Helm, and uv install from official upstream release artifacts
  verified against a pinned SHA256 before install. This fixed the bogus
  `v0.0.0` / `0.0.0-dev` version strings the old source builds produced.
- **Source-built (Go 1.27.0) in a minimal `go-builder` stage:** `kubeconform`
  and `kubesec` only. Their upstream release binaries are built below this
  image's CVE floor (kubeconform Go 1.24.2; kubesec Go 1.23.1 + x/crypto
  v0.29.0), and both are at their latest release, so they are compiled with Go
  1.27.0 and kubesec's `golang.org/x/crypto` is bumped to v0.55.0. The builder's
  module cache lives only in the throwaway stage and never reaches the final
  image.
- **AWS CLI v2:** GPG-verified against a committed, fingerprint-pinned signing
  key with build-time expiry enforcement.
- **apt third-party repos:** installed via explicit keyrings whose full
  fingerprints are asserted before use (HashiCorp, Docker, GitHub CLI).
- **CVE-floor gate (`test/verify-cve-floor.sh`):** machine-enforced at build time
  and in CI — every Go tool toolchain ≥ Go 1.24.6, Trivy go-getter ≥ v1.7.9,
  kubesec x/crypto ≥ v0.35.0. Trivy's full HIGH/CRITICAL scan is **report-only**
  (upstream-binary and dind base-image fixed CVEs cannot be remediated here).
- **Go runtime:** a clean Go 1.27.0 stays in the final image for CI workflows.

Measured toolchains (2026-08-19 version refresh): kubectl go1.26.5, doctl
go1.25.0, kubeconform go1.27.0, kubesec go1.27.0 (x/crypto v0.55.0), trivy
go1.26.6 (go-getter v1.8.6), buildx go1.26.5.

Previously measured at adoption (2026-06-01): kubectl go1.26.2, doctl go1.25.0,
kubeconform go1.26.3, kubesec go1.26.3 (x/crypto v0.52.0), trivy go1.25.9
(go-getter v1.8.6), buildx go1.26.3.

## Overview (historical — superseded by the section above)

This document describes the comprehensive Dockerfile refactor implemented to eliminate false positive security alerts and optimize the image size for the redducklabs-runners project.

## Problem Analysis

### Original Issues
- **30+ False Positive Security Alerts**: Go dependency test fixtures containing certificates and private keys persisted in Docker layers
- **5 Separate Go Builds**: Each build created separate Docker layers with cached Go module artifacts
- **Layer Caching Problem**: Docker's layer caching preserved test certificates from Go dependencies in intermediate layers
- **Large Image Size**: Build artifacts and development dependencies inflated the final image
- **Slow Security Scans**: Trivy timeouts caused by excessive test fixture scanning

### Root Cause
The original single-stage Dockerfile performed 5 separate `RUN` commands for Go builds:
1. kubectl build
2. doctl build  
3. kubeconform build
4. kubesec build
5. trivy build

Each build created a separate Docker layer containing:
- Go module cache with test certificates
- Private keys from dependency test fixtures
- Build artifacts and temporary files
- Debug symbols and development dependencies

Even though cleanup was performed at the end, the intermediate layers retained these artifacts, causing persistent false positive security alerts.

## Solution: Multi-Stage Build Architecture

### Stage 1: Go Builder (`golang:1.24.6-alpine`)
```dockerfile
FROM golang:1.24.6-alpine AS go-builder
```

**Purpose**: Build all Go tools in a single, isolated environment with unified cache management.

**Key Features**:
- **Unified Build Process**: All 5 Go tools built in a single `RUN` command
- **Shared Go Cache**: Single `GOPATH` and `GOCACHE` for all builds
- **Aggressive Cleanup**: Remove all Go-related files in the same layer as builds
- **Binary Stripping**: Remove debug symbols to minimize binary size
- **Test Fixture Elimination**: Comprehensive removal of test certificates and private keys

### Stage 2: Python Builder (`python:3.13-slim`)
```dockerfile
FROM python:3.13-slim AS python-builder
```

**Purpose**: Install Python development tools in isolation.

**Key Features**:
- **Isolated Python Environment**: Separate from Go builds to prevent contamination
- **Target Installation**: Install to specific directory for clean copying
- **No Cache Pollution**: Install without leaving pip caches in final image

### Stage 3: Final Image (`ghcr.io/actions/actions-runner:latest`)
```dockerfile
FROM ghcr.io/actions/actions-runner:latest
```

**Purpose**: Create minimal runtime image with only necessary components.

**Key Features**:
- **Binary-Only Copying**: Copy only compiled binaries from builder stages
- **Runtime Dependencies**: Install only runtime packages, no build tools
- **Zero Build Artifacts**: No Go installation, modules, or development files
- **Comprehensive Cleanup**: Final cleanup to ensure minimal footprint

## Security Improvements

### 1. Elimination of False Positives

**Before**: 30+ security alerts from Go module test fixtures
**After**: Zero false positives from test certificates and private keys

**Implementation**:
```bash
# Aggressive cleanup in the same layer as builds
rm -rf /tmp/unified-go-build /tmp/unified-go-cache /go/pkg /root/.cache/go-build /usr/local/go
rm -rf /go/src /go/bin
find / -name "*.mod" -type f -delete 2>/dev/null || true
find / -name "*.sum" -type f -delete 2>/dev/null || true
find / -name "testdata" -type d -exec rm -rf {} + 2>/dev/null || true
find / -name "*_test.go" -type f -delete 2>/dev/null || true
```

### 2. .trivyignore Configuration

Created comprehensive `.trivyignore` file to prevent scanning of test fixtures:

```bash
# Go module test certificates and private keys
**/testdata/**
**/test/**
**/tests/**
**/*_test.go
**/*.test
**/fixtures/**
**/mock/**
**/mocks/**
```

### 3. Optimized Security Scanning

**Improvements**:
- Reduced timeout from 30m to 20m (faster scans)
- Added `.trivyignore` support to workflow
- Implemented verification steps for build artifacts removal
- Added security scan summary with vulnerability counts

## Performance Optimizations

### 1. Image Size Reduction

**Expected Results**:
- **60-80% size reduction** through multi-stage build
- **Eliminated build dependencies**: No Go installation in final image
- **Stripped binaries**: Removed debug symbols from all tools
- **Minimal runtime**: Only necessary packages in final image

### 2. Build Process Improvements

**Unified Go Builds**:
- **Single RUN command**: All Go tools built together
- **Shared cache**: Reduced redundant module downloads
- **Parallel processing**: More efficient resource utilization
- **Same-layer cleanup**: Prevents artifact persistence

### 3. Faster Security Scans

**Scan Optimizations**:
- **Reduced scan time**: Less content to analyze
- **Fewer false positives**: Targeted ignore rules
- **Timeout optimization**: 20m vs 30m
- **Better resource usage**: No test fixture scanning

## Verification Process

### 1. Build Verification

The updated workflow includes comprehensive verification:

```bash
# Verify Go installation is completely removed
docker run --rm image which go || echo "✅ Go binary not found (expected)"
docker run --rm image test ! -d /usr/local/go && echo "✅ Go installation removed"
docker run --rm image test ! -d /go && echo "✅ GOPATH removed"

# Verify no build artifacts remain
docker run --rm image find / -name "*.mod" -o -name "*.sum" -o -name "testdata" -type d | wc -l | grep -q "^0$"

# Verify all tools are functional
docker run --rm image kubectl version --client
docker run --rm image doctl version
docker run --rm image kubeconform -v
docker run --rm image kubesec version
docker run --rm image trivy --version
```

### 2. Security Verification

**Automated Checks**:
- **Vulnerability counting**: Track CRITICAL and HIGH severity issues
- **Build artifact verification**: Ensure complete cleanup
- **Tool functionality**: Confirm all tools work correctly
- **Size monitoring**: Track image size improvements

## Maintenance Benefits

### 1. Simplified Updates

**Tool Updates**: 
- All Go tools built with same Go version
- Unified dependency management
- Single security patch point

**Version Management**:
- Consistent Go version across all tools
- Easier CVE tracking and patching
- Simplified security audit process

### 2. Reduced False Positives

**Before**: Manual dismissal of 30+ false positive alerts
**After**: Zero false positives from test fixtures

**Benefits**:
- **Faster security reviews**: Focus on real vulnerabilities
- **Reduced maintenance overhead**: No false positive management
- **Better security visibility**: Clear signal-to-noise ratio

### 3. Improved CI/CD Performance

**Build Performance**:
- **Faster builds**: Unified caching and parallel processing
- **Faster scans**: Less content and targeted ignores
- **Reduced resource usage**: Smaller images and efficient processes

## Version Management and Security

### 1. Build Arguments for Version Control

**Security Enhancement**: All versions are now managed through build arguments to eliminate hardcoded versions:

```dockerfile
# Build arguments for version management (current values, 2026 refresh)
ARG GO_VERSION=1.27.0
ARG TRIVY_VERSION=v0.74.0
ARG KUBECTL_VERSION=v1.36.3
ARG DOCTL_VERSION=v1.167.0
ARG KUBECONFORM_VERSION=v0.8.0   # source-built
ARG KUBESEC_VERSION=v2.14.2      # source-built, x/crypto bumped
ARG KUBESEC_XCRYPTO_VERSION=v0.55.0
ARG HELM_VERSION=v3.21.4
ARG TERRAFORM_VERSION=1.15.9-1
ARG BUILDX_VERSION=v0.36.1
ARG UV_VERSION=0.12.5
ARG AWSCLI_VERSION=2.36.27
ARG PYTHON_FULL_VERSION=3.13.15
ARG NODE_VERSION=22.23.2          # nodejs.org tarball (NodeSource apt is stale)
ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:2.336.0
ARG PLAYWRIGHT_VERSION=1.60.0
```

Each downloaded release artifact also has a matching `*_SHA256` build argument
(`GO_SHA256`, `TRIVY_SHA256`, `KUBECTL_SHA256`, `DOCTL_SHA256`, `HELM_SHA256`,
`BUILDX_SHA256`, `UV_SHA256`, `NODE_SHA256`, `PYTHON_TARBALL_SHA256`).

**Benefits**:
- **Centralized version management**: All versions defined at the top of Dockerfile
- **Easy updates**: Change version in one place for each tool
- **Build-time customization**: Override versions without modifying Dockerfile
- **Audit trail**: Clear visibility of all component versions

### 2. SHA256 Checksum Verification

**Security Enhancement**: All downloaded binaries now include checksum verification:

```dockerfile
# Install Docker buildx (verified SHA256)
RUN set -eux && \
    cd /tmp && \
    wget -q "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" -O docker-buildx && \
    echo "${BUILDX_SHA256}  docker-buildx" | sha256sum -c - && \
    install -m 0755 docker-buildx /usr/local/bin/docker-buildx && \
    mkdir -p /usr/local/lib/docker/cli-plugins && \
    cp /usr/local/bin/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx && \
    rm -f /tmp/docker-buildx && \
    docker buildx version
```

**Security Benefits**:
- **Supply chain protection**: Prevents tampered or malicious binaries
- **Integrity verification**: Ensures downloaded files match expected content
- **Attack surface reduction**: Blocks potential download hijacking
- **Compliance requirement**: Meets security audit standards

**Checksum Update Procedure**:
1. **Obtain official checksums**: Download from GitHub releases page
2. **Verify integrity**: Use `gh` CLI to get checksums.txt file
3. **Update Dockerfile**: Replace checksum values with new releases
4. **Test verification**: Ensure checksum validation passes in build

Example checksum update workflow:
```bash
# Download official checksums
gh release download v0.27.0 --repo docker/buildx --pattern "checksums.txt"

# Find checksum for linux-amd64
grep "linux-amd64" checksums.txt

# Update the Dockerfile build argument with the new checksum value
ARG BUILDX_SHA256=<new_checksum_value>
```

### 3. Enhanced Error Handling

**Reliability Enhancement**: Build steps run with `set -eux`. Only kubeconform
and kubesec are still built from source, in the `go-builder` stage:

```bash
RUN set -eux && \
    mkdir -p /tmp/binaries && \
    git clone --depth 1 --branch ${KUBECONFORM_VERSION} https://github.com/yannh/kubeconform.git /tmp/kubeconform-src && \
    cd /tmp/kubeconform-src && \
    go build -ldflags="-w -s" -o /tmp/binaries/kubeconform ./cmd/kubeconform && \
    /tmp/binaries/kubeconform -v && \
    git clone --depth 1 --branch ${KUBESEC_VERSION} https://github.com/controlplaneio/kubesec.git /tmp/kubesec-src && \
    cd /tmp/kubesec-src && \
    go get "golang.org/x/crypto@${KUBESEC_XCRYPTO_VERSION}" && \
    go mod tidy && \
    go build -ldflags="-w -s -X github.com/controlplaneio/kubesec/v2/cmd.version=${KUBESEC_VERSION}" -o /tmp/binaries/kubesec . && \
    /tmp/binaries/kubesec version && \
    strip /tmp/binaries/kubeconform /tmp/binaries/kubesec
```

**Error Handling Features**:
- **Fail fast**: Exit immediately on any command failure (`set -e`)
- **Undefined variable detection**: Catch undefined variables (`set -u`)
- **Command tracing**: Each command is echoed to the build log (`set -x`)
- **Step validation**: Each binary is executed (`-v` / `version`) right after it is built or installed

### 4. Security-Focused .trivyignore Patterns

**Security Enhancement**: `.trivyignore` now contains only `CVE-2025-47907`
(container runtime tools in the actions-runner base image). The Go module-cache
path ignores (`/go/pkg/mod/**`, `/tmp/unified-go-build/**`) were deleted because
no build-stage artifacts reach the final image.

**Security Benefits**:
- **No path-based exclusions**: Every file in the final image is scanned
- **Reduced false negative risk**: No certificate/key patterns that could mask real findings

## Security Compliance

### 1. CVE Fixes Maintained

All current CVE fixes are enforced by the CVE-floor gate (measured 2026-08-19):
- **CVE-2025-47907**: every Go tool toolchain ≥ Go 1.24.6 (measured go1.25.0–1.27.0)
- **CVE-2025-22869 / CVE-2024-45337**: kubesec `x/crypto` v0.55.0 (≥ v0.35.0)
- **CVE-2025-8959**: Trivy `go-getter` v1.8.6 (≥ v1.7.9)
- **CVE-2025-54388**: Docker CLI ≥ v28.3.3 (smoke-enforced)
- **CVE-2025-55199 / CVE-2025-55198**: Helm 3.21.4

### 2. Build Security

**Secure Build Process**:
- **Mixed builds**: kubectl, doctl, trivy, and buildx are SHA256-verified release binaries; only kubeconform and kubesec are built from source (pinned git tags)
- **Latest dependencies**: Updated crypto and security packages
- **Isolated environments**: Multi-stage isolation prevents contamination
- **Verified binaries**: All tools tested for functionality with error handling
- **Version control**: Build arguments eliminate hardcoded versions
- **Supply chain security**: SHA256 checksums protect against tampering

## Rollback Plan

If issues arise, rollback is straightforward:

1. **Revert Dockerfile**: Use git to restore previous version
2. **Remove .trivyignore**: Delete file to restore original scanning
3. **Revert workflow**: Remove new verification steps
4. **Trigger rebuild**: Force rebuild with original configuration

## Monitoring and Alerting

### 1. Success Metrics

- **Zero false positive alerts** from Go test fixtures
- **Image size reduction** of 60-80%
- **Build time improvement** through unified process
- **Scan time reduction** from optimized content

### 2. Failure Indicators

- **Tool functionality failures**: Any Go binary not working
- **Unexpected vulnerabilities**: New CRITICAL/HIGH alerts
- **Build failures**: Multi-stage build process issues
- **Size increases**: Regression in image optimization

## Conclusion

This multi-stage Dockerfile refactor provides:

1. **Complete elimination** of false positive security alerts
2. **Significant image size reduction** (60-80% target)
3. **Improved security scanning** performance and accuracy
4. **Maintained functionality** of all existing tools
5. **Enhanced maintainability** with unified build process
6. **Better CI/CD performance** with optimized workflows

The implementation represents a comprehensive solution to the Docker layer caching security alert problem while providing substantial performance and maintainability improvements.
