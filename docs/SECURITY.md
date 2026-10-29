# Security Guide - Red Duck Labs GitHub Actions Runners

**Last Updated:** October 27, 2026

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

**`RUNNER_TOKEN` uses beyond ARC registration:**
- `prepare-trust-boundary` re-reads each member repository's fork-PR workflow
  policy (`GET /repos/{owner}/{repo}/actions/permissions/fork-pr-workflows-private-repos`),
  which needs repository administration read on every member. Without it the
  read fails and the operation fails closed before any runner-group change.
- **Runner Acceptance Evidence** reads `redducklabs/aurolegal.ai` Actions runs,
  jobs and tags, and cancels the acceptance probe run it has verified. It never
  cancels a run it has not verified (repository, workflow path, `headSha`,
  event, attempt, annotated tag resolving to the reviewed commit).

### Burst capacity controls

The burst design (`docs/specs/2026-10-26-runner-burst-autoscaling-design.md`)
raises the fleet to at most 10 runner nodes and 20 runners. It keeps every
earlier fail-closed control and adds:

- Provider bounds as the node ceiling: baseline `min=max=count=2`, burst pools
  0..6 and 0..2, maxima summing to at most 8; every guard rejects anything else.
- One operation-aware pool-state gate (`scripts/verify-runner-pool-state.sh`)
  before every fleet mutation, and an identity bracket around every mutation
  (cluster, baseline pool and baseline node identities must not change).
- `expected_sha` verified first and the shared non-cancelling
  `runner-fleet-mutation` concurrency group on every fleet mutator (Deploy,
  Scale Runners, Node Pool Sizing, Prepare Runner Platform, Deploy Cluster
  Addons). Two documented exceptions have their own non-cancelling groups:
  Emergency Stop (`runner-emergency-stop`) runs immediately, and in-flight
  mutations then fail closed at their next identity comparison or admission;
  Rebalance (`runner-rebalance`) skips while any fleet mutator is queued or
  running and still passes the gate and per-deletion identity checks.
- Emergency Stop leaves a classified `stopped` state (the base template at
  `minRunners=maxRunners=0`); only the recovery paths admit it, and every other
  operation rejects it.
- Every Helm write keeps 100 revisions (`--history-max 100`). Rollback does not
  depend on Helm history: Deploy `rollback` validates the committed, reviewed
  `deploy/density-values.yaml` as the `density` contract (values and rendered
  manifest) and upgrades the release to exactly that render, and Scale Runners
  `record-density` verifies read-only that the live pre-burst release equals
  it. Drain takes and verifies no revision.
- Emergency Stop fence, client side (Ruling 33): Emergency Stop writes the
  marker ConfigMap `arc-runners/runner-fleet-emergency-stop` before its Helm
  write. While it exists the pool-state gate refuses every fleet mutator except
  Deploy `deploy`/`rollback` dispatched with `acknowledge_emergency_stop=true`
  (they delete the marker with uid/resourceVersion preconditions, inside the
  identity bracket) and `remove-burst`; every fleet Helm write re-reads the
  marker afterwards and re-applies 0/0 if it exists.
- Emergency Stop fence, server side (Ruling 36): the client-side re-check runs
  only if the writing process survives its Helm call. The
  ValidatingAdmissionPolicy `runner-fleet-emergency-stop-fence`
  (`deploy/runner-emergency-stop-fence.yaml`, `failurePolicy: Fail`, binding
  `validationActions: [Deny]`) takes the marker as its parameter
  (`paramRef`, `parameterNotFoundAction: Allow`): while the marker exists the
  API server denies every CREATE or UPDATE of an AutoscalingRunnerSet in
  `arc-runners` unless it keeps `maxRunners=0` and `minRunners` 0 or absent,
  whoever sends it. A stale fleet run that is cancelled or loses its runner
  right after its Helm write therefore cannot leave the fleet reopened.
  Emergency Stop's own 0/0 write is allowed, the status subresource and DELETE
  are not matched, and outside a stop the policy is inert. Deploy `deploy` and
  `rollback` install it before their Helm write (server-side dry run whose
  returned specs must equal the file, then a bracketed server-side apply and a
  type-check readback); every other fleet mutator's admission requires the live
  policy and binding to equal the file (an absent fence is tolerated only while
  ARC is `density`/`density-stopped`, before the first burst deploy). After
  writing the marker and before its Helm write, Emergency Stop proves the fence
  enforces: a server-side dry-run patch of the AutoscalingRunnerSet to
  `maxRunners=1` must be denied by this policy (retried for up to 30 s for the
  admission informer); if not, the stop is still applied and the run fails.
  Residual: while the marker exists the API server also denies the ARC
  controller's own metadata updates of an AutoscalingRunnerSet that is not yet
  0/0 (only in the seconds between the marker write and Emergency Stop's
  write), and a deployment credential able to delete the policy can still
  remove the fence; a missing or changed fence then fails the admission of
  every later mutator that requires it, and Emergency Stop reports it red.
