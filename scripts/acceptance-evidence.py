#!/usr/bin/env python3
"""Evidence collection for runner-acceptance-evidence.yml.

Read-only against the cluster and DigitalOcean: it runs only `kubectl get`,
`doctl ... list`, the read-only pool-state gate (`--operation status`) and the
trust-boundary readback (`--verify-only`). Its one write anywhere is
`gh run cancel` of the verified acceptance probe run during cleanup.

Subcommands (all share one state file, rewritten after every step):

  verify-probe    create the state file and, for phases A, B, D and E,
            verify the probe run: redducklabs/aurolegal.ai's
            .github/workflows/runner-burst-acceptance.yml, event
            workflow_dispatch, attempt 1, dispatched from DISPATCH_TAG, an
            annotated tag that resolves to EXPECTED_WORKFLOW_SHA, with
            headSha == EXPECTED_WORKFLOW_SHA. The verified probe is saved at
            once, so a later failure (including verify-anchors) cancels it.
            Exit 1 ("REJECTED:") otherwise, before any evidence is collected.
  verify-anchors  verify the phase's runs in this repository (D: Deploy drain;
            C: Scale Runners acceptance-phase-c; E: Deploy rollback, completed,
            and the Phase A evidence run whose record holds the baseline pool
            ID, at the reviewed SHA or a commit before it, Ruling 50) and add
            them to the state file.
  watch     poll every 60 s while the watched runs (probe; drain in phase D;
            the Phase C run in phase C) are not completed, capturing runner
            pods, runner nodes, events, node pools and pool-state checks.
            Exit 1 with "DEADLINE:" when --deadline-minutes passes first.
  finalize  capture once more after completion, read the probe jobs and the
            phase's anchor runs, wait for the phase's after-state (B: primary
            restored to 0/6; E: two warm runners on baseline), and write the
            evidence JSON read by scripts/acceptance-verdict.py. The evidence
            keeps every pod, node and event ever captured (history), and
            latest_collection_at, the time of the final collection; Phase E's
            warm_after holds only runners of that final collection (Running,
            Ready, not terminating, idle), each with observed_at. Phase C's
            jobs_killed reads every attempt of every run that can have a job in
            the Phase C run (see jobs_killed). In phase A it
            also reads the probe's network-probe job log (its
            NETWORK_PROBE_RESULT line) and resolves the probe's targets in the
            cluster: the node pool of each node address (VPC InternalIP, and the
            runner node's public ExternalIP), the namespace, type and ports of
            the ClusterIP service, the kubernetes.default ClusterIP, and the
            namespace, ports and kube-dns membership of the pod.
  cleanup   cancel the verified probe run, wait until it is completed
            (bounded 10 minutes), then require that no job of the run is
            queued or in progress and no EphemeralRunner is assigned to it.
            Exit 1 ("CLEANUP: failed") otherwise.

Runner pods: every pod of the scale set (actions.github.com/scale-set-name=
redducklabs-runners), probe runners and idle warm runners alike, with its node,
pool, created_at, first_seen and last_seen; ARC 0.14.2 runs minRunners + jobs
runners (Ruling 43). Each collection also appends to pod_collections the pod
read's interval (requested_at before the first attempt, observed_at after the
successful response, retries included) and every runner pod it listed, with
that read's node (null while unscheduled), pool, phase, terminating flag and
the job fields of its EphemeralRunner from the runner read that follows; each
entry also keeps that whole runner read (ephemeral_runners: its own
requested_at/observed_at and every EphemeralRunner's name, uid, phase,
terminating flag and job fields, with or without a pod; Ruling 44:
a job of the probe run, of another run, or none); pool_collections records
each node-pool read (count, min, max, registered nodes per runner pool) with its
own interval, as diagnostics.
The verdict judges placement during the hold from these observations, never
from a pod's final node.

Every read is tried up to three times with a short backoff; a persistent
failure still fails the step. Runner pods are recorded with their full spec
(literal env values redacted, valueFrom references kept) and their container
statuses (restart count, state, last termination reason and exit code).

Test seams: NOW_CMD (default "date +%s"), SLEEP_CMD (default "sleep"),
POOL_STATE_CMD (default scripts/verify-runner-pool-state.sh) and
TRUST_VERIFY_CMD (default scripts/verify-runner-trust-boundary.sh).
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

# The shared node-pool list normalizer (Ruling 39) lives in
# scripts/lib/runner_pool_state.py; load it without writing bytecode.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
from runner_pool_state import normalize_pool_list  # noqa: E402
ORG = "redducklabs"
PROBE_REPOSITORY = "redducklabs/aurolegal.ai"
PROBE_WORKFLOW = ".github/workflows/runner-burst-acceptance.yml"
FLEET_REPOSITORY = "redducklabs/redducklabs-runners"
DEPLOY_WORKFLOW = ".github/workflows/deploy-runners.yml"
SCALE_WORKFLOW = ".github/workflows/scale-runners.yml"
DRAIN_JOB = "Drain Burst Runners"
DRAIN_STEP = "Drain runners"
DRAIN_READBACK = "READBACK: ARC is drain 2/4"
ROLLBACK_JOB = "Roll Back Self-Hosted Runners"
ROLLBACK_READBACK_STEP = "Verify rollback transition and density readback"
PHASE_C_JOB = "Scale Runners - acceptance-phase-c"
PHASE_C_ARTIFACT = "phase-c-evidence"
NAMESPACE = "arc-runners"
SCALE_SET_SELECTOR = "actions.github.com/scale-set-name=redducklabs-runners"
POOL_LABEL = "doks.digitalocean.com/node-pool"
BASELINE = "github-runners-pool-16g"
PRIMARY = "github-runners-burst-amd-16g"
FALLBACK = "github-runners-burst-intel-16g"
RUNNER_POOLS = (BASELINE, PRIMARY, FALLBACK)
EXPANDER_CONFIGMAP = "cluster-autoscaler-priority-expander"
EXPANDER_MANAGED_LABEL = "doks.digitalocean.com/managed"
ER_JOB_FIELDS = ("jobRequestId", "jobId", "jobRepositoryName", "jobWorkflowRef", "workflowRunId")
PROBE_JOB = re.compile(r"^(batch|continuous) ([0-9]+)$")
POLL_SECONDS = 60
CLEANUP_POLL_SECONDS = 15
CLEANUP_WAIT_SECONDS = 10 * 60
RESTORE_WAIT_SECONDS = 30 * 60
# Phase E: after the smoke probe the operator dispatches Rebalance Runners to
# retire idle runners left on burst nodes (a batch of N jobs runs minRunners + N
# runners, Ruling 43), so the warm floor returns to baseline.
WARM_WAIT_SECONDS = 30 * 60
# jobs_killed: a run created this long before Phase C can still run jobs in
# it (re-runs up to 30 days after the initial run, plus the 35-day run limit).
RUN_LOOKBACK_DAYS = 65
RUN_LIST_CAP = 1000
RUN_MIN_SLICE_SECONDS = 3600
GATE_EVERY_POLLS = 5
READ_ATTEMPTS = 3
READ_BACKOFF_SECONDS = (5, 15)
EVIDENCE_WORKFLOW = ".github/workflows/runner-acceptance-evidence.yml"
RUNNER_NAME_PREFIX = "redducklabs-runners-"
REDACTED = "<redacted>"
# Phase A network probe (runner network isolation): the probe run's
# network-probe job prints one line "NETWORK_PROBE_RESULT <json>".
NETWORK_PROBE_JOB = "network-probe"
NETWORK_PROBE_MARKER = "NETWORK_PROBE_RESULT "
IPV4 = re.compile(r"^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$")


class ReadError(Exception):
    pass


# --- process helpers ---------------------------------------------------------


def run_once(argv):
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as error:
        raise ReadError(f"could not run {argv[0]}: {error}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()
        raise ReadError(f"'{' '.join(argv[:5])}' failed (exit {completed.returncode})"
                        + (f": {detail[0][:200]}" if detail else ""))
    return completed.stdout


def run(argv):
    """A read-only call, retried on failure (READ_ATTEMPTS, backoff between)."""
    for attempt in range(1, READ_ATTEMPTS + 1):
        try:
            return run_once(argv)
        except ReadError as error:
            if attempt == READ_ATTEMPTS:
                raise
            log(f"RETRY: attempt {attempt}/{READ_ATTEMPTS} failed: {error}")
            sleep(READ_BACKOFF_SECONDS[attempt - 1])
    raise AssertionError("unreachable")


ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def job_logs(repository, job_id):
    """A job's log as plain text.

    Job logs carry terminal escape sequences (colored run-step echoes), and
    gh refuses to print such a response without --allow-escape-sequences
    (live Phase A evidence run 40797455827). CSI sequences are removed before
    any line is parsed; any other escape left in the text (OSC, a lone ESC)
    fails the read rather than parsing a line normalization may have altered.
    """
    text = ANSI_ESCAPE.sub("", run(["gh", "api", "--allow-escape-sequences",
                                    f"repos/{repository}/actions/jobs/{job_id}/logs"]))
    if "\x1b" in text:
        raise ReadError(f"job {job_id} log of {repository} contains an unsupported terminal escape sequence")
    return text


def run_json(argv):
    text = run(argv)
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ReadError(f"'{' '.join(argv[:5])}' did not return JSON: {error}") from error


def now():
    text = run_once(shlex.split(os.environ.get("NOW_CMD") or "date +%s")).strip()
    if not text.isdigit():
        raise ReadError("NOW_CMD did not print an integer epoch")
    return int(text)


def sleep(seconds):
    run_once(shlex.split(os.environ.get("SLEEP_CMD") or "sleep") + [str(seconds)])


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def trim_ts(value):
    """GitHub log and API timestamps -> second precision ISO-8601 UTC."""
    if not value:
        return None
    match = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", value)
    return match.group(1) + "Z" if match else None


def gh_api(path):
    return run_json(["gh", "api", path])


def gh_jobs(repository, run_id):
    pages = run_json(["gh", "api", "--paginate", "--slurp",
                      f"repos/{repository}/actions/runs/{run_id}/attempts/1/jobs?per_page=100"])
    jobs = []
    for page in pages if isinstance(pages, list) else []:
        jobs.extend(page.get("jobs") or [])
    return jobs


def load_state(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as stream:
        json.dump(state, stream, indent=1, sort_keys=True)
    os.replace(tmp, path)


def log(message):
    print(message, flush=True)


# --- verify ------------------------------------------------------------------


def run_identity(repository, run_id):
    data = gh_api(f"repos/{repository}/actions/runs/{run_id}")
    return {
        "id": data.get("id"),
        "repository": (data.get("repository") or {}).get("full_name"),
        "workflow_path": data.get("path"),
        "head_sha": data.get("head_sha"),
        "head_branch": data.get("head_branch"),
        "event": data.get("event"),
        "attempt": data.get("run_attempt"),
        "status": data.get("status"),
        "conclusion": data.get("conclusion"),
        "created_at": trim_ts(data.get("created_at")),
        "started": trim_ts(data.get("run_started_at")),
        "updated_at": trim_ts(data.get("updated_at")),
        "completed_at": trim_ts(data.get("updated_at")) if data.get("status") == "completed" else None,
    }


def resolve_tag(tag):
    ref = gh_api(f"repos/{PROBE_REPOSITORY}/git/ref/tags/{tag}")
    obj = ref.get("object") or {}
    if obj.get("type") != "tag":
        raise ReadError(f"tag {tag} is not an annotated tag (ref object type {obj.get('type')!r})")
    annotated = gh_api(f"repos/{PROBE_REPOSITORY}/git/tags/{obj.get('sha')}")
    target = annotated.get("object") or {}
    if target.get("type") != "commit":
        raise ReadError(f"tag {tag} does not target a commit")
    return target.get("sha")


def verify_probe(args, state):
    run_data = run_identity(PROBE_REPOSITORY, args.probe_run_id)
    problems = []
    if run_data["repository"] != PROBE_REPOSITORY:
        problems.append(f"repository is {run_data['repository']!r}, expected {PROBE_REPOSITORY}")
    if run_data["workflow_path"] != PROBE_WORKFLOW:
        problems.append(f"workflow is {run_data['workflow_path']!r}, expected {PROBE_WORKFLOW}")
    if run_data["head_sha"] != args.expected_workflow_sha:
        problems.append(f"headSha {run_data['head_sha']} is not expected_workflow_sha {args.expected_workflow_sha}")
    if run_data["event"] != "workflow_dispatch":
        problems.append(f"event is {run_data['event']!r}, expected workflow_dispatch")
    if run_data["attempt"] != 1:
        problems.append(f"attempt is {run_data['attempt']!r}, expected 1")
    if run_data["head_branch"] != args.dispatch_tag:
        problems.append(f"run was dispatched from {run_data['head_branch']!r}, not tag {args.dispatch_tag}")
    if problems:
        raise ReadError("probe run " + "; ".join(problems))
    tag_sha = resolve_tag(args.dispatch_tag)
    if tag_sha != args.expected_workflow_sha:
        raise ReadError(f"tag {args.dispatch_tag} resolves to {tag_sha}, not expected_workflow_sha")
    state["probe"] = {"repository": PROBE_REPOSITORY, "workflow_path": PROBE_WORKFLOW,
                      "dispatch_tag": args.dispatch_tag, "expected_workflow_sha": args.expected_workflow_sha,
                      "tag_sha": tag_sha, "run": run_data, "drain": None}


def precedes(base, head):
    """True when commit base is a strict ancestor of head in this repository."""
    return gh_api(f"repos/{FLEET_REPOSITORY}/compare/{base}...{head}").get("status") == "ahead"


def verify_fleet_run(run_id, workflow, expected_sha, label, earlier_ok=False):
    """earlier_ok also accepts a run at a commit before the reviewed SHA
    (Ruling 50: the Phase A record outlives fixes merged after Phase A)."""
    data = run_identity(FLEET_REPOSITORY, run_id)
    problems = []
    if data["repository"] != FLEET_REPOSITORY or data["workflow_path"] != workflow:
        problems.append(f"is {data['repository']}:{data['workflow_path']}, expected {FLEET_REPOSITORY}:{workflow}")
    if data["head_sha"] != expected_sha and not (earlier_ok and data["head_sha"] and precedes(data["head_sha"], expected_sha)):
        problems.append(f"ran at {data['head_sha']}, not the reviewed SHA {expected_sha}"
                        + (" or a commit before it" if earlier_ok else ""))
    if data["event"] != "workflow_dispatch":
        problems.append(f"event is {data['event']!r}")
    if data["status"] == "completed" and data["conclusion"] != "success":
        problems.append(f"concluded {data['conclusion']!r}")
    if problems:
        raise ReadError(f"{label} run {run_id} " + "; ".join(problems))
    return data


def run_view_jobs(run_id):
    return run_json(["gh", "run", "view", str(run_id), "-R", FLEET_REPOSITORY, "--json", "jobs"]).get("jobs") or []


def find_job(jobs, name):
    matches = [job for job in jobs if job.get("name") == name]
    return matches[0] if len(matches) == 1 else None


REQUIRED_ARGS = {
    "probe": ("probe_run_id", "dispatch_tag", "expected_workflow_sha"),
    "A": (), "B": (), "C": ("phase_c_run_id",), "D": ("drain_run_id",),
    "E": ("rollback_run_id", "baseline_run_id"),
}


def missing_args(args, names):
    return [name for name in names if not getattr(args, name, None)]


def cmd_verify_probe(args):
    state = {"phase": args.phase, "expected_sha": args.expected_sha, "cluster_name": args.cluster_name,
             "probe": None, "snapshots": {"pods": {}, "nodes": {}, "events": {}, "ephemeral_runners": {}},
             "pool_state_checks": [], "pools_before": None, "polls": 0}
    if args.phase != "C":
        missing = missing_args(args, REQUIRED_ARGS["probe"])
        if missing:
            log(f"REJECTED: phase {args.phase} requires {', '.join(missing)}")
            return 1
        try:
            verify_probe(args, state)
        except ReadError as error:
            log(f"REJECTED: {error}")
            return 1
    save_state(args.state, state)
    log(f"VERIFIED: phase {args.phase} probe run" if state["probe"] else f"VERIFIED: phase {args.phase} has no probe run")
    return 0


def baseline_record(run_id, expected_sha):
    """Baseline pool ID from a passing Phase A evidence record at the reviewed SHA
    or a commit before it."""
    data = verify_fleet_run(run_id, EVIDENCE_WORKFLOW, expected_sha, "Phase A evidence", earlier_ok=True)
    if data["status"] != "completed" or data["conclusion"] != "success":
        raise ReadError(f"Phase A evidence run {run_id} has not completed successfully")
    directory = tempfile.mkdtemp()
    run(["gh", "run", "download", str(run_id), "-R", FLEET_REPOSITORY, "-n", "acceptance-A", "-D", directory])
    with open(os.path.join(directory, "acceptance-A.json"), encoding="utf-8") as stream:
        record = json.load(stream)
    if record.get("phase") != "A" or (record.get("verdict") or {}).get("pass") is not True:
        raise ReadError(f"run {run_id} does not hold a passing Phase A record")
    pool_id = ((record.get("pools_before") or {}).get(BASELINE) or {}).get("id")
    if not pool_id:
        raise ReadError(f"the Phase A record of run {run_id} has no baseline pool ID")
    return {"run_id": data["id"], "pool_id": pool_id}


def cmd_verify_anchors(args):
    state = load_state(args.state)
    phase = state["phase"]
    missing = missing_args(args, REQUIRED_ARGS[phase])
    if missing:
        log(f"REJECTED: phase {phase} requires {', '.join(missing)}")
        return 1
    expected_sha = state["expected_sha"]
    try:
        if phase == "D":
            state["drain_run"] = verify_fleet_run(args.drain_run_id, DEPLOY_WORKFLOW, expected_sha, "drain")
        if phase == "C":
            state["phase_c_run"] = verify_fleet_run(args.phase_c_run_id, SCALE_WORKFLOW, expected_sha, "Phase C")
        if phase == "E":
            data = verify_fleet_run(args.rollback_run_id, DEPLOY_WORKFLOW, expected_sha, "rollback")
            if data["status"] != "completed":
                raise ReadError(f"rollback run {args.rollback_run_id} has not completed")
            job = find_job(run_view_jobs(args.rollback_run_id), ROLLBACK_JOB)
            readback = [step for step in (job or {}).get("steps") or [] if step.get("name") == ROLLBACK_READBACK_STEP]
            data.update(job_name=(job or {}).get("name"),
                        readback_step=readback[0].get("conclusion") if len(readback) == 1 else None)
            state["rollback_run"] = data
            state["recorded_baseline"] = baseline_record(args.baseline_run_id, expected_sha)
    except (ReadError, OSError, ValueError) as error:
        log(f"REJECTED: {error}")
        return 1
    save_state(args.state, state)
    log(f"VERIFIED: phase {phase} anchor runs")
    return 0


# --- snapshots ---------------------------------------------------------------


def node_pool_of(node):
    return ((node.get("metadata") or {}).get("labels") or {}).get(POOL_LABEL)


def ready_at(node):
    for condition in (node.get("status") or {}).get("conditions") or []:
        if condition.get("type") == "Ready" and condition.get("status") == "True":
            return trim_ts(condition.get("lastTransitionTime"))
    return None


def pod_ready(pod):
    """Pod condition Ready=True (every container passed its readiness)."""
    return any(condition.get("type") == "Ready" and condition.get("status") == "True"
               for condition in (pod.get("status") or {}).get("conditions") or [])


def required_baseline(pod):
    terms = ((((pod.get("spec") or {}).get("affinity") or {}).get("nodeAffinity") or {})
             .get("requiredDuringSchedulingIgnoredDuringExecution") or {}).get("nodeSelectorTerms") or []
    return any(expr.get("key") == POOL_LABEL and expr.get("values") == [BASELINE]
               for term in terms for expr in term.get("matchExpressions") or [])


def redacted_spec(spec):
    """The pod spec with every literal env value replaced; names and valueFrom kept."""
    spec = json.loads(json.dumps(spec or {}))
    for key in ("containers", "initContainers", "ephemeralContainers"):
        for container in spec.get(key) or []:
            for entry in container.get("env") or []:
                if "value" in entry:
                    entry["value"] = REDACTED
    return spec


def container_statuses(status):
    """Restart, state and last-termination facts (OOMKilled lives in lastState)."""
    result = []
    for key in ("initContainerStatuses", "containerStatuses"):
        for item in (status or {}).get(key) or []:
            state = {name: {k: v for k, v in (detail or {}).items() if k != "message"}
                     for name, detail in (item.get("state") or {}).items()}
            terminated = ((item.get("lastState") or {}).get("terminated")) or {}
            result.append({"name": item.get("name"), "restart_count": item.get("restartCount"), "state": state,
                           "last_terminated_reason": terminated.get("reason"),
                           "last_terminated_exit_code": terminated.get("exitCode")})
    return result


def cluster_and_pools(cluster_name):
    clusters = run_json(["doctl", "kubernetes", "cluster", "list", "-o", "json"])
    matches = [c for c in clusters if isinstance(c, dict) and c.get("name") == cluster_name] if isinstance(clusters, list) else []
    if len(matches) != 1:
        raise ReadError(f"expected exactly one cluster named {cluster_name}")
    cluster = matches[0]
    pools = normalize_pool_list(
        run_json(["doctl", "kubernetes", "cluster", "node-pool", "list", cluster["id"], "-o", "json"]))
    if not isinstance(pools, list):
        raise ReadError("doctl node-pool list is not a JSON array")
    return cluster, pools


def runner_job(item):
    """The job fields of an EphemeralRunner's status (empty when it holds none)."""
    status = item.get("status") or {}
    return {field: status.get(field) for field in ER_JOB_FIELDS if status.get(field) not in (None, "", 0)}


