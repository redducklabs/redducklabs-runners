# Runner Capacity and Memory Design

**Date:** 2026-08-19
**Status:** Implemented
**Scope:** Runner concurrency ceiling, per-job memory, and OOM attribution.

Toolchain and chart version upgrades are explicitly **out of scope** and are
tracked as separate work.

## Problem

Two symptoms, reported together:

1. Frequent "low memory" failures in CI jobs.
2. Not enough runners - jobs queued behind a concurrency ceiling.

## Diagnosis

Measured against the live cluster (`do-sfo3-redducklabs-cluster`,
pool `github-runners-pool-16g`, `s-8vcpu-16gb`):

| | Before |
|---|---|
| Node allocatable | 13.32 GiB, 7880m CPU |
| System pod memory requests | ~0.68 GiB |
| `runner` container | requests 5Gi, limits 6Gi / 3 CPU |
| `dind` sidecar | **no requests, no limits** |
| Pods per node | 2 |
| Node memory requests | 10934Mi (80% of allocatable) |
| Scale set | `minRunners: 2`, `maxRunners: 6` - observed saturated at 6/6 |
| Node pool | autoscaling 1-4 nodes |

### There were two distinct failure mechanisms

**1. The runner container's hard cap.** Work run directly on the runner (npm,
jest, webpack, pytest, go build) hit the 6Gi cgroup limit and was cleanly
OOMKilled.

**2. The unbounded Docker daemon - the dominant cause.** Everything run inside
Docker (`docker build`, compose, testcontainers) is charged to the `dind`
sidecar, which had **no memory request and no memory limit**. Per node, two
runner pods reserved 10Gi of 13.32Gi and system pods took ~0.68Gi, leaving
**~2.6 GiB unreserved, shared between both nodes' Docker daemons**.

A Docker build's available memory therefore depended on what the *other* runner
on the same node happened to be doing, and because `dind` requested nothing it
was the first candidate for the kernel OOM killer. That non-determinism is why
the failures felt constant and could not be attributed to any one job.

Critically: **raising the runner limit alone would have made mechanism 2 worse**,
by reserving more of the node and starving `dind` further.

### Concurrency was also under-provisioned twice over

`maxRunners: 6` against a pool that could already provision 4 nodes x 2 pods =
8 runner slots. Two slots were unused at zero cost.

## Constraint discovered

ARC's `containerMode.type: "dind"` renders the Docker sidecar from a **hardcoded
chart template with no `resources` field**, and a user-supplied container named
`dind` is explicitly filtered out of values by the
`gha-runner-scale-set.non-runner-non-dind-containers` helper.

Verified in chart **0.12.1** (deployed) and **0.14.2** (current). There is no
values-level way to give the Docker daemon a memory reservation while
`containerMode.type: "dind"` is set.

## Decision

Drop `containerMode.type: "dind"` and declare the Docker sidecar explicitly in
`template.spec.initContainers` (the chart's "default" container mode, which
renders `initContainers`, `containers` and `volumes` verbatim). This is the only
mechanism that permits `resources` on the daemon.

### Resulting configuration

| | Requests | Limits |
|---|---|---|
| `runner` | 5Gi, 2 CPU | 10Gi, no CPU limit |
| `dind` | 5Gi, 1 CPU | 10Gi, no CPU limit |

| | Before | After |
|---|---|---|
| Concurrent runners | 6 | **8** |
| Pods per node | 2 | **1** |
| Memory per job | 6Gi hard cap + ~2.6Gi contended | **~12.5Gi across two reserved budgets** |
| CPU per job | 3 of 8 vCPU | **8 vCPU** |
| Node pool bounds | 1-4 nodes | **2-8 nodes** |
| Cost floor / ceiling | $96 / $384 per month | **$192 / $768 per month** |

### Rationale for the specific numbers

**Requests of 5Gi + 5Gi = 10Gi** force exactly one pod per node: two pods would
require 20Gi against 13.32Gi allocatable. One pod per node is the structural fix
- it removes the noisy neighbour entirely rather than merely bounding it.

Requests were deliberately set *below* the ~12.64Gi available budget rather than
at it. 6Gi + 6Gi would have left only ~0.64Gi of slack, so a single additional
DaemonSet could block scheduling. Since one-pod-per-node is already guaranteed
by anything above 6.32Gi total, the extra reservation would buy nothing.

