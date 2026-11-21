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

Store the PAT as the `RUNNER_TOKEN` GitHub Actions secret. The **Deploy GitHub
Runners** workflow passes it to Helm with `--set githubConfigSecret.github_token=...`,
and the ARC chart creates the Kubernetes secret. The repository never holds the
token value:

```yaml
# deploy/dind-values.yaml
githubConfigSecret:
  github_token: ""  # Provided via --set flag
```

### Container Registry Security

**DigitalOcean Registry:**
- Use dedicated registry tokens, not personal tokens
- Configure pull secrets for private images
- Regular credential rotation

The **Deploy GitHub Runners** workflow creates the registry pull secret with
`doctl` (authenticated by the `DO_TOKEN` secret) when it is missing. To create
it by hand:

```bash
doctl auth init   # with the DigitalOcean API token
doctl registry kubernetes-manifest --name do-registry-secret --namespace arc-runners \
  | kubectl apply -f -
```

### Kubernetes RBAC

Runner pods use the service account the ARC chart provides; this repository
does not deploy custom RBAC. If you add a dedicated service account, keep it
minimal.

**Example (not deployed by this repository):**
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

This repository does not deploy NetworkPolicies. The policies below are
recommended examples; the cluster's CNI must support NetworkPolicy for them to
take effect.

**Egress Control (example):**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: runner-network-policy
  namespace: arc-runners
spec:
  podSelector:
    matchLabels:
      actions.github.com/scale-set-name: redducklabs-runners
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

**Ingress Restrictions (example):**
```yaml
# No ingress required for runners
spec:
  policyTypes:
  - Ingress
  ingress: []  # Deny all ingress
```

### Container Network Security

- Containers run in isolated network namespaces
- The Docker-in-Docker sidecar runs `privileged: true`, which `dockerd`
  requires; the pod and its dedicated node are the isolation boundary. See AOR-1
  in [vulnerability-dismissals.md](security/vulnerability-dismissals.md#accepted-operational-risks).

## 🐳 Container Security

### Image Security

**Base Image:**
- Use official GitHub runner images as base
- Regular updates to base images
- Vulnerability scanning with Trivy

**Custom Image Security** (`docker/Dockerfile.custom-runner`):
- Each release binary is checked with `sha256sum -c` and installed with
  `install -m 0755` into `/usr/local/bin`.
- Apt caches and temp files are removed in the final layer
  (`apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*`).
- The image ends with `USER runner` (non-root).

**Image Scanning:**
```bash
# Automated scanning in CI/CD
trivy image registry.digitalocean.com/redducklabs/github-runner:latest
```

### Runtime Security

**Security Context** (from `deploy/dind-values.yaml`):
```yaml
template:
  spec:
    initContainers:
    - name: dind           # native sidecar (restartPolicy: Always)
      securityContext:
        privileged: true   # required by dockerd
    containers:
    - name: runner
      securityContext:
        runAsUser: 1001
        runAsGroup: 121
        allowPrivilegeEscalation: true   # sudo/apt in CI jobs; accepted risk AOR-1
        readOnlyRootFilesystem: false    # Required for runner operation
```

Runner jobs can use `sudo`. This is an accepted risk, recorded as AOR-1 in
[vulnerability-dismissals.md](security/vulnerability-dismissals.md#accepted-operational-risks).

**Resource Limits:**
```yaml
# runner container
resources:
  requests: { cpu: "2", memory: "5Gi" }
  limits:   { memory: "10Gi" }   # no CPU limit; one runner pod per node
# dind sidecar
resources:
  requests: { cpu: "1", memory: "5Gi" }
  limits:   { memory: "10Gi" }
```

See [runbooks/node-pool-sizing.md](runbooks/node-pool-sizing.md) for how these
values relate to node size.

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

# Update the RUNNER_TOKEN and DO_TOKEN GitHub Actions secrets, then remove
# the old registry pull secret so the next deploy recreates it
kubectl delete secret do-registry-secret -n arc-runners

# Redeploy with the new credentials via the "Deploy GitHub Runners" workflow
gh workflow run deploy-runners.yml
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

**Runner Configuration** (runner container environment in `deploy/dind-values.yaml`):
```yaml
template:
  spec:
    containers:
    - name: runner
      env:
      - name: DOCKER_HOST
        value: unix:///var/run/docker.sock
      - name: RUNNER_WAIT_FOR_DOCKER_IN_SECONDS
        value: "120"
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
    - uses: actions/checkout@v7
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
Trivy is installed as the official release binary (`TRIVY_VERSION` in
`docker/Dockerfile.custom-runner`) with SHA256 verification. Current releases
embed a fixed go-getter, and the go-getter >= v1.7.9 floor is enforced at build
time and in CI by `test/verify-cve-floor.sh`. (Trivy was previously built from
source to get the fix; that is no longer needed.)

**Technical Details:**
- The fix disables symlinks in git client operations
- Specifically addresses subdirectory symlink content handling
- Prevents unauthorized directory traversal via symlink attacks

**Verification:**
```bash
# Enforced check (all CVE floors)
./test/verify-cve-floor.sh <image-ref>

# Or inspect the embedded go-getter version directly
go version -m /usr/local/bin/trivy | grep go-getter
```

**References:**
- CVE-2025-8959
- HashiCorp go-getter PR #540: https://github.com/hashicorp/go-getter/pull/540
- go-getter v1.7.9 release: https://github.com/hashicorp/go-getter/releases/tag/v1.7.9

**kubesec Security:**
```bash
# deploy/dind-values.yaml is Helm values, not a manifest: render it first
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 -f deploy/dind-values.yaml | kubesec scan /dev/stdin
```

### Policy Enforcement

**Open Policy Agent (OPA):**

As written, this example would also block the runner pods, because the dind
sidecar is privileged. Exclude the `arc-runners` namespace or the `dind`
container if you adopt it.

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