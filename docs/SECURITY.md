# Security Guide - Red Duck Labs GitHub Actions Runners

This document outlines security best practices and guidelines for the Red Duck Labs GitHub Actions self-hosted runners.

## 🔒 Core Security Principles

### 1. Principle of Least Privilege
- Runners have minimal permissions required for their function
- Service accounts are scoped to specific namespaces
- Container registry access is limited to pull operations only

### 2. Defense in Depth
- Multiple layers of security controls
- Network policies restrict communication
- Resource limits prevent resource exhaustion
- Image scanning for vulnerabilities

### 3. Zero Trust Architecture
- All network traffic is considered untrusted
- Authentication and authorization at every layer
- Continuous monitoring and validation

## 🔐 Authentication & Authorization

### GitHub Token Security

**Requirements:**
- Use Personal Access Tokens (PAT) with minimal required scopes
- Rotate tokens regularly (recommended: every 90 days)
- Store tokens in Kubernetes secrets, never in code

**Required Scopes:**
```
admin:org    # For organization-level runners
repo         # For repository access
workflow     # For workflow management
```

**Token Storage:**
```bash
# Store in Kubernetes secret
kubectl create secret generic github-token \
  --from-literal=token=$GITHUB_TOKEN \
  --namespace=arc-runners

# Reference in Helm values
githubConfigSecret:
  github_token: ""  # Provided via --set flag
```

### Container Registry Security

**DigitalOcean Registry:**
- Use dedicated registry tokens, not personal tokens
- Configure pull secrets for private images
- Regular credential rotation

```bash
# Create registry pull secret
kubectl create secret docker-registry do-registry-secret \
  --docker-server=registry.digitalocean.com \
  --docker-username=$DO_REGISTRY_TOKEN \
  --docker-password=$DO_REGISTRY_TOKEN \
  --namespace=arc-runners
```

### Kubernetes RBAC

**Service Account Configuration:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: runner-sa
  namespace: arc-runners
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: runner-role
  namespace: arc-runners
rules:
- apiGroups: [""]
  resources: ["pods", "secrets"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]  # Required for debugging only
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: runner-binding
  namespace: arc-runners
subjects:
- kind: ServiceAccount
  name: runner-sa
  namespace: arc-runners
roleRef:
  kind: Role
  name: runner-role
  apiGroup: rbac.authorization.k8s.io
```

## 🌐 Network Security

### Network Policies

**Egress Control:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: runner-network-policy
  namespace: arc-runners
spec:
  podSelector:
    matchLabels:
      runner-scale-set-name: redducklabs-runners
  policyTypes:
  - Egress
  egress:
  # Allow GitHub API access
  - to: []
    ports:
    - protocol: TCP
      port: 443  # HTTPS
    - protocol: TCP
      port: 80   # HTTP (for redirects)
  # Allow DNS
  - to: []
    ports:
    - protocol: UDP
      port: 53
```

**Ingress Restrictions:**
```yaml
# No ingress required for runners
spec:
  policyTypes:
  - Ingress
  ingress: []  # Deny all ingress
```

### Container Network Security

- Containers run in isolated network namespaces
- Docker-in-Docker uses secure configuration
- No privileged containers unless absolutely necessary

## 🐳 Container Security

### Image Security

**Base Image:**
- Use official GitHub runner images as base
- Regular updates to base images
- Vulnerability scanning with Trivy

**Custom Image Security:**
```dockerfile
# Run as non-root user
USER runner

# Remove unnecessary packages
RUN apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/*

# Set secure permissions
RUN chmod 755 /usr/local/bin/*
```

**Image Scanning:**
```bash
# Automated scanning in CI/CD
trivy image registry.digitalocean.com/redducklabs/github-runner:latest
```

### Runtime Security

**Security Context:**
```yaml
template:
  spec:
    securityContext:
      runAsNonRoot: true
      runAsUser: 1001
      fsGroup: 1001
    containers:
    - name: runner
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false  # Required for runner operation
        runAsNonRoot: true
        capabilities:
          drop:
          - ALL
```

**Resource Limits:**
```yaml
resources:
  limits:
    cpu: "2"
    memory: "4Gi"
    ephemeral-storage: "10Gi"
  requests:
    cpu: "500m"
    memory: "1Gi"
```

## 🔍 Monitoring & Auditing

### Security Monitoring

**Log Collection:**
- Kubernetes audit logs
- Container runtime logs
- GitHub webhook logs
- Runner execution logs

**Key Metrics to Monitor:**
- Failed authentication attempts
- Unusual resource usage
- Network policy violations
- Image pull failures

**Alerting Rules:**
```yaml
# Example Prometheus alert
groups:
- name: runner-security
  rules:
  - alert: RunnerHighCPUUsage
    expr: rate(container_cpu_usage_seconds_total{pod=~".*runner.*"}[5m]) > 0.8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Runner using high CPU"
```

### Audit Logging

**Enable Kubernetes Audit:**
```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  namespaces: ["arc-runners"]
  resources:
  - group: ""
    resources: ["pods", "secrets"]
```

**GitHub Audit:**
- Monitor runner registration/deregistration
- Track workflow execution
- Review access patterns

## 🚨 Incident Response

### Security Incident Procedures

**1. Immediate Response:**
```bash
# Emergency stop all runners
./scripts/emergency-stop.sh

# Isolate affected pods
kubectl label pod <pod-name> security=isolated -n arc-runners
```

**2. Investigation:**
```bash
# Collect logs
kubectl logs <pod-name> -n arc-runners -c runner > incident-logs.txt

# Check events
kubectl get events -n arc-runners --sort-by='.lastTimestamp'

# Review audit logs
grep "arc-runners" /var/log/kubernetes/audit.log
```