RUNNER_LABEL = ("node-type", "github-runner")
RUNNER_TAINT_KEY = "github-runner"


def node_pool_identity(entry):
    """A node pool's ID, name, labels, taints and whether it is a runner pool
    (runner label node-type=github-runner or the github-runner taint)."""
    labels = entry.get("labels") or {}
    taints = [{str(key).lower(): value for key, value in taint.items()}
              for taint in entry.get("taints") or [] if isinstance(taint, dict)]
    runner = labels.get(RUNNER_LABEL[0]) == RUNNER_LABEL[1] or any(t.get("key") == RUNNER_TAINT_KEY for t in taints)
    return {"id": entry.get("id"), "name": entry.get("name"), "labels": labels, "taints": taints, "runner": runner}


def pool_summary(pools, registered):
    summary = {}
    for entry in pools:
        name = entry.get("name")
        if name in RUNNER_POOLS:
            summary[name] = {"id": entry.get("id"), "min": entry.get("min_nodes"), "max": entry.get("max_nodes"),
                             "count": entry.get("count"), "nodes": registered.get(name, 0)}
    return summary


def pool_state_check(state, node_items):
    command = shlex.split(os.environ.get("POOL_STATE_CMD") or os.path.join(SCRIPT_DIR, "verify-runner-pool-state.sh"))
    completed = subprocess.run(command + ["--cluster-name", state["cluster_name"], "--operation", "status"],
                               capture_output=True, text=True, check=False)
    lines = [line for line in (completed.stdout + completed.stderr).splitlines() if line.startswith(("STATE:", "REJECTED:", "ERROR:"))]
    ready = sorted(item["metadata"]["name"] for item in node_items if ready_at(item))
    return {"at": iso(now()), "pass": completed.returncode == 0, "state": lines[0] if lines else "",
            "ready_nodes": ready}


