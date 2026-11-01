#!/usr/bin/env python3
"""Acceptance verdict for the runner burst rollout.

A pure function over captured evidence: verdict(phase, evidence) returns
{"phase", "pass", "failures", "ready_for_migration", "notes", "pickup"}.
The criteria are the spec's Acceptance pass criteria for phases A-E
(docs/specs/2026-10-26-runner-burst-autoscaling-design.md, "Acceptance") plus
the Performance pickup thresholds: warm p95 <= 90 s, cold p95 <= 8 minutes.
Every failure string starts with the criterion ID it violates (for example
"A-primary-only: ..."), so a fixture can name the criterion it breaks.

Evidence is written by scripts/acceptance-evidence.py (runner-acceptance-
evidence.yml); test/fixtures/acceptance/ holds one passing and deliberately
violating fixtures per criterion. ready_for_migration is true only for a
passing phase E; nothing else authorizes repository migration.

Pickup: a probe job is cold when the node its runner pod ran on was created
after the job's created_at, warm otherwise; pickup = started_at - created_at.
p95 is the nearest-rank percentile. The thresholds apply to phases A, B and
E; Phase C has no probe jobs and the spec's Phase D row has no pickup
criterion (Ruling 22), so D reports none.

Network (phase A, criterion A-network): the probe run's network-probe job
ran on a fleet runner and concluded success; from inside the runner pod it
resolved and fetched github.com and was blocked (timed out) from the metadata
service, a worker-pool node's kubelet and SSH, a baseline runner node's
kubelet, a runner node's public (ExternalIP) kubelet and SSH, the
kubernetes.default service (pinned to the default/kubernetes ClusterIP), a
ClusterIP service and a pod in other namespaces (not a kube-dns pod, which the
policy's DNS rule allows). The evidence collector verifies those targets in the
cluster; any successful forbidden connection fails the phase.

Runner health (every phase): no runner pod container may be OOMKilled,
restarted or evicted, judged from the captured containerStatuses
(restartCount, state, lastState.terminated.reason) and from OOMKilling,
OOMKilled, Evicted and Preempted events tied to a runner pod (a Pod in
arc-runners) or a runner node (a captured node-type=github-runner node) that
occurred inside the phase window: from the probe run's created_at (phase C:
the Phase C run's start) to latest_collection_at. Other such events (for
example a worker-pool node OOM, or an event that ended before the phase) are
reported in notes as diagnostics only.

Runner pods (phases A and B, Ruling 43): ARC 0.14.2's listener sets the
scale set's target to min(minRunners + assigned jobs, maxRunners)
(actions-runner-controller gha-runner-scale-set-0.14.2,
cmd/ghalistener/scaler/scaler.go:237), so the burst contract's warm floor
(minRunners=2) is added to every probe: a batch of N jobs runs N + 2 runner
pods, two of them idle. The placement criteria therefore count every runner
pod of the scale set observed during the hold (probe runners and idle warm
runners alike), not only the probe's runners. The hold is the interval in
which every batch entry was in progress (latest started_at to earliest
completed_at). Placement is judged only from the collector's
pod_collections that lie wholly inside the hold: a collection's pod read was
requested at requested_at and answered at observed_at (retries included), and
it counts only when requested_at >= the hold start and observed_at <= the hold
end, so a read that crosses the hold end cannot pass off later scheduling as
in-hold. Each lists every runner pod with the node that read saw (null while
unscheduled); a pod's final node or lifetime is never used:

  - at least one collection must lie inside the hold;
  - the latest in-hold collection must show exactly the required placement
    (Phase A, 14 jobs: 4 pods on baseline and 12 on the primary pool; Phase B,
    6 jobs: 4 on baseline and 4 on the fallback pool), so a pod still Pending
    when the hold ends, or scheduled only after it, fails;
  - every in-hold collection must hold no more than that many runner pods, no
    pod on a pool outside the phase's pools and none on an unknown pool, so
    idle-pod turnover or a detour through another pool at any point of the
    hold fails.

An earlier in-hold collection may still show an idle pod Pending: the hold
starts when the last job starts, which can precede the node its idle runner
waits for, and that pod is placed during the hold once the latest in-hold
collection shows it scheduled. Requiring the exact placement in every in-hold
collection would fail such runs without any placement having been wrong.
The concurrency criteria use the probe's job count (14 and 6).

Exclusive fleet (Ruling 44 revised): the placement counts above hold only when
the probe is the fleet's only workload. A-shared-fleet / B-shared-fleet fail
when an EphemeralRunner read wholly inside the hold (each collection keeps its
complete runner list, with its own interval, apart from the pod read) shows a
runner whose job fields do not belong to the probe run (repository
redducklabs/aurolegal.ai and the probe's workflowRunId), whether or not that
runner has a pod in the pod read, or one job on two runners, or when no runner
read lies inside the hold; the phase is then re-run while no other
repository's CI uses the fleet.

Priority (A-priority, B-priority): the order is proven from the
cluster-autoscaler's own decisions, not from periodic snapshots: the
TriggeredScaleUp and ScaledUpGroup events in the phase window, aggregated
"(combined from similar events): " messages included; a message that does
not parse fails. Only runner node groups are judged (Ruling 46): a group
whose ID resolves to a non-runner pool (node_pools evidence) is unrelated
demand and only noted, while the baseline, another runner pool or an
unresolved group ID fails. Phase A (Ruling 45): at least one event names the
primary, and every fallback decision, or aggregated event that may hide
one, comes strictly after a primary decision to its maximum (6 of 6).
Phase B: runner scale-ups name only the fallback, at least one does, and an
aggregated event fails. See check_scale_up_priority. The node-pool reads
(pool_collections) are diagnostics only.

Warm floor (phase E, criterion E-warm): exactly two warm_after runners, on
baseline, each observed_at == latest_collection_at (the collector's final
collection, not historical snapshots) and recorded Running, Ready,
non-terminating and idle.

Usage: acceptance-verdict.py --phase A|B|C|D|E EVIDENCE.json [--out VERDICT.json]
Prints the verdict JSON; exit 0 when it passes, 1 when it fails or the
evaluation itself raised (the verdict then records the error with pass false),
2 on a usage or unreadable-evidence error.
"""

import argparse
import json
import math
import re
import sys
import traceback
from datetime import datetime, timezone

PROBE_REPOSITORY = "redducklabs/aurolegal.ai"
PROBE_WORKFLOW = ".github/workflows/runner-burst-acceptance.yml"
FLEET_REPOSITORY = "redducklabs/redducklabs-runners"
DEPLOY_WORKFLOW = ".github/workflows/deploy-runners.yml"
SCALE_WORKFLOW = ".github/workflows/scale-runners.yml"
DRAIN_JOB = "Drain Burst Runners"
ROLLBACK_JOB = "Roll Back Self-Hosted Runners"
ROLLBACK_READBACK_STEP = "Verify rollback transition and density readback"
PHASE_C_JOB = "Scale Runners - acceptance-phase-c"

BASELINE = "github-runners-pool-16g"
PRIMARY = "github-runners-burst-amd-16g"
FALLBACK = "github-runners-burst-intel-16g"
BURST_POOLS = (PRIMARY, FALLBACK)

WARM_P95_SECONDS = 90
COLD_P95_SECONDS = 8 * 60