- Runner pods marked `safe-to-evict: "false"`, so no node with a job is scaled
  down; idle-runner retirement deletes only EphemeralRunners with no job.
- A read-only acceptance controller: Runner Acceptance Evidence runs only
  `kubectl get`, `doctl ... list` and read-only gate checks; repositories migrate
  only after acceptance Phase E reports `READY_FOR_MIGRATION=true`.

The privileged DinD co-tenancy trade-off and the selected-repository trust
boundary are recorded in `docs/security/vulnerability-dismissals.md` (AOR-2).

### Container Registry Security

**DigitalOcean Registry:**
- Prepare registry access only through the **Prepare Runner Platform** workflow.
- The workflow obtains read-only Docker configuration without printing it and
  creates `do-registry-secret` explicitly in `arc-runners`.
- Deployment requires type `kubernetes.io/dockerconfigjson`, valid
  `.dockerconfigjson`, and non-empty auth for `registry.digitalocean.com`.
- Rotate the repository `DO_TOKEN`, then rerun the reviewed preparation
  workflow from its exact commit SHA.

### Kubernetes RBAC

The scale-set chart owns
`redducklabs-runners-gha-rs-no-permission`. Platform preparation does not create
or adopt it. If the object already exists before deploy, its Helm release and
namespace annotations must identify `redducklabs-runners` in `arc-runners`,
and its managed-by label must be `Helm`. Runner Pods set
`automountServiceAccountToken: false`; server-side admission validation rejects
an injected service-account token volume or mount. Deploy only upgrades an
existing release; there is no first-install bootstrap (the pool-state gate
requires exactly one deployed release of the pinned chart). A fresh cluster
needs a separate, reviewed bootstrap procedure, which is out of scope of the
burst design (Ruling 15 in the burst autoscaling design record).

## 🌐 Network Security

### Network Policies

Runner network isolation is enforced by
[`deploy/runner-network-policy.yaml`](../deploy/runner-network-policy.yaml)
(design: `docs/specs/2026-10-26-runner-burst-autoscaling-design.md`,
"Runner network isolation"). Runner pods include privileged DinD, so without
it they could reach production pods and services, node kubelets and the VPC
(`10.124.0.0/20`, including managed databases).

- One `networking.k8s.io/v1` NetworkPolicy, `redducklabs-runner-isolation`,
  in `arc-runners`, selecting
  `actions.github.com/scale-set-name=redducklabs-runners`, with
  `policyTypes: [Ingress, Egress]` and no ingress rule (all ingress denied).
- Egress only to kube-dns pods (`kube-system`, `k8s-app=kube-dns`) on UDP and
  TCP 53, and to `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`, `100.64.0.0/10` and `169.254.0.0/16`. Those ranges cover the
  pod CIDR `10.244.0.0/16`, the service CIDR `10.245.0.0/16`, the VPC and node
  addresses. Jobs keep internet access for GitHub, registries and mirrors.
- The DigitalOcean metadata service is also blocked by the DOKS-managed
  CiliumClusterwideNetworkPolicy `deny-imds-egress` for every endpoint not
  labeled `doks.digitalocean.com/allow-imds-egress=true`; Cilium deny rules
  take precedence over allows. The `169.254.0.0/16` exception is defense in
  depth.

Allows are additive, so reading back one object does not prove the boundary.
`scripts/verify-runner-network-policy.sh` validates the complete applicable
policy set, read-only:

- NetworkPolicies in `arc-runners`: exactly one, `redducklabs-runner-isolation`,
  whose `spec` equals the committed file;
- CiliumNetworkPolicies in `arc-runners`: none;
- every CiliumClusterwideNetworkPolicy deny-only (only `egressDeny` /
  `ingressDeny`; any `egress` or `ingress` allow fails, because a clusterwide
  selector can match runner pods);
- a Cilium policy CRD that is not installed counts as zero objects; any other
  API error, including a failed CRD list, fails;
- no pod in `arc-runners` labeled `doks.digitalocean.com/allow-imds-egress=true`.

