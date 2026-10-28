#!/usr/bin/env python3
"""Runner pool-state evaluation for scripts/verify-runner-pool-state.sh.

Implements the "State contract for fleet workflows" section of
docs/specs/2026-10-26-runner-burst-autoscaling-design.md: structural pool,
node, maintenance, compatibility and ARC checks; the per-operation admission
table; and the identity snapshot (emit / compare with one declared transition).

Invoke through scripts/verify-runner-pool-state.sh, which checks ARC release
and controller identity first. Exit codes: 0 admitted / equal, 1 rejected or
read error, 2 usage error, 3 identity difference.

Live state is read in a fixed order - cluster, node pools, nodes, pods, then
ARC - so a node that registers after the pool read shows up as more
registered nodes than the provider count, and a runner pod bound after the
node read shows up as bound to an unknown node. Both fail closed.
"""

import argparse
import contextlib
import copy
import datetime
import hashlib
import importlib.util
import io
import json
import math
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
from decimal import Decimal, InvalidOperation

import yaml

BASELINE = "github-runners-pool-16g"
PRIMARY = "github-runners-burst-16g"
FALLBACK = "github-runners-burst-amd-16g"
RUNNER_POOL_SIZES = {
    BASELINE: "s-8vcpu-16gb",
    PRIMARY: "s-8vcpu-16gb",
    FALLBACK: "s-8vcpu-16gb-amd",
}
BURST_CAPS = {PRIMARY: 6, FALLBACK: 2}
BURST_SUM_CAP = 8
BASELINE_NODES = 2
RUNNER_LABELS = {"node-type": "github-runner", "workload-type": "ci-cd"}
RUNNER_TAINT = {"key": "github-runner", "value": "true", "effect": "NoSchedule"}
POOL_LABEL = "doks.digitalocean.com/node-pool"
# Ruling 5: NoSchedule taints a burst node may carry within 15 minutes of
# creation, Ready or not. node.kubernetes.io/unreachable is never tolerated
# (Ruling 10).
PROVISIONING_TAINTS = {
    "node.kubernetes.io/not-ready",
    "node.cloudprovider.kubernetes.io/uninitialized",
}
# Ruling 5: cluster-autoscaler scale-down taints (key -> effect). Admitted on
# burst-pool nodes only; such a node is unavailable (no free runner slots and
# outside the headroom requirement). Either key on a baseline node fails.
AUTOSCALER_TAINTS = {
    "ToBeDeletedByClusterAutoscaler": "NoSchedule",
    "DeletionCandidateOfClusterAutoscaler": "PreferNoSchedule",
}
NOTREADY_GRACE_SECONDS = 15 * 60
MIN_KUBERNETES = (1, 36)
RUNNER_CPU_M = 3000
RUNNER_MEMORY_MI = 5120
MIN_FREE_CPU_M = 1000
MIN_FREE_MEMORY_MI = 2048

NAMESPACE = "arc-runners"
RELEASE = "redducklabs-runners"
SCALE_SET_LABEL = "actions.github.com/scale-set-name"
EXPANDERS = ["priority", "random"]
EXPANDER_CONFIGMAP = ("kube-system", "cluster-autoscaler-priority-expander")
EXPANDER_MANAGED_LABEL = "doks.digitalocean.com/managed"
# Ruling 33: Emergency Stop writes this ConfigMap before its Helm write. While
# it exists every fleet mutator is refused; only Deploy `deploy` and
# `rollback` dispatched with acknowledge_emergency_stop=true are admitted (they
# delete it, bracketed, before their Helm write). Node Pool Sizing
# `remove-burst` is also admitted: it deletes only empty, closed burst pools,
# cannot start a runner, and is the first step of the documented recovery from
# drain-stopped (without it that recovery could not run). Status and Rebalance
# report it as a stopped condition.
STOP_MARKER = "runner-fleet-emergency-stop"
STOP_ACKNOWLEDGED = {"deploy", "rollback"}
STOP_TOLERATED = {"status", "rebalance", "remove-burst"}
# Ruling 36: the server-side fence (deploy/runner-emergency-stop-fence.yaml)
# must exist with exactly the committed specs before a fleet mutator is
# admitted. Not required: status and record-density (read-only), Deploy
# `deploy` and `rollback` (they install it, server dry run first, before their
# Helm write; `deploy` is the bootstrap path), and remove-burst (for the
# reason it is admitted under the stop marker: it deletes only empty closed
# pools and cannot start a runner, and it must stay available to recover from
# drain-stopped). While ARC is density or density-stopped no deploy has
# installed the fence yet (rollout steps before Deploy `deploy`), so there an
# absent fence is tolerated; a present but different one never is.
FENCE_NOT_REQUIRED = {"status", "record-density", "deploy", "rollback", "remove-burst"}
FENCE_ABSENT_TOLERATED_ARC = {"density", "density-stopped"}

# (contract, minRunners, maxRunners) states the gate can classify.
ARC_STATES = (
    ("density", 2, 4),
    ("burst", 2, 20),
    ("burst-acceptance", 8, 20),
    ("burst-acceptance", 4, 20),
    ("drain", 2, 4),
    # Ruling 26: Emergency Stop's 0/0 on each base template.
    ("burst-stopped", 0, 0),
    ("density-stopped", 0, 0),
    ("drain-stopped", 0, 0),
)
STOPPED = {"burst-stopped", "density-stopped", "drain-stopped"}
OPERATIONS = (
    "status", "rebalance", "acceptance-phase-c", "record-density",
    "set-burst-maxima", "create-burst", "configure-expander", "deploy",
    "enable-burst", "drain", "remove-burst", "rollback",
)
# Spec table "ARC states admitted per operation" (contract column). The
# stopped states (Ruling 26) are admitted only where a recovery starts from
# them: status reads them, rebalance skips with a notice, Deploy `deploy`
# restores burst from burst-stopped, Deploy `drain` starts from burst-stopped,
# and remove-burst and rollback continue the rollback path from drain-stopped
# or density-stopped under the same pool conditions as drain and density.
ADMITTED_ARC = {
    "status": {"density", "burst", "burst-acceptance", "drain"} | STOPPED,
    "rebalance": {"burst", "drain"} | STOPPED,
    "acceptance-phase-c": {"burst", "burst-acceptance"},
    "record-density": {"density"},
    "set-burst-maxima": {"burst"},
    "create-burst": {"density", "burst"},
    "configure-expander": {"density", "burst"},
    "deploy": {"density", "burst", "burst-stopped"},
    "enable-burst": {"burst"},
    "drain": {"burst", "burst-acceptance", "drain", "burst-stopped"},
    "remove-burst": {"drain", "density", "drain-stopped", "density-stopped"},
    "rollback": {"drain", "density", "drain-stopped", "density-stopped"},
}
ENABLE_BURST_STAGES = ({PRIMARY: 0, FALLBACK: 0}, {PRIMARY: 6, FALLBACK: 0}, {PRIMARY: 6, FALLBACK: 2})