PHASES = ("A", "B", "C", "D", "E")
# Mode and matrix size of the probe run each phase requires. A batch of N jobs
# runs MIN_RUNNERS + N runner pods (Ruling 43): A 14 -> 16, B 6 -> 8, E 8 -> 10.
MIN_RUNNERS = 2
PROBE_SHAPE = {"A": ("batch", 14), "B": ("batch", 6), "D": ("continuous", 64), "E": ("batch", 8)}
# Runner pods by pool during the hold (every pod of the scale set).
HOLD_PLACEMENT = {"A": {BASELINE: 4, PRIMARY: 12}, "B": {BASELINE: 4, FALLBACK: 4}}
PLACEMENT_CRITERION = {"A": "A-primary-only", "B": "B-placement"}
# Primary maximum (github-runners-burst-amd-16g 0..6); A-priority needs a
# primary decision at this size before any fallback decision (Ruling 45).
PRIMARY_MAX_NODES = 6
UNSCHEDULED = "unscheduled"
UNKNOWN_POOL = "unknown-pool"
PROBE_JOB = re.compile(r"^(batch|continuous) ([0-9]+)$")


class EvidenceError(Exception):
    """Evidence is missing a field the verdict needs."""


def ts(value, label):
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{label} is missing")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise EvidenceError(f"{label} is not an ISO-8601 UTC timestamp: {value!r}") from error
    return parsed.replace(tzinfo=timezone.utc).timestamp()


