# Go Runtime Fix - Critical Functionality Restoration

> **Update (2026 toolchain refresh):** the clean Go runtime is now **Go 1.27.0**
> (was 1.24.6). The broad five-tool Go source-build stage was replaced by release
> binaries for kubectl/doctl/trivy/buildx; a **minimal** `go-builder` stage
> remains only to source-build kubeconform and kubesec (their release binaries
> are below the CVE floor). This document concerns the clean Go **runtime** in the
> final image; version numbers below are historical unless noted.

## Issue Summary

The Dockerfile refactor removed Go completely from the final image, breaking functionality for CI workflows that depend on Go being available. Line 213 in the original Dockerfile: `rm -rf /usr/local/go /go /root/.cache/go-build 2>/dev/null || true` eliminated the Go runtime entirely.

## Root Cause

The security refactor was designed to eliminate false positive security alerts from Go module test fixtures and cached dependencies, but it over-corrected by removing Go completely instead of distinguishing between:

1. **Build-time Go artifacts** (module cache, test fixtures) - Should be removed
2. **Runtime Go installation** (clean Go binary) - Should be preserved

## Solution Implemented

### 1. Clean Go Runtime Installation

The final stage installs the official Go release tarball at `ARG GO_VERSION`
(1.27.0 at the time of writing), verified against the pinned `ARG GO_SHA256`.
The same `GO_VERSION` selects the `golang:<version>-alpine` image of the
`go-builder` stage:

```dockerfile
# Install clean Go runtime for CI workflows (no module cache or test fixtures)
RUN set -eux && \
    GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz" && \
    cd /tmp && \
    wget -q "https://go.dev/dl/${GO_TARBALL}" && \
    echo "${GO_SHA256}  ${GO_TARBALL}" | sha256sum -c - && \
    tar -C /usr/local -xzf "${GO_TARBALL}" && \
    rm -f "${GO_TARBALL}" && \
    /usr/local/go/bin/go version
```

When bumping `GO_VERSION`, update `GO_SHA256` from the official
`go.dev/dl` checksum for `go<version>.linux-amd64.tar.gz`.

### 2. Proper Environment Variables

Set essential Go environment variables:

```dockerfile
ENV GOROOT=/usr/local/go
ENV GOPATH=/home/runner/go
ENV PATH=${GOROOT}/bin:${GOPATH}/bin:${PATH}
ENV GO111MODULE=on
ENV CGO_ENABLED=1
```

### 3. Clean Workspace Setup

Created a proper Go workspace for the runner user:

```dockerfile
# Ensure Go workspace is clean for runner user
mkdir -p /home/runner/go/{bin,src,pkg} && \
chown -R runner:runner /home/runner/go
```

### 4. Security Exclusions (historical)

The original fix added `/usr/local/go/**` and `/home/runner/go/**` path
exclusions to `.trivyignore`. Those exclusions have since been deleted:
`.trivyignore` now lists only the base-image CVE-2025-47907, so Trivy scans the
Go runtime and workspace like the rest of the image. The Trivy HIGH/CRITICAL
scan in CI is report-only; the enforcing gate is `test/verify-cve-floor.sh`.

## Key Distinctions

| Aspect | Build-time Go (not shipped) | Runtime Go (Preserved) |
|--------|------------------------|------------------------|
| **Location** | `go-builder` stage (`golang:<GO_VERSION>-alpine`: kubeconform/kubesec sources and module cache) | `/usr/local/go` |
| **Purpose** | Building kubeconform and kubesec | Runtime execution |
| **Contains** | Module cache and dependency sources | Official Go release tarball, SHA256-verified |
| **Reaches final image** | No: only the two binaries are copied | Yes |
| **Trivy Scanning** | Not in the image | Scanned (report-only) |

## Security Benefits Maintained

✅ **No cached Go modules** - the final image gets no module cache; `/home/runner/go` is created empty and owned by `runner`  
✅ **Verified download** - the Go tarball must match `GO_SHA256`  
✅ **No dependency build artifacts** - only the kubeconform and kubesec binaries leave the `go-builder` stage  
✅ **Multi-stage isolation** - Build artifacts isolated and cleaned  

## Functionality Restored

✅ **Go `GO_VERSION` available** - `go` command in PATH  
✅ **Environment variables set** - GOROOT, GOPATH, PATH configured  
✅ **Module support** - `go mod init`, `go mod tidy` working  
✅ **Compilation support** - `go build`, `go run` working  
✅ **Package management** - `go get`, `go install` working  
✅ **Runner user access** - Writable workspace in /home/runner/go  

## Verification

Run the verification script to confirm the fix. It is not run in CI, and it
starts a container from the local tag `redducklabs/custom-runner:latest`, so
build that tag first:

```bash
cd docker && docker build -t redducklabs/custom-runner:latest -f Dockerfile.custom-runner . && cd ..
bash test/verify-go-runtime.sh
```

The script tests:
- Go binary availability, and the Go version against a version written into
  the script (keep it equal to `ARG GO_VERSION`)
- Environment variable configuration
- Basic compilation functionality
- Module system functionality (`go mod init`)
- Workspace permissions
- That `/usr/local/go` contains no `testdata`, `*_test.go`, `*.pem` or `*.key`
  entries

## Impact

This fix resolves the critical regression where CI workflows requiring Go would fail with "command not found" errors, while maintaining all security improvements from the refactor.

## Testing Required

Before deploying:
1. Run `bash test/verify-go-runtime.sh` to confirm functionality
2. Run `./test/verify-cve-floor.sh <image-ref>` to confirm the CVE floor (CI
   also runs it on every image build)
3. Test a sample CI workflow that uses Go
4. Review the report-only Trivy scan from the image build

## Files Modified

Original fix:

1. `docker/Dockerfile.custom-runner` - Added clean Go runtime installation
2. `.trivyignore` - Added exclusions for clean Go installation (since removed)
3. `test/verify-go-runtime.sh` - Added verification script (new)
4. `docs/toolchain/go-runtime.md` - This documentation (new)