CLUSTER_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
VALIDATOR = pathlib.Path(__file__).resolve().parent.parent / "validate-runner-isolation-contract.py"

# scripts/lib/runner_stop_fence.py, loaded by path without writing bytecode.
_FENCE_SPEC = importlib.util.spec_from_file_location(
    "runner_stop_fence", pathlib.Path(__file__).resolve().parent / "runner_stop_fence.py")
stop_fence = importlib.util.module_from_spec(_FENCE_SPEC)
sys.dont_write_bytecode = True
_FENCE_SPEC.loader.exec_module(stop_fence)


class ReadError(Exception):
    """A live read failed or returned something unparseable."""


class UsageError(Exception):
    """The caller's arguments are invalid."""


class DifferenceError(Exception):
    """The snapshot cannot take the declared transition."""


# --------------------------------------------------------------------------
# Live reads
# --------------------------------------------------------------------------

def run(argv):
    """Run a read-only CLI command; never echo its stdout (it may hold values)."""
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as error:
        raise ReadError(f"could not run {argv[0]}: {error}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()
        hint = f": {detail[0][:200]}" if detail else ""
        raise ReadError(f"'{' '.join(argv[:4])} ...' failed with exit {completed.returncode}{hint}")
    return completed.stdout


def run_json(argv):
    text = run(argv)
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ReadError(f"'{' '.join(argv[:4])} ...' did not return JSON: {error}") from error


def items_of(document, what):
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        raise ReadError(f"{what} is not a Kubernetes list")
    return items


def read_live(cluster_name, with_pods):
    """Read live state in the documented order. Raises ReadError."""
    clusters = run_json(["doctl", "kubernetes", "cluster", "list", "-o", "json"])
    if not isinstance(clusters, list):
        raise ReadError("doctl cluster list is not a JSON array")
    matches = [c for c in clusters if isinstance(c, dict) and c.get("name") == cluster_name]
    if len(matches) != 1 or not isinstance(matches[0].get("id"), str) or not matches[0]["id"]:
        raise ReadError(
            f"cluster '{cluster_name}' must resolve to exactly one DigitalOcean cluster; found {len(matches)}"
        )
    cluster = matches[0]
    pools = run_json(["doctl", "kubernetes", "cluster", "node-pool", "list", cluster["id"], "-o", "json"])
    if not isinstance(pools, list) or not all(isinstance(p, dict) for p in pools):
        raise ReadError("doctl node-pool list is not a JSON array of pools")
    for pool in pools:
        if not isinstance(pool.get("name"), str) or not pool["name"]:
            raise ReadError(f"node pool {pool.get('id')!r} has a missing or non-string name")
    nodes = items_of(run_json(["kubectl", "get", "nodes", "-o", "json"]), "node list")
    pods = items_of(run_json(["kubectl", "get", "pods", "-A", "-o", "json"]), "pod list") if with_pods else []
    values_text = run(["helm", "get", "values", RELEASE, "-n", NAMESPACE, "-o", "json"])
    manifest_text = run(["helm", "get", "manifest", RELEASE, "-n", NAMESPACE])
    asrs_text = run(["kubectl", "get", "autoscalingrunnersets.actions.github.com", "-n", NAMESPACE, "-o", "json"])
    return {
        "cluster": cluster,
        "pools": pools,
        "nodes": nodes,
        "pods": pods,
        "arc": classify_arc(values_text, manifest_text, asrs_text),
    }


def read_expander_configmap():
    namespace, name = EXPANDER_CONFIGMAP
    return run_json(["kubectl", "get", "configmap", name, "-n", namespace, "-o", "json"])


def read_stop_marker():
    """The Emergency Stop marker ConfigMap, or None when absent. Raises ReadError."""
    text = run(["kubectl", "get", "configmap", STOP_MARKER, "-n", NAMESPACE, "--ignore-not-found", "-o", "json"])
    if not text.strip():
        return None
    try:
        marker = json.loads(text)
    except json.JSONDecodeError as error:
        raise ReadError(f"the Emergency Stop marker {NAMESPACE}/{STOP_MARKER} is not JSON: {error}") from error
    if not isinstance(marker, dict) or (marker.get("metadata") or {}).get("name") != STOP_MARKER:
        raise ReadError(f"the Emergency Stop marker read did not return {NAMESPACE}/{STOP_MARKER}")
    return marker


def stop_line(marker):
    data = marker.get("data") or {}
    run_id = re.sub(r"[^0-9A-Za-z._:-]", "", str(data.get("run-id", "unknown")))[:40] or "unknown"
    stamp = re.sub(r"[^0-9A-Za-z._:-]", "", str(data.get("time", "unknown")))[:40] or "unknown"
    return f"STOP: Emergency Stop marker {NAMESPACE}/{STOP_MARKER} present (run {run_id} at {stamp})"


def stop_errors(operation, marker, acknowledged):
    """Ruling 33: operations refused while the Emergency Stop marker exists."""
    if marker is None or operation in STOP_TOLERATED:
        return []
    if operation in STOP_ACKNOWLEDGED and acknowledged:
        return []
    hint = ("dispatch it with acknowledge_emergency_stop=true to recover" if operation in STOP_ACKNOWLEDGED
            else "recover first with Deploy `deploy` or `rollback` and acknowledge_emergency_stop=true")
    return [f"operation '{operation}' is refused while the Emergency Stop marker {NAMESPACE}/{STOP_MARKER} exists; {hint}"]


def fence_errors(operation, arc):
    """Ruling 36: the Emergency Stop fence must be installed exactly as committed."""
    if operation in FENCE_NOT_REQUIRED:
        return []
    try:
        state, errors = stop_fence.evaluate(stop_fence.load_fence_file(), stop_fence.read_live())
    except stop_fence.ReadError as error:
        raise ReadError(f"Emergency Stop fence: {error}") from error
    if state == "exact":
        return []
    if state == "absent" and arc is not None and arc[0] in FENCE_ABSENT_TOLERATED_ARC:
        return []
    hint = ("Deploy `deploy` (or `rollback`) installs it" if state == "absent"
            else "re-run Deploy `deploy` (or `rollback`) to reinstall the committed fence")
    return [f"operation '{operation}' requires the Emergency Stop fence {stop_fence.NAME} to equal "
            f"deploy/runner-emergency-stop-fence.yaml: {error}; {hint}" for error in errors]


def verify_release_identity():
    """Run verify_arc_identity (scripts/lib/arc-identity.sh); ReadError on failure."""
    library = pathlib.Path(__file__).resolve().parent / "arc-identity.sh"
    completed = subprocess.run(
        ["bash", "-c", 'source "$1" && verify_arc_identity', "verify_arc_identity", str(library)],
        capture_output=True, text=True, check=False,
    )
    if completed.returncode != 0:
        for line in (completed.stderr or "").strip().splitlines():
            print(line, file=sys.stderr)
        raise ReadError("ARC release or controller identity check failed; ARC transition not trusted")


def now_seconds():
    command = shlex.split(os.environ.get("NOW_CMD") or "date +%s")
    try:
        return int(run(command).strip())
    except ValueError as error:
        raise ReadError("NOW_CMD did not print an integer epoch") from error


# --------------------------------------------------------------------------
# ARC classification (delegates every decision to the Task 1 validator)
# --------------------------------------------------------------------------

_validator_module = None


def validate(contract, kind, min_runners, max_runners, text):
    """Run the contract validator's main() in process; True on exit 0."""
    global _validator_module
    if _validator_module is None:
        sys.dont_write_bytecode = True  # never leave __pycache__ in the checkout
        spec = importlib.util.spec_from_file_location("runner_isolation_contract", VALIDATOR)
        _validator_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_validator_module)
    argv, stdin = sys.argv, sys.stdin
    sys.argv = [
        str(VALIDATOR), "--contract", contract, "--kind", kind,
        "--min-runners", str(min_runners), "--max-runners", str(max_runners),
        "--runner-group", "private",
    ]
    sys.stdin = io.StringIO(text)
    try:
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            return _validator_module.main() == 0
    except SystemExit:
        return False
    finally:
        sys.argv, sys.stdin = argv, stdin


