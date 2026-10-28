#!/usr/bin/env python3
"""Plan which idle EphemeralRunners to retire from burst nodes.

Invoked by scripts/retire-idle-burst-runners.sh after the ARC identity check.
This helper is read-only: it prints one JSON plan on stdout and the script
performs the deletions. Reads happen in a fixed order - Kubernetes first
(nodes, runner pods, EphemeralRunners), GitHub last - so a job assigned after
the Kubernetes read is visible as busy=true in the GitHub read.

A runner is a candidate only when every one of these holds:
  - it is not already being deleted and has a creationTimestamp;
  - its pod exists in arc-runners and is not terminal;
  - the pod's node is in a burst pool (pool membership comes from the node
    label, with pool names defined in runner_pool_state.py);
  - the EphemeralRunner records no job (status.jobRequestId empty or 0, and
    none of the other job fields set);
  - the GitHub runner with the same name as status.runnerName exists and has
    busy == false.
Anything unknown (no pod, no node, no runnerName, not listed by GitHub) is kept.

Free baseline slots = 2 x Ready baseline nodes, minus runner pods on baseline
(terminating ones included), minus unscheduled non-terminal runner pods, minus
EphemeralRunners (not being deleted) that have no live pod yet.

Exit codes: 0 plan printed, 1 a read failed or returned something unparseable.
"""

import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import runner_pool_state as pool_state  # noqa: E402

ORG = "redducklabs"
RUNNERS_ENDPOINT = f"orgs/{ORG}/actions/runners?per_page=100"
NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
BURST_POOLS = (pool_state.PRIMARY, pool_state.FALLBACK)
TERMINAL_PHASES = ("Succeeded", "Failed")
# EphemeralRunner status fields that are only set once a job is assigned.
JOB_FIELDS = ("jobRequestId", "jobId", "jobRepositoryName", "jobWorkflowRef", "workflowRunId")


def read_github_runners():
    """Return {runner name: [busy flags]} from every page of the org runner list."""
    text = pool_state.run(["gh", "api", "--paginate", RUNNERS_ENDPOINT])
    decoder = json.JSONDecoder()
    position, pages = 0, []
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if position >= len(text):
            break
        try:
            page, position = decoder.raw_decode(text, position)
        except json.JSONDecodeError as error:
            raise pool_state.ReadError(f"GitHub runner list is not JSON: {error}") from error
        pages.append(page)
    if not pages:
        raise pool_state.ReadError("GitHub runner list is empty")
    runners = {}
    count = 0
    for page in pages:
        listed = page.get("runners") if isinstance(page, dict) else None
        if not isinstance(listed, list) or not all(isinstance(r, dict) for r in listed):
            raise pool_state.ReadError("GitHub runner page has no runners list")
        for runner in listed:
            if not isinstance(runner.get("name"), str) or not isinstance(runner.get("busy"), bool):
                raise pool_state.ReadError("GitHub runner entry lacks a string name or boolean busy")
            runners.setdefault(runner["name"], []).append(runner["busy"])
            count += 1
    total = pages[-1].get("total_count")
    if not pool_state.is_int(total) or total != count:
        raise pool_state.ReadError(
            f"GitHub runner list is incomplete: collected {count} runners, total_count is {total!r}"
        )
    return runners


def has_job(status):
    for field in JOB_FIELDS:
        value = status.get(field)
        if value in (None, "", 0, "0", False):
            continue
        return True
    return False


def plan():
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
    github = read_github_runners()  # after every Kubernetes read

    node_pool = {}
    ready_baseline = 0
    for node in nodes:
        name = (node.get("metadata") or {}).get("name")
        pool = ((node.get("metadata") or {}).get("labels") or {}).get(pool_state.POOL_LABEL)
        if isinstance(name, str) and isinstance(pool, str):
            node_pool[name] = pool
            if pool == pool_state.BASELINE and pool_state.is_ready(node):
                ready_baseline += 1

    pod_node = {}  # live (non-terminal) runner pod name -> node name ("" while unscheduled)
    baseline_runner_pods = 0
    unscheduled_pods = 0
    for pod in pods:
        metadata = pod.get("metadata") or {}
        labels = metadata.get("labels") or {}
        if metadata.get("namespace") != pool_state.NAMESPACE \
                or labels.get(pool_state.SCALE_SET_LABEL) != pool_state.RELEASE:
            continue
        if (pod.get("status") or {}).get("phase") in TERMINAL_PHASES:
            continue
        node_name = (pod.get("spec") or {}).get("nodeName")
        if not isinstance(node_name, str) or not node_name:
            # Waiting to schedule: it will take a baseline slot if one is free.
            unscheduled_pods += 1
            pod_node[metadata.get("name")] = ""
            continue
        pod_node[metadata.get("name")] = node_name
        # A terminating pod still occupies its node, so it is counted.
        if node_pool.get(node_name) == pool_state.BASELINE:
            baseline_runner_pods += 1

    # An EphemeralRunner without a live pod is about to get one, and that pod
    # will also compete for baseline.
    podless_runners = 0
    for runner in ephemeral:
        metadata = runner.get("metadata") or {}
        if not metadata.get("deletionTimestamp") and metadata.get("name") not in pod_node:
            podless_runners += 1

    free = max(0, 2 * ready_baseline - baseline_runner_pods - unscheduled_pods - podless_runners)

    candidates = []
    for runner in ephemeral:
        metadata = runner.get("metadata") or {}
        status = runner.get("status") or {}
        name = metadata.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name) or metadata.get("deletionTimestamp"):
            continue
        created = metadata.get("creationTimestamp")
        if not isinstance(created, str) or not created:
            continue  # age unknown: never treat it as the oldest
        if node_pool.get(pod_node.get(name)) not in BURST_POOLS:
            continue
        if has_job(status):
            continue
        runner_name = status.get("runnerName")
        busy_flags = github.get(runner_name) if isinstance(runner_name, str) and runner_name else None
        if not busy_flags or any(busy_flags):
            continue
        candidates.append((created, name))
    candidates.sort()
    ordered = [name for _, name in candidates]
    return {"free_baseline_slots": free, "candidates": ordered, "select": ordered[:free]}


def main():
    try:
        result = plan()
    except pool_state.ReadError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