def snapshot(state, final=False):
    shots = state["snapshots"]
    stamp = iso(now())
    nodes = run_json(["kubectl", "get", "nodes", "-l", "node-type=github-runner", "-o", "json"]).get("items") or []
    for item in nodes:
        meta = item.get("metadata") or {}
        entry = shots["nodes"].setdefault(meta.get("name"), {"first_seen": stamp})
        entry.update(name=meta.get("name"), pool=node_pool_of(item), created_at=trim_ts(meta.get("creationTimestamp")),
                     ready_at=ready_at(item) or entry.get("ready_at"),
                     kubelet_version=((item.get("status") or {}).get("nodeInfo") or {}).get("kubeletVersion"),
                     last_seen=stamp)
    # The pod read's own interval, retries and backoff included: the placement
    # it returns was observed somewhere in [requested_at, observed_at], which
    # the verdict requires to lie wholly inside the hold (PR #41 review 2).
    requested_at = iso(now())
    pods = run_json(["kubectl", "get", "pods", "-n", NAMESPACE, "-l", SCALE_SET_SELECTOR, "-o", "json"]).get("items") or []
    observed_at = iso(now())
    # The EphemeralRunner read that follows has its own interval and is kept
    # whole (every runner, with or without a pod in the read above): its job
    # fields show whether the fleet was shared, which the verdict judges from
    # this list alone, independently of pod placement (Ruling 44 revised,
    # PR #42 review 2).
    runners_requested_at = iso(now())
    runners = run_json(["kubectl", "get", "ephemeralrunners.actions.github.com", "-n", NAMESPACE, "-o", "json"]).get("items") or []
    runners_observed_at = iso(now())
    # Placement as this collection saw it (Ruling 43): the per-UID snapshot
    # below keeps only the latest node, so the verdict judges placement during
    # the hold from these timestamped observations, unscheduled pods included.
    node_pools = {(item.get("metadata") or {}).get("name"): node_pool_of(item) for item in nodes}
    runner_jobs = {(item.get("metadata") or {}).get("name"): runner_job(item) for item in runners}
    observed = []
    for item in pods:
        meta = item.get("metadata") or {}
        node_name = (item.get("spec") or {}).get("nodeName") or None
        observed.append({"uid": meta.get("uid"), "runner_name": meta.get("name"), "node": node_name,
                         "pool": node_pools.get(node_name) if node_name else None,
                         "phase": (item.get("status") or {}).get("phase"),
                         "terminating": bool(meta.get("deletionTimestamp")),
                         "ephemeral_runner": meta.get("name") in runner_jobs,
                         "job": runner_jobs.get(meta.get("name")) or {}})
    assignments = [{"name": (item.get("metadata") or {}).get("name"), "uid": (item.get("metadata") or {}).get("uid"),
                    "phase": (item.get("status") or {}).get("phase"),
                    "terminating": bool((item.get("metadata") or {}).get("deletionTimestamp")),
                    "job": runner_job(item)} for item in runners]
    state.setdefault("pod_collections", []).append(
        {"requested_at": requested_at, "observed_at": observed_at,
         "pods": sorted(observed, key=lambda pod: str(pod["runner_name"])),
         "ephemeral_runners": {"requested_at": runners_requested_at, "observed_at": runners_observed_at,
                               "items": sorted(assignments, key=lambda runner: str(runner["name"]))}})
    for item in pods:
        meta = item.get("metadata") or {}
        entry = shots["pods"].setdefault(meta.get("uid"), {"first_seen": stamp})
        node_name = (item.get("spec") or {}).get("nodeName") or entry.get("node")
        entry.update(uid=meta.get("uid"), runner_name=meta.get("name"), node=node_name,
                     created_at=trim_ts(meta.get("creationTimestamp")),
                     annotations={k: v for k, v in (meta.get("annotations") or {}).items()
                                  if k.startswith("cluster-autoscaler.kubernetes.io/")},
                     required_baseline_affinity=required_baseline(item),
                     spec=redacted_spec(item.get("spec")),
                     container_statuses=container_statuses(item.get("status")) or entry.get("container_statuses", []),
                     phase=(item.get("status") or {}).get("phase"), ready=pod_ready(item),
                     terminating=bool(meta.get("deletionTimestamp")), last_seen=stamp)
    for item in runners:
        meta, status = item.get("metadata") or {}, item.get("status") or {}
        shots["ephemeral_runners"][meta.get("name")] = {
            "name": meta.get("name"), "phase": status.get("phase"), "last_seen": stamp,
            "terminating": bool(meta.get("deletionTimestamp")), "job": runner_job(item)}
    events = run_json(["kubectl", "get", "events", "-A", "-o", "json"]).get("items") or []
    for item in events:
        meta = item.get("metadata") or {}
        involved = item.get("involvedObject") or {}
        if meta.get("namespace") != NAMESPACE and involved.get("kind") != "Node" \
                and (item.get("source") or {}).get("component") != "cluster-autoscaler":
            continue
        shots["events"][meta.get("uid")] = {
            "uid": meta.get("uid"), "reason": item.get("reason"), "type": item.get("type"),
            "namespace": meta.get("namespace"), "involved_kind": involved.get("kind"),
            "involved_name": involved.get("name"), "message": (item.get("message") or "")[:300],
            "count": item.get("count"),
            "first_timestamp": trim_ts(item.get("firstTimestamp") or item.get("eventTime") or meta.get("creationTimestamp")),
            "last_timestamp": trim_ts(item.get("lastTimestamp") or item.get("eventTime") or meta.get("creationTimestamp"))}
    pools_requested_at = iso(now())
    _, pools = cluster_and_pools(state["cluster_name"])
    pools_observed_at = iso(now())
    registered = {}
    for item in nodes:
        registered[node_pool_of(item)] = registered.get(node_pool_of(item), 0) + 1
    summary = pool_summary(pools, registered)
    # Every node pool of the cluster with its labels and taints, so the
    # verdict can resolve a scale-up event's node group ID and tell runner
    # pools from pools that cannot host runner pods (Ruling 46).
    state["node_pools"] = [node_pool_identity(entry) for entry in pools if isinstance(entry, dict)]
    # The autoscaler's per-pool targets (count) over time, kept as
    # diagnostics: periodic reads cannot order scale-up decisions, which the
    # verdict judges from the autoscaler's scale-up events (Ruling 44 revised).
    state.setdefault("pool_collections", []).append(
        {"requested_at": pools_requested_at, "observed_at": pools_observed_at,
         "pools": {name: {key: entry[key] for key in ("count", "min", "max", "nodes")}
                   for name, entry in summary.items()}})
    if state.get("pools_before") is None:
        state["pools_before"] = summary
    state["pools_latest"] = summary
    known = sorted(item["metadata"]["name"] for item in nodes)
    # The membership of this collection, kept apart from the historical
    # snapshots: an object absent from the latest lists is not current.
    state["latest_collection"] = {
        "at": stamp, "nodes": known,
        "pods": sorted(str((item.get("metadata") or {}).get("uid")) for item in pods),
        "ephemeral_runners": sorted(str((item.get("metadata") or {}).get("name")) for item in runners)}
    if final or state["polls"] % GATE_EVERY_POLLS == 0 or known != state.get("last_node_names"):
        state["pool_state_checks"].append(pool_state_check(state, nodes))
    state["last_node_names"] = known
    state["polls"] += 1


