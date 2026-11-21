# Security Guide - Red Duck Labs GitHub Actions Runners

**Last Updated:** November 21, 2026

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
- Store the token only as the `RUNNER_TOKEN` GitHub Actions repository secret,
  never in code or in a committed values file

**Required Scopes:**
```
admin:org    # For organization-level runners
repo         # For repository access
workflow     # For workflow management
```

**Token Storage:**

`deploy/dind-values.yaml` commits `githubConfigSecret.github_token: ""`. The
**Deploy GitHub Runners** workflow passes the token to Helm at deploy time, and
the ARC scale-set chart stores it in a Kubernetes Secret that the chart creates
in `arc-runners`. No manually created token secret is used.

```bash
# What .github/workflows/deploy-runners.yml runs (token from secrets.RUNNER_TOKEN)
helm upgrade ... -f deploy/dind-values.yaml \
  --set githubConfigSecret.github_token="${RUNNER_TOKEN}"
```

**`RUNNER_TOKEN` uses beyond ARC registration:**
- `prepare-trust-boundary` re-reads each member repository's fork-PR workflow
  policy (`GET /repos/{owner}/{repo}/actions/permissions/fork-pr-workflows-private-repos`),
  which needs repository administration read on every member. Without it the
  read fails and the operation fails closed before any runner-group change.
- **Runner Version Guard** pushes one `automation/actions-runner-<version>`
  branch, opens its PR, and writes a tracking issue in this repository. A PR
  from `GITHUB_TOKEN` would not trigger the image build, so it uses this token.
  The branch needs the usual build, scans and a merge, so a new base image never
  reaches the privileged fleet unreviewed. The version comes from upstream tags
  that must match `vX.Y.Z`, and no release text reaches a shell or a PR body.
  It also uses `DO_TOKEN` for read-only pod and log reads, and prints only
  version numbers from those logs.
- **CI Usage Report** lists the organization's repositories and reads Actions
  runs and jobs (GET only) of every non-archived repository, which needs the
  `repo` scope for the private ones. It runs on GitHub-hosted `ubuntu-latest`
  with `contents: read` and mutates nothing. Because this repository is public
  and its Actions logs, job summaries and artifacts are readable by anyone who
  can read it, everything the workflow emits (summary, artifact, stdout and
  stderr) is aggregate and non-identifying: organization totals for fleet and
  hosted jobs and minutes, cost totals by runner SKU, concurrency and queue
  statistics, and a count of unreadable repositories. No repository name,
  per-repository number, job name or API error text is printed. The
  per-repository breakdown (`--per-repo`) exists only for an operator's local
  run; the workflow never passes it and the script refuses it when
  `GITHUB_ACTIONS=true`. Tests in `test/verify-burst-autoscaling.sh` check that
  no fixture repository name reaches aggregate output, logs or JSON.
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
- The pre-tool-cache burst-family template is no longer admitted: the
  transition variant that let the earlier live release classify was removed
  once the fleet was deployed with the tool cache (2026-11-01).

### Container Network Security

- The runner container and the DinD sidecar share the pod's network
  namespace, so the runner NetworkPolicy above applies to both
- `dockerd` listens only on the Unix socket `/var/run/docker.sock`, shared with
  the runner through the `dind-sock` emptyDir volume; no TCP listener is opened
- The DinD sidecar runs with `privileged: true`; the runner container is not
  privileged. This is an accepted risk (AOR-1 and AOR-2 in
  `docs/security/vulnerability-dismissals.md`)

## 🐳 Container Security

### Image Security

**Base Image:**
- The official GitHub runner image, pinned by version in
  `docker/Dockerfile.custom-runner`
  (`ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:<version>`)
- The **Runner Version Guard** workflow opens a reviewed PR to bump the pin
  when a new runner release appears
- Vulnerability scanning with Trivy and an enforcing CVE-floor gate (below)

**Custom Image Security** (`docker/Dockerfile.custom-runner`):
- Multi-stage build: kubeconform and kubesec are built from source with a
  current Go toolchain in a throwaway builder stage; kubectl, doctl, Trivy,
  Helm, buildx, uv and Node.js are downloaded as release artifacts and checked
  against pinned SHA256 values
- Tool versions are pinned with `ARG` values at the top of the Dockerfile
- apt lists, `/tmp` and Python caches are removed in a final cleanup layer
- The image ends with `USER runner`; root is used only during the build