def p95(values):
    """Nearest-rank 95th percentile."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def probe_jobs(evidence):
    run = (evidence.get("probe") or {}).get("run") or {}
    return [job for job in run.get("jobs") or [] if PROBE_JOB.match(str(job.get("name", "")))]


def node_index(evidence):
    return {node.get("name"): node for node in evidence.get("nodes") or []}


def pod_index(evidence):
    """runner name -> pod (ARC names the pod after the runner)."""
    return {pod.get("runner_name"): pod for pod in evidence.get("pods") or []}


def max_concurrency(jobs):
    """Largest number of jobs in progress at one instant, on distinct runners."""
    points = []
    for job in jobs:
        start = ts(job.get("started_at"), f"job {job.get('name')} started_at")
        end = ts(job.get("completed_at"), f"job {job.get('name')} completed_at")
        points.append((start, 1, job.get("runner_name")))
        points.append((end, -1, job.get("runner_name")))
    best, active = 0, {}
    # Ends sort before starts at the same instant: a runner that finished is
    # not counted together with its successor.
    for _, delta, runner in sorted(points, key=lambda item: (item[0], item[1])):
        active[runner] = active.get(runner, 0) + delta
        best = max(best, sum(1 for count in active.values() if count > 0))
    return best


def in_progress_at(jobs, instant):
    count = 0
    for job in jobs:
        start = job.get("started_at")
        if not start or ts(start, "started_at") > instant:
            continue
        end = job.get("completed_at")
        if end is None or ts(end, "completed_at") > instant:
            count += 1
    return count


# --- shared criteria -------------------------------------------------------


def check_probe_identity(phase, evidence, failures):
    probe = evidence.get("probe") or {}
    run = probe.get("run") or {}
    expected = probe.get("expected_workflow_sha")
    mode, size = PROBE_SHAPE[phase]
    if probe.get("repository") != PROBE_REPOSITORY:
        failures.append(f"probe-identity: repository {probe.get('repository')!r}, expected {PROBE_REPOSITORY}")
    if probe.get("workflow_path") != PROBE_WORKFLOW:
        failures.append(f"probe-identity: workflow {probe.get('workflow_path')!r}, expected {PROBE_WORKFLOW}")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{40}", expected):
        failures.append("probe-identity: expected_workflow_sha is not a 40-character SHA")
    if run.get("head_sha") != expected:
        failures.append(f"probe-identity: run headSha {run.get('head_sha')!r} differs from expected_workflow_sha")
    if probe.get("tag_sha") != expected:
        failures.append(f"probe-identity: tag {probe.get('dispatch_tag')!r} resolves to {probe.get('tag_sha')!r}, not expected_workflow_sha")
    if run.get("head_branch") != probe.get("dispatch_tag"):
        failures.append(f"probe-identity: run was dispatched from {run.get('head_branch')!r}, not tag {probe.get('dispatch_tag')!r}")
    if run.get("event") != "workflow_dispatch":
        failures.append(f"probe-identity: run event {run.get('event')!r}, expected workflow_dispatch")
    if run.get("attempt") != 1:
        failures.append(f"probe-identity: run attempt {run.get('attempt')!r}, expected 1")
    if run.get("mode") != mode:
        failures.append(f"probe-identity: run mode {run.get('mode')!r}, phase {phase} requires {mode}")
    jobs = probe_jobs(evidence)
    if len(jobs) != size:
        failures.append(f"probe-identity: {len(jobs)} {mode} entries, phase {phase} requires {size}")
    return jobs


def check_batch(phase, jobs, failures):
    """Every entry succeeded on its own runner and all of them overlapped."""
    _, size = PROBE_SHAPE[phase]
    label = f"{phase}-runners" if phase != "E" else "E-smoke"
    bad = [f"{job.get('name')}={job.get('conclusion')}" for job in jobs if job.get("conclusion") != "success"]
    if bad:
        failures.append(f"{label}: probe entries did not succeed: {', '.join(bad)}")
        return
    runners = {job.get("runner_name") for job in jobs}
    if len(runners) != len(jobs) or None in runners or "" in runners:
        failures.append(f"{label}: {len(jobs)} entries ran on {len(runners - {None, ''})} distinct runners")
    concurrent = max_concurrency(jobs)
    if concurrent < size:
        failures.append(f"{label}: at most {concurrent} distinct runners were concurrent, expected {size}")


def check_pickup(phase, evidence, jobs, failures, report):
    pods, nodes = pod_index(evidence), node_index(evidence)
    warm, cold = [], []
    for job in jobs:
        name = job.get("name")
        created = ts(job.get("created_at"), f"job {name} created_at")
        started = job.get("started_at")
        if not started:
            continue
        pickup = ts(started, f"job {name} started_at") - created
        pod = pods.get(job.get("runner_name"))
        if pod is None:
            failures.append(f"pickup: no runner pod captured for {name} (runner {job.get('runner_name')!r})")
            continue
        node = nodes.get(pod.get("node"))
        if node is None:
            failures.append(f"pickup: no node captured for runner {pod.get('runner_name')} (node {pod.get('node')!r})")
            continue
        (cold if ts(node.get("created_at"), f"node {node.get('name')} created_at") > created else warm).append(pickup)
    report["warm_count"], report["cold_count"] = len(warm), len(cold)
    report["warm_p95_seconds"] = p95(warm) if warm else None
    report["cold_p95_seconds"] = p95(cold) if cold else None
    if warm and p95(warm) > WARM_P95_SECONDS:
        failures.append(f"pickup-warm: warm pickup p95 {p95(warm):.0f}s exceeds {WARM_P95_SECONDS}s")
    if cold and p95(cold) > COLD_P95_SECONDS:
        failures.append(f"pickup-cold: cold pickup p95 {p95(cold):.0f}s exceeds {COLD_P95_SECONDS}s")


def hold_window(jobs):
    """(start, end) epochs in which every batch entry was in progress; None
    when an entry has no start or end, or the entries never all overlapped."""
    if not jobs or any(not job.get("started_at") or not job.get("completed_at") for job in jobs):
        return None
    start = max(ts(job["started_at"], f"job {job.get('name')} started_at") for job in jobs)
    end = min(ts(job["completed_at"], f"job {job.get('name')} completed_at") for job in jobs)
    return (start, end) if start <= end else None


def collection_placement(collection):
    """Runner pods of one collection by pool, as that collection saw them."""
    placement = {}
    for pod in collection.get("pods") or []:
        where = (pod.get("pool") or UNKNOWN_POOL) if pod.get("node") else UNSCHEDULED
        placement[where] = placement.get(where, 0) + 1
    return placement


def iso_at(epoch):
    return f"{datetime.fromtimestamp(epoch, timezone.utc):%Y-%m-%dT%H:%M:%SZ}"


def hold_placement(phase, evidence, jobs, failures, notes):
    """Placement of every runner pod of the scale set during the hold, from
    the collections taken inside it (Ruling 43; see the module docstring).

    Returns the latest in-hold collection's placement, or None when it cannot
    be judged: no hold fails {phase}-runners, no in-hold collection fails the
    phase's placement criterion. Breaches in earlier in-hold collections are
    appended to failures here."""
    window = hold_window(jobs)
    if window is None:
        failures.append(f"{phase}-runners: no instant at which all {len(jobs)} entries were in progress; "
                        "runner placement during the hold cannot be judged")
        return None
    start, end = window
    label = PLACEMENT_CRITERION[phase]
    held = []
    for collection in evidence.get("pod_collections") or []:
        requested = ts(collection.get("requested_at"), "pod collection requested_at")
        observed = ts(collection.get("observed_at"), "pod collection observed_at")
        if observed < requested:
            raise EvidenceError(f"pod collection observed_at {collection.get('observed_at')} precedes its requested_at")
        if start <= requested and observed <= end:
            held.append((observed, collection))
    held.sort(key=lambda item: item[0])
    if not held:
        failures.append(f"{label}: no runner-pod collection inside the hold {iso_at(start)}..{iso_at(end)}; "
                        "placement during the hold was not observed")
        return None
    total = sum(HOLD_PLACEMENT[phase].values())
    allowed = set(HOLD_PLACEMENT[phase]) | {UNSCHEDULED}
    for at, collection in held:
        placement = collection_placement(collection)
        stray = {name: count for name, count in placement.items() if name not in allowed}
        if stray or sum(placement.values()) > total:
            failures.append(f"{label}: collection at {iso_at(at)} inside the hold saw runner pods {placement}; "
                            f"at most {total}, only on {sorted(HOLD_PLACEMENT[phase])} or not yet scheduled")
    at, latest = held[-1]
    placement = collection_placement(latest)
    probe_runners = {job.get("runner_name") for job in jobs}
    idle = sum(1 for pod in latest.get("pods") or [] if pod.get("runner_name") not in probe_runners)
    notes.append(f"Phase {phase}: runner pods during the hold {iso_at(start)}..{iso_at(end)} "
                 f"({len(held)} collections wholly inside it; latest observed at {iso_at(at)}) by pool {placement} "
                 f"({sum(placement.values()) - idle} probe runners, {idle} without a probe job; "
                 f"ARC target minRunners {MIN_RUNNERS} + {len(jobs)} jobs)")
    return placement


def held_runner_reads(evidence, jobs):
    """The EphemeralRunner reads (one per pod collection) whose own interval
    lies wholly inside the hold (none without a hold)."""
    window = hold_window(jobs)
    if window is None:
        return []
    start, end = window
    reads = []
    for collection in evidence.get("pod_collections") or []:
        read = collection.get("ephemeral_runners")
        if not isinstance(read, dict):
            continue
        requested = ts(read.get("requested_at"), "EphemeralRunner read requested_at")
        observed = ts(read.get("observed_at"), "EphemeralRunner read observed_at")
        if observed < requested:
            raise EvidenceError(f"EphemeralRunner read observed_at {read.get('observed_at')} precedes its requested_at")
        if start <= requested and observed <= end:
            reads.append(read)
    return reads


def check_exclusive_fleet(phase, evidence, jobs, failures):
    """{phase}-shared-fleet: no other run's job on the fleet during the hold (Ruling 44 revised).

    Judged from every EphemeralRunner read wholly inside the hold, each the
    complete runner list of its collection (PR #42 review 2): a runner counts
    whether or not its pod was in that collection's earlier pod read. Any job
    field that does not belong to the probe run (repository
    redducklabs/aurolegal.ai and the probe's workflowRunId), or one job (jobId
    or jobRequestId) on two runners of one read, means the fleet was shared or
    the assignment evidence is inconsistent; placement cannot then show the
    priority order, so the phase must be re-run on an exclusive fleet. No
    runner read inside the hold fails too: exclusivity was not observed."""
    rerun = "re-run this phase while no other repository's CI uses the fleet"
    if hold_window(jobs) is None:
        return
    reads = held_runner_reads(evidence, jobs)
    if not reads:
        failures.append(f"{phase}-shared-fleet: no EphemeralRunner read lies wholly inside the hold; "
                        f"exclusive use of the fleet was not observed; {rerun}")
        return
    probe_id = str(((evidence.get("probe") or {}).get("run") or {}).get("id"))
    foreign, duplicates = set(), set()
    for read in reads:
        assigned = {}
        for runner in read.get("items") or []:
            job = runner.get("job") or {}
            if not job:
                continue
            if job.get("jobRepositoryName") != PROBE_REPOSITORY or str(job.get("workflowRunId")) != probe_id:
                foreign.add(f"{job.get('jobRepositoryName') or 'unknown repository'} run "
                            f"{job.get('workflowRunId') or 'unknown'}")
            for key in ("jobId", "jobRequestId"):
                if job.get(key) in (None, ""):
                    continue
                first = assigned.setdefault((key, str(job[key])), runner.get("name"))
                if first != runner.get("name"):
                    duplicates.add(f"{key} {job[key]} on {first} and {runner.get('name')}")
    if foreign:
        failures.append(f"{phase}-shared-fleet: runners held jobs of other runs during the hold "
                        f"({', '.join(sorted(foreign))}); {rerun}")
    if duplicates:
        failures.append(f"{phase}-shared-fleet: one job was assigned to several runners in one read during the "
                        f"hold ({', '.join(sorted(duplicates))}); {rerun}")


SCALE_UP_REASONS = ("TriggeredScaleUp", "ScaledUpGroup")
# cluster-autoscaler 1.36 (kubernetes/autoscaler cluster-autoscaler-1.36.1):
# processors/status/eventing_scale_up_processor.go emits TriggeredScaleUp
# "pod triggered scale-up: %v" over []ScaleUpInfo, each printed
# "{%v %v->%v (max: %v)}" (processors/nodegroupset/nodegroup_set_processor.go);
# core/scaleup/orchestrator/executor.go emits ScaledUpGroup "Scale-up: setting
# group %s size to %d instead of %d (max: %d)" and "Scale-up: group %s size set
# to %d instead of %d (max: %d)". On DOKS the group ID is the node pool ID.
SCALE_UP_INFO = re.compile(r"\{(\S+) (\d+)->(\d+) \(max: (\d+)\)\}")
SCALED_UP_GROUP = re.compile(r"^Scale-up: (?:setting group (\S+) size to|group (\S+) size set to) "
                             r"(\d+) instead of (\d+) \(max: (\d+)\)$")


# client-go v0.36.2 (the version cluster-autoscaler 1.36.1 vendors),
# tools/record/events_cache.go EventAggregatorByReasonMessageFunc: once similar
# events (same object, reason and source) repeat, the recorder emits one
# aggregated event whose message is the latest one with this prefix and whose
# count grows; messages between collections are then lost.
COMBINED_PREFIX = "(combined from similar events): "


def scale_up_decisions(event):
    """[(group ID, target size, max size)] a scale-up event's message names,
    and whether it is an aggregated (combined) event; None when the message
    does not parse."""
    message = str(event.get("message") or "")
    combined = message.startswith(COMBINED_PREFIX)
    if combined:
        message = message[len(COMBINED_PREFIX):]
    if event.get("reason") == "TriggeredScaleUp":
        prefix = "pod triggered scale-up: ["
        if not message.startswith(prefix) or not message.endswith("]"):
            return None
        inner = message[len(prefix):-1]
        found = [(group, int(new), int(maximum)) for group, _, new, maximum in SCALE_UP_INFO.findall(inner)]
        return (found, combined) if found and not SCALE_UP_INFO.sub("", inner).strip() else None
    match = SCALED_UP_GROUP.match(message)
    if not match:
        return None
    return [(match.group(1) or match.group(2), int(match.group(3)), int(match.group(5)))], combined


def event_in_window(event, window):
    start, end = window
    first, last = event.get("first_timestamp"), event.get("last_timestamp") or event.get("first_timestamp")
    if start is not None and last and ts(last, "event last_timestamp") < start:
        return False
    if end is not None and first and ts(first, "event first_timestamp") > end:
        return False
    return True


def node_group_kinds(evidence):
    """{node group ID: (pool name, kind)}; kind is primary, fallback, baseline,
    runner (another runner-labeled pool) or non-runner (Ruling 46).

    The three runner pools come from the pools evidence; every other pool of
    the cluster from node_pools, marked runner when it carries the runner
    label node-type=github-runner or the github-runner taint."""
    pools = evidence.get("pools_after") or evidence.get("pools_before") or {}
    kinds = {}
    for item in evidence.get("node_pools") or []:
        if item.get("id"):
            kinds[item["id"]] = (item.get("name"), "runner" if item.get("runner") is not False else "non-runner")
    for name, kind in ((PRIMARY, "primary"), (FALLBACK, "fallback"), (BASELINE, "baseline")):
        pool_id = (pools.get(name) or {}).get("id")
        if pool_id:
            kinds[pool_id] = (name, kind)
    return kinds


def check_scale_up_priority(phase, evidence, failures, notes):
    """{phase}-priority: the autoscaler's scale-up decisions respect the priority order.

    Judged from every TriggeredScaleUp (on a pod) and ScaledUpGroup
    (cluster-autoscaler status) event in the phase window, aggregated
    "(combined from similar events): " messages included; a message that does
    not parse fails closed.

    Only runner node groups are judged (Ruling 46). cluster-autoscaler scales
    a node group only when its node template can host a pending pod; runner
    pods select node-type=github-runner and tolerate only
    github-runner=true:NoSchedule, so only runner pools are candidates for
    runner demand. The baseline runner pool is fixed at 2/2 (its maximum) and
    cannot scale, and the worker pool cannot host runner pods. A scale-up of a
    group that resolves to a non-runner pool (node_pools evidence: no runner
    label or taint) is therefore unrelated demand and only noted. A visible
    event naming the baseline, another runner pool, or a group ID that
    resolves to no known pool fails closed.

    Phase B: every runner scale-up names only the fallback group (the primary
    is 0/0), at least one does, and an aggregated (combined) event fails,
    because the groups of its earlier occurrences cannot be established.

    Phase A (Ruling 45): at least one event names the primary, and every
    event that may stand for a fallback decision comes strictly after a
    primary decision whose target size is the primary maximum (6 of 6): the
    fallback was asked for only once the primary was at its maximum. Times
    are event timestamps (firstTimestamp, or eventTime when firstTimestamp is
    unset, as the collector records them), chosen fail closed: a fallback
    decision counts at its earliest possible in-window occurrence,
    max(first_timestamp, window start); a primary-at-max decision counts at
    its earliest occurrence known to carry that message, its first_timestamp
    when inside the window, otherwise its last_timestamp. An aggregated
    (combined) event keeps only its latest message; by the argument above its
    earlier occurrences can only have named the primary, the fallback or a
    non-runner pool, so it is treated as a possible fallback decision from its
    first timestamp on (the ordering rule then covers it) and proves the
    primary at its maximum only at its last timestamp. Equal timestamps
    (one-second resolution) do not order the decisions, so a tie fails.
    Attempt 3 (probe run 40897316886) set the primary to 6 at 15:01:40 and the
    fallback to 1 at 15:02:44, after the primary had reached its maximum: the
    autoscaler over-estimated demand while the primary nodes were still
    booting, which is a cost, not a priority failure; A-primary-only still
    requires no runner pod on the fallback."""
    label = f"{phase}-priority"
    wanted = PRIMARY if phase == "A" else FALLBACK
    kinds = node_group_kinds(evidence)
    ids = {kind: group for group, (_, kind) in kinds.items() if kind in ("primary", "fallback")}
    wanted_id = ids.get("primary" if phase == "A" else "fallback")
    fallback_id = ids.get("fallback")
    if not wanted_id or (phase == "A" and not fallback_id):
        failures.append(f"{label}: the {wanted} or {FALLBACK} node pool ID is unknown; scale-up events cannot be matched")
        return
    allowed_kinds = {"primary", "fallback"} if phase == "A" else {"fallback"}
    window = phase_window(evidence)
    start = window[0]
    named, proofs, fallback_times, unrelated, combined_events = {}, [], [], {}, []
    for event in evidence.get("events") or []:
        if event.get("reason") not in SCALE_UP_REASONS or not event_in_window(event, window):
            continue
        parsed = scale_up_decisions(event)
        if parsed is None:
            failures.append(f"{label}: cannot parse the {event.get('reason')} event message "
                            f"{str(event.get('message'))[:160]!r}")
            continue
        decisions, combined = parsed
        if combined and phase != "A":
            # Phase B: an aggregated event keeps only its latest message, so
            # the groups of its earlier occurrences cannot be established and
            # one of them may be the forbidden primary; fail closed. Repeated
            # identical-message events (count > 1, no prefix) are still judged
            # by their message (PR #45 review 1).
            failures.append(f"{label}: an aggregated {event.get('reason')} event "
                            f"({event.get('count')} occurrences from {event.get('first_timestamp')}) hides the node "
                            f"groups of its earlier scale-ups: {str(event.get('message'))[:120]!r}; "
                            f"re-run the phase")
        first = ts(event.get("first_timestamp"), "event first_timestamp")
        last = ts(event.get("last_timestamp") or event.get("first_timestamp"), "event last_timestamp")
        earliest = max(first, start) if start is not None else first
        if combined and phase == "A":
            combined_events.append(f"{event.get('reason')} x{event.get('count')} from {event.get('first_timestamp')}")
            fallback_times.append((earliest, f"aggregated {event.get('reason')} {str(event.get('message'))[:120]!r}"))
        for group, target, maximum in decisions:
            name, kind = kinds.get(group, (None, "unknown"))
            if kind == "non-runner":
                unrelated[name or group] = unrelated.get(name or group, 0) + 1
                continue
            named[group] = named.get(group, 0) + 1
            if kind not in allowed_kinds:
                continue
            if phase == "A" and group == wanted_id and target == maximum == PRIMARY_MAX_NODES:
                proofs.append(last if combined or (start is not None and first < start) else first)
            if phase == "A" and group == fallback_id and not combined:
                fallback_times.append((earliest, f"{event.get('reason')} {str(event.get('message'))[:120]!r}"))
    others = {(kinds.get(group, (None, None))[0] or f"unknown group {group}"): count
              for group, count in named.items() if kinds.get(group, (None, "unknown"))[1] not in allowed_kinds}
    if others:
        failures.append(f"{label}: cluster-autoscaler scale-up events in the phase window name {others}; only "
                        f"{sorted(kinds[ids[kind]][0] for kind in allowed_kinds if kind in ids)} may scale up "
                        f"among runner pools, and every group must resolve to a known node pool")
    if wanted_id not in named:
        failures.append(f"{label}: no cluster-autoscaler scale-up event in the phase window names {wanted} "
                        f"({wanted_id}); the scale-up order is not proven")
    if phase == "A":
        reached = min(proofs) if proofs else None
        early = [(at, what) for at, what in fallback_times if reached is None or at <= reached]
        for at, what in sorted(early):
            failures.append(f"{label}: a fallback scale-up (or an aggregated scale-up event that may hide one) at "
                            f"{iso_at(at)} is not strictly after the primary was set to its maximum "
                            f"{PRIMARY_MAX_NODES} ({iso_at(reached) if reached else 'never'}): {what}")
        notes.append(f"Phase A: primary set to its maximum at {iso_at(reached) if reached else 'never'}; "
                     f"{len(fallback_times)} fallback (or aggregated) scale-up events after it")
        if combined_events:
            notes.append(f"Phase A: aggregated scale-up events {combined_events} were judged as possible fallback "
                         "decisions from their first timestamp; their hidden earlier occurrences can only name the "
                         "primary, the fallback or a non-runner pool (the baseline is at its maximum and only "
                         "runner pools can host runner pods), so each must follow the primary maximum")
    if unrelated:
        notes.append(f"Phase {phase}: scale-ups of non-runner node pools during the phase (unrelated demand, "
                     f"diagnostic only): {unrelated}")
    notes.append(f"Phase {phase}: scale-up events in the phase window by node group "
                 f"{ {(kinds.get(group, (None, None))[0] or group): count for group, count in named.items()} }")


def burst_nodes_before_run(evidence):
    """Burst nodes that already existed when the probe run was created."""
    created = ts(((evidence.get("probe") or {}).get("run") or {}).get("created_at"), "probe run created_at")
    return [node.get("name") for node in evidence.get("nodes") or []
            if node.get("pool") in BURST_POOLS and ts(node.get("created_at"), "node created_at") < created]


def pool(evidence, key, name):
    return ((evidence.get(key) or {}).get(name)) or {}


def expander_matches(evidence, failures, label):
    readback = evidence.get("expander_readback") or {}
    pools = evidence.get("pools_after") or evidence.get("pools_before") or {}
    primary_id = (pools.get(PRIMARY) or {}).get("id")
    fallback_id = (pools.get(FALLBACK) or {}).get("id")
    expected = {"100": [primary_id], "50": [fallback_id], "1": [".*"]}
    if readback.get("expanders") != ["priority", "random"]:
        failures.append(f"{label}: cluster expanders {readback.get('expanders')!r}, expected ['priority', 'random']")
    if not primary_id or not fallback_id or readback.get("priorities") != expected:
        failures.append(f"{label}: priority expander ConfigMap {readback.get('priorities')!r} does not rank {PRIMARY}=100, {FALLBACK}=50, .*=1")
    if readback.get("managed") is not True:
        failures.append(f"{label}: priority expander ConfigMap lost its doks.digitalocean.com/managed label")


HEALTH_EVENTS = ("OOMKilling", "OOMKilled", "Evicted", "Preempted")


def phase_window(evidence):
    """(start, end) epochs of the observation window; None for an unknown bound.

    Start: the probe run's created_at, or for phase C the Phase C run's start.
    End: latest_collection_at, the evidence collector's final collection. An
    unknown bound is left open, so an event is never excused by missing data."""
    start = ((evidence.get("probe") or {}).get("run") or {}).get("created_at") \
        or (evidence.get("phase_c_run") or {}).get("started")
    end = evidence.get("latest_collection_at")
    return (ts(start, "phase window start") if start else None,
            ts(end, "latest_collection_at") if end else None)


def runner_health_event(evidence, event, window):
    """A health event counts when it is tied to a runner pod (arc-runners Pod)
    or a runner node (a captured node-type=github-runner node) and it occurred
    inside the phase window. Other events stay in the evidence as diagnostics."""
    runner_nodes = {node.get("name") for node in evidence.get("nodes") or []}
    kind, name = event.get("involved_kind"), event.get("involved_name")
    if not ((kind == "Pod" and event.get("namespace") == "arc-runners") or (kind == "Node" and name in runner_nodes)):
        return False
    start, end = window
    first, last = event.get("first_timestamp"), event.get("last_timestamp") or event.get("first_timestamp")
    if start is not None and last and ts(last, "event last_timestamp") < start:
        return False
    if end is not None and first and ts(first, "event first_timestamp") > end:
        return False
    return True


def check_runner_health(evidence, failures, notes):
    """No runner container OOMKilled, restarted or evicted during the phase."""
    for pod in evidence.get("pods") or []:
        for status in pod.get("container_statuses") or []:
            where = f"{pod.get('runner_name')}/{status.get('name')}"
            terminated = (status.get("state") or {}).get("terminated") or {}
            reasons = {terminated.get("reason"), status.get("last_terminated_reason")}
            if "OOMKilled" in reasons:
                failures.append(f"runner-health: container {where} was OOMKilled")
            elif (status.get("restart_count") or 0) > 0:
                failures.append(f"runner-health: container {where} restarted {status.get('restart_count')} time(s)"
                                f" (last exit {status.get('last_terminated_exit_code')})")
    window = phase_window(evidence)
    ignored = []
    for event in evidence.get("events") or []:
        if event.get("reason") not in HEALTH_EVENTS:
            continue
        if not runner_health_event(evidence, event, window):
            ignored.append(f"{event.get('reason')}@{event.get('involved_kind')}/{event.get('involved_name')}")
            continue
        failures.append(f"runner-health: {event.get('reason')} event on {event.get('involved_kind')} "
                        f"{event.get('involved_name')}: {str(event.get('message'))[:120]}")
    if ignored:
        notes.append("runner-health: diagnostic only (not a runner pod or node, or outside the phase window): "
                     + ", ".join(ignored[:10]))


# --- phases ----------------------------------------------------------------


def check_compatibility(label, evidence, pool_name, failures):
    """A passing pool-state check (node compatibility and headroom) covered every node of the pool while Ready.

    Neither burst size (s-8vcpu-16gb-amd primary, s-8vcpu-16gb-intel fallback)
    had run in the cluster when the allocatable assumption of
    test/verify-runner-resources.sh was made (spec, Ruling 38): phase A is the
    live measurement for the primary size, phase B for the fallback size.
    """
    names = {node.get("name") for node in evidence.get("nodes") or [] if node.get("pool") == pool_name}
    compatible = any(check.get("pass") is True and names <= set(check.get("ready_nodes") or [])
                     for check in evidence.get("pool_state_checks") or [])
    if not names or not compatible:
        failures.append(f"{label}-compatibility: no passing pool-state check (node compatibility and headroom) "
                        f"covered every {pool_name} node while Ready")


def phase_a(evidence, failures, report, notes):
    jobs = check_probe_identity("A", evidence, failures)
    pre = burst_nodes_before_run(evidence)
    if pre:
        failures.append(f"A-setup: burst nodes existed before the probe (not from zero): {', '.join(pre)}")
    expander_matches(evidence, failures, "A-setup")
    check_batch("A", jobs, failures)
    placement = hold_placement("A", evidence, jobs, failures, notes)
    expected = HOLD_PLACEMENT["A"]
    if placement is not None and placement.get(BASELINE, 0) != expected[BASELINE]:
        failures.append(f"A-baseline: {placement.get(BASELINE, 0)} runner pods on {BASELINE} in the latest collection inside the hold, "
                        f"expected {expected[BASELINE]}")
    outside = {name: count for name, count in (placement or {}).items() if name not in (BASELINE, PRIMARY)}
    # Ruling 45: fallback nodes alone do not fail A (the autoscaler may
    # over-estimate demand while primary nodes boot, after the primary reached
    # its maximum; A-priority judges the order); no runner pod may use them.
    fallback_nodes = [node.get("name") for node in evidence.get("nodes") or [] if node.get("pool") == FALLBACK]
    notes.append(f"Phase A: {len(fallback_nodes)} fallback nodes registered (cost signal): {fallback_nodes}")
    if placement is not None and (placement.get(PRIMARY, 0) != expected[PRIMARY] or outside):
        failures.append(f"A-primary-only: runner pods in the latest collection inside the hold {placement}, expected {expected[PRIMARY]} on "
                        f"{PRIMARY} and none elsewhere; fallback nodes {fallback_nodes}")
    check_exclusive_fleet("A", evidence, jobs, failures)
    check_scale_up_priority("A", evidence, failures, notes)
    check_compatibility("A", evidence, PRIMARY, failures)
    check_pickup("A", evidence, jobs, failures, report)
    # A-network (runner network isolation): check_network_probe.
    for extra in EXTRA_CRITERIA["A"]:
        extra(evidence, failures, report, notes)


def phase_b(evidence, failures, report, notes):
    jobs = check_probe_identity("B", evidence, failures)
    for name, expected_max in ((PRIMARY, 0), (FALLBACK, 2)):
        before = pool(evidence, "pools_before", name)
        if before.get("min") != 0 or before.get("max") != expected_max:
            failures.append(f"B-setup: {name} was {before.get('min')}/{before.get('max')} during the probe, expected 0/{expected_max}")
    pre = burst_nodes_before_run(evidence)
    if pre:
        failures.append(f"B-setup: burst nodes existed before the probe (not from zero): {', '.join(pre)}")
    check_batch("B", jobs, failures)
    placement = hold_placement("B", evidence, jobs, failures, notes)
    if placement is not None and placement != HOLD_PLACEMENT["B"]:
        failures.append(f"B-placement: runner pods in the latest collection inside the hold by pool {placement}, expected 4 on {BASELINE} "
                        f"and 4 on {FALLBACK} (unscheduled pods count as placed nowhere)")
    fallback = [node for node in evidence.get("nodes") or [] if node.get("pool") == FALLBACK]
    primary = [node.get("name") for node in evidence.get("nodes") or [] if node.get("pool") == PRIMARY]
    if len(fallback) != 2 or primary:
        failures.append(f"B-fallback-nodes: {len(fallback)} fallback nodes and primary nodes {primary}; expected exactly two fallback nodes and no primary node")
    check_exclusive_fleet("B", evidence, jobs, failures)
    check_scale_up_priority("B", evidence, failures, notes)
    check_compatibility("B", evidence, FALLBACK, failures)
    for name, expected_max in ((PRIMARY, 6), (FALLBACK, 2)):
        after = pool(evidence, "pools_after", name)
        if after.get("min") != 0 or after.get("max") != expected_max:
            failures.append(f"B-restored: {name} is {after.get('min')}/{after.get('max')} afterwards, expected 0/{expected_max}")
    check_pickup("B", evidence, jobs, failures, report)


def phase_c(evidence, failures, report, notes):
    run = evidence.get("phase_c_run") or {}
    expected_sha = evidence.get("expected_sha")
    if (run.get("repository") != FLEET_REPOSITORY or run.get("workflow_path") != SCALE_WORKFLOW
            or run.get("job_name") != PHASE_C_JOB):
        failures.append(f"C-run: run {run.get('id')} is not this repository's Scale Runners acceptance-phase-c")
    if run.get("head_sha") != expected_sha or run.get("conclusion") != "success":
        failures.append(f"C-run: Phase C run at {run.get('head_sha')!r} concluded {run.get('conclusion')!r}; expected success at the reviewed SHA")
    evidence_c = evidence.get("phase_c")
    if not isinstance(evidence_c, dict) or not evidence_c.get("cycles"):
        failures.append("C-evidence: phase-c-evidence.json is missing or has no cycles")
        return
    cycles = evidence_c["cycles"]
    for index, cycle in enumerate(cycles, 1):
        if cycle.get("min8") != {"baseline": 4, "burst": 4, "retired": 0}:
            failures.append(f"C-full-baseline: cycle {index} at minRunners=8 was {cycle.get('min8')}, expected 4 baseline, 4 burst, nothing retired")
    survivors = [cycle for cycle in cycles if (cycle.get("after4") or {}).get("survivor_on_burst")]
    result = evidence_c.get("result")
    if result == "retired":
        if not any((cycle.get("after4") or {}).get("retired", 0) >= 1 for cycle in survivors):
            failures.append("C-retirement: result 'retired' but no cycle retired a burst-node survivor")
    elif result == "fixture-only":
        if survivors or len(cycles) != 3:
            failures.append("C-retirement: result 'fixture-only' needs three cycles without a burst survivor")
        notes.append("Phase C: no idle runner survived on a burst node in three cycles; "
                     "retirement of a survivor was exercised only by fixtures - track the follow-up")
    else:
        failures.append(f"C-retirement: unknown result {result!r}")
    if not cycles[-1].get("pools_zero_at"):
        failures.append("C-zero-nodes: both burst pools did not reach zero nodes within 60 minutes")
    for name in BURST_POOLS:
        after = pool(evidence, "pools_after", name)
        if after.get("count") != 0 or after.get("nodes") != 0:
            failures.append(f"C-zero-nodes: {name} has count {after.get('count')} and {after.get('nodes')} nodes afterwards")
    killed = evidence_c.get("jobs_killed")
    if not isinstance(killed, int) or isinstance(killed, bool):
        failures.append("C-jobs-killed: jobs_killed was not measured")
    elif killed != 0:
        failures.append(f"C-jobs-killed: {killed} fleet job(s) were cancelled or failed during Phase C: {evidence_c.get('killed_jobs')}")
    if evidence.get("arc_contract_after") != "burst":
        failures.append(f"C-arc: ARC is {evidence.get('arc_contract_after')!r} afterwards, expected burst")


def phase_d(evidence, failures, report, notes):
    jobs = check_probe_identity("D", evidence, failures)
    drain = (evidence.get("probe") or {}).get("drain") or {}
    if (drain.get("repository") != FLEET_REPOSITORY or drain.get("workflow_path") != DEPLOY_WORKFLOW
            or drain.get("operation_job") != DRAIN_JOB):
        failures.append(f"D-drain-run: run {drain.get('run_id')} is not this repository's Deploy drain")
    if drain.get("head_sha") != evidence.get("expected_sha"):
        failures.append(f"D-drain-run: drain ran at {drain.get('head_sha')!r}, not the reviewed SHA")
    if drain.get("conclusion") != "success":
        failures.append(f"D-drain-run: drain concluded {drain.get('conclusion')!r}")
    if failures:
        return
    started = ts(drain.get("started"), "drain started")
    effective = ts(drain.get("effective"), "drain effective (READBACK)")
    completed = ts(drain.get("completed"), "drain completed")
    if not started <= effective <= completed:
        failures.append("D-drain-run: drain timestamps are out of order")
        return
    bad = [f"{job.get('name')}={job.get('conclusion')}" for job in jobs if job.get("conclusion") != "success"]
    if bad:
        failures.append(f"D-jobs: probe entries did not succeed: {', '.join(bad[:8])}")
    run_created = ts(((evidence.get("probe") or {}).get("run") or {}).get("created_at"), "probe run created_at")
    if run_created > started:
        failures.append("D-overlap-start: the probe run was created after the drain started")
    at_start = in_progress_at(jobs, started)
    report["in_flight_at_drain_started"] = at_start
    if at_start < 8:
        failures.append(f"D-overlap-start: {at_start} probe entries in progress when the drain started, expected at least 8")
    # Entries in progress across [started, completed], except for gaps of at
    # most WARM_P95_SECONDS between one entry ending and the next starting
    # (Ruling 48): at the drain cap, entries that end together leave no runner
    # busy while ARC replaces the ephemeral runners, which is pickup latency,
    # not a stalled fleet. A longer gap fails.
    intervals = sorted(
        (ts(job["started_at"], "started_at"), ts(job["completed_at"], "completed_at"))
        for job in jobs if job.get("started_at") and job.get("completed_at"))
    # Gaps are measured inside [started, completed] only: a gap that runs past
    # the drain's completion counts up to the completion, so entries starting
    # after the drain cannot change the verdict.
    covered, widest, widest_from = started, 0, started
    for begin, end in intervals:
        if begin >= completed:
            break
        if end <= covered:
            continue
        if begin > covered and begin - covered > widest:
            widest, widest_from = begin - covered, covered
        covered = end
        if covered >= completed:
            break
    if covered < completed and completed - covered > widest:
        widest, widest_from = completed - covered, covered
    report["max_gap_seconds"] = widest
    if widest > WARM_P95_SECONDS:
        failures.append(f"D-overlap-continuous: no probe entry in progress for {widest:.0f} s from {datetime.fromtimestamp(widest_from, timezone.utc):%Y-%m-%dT%H:%M:%SZ} inside the drain interval (at most {WARM_P95_SECONDS} s allowed)")
    elif widest:
        notes.append(f"Phase D: widest gap between probe entries inside the drain interval {widest:.0f} s (at most {WARM_P95_SECONDS} s allowed, Ruling 48)")
    later = [job for job in jobs if not job.get("completed_at") or ts(job["completed_at"], "completed_at") > completed]
    if not later:
        failures.append("D-overlap-end: the probe exhausted its matrix before the drain completed")
    late = [pod for pod in evidence.get("pods") or [] if ts(pod.get("created_at"), "pod created_at") >= effective]
    unscheduled = [pod.get("runner_name") for pod in late if not pod.get("node")]
    if unscheduled:
        notes.append(f"Phase D: runner pods never seen scheduled after the drain: {', '.join(map(str, unscheduled))}")
    on_burst = [f"{pod.get('runner_name')}@{pod.get('pool')}" for pod in late
                if pod.get("node") and pod.get("pool") != BASELINE]
    if on_burst:
        failures.append(f"D-post-drain-placement: runner pods created after the drain are not on baseline: {', '.join(on_burst)}")
    scale_ups = [event.get("involved_name") for event in evidence.get("events") or []
                 if event.get("reason") == "TriggeredScaleUp" and event.get("namespace") == "arc-runners"
                 and ts(event.get("last_timestamp"), "event last_timestamp") >= effective]
    if scale_ups:
        failures.append(f"D-no-scale-up: runner pods triggered scale-up after the drain: {', '.join(map(str, scale_ups))}")
    for name in BURST_POOLS:
        after = pool(evidence, "pools_after", name)
        if after.get("count") != 0 or after.get("nodes") != 0:
            failures.append(f"D-zero: {name} has count {after.get('count')} and {after.get('nodes')} nodes afterwards")
    if evidence.get("arc_contract_after") != "drain":
        failures.append(f"D-arc: ARC is {evidence.get('arc_contract_after')!r} afterwards, expected drain")


def phase_e(evidence, failures, report, notes):
    jobs = check_probe_identity("E", evidence, failures)
    rollback = evidence.get("rollback_run") or {}
    if (rollback.get("repository") != FLEET_REPOSITORY or rollback.get("workflow_path") != DEPLOY_WORKFLOW
            or rollback.get("job_name") != ROLLBACK_JOB or rollback.get("head_sha") != evidence.get("expected_sha")
            or rollback.get("conclusion") != "success" or rollback.get("readback_step") != "success"):
        failures.append(f"E-rollback: run {rollback.get('id')} is not a successful Deploy rollback with a density readback at the reviewed SHA")
    if evidence.get("arc_contract_after") != "burst":
        failures.append(f"E-arc: ARC is {evidence.get('arc_contract_after')!r}, expected burst")
    expected = {BASELINE: (2, 2, 2), PRIMARY: (0, 6, None), FALLBACK: (0, 2, None)}
    after = evidence.get("pools_after") or {}
    ids = []
    for name, (low, high, count) in expected.items():
        entry = after.get(name) or {}
        ids.append(entry.get("id"))
        if entry.get("min") != low or entry.get("max") != high or (count is not None and entry.get("count") != count):
            failures.append(f"E-pools: {name} is {entry.get('min')}/{entry.get('max')} count {entry.get('count')}, expected {low}/{high}")
    if None in ids or "" in ids or len(set(ids)) != 3:
        failures.append(f"E-pools: pool IDs {ids} are not three distinct IDs")
    recorded = evidence.get("recorded_baseline") or {}
    if not recorded.get("pool_id") or recorded.get("pool_id") != (after.get(BASELINE) or {}).get("id"):
        failures.append(f"E-pools: baseline pool ID {(after.get(BASELINE) or {}).get('id')!r} does not match the "
                        f"Phase A record {recorded.get('pool_id')!r} (run {recorded.get('run_id')})")
    run_created = ((evidence.get("probe") or {}).get("run") or {}).get("created_at")
    if not rollback.get("completed_at") or not run_created \
            or ts(rollback["completed_at"], "rollback completed_at") >= ts(run_created, "probe run created_at"):
        failures.append("E-rollback: the rollback run did not complete before the smoke probe was created")
    expander_matches(evidence, failures, "E-expander")
    if (evidence.get("trust_readback") or {}).get("pass") is not True:
        failures.append("E-trust: trust-boundary readback did not pass")
    warm = evidence.get("warm_after") or []
    latest = evidence.get("latest_collection_at")
    if len(warm) != 2 or any(runner.get("pool") != BASELINE for runner in warm):
        failures.append(f"E-warm: warm runners {[(r.get('runner_name'), r.get('pool')) for r in warm]}, expected two on {BASELINE}")
    elif not isinstance(latest, str) or not latest:
        failures.append("E-warm: latest_collection_at is missing; the warm set cannot be tied to the final collection")
    else:
        stale = [runner.get("runner_name") for runner in warm
                 if runner.get("observed_at") != latest or runner.get("phase") != "Running"
                 or runner.get("ready") is not True or runner.get("terminating") is not False
                 or runner.get("idle") is not True]
        if stale or len({runner.get("runner_name") for runner in warm}) != 2:
            failures.append(f"E-warm: warm runners {stale or [r.get('runner_name') for r in warm]} were not current, "
                            f"Running, Ready, non-terminating and idle in the final collection at {latest}")
    check_batch("E", jobs, failures)
    check_pickup("E", evidence, jobs, failures, report)


# --- runner network isolation (Phase A network probe) ----------------------

NETWORK_PROBE_JOB = "network-probe"
RUNNER_NAME_PREFIX = "redducklabs-runners-"
WORKER_POOL = "worker-pool"
IMDS_ADDRESS = "169.254.169.254:80"
RUNNER_POOLS = (BASELINE, PRIMARY, FALLBACK)
# target -> expected outcome. "allowed" must be observed "connected"; "blocked"
# must be observed "blocked" (the connection timed out: the packets were
# dropped). "refused" means the path was open and is a failure too.
NETWORK_TARGETS = {
    "dns-github": "allowed",
    "https-github": "allowed",
    "imds": "blocked",
    "worker-node-kubelet": "blocked",
    "worker-node-ssh": "blocked",
    "runner-node-kubelet": "blocked",
    "runner-node-public-kubelet": "blocked",
    "runner-node-public-ssh": "blocked",
    "kubernetes-service": "blocked",
    "other-namespace-service": "blocked",
    "other-namespace-pod": "blocked",
}
EXPECTED_OBSERVATION = {"allowed": "connected", "blocked": "blocked"}


def network_target_errors(probe):
    """The probe's targets must be what the spec names, as verified in the cluster."""
    errors = []
    targets = probe.get("targets") or {}
    checks = probe.get("target_checks") or {}
    worker, runner = checks.get("worker_node") or {}, checks.get("runner_node") or {}
    public = checks.get("runner_node_public") or {}
    service, pod = checks.get("service") or {}, checks.get("pod") or {}
    if worker.get("pool") != WORKER_POOL:
        errors.append(f"worker_node {targets.get('worker_node')!r} is not a {WORKER_POOL} node (found {worker or None})")
    if runner.get("pool") != BASELINE:
        errors.append(f"runner_node {targets.get('runner_node')!r} is not a {BASELINE} node (found {runner or None})")
    if public.get("pool") not in RUNNER_POOLS or public.get("address_type") != "ExternalIP":
        errors.append(f"runner_node_public {targets.get('runner_node_public')!r} is not the public (ExternalIP) "
                      f"address of a runner node (found {public or None})")
    if not service or service.get("namespace") in (None, "arc-runners") or service.get("type") != "ClusterIP" \
            or service.get("port_declared") is not True:
        errors.append(f"service {targets.get('service')!r} is not a declared port of a ClusterIP service outside arc-runners (found {service or None})")
    if not pod or pod.get("namespace") in (None, "arc-runners") or pod.get("port_declared") is not True:
        errors.append(f"pod {targets.get('pod')!r} is not a declared port of a pod outside arc-runners (found {pod or None})")
    elif pod.get("allowed_by_dns_rule") is not False:
        errors.append(f"pod {targets.get('pod')!r} is a kube-dns pod, which the runner policy's DNS rule selects; "
                      "use a pod no allow rule selects")
    if not (checks.get("kubernetes_service") or {}).get("address"):
        errors.append("the default/kubernetes Service ClusterIP was not resolved")
    return errors


def check_network_probe(evidence, failures, report, notes):
    """A-network: the runner network policy holds from inside a runner pod."""
    probe = evidence.get("network_probe")
    if not isinstance(probe, dict):
        failures.append("A-network: no network probe evidence (run the probe with network_targets)")
        return
    if probe.get("error"):
        failures.append(f"A-network: network probe evidence incomplete: {probe.get('error')}")
        return
    job = probe.get("job") or {}
    if job.get("name") != NETWORK_PROBE_JOB or job.get("conclusion") != "success":
        failures.append(f"A-network: job {NETWORK_PROBE_JOB!r} concluded {job.get('conclusion')!r}, expected success")
    if not str(job.get("runner_name") or "").startswith(RUNNER_NAME_PREFIX):
        failures.append(f"A-network: the probe ran on {job.get('runner_name')!r}, not a {RUNNER_NAME_PREFIX}* runner")
    if probe.get("pass") is not True:
        failures.append("A-network: the network probe did not report pass")
    results = probe.get("results")
    if not isinstance(results, list):
        failures.append("A-network: network probe results are missing")
        return
    seen = {}
    for result in results:
        target = result.get("target") if isinstance(result, dict) else None
        if target not in NETWORK_TARGETS or target in seen:
            failures.append(f"A-network: unexpected or repeated probe target {target!r}")
            continue
        seen[target] = result
    missing = sorted(set(NETWORK_TARGETS) - set(seen))
    if missing:
        failures.append(f"A-network: probe targets not checked: {', '.join(missing)}")
    targets = probe.get("targets") or {}
    addresses = {
        "imds": IMDS_ADDRESS,
        "worker-node-kubelet": f"{targets.get('worker_node')}:10250",
        "worker-node-ssh": f"{targets.get('worker_node')}:22",
        "runner-node-kubelet": f"{targets.get('runner_node')}:10250",
        "runner-node-public-kubelet": f"{targets.get('runner_node_public')}:10250",
        "runner-node-public-ssh": f"{targets.get('runner_node_public')}:22",
        "kubernetes-service": ((probe.get("target_checks") or {}).get("kubernetes_service") or {}).get("address"),
        "other-namespace-service": targets.get("service"),
        "other-namespace-pod": targets.get("pod"),
    }
    for target, result in seen.items():
        expected = NETWORK_TARGETS[target]
        observed = result.get("observed")
        if result.get("expected") != expected:
            failures.append(f"A-network: {target} was probed as {result.get('expected')!r}, the spec requires {expected}")
        elif expected == "blocked" and observed == "connected":
            failures.append(f"A-network: forbidden connection to {target} ({result.get('address')}) succeeded")
        elif observed != EXPECTED_OBSERVATION[expected]:
            failures.append(f"A-network: {target} ({result.get('address')}) observed {observed!r}, expected {EXPECTED_OBSERVATION[expected]}")
        if target in addresses and result.get("address") != addresses[target]:
            failures.append(f"A-network: {target} probed {result.get('address')!r}, not {addresses[target]!r}")
    for error in network_target_errors(probe):
        failures.append(f"A-network: {error}")
    report["network_probe_targets"] = len(seen)


PHASE_CHECKS = {"A": phase_a, "B": phase_b, "C": phase_c, "D": phase_d, "E": phase_e}
# Additional criteria per phase. Phase A: runner network isolation (A-network).
EXTRA_CRITERIA = {phase: [] for phase in PHASES}
EXTRA_CRITERIA["A"].append(check_network_probe)


def verdict(phase, evidence):
    failures, notes, report = [], [], {}
    if phase not in PHASE_CHECKS:
        raise ValueError(f"unknown phase {phase!r}")
    if not isinstance(evidence, dict):
        failures.append("evidence: not a JSON object")
    elif evidence.get("phase") != phase:
        failures.append(f"evidence: evidence is for phase {evidence.get('phase')!r}, not {phase}")
    else:
        try:
            PHASE_CHECKS[phase](evidence, failures, report, notes)
            check_runner_health(evidence, failures, notes)
        except EvidenceError as error:
            failures.append(f"evidence: {error}")
    passed = not failures
    return {
        "phase": phase,
        "pass": passed,
        "failures": failures,
        "ready_for_migration": passed and phase == "E",
        "notes": notes,
        "pickup": report,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--phase", required=True, choices=PHASES)
    parser.add_argument("evidence")
    parser.add_argument("--out")
    args = parser.parse_args()
    try:
        with open(args.evidence, encoding="utf-8") as stream:
            evidence = json.load(stream)
    except (OSError, ValueError) as error:
        print(f"ERROR: cannot read evidence {args.evidence}: {error}", file=sys.stderr)
        return 2
    try:
        result = verdict(args.phase, evidence)
    except Exception as error:  # noqa: BLE001 - an evaluation crash must still yield a failing verdict
        traceback.print_exc()
        result = {"phase": args.phase, "pass": False, "ready_for_migration": False, "notes": [], "pickup": {},
                  "failures": [f"verdict-error: {type(error).__name__}: {error}"]}
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as stream:
            stream.write(text + "\n")
    print(text)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
