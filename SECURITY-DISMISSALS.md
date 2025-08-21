# Security Vulnerability Dismissals

This document tracks security vulnerabilities that have been reviewed and dismissed as "Won't Fix" with proper risk assessment and justification.

## Overview

The vulnerabilities listed in this document originate from the official GitHub Actions runner base image (`ghcr.io/actions/actions-runner:latest`) and cannot be remediated without:
1. Breaking compatibility with GitHub's Actions Runner Controller (ARC)
2. Requiring maintenance of a completely custom runner implementation
3. Losing official support and updates from GitHub

## Risk Assessment Philosophy

These dismissals follow the principle of **Informed Risk Acceptance** where:
- The vulnerability source is identified and understood
- The risk is assessed in the context of our threat model
- Mitigation controls are implemented where possible
- The business impact of fixing vs. not fixing is evaluated
- Regular review processes are established

---

## Dismissed Vulnerabilities

### CVE-2025-47907 - Container Runtime Components

**Alert IDs:** #11, #10, #8, #6, #5, #4, #3  
**Affected Components:**
- `/usr/bin/runc` (Alert #11)
- `/usr/bin/dockerd` (Alert #10)  
- `/usr/bin/docker-proxy` (Alert #8)
- `/usr/bin/docker` (Alert #6)
- `/usr/bin/ctr` (Alert #5)
- `/usr/bin/containerd-shim-runc-v2` (Alert #4)
- `/usr/bin/containerd` (Alert #3)

**Severity:** High  
**CVSS Score:** [Score from CVE database]  
**CWE:** [Weakness type from CVE database]

#### Vulnerability Description
CVE-2025-47907 affects multiple Docker and container runtime components within the GitHub Actions runner base image. This vulnerability impacts the core container runtime functionality that is essential for GitHub Actions execution.

#### Risk Assessment

**Threat Context:**
- Affects container runtime components critical to runner operation
- Exploitation would require access to the container runtime environment
- Our runners operate in isolated Kubernetes pods with restricted network policies

**Impact Analysis:**
- **Confidentiality:** Medium - Limited to container runtime context
- **Integrity:** High - Could potentially affect container execution
- **Availability:** Medium - Could impact runner stability

**Exploitability:**
- Requires authenticated access to the runner environment
- Limited by Kubernetes network policies and RBAC
- Runners are ephemeral and automatically recycled

#### Justification for Dismissal

**Primary Reasons:**
1. **Base Image Dependency:** These components are integral to the official GitHub Actions runner image
2. **Compatibility Requirements:** Modifying these components would break ARC compatibility
3. **Vendor Responsibility:** GitHub is responsible for base image security updates
4. **Limited Attack Surface:** Our security controls significantly limit potential exploitation

**Risk Acceptance Criteria:**
- Benefits of maintaining official GitHub compatibility outweigh the identified risks
- Compensating controls provide adequate risk mitigation
- GitHub's security response team will address critical base image vulnerabilities

#### Compensating Controls

**Container Security:**
- Runners execute in isolated Kubernetes pods
- Non-root user execution (`runAsUser: 1001`)
- Restricted security context with `allowPrivilegeEscalation: false`
- Resource limits prevent resource exhaustion attacks
- Read-only root filesystem where possible

**Network Security:**
- Network policies restrict egress to essential services only
- No ingress traffic allowed to runner pods
- DNS restrictions limit name resolution scope

**Runtime Security:**
- Pod Security Standards enforcement
- Automatic pod lifecycle management (ephemeral runners)
- Container image scanning for additional vulnerabilities
- Runtime monitoring and alerting

**Access Controls:**
- Kubernetes RBAC limits service account permissions
- GitHub token scoping restricts repository access
- Container registry access limited to pull operations

#### Mitigation Strategies

**Immediate Actions:**
1. Enhanced monitoring for container runtime anomalies
2. Automated runner pod rotation policies
3. Network traffic analysis for unusual patterns
4. Regular security assessment of runner configurations

**Long-term Monitoring:**
1. Subscribe to GitHub Security Advisories for base image updates
2. Implement automated vulnerability scanning on base image updates
3. Regular review of this risk acceptance (quarterly)
4. Evaluation of alternative runner architectures if security posture changes

**Contingency Planning:**
1. Emergency runner shutdown procedures documented in `/scripts/emergency-stop.sh`
2. Rapid redeployment capabilities with updated base images
3. Alternative runner deployment options maintained

---

### CVE-2024-21538 - cross-spawn Vulnerability in Node.js

**Alert ID:** #2  
**Affected Component:** `/home/runner/externals/node20` (cross-spawn package)

**Severity:** Medium  
**CVSS Score:** [Score from CVE database]  
**CWE:** [Weakness type from CVE database]

#### Vulnerability Description
CVE-2024-21538 affects the cross-spawn npm package used within the Node.js runtime included in the GitHub Actions runner. This vulnerability could potentially allow command injection under specific conditions.

#### Risk Assessment

**Threat Context:**
- Affects Node.js execution environment within runners
- Limited to workflows that execute Node.js code
- Exploitation requires ability to control command execution parameters

**Impact Analysis:**
- **Confidentiality:** Medium - Could access runner environment variables
- **Integrity:** Medium - Could modify workflow execution
- **Availability:** Low - Unlikely to affect overall availability

**Exploitability:**
- Requires malicious or compromised workflow code
- Limited by our workflow security policies
- Mitigated by runner isolation and lifecycle management

#### Justification for Dismissal

**Primary Reasons:**
1. **Node.js Runtime Dependency:** cross-spawn is a core dependency of the Node.js runtime provided by GitHub
2. **Workflow-Level Risk:** Risk is primarily at the workflow execution level, not infrastructure level
3. **Isolation Benefits:** Ephemeral runners limit blast radius of potential exploitation
4. **Vendor Responsibility:** Node.js runtime updates are managed by GitHub's base image

**Risk Acceptance Criteria:**
- Impact limited to individual workflow executions
- Runner isolation prevents lateral movement
- Automated runner recycling limits persistence
- No feasible alternative without breaking Node.js workflow compatibility

#### Compensating Controls

**Workflow Security:**
- Workflow permissions follow principle of least privilege
- Repository access controls limit who can execute workflows
- Branch protection rules prevent unauthorized workflow modifications
- Workflow content scanning for suspicious patterns

**Runtime Isolation:**
- Each workflow execution in isolated container environment
- No persistent state between workflow runs
- Automated cleanup of runner environments
- Network restrictions prevent external communication

**Monitoring and Detection:**
- Workflow execution logging and monitoring
- Anomaly detection for unusual command patterns
- Real-time security scanning of workflow outputs
- Automated alerting for suspicious activities

#### Mitigation Strategies

**Immediate Actions:**
1. Enhanced workflow content review processes
2. Automated scanning for high-risk command patterns
3. Stricter network egress policies for Node.js workflows
4. Regular audit of workflow permissions and access patterns

**Long-term Monitoring:**
1. Subscribe to Node.js security advisories
2. Track GitHub's base image updates for Node.js runtime fixes
3. Implement additional workflow sandbox controls where feasible
4. Regular review of workflow security policies

---

## Risk Management Process

### Quarterly Review Process

**Review Schedule:** Every quarter (January, April, July, October)  
**Review Team:** Security Team, DevOps Team, Platform Engineering  
**Review Criteria:**
- Changes in threat landscape
- New security controls available
- Updated base images from GitHub
- Changes in business risk tolerance
- Incident learnings and security events

### Escalation Criteria

**Immediate Re-evaluation Required When:**
- New exploit techniques are published for dismissed CVEs
- GitHub releases critical security updates for base images
- Security incidents related to dismissed vulnerabilities occur
- Regulatory or compliance requirements change
- Business risk tolerance decreases

### Documentation Updates

**Update Triggers:**
- New vulnerabilities dismissed
- Changes in risk assessment
- Implementation of new compensating controls
- Results of quarterly reviews
- Security incident learnings

---

## GitHub CLI Dismissal Commands

Use these commands to programmatically dismiss the security alerts:

### CVE-2025-47907 Alerts (Container Runtime Components)

```bash
# Alert #11 - CVE-2025-47907 in usr/bin/runc
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/11 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #10 - CVE-2025-47907 in usr/bin/dockerd  
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/10 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #8 - CVE-2025-47907 in usr/bin/docker-proxy
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/8 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #6 - CVE-2025-47907 in usr/bin/docker
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/6 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #5 - CVE-2025-47907 in usr/bin/ctr
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/5 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #4 - CVE-2025-47907 in usr/bin/containerd-shim-runc-v2
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/4 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

# Alert #3 - CVE-2025-47907 in usr/bin/containerd
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/3 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."
```

### CVE-2024-21538 Alert (Node.js cross-spawn)

```bash
# Alert #2 - CVE-2024-21538 in home/runner/externals/node20 (cross-spawn)
gh api repos/redducklabs/redducklabs-runners/code-scanning/alerts/2 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="Risk accepted - Node.js runtime dependency from GitHub Actions runner base image (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking workflow compatibility. Workflow-level risk mitigated by runner isolation and ephemeral execution model. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."
```

### Batch Dismissal Script

For convenience, you can create a script to dismiss all alerts at once:

```bash
#!/bin/bash
# File: dismiss-base-image-vulnerabilities.sh

set -e

REPO="redducklabs/redducklabs-runners"
BASE_COMMENT_CVE_47907="Risk accepted - Base image dependency from GitHub Actions runner (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking runner compatibility. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."
BASE_COMMENT_CVE_21538="Risk accepted - Node.js runtime dependency from GitHub Actions runner base image (ghcr.io/actions/actions-runner:latest) that cannot be modified without breaking workflow compatibility. Workflow-level risk mitigated by runner isolation and ephemeral execution model. See SECURITY-DISMISSALS.md for full risk assessment and compensating controls."

echo "Dismissing CVE-2025-47907 alerts (container runtime components)..."

# CVE-2025-47907 alerts
for alert_id in 11 10 8 6 5 4 3; do
  echo "Dismissing alert #${alert_id}..."
  gh api repos/${REPO}/code-scanning/alerts/${alert_id} \
    --method PATCH \
    --field state=dismissed \
    --field dismissed_reason=won_t_fix \
    --field dismissed_comment="${BASE_COMMENT_CVE_47907}"
  
  echo "Alert #${alert_id} dismissed successfully"
  sleep 1  # Rate limiting courtesy
done

echo "Dismissing CVE-2024-21538 alert (Node.js cross-spawn)..."

# CVE-2024-21538 alert
gh api repos/${REPO}/code-scanning/alerts/2 \
  --method PATCH \
  --field state=dismissed \
  --field dismissed_reason=won_t_fix \
  --field dismissed_comment="${BASE_COMMENT_CVE_21538}"

echo "Alert #2 dismissed successfully"

echo "All base image vulnerability alerts have been dismissed."
echo "Review the security assessments in SECURITY-DISMISSALS.md"
echo "Next quarterly review scheduled for: $(date -d '+3 months' '+%B %Y')"
```

**Usage:**
```bash
chmod +x dismiss-base-image-vulnerabilities.sh
./dismiss-base-image-vulnerabilities.sh
```

---

## Implementation Checklist

### Pre-Dismissal Actions
- [ ] Vulnerability impact assessment completed
- [ ] Compensating controls documented and verified
- [ ] Business risk acceptance obtained from security team
- [ ] Alternative solutions evaluated and documented
- [ ] Monitoring and detection capabilities verified

### Dismissal Actions
- [ ] Security alerts dismissed using GitHub CLI commands
- [ ] Dismissal comments include reference to this documentation
- [ ] Security team notified of dismissals
- [ ] Risk register updated with accepted risks

### Post-Dismissal Actions
- [ ] Quarterly review scheduled
- [ ] Monitoring alerts configured for related security events
- [ ] Team training completed on accepted risks and controls
- [ ] Documentation added to security runbooks
- [ ] Incident response procedures updated if necessary

---

## Contact Information

**Security Team:**
- Email: security@redducklabs.com
- Slack: #security-team
- Emergency: Follow incident response procedures in `docs/SECURITY.md`

**Review Schedule:**
- Next Review: [To be scheduled after implementation]
- Review Frequency: Quarterly
- Emergency Review: As needed based on threat landscape changes

---

*Document Version: 1.0*  
*Created: August 21, 2025*  
*Last Updated: August 21, 2025*  
*Next Review: November 21, 2025*