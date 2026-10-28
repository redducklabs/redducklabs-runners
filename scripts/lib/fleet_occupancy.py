#!/usr/bin/env python3
"""Report where runner pods sit and how many burst nodes exist.

Read-only helper for scripts/drain-runners.sh and scripts/acceptance-phase-c.sh.
It prints one JSON object on stdout:

  {
    "runners": <EphemeralRunners not being deleted>,
    "runner_pods": {"baseline": n, "burst": n, "other": n, "unscheduled": n},
    "ready_idle": {"baseline": n, "burst": n},
    "burst_nodes": <registered Kubernetes nodes in the burst pools>,
    "burst_pool_counts": {"<primary>": count|null, "<fallback>": count|null}
  }

runner_pods counts non-terminal pods of the redducklabs-runners scale set by
the pool of the node they are bound to. A pod is "ready idle" when it is
Running with condition Ready=True and its EphemeralRunner records no job (the
same job fields scripts/lib/retire_idle_runners.py treats as busy). A burst
pool that does not exist reports count null.

Reads: Kubernetes nodes, runner pods, EphemeralRunners, then the DigitalOcean
cluster and its node pools. Exit codes: 0 report printed, 1 a read failed or
returned something unparseable, 2 usage error.
"""

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import runner_pool_state as pool_state  # noqa: E402
import retire_idle_runners as retire  # noqa: E402

BURST_POOLS = (pool_state.PRIMARY, pool_state.FALLBACK)


def pod_ready(pod):
    status = pod.get("status") or {}
    if status.get("phase") != "Running":
        return False
    return any(
        c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions") or []
    )


def report(cluster_name):
    nodes = pool_state.items_of(pool_state.run_json(["kubectl", "get", "nodes", "-o", "json"]), "node list")
    pods = pool_state.items_of(
        pool_state.run_json([
            "kubectl", "get", "pods", "-n", pool_state.NAMESPACE,
            "-l", f"{pool_state.SCALE_SET_LABEL}={pool_state.RELEASE}", "-o", "json",
        ]),
        "runner pod list",
    )
    ephemeral = pool_state.items_of(
        pool_state.run_json([
            "kubectl", "get", "ephemeralrunners.actions.github.com", "-n", pool_state.NAMESPACE, "-o", "json",
        ]),
        "EphemeralRunner list",
    )
    clusters = pool_state.run_json(["doctl", "kubernetes", "cluster", "list", "-o", "json"])
    if not isinstance(clusters, list):
        raise pool_state.ReadError("doctl cluster list is not a JSON array")
    matches = [c for c in clusters if isinstance(c, dict) and c.get("name") == cluster_name]
    if len(matches) != 1 or not isinstance(matches[0].get("id"), str) or not matches[0]["id"]:
        raise pool_state.ReadError(f"cluster '{cluster_name}' must resolve to exactly one DigitalOcean cluster")
    pools = pool_state.normalize_pool_list(
        pool_state.run_json(["doctl", "kubernetes", "cluster", "node-pool", "list", matches[0]["id"], "-o", "json"])
    )
    if not isinstance(pools, list) or not all(isinstance(p, dict) for p in pools):
        raise pool_state.ReadError("doctl node-pool list is not a JSON array of pools")

    node_pool = {}
    burst_nodes = 0
    for node in nodes:
        metadata = node.get("metadata") or {}
        pool = (metadata.get("labels") or {}).get(pool_state.POOL_LABEL)
        if isinstance(metadata.get("name"), str):
            node_pool[metadata["name"]] = pool
        if pool in BURST_POOLS:
            burst_nodes += 1

    job_by_runner = {}
    runners = 0
    for runner in ephemeral:
        metadata = runner.get("metadata") or {}
        if metadata.get("deletionTimestamp"):
            continue
        runners += 1
        job_by_runner[metadata.get("name")] = retire.has_job(runner.get("status") or {})

    runner_pods = {"baseline": 0, "burst": 0, "other": 0, "unscheduled": 0}
    ready_idle = {"baseline": 0, "burst": 0}
    for pod in pods:
        metadata = pod.get("metadata") or {}
        if metadata.get("namespace") != pool_state.NAMESPACE \
                or (metadata.get("labels") or {}).get(pool_state.SCALE_SET_LABEL) != pool_state.RELEASE:
            continue
        if (pod.get("status") or {}).get("phase") in retire.TERMINAL_PHASES:
            continue
        node_name = (pod.get("spec") or {}).get("nodeName")
        if not isinstance(node_name, str) or not node_name:
            runner_pods["unscheduled"] += 1
            continue
        pool = node_pool.get(node_name)
        where = "baseline" if pool == pool_state.BASELINE else "burst" if pool in BURST_POOLS else "other"
        runner_pods[where] += 1
        # A pod whose EphemeralRunner is unknown is never counted as idle.
        if where in ready_idle and pod_ready(pod) and job_by_runner.get(metadata.get("name")) is False:
            ready_idle[where] += 1

    counts = {}
    for name in BURST_POOLS:
        found = [p for p in pools if p.get("name") == name]
        if len(found) > 1:
            raise pool_state.ReadError(f"node pool name '{name}' is not unique")
        count = found[0].get("count") if found else None
        if found and not pool_state.is_int(count):
            raise pool_state.ReadError(f"node pool '{name}' has a non-integer count")
        counts[name] = count
    return {
        "runners": runners,
        "runner_pods": runner_pods,
        "ready_idle": ready_idle,
        "burst_nodes": burst_nodes,
        "burst_pool_counts": counts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cluster-name", required=True)
    try:
        args = parser.parse_args()
    except SystemExit:
        return 2
    if not pool_state.CLUSTER_NAME_RE.match(args.cluster_name):
        print(f"ERROR: invalid cluster name '{args.cluster_name}'", file=sys.stderr)
        return 2
    try:
        result = report(args.cluster_name)
    except pool_state.ReadError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
