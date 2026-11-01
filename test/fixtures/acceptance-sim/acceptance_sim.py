#!/usr/bin/env python3
"""Fake gh/kubectl/doctl/sleep for test/verify-acceptance.sh.

  acceptance_sim.py DIR init EVIDENCE.json OVERRIDES_JSON
      builds DIR/scenario.json from an acceptance evidence fixture: the probe
      run and its jobs, the anchor runs (drain, Phase C, rollback), runner
      pods, nodes, EphemeralRunners, events, node pools, the expander
      ConfigMap and the dispatch tag. OVERRIDES_JSON is merged into the
      scenario (dotted keys such as "runs.probe.api.path").
  acceptance_sim.py DIR <gh|kubectl|doctl|sleep> ARGS...
      answers one CLI call from the scenario; every call is appended to
      DIR/calls.log. Unknown calls exit 97. "sleep N" advances DIR/clock.

Run status: "completed" once the clock reaches the run's complete_at; after
`gh run cancel` a run with cancel=completes is completed (conclusion
cancelled) 30 s later, while cancel=ignored never completes.

Run lists honour the created (A..B, >=X, ...) and status filters, job lists
the filter (latest/all by run_attempt) parameter; an unsupported query
parameter exits 97. Scenario "changes" alter pods and EphemeralRunners from a
clock time on (see live()).

ARC model (Ruling 43): ARC 0.14.2 targets minRunners + assigned jobs
(cmd/ghalistener/scaler/scaler.go:237), so a batch probe of N jobs runs
MIN_RUNNERS + N runner pods. init refuses (exit 97) a batch scenario whose
fixture pod_collections have no collection inside the hold (every entry in
progress) or whose latest in-hold collection does not list MIN_RUNNERS + N
runner pods. The pods are served per collection: each kubectl call returns
the scenario pods after the "changes" due by the clock, so a scenario can keep
a pod Pending (spec.nodeName null) through the hold and schedule it later,
replace an idle pod ("add" then "remove"), or start collecting after the hold
(an overridden "clock").

EphemeralRunners and node pools are served per collection time (Ruling 44
revised): each fixture pod collection's runners, with exactly its job fields,
from that collection's requested_at; each fixture pool collection's counts from
its requested_at (see timelines()). A runner that holds another run's job adds
one runner to the ARC model above.

Job logs carry terminal escape sequences as live logs do: the network-probe
result line and the drain READBACK line are colored around and inside their
markers and payload, so the collector parses them only after stripping.

Faults: scenario "faults" maps a full call line ("kubectl get events -A -o
json") to the number of times it fails (exit 1) before it answers normally.
"faults_at" maps a call line to {"from": ISO, "count": N}: once the clock
reaches "from", the next N such calls fail. The collector retries with
backoff through SLEEP_CMD, so the clock advances during the read: this models
a delayed, retried pod read whose response arrives later than it was asked.
Runner pods carry a spec with one literal env value
(LITERAL_ENV_VALUE) and one valueFrom reference, and the fixture's
container_statuses as Kubernetes containerStatuses.
"""

LITERAL_ENV_VALUE = "literal-env-value-must-not-appear"

import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import parse_qs

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from doctl_encoding import encode_pool_list  # noqa: E402  (doctl's live omitempty encoding, Ruling 39)

PROBE_REPO = "redducklabs/aurolegal.ai"
FLEET_REPO = "redducklabs/redducklabs-runners"
POOL_LABEL = "doks.digitalocean.com/node-pool"
MIN_RUNNERS = 2