def canonical_sha256(document):
    data = json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def values_digest(values_text):
    """Hash Helm values with the GitHub token redacted (never hash or emit it)."""
    try:
        values = json.loads(values_text)
    except json.JSONDecodeError as error:
        raise ReadError("helm get values did not return JSON") from error
    values = copy.deepcopy(values)
    secret = values.get("githubConfigSecret") if isinstance(values, dict) else None
    if isinstance(secret, dict) and "github_token" in secret:
        secret["github_token"] = "<redacted>"
    return canonical_sha256(values)


def manifest_digest(manifest_text):
    """Hash the rendered manifest with Secret payloads removed."""
    try:
        documents = [d for d in yaml.safe_load_all(manifest_text) if d is not None]
    except yaml.YAMLError as error:
        raise ReadError("helm get manifest did not return YAML") from error
    for document in documents:
        if isinstance(document, dict) and document.get("kind") == "Secret":
            document.pop("data", None)
            document.pop("stringData", None)
    return canonical_sha256(documents)


def classify_arc(values_text, manifest_text, asrs_text):
    matched = {"values": [], "manifest": [], "asrs-list": []}
    texts = {"values": values_text, "manifest": manifest_text, "asrs-list": asrs_text}
    for state in ARC_STATES:
        for kind, text in texts.items():
            if validate(state[0], kind, state[1], state[2], text):
                matched[kind].append(state)
    agreed = [s for s in ARC_STATES if all(s in matched[k] for k in matched)]
    try:
        generation = json.loads(asrs_text)["items"][0]["metadata"]["generation"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
        generation = None
    if not isinstance(generation, int) or isinstance(generation, bool):
        generation = None
    state = agreed[0] if len(agreed) == 1 else None
    return {
        "state": state,
        "matched": matched,
        "snapshot": {
            "contract": state[0] if state else None,
            "minRunners": state[1] if state else None,
            "maxRunners": state[2] if state else None,
            "values_sha256": values_digest(values_text),
            "manifest_sha256": manifest_digest(manifest_text),
            "asrs_generation": generation,
        },
    }


# --------------------------------------------------------------------------
# Quantities and pod requests (same arithmetic as Deploy's headroom preflight)
# --------------------------------------------------------------------------

def cpu_m(value):
    value = str(value or "0")
    try:
        if value.endswith("n"):
            milli = Decimal(value[:-1]) / Decimal(1_000_000)
        elif value.endswith("u"):
            milli = Decimal(value[:-1]) / Decimal(1_000)
        elif value.endswith("m"):
            milli = Decimal(value[:-1])
        else:
            milli = Decimal(value) * Decimal(1000)
    except InvalidOperation as error:
        raise ValueError(f"unsupported CPU quantity {value}") from error
    return math.ceil(milli)


def memory_mi(value):
    value = str(value or "0")
    match = re.fullmatch(r"([0-9.]+)([KMGT]i?|)", value)
    if not match:
        raise ValueError(f"unsupported memory quantity {value}")
    factors = {"": 1 / 1024 / 1024, "K": 1000 / 1024 / 1024, "Ki": 1 / 1024,
               "M": 1000**2 / 1024**2, "Mi": 1, "G": 1000**3 / 1024**2, "Gi": 1024,
               "T": 1000**4 / 1024**2, "Ti": 1024**2}
    return math.ceil(float(match.group(1)) * factors[match.group(2)])


def pod_requests(pod):
    spec = pod.get("spec") or {}

    def req(item, name, convert):
        return convert(((item.get("resources") or {}).get("requests") or {}).get(name))

    app_cpu = sum(req(c, "cpu", cpu_m) for c in spec.get("containers") or [])
    app_memory = sum(req(c, "memory", memory_mi) for c in spec.get("containers") or [])
    sidecar_cpu = sidecar_memory = init_peak_cpu = init_peak_memory = 0
    for init in spec.get("initContainers") or []:
        init_cpu, init_memory = req(init, "cpu", cpu_m), req(init, "memory", memory_mi)
        if init.get("restartPolicy") == "Always":
            sidecar_cpu += init_cpu
            sidecar_memory += init_memory
            init_peak_cpu = max(init_peak_cpu, sidecar_cpu)
            init_peak_memory = max(init_peak_memory, sidecar_memory)
        else:
            init_peak_cpu = max(init_peak_cpu, sidecar_cpu + init_cpu)
            init_peak_memory = max(init_peak_memory, sidecar_memory + init_memory)
    cpu = max(app_cpu + sidecar_cpu, init_peak_cpu)
    memory = max(app_memory + sidecar_memory, init_peak_memory)
    pod_level = (spec.get("resources") or {}).get("requests") or {}
    if "cpu" in pod_level:
        cpu = max(cpu_m(pod_level["cpu"]), cpu)
    if "memory" in pod_level:
        memory = max(memory_mi(pod_level["memory"]), memory)
    overhead = spec.get("overhead") or {}
    return cpu + cpu_m(overhead.get("cpu")), memory + memory_mi(overhead.get("memory"))


# --------------------------------------------------------------------------
# Normalization and snapshot
# --------------------------------------------------------------------------

def normalize_taints(taints):
    if taints is None:
        return []
    if not isinstance(taints, list) or not all(isinstance(t, dict) for t in taints):
        return None
    normalized = [{str(k).lower(): v for k, v in t.items()} for t in taints]
    return sorted(normalized, key=lambda t: json.dumps(t, sort_keys=True))


def pool_entry(pool):
    return {
        "id": pool.get("id"),
        "size": pool.get("size"),
        "auto_scale": pool.get("auto_scale"),
        "min_nodes": pool.get("min_nodes"),
        "max_nodes": pool.get("max_nodes"),
        "labels": pool.get("labels") or {},
        "taints": normalize_taints(pool.get("taints")),
    }


def node_labels(node):
    return (node.get("metadata") or {}).get("labels") or {}


def build_snapshot(live):
    pools = {}
    for pool in live["pools"]:
        name = pool.get("name")
        # A duplicated name cannot be represented; record it so it never matches.
        pools[name] = pool_entry(pool) if name not in pools else {"duplicate": True}
    baseline = pools.get(BASELINE) or {}
    baseline_nodes = sorted(
        (
            {"uid": (n.get("metadata") or {}).get("uid"), "providerID": (n.get("spec") or {}).get("providerID")}
            for n in live["nodes"]
            if node_labels(n).get(POOL_LABEL) == BASELINE
        ),
        key=lambda n: (str(n["uid"]), str(n["providerID"])),
    )
    return {
        "immutable": {
            "cluster_id": live["cluster"].get("id"),
            "baseline_pool_id": baseline.get("id"),
            "baseline_nodes": baseline_nodes,
        },
        "pools": pools,
        "arc": live["arc"]["snapshot"],
    }


# --------------------------------------------------------------------------
# Structural evaluation
# --------------------------------------------------------------------------

def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_ready(node):
    conditions = (node.get("status") or {}).get("conditions") or []
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)