**3. Recovery:**
```bash
# Rotate tokens
# Update GitHub token
export NEW_GITHUB_TOKEN=ghp_new_token

# Update registry credentials
kubectl delete secret do-registry-secret -n arc-runners
kubectl create secret docker-registry do-registry-secret \
  --docker-server=registry.digitalocean.com \
  --docker-username=$NEW_DO_TOKEN \
  --docker-password=$NEW_DO_TOKEN \
  --namespace=arc-runners

# Redeploy with new credentials
cd deploy && ./deploy.sh
```

### Common Security Incidents

**1. Token Compromise:**
- Immediately revoke the token in GitHub
- Generate new token with minimal scopes
- Update Kubernetes secrets
- Monitor for unauthorized usage

**2. Container Escape:**
- Isolate affected nodes
- Preserve evidence
- Update security policies
- Review container configurations

**3. Resource Exhaustion:**
- Identify source of high resource usage
- Implement stricter resource limits
- Scale down if necessary
- Review resource monitoring

## 🔧 Security Hardening

### System Hardening

**Node Security:**
- Keep nodes updated
- Use minimal OS distributions
- Disable unnecessary services
- Enable SELinux/AppArmor

**Kubernetes Hardening:**
- Enable admission controllers
- Use Pod Security Standards
- Regular security updates
- Network policy enforcement

### Application Hardening

**Runner Configuration:**
```yaml
# Disable unnecessary features
template:
  spec:
    containers:
    - name: runner
      env:
      - name: RUNNER_ALLOW_RUNASROOT
        value: "false"
      - name: DISABLE_RUNNER_UPDATE
        value: "true"
```

**Workflow Security:**
```yaml
# Example secure workflow
jobs:
  secure-job:
    runs-on: redducklabs-runners
    permissions:
      contents: read      # Minimal permissions
      packages: none      # No package access
    steps:
    - uses: actions/checkout@v4
      with:
        token: ${{ secrets.GITHUB_TOKEN }}  # Use provided token
```

## 📊 Security Compliance

### Compliance Frameworks

**SOC 2 Type II:**
- Access controls and authentication
- System monitoring and logging
- Change management procedures
- Data protection measures

**ISO 27001:**
- Information security management
- Risk assessment and treatment
- Incident response procedures
- Business continuity planning

### Regular Security Reviews

**Monthly:**
- Review access permissions
- Check for security updates
- Analyze security logs
- Test incident response procedures

**Quarterly:**
- Penetration testing
- Security configuration review
- Update security documentation
- Training and awareness

## 🔗 Security Tools Integration

### Vulnerability Scanning

**Trivy Integration:**
```bash
# Scan runner image
trivy image registry.digitalocean.com/redducklabs/github-runner:latest

# Scan cluster
trivy k8s cluster --report summary
```

## 🔒 Security Vulnerability Remediation

### CVE-2025-8959: HashiCorp go-getter Symlink Attack Vulnerability

**Status:** RESOLVED  
**Severity:** HIGH  
**Date Fixed:** August 21, 2025

**Vulnerability Description:**
HashiCorp's go-getter library subdirectory download feature was vulnerable to symlink attacks leading to unauthorized read access beyond the designated directory boundaries.

**Affected Component:**
- Trivy security scanner (included in custom runner image)
- go-getter library dependency v1.7.8

**Remediation Action:**
Updated Trivy installation in `docker/Dockerfile.custom-runner` to:
1. Build from source using Go 1.24.6 instead of using pre-compiled binaries
2. Explicitly update go-getter dependency to v1.7.9 which includes the security fix
3. Build from main branch to ensure latest security patches

**Technical Details:**
- The fix disables symlinks in git client operations
- Specifically addresses subdirectory symlink content handling
- Prevents unauthorized directory traversal via symlink attacks

**Verification:**
```bash
# Verify Trivy includes fixed go-getter version
trivy --version
# Check for go-getter v1.7.9 in dependencies
```

**References:**
- CVE-2025-8959
- HashiCorp go-getter PR #540: https://github.com/hashicorp/go-getter/pull/540
- go-getter v1.7.9 release: https://github.com/hashicorp/go-getter/releases/tag/v1.7.9

**kubesec Security:**
```bash
# Validate Kubernetes manifests
kubesec scan deploy/dind-values.yaml
```

### Policy Enforcement

**Open Policy Agent (OPA):**
```rego
# Example policy
package kubernetes.admission

deny[msg] {
  input.request.kind.kind == "Pod"
  input.request.object.spec.containers[_].securityContext.privileged == true
  msg := "Privileged containers are not allowed"
}
```

## ✅ Security Checklist

### Deployment Security
- [ ] GitHub tokens have minimal required scopes
- [ ] Container registry uses dedicated tokens
- [ ] Kubernetes RBAC is properly configured
- [ ] Network policies restrict communication
- [ ] Resource limits are set
- [ ] Security contexts are configured
- [ ] Image scanning is enabled

### Operational Security
- [ ] Regular token rotation schedule
- [ ] Security monitoring is active
- [ ] Incident response procedures are documented
- [ ] Backup and recovery procedures are tested
- [ ] Security updates are applied regularly
- [ ] Access permissions are reviewed monthly

### Compliance
- [ ] Audit logging is enabled
- [ ] Compliance requirements are met
- [ ] Security documentation is current
- [ ] Staff training is completed
- [ ] Regular security assessments are conducted

## 📞 Security Contacts

**Internal Security Team:**
- Email: security@redducklabs.com
- Slack: #security-incidents
- On-call: Follow incident response procedures

**External Resources:**
- GitHub Security Advisory: security@github.com
- DigitalOcean Security: security@digitalocean.com
- Kubernetes Security: security@kubernetes.io

Remember: Security is everyone's responsibility. Report any security concerns immediately.