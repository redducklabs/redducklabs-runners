# GitHub Actions Runner Management Scripts

This directory contains scripts for managing and scaling redducklabs GitHub Actions runners.

## Prerequisites

`scale-runners.sh` requires `GITHUB_TOKEN` (the other scripts use it where
noted below):
```bash
export GITHUB_TOKEN=ghp_your_token_here
```

Ensure you have access to the redducklabs Kubernetes cluster:
```bash
kubectl config use-context do-sfo3-redducklabs-cluster
```

Most scripts are committed without the executable bit, so on Linux/macOS run
them with `bash <path>` (for example `bash ./scale-runners.sh status`) or
`chmod +x` them first. `runner-admin.sh` calls `./scale-runners.sh` directly, so
run it from this directory with `scale-runners.sh` made executable.

## Available Scripts

### 📊 scale-runners.sh
Main scaling script with full control over runner count.

```bash
# Check current status
./scale-runners.sh status

# Scale to default (2 min, 8 max)
./scale-runners.sh up

# Scale to zero for maintenance (prompts y/N)
./scale-runners.sh down

# Scale to maximum warm capacity (4 min, 8 max) - MIN is billed continuously
./scale-runners.sh max

# Custom scaling
./scale-runners.sh scale 3 6  # 3 min, 6 max

# Show current minRunners/maxRunners from helm values
./scale-runners.sh get
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
- Check failed pods
- Clean up terminated pods
- Check GitHub registration (needs `GITHUB_TOKEN`)

### 🚨 emergency-stop.sh
Emergency shutdown for all runners.

```bash
./emergency-stop.sh
```

**USE WITH CAUTION!** This will:
- Scale runners to zero immediately
- Force delete all runner pods
- Requires typing 'STOP' to confirm

`GITHUB_TOKEN` is optional: without it the script warns and skips the GitHub
runner status check.

### 🔒 dismiss-base-image-vulnerabilities.sh
Security alert dismissal script for base image vulnerabilities.

```bash
./dismiss-base-image-vulnerabilities.sh
```

**Purpose:** Dismisses security alerts that originate from the official GitHub Actions runner base image (`ghcr.io/actions/actions-runner:2.336.0`, pinned via `ACTIONS_RUNNER_BASE`) and cannot be fixed without breaking runner compatibility.

**Covered Vulnerabilities:**
- CVE-2025-47907: Container runtime components (alerts 11,10,8,6,5,4,3)
- CVE-2024-21538: Node.js cross-spawn vulnerability (alert 2)

**Features:**
- Interactive confirmation prompts
- Batch dismissal of multiple alerts
- Detailed dismissal comments with risk justification
- Verification of dismissal success
- Links to comprehensive risk assessment in
  [`../docs/security/vulnerability-dismissals.md`](../docs/security/vulnerability-dismissals.md)

**Requirements:**
- GitHub CLI (`gh`) installed and authenticated (uses `gh auth`, not `GITHUB_TOKEN`)
- Repository admin permissions for security alert management
- Review and approval of risk acceptance in
  [`../docs/security/vulnerability-dismissals.md`](../docs/security/vulnerability-dismissals.md)

### launch-codex.sh
Starts `codex` from the repository root, passing all arguments through.

```bash
./launch-codex.sh [codex args]
```

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
| Normal operation | 2 | 8 | `./scale-runners.sh up` |
| High load | 4 | 8 | `./scale-runners.sh max` |
| Maintenance | 0 | 0 | `./scale-runners.sh down` |
| Cost saving | 1 | 2 | `./scale-runners.sh scale 1 2` |
| CI/CD pipeline | 3 | 6 | `./scale-runners.sh scale 3 6` |

## Troubleshooting

### Runners not scaling up
- Check GitHub token is valid
- Verify namespace exists: `kubectl get ns arc-runners`
- Check controller logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-rs-controller`

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
- `scale-runners.sh` requires the GITHUB_TOKEN environment variable; `runner-admin.sh` needs it for its scaling options (which call `scale-runners.sh`) and the GitHub registration checks; `emergency-stop.sh` runs without it; `dismiss-base-image-vulnerabilities.sh` uses `gh auth`
- Scripts include error handling and confirmation prompts
- Emergency stop requires explicit confirmation

## Notes

- Scaling changes apply asynchronously through ARC and Kubernetes
- Runners are ephemeral - they restart after each job
- Docker-in-Docker pods show as 2/2 (runner + dind sidecar)
- Maximum runners is capped by the runner pool's `max_nodes` (default 8, one runner pod per node); see [`../docs/runbooks/node-pool-sizing.md`](../docs/runbooks/node-pool-sizing.md)
- All scripts include colored output for better visibility