**Image Scanning:**

The **Build Runner Image** workflow scans every PR image and every pushed
image. The Trivy HIGH/CRITICAL scan (`aquasecurity/trivy-action`, honoring
`.trivyignore`) is report-only and uploads SARIF to the Security tab. The
enforcing gate is `test/verify-cve-floor.sh`, which fails the build if any Go
tool's toolchain is below Go 1.24.6, Trivy's go-getter is below v1.7.9, or
kubesec's `golang.org/x/crypto` is below v0.35.0. The workflow also requires
Docker CLI 28.3.3 or newer.

```bash
# Run the CVE-floor gate against a locally built image
bash test/verify-cve-floor.sh <image-ref>

# Scan the published image (log in first with `doctl registry login`)
trivy image registry.digitalocean.com/redducklabs/github-runner:latest
```

### Runtime Security

**Security Context** (as set in `deploy/dind-values.yaml`):
```yaml
template:
  spec:
    automountServiceAccountToken: false
    # No pod-level securityContext (no runAsNonRoot, no fsGroup)
    initContainers:
    - name: dind
      securityContext:
        privileged: true            # Docker daemon; accepted risk (AOR-2)
    containers:
    - name: runner
      securityContext:
        runAsUser: 1001
        runAsGroup: 121
        allowPrivilegeEscalation: true   # workflows use sudo (AOR-1)
        readOnlyRootFilesystem: false
```

The runner container starts as uid 1001 but keeps the default capability set
and can escalate with `sudo`. Setting `allowPrivilegeEscalation: false` or
dropping all capabilities breaks `sudo`/`apt` in real workflows; the isolation
boundary is the pod, not in-container privilege restriction. See AOR-1 in
`docs/security/vulnerability-dismissals.md`.

**Resource Limits:**

One pod-level budget is shared by the runner and the DinD sidecar; containers
set no resources of their own. There is no CPU limit and no ephemeral-storage
limit.

```yaml
template:
  spec:
    resources:
      requests:
        cpu: "3"
        memory: "5Gi"
      limits:
        memory: "6Gi"
```

`test/verify-runner-resources.sh` renders the chart and checks this budget and
the two-pods-per-node packing.

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

This repository does not deploy Prometheus, alerting rules, or a Kubernetes
audit policy; the cluster add-ons it manages are limited to metrics-server
(`deploy/metrics-server-values.yaml`). The **Runner Status** workflow reports
pod state and OOM evidence. The two snippets below are illustrative examples
for an operator who adds that tooling, not deployed configuration.

**Alerting Rules:**
```yaml
# Example Prometheus alert (not deployed by this repository)
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

**Kubernetes Audit (example):**
```yaml
# audit-policy.yaml (example; DOKS manages the API server, so apply this only
# where you control the control plane's audit configuration)
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
```

Relabeling a pod does not isolate it: the runner NetworkPolicy selects pods by
`actions.github.com/scale-set-name`, which a new label does not change.
Runner pods are ephemeral and are removed when their job ends or the release
is stopped, so collect logs before or while stopping.

**2. Investigation:**
```bash
# Collect logs (runner and Docker daemon)
kubectl logs <pod-name> -n arc-runners -c runner > incident-runner.txt
kubectl logs <pod-name> -n arc-runners -c dind > incident-dind.txt

# Check events
kubectl get events -n arc-runners --sort-by='.lastTimestamp'
```

Review the organization audit log in GitHub for runner registration and
runner-group changes.

**3. Recovery:**

Rotate credentials in GitHub, then redeploy from a reviewed commit:

1. Create a new `RUNNER_TOKEN` PAT, update the repository secret, and revoke
   the old token.
2. If `DO_TOKEN` is affected, create a new DigitalOcean token, update the
   repository secret, revoke the old one, and run **Prepare Runner Platform**
   from the reviewed SHA to recreate `do-registry-secret`.
3. Run **Deploy GitHub Runners** (`operation=deploy`, with
   `acknowledge_emergency_stop=true` after an Emergency Stop) from the same
   reviewed SHA. Deploy re-renders the chart's token Secret from the new
   `RUNNER_TOKEN`.

### Common Security Incidents

**1. Token Compromise:**
- Immediately revoke the token in GitHub
- Generate new token with minimal scopes
- Update the `RUNNER_TOKEN` (or `DO_TOKEN`) repository secret and redeploy
  through the workflows, as in Recovery above
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

The runner container's environment in `deploy/dind-values.yaml` is limited to
the Docker connection and the shared tool cache:
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
      - name: RUNNER_TOOL_CACHE
        value: /opt/hostedtoolcache
      - name: AGENT_TOOLSDIRECTORY
        value: /opt/hostedtoolcache
```