**Limits of 10Gi + 10Gi are intentionally overcommitted** against the ~12.64Gi
node budget. This lets a runner-heavy job use ~10Gi on the runner while dockerd
idles, and a Docker-heavy job do the reverse. With one pod per node, the only
workload exposed to that overcommit is the job itself.

**No CPU limit.** With one pod per node there is nothing to protect, and the
previous 3-CPU limit throttled builds to 3 of 8 available cores.

### OOM attribution

Because both containers now carry explicit limits, an OOM kill names the
container that overran: `runner` means the job process, `dind` means a Docker
build. This was the specific requirement, as the dominant failure mode was not
known in advance.

## Alternatives considered

| Option | Outcome | Why not |
|---|---|---|
| **A.** 2 pods/node with an explicit dind reservation, pool to 8 nodes | 12 concurrent x ~6Gi | Same cost ceiling as the chosen option but bounds contention rather than removing it, and only marginally raises per-job memory |
| **C.** Move to `m-8vcpu-64gb` ($336/mo, cheapest RAM on DigitalOcean at $5.25/GB), 4 pods/node | 12 concurrent x ~14Gi | Higher ceiling ($1008/mo) and only 2 vCPU per job |
| **D.** Tiered pools with an opt-in `-xl` scale set | Varies | Best only if a small, known set of workflows are the memory hogs; that was not established |
| Raise the runner limit only | - | Does not address the dominant failure mode, and worsens it by starving dind further |
| `g-8vcpu-32gb` | - | $7.88/GB, strictly dominated by both `s-8vcpu-16gb` ($6/GB) and `m-8vcpu-64gb` ($5.25/GB) |

## Supporting changes

- **metrics-server deployed.** It was absent, so `kubectl top` did not work and
  there was no memory visibility at all. Verified serving with TLS verification
  fully enabled - `--kubelet-insecure-tls` is **not** required on this DOKS
  cluster and is deliberately not set.
- **Node pool sizing moved into code.** The pool's bounds previously existed
  only as a comment while the real values were set by hand. Now applied by
  `.github/workflows/node-pool-sizing.yml`, which validates the bounds against
  `deploy/dind-values.yaml` and verifies that pool labels and taints survive.
- **Capacity drift detection.** `deploy-runners.yml` and `runner-status.yml`
  both warn when `maxRunners` exceeds the pool's `max_nodes`, which would
  otherwise leave runners `Pending` with no obvious cause.
- **`docker:dind` pinned** to `docker:29.7.2-dind`. The chart used a floating
  tag; 29.7.2 is what it already resolved to, so this is a reproducibility fix
  and not a behavioural change.

## Verification performed

- Rendered `deploy/dind-values.yaml` with `helm template` (chart 0.12.1,
  `--kube-version 1.33.12`) and diffed the pod spec against a render of the
  previous `containerMode: "dind"` configuration. The **only** differences are
  the four intended ones: runner resources, dind resources, the pinned dind
  image, and volume ordering. Environment variables, volume mounts,
  `securityContext`, `startupProbe`, `serviceAccountName`, `restartPolicy`,
  tolerations, `nodeSelector`, `imagePullSecrets` and the init container are
  byte-identical, as is the set of rendered resource kinds.
- Node pool resized and re-read: `auto_scale=true min=2 max=8`, labels and
  taints intact.
- metrics-server deployed and confirmed serving `kubectl top nodes` and
  `kubectl top pods --containers`, both before and after applying the committed
  values file. Rendered container args checked for duplicate flags.
- YAML parse check across all workflows and values files; `bash -n` across all
  scripts.

## Known trade-off

At one pod per node, **any job beyond the warm pool waits for DigitalOcean to
provision a node and pull the ~1.34GB runner image**. Previously every second
job landed on an already-running node. `minRunners`/`min_nodes` is the dial that
buys that latency back with money; it is a one-line change in
`deploy/dind-values.yaml` plus a **Node Pool Sizing** run.

## Follow-up work (separate change)

- ARC chart 0.12.1 -> 0.14.2 (controller and scale set). On upgrade, re-render
  and re-diff the pod spec, since this design moves ownership of the dind
  sidecar from the chart to this repository.
- DOKS 1.33.12 -> 1.36.3. Note the `restartPolicy: Always` native sidecar
  requires >= 1.29.
- Dockerfile toolchain version sweep.