def epoch(value):
    return int(datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def merge(target, dotted, value):
    keys = dotted.split(".")
    for key in keys[:-1]:
        target = target.setdefault(key, {})
    target[keys[-1]] = value


def run_api(run_id, repo, path, head_sha, head_branch, created, conclusion="success"):
    return {"id": run_id, "path": path, "head_sha": head_sha, "head_branch": head_branch,
            "event": "workflow_dispatch", "run_attempt": 1, "conclusion": conclusion,
            "created_at": created, "run_started_at": created, "updated_at": created,
            "repository": {"full_name": repo}}


def doctl_pools(pools):
    return [{"id": entry["id"], "name": name, "min_nodes": entry["min"], "max_nodes": entry["max"],
             "count": entry["count"], "auto_scale": True,
             # Runner pools carry the runner label and taint (Ruling 46).
             "labels": {"node-type": "github-runner"},
             "taints": [{"key": "github-runner", "value": "true", "effect": "NoSchedule"}]}
            for name, entry in (pools or {}).items()]


def arc_model_errors(ev):
    """A batch probe of N jobs must hold MIN_RUNNERS + N runner pods (ARC 0.14.2)."""
    run = ((ev.get("probe") or {}).get("run")) or {}
    batch = [job for job in run.get("jobs") or [] if str(job.get("name", "")).startswith("batch ")]
    if run.get("mode") != "batch" or not batch:
        return None
    start = max(epoch(job["started_at"]) for job in batch)
    end = min(epoch(job["completed_at"]) for job in batch)
    if start > end:
        return None
    held = [collection for collection in ev.get("pod_collections") or []
            if start <= epoch(collection["requested_at"]) and epoch(collection["observed_at"]) <= end]
    if not held:
        return f"acceptance-sim: the fixture has no pod collection inside the hold {iso(start)}..{iso(end)}"
    latest = max(held, key=lambda collection: epoch(collection["observed_at"]))
    # A runner holding another run's job (a shared fleet) is one more runner.
    foreign = sum(1 for pod in latest["pods"]
                  if pod.get("job") and str(pod["job"].get("workflowRunId")) != str(run.get("id")))
    if len(latest["pods"]) != MIN_RUNNERS + len(batch) + foreign:
        extra = f" and {foreign} other runs' jobs" if foreign else ""
        return (f"acceptance-sim: {len(batch)} batch jobs{extra} need {MIN_RUNNERS + len(batch) + foreign} runner pods "
                f"during the hold (ARC 0.14.2 targets minRunners + jobs), the fixture's collection observed at "
                f"{latest['observed_at']} has {len(latest['pods'])}")
    return None


def timelines(ev):
    """Per-collection EphemeralRunner and node-pool states, replayed by clock.

    Each fixture pod collection's runner read (ephemeral_runners: its complete
    runner list, runners without a pod included) becomes the EphemeralRunner
    list served from that read's requested_at on, with exactly its job fields,
    so a job can start and end between collections; a collection without one
    serves one EphemeralRunner per listed pod. Each fixture pool collection becomes the node-pool
    counts served from its requested_at on. Nothing is merged across
    collections."""
    runners = []
    for collection in ev.get("pod_collections") or []:
        read = collection.get("ephemeral_runners")
        if isinstance(read, dict):
            # The fixture's complete runner read: every runner, pod or not.
            items = [{"metadata": {"name": runner["name"], "uid": runner.get("uid")},
                      "status": dict(runner.get("job") or {}, phase=runner.get("phase") or "Running")}
                     for runner in read.get("items") or []]
            runners.append({"at": read["requested_at"], "items": items})
        else:
            runners.append({"at": collection["requested_at"],
                            "items": [{"metadata": {"name": pod["runner_name"]},
                                       "status": dict(pod.get("job") or {}, phase="Running")}
                                      for pod in collection.get("pods") or []]})
    pools = [{"at": read["requested_at"], "pools": read["pools"]} for read in ev.get("pool_collections") or []]
    return (sorted(runners, key=lambda entry: epoch(entry["at"])), sorted(pools, key=lambda entry: epoch(entry["at"])))


def at_clock(timeline, clock):
    """The timeline entry in effect at clock (the latest one not after it)."""
    current = None
    for entry in timeline:
        if epoch(entry["at"]) <= clock:
            current = entry
    return current


def init(directory, evidence_path, overrides):
    with open(evidence_path, encoding="utf-8") as stream:
        ev = json.load(stream)
    error = arc_model_errors(ev)
    if error:
        print(error, file=sys.stderr)
        return 97
    phase = ev["phase"]
    scenario = {"phase": phase, "runs": {}, "tags": {}, "artifacts": {}, "repo_runs": {}, "logs": {}}
    probe = ev.get("probe")
    complete_at = None
    if probe:
        run = probe["run"]
        complete_at = max(epoch(job["completed_at"]) for job in run["jobs"]) + 60
        api = run_api(777, PROBE_REPO, probe["workflow_path"], run["head_sha"], run["head_branch"], run["created_at"])
        scenario["runs"]["probe"] = {"repo": PROBE_REPO, "id": 777, "api": api, "complete_at": complete_at,
                                     "cancel": "completes",
                                     "jobs": [dict(job, status="completed") for job in run["jobs"]]}
        scenario["tags"][probe["dispatch_tag"]] = {"type": "tag", "sha": "tagobject1", "commit": probe["tag_sha"]}
        scenario["clock"] = epoch(run["created_at"]) + 600
    drain = (probe or {}).get("drain")
    if drain:
        api = run_api(444, FLEET_REPO, drain["workflow_path"], drain["head_sha"], "main", drain["started"])
        scenario["runs"]["drain"] = {
            "repo": FLEET_REPO, "id": 444, "api": api, "complete_at": epoch(drain["completed"]) + 30,
            "cancel": "ignored",
            "view_jobs": [{"name": "Drain Burst Runners", "databaseId": 4441, "conclusion": drain["conclusion"],
                           "steps": [{"name": "Drain runners", "conclusion": drain["conclusion"],
                                      "startedAt": drain["started"], "completedAt": drain["completed"]}]}]}
        # The drain ends with both burst pools at zero nodes.
        scenario["nodes_removed_at"] = {node["name"]: epoch(drain["completed"]) for node in ev.get("nodes") or []
                                        if node["pool"] != "github-runners-pool-16g"}
        # Colored like live logs: the READBACK marker is split by escapes and
        # the whole line, timestamp included, sits inside a color.
        scenario["logs"]["4441"] = (f"{drain['started'][:-1]}.1000000Z PLAN: helm upgrade redducklabs-runners from burst:2/20 to drain 2/4\n"
                                    f"\x1b[0m{drain['effective'][:-1]}.2000000Z \x1b[1;32mREAD\x1b[0;32mBACK:\x1b[0m ARC is drain 2/4\x1b[0m\n")
    if ev.get("phase_c_run"):
        info = ev["phase_c_run"]
        api = run_api(555, FLEET_REPO, info["workflow_path"], info["head_sha"], "main", info["started"])
        start = epoch(info["started"])
        scenario["runs"]["phase_c"] = {"repo": FLEET_REPO, "id": 555, "api": api, "complete_at": start + 600,
                                       "cancel": "ignored", "view_jobs": [{"name": info["job_name"], "conclusion": info["conclusion"]}],
                                       "final_conclusion": info["conclusion"]}
        artifact = dict(ev["phase_c"], jobs_killed=None, jobs_killed_note="not measured by phase-c script")
        artifact.pop("killed_jobs", None)
        scenario["artifacts"]["555/phase-c-evidence"] = artifact
        scenario["clock"] = start + 60
    if ev.get("rollback_run"):
        info = ev["rollback_run"]
        api = run_api(333, FLEET_REPO, info["workflow_path"], info["head_sha"], "main", "2026-11-02T17:00:00Z",
                      info["conclusion"])
        scenario["runs"]["rollback"] = {"repo": FLEET_REPO, "id": 333, "api": api,
                                        "complete_at": epoch(info["completed_at"]), "cancel": "ignored",
                                        "view_jobs": [{"name": info["job_name"], "conclusion": info["conclusion"],
                                                       "steps": [{"name": "Verify rollback transition and density readback",
                                                                  "conclusion": info["readback_step"]}]}]}
    if ev.get("recorded_baseline"):
        base = ev["recorded_baseline"]
        api = run_api(base["run_id"], FLEET_REPO, ".github/workflows/runner-acceptance-evidence.yml",
                      ev["expected_sha"], "main", "2026-11-02T16:00:00Z")
        scenario["runs"]["baseline"] = {"repo": FLEET_REPO, "id": base["run_id"], "api": api, "complete_at": 0,
                                        "cancel": "ignored"}
        scenario["artifacts"][f"{base['run_id']}/acceptance-A"] = {
            "phase": "A", "verdict": {"pass": True},
            "pools_before": {"github-runners-pool-16g": {"id": base["pool_id"]}}}
    scenario["nodes"] = [{"metadata": {"name": node["name"], "labels": {POOL_LABEL: node["pool"], "node-type": "github-runner"},
                                       "creationTimestamp": node["created_at"]},
                          "status": {"conditions": [{"type": "Ready", "status": "True", "lastTransitionTime": node["ready_at"]}],
                                     "nodeInfo": {"kubeletVersion": node["kubelet_version"]}}}
                         for node in ev.get("nodes") or []]
    def k8s_statuses(statuses):
        result = []
        for status in statuses or []:
            item = {"name": status["name"], "restartCount": status["restart_count"], "state": status["state"]}
            if status.get("last_terminated_reason"):
                item["lastState"] = {"terminated": {"reason": status["last_terminated_reason"],
                                                    "exitCode": status["last_terminated_exit_code"],
                                                    "message": "kernel log text"}}
            result.append(item)
        return result

    def pod_spec(node_name):
        return {"nodeName": node_name, "containers": [{"name": "runner", "env": [
            {"name": "LITERAL_SETTING", "value": LITERAL_ENV_VALUE},
            {"name": "FROM_REF", "valueFrom": {"secretKeyRef": {"name": "ref", "key": "key"}}}]}]}

    pods = [{"metadata": {"name": pod["runner_name"], "uid": pod["uid"], "creationTimestamp": pod["created_at"],
                          "annotations": pod["annotations"]},
             "spec": pod_spec(pod["node"]),
             "status": {"phase": "Succeeded", "containerStatuses": k8s_statuses(pod.get("container_statuses"))}}
            for pod in ev.get("pods") or []]
    runners = []
    for warm in ev.get("warm_after") or []:
        pods.append({"metadata": {"name": warm["runner_name"], "uid": "uid-" + warm["runner_name"],
                                  "creationTimestamp": "2026-11-02T18:30:00Z", "annotations": {}},
                     "spec": {"nodeName": warm["node"]},
                     "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}})
        runners.append({"metadata": {"name": warm["runner_name"]}, "status": {"phase": "Running"}})
    scenario["pods"], scenario["ephemeral_runners"] = pods, runners
    scenario["runner_timeline"], scenario["pool_timeline"] = timelines(ev)
    # cluster-autoscaler events carry source.component cluster-autoscaler,
    # which is how the collector keeps ScaledUpGroup events on its status
    # ConfigMap in kube-system.
    autoscaler_reasons = ("TriggeredScaleUp", "NotTriggerScaleUp", "ScaledUpGroup", "ScaleDown")
    scenario["events"] = [{"metadata": {"uid": event["uid"], "namespace": event["namespace"]},
                           "reason": event["reason"], "type": event["type"], "message": event["message"],
                           "involvedObject": {"kind": event["involved_kind"], "name": event["involved_name"]},
                           "source": {"component": "cluster-autoscaler" if event["reason"] in autoscaler_reasons
                                      else "kubelet"},
                           "firstTimestamp": event["first_timestamp"], "lastTimestamp": event["last_timestamp"], "count": 1}
                          for event in ev.get("events") or []]
    expander = ev.get("expander_readback") or {}
    scenario["cluster"] = {"id": "cluster-1", "name": "redducklabs-cluster",
                           "cluster_autoscaler_configuration": {"expanders": expander.get("expanders") or []}}
    priorities = "".join(f"{key}:\n" + "".join(f"  - {value}\n" for value in values)
                         for key, values in (expander.get("priorities") or {}).items())
    scenario["configmap"] = {"metadata": {"labels": {"doks.digitalocean.com/managed": "true"} if expander.get("managed") else {}},
                             "data": {"priorities": priorities}}
    # Other node pools of the cluster (node_pools evidence, Ruling 46): served
    # with their labels and taints after the runner pools.
    runner_names = set((ev.get("pools_before") or {}).keys())
    scenario["extra_pools"] = [{"id": item["id"], "name": item["name"], "min_nodes": 1, "max_nodes": 3, "count": 2,
                                "auto_scale": True, "labels": item.get("labels") or {}, "taints": item.get("taints") or []}
                               for item in ev.get("node_pools") or [] if item.get("name") not in runner_names]
    scenario["pools_before"] = doctl_pools(ev.get("pools_before"))
    scenario["pools_after"] = doctl_pools(ev.get("pools_after"))
    scenario["pools_switch_at"] = complete_at or 0
    # Phase A network probe: the job log line and the cluster objects its
    # targets resolve to (worker and runner nodes, a service, a pod).
    network = ev.get("network_probe") or {}
    probe_jobs_by_name = {job["name"]: job for job in ((probe or {}).get("run") or {}).get("jobs") or []}
    scenario["cluster_nodes"], scenario["services"], scenario["all_pods"] = [], [], []
    if network.get("results") and "network-probe" in probe_jobs_by_name:
        report = {"pass": network["pass"], "targets": network["targets"], "results": network["results"]}
        started = probe_jobs_by_name["network-probe"]["started_at"][:-1]
        scenario["logs"][str(probe_jobs_by_name["network-probe"]["id"])] = (
            # Live job logs carry terminal escape sequences (the run-step echo
            # is colored), which gh refuses to print without
            # --allow-escape-sequences.
            f"{started}.1000000Z \x1b[36;1mprintf 'NETWORK_PROBE_%s %s\\n' RESULT \"${{REPORT}}\"\x1b[0m\n"
            # The marker and the JSON payload are colored too, one escape
            # inside the marker and one inside the payload.
            f"{started}.2000000Z \x1b[32mNETWORK_PROBE\x1b[1m_RESULT\x1b[0m "
            f"\x1b[33m{{\x1b[0m{json.dumps(report)[1:]}\x1b[0m\n")
        targets, checks = network["targets"], network["target_checks"]
        nodes = {}
        for key in ("worker_node", "runner_node", "runner_node_public"):
            if checks.get(key):
                node = nodes.setdefault(checks[key]["node"], {
                    "metadata": {"name": checks[key]["node"], "labels": {POOL_LABEL: checks[key]["pool"]}},
                    "status": {"addresses": [{"type": "Hostname", "address": checks[key]["node"]}]}})
                node["status"]["addresses"].append({"type": checks[key]["address_type"], "address": targets[key]})
        scenario["cluster_nodes"] = list(nodes.values())
        if checks.get("kubernetes_service"):
            host = checks["kubernetes_service"]["address"].rsplit(":", 1)[0]
            scenario["services"].append({
                "metadata": {"name": "kubernetes", "namespace": "default"},
                "spec": {"type": "ClusterIP", "clusterIP": host, "clusterIPs": [host],
                         "ports": [{"port": 443, "protocol": "TCP"}]}})
        if checks.get("service"):
            host, port = targets["service"].rsplit(":", 1)
            declared = int(port) if checks["service"]["port_declared"] else int(port) + 1
            scenario["services"].append({
                "metadata": {"name": checks["service"]["name"], "namespace": checks["service"]["namespace"]},
                "spec": {"type": checks["service"]["type"], "clusterIP": host, "clusterIPs": [host],
                         "ports": [{"port": declared, "protocol": "TCP"}]}})
        if checks.get("pod"):
            host, port = targets["pod"].rsplit(":", 1)
            declared = int(port) if checks["pod"]["port_declared"] else int(port) + 1
            labels = {"k8s-app": "kube-dns"} if checks["pod"].get("allowed_by_dns_rule") \
                else {"app.kubernetes.io/name": "metrics-server"}
            scenario["all_pods"].append({
                "metadata": {"name": checks["pod"]["name"], "namespace": checks["pod"]["namespace"],
                             "labels": labels},
                "spec": {"containers": [{"name": "main", "ports": [{"containerPort": declared}]}]},
                "status": {"phase": "Running", "podIP": host}})
    for key, value in overrides.items():
        merge(scenario, key, value)
    with open(os.path.join(directory, "scenario.json"), "w", encoding="utf-8") as stream:
        json.dump(scenario, stream, indent=1)
    with open(os.path.join(directory, "clock"), "w", encoding="utf-8") as stream:
        stream.write(f"{scenario.get('clock', 1800000000)}\n")


class Sim:
    def __init__(self, directory):
        self.directory = directory
        with open(os.path.join(directory, "scenario.json"), encoding="utf-8") as stream:
            self.scenario = json.load(stream)
        with open(os.path.join(directory, "clock"), encoding="utf-8") as stream:
            self.clock = int(stream.read().strip())

    def save(self):
        with open(os.path.join(self.directory, "scenario.json"), "w", encoding="utf-8") as stream:
            json.dump(self.scenario, stream, indent=1)

    def find_run(self, repo, run_id):
        for run in self.scenario["runs"].values():
            if run["repo"] == repo and str(run["id"]) == str(run_id):
                return run
        return None

    def status(self, run):
        if run.get("cancelled_at") is not None:
            if run["cancel"] == "completes" and self.clock >= run["cancelled_at"] + 30:
                return "completed", "cancelled"
            if run["cancel"] == "ignored" and run.get("complete_at") is None:
                return "in_progress", None
        if run.get("complete_at") is not None and self.clock >= run["complete_at"]:
            return "completed", run.get("final_conclusion", run["api"].get("conclusion"))
        return "in_progress", None

    def run_json(self, run):
        state, conclusion = self.status(run)
        api = dict(run["api"], status=state, conclusion=conclusion)
        if state == "completed":
            api["updated_at"] = iso(run["complete_at"] if run.get("complete_at") is not None else self.clock)
        return api


def out(document):
    print(json.dumps(document))
    return 0


def created_matches(value, created):
    """GitHub's created filter: A..B (inclusive, * open), >=X, <=X, >X, <X, or X."""
    if not created:
        return True
    if not value:
        return False
    at = epoch(value)

    def bound(text):
        text = text.strip()
        return None if text == "*" else epoch(text)

    if ".." in created:
        low, high = (bound(text) for text in created.split("..", 1))
        return (low is None or at >= low) and (high is None or at <= high)
    for prefix, test in ((">=", lambda x: at >= x), ("<=", lambda x: at <= x),
                         (">", lambda x: at > x), ("<", lambda x: at < x)):
        if created.startswith(prefix):
            return test(epoch(created[len(prefix):]))
    return at == epoch(created)


def select_runs(runs, query):
    """The run list endpoint's selection: created and status filters; None for
    an unsupported parameter, so a collector query the fake cannot honour fails."""
    if set(query) - {"created", "status", "per_page", "page"}:
        return None
    created = (query.get("created") or [""])[0]
    status = (query.get("status") or [""])[0]
    try:
        selected = [run for run in runs if created_matches(run.get("created_at"), created)]
    except ValueError:
        return None
    if status:
        selected = [run for run in selected if status in (run.get("status"), run.get("conclusion"))]
    return selected


def select_jobs(jobs, query):
    """filter=latest (default): jobs of the highest run_attempt; filter=all: every attempt."""
    if set(query) - {"filter", "per_page", "page"}:
        return None
    mode = (query.get("filter") or ["latest"])[0]
    if mode == "all":
        return jobs
    if mode != "latest":
        return None
    latest = max((job.get("run_attempt", 1) for job in jobs), default=1)
    return [job for job in jobs if job.get("run_attempt", 1) == latest]


def gh(sim, args):
    line = " ".join(args)
    if args[:2] == ["run", "cancel"]:
        run = sim.find_run(args[4], args[2])
        if run is None:
            return 1
        if sim.status(run)[0] == "completed":
            print("Cannot cancel a workflow run that is completed", file=sys.stderr)
            return 1
        run["cancelled_at"] = sim.clock
        sim.save()
        return 0
    if args[:2] == ["run", "view"]:
        run = sim.find_run(args[4], args[2])
        return out({"jobs": run.get("view_jobs") or []}) if run else 1
    if args[:2] == ["run", "download"]:
        name = f"{args[2]}/{args[6]}"
        if name not in sim.scenario["artifacts"]:
            print(f"no artifact {name}", file=sys.stderr)
            return 1
        os.makedirs(args[8], exist_ok=True)
        with open(os.path.join(args[8], f"{args[6]}.json"), "w", encoding="utf-8") as stream:
            json.dump(sim.scenario["artifacts"][name], stream)
        return 0
    if args[0] != "api":
        return None
    if "--allow-escape-sequences" in args:
        args = [arg for arg in args if arg != "--allow-escape-sequences"]
    elif any("\x1b" in text for text in sim.scenario["logs"].values()) and "/logs" in line:
        # Like gh 2.8x: a response with escape sequences is refused.
        print("the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway",
              file=sys.stderr)
        return 1
    paginate = args[1:3] == ["--paginate", "--slurp"]
    path = args[3] if paginate else args[1]
    parts = path.split("?")[0].split("/")
    query = parse_qs(path.split("?", 1)[1], keep_blank_values=True) if "?" in path else {}
    if parts[0] == "repos" and len(parts) >= 5:
        repo = "/".join(parts[1:3])
        if parts[3:5] == ["git", "ref"] and parts[5] == "tags":
            tag = sim.scenario["tags"].get("/".join(parts[6:]))
            return out({"object": {"type": tag["type"], "sha": tag["sha"]}}) if tag else 1
        if parts[3] == "compare" and len(parts) == 5:
            # scenario "compare" maps "BASE...HEAD" to the API status (ahead,
            # behind, diverged); an unlisted pair is an unknown commit (404).
            base, head = parts[4].split("...", 1)
            status = "identical" if base == head else (sim.scenario.get("compare") or {}).get(parts[4])
            return out({"status": status}) if status else 1
        if parts[3:5] == ["git", "tags"]:
            for tag in sim.scenario["tags"].values():
                if tag["sha"] == parts[5]:
                    return out({"object": {"type": "commit", "sha": tag["commit"]}})
            return 1
        if parts[3:5] == ["actions", "jobs"] and parts[6:] == ["logs"]:
            text = sim.scenario["logs"].get(parts[5])
            if text is None:
                return 1
            sys.stdout.write(text)
            return 0
        if parts[3:5] == ["actions", "runs"] and len(parts) == 5 and paginate:
            selected = select_runs(sim.scenario["repo_runs"].get(repo, []), query)
            if selected is None:
                print(f"fake gh: unsupported run list query: {line}", file=sys.stderr)
                return 97
            # total_count is the match count. scenario "run_overflow" maps a repo to
            # {"over_seconds": S, "total_count": N}: a created range wider than S
            # reports N matches and returns none of them (results past the search
            # cap are lost), so only a bisected query sees the runs.
            overflow = sim.scenario.get("run_overflow", {}).get(repo)
            created = (query.get("created") or [""])[0]
            if overflow and ".." in created and "*" not in created:
                low, high = (epoch(text) for text in created.split("..", 1))
                if high - low > overflow["over_seconds"]:
                    return out([{"total_count": overflow["total_count"], "workflow_runs": []}])
            return out([{"total_count": len(selected), "workflow_runs": selected}])
        if parts[3:5] == ["actions", "runs"] and len(parts) >= 6:
            run = sim.find_run(repo, parts[5])
            if run is None:
                for extra in sim.scenario.get("extra_runs", {}).values():
                    if extra["repo"] == repo and str(extra["id"]) == parts[5] and paginate and parts[6:] == ["jobs"]:
                        jobs = select_jobs(extra["jobs"], query)
                        if jobs is None:
                            print(f"fake gh: unsupported job list query: {line}", file=sys.stderr)
                            return 97
                        return out([{"total_count": len(jobs), "jobs": jobs}])
                return 1
            if paginate and parts[6:9] == ["attempts", "1", "jobs"]:
                jobs = run.get("jobs") or []
                if sim.status(run)[0] != "completed":
                    jobs = [dict(job, status="in_progress", conclusion=None, completed_at=None) for job in jobs]
                elif run.get("live_jobs_after_cancel"):
                    jobs = [dict(job, status="in_progress") for job in jobs]
                return out([{"total_count": len(jobs), "jobs": jobs}])
            if len(parts) == 6 and not paginate:
                return out(sim.run_json(run))
    print(f"fake gh: unexpected call: {line}", file=sys.stderr)
    return 97


def deep_merge(target, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            deep_merge(target[key], value)
        else:
            target[key] = value


def live(sim, kind):
    """scenario[kind] after the scenario "changes" due by the clock: each
    {"at": ISO, "kind": "pods"|"ephemeral_runners", "name": metadata.name,
    "remove": true} drops the object (name "*": every object), {"merge": {...}}
    deep-merges into it, and {"add": {...}} (no name) appends a new object."""
    items = json.loads(json.dumps(sim.scenario[kind]))
    for change in sim.scenario.get("changes") or []:
        if change["kind"] != kind or sim.clock < epoch(change["at"]):
            continue
        if change.get("add"):
            items.append(json.loads(json.dumps(change["add"])))
            continue
        if change.get("remove"):
            items = [item for item in items if change["name"] not in ("*", item["metadata"]["name"])]
            continue
        for item in items:
            if item["metadata"]["name"] == change["name"]:
                deep_merge(item, change["merge"])
    return items


def kubectl(sim, args):
    line = " ".join(args)
    scenario = sim.scenario
    if args[:2] == ["config", "use-context"]:
        return 0
    if args[0] == "get" and not os.path.exists(os.path.join(sim.directory, "kubeconfig")):
        # Like kubectl without a kubeconfig: it dials the default localhost:8080.
        print('couldn't get current server API group list: Get "http://localhost:8080/api?timeout=32s": '
              "dial tcp [::1]:8080: connect: connection refused", file=sys.stderr)
        return 1
    if args == ["config", "current-context"]:
        print("do-sfo3-redducklabs-cluster")
        return 0
    if line == "get nodes -l node-type=github-runner -o json":
        removed = scenario.get("nodes_removed_at") or {}
        return out({"items": [node for node in scenario["nodes"]
                              if sim.clock < removed.get(node["metadata"]["name"], sim.clock + 1)]})
    if line == "get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners -o json":
        return out({"items": live(sim, "pods")})
    if line == "get ephemeralrunners.actions.github.com -n arc-runners -o json":
        entry = at_clock(scenario.get("runner_timeline") or [], sim.clock)
        return out({"items": ((entry or {}).get("items") or []) + live(sim, "ephemeral_runners")})
    if line == "get events -A -o json":
        # scenario "extra_events" (an override) adds events to the fixture's.
        return out({"items": scenario["events"] + (scenario.get("extra_events") or [])})
    if line == "get configmap cluster-autoscaler-priority-expander -n kube-system -o json":
        return out(scenario["configmap"])
    if line == "get nodes -o json":
        return out({"items": scenario.get("cluster_nodes") or []})
    if line == "get services -A -o json":
        return out({"items": scenario.get("services") or []})
    if args[:4] == ["get", "pods", "-A", "--field-selector"] and args[5:] == ["-o", "json"] \
            and args[4].startswith("status.podIP="):
        address = args[4].split("=", 1)[1]
        return out({"items": [pod for pod in scenario.get("all_pods") or [] if pod["status"]["podIP"] == address]})
    return None


def doctl(sim, args):
    line = " ".join(args)
    if args[:2] == ["auth", "init"]:
        return 0
    if args[:4] == ["kubernetes", "cluster", "kubeconfig", "save"]:
        open(os.path.join(sim.directory, "kubeconfig"), "w", encoding="utf-8").close()
        return 0
    if line == "kubernetes cluster list -o json":
        return out([sim.scenario["cluster"]])
    if line == "kubernetes cluster node-pool list cluster-1 -o json":
        switch = sim.scenario.get("pools_switch_at") or 0
        pools = json.loads(json.dumps(sim.scenario["pools_after"] if sim.clock >= switch else sim.scenario["pools_before"]))
        entry = at_clock(sim.scenario.get("pool_timeline") or [], sim.clock)
        for item in pools if entry else []:
            read = entry["pools"].get(item["name"]) or {}
            item.update(count=read.get("count", item["count"]), min_nodes=read.get("min", item["min_nodes"]),
                        max_nodes=read.get("max", item["max_nodes"]))
        return out(encode_pool_list(pools + (sim.scenario.get("extra_pools") or [])))
    return None


def main():
    directory, tool = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    if tool == "init":
        return init(directory, args[0], json.loads(args[1]) if len(args) > 1 else {}) or 0
    with open(os.path.join(directory, "calls.log"), "a", encoding="utf-8") as stream:
        stream.write(f"{tool} {' '.join(args)}\n")
    sim = Sim(directory)
    line = f"{tool} {' '.join(args)}"
    faults = sim.scenario.get("faults") or {}
    if faults.get(line, 0) > 0:
        faults[line] -= 1
        sim.save()
        print(f"fake {tool}: injected fault", file=sys.stderr)
        return 1
    timed = (sim.scenario.get("faults_at") or {}).get(line)
    if timed and timed["count"] > 0 and sim.clock >= epoch(timed["from"]):
        timed["count"] -= 1
        sim.save()
        print(f"fake {tool}: injected fault at {iso(sim.clock)}", file=sys.stderr)
        return 1
    if tool == "sleep":
        with open(os.path.join(directory, "clock"), "w", encoding="utf-8") as stream:
            stream.write(f"{sim.clock + int(args[0])}\n")
        return 0
    result = {"gh": gh, "kubectl": kubectl, "doctl": doctl}[tool](sim, args)
    if result is None:
        print(f"fake {tool}: unexpected call: {' '.join(args)}", file=sys.stderr)
        return 97
    return result


if __name__ == "__main__":
    sys.exit(main())