# --- watch -------------------------------------------------------------------


def watched_runs(state):
    runs = []
    if state.get("probe"):
        runs.append((PROBE_REPOSITORY, state["probe"]["run"]["id"]))
    for key in ("drain_run", "phase_c_run"):
        if state.get(key):
            runs.append((FLEET_REPOSITORY, state[key]["id"]))
    return runs


def cmd_watch(args):
    state = load_state(args.state)
    try:
        deadline = now() + args.deadline_minutes * 60
        while True:
            snapshot(state)
            pending = [f"{repo}#{run_id}" for repo, run_id in watched_runs(state)
                       if run_identity(repo, run_id)["status"] != "completed"]
            save_state(args.state, state)
            if not pending:
                log(f"WATCH: all watched runs completed after {state['polls']} polls")
                return 0
            if now() >= deadline:
                log(f"DEADLINE: {', '.join(pending)} not completed within {args.deadline_minutes} minutes")
                return 1
            log(f"WATCH: poll {state['polls']}: waiting for {', '.join(pending)}")
            sleep(POLL_SECONDS)
    except ReadError as error:
        save_state(args.state, state)
        log(f"ERROR: {error}")
        return 1


# --- finalize ----------------------------------------------------------------


def probe_run_jobs(state):
    jobs = []
    for job in gh_jobs(PROBE_REPOSITORY, state["probe"]["run"]["id"]):
        jobs.append({"id": job.get("id"), "name": job.get("name"), "status": job.get("status"),
                     "conclusion": job.get("conclusion"), "runner_name": job.get("runner_name"),
                     "created_at": trim_ts(job.get("created_at")), "started_at": trim_ts(job.get("started_at")),
                     "completed_at": trim_ts(job.get("completed_at"))})
    return jobs