Runners are ephemeral (one job per pod) and cannot self-update. The runner
version is the pinned base image; the **Runner Version Guard** workflow opens a
PR before GitHub's 30-day version cutoff (see `docs/runbooks/node-pool-sizing.md`).

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

# Scan the cluster in the current kube context (read-only)
trivy k8s --report summary
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
The August 2025 fix built Trivy from source with Go 1.24.6 and go-getter
v1.7.9. The 2026 toolchain refresh
(`docs/specs/2026-05-31-runner-toolchain-refresh-design.md`) replaced the
source build: `docker/Dockerfile.custom-runner` now installs the official Trivy
release binary (`TRIVY_VERSION`, verified against `TRIVY_SHA256`), whose
upstream build already includes the fixed go-getter. The fix is enforced, not
assumed: the CVE-floor gate (`test/verify-cve-floor.sh`) fails the image build
if Trivy's embedded go-getter is below v1.7.9.

**Technical Details:**
- The fix disables symlinks in git client operations
- Specifically addresses subdirectory symlink content handling
- Prevents unauthorized directory traversal via symlink attacks

**Verification:**
```bash
# Enforcing gate, as run by the Build Runner Image workflow
bash test/verify-cve-floor.sh <image-ref>

# Manual check inside the image (the image ships a Go runtime)
docker run --rm <image-ref> bash -c 'go version -m /usr/local/bin/trivy | grep go-getter'
```

**References:**
- CVE-2025-8959
- HashiCorp go-getter PR #540: https://github.com/hashicorp/go-getter/pull/540
- go-getter v1.7.9 release: https://github.com/hashicorp/go-getter/releases/tag/v1.7.9

**kubesec Security:**
`deploy/dind-values.yaml` is a Helm values file, not a manifest, and the
rendered runner pod template sits inside an `AutoscalingRunnerSet` custom
resource, while kubesec scores standard workload kinds such as Pod and
Deployment. Render the chart, wrap the pod template in a Pod, and scan that. Expect kubesec to flag the privileged DinD sidecar and
`allowPrivilegeEscalation: true`; both are accepted risks (AOR-1, AOR-2).
```bash
# Render the runner scale set (no cluster access needed)
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 --kube-version 1.36.3 -f deploy/dind-values.yaml \
  --set githubConfigSecret.github_token=PLACEHOLDER \
  --set controllerServiceAccount.name=arc-gha-rs-controller \
  --set controllerServiceAccount.namespace=arc-systems > rendered-runners.yaml

# Extract the runner pod template as a Pod (needs PyYAML) and scan it
python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "AutoscalingRunnerSet":
        print(yaml.safe_dump({"apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": "runner"}, "spec": d["spec"]["template"]["spec"]}))
' < rendered-runners.yaml > runner-pod.yaml
kubesec scan runner-pod.yaml
```

### Policy Enforcement

No OPA, Gatekeeper, Kyverno, or Pod Security Standards enforcement is deployed
for `arc-runners`. A policy that rejects privileged containers (or the
`baseline`/`restricted` Pod Security Standards) would reject the DinD sidecar,
which must run privileged. The admission and policy controls this repository
does enforce are:

- the ValidatingAdmissionPolicy `runner-fleet-emergency-stop-fence`
  (`deploy/runner-emergency-stop-fence.yaml`), described under Burst capacity
  controls;
- the NetworkPolicy `redducklabs-runner-isolation`
  (`deploy/runner-network-policy.yaml`), validated by
  `scripts/verify-runner-network-policy.sh`;
- workflow-side checks before every Helm write: the rendered contract checks
  in `scripts/validate-runner-isolation-contract.py` and the Deploy workflow, a
  server-side dry run, and the pool-state gate
  (`scripts/verify-runner-pool-state.sh`);
- the runner-group trust boundary (`scripts/verify-runner-trust-boundary.sh`
  against `deploy/trusted-runner-repositories.txt`).

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