def parse_time(value):
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        ).timestamp()
    except (TypeError, ValueError):
        return None


def kube_version(node):
    version = ((node.get("status") or {}).get("nodeInfo") or {}).get("kubeletVersion") or ""
    match = re.match(r"v?(\d+)\.(\d+)", version)
    return (version, (int(match.group(1)), int(match.group(2))) if match else None)


def evaluate(live, now):
    """Return (errors, facts) for the operation-independent state contract."""
    errors = []
    cluster = live["cluster"]
    state = (cluster.get("status") or {}).get("state")
    if state != "running":
        errors.append(f"cluster status is '{state}', not running (maintenance in progress)")

    # Eligible pools.
    pools = {}
    structural = {}  # burst pool name -> structural mismatches (Ruling 8)
    for pool in live["pools"]:
        name = pool.get("name")
        if not isinstance(name, str) or not name:
            errors.append(f"node pool {pool.get('id')!r} has a missing or non-string name")
            continue
        if name in pools:
            errors.append(f"pool '{name}' appears more than once")
            continue
        pools[name] = pool
        labels = pool.get("labels") or {}
        eligible = isinstance(labels, dict) and labels.get("node-type") == "github-runner"
        if name not in RUNNER_POOL_SIZES:
            if eligible:
                errors.append(f"unknown eligible pool '{name}' carries node-type=github-runner")
            continue
        mismatches = []
        if pool.get("size") != RUNNER_POOL_SIZES[name]:
            mismatches.append(f"pool '{name}' size is '{pool.get('size')}', expected '{RUNNER_POOL_SIZES[name]}'")
        if labels != RUNNER_LABELS:
            mismatches.append(f"pool '{name}' labels are not exactly node-type=github-runner, workload-type=ci-cd")
        if normalize_taints(pool.get("taints")) != [RUNNER_TAINT]:
            mismatches.append(f"pool '{name}' taints are not exactly github-runner=true:NoSchedule")
        if pool.get("auto_scale") is not True:
            mismatches.append(f"pool '{name}' auto_scale must be true")
        if name in BURST_CAPS:
            if mismatches:
                structural[name] = mismatches
        else:
            errors.extend(mismatches)
        for field in ("count", "min_nodes", "max_nodes"):
            if not is_int(pool.get(field)) or pool.get(field) < 0:
                errors.append(f"pool '{name}' {field} is not a non-negative integer")

    baseline = pools.get(BASELINE)
    if baseline is None:
        errors.append(f"baseline pool '{BASELINE}' is missing")
    elif not (baseline.get("count") == baseline.get("min_nodes") == baseline.get("max_nodes") == BASELINE_NODES):
        errors.append(
            f"baseline pool must have count=min=max={BASELINE_NODES}; found count={baseline.get('count')} "
            f"min={baseline.get('min_nodes')} max={baseline.get('max_nodes')}"
        )

    burst = {name: pools[name] for name in BURST_CAPS if name in pools}
    burst_max_sum = 0
    for name, pool in burst.items():
        minimum, maximum, count = pool.get("min_nodes"), pool.get("max_nodes"), pool.get("count")
        if minimum != 0:
            errors.append(f"burst pool '{name}' min_nodes must be 0; found {minimum}")
        if not is_int(maximum) or not 0 <= maximum <= BURST_CAPS[name]:
            errors.append(f"burst pool '{name}' max_nodes {maximum} is outside 0..{BURST_CAPS[name]}")
        if is_int(maximum):
            burst_max_sum += maximum
            if is_int(count) and count > maximum:
                errors.append(f"burst pool '{name}' count {count} exceeds max_nodes {maximum}")
    if burst_max_sum > BURST_SUM_CAP:
        errors.append(f"sum of burst max_nodes {burst_max_sum} exceeds {BURST_SUM_CAP}")

    # Node membership, readiness and compatibility.
    registered = {}
    node_pool = {}
    baseline_ready = 0
    baseline_identities = []
    unavailable_nodes = []
    pods_by_node = {}
    for pod in live["pods"]:
        node_name = (pod.get("spec") or {}).get("nodeName")
        if node_name:
            pods_by_node.setdefault(node_name, []).append(pod)
    for node in live["nodes"]:
        metadata = node.get("metadata") or {}
        name = metadata.get("name")
        labels = node_labels(node)
        pool_name = labels.get(POOL_LABEL)
        if pool_name is not None:
            registered[pool_name] = registered.get(pool_name, 0) + 1
            node_pool[name] = pool_name
        runner = labels.get("node-type") == "github-runner" or pool_name in RUNNER_POOL_SIZES
        if not runner:
            continue
        if pool_name not in RUNNER_POOL_SIZES or pool_name not in pools:
            errors.append(
                f"runner node '{name}' does not belong to a runner pool through {POOL_LABEL} (found '{pool_name}')"
            )
            continue
        ready = is_ready(node)
        is_burst = pool_name in BURST_CAPS
        created = parse_time(metadata.get("creationTimestamp"))
        young = created is not None and now - created <= NOTREADY_GRACE_SECONDS
        if is_burst and created is None:
            errors.append(f"burst node '{name}' has no parseable creationTimestamp")
        elif is_burst and not ready and not young:
            errors.append(f"burst node '{name}' has been NotReady for longer than 15 minutes")
        if any(labels.get(k) != v for k, v in RUNNER_LABELS.items()):
            errors.append(f"runner node '{name}' lacks the runner labels node-type=github-runner, workload-type=ci-cd")
        taints = normalize_taints((node.get("spec") or {}).get("taints")) or []
        if [t for t in taints if t.get("key") == RUNNER_TAINT["key"]] != [RUNNER_TAINT]:
            errors.append(f"runner node '{name}' lacks the github-runner=true:NoSchedule taint")
        unavailable = False
        for taint in taints:
            key, effect = taint.get("key"), taint.get("effect")
            if key == RUNNER_TAINT["key"]:
                continue
            if key in AUTOSCALER_TAINTS:
                if not is_burst:
                    errors.append(f"baseline node '{name}' carries cluster-autoscaler taint '{key}'")
                    continue
                if effect == AUTOSCALER_TAINTS[key]:
                    unavailable = True
                    continue
            if effect not in ("NoSchedule", "NoExecute"):
                continue
            if is_burst and young and effect == "NoSchedule" and key in PROVISIONING_TAINTS:
                continue
            errors.append(f"runner node '{name}' has an extra NoSchedule/NoExecute taint '{key}'")
        if unavailable:
            unavailable_nodes.append(name)
        if pool_name == BASELINE:
            baseline_identities.append(((metadata.get("uid") or ""), ((node.get("spec") or {}).get("providerID") or "")))
            if ready:
                baseline_ready += 1
        if not ready:
            continue
        version, parsed = kube_version(node)
        if parsed is None or parsed < MIN_KUBERNETES:
            errors.append(f"runner node '{name}' runs Kubernetes '{version}'; 1.36 or newer is required")
        if unavailable:
            continue  # being scaled down: no runner slots, so no headroom requirement
        try:
            allocatable = (node.get("status") or {}).get("allocatable") or {}
            free_cpu = cpu_m(allocatable.get("cpu")) - 2 * RUNNER_CPU_M
            free_memory = memory_mi(allocatable.get("memory")) - 2 * RUNNER_MEMORY_MI
            for pod in pods_by_node.get(name, []):
                if (pod.get("status") or {}).get("phase") in ("Succeeded", "Failed"):
                    continue
                pod_meta = pod.get("metadata") or {}
                if pod_meta.get("namespace") == NAMESPACE and (pod_meta.get("labels") or {}).get(SCALE_SET_LABEL) == RELEASE:
                    continue
                cpu, memory = pod_requests(pod)
                free_cpu -= cpu
                free_memory -= memory
        except ValueError as error:
            errors.append(f"runner node '{name}' headroom could not be computed: {error}")
            continue
        if free_memory < MIN_FREE_MEMORY_MI or free_cpu < MIN_FREE_CPU_M:
            errors.append(
                f"runner node '{name}' lacks headroom after two runner reservations: "
                f"{free_memory}Mi memory / {free_cpu}m CPU left (need {MIN_FREE_MEMORY_MI}Mi / {MIN_FREE_CPU_M}m)"
            )

    for name, pool in pools.items():
        count = pool.get("count")
        if is_int(count) and registered.get(name, 0) > count:
            errors.append(
                f"maintenance: pool '{name}' has {registered.get(name, 0)} registered nodes but provider count {count}"
            )
    if baseline is not None and (registered.get(BASELINE, 0) != BASELINE_NODES or baseline_ready != BASELINE_NODES):
        errors.append(
            f"baseline pool must have exactly two Ready nodes; found {baseline_ready} Ready of {registered.get(BASELINE, 0)}"
        )
    uids = [u for u, _ in baseline_identities]
    providers = [p for _, p in baseline_identities]
    if not all(uids + providers) or len(set(uids)) != len(uids) or len(set(providers)) != len(providers):
        errors.append("baseline node UID/providerID identities are missing or ambiguous")

    arc = live["arc"]
    if arc["snapshot"]["asrs_generation"] is None:
        errors.append("live AutoscalingRunnerSet has no metadata.generation")
    if arc["state"] is None:
        described = "; ".join(
            f"{kind}: {', '.join(f'{c} {mn}/{mx}' for c, mn, mx in states) or 'none'}"
            for kind, states in arc["matched"].items()
        )
        errors.append(f"ARC state matches no admissible contract across values, manifest and live ASRS ({described})")

    # Runner pods per burst pool, and runner pods bound to an unknown node.
    known_nodes = {(n.get("metadata") or {}).get("name") for n in live["nodes"]}
    runner_pods_in_pool = {}
    unknown_bound = []
    for pod in live["pods"]:
        pod_meta = pod.get("metadata") or {}
        if pod_meta.get("namespace") != NAMESPACE or (pod_meta.get("labels") or {}).get(SCALE_SET_LABEL) != RELEASE:
            continue
        node_name = (pod.get("spec") or {}).get("nodeName")
        if not node_name:
            continue
        if node_name not in known_nodes:
            unknown_bound.append(pod_meta.get("name"))
            continue
        pool_name = node_pool.get(node_name)
        runner_pods_in_pool[pool_name] = runner_pods_in_pool.get(pool_name, 0) + 1

    present = [name for name in (PRIMARY, FALLBACK) if name in burst]
    facts = {
        "arc": arc["state"],
        "pools": pools,
        "present": present,
        "open": any(is_int(burst[n].get("max_nodes")) and burst[n]["max_nodes"] > 0 for n in present),
        "registered": registered,
        "runner_pods_in_pool": runner_pods_in_pool,
        "unknown_bound": unknown_bound,
        "structural": structural,
        "unavailable_nodes": unavailable_nodes,
    }
    return errors, facts


