# Security Update Validation Plan
## Red Duck Labs GitHub Actions Runners

**Date:** August 21, 2025  
**Update Type:** Critical Security Updates & Base Image Upgrade

## 🔍 Summary of Changes

### 1. Base Image Updates
- **Ubuntu Version:** Updated Docker CLI dependency from Ubuntu 22.04 to 24.04 LTS (noble)
- **Security Impact:** Latest LTS provides extended security support and updated base packages

### 2. Critical CVE Remediation

#### CVE-2025-8959: HashiCorp go-getter Symlink Attack Vulnerability
- **Status:** RESOLVED
- **Severity:** HIGH
- **Component:** Trivy security scanner
- **Fix:** Updated Trivy build process to compile from source with Go 1.24.6, ensuring go-getter v1.7.9+ with symlink attack mitigation

### 3. Tool Version Updates
- **Helm:** Updated to v3.18.6 (Security Update - fixes CVE-2025-55199 & CVE-2025-55198)
- **kubectl:** Updated to v1.33.3
- **doctl:** Updated to v1.139.0
- **Docker CLI:** Updated to v28.3.3+ (Security Update - fixes CVE-2025-54388)

### 4. Documentation & Testing Enhancements
- **Security Documentation:** Added comprehensive CVE tracking in `docs/SECURITY.md`
- **Testing Infrastructure:** Created security-focused validation scripts
- **Test Coverage:** Enhanced tool verification with version-specific checks

## 🧪 Validation Plan

### Phase 1: Pre-Deployment Validation

#### 1.1 Dockerfile Integrity Check ✅
```bash
# Syntax validation
docker buildx build -f docker/Dockerfile.custom-runner --check .
```
**Status:** PASSED - No warnings found

#### 1.2 Tool Version Alignment ✅
```bash
# Verify test scripts match Dockerfile versions
grep -n "3.18" docker/Dockerfile.custom-runner test/verify-tools.sh
```
**Status:** PASSED - Helm version aligned to 3.18.6

#### 1.3 Security Documentation Review ✅
- CVE-2025-8959 documented with remediation details
- References to security fixes included
- Verification procedures documented

### Phase 2: Build Validation

#### 2.1 Image Build Test
```bash
# Build test image
docker build -f docker/Dockerfile.custom-runner -t redducklabs/runner:security-test .
```
**Expected:** Successful build with all security updates

#### 2.2 Security Tool Functionality
```bash
# Test critical security tools in built image
docker run --rm redducklabs/runner:security-test trivy --version
docker run --rm redducklabs/runner:security-test kubesec version
docker run --rm redducklabs/runner:security-test helm version
```
**Expected:** All tools respond with correct versions

### Phase 3: Deployment Validation

#### 3.1 Runner Deployment Test
```bash
# Deploy updated runners
cd deploy && ./deploy.sh
```
**Expected:** Successful deployment with new image

#### 3.2 Tool Verification
```bash
# Run comprehensive tool verification
./test/verify-tools.sh
```
**Expected:** All 20+ tools verified successfully

#### 3.3 Security Fix Verification
```bash
# Run security-specific validation
./test/verify-security-fixes.sh
```
**Expected:** CVE-2025-8959 verification passes

### Phase 4: Production Validation

#### 4.1 Workflow Execution Test
- Run representative GitHub Actions workflow
- Verify security tools function in CI context
- Confirm no regression in runner functionality

#### 4.2 Security Scanning
```bash
# Scan deployed runner image
trivy image registry.digitalocean.com/redducklabs/github-runner:latest
```
**Expected:** No HIGH/CRITICAL vulnerabilities for fixed CVEs

#### 4.3 Runtime Security Check
- Verify container security contexts
- Confirm non-root user execution
- Test resource limits and constraints

## 🚦 Acceptance Criteria

### Must Pass ✅
- [ ] Dockerfile builds without errors or warnings
- [ ] All tool versions match expected values
- [ ] CVE-2025-8959 remediation verified
- [ ] Security documentation is complete and accurate
- [ ] Test scripts execute successfully

### Should Pass ⚠️
- [ ] No new HIGH/CRITICAL vulnerabilities introduced
- [ ] Performance impact is minimal
- [ ] All existing workflows continue to function
- [ ] Resource usage within expected limits

### Nice to Have 🎯
- [ ] Improved security scan scores
- [ ] Reduced attack surface
- [ ] Enhanced monitoring capabilities
- [ ] Better compliance posture

## 🔄 Rollback Plan

### If Critical Issues Found:
1. **Immediate:** Revert to previous runner image version
2. **Short-term:** Investigate and fix issues in development
3. **Long-term:** Re-deploy with fixes after validation

### Rollback Commands:
```bash
# Emergency rollback
kubectl set image deployment/runner-scale-set \
  runner=registry.digitalocean.com/redducklabs/github-runner:previous-stable \
  -n arc-runners

# Verify rollback
kubectl rollout status deployment/runner-scale-set -n arc-runners
```

## 📊 Success Metrics

### Security Metrics
- **CVE Count:** Zero HIGH/CRITICAL for addressed vulnerabilities
- **Scan Score:** Improved security posture score
- **Compliance:** Maintained or improved compliance ratings

### Operational Metrics
- **Build Time:** No significant increase in image build time
- **Deploy Time:** Deployment completes within normal timeframes
- **Resource Usage:** Memory/CPU usage within acceptable limits
- **Reliability:** No increase in runner failure rates

### Functional Metrics
- **Tool Coverage:** All 20+ tools verified and functional
- **Workflow Success:** Existing workflows execute successfully
- **Performance:** No degradation in workflow execution time

## 🔍 Post-Deployment Monitoring

### Week 1: Intensive Monitoring
- Daily security scans
- Workflow success rate monitoring
- Resource usage tracking
- Error rate analysis

### Ongoing: Regular Validation
- Weekly security scans
- Monthly tool verification
- Quarterly security review
- Continuous compliance monitoring

## 📞 Escalation Contacts

**Security Issues:**
- Primary: security@redducklabs.com
- Secondary: DevOps Team Lead

**Operational Issues:**
- Primary: DevOps Team
- Secondary: Infrastructure Team

---

**Note:** This validation plan ensures comprehensive verification of all security updates while maintaining operational stability and runner functionality.