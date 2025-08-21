# Test Scripts

This directory contains scripts for testing and verifying the Red Duck Labs GitHub Actions runners.

## Available Tests

### `verify-tools.sh`
Comprehensive verification of all tools installed in the runner image.

**Usage:**
```bash
./test/verify-tools.sh
```

**What it tests:**
- Programming languages (Python 3.13, Node.js 22)
- Package managers (npm, pnpm, pip)
- Infrastructure tools (Terraform, kubectl, Helm, doctl)
- Security tools (Trivy, kubesec, kubeconform)
- Development tools (Git, Docker CLI, GitHub CLI)
- Database clients (PostgreSQL, Redis)
- Python packages (black, flake8, mypy, ruff, pytest, requests, boto3, yaml)

### `verify-security-fixes.sh`
Security-focused verification to ensure known CVEs have been remediated.

**Usage:**
```bash
./test/verify-security-fixes.sh
```

**What it tests:**
- CVE-2025-8959: HashiCorp go-getter symlink attack vulnerability
- Trivy functionality after security updates
- Container image vulnerability scanning
- Security tool version verification

### `test-deployment.sh`
Tests the deployment process and runner functionality.

**Usage:**
```bash
./test/test-deployment.sh
```

## Prerequisites

Before running tests, ensure:

1. **Kubernetes cluster access:**
   ```bash
   kubectl config current-context
   kubectl get pods -n arc-runners
   ```

2. **Runners are deployed:**
   ```bash
   kubectl get pods -n arc-runners -l runner-scale-set-name=redducklabs-runners
   ```

3. **Required tools on local machine:**
   - kubectl
   - jq (for JSON parsing)

## Running All Tests

To run a complete verification:

```bash
# Test tools and functionality
./test/verify-tools.sh

# Test security fixes
./test/verify-security-fixes.sh

# Test deployment (if needed)
./test/test-deployment.sh
```

## Test Output

All tests use color-coded output:
- 🟢 **Green**: Test passed
- 🔴 **Red**: Test failed
- 🔵 **Blue**: Test description/info
- 🟡 **Yellow**: Warning/note

## Troubleshooting

### No runner pods found
```bash
# Check if runners are deployed
kubectl get pods -n arc-runners

# Check runner scale set
kubectl get pods -n arc-runners -l runner-scale-set-name=redducklabs-runners

# If no pods exist, deploy runners first
cd deploy && ./deploy.sh
```

### Tool version mismatches
The test scripts check for specific versions. If you've updated the Dockerfile with newer versions, update the corresponding test scripts.

### Security test failures
If security tests fail:
1. Check that the container image was built with the latest Dockerfile
2. Verify the image includes the security fixes
3. Rebuild and redeploy if necessary

## Adding New Tests

To add new tool verification:

1. Add to `verify-tools.sh`:
   ```bash
   test_tool "Tool Name Version" "command --version"
   ```

2. For security fixes, add to `verify-security-fixes.sh`:
   ```bash
   test_security_fix "CVE-ID" "Description" "test_command" "expected_result"
   ```

## Integration with CI/CD

These tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions workflow step
- name: Verify runners
  run: |
    ./test/verify-tools.sh
    ./test/verify-security-fixes.sh
```

For more information, see the main [SECURITY.md](../docs/SECURITY.md) documentation.