def state_line(facts):
    present = facts["present"]
    pools = "both" if len(present) == 2 else "primary" if present == [PRIMARY] else "fallback" if present else "none"
    contract = facts["arc"][0] if facts["arc"] else "unknown"
    return f"STATE: arc={contract} pools={pools} burst={'open' if facts['open'] else 'closed'}"


def expander_errors(cluster, primary_id, fallback_id, operation):
    errors = []
    expanders = (cluster.get("cluster_autoscaler_configuration") or {}).get("expanders")
    if expanders != EXPANDERS:
        errors.append(f"{operation} requires cluster expanders {','.join(EXPANDERS)}; found {expanders}")
    try:
        configmap = read_expander_configmap()
    except ReadError as error:
        return errors + [f"{operation} requires the priority expander ConfigMap: {error}"]
    if not isinstance(configmap, dict):
        return errors + [f"{operation}: priority expander ConfigMap is not a JSON object"]
    labels = (configmap.get("metadata") or {}).get("labels") or {}
    if EXPANDER_MANAGED_LABEL not in labels:
        errors.append(f"priority expander ConfigMap lost its {EXPANDER_MANAGED_LABEL} label")
    try:
        priorities = yaml.safe_load((configmap.get("data") or {}).get("priorities") or "")
    except yaml.YAMLError:
        priorities = None
    expected = {100: [primary_id], 50: [fallback_id], 1: [".*"]}
    if priorities != expected:
        errors.append(f"{operation} requires the priority expander to rank {PRIMARY} at 100, {FALLBACK} at 50, .* at 1")
    return errors


