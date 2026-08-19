# Runbook: Runner Node Pool Sizing

How to change how many GitHub Actions runners can run concurrently, and how much
memory each one gets.

- **Cluster:** `redducklabs-cluster` (context `do-sfo3-redducklabs-cluster`, region sfo3)
- **Pool:** `github-runners-pool-16g`
- **Node size:** `s-8vcpu-16gb` — 8 vCPU, 16 GB, **$96/node/month**
- **Pool labels/taints:** `node-type=github-runner`, `workload-type=ci-cd`,
  taint `github-runner=true:NoSchedule`

## The invariant: one runner pod per node

This is the single most important thing to understand before changing anything.

The runner pod requests `5Gi` (runner container) + `5Gi` (dind sidecar) = **10Gi
of memory requests**. Node allocatable is **13.32Gi**. Two pods would need 20Gi,
so the scheduler can only ever fit **one runner pod per node**, and the
cluster-autoscaler adds a node for each additional concurrent job.

That is deliberate. It is what stops one job's `docker build` from starving a
neighbouring job's, which was the cause of the intermittent out-of-memory
failures this design replaced.

It means the pool bounds and the scale set bounds are coupled:

```
min_nodes >= minRunners        max_nodes >= maxRunners
```

`deploy/dind-values.yaml` is the source of truth for `minRunners`/`maxRunners`.
The sizing workflow refuses to apply bounds that violate the invariant.

## Current configuration

| Setting | Value | Where it lives |
|---|---|---|
| `minRunners` | 2 | `deploy/dind-values.yaml` |
| `maxRunners` | 8 | `deploy/dind-values.yaml` |
| `min_nodes` | 2 | node pool (applied by the workflow below) |
| `max_nodes` | 8 | node pool (applied by the workflow below) |
| Per job | ~12.5Gi usable, 8 vCPU | `deploy/dind-values.yaml` resources |

**Cost floor: $192/month** (2 nodes always running).
**Cost ceiling: $768/month** (8 nodes, only while 8 jobs run concurrently).

## Changing concurrency

Concurrency is capped by `maxRunners` *and* by `max_nodes`. Raising one without
the other does nothing useful — the extra runners just sit `Pending`.

### 1. Change the scale set bounds

Edit `deploy/dind-values.yaml`:

```yaml
minRunners: 2
maxRunners: 8
```

Commit and open a PR. Then deploy via the **Deploy GitHub Runners** workflow
(`.github/workflows/deploy-runners.yml`), setting `min_runners`/`max_runners` to
the same numbers.

### 2. Change the pool bounds

Run the **Node Pool Sizing** workflow
(`.github/workflows/node-pool-sizing.yml`):

```
Actions -> Node Pool Sizing -> Run workflow
  min_nodes: 2
  max_nodes: 8
  pool_name: github-runners-pool-16g
  apply:     (leave unchecked for a dry run first)
```

Run it once with `apply` unchecked to see the before/after, then again with
`apply` checked. The workflow validates the inputs against
`deploy/dind-values.yaml`, applies the change, and then verifies that
autoscaling is still enabled and that the pool's labels and taints survived.

### Fallback: apply by hand

Only if the workflow is unavailable. Read the DigitalOcean guidance in the
project instructions before mutating production by hand.

```bash
CLUSTER_ID=$(doctl kubernetes cluster list -o json \
  | jq -r '.[] | select(.name=="redducklabs-cluster") | .id')

POOL_ID=$(doctl kubernetes cluster node-pool list "$CLUSTER_ID" -o json \
  | jq -r '.[] | select(.name=="github-runners-pool-16g") | .id')

# --auto-scale MUST be passed. Omitting it can clear autoscaling and pin the
# pool to a fixed node count.
doctl kubernetes cluster node-pool update "$CLUSTER_ID" "$POOL_ID" \
  --auto-scale --min-nodes 2 --max-nodes 8

# Verify, including that labels and taints survived
doctl kubernetes cluster node-pool list "$CLUSTER_ID" -o json \
  | jq '.[] | select(.name=="github-runners-pool-16g")
        | {auto_scale, min_nodes, max_nodes, count, labels, taints}'
```

If the label `node-type=github-runner` or the taint `github-runner=true:NoSchedule`
is missing after an update, **fix it immediately** — without them, runner pods
cannot schedule onto the pool, and production workloads can schedule onto it.

## Changing memory per job

Per-job memory is set by the `resources` blocks in `deploy/dind-values.yaml`:

- `runner` container — memory for work run **directly** on the runner
  (npm, jest, webpack, pytest, go build).
- `dind` sidecar — memory for everything run **inside Docker**
  (`docker build`, compose, testcontainers).

Both are capped at `10Gi` with `5Gi` requested. The requests are what force one
pod per node; the limits are what a job can actually consume.

**Before raising a limit**, check which container is actually running out — see
"Diagnosing an OOM" below. Raising the wrong one changes nothing.

**Before raising the requests**, note the budget: node allocatable is 13.32Gi and
system DaemonSets take ~0.68Gi, leaving **~12.64Gi**. Total requests must stay
comfortably under that or pods stop scheduling entirely.

To go beyond ~12.5Gi per job you need a bigger node size, which is a pool
replacement, not a resize. `m-8vcpu-64gb` ($336/mo) is the cheapest memory on
DigitalOcean at $5.25/GB.

## Diagnosing an OOM

Both containers now have explicit memory limits, so **an OOM names the container
that overran**:

- `runner` OOMKilled → the job process itself. Raise the `runner` limit, or
  lower the job's own concurrency (e.g. Jest `--maxWorkers`).
- `dind` OOMKilled → a Docker build. Raise the `dind` limit.

```bash
kubectl config use-context do-sfo3-redducklabs-cluster

# Live memory use per container
kubectl top pods -n arc-runners --containers

# Node headroom
kubectl top nodes

# OOM kills and evictions (runner pods are ephemeral, so check promptly)
kubectl get events -n arc-runners --sort-by=.lastTimestamp \
  | grep -Ei 'oom|evict'
```

The scheduled **Runner Status** workflow also reports OOMKilled and evicted
runners plus node memory headroom on every run.

`kubectl top` depends on metrics-server, which is deployed by the
**Deploy Cluster Addons** workflow (`.github/workflows/deploy-cluster-addons.yml`).

## Trade-offs when tuning

| Change | Effect | Cost |
|---|---|---|
| Raise `max_nodes` + `maxRunners` | More concurrent jobs | Ceiling only; you pay per node actually running |
| Raise `min_nodes` + `minRunners` | Less queueing — jobs start without waiting for a node | **Floor**; billed continuously |
| Raise container limits | More memory per job | Free until it forces a bigger node size |
| Bigger node size | More memory per job | Pool replacement; per-node price change |

The latency trade-off is worth stating plainly: at one pod per node, **any job
beyond the warm pool waits for DigitalOcean to provision a node and pull the
~1.34GB runner image.** `minRunners`/`min_nodes` is the dial that buys that
latency away with money. Raise it if queueing hurts more than the bill.

## Rollback

Re-run the **Node Pool Sizing** workflow with the previous bounds. The pool is
autoscaled, so lowering `max_nodes` does not destroy running jobs — the
autoscaler drains surplus nodes as jobs finish. Lowering `min_nodes` takes
effect once nodes go idle.

If you need to stop everything, use the **Emergency Stop** workflow rather than
resizing the pool to zero; DigitalOcean autoscaling pools cannot scale below one
node.