def probe_mode(jobs):
    modes = {PROBE_JOB.match(job["name"] or "").group(1) for job in jobs if PROBE_JOB.match(job["name"] or "")}
    return modes.pop() if len(modes) == 1 else None


def drain_anchor(state):
    run_data = run_identity(FLEET_REPOSITORY, state["drain_run"]["id"])
    job = find_job(run_view_jobs(state["drain_run"]["id"]), DRAIN_JOB)
    anchor = {"run_id": run_data["id"], "repository": run_data["repository"],
              "workflow_path": run_data["workflow_path"], "head_sha": run_data["head_sha"],
              "conclusion": run_data["conclusion"], "operation_job": None,
              "started": None, "effective": None, "completed": None}
    if job is None or job.get("conclusion") == "skipped":
        return anchor
    anchor["operation_job"] = job.get("name")
    steps = [step for step in job.get("steps") or [] if step.get("name") == DRAIN_STEP]
    if len(steps) == 1:
        # One step runs the Helm upgrade and then the wait (scripts/drain-runners.sh),
        # so its start bounds the upgrade and its completion is the end of the wait.
        anchor["started"] = trim_ts(steps[0].get("startedAt"))
        anchor["completed"] = trim_ts(steps[0].get("completedAt"))
    logs = job_logs(FLEET_REPOSITORY, job.get("databaseId"))
    for line in logs.splitlines():
        if DRAIN_READBACK in line:
            anchor["effective"] = trim_ts(line.split(" ", 1)[0])
            break
    return anchor