def admission_errors(operation, live, facts, marker=None):
    """Operation-specific admission (spec table 'ARC states admitted per operation')."""
    errors = []
    arc = facts["arc"]
    # While the Emergency Stop marker exists Rebalance treats the fleet as
    # stopped whatever the release reads (Ruling 33): notice only.
    marker_rebalance = operation == "rebalance" and marker is not None
    if arc is not None and arc[0] not in ADMITTED_ARC[operation] and not marker_rebalance:
        errors.append(f"operation '{operation}' does not admit ARC state '{arc[0]}' ({arc[1]}/{arc[2]})")
    pools, present = facts["pools"], facts["present"]
    # Ruling 8: a burst-named pool with the wrong size, labels, taint or
    # auto_scale is fatal except for remove-burst, whose own conditions below
    # (count 0, no registered nodes, no runner pods, ARC density or drain)
    # are what admit deleting it.
    if operation != "remove-burst":
        for mismatches in facts["structural"].values():
            errors.extend(mismatches)
    both = len(present) == 2
    maxima = {name: pools[name].get("max_nodes") for name in present}
    needs_both = {"rebalance", "acceptance-phase-c", "set-burst-maxima", "configure-expander", "deploy",
                  "enable-burst", "drain"}
    # A stopped fleet runs no runners, so Rebalance has nothing to retire and
    # skips with a notice whatever the burst pools are (Ruling 26).
    stopped_rebalance = operation == "rebalance" and (marker is not None or (arc is not None and arc[0] in STOPPED))
    if operation in needs_both and not both and not stopped_rebalance:
        errors.append(f"operation '{operation}' requires both burst pools present; found {present or 'none'}")
    if operation in ("record-density", "rollback") and present:
        errors.append(f"operation '{operation}' requires no burst pools; found {present}")
    # create-burst reconciles by narrowing only: a structurally correct pool
    # that is open (max > 0) is admitted so the operation can lower it to 0.
    enabled = {PRIMARY: BURST_CAPS[PRIMARY], FALLBACK: BURST_CAPS[FALLBACK]}
    if operation == "acceptance-phase-c" and both and maxima != enabled:
        errors.append(f"acceptance-phase-c requires both burst pools enabled at exactly 0/6 and 0/2; maxima are {maxima}")
    if operation == "enable-burst" and both and maxima not in ENABLE_BURST_STAGES:
        errors.append(f"enable-burst stage {maxima} is not one of closed, primary-open, both-open")
    if operation in ("deploy", "enable-burst") and both:
        errors.extend(expander_errors(live["cluster"], pools[PRIMARY].get("id"), pools[FALLBACK].get("id"), operation))
    if operation == "remove-burst":
        if arc is not None and arc[0] in ("density", "density-stopped"):
            for name in present:
                if maxima[name] != 0:
                    errors.append(f"remove-burst from density requires burst pool '{name}' at max_nodes=0; found {maxima[name]}")
        for name in present:
            count = pools[name].get("count")
            if count != 0:
                errors.append(f"remove-burst requires burst pool '{name}' at provider count 0; found provider count {count}")
            if facts["registered"].get(name, 0):
                errors.append(f"remove-burst requires zero nodes in '{name}'; found {facts['registered'][name]} registered node(s)")
            if facts["runner_pods_in_pool"].get(name, 0):
                errors.append(f"remove-burst requires zero runner pods in '{name}'; found {facts['runner_pods_in_pool'][name]}")
        if facts["unknown_bound"]:
            errors.append(f"remove-burst found runner pod(s) bound to unregistered nodes: {', '.join(facts['unknown_bound'])}")
    return errors