Deploy `deploy` installs the policy before the Helm upgrade: a server-side dry
run, then a server-side apply inside the identity bracket (exact comparison and
re-admission before it, exact comparison after it), then the policy-set
validation, which must pass before the Helm upgrade runs. The pool-state gate
requires the same validation on admission for `enable-burst`, `rebalance` and
`acceptance-phase-c`; `drain` and `rollback` leave the policy in place.
Acceptance Phase A runs a network probe from inside a runner pod (criterion
`A-network`): DNS and HTTPS to github.com must work, and the metadata service, a
`worker-pool` node's kubelet and SSH, a baseline runner node's kubelet, a
runner node's public (ExternalIP) kubelet and SSH, `kubernetes.default`, and a
ClusterIP service and a pod (not a kube-dns pod) in other namespaces must time
out.

**Scope of the control:** Cilium enforces the policy at the runner pod's
network interface. A job that escapes the privileged DinD container to the
node is outside the pod's network namespace and is not constrained by it; that
path is covered by the accepted privileged-DinD co-tenancy risk (AOR-2 in
`docs/security/vulnerability-dismissals.md`), not by this policy.

### Docker Hub pull-through mirror

The burst, burst-acceptance and drain contracts start the DinD `dockerd` with
`--registry-mirror=https://mirror.gcr.io`. Anonymous Docker Hub pulls are
limited per source IP, and a single CI run makes dozens of pulls, so many
concurrent jobs on a few node IPs would exhaust the limit.

- `mirror.gcr.io` is a public pull-through cache for Docker Hub operated by
  Google. It is not a private registry and is not under Red Duck Labs control.
- Only Docker Hub (`docker.io`) pulls use the mirror; other registries are
  unaffected. A mirror miss or failure falls back to Docker Hub.
- Images referenced by digest are still verified by digest: the daemon rejects
  content whose digest does not match, so a compromised or stale mirror cannot
  substitute a pinned image. Images referenced only by a mutable tag trust the
  mirror's copy of that tag, as they would trust Docker Hub's.
- The mirror is egress to a public Google endpoint and is already within the
  runner pods' permitted public egress; no NetworkPolicy change is needed.
- Density and legacy-isolated contracts do not carry the flag, so recorded
  revisions of earlier releases remain valid rollback targets.

### Shared actions/setup-* tool cache

The burst, burst-acceptance and drain contracts mount one `tool-cache`
emptyDir at `/opt/hostedtoolcache` in both the runner and the DinD sidecar, and
set `RUNNER_TOOL_CACHE` and `AGENT_TOOLSDIRECTORY` to that path on the runner.

- Both mounts are required. Container jobs bind-mount the runner's tool
  directory (`-v <tool dir>:/__t`), and dockerd resolves bind sources in its
  own filesystem. Without the dind mount, dockerd creates a separate root-owned
  directory that a non-root job container (`--user 1001:121`) cannot write.
- Ownership: the kubelet creates a plain emptyDir mode 0777, as it does for
  `work`, which already holds the job workspace. uid 1001 writes it with no
  root init container, no pod `fsGroup` (which would also re-own the dind
  socket volume and add a group to the privileged sidecar), and no
  securityContext change. Anything in the pod can write it, which is the same
  exposure as `work`. Its lifetime is one ephemeral job pod.
- The volume is disk-backed (no `medium: Memory`) so toolchains do not count
  against the shared pod memory limit. Like `work`, it has no `sizeLimit`.
- The image sets no tool-cache env. Density and legacy-isolated do not carry
  the volume or env, so those pods keep the runner default `<work>/_tool` on
  the shared `work` volume, and recorded revisions remain valid rollback
  targets. The contract validator and the Deploy admission check pin all of
  this exactly.
- Transition: until Deploy `deploy` applies the tool cache, the live burst
  release is the earlier template. The validator therefore also admits that
  exact pre-tool-cache burst-family template (every tool-cache part absent
  together). Otherwise every fleet gate, Emergency Stop's readback included,
  would classify the live fleet as matching no contract. A partial tool cache
  matches neither template. The Deploy admission check admits only the full
  tool cache for a new release. Remove the transition variant once the fleet
  runs the tool cache.

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

Run **Emergency Stop Runners** in GitHub Actions (`confirm=STOP-RUNNERS`). It
runs immediately in its own `runner-emergency-stop` concurrency group, sets the
release to 0/0 on the pinned chart, and reads back the `stopped` state; recovery
is in `docs/runbooks/node-pool-sizing.md`, "Emergency Stop". The local
`scripts/emergency-stop.sh` is a legacy fallback for when GitHub Actions is
unavailable.

```bash
# Legacy local fallback only
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

# Update the repository DO_TOKEN secret, then run Prepare Runner Platform from
# the reviewed SHA to reconcile registry access. Deploy runners through the
# GitHub Actions deployment workflow from that same reviewed SHA.
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