def trusted_repositories():
    names = []
    with open(os.path.join(REPO_ROOT, "deploy", "trusted-runner-repositories.txt"), encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if line and not line.startswith("#"):
                names.append(line.split(":", 1)[1])
    return names


def to_epoch(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def runs_created_between(repo, start, end):
    """Workflow runs of ORG/repo created in [start, end] (epochs), complete.

    The list endpoint returns at most RUN_LIST_CAP results for a search with
    the created filter, so a range whose total_count exceeds it is bisected
    (bounded ranges overlap at their endpoints; callers deduplicate by ID)."""
    pages = run_json(["gh", "api", "--paginate", "--slurp",
                      f"repos/{ORG}/{repo}/actions/runs?created={iso(start)}..{iso(end)}&per_page=100"])
    if not isinstance(pages, list) or not all(isinstance(page, dict) for page in pages):
        raise ReadError(f"workflow run list of {ORG}/{repo} is not a list of pages")
    total = max((page.get("total_count") or 0 for page in pages), default=0)
    if total > RUN_LIST_CAP:
        if end - start <= RUN_MIN_SLICE_SECONDS:
            raise ReadError(f"{ORG}/{repo} has {total} runs created in {iso(start)}..{iso(end)}, "
                            f"more than the {RUN_LIST_CAP}-result search limit")
        middle = start + (end - start) // 2
        return runs_created_between(repo, start, middle) + runs_created_between(repo, middle, end)
    return [run_data for page in pages for run_data in page.get("workflow_runs") or []]


def jobs_killed(state, window_start, window_end):
    """Fleet jobs that ended cancelled or failed while Phase C ran.

    Runs are not selected by a recent created_at: a run created long before
    Phase C can be re-run during it, and the jobs of its later attempts keep
    the run's original created_at. GitHub's run list has no updated-time
    filter, so every run created from RUN_LOOKBACK_DAYS before the window (a
    run can be re-run up to 30 days after the initial run, and a run is
    limited to 35 days) up to the window end is listed; a run last updated
    before the window is skipped (a job completing in the window updates its
    run), and the jobs of every attempt (filter=all) are read for the rest.

    A job is a fleet job when its runner name carries the scale set's prefix
    (ARC names runners "redducklabs-runners-<set>-runner-<id>"). Every
    cancelled or failed fleet job completed in the window counts, including a
    genuine test failure: the check fails closed and Phase C is re-run.
    """
    start, end = int(to_epoch(window_start)), int(to_epoch(window_end))
    killed = []
    for repo in trusted_repositories():
        seen = set()
        for run_data in runs_created_between(repo, start - RUN_LOOKBACK_DAYS * 86400, end):
            if run_data.get("id") in seen:
                continue
            seen.add(run_data.get("id"))
            updated = trim_ts(run_data.get("updated_at"))
            if updated and to_epoch(updated) < start:
                continue
            job_pages = run_json(["gh", "api", "--paginate", "--slurp",
                                  f"repos/{ORG}/{repo}/actions/runs/{run_data.get('id')}/jobs?filter=all&per_page=100"])
            for job in (job for page in job_pages if isinstance(page, dict) for job in page.get("jobs") or []):
                completed = trim_ts(job.get("completed_at"))
                if not str(job.get("runner_name") or "").startswith(RUNNER_NAME_PREFIX) or not completed:
                    continue
                if not start <= to_epoch(completed) <= end:
                    continue
                if job.get("conclusion") in ("cancelled", "failure"):
                    killed.append({"repository": f"{ORG}/{repo}", "run_id": run_data.get("id"),
                                   "run_attempt": job.get("run_attempt"), "id": job.get("id"),
                                   "runner_name": job.get("runner_name"), "conclusion": job.get("conclusion")})
    return killed


def phase_c_evidence(state):
    run_data = run_identity(FLEET_REPOSITORY, state["phase_c_run"]["id"])
    job = find_job(run_view_jobs(state["phase_c_run"]["id"]), PHASE_C_JOB)
    run_info = {"id": run_data["id"], "repository": run_data["repository"],
                "workflow_path": run_data["workflow_path"], "head_sha": run_data["head_sha"],
                "conclusion": run_data["conclusion"], "job_name": (job or {}).get("name"),
                "started": run_data["started"], "completed": run_data["updated_at"]}
    directory = tempfile.mkdtemp()
    run(["gh", "run", "download", str(run_data["id"]), "-R", FLEET_REPOSITORY, "-n", PHASE_C_ARTIFACT, "-D", directory])
    with open(os.path.join(directory, "phase-c-evidence.json"), encoding="utf-8") as stream:
        evidence = json.load(stream)
    killed = jobs_killed(state, run_info["started"], run_info["completed"])
    evidence.update(jobs_killed=len(killed), killed_jobs=killed,
                    jobs_killed_note="measured by runner-acceptance-evidence from GitHub job conclusions of "
                                     f"jobs on {RUNNER_NAME_PREFIX}* runners completed during the Phase C run, "
                                     f"in every attempt of every run created up to {RUN_LOOKBACK_DAYS} days before it")
    return run_info, evidence


def expander_readback(state):
    cluster, _ = cluster_and_pools(state["cluster_name"])
    configmap = run_json(["kubectl", "get", "configmap", EXPANDER_CONFIGMAP, "-n", "kube-system", "-o", "json"])
    try:
        priorities = yaml.safe_load(((configmap.get("data") or {}).get("priorities")) or "")
    except yaml.YAMLError:
        priorities = None
    if isinstance(priorities, dict):
        priorities = {str(key): value for key, value in priorities.items()}
    return {"expanders": (cluster.get("cluster_autoscaler_configuration") or {}).get("expanders") or [],
            "priorities": priorities,
            "managed": EXPANDER_MANAGED_LABEL in ((configmap.get("metadata") or {}).get("labels") or {})}


def trust_readback(state):
    command = shlex.split(os.environ.get("TRUST_VERIFY_CMD") or os.path.join(SCRIPT_DIR, "verify-runner-trust-boundary.sh"))
    completed = subprocess.run(command + ["--expected-sha", state["expected_sha"], "--verify-only"],
                               capture_output=True, text=True, check=False)
    tail = (completed.stdout + completed.stderr).strip().splitlines()[-3:]
    return {"pass": completed.returncode == 0, "output_tail": tail}


def wait_until(state, seconds, done, label):
    deadline = now() + seconds
    while True:
        snapshot(state)
        if done(state):
            return True
        if now() >= deadline:
            log(f"WAIT: {label} not reached within {seconds // 60} minutes")
            return False
        log(f"WAIT: {label}")
        sleep(POLL_SECONDS)


def restored(state):
    pools = state.get("pools_latest") or {}
    return ((pools.get(PRIMARY) or {}).get("min"), (pools.get(PRIMARY) or {}).get("max")) == (0, 6) \
        and ((pools.get(FALLBACK) or {}).get("min"), (pools.get(FALLBACK) or {}).get("max")) == (0, 2)


def warm_runners(state):
    """Warm runners of the latest collection only (never the historical snapshots).

    A warm runner is a pod in the latest pod list that is Running, has the pod
    condition Ready=True and no deletionTimestamp, whose EphemeralRunner is in
    the latest EphemeralRunner list, Running, not terminating and holds no job,
    on a node in the latest node list. Each entry records the collection time
    it was observed at (observed_at == latest_collection_at)."""
    latest = state.get("latest_collection")
    if not latest:
        return []
    shots = state["snapshots"]
    pods, runners = set(latest["pods"]), set(latest["ephemeral_runners"])
    nodes = shots["nodes"]
    warm = []
    for uid in sorted(pods):
        pod = shots["pods"].get(uid) or {}
        runner = shots["ephemeral_runners"].get(pod.get("runner_name"))
        if runner is None or runner.get("name") not in runners or pod.get("node") not in latest["nodes"]:
            continue
        if pod.get("phase") != "Running" or pod.get("ready") is not True or pod.get("terminating") is not False:
            continue
        if runner.get("job") or runner.get("phase") != "Running" or runner.get("terminating") is not False:
            continue
        warm.append({"runner_name": pod["runner_name"], "node": pod["node"],
                     "pool": (nodes.get(pod["node"]) or {}).get("pool"), "observed_at": latest["at"],
                     "phase": pod["phase"], "ready": True, "terminating": False, "idle": True})
    return warm


def two_warm_on_baseline(state):
    warm = warm_runners(state)
    return len(warm) == 2 and all(runner["pool"] == BASELINE for runner in warm)


def arc_contract(state):
    """ARC contract from the final pool-state check; None when it did not pass."""
    checks = state["pool_state_checks"]
    if not checks or not checks[-1]["pass"]:
        return None
    match = re.search(r"\barc=(\S+)", checks[-1]["state"])
    return match.group(1) if match else None


def split_endpoint(value):
    """'10.245.1.2:443' -> ('10.245.1.2', 443); None when malformed."""
    host, _, port = str(value or "").rpartition(":")
    if not IPV4.match(host) or not port.isdigit() or not 0 < int(port) < 65536:
        return None
    return host, int(port)


NETWORK_TARGET_KEYS = ("worker_node", "runner_node", "runner_node_public", "service", "pod")


def node_with_address(nodes, address, kind):
    """The node whose status.addresses holds <address> as <kind> (InternalIP or ExternalIP)."""
    for node in nodes:
        for entry in (node.get("status") or {}).get("addresses") or []:
            if entry.get("type") == kind and entry.get("address") == address:
                return {"node": (node.get("metadata") or {}).get("name"), "pool": node_pool_of(node),
                        "address_type": kind}
    return None


def verify_network_targets(targets):
    """Resolve the probe's targets in the cluster (read-only), so a bogus address
    that nothing listens on cannot pass as 'blocked'.

    Also records the kubernetes.default ClusterIP (the default/kubernetes
    Service) so the verdict can pin the kubernetes-service target, and whether
    the pod is one the runner policy's DNS rule deliberately allows (a kube-dns
    pod in kube-system), which cannot serve as a forbidden target."""
    checks = {key: None for key in NETWORK_TARGET_KEYS}
    checks["kubernetes_service"] = None
    nodes = run_json(["kubectl", "get", "nodes", "-o", "json"]).get("items") or []
    for key, kind in (("worker_node", "InternalIP"), ("runner_node", "InternalIP"),
                      ("runner_node_public", "ExternalIP")):
        if IPV4.match(str(targets.get(key) or "")):
            checks[key] = node_with_address(nodes, targets[key], kind)
    endpoint = split_endpoint(targets.get("service"))
    for service in run_json(["kubectl", "get", "services", "-A", "-o", "json"]).get("items") or []:
        metadata, spec = service.get("metadata") or {}, service.get("spec") or {}
        if (metadata.get("namespace"), metadata.get("name")) == ("default", "kubernetes") and spec.get("clusterIP"):
            checks["kubernetes_service"] = {"address": f"{spec['clusterIP']}:443"}
        if endpoint and checks["service"] is None \
                and endpoint[0] in ([spec.get("clusterIP")] + list(spec.get("clusterIPs") or [])):
            checks["service"] = {"namespace": metadata.get("namespace"), "name": metadata.get("name"),
                                 "type": spec.get("type"),
                                 "port_declared": endpoint[1] in [p.get("port") for p in spec.get("ports") or []]}
    endpoint = split_endpoint(targets.get("pod"))
    if endpoint:
        pods = run_json(["kubectl", "get", "pods", "-A", "--field-selector", f"status.podIP={endpoint[0]}",
                         "-o", "json"]).get("items") or []
        for pod in pods:
            if (pod.get("status") or {}).get("podIP") != endpoint[0] or (pod.get("spec") or {}).get("hostNetwork"):
                continue
            metadata = pod.get("metadata") or {}
            ports = [port.get("containerPort") for container in (pod.get("spec") or {}).get("containers") or []
                     for port in container.get("ports") or []]
            checks["pod"] = {"namespace": metadata.get("namespace"), "name": metadata.get("name"),
                             "port_declared": endpoint[1] in ports,
                             "allowed_by_dns_rule": metadata.get("namespace") == "kube-system"
                             and (metadata.get("labels") or {}).get("k8s-app") == "kube-dns"}
            break
    return checks


def network_probe_evidence(jobs):
    """Phase A: the network-probe job's reported results and verified targets."""
    evidence = {"pass": False, "error": None, "job": None, "results": [], "targets": {}, "target_checks": {}}
    matches = [job for job in jobs if job.get("name") == NETWORK_PROBE_JOB]
    if len(matches) != 1:
        evidence["error"] = f"expected one {NETWORK_PROBE_JOB} job in the probe run, found {len(matches)}"
        return evidence
    job = matches[0]
    evidence["job"] = {key: job.get(key) for key in ("id", "name", "conclusion", "runner_name")}
    logs = job_logs(PROBE_REPOSITORY, job.get("id"))
    reported = None
    for line in logs.splitlines():
        index = line.find(NETWORK_PROBE_MARKER)
        if index >= 0:
            reported = line[index + len(NETWORK_PROBE_MARKER):].strip()
    try:
        parsed = json.loads(reported) if reported is not None else None
    except json.JSONDecodeError:
        parsed = None
    if not isinstance(parsed, dict) or not isinstance(parsed.get("results"), list) \
            or not isinstance(parsed.get("targets"), dict):
        evidence["error"] = f"the {NETWORK_PROBE_JOB} log has no parseable {NETWORK_PROBE_MARKER.strip()} line"
        return evidence
    evidence["targets"] = {key: parsed["targets"].get(key) for key in NETWORK_TARGET_KEYS}
    evidence["results"] = [{key: result.get(key) for key in ("target", "address", "expected", "observed")}
                           for result in parsed["results"] if isinstance(result, dict)]
    evidence["target_checks"] = verify_network_targets(evidence["targets"])
    evidence["pass"] = job.get("conclusion") == "success" and parsed.get("pass") is True
    return evidence


def cmd_finalize(args):
    state = load_state(args.state)
    phase = state["phase"]
    try:
        snapshot(state, final=True)
        if phase == "B":
            wait_until(state, RESTORE_WAIT_SECONDS, restored, "primary restored to 0/6 by Node Pool Sizing set-burst-maxima")
        if phase == "E":
            wait_until(state, WARM_WAIT_SECONDS, two_warm_on_baseline, "two warm runners on baseline")
        snapshot(state, final=True)
        nodes = state["snapshots"]["nodes"]
        pods = []
        for pod in state["snapshots"]["pods"].values():
            pods.append(dict(pod, pool=(nodes.get(pod.get("node")) or {}).get("pool")))
        evidence = {
            "phase": phase, "expected_sha": state["expected_sha"], "probe": None,
            "pods": sorted(pods, key=lambda p: (p["created_at"] or "", p["runner_name"] or "")),
            "nodes": sorted(nodes.values(), key=lambda n: (n["created_at"] or "", n["name"])),
            "events": sorted(state["snapshots"]["events"].values(), key=lambda e: (e["first_timestamp"] or "", e["uid"] or "")),
            "pool_state_checks": state["pool_state_checks"],
            "latest_collection_at": state["latest_collection"]["at"],
            "pod_collections": state.get("pod_collections") or [],
            "pool_collections": state.get("pool_collections") or [],
            "node_pools": state.get("node_pools") or [],
            "pools_before": state["pools_before"], "pools_after": state.get("pools_latest"),
            "arc_contract_after": arc_contract(state), "phase_c": None,
            "trust_readback": None, "expander_readback": expander_readback(state),
            "network_probe": None,
        }
        if state.get("probe"):
            probe = dict(state["probe"])
            probe["run"] = dict(run_identity(PROBE_REPOSITORY, probe["run"]["id"]))
            probe["run"]["jobs"] = probe_run_jobs(state)
            probe["run"]["mode"] = probe_mode(probe["run"]["jobs"])
            if phase == "D":
                probe["drain"] = drain_anchor(state)
            evidence["probe"] = probe
        if phase == "C":
            evidence["phase_c_run"], evidence["phase_c"] = phase_c_evidence(state)
        if phase == "E":
            evidence["rollback_run"] = state["rollback_run"]
            evidence["recorded_baseline"] = state["recorded_baseline"]
            evidence["trust_readback"] = trust_readback(state)
            evidence["warm_after"] = warm_runners(state)
        if phase == "A" and evidence["probe"]:
            evidence["network_probe"] = network_probe_evidence(evidence["probe"]["run"]["jobs"])
    except (ReadError, OSError, ValueError, KeyError) as error:
        save_state(args.state, state)
        log(f"ERROR: evidence incomplete: {error}")
        return 1
    save_state(args.state, state)
    with open(args.out, "w", encoding="utf-8") as stream:
        json.dump(evidence, stream, indent=1, sort_keys=True)
        stream.write("\n")
    log(f"EVIDENCE: wrote {args.out}")
    return 0


# --- cleanup -----------------------------------------------------------------


def cmd_cleanup(args):
    state = load_state(args.state)
    result = {"status": "failed", "reason": None, "run_id": None}

    def finish(status, reason):
        result.update(status=status, reason=reason)
        with open(args.out, "w", encoding="utf-8") as stream:
            json.dump(result, stream, indent=1, sort_keys=True)
            stream.write("\n")
        log(f"CLEANUP: {status}: {reason}")
        return 0 if status in ("clean", "not-applicable") else 1

    if not state.get("probe"):
        return finish("not-applicable", "this phase has no probe run")
    run_id = state["probe"]["run"]["id"]
    result["run_id"] = run_id
    try:
        cancel = subprocess.run(["gh", "run", "cancel", str(run_id), "-R", PROBE_REPOSITORY],
                                capture_output=True, text=True, check=False)
        result["cancel_exit"] = cancel.returncode
        deadline = now() + CLEANUP_WAIT_SECONDS
        while run_identity(PROBE_REPOSITORY, run_id)["status"] != "completed":
            if now() >= deadline:
                return finish("failed", f"probe run {run_id} did not reach status completed within 10 minutes")
            sleep(CLEANUP_POLL_SECONDS)
        jobs = gh_jobs(PROBE_REPOSITORY, run_id)
        live = [job.get("name") for job in jobs if job.get("status") in ("queued", "in_progress", "waiting", "pending")]
        if live:
            return finish("failed", f"jobs still queued or in progress: {', '.join(map(str, live))}")
        job_ids = {str(job.get("id")) for job in jobs}
        runners = run_json(["kubectl", "get", "ephemeralrunners.actions.github.com", "-n", NAMESPACE, "-o", "json"]).get("items") or []
        assigned = [item["metadata"]["name"] for item in runners
                    if str((item.get("status") or {}).get("workflowRunId")) == str(run_id)
                    or str((item.get("status") or {}).get("jobId")) in job_ids]
        if assigned:
            return finish("failed", f"runner pods still assigned to the probe run: {', '.join(assigned)}")
    except ReadError as error:
        return finish("failed", str(error))
    return finish("clean", f"probe run {run_id} is completed with no queued or running job and no assigned runner")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    verify = sub.add_parser("verify-probe")
    verify.add_argument("--phase", required=True, choices=("A", "B", "C", "D", "E"))
    verify.add_argument("--state", required=True)
    verify.add_argument("--expected-sha", required=True)
    verify.add_argument("--cluster-name", default=os.environ.get("CLUSTER_NAME") or "redducklabs-cluster")
    verify.add_argument("--probe-run-id")
    verify.add_argument("--dispatch-tag")
    verify.add_argument("--expected-workflow-sha")
    anchors = sub.add_parser("verify-anchors")
    anchors.add_argument("--state", required=True)
    anchors.add_argument("--drain-run-id")
    anchors.add_argument("--phase-c-run-id")
    anchors.add_argument("--rollback-run-id")
    anchors.add_argument("--baseline-run-id")
    watch = sub.add_parser("watch")
    watch.add_argument("--state", required=True)
    watch.add_argument("--deadline-minutes", type=int, required=True)
    for name in ("finalize", "cleanup"):
        command = sub.add_parser(name)
        command.add_argument("--state", required=True)
        command.add_argument("--out", required=True)
    args = parser.parse_args()
    return {"verify-probe": cmd_verify_probe, "verify-anchors": cmd_verify_anchors, "watch": cmd_watch, "finalize": cmd_finalize, "cleanup": cmd_cleanup}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