# --------------------------------------------------------------------------
# Identity comparison
# --------------------------------------------------------------------------

TRANSITION_RE = {
    "pool-created": re.compile(r"^pool-created:([a-z0-9-]+):([a-z0-9-]+):(\d+)/(\d+)$"),
    "pool-deleted": re.compile(r"^pool-deleted:([a-z0-9-]+)$"),
    "pool-bounds": re.compile(r"^pool-bounds:([a-z0-9-]+):(\d+)/(\d+)$"),
    "arc": re.compile(r"^arc:([a-z-]+):(\d+)/(\d+)$"),
}


def parse_transition(text):
    if text == "none":
        return ("none",)
    kind = text.split(":", 1)[0]
    match = TRANSITION_RE.get(kind).match(text) if kind in TRANSITION_RE else None
    if not match:
        raise UsageError(f"malformed transition '{text}'")
    groups = match.groups()
    if kind in ("pool-created", "pool-bounds"):
        name = groups[0]
        minimum, maximum = int(groups[-2]), int(groups[-1])
        if name not in BURST_CAPS:
            raise UsageError(f"{kind} names '{name}', which is not a burst pool")
        if minimum != 0 or not 0 <= maximum <= BURST_CAPS[name]:
            raise UsageError(f"{kind} bounds {minimum}/{maximum} are outside 0/0..{BURST_CAPS[name]}")
        if kind == "pool-created":
            if groups[1] != RUNNER_POOL_SIZES[name]:
                raise UsageError(f"pool-created size '{groups[1]}' is not the size of '{name}'")
            return (kind, name, groups[1], minimum, maximum)
        return (kind, name, minimum, maximum)
    if kind == "pool-deleted":
        if groups[0] not in BURST_CAPS:
            raise UsageError(f"pool-deleted names '{groups[0]}', which is not a burst pool")
        return (kind, groups[0])
    state = (groups[0], int(groups[1]), int(groups[2]))
    if state not in ARC_STATES:
        raise UsageError(f"arc transition {state[0]} {state[1]}/{state[2]} is not a canonical ARC state")
    return (kind,) + state


SNAPSHOT_KEYS = {
    "immutable": {"cluster_id", "baseline_pool_id", "baseline_nodes"},
    "arc": {"contract", "minRunners", "maxRunners", "values_sha256", "manifest_sha256", "asrs_generation"},
}


def load_snapshot(path):
    try:
        with open(path, encoding="utf-8") as stream:
            snapshot = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise ReadError(f"could not read snapshot {path}: {error}") from error
    if (
        not isinstance(snapshot, dict)
        or set(snapshot) != {"immutable", "pools", "arc"}
        or not isinstance(snapshot["pools"], dict)
        or any(not isinstance(snapshot[k], dict) or set(snapshot[k]) != keys for k, keys in SNAPSHOT_KEYS.items())
    ):
        raise ReadError(f"snapshot {path} does not have the identity schema")
    return snapshot


