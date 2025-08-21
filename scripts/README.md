# GitHub Actions Runner Management Scripts

This directory contains scripts for managing and scaling redducklabs GitHub Actions runners.

## Prerequisites

Before using these scripts:
```bash
export GITHUB_TOKEN=ghp_your_token_here
```

Ensure you have access to the redducklabs Kubernetes cluster:
```bash
kubectl config use-context do-sfo3-redducklabs-cluster
```

## Available Scripts

### 📊 scale-runners.sh
Main scaling script with full control over runner count.

```bash
# Check current status
./scale-runners.sh status

# Scale to default (2 min, 4 max)
./scale-runners.sh up

# Scale to zero for maintenance
./scale-runners.sh down

# Scale to maximum capacity (4 min, 8 max)
./scale-runners.sh max

# Custom scaling
./scale-runners.sh scale 3 6  # 3 min, 6 max
```

### 🎛️ runner-admin.sh
Interactive menu for runner administration.

```bash
./runner-admin.sh
```

Features:
- View runner status
- Scale runners (default/max/custom)
- Restart all runners
- View logs
- Clean up terminated pods
- Check GitHub registration

### 🚨 emergency-stop.sh
Emergency shutdown for all runners.

```bash
./emergency-stop.sh
```

**USE WITH CAUTION!** This will:
- Scale runners to zero immediately
- Force delete all runner pods
- Requires typing 'STOP' to confirm

### 🔒 dismiss-base-image-vulnerabilities.sh
Security alert dismissal script for base image vulnerabilities.

```bash
./dismiss-base-image-vulnerabilities.sh
```

**Purpose:** Dismisses security alerts that originate from the official GitHub Actions runner base image (`ghcr.io/actions/actions-runner:latest`) and cannot be fixed without breaking runner compatibility.

**Covered Vulnerabilities:**
- CVE-2025-47907: Container runtime components (alerts 11,10,8,6,5,4,3)
- CVE-2024-21538: Node.js cross-spawn vulnerability (alert 2)

**Features:**
- Interactive confirmation prompts
- Batch dismissal of multiple alerts
- Detailed dismissal comments with risk justification
- Verification of dismissal success
- Links to comprehensive risk assessment in `SECURITY-DISMISSALS.md`

**Requirements:**
- GitHub CLI (`gh`) installed and authenticated
- Repository admin permissions for security alert management
- Review and approval of risk acceptance in `SECURITY-DISMISSALS.md`

## Common Operations

### Scale for high load
```bash
./scale-runners.sh max  # 4-8 runners
```

### Maintenance mode
```bash
# Scale down
./scale-runners.sh down

# Do maintenance...

# Scale back up
./scale-runners.sh up
```

### Check runner health
```bash
./scale-runners.sh status
```

### Restart stuck runners
```bash
kubectl delete pod <pod-name> -n arc-runners
# New pod will be created automatically
```

## Scaling Guidelines for redducklabs

| Scenario | Min | Max | Command |
|----------|-----|-----|---------|
| Normal operation | 2 | 4 | `./scale-runners.sh up` |
| High load | 4 | 8 | `./scale-runners.sh max` |
| Maintenance | 0 | 0 | `./scale-runners.sh down` |
| Cost saving | 1 | 2 | `./scale-runners.sh scale 1 2` |
| CI/CD pipeline | 3 | 6 | `./scale-runners.sh scale 3 6` |

## Troubleshooting

### Runners not scaling up
- Check GitHub token is valid
- Verify namespace exists: `kubectl get ns arc-runners`
- Check controller logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=controller`

### Stuck runners
- Force delete: `kubectl delete pod <name> -n arc-runners --force`
- Use emergency stop if multiple stuck: `./emergency-stop.sh`

### Jobs not being picked up
- Verify runners are online: `./scale-runners.sh status`
- Check workflow uses: `runs-on: redducklabs-runners`
- Ensure minRunners > 0

## Production Configuration

All scripts are configured for redducklabs production environment:
- Namespace: `arc-runners`
- Release name: `redducklabs-runners`
- Cluster context: `do-sfo3-redducklabs-cluster`
- Runner label: `redducklabs-runners`

## Security Notes

- Never commit GitHub tokens to git
- All scripts require GITHUB_TOKEN environment variable
- Scripts include error handling and confirmation prompts
- Emergency stop requires explicit confirmation

## Notes

- Scaling changes take 30-60 seconds to fully apply
- Runners are ephemeral - they restart after each job
- Docker-in-Docker pods show as 2/2 (runner + dind sidecar)
- Maximum recommended runners: 10 (cluster capacity)
- All scripts include colored output for better visibility