def write_snapshot(path, snapshot):
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(prefix=".pool-state.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(snapshot, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def differences(expected, actual, path=""):
    if isinstance(expected, dict) and isinstance(actual, dict):
        found = []
        for key in sorted(set(expected) | set(actual), key=str):
            child = f"{path}.{key}" if path else str(key)
            if key not in expected:
                found.append(f"{child}: unexpected, live={json.dumps(actual[key], sort_keys=True)}")
            elif key not in actual:
                found.append(f"{child}: expected, absent live")
            else:
                found.extend(differences(expected[key], actual[key], child))
        return found
    if expected != actual:
        return [f"{path}: expected={json.dumps(expected, sort_keys=True)} live={json.dumps(actual, sort_keys=True)}"]
    return []


def expected_after(snapshot, transition, live_snapshot):
    """Apply one declared transition to the trusted snapshot."""
    expected = copy.deepcopy(snapshot)
    kind = transition[0]
    if kind == "pool-created":
        _, name, size, minimum, maximum = transition
        if name in snapshot["pools"]:
            raise DifferenceError(f"pool-created names '{name}', which is already in the snapshot")
        live_id = (live_snapshot["pools"].get(name) or {}).get("id")
        known_ids = {p.get("id") for p in snapshot["pools"].values()}
        if not isinstance(live_id, str) or not live_id or live_id in known_ids:
            live_id = None
        expected["pools"][name] = {
            "id": live_id, "size": size, "auto_scale": True, "min_nodes": minimum, "max_nodes": maximum,
            "labels": dict(RUNNER_LABELS), "taints": [dict(RUNNER_TAINT)],
        }
    elif kind == "pool-deleted":
        name = transition[1]
        if name not in snapshot["pools"]:
            raise DifferenceError(f"pool-deleted names '{name}', which is not in the snapshot")
        del expected["pools"][name]
    elif kind == "pool-bounds":
        _, name, minimum, maximum = transition
        if name not in snapshot["pools"]:
            raise DifferenceError(f"pool-bounds names '{name}', which is not in the snapshot")
        expected["pools"][name]["min_nodes"] = minimum
        expected["pools"][name]["max_nodes"] = maximum
    elif kind == "arc":
        _, contract, minimum, maximum = transition
        expected["arc"] = dict(live_snapshot["arc"])
        expected["arc"].update({"contract": contract, "minRunners": minimum, "maxRunners": maximum})
        if live_snapshot["arc"].get("asrs_generation") is None:
            raise DifferenceError("live AutoscalingRunnerSet has no metadata.generation; ARC state not trusted")
    return expected


# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

def admit(args):
    if args.acknowledge_emergency_stop and args.operation not in STOP_ACKNOWLEDGED:
        raise UsageError("--acknowledge-emergency-stop is valid only for deploy and rollback")
    live = read_live(args.cluster_name, with_pods=True)
    marker = read_stop_marker()
    errors, facts = evaluate(live, now_seconds())
    errors += stop_errors(args.operation, marker, args.acknowledge_emergency_stop)
    errors += admission_errors(args.operation, live, facts, marker)
    errors += fence_errors(args.operation, facts["arc"])
    if marker is not None:
        print(stop_line(marker), file=sys.stderr if errors else sys.stdout)
    if errors:
        for error in errors:
            print(f"REJECTED: {error}", file=sys.stderr)
        print(f"REJECTED: operation '{args.operation}' not admitted; observed {state_line(facts)[7:]}", file=sys.stderr)
        return 1
    if args.emit_identities:
        write_snapshot(args.emit_identities, build_snapshot(live))
    print(state_line(facts))
    return 0


def compare(args):
    transition = parse_transition(args.transition)
    snapshot = load_snapshot(args.compare_identities)
    if transition[0] == "arc":
        verify_release_identity()
    live_snapshot = build_snapshot(read_live(args.cluster_name, with_pods=False))
    try:
        expected = expected_after(snapshot, transition, live_snapshot)
    except DifferenceError as error:
        print(f"IDENTITY: {error}", file=sys.stderr)
        return 3
    found = differences(expected, live_snapshot)
    if found:
        for line in found:
            print(f"IDENTITY: {line}", file=sys.stderr)
        print(f"IDENTITY: live state differs from the snapshot under transition '{args.transition}'", file=sys.stderr)
        return 3
    if transition[0] != "none":
        write_snapshot(args.compare_identities, live_snapshot)
    print(f"IDENTITY: live state equals the snapshot under transition '{args.transition}'")
    return 0


def report(args):
    """Read-only per-pool node counts, bounds and expander readback (Runner Status)."""
    live = read_live(args.cluster_name, with_pods=False)
    pools = {}
    duplicates = {}
    for pool in live["pools"]:
        if pool["name"] in pools:
            duplicates[pool["name"]] = duplicates.get(pool["name"], 1) + 1
        else:
            pools[pool["name"]] = pool

    def shown(value):
        return "unknown" if value is None else value

    registered = {name: 0 for name in RUNNER_POOL_SIZES}
    ready = {name: 0 for name in RUNNER_POOL_SIZES}
    for node in live["nodes"]:
        name = node_labels(node).get(POOL_LABEL)
        if name in registered:
            registered[name] += 1
            ready[name] += 1 if is_ready(node) else 0
    for name in RUNNER_POOL_SIZES:
        pool = pools.get(name)
        if pool is None:
            print(f"POOL {name} absent")
            continue
        if name in duplicates:
            print(f"POOL {name} duplicate: {duplicates[name]} pools share this name; counts not reported")
            continue
        auto_scale = pool.get("auto_scale")
        print(
            f"POOL {name} provider_count={shown(pool.get('count'))} min={shown(pool.get('min_nodes'))} "
            f"max={shown(pool.get('max_nodes'))} "
            f"auto_scale={'unknown' if auto_scale is None else str(auto_scale).lower()} "
            f"registered={registered[name]} ready={ready[name]}"
        )
    present = [name for name in (PRIMARY, FALLBACK) if name in pools]
    if any(name in duplicates for name in present):
        print("EXPANDER drift: a burst pool name is duplicated; the priority expander cannot be read")
    elif not present:
        print("EXPANDER n/a: no burst pools")
    elif len(present) == 1:
        print(f"EXPANDER drift: only burst pool '{present[0]}' exists; the priority expander needs both")
    else:
        problems = expander_errors(live["cluster"], pools[PRIMARY].get("id"), pools[FALLBACK].get("id"), "status")
        if problems:
            for problem in problems:
                print(f"EXPANDER drift: {problem}")
        else:
            print(f"EXPANDER ok: cluster expanders {','.join(EXPANDERS)}; priority ConfigMap ranks {PRIMARY} 100, {FALLBACK} 50, .* 1")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    admit_parser = sub.add_parser("admit")
    admit_parser.add_argument("--operation", required=True, choices=OPERATIONS)
    admit_parser.add_argument("--cluster-name", required=True)
    admit_parser.add_argument("--emit-identities")
    admit_parser.add_argument("--acknowledge-emergency-stop", action="store_true")
    digest_parser = sub.add_parser("manifest-digest")
    digest_parser.add_argument("--cluster-name", default="redducklabs-cluster")
    report_parser = sub.add_parser("report")
    report_parser.add_argument("--cluster-name", required=True)
    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("--cluster-name", required=True)
    compare_parser.add_argument("--compare-identities", required=True)
    compare_parser.add_argument("--transition", required=True)
    try:
        args = parser.parse_args()
    except SystemExit:
        return 2
    try:
        if not CLUSTER_NAME_RE.match(args.cluster_name):
            raise UsageError(f"invalid cluster name '{args.cluster_name}'")
        if args.mode == "manifest-digest":
            print(manifest_digest(sys.stdin.read()))
            return 0
        if args.mode == "report":
            return report(args)
        if args.mode == "compare":
            parse_transition(args.transition)
            return compare(args)
        return admit(args)
    except UsageError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except ReadError as error:
        print(f"REJECTED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
