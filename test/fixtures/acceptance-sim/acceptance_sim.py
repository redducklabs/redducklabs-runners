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

Faults: scenario "faults" maps a full call line ("kubectl get events -A -o
json") to the number of times it fails (exit 1) before it answers normally.
Runner pods carry a spec with one literal env value
(LITERAL_ENV_VALUE) and one valueFrom reference, and the fixture's
container_statuses as Kubernetes containerStatuses.
"""

LITERAL_ENV_VALUE = "literal-env-value-must-not-appear"

import json
import os
import sys
from datetime import datetime, timezone

PROBE_REPO = "redducklabs/aurolegal.ai"
FLEET_REPO = "redducklabs/redducklabs-runners"
POOL_LABEL = "doks.digitalocean.com/node-pool"


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
             "count": entry["count"], "auto_scale": True} for name, entry in (pools or {}).items()]


def init(directory, evidence_path, overrides):
    with open(evidence_path, encoding="utf-8") as stream:
        ev = json.load(stream)
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
        scenario["logs"]["4441"] = (f"{drain['started'][:-1]}.1000000Z PLAN: helm upgrade redducklabs-runners from burst:2/20 to drain 2/4\n"
                                    f"{drain['effective'][:-1]}.2000000Z READBACK: ARC is drain 2/4\n")
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
                     "spec": {"nodeName": warm["node"]}, "status": {"phase": "Running"}})
        runners.append({"metadata": {"name": warm["runner_name"]}, "status": {"phase": "Running"}})
    scenario["pods"], scenario["ephemeral_runners"] = pods, runners
    scenario["events"] = [{"metadata": {"uid": event["uid"], "namespace": event["namespace"]},
                           "reason": event["reason"], "type": event["type"], "message": event["message"],
                           "involvedObject": {"kind": event["involved_kind"], "name": event["involved_name"]},
                           "firstTimestamp": event["first_timestamp"], "lastTimestamp": event["last_timestamp"], "count": 1}
                          for event in ev.get("events") or []]
    expander = ev.get("expander_readback") or {}
    scenario["cluster"] = {"id": "cluster-1", "name": "redducklabs-cluster",
                           "cluster_autoscaler_configuration": {"expanders": expander.get("expanders") or []}}
    priorities = "".join(f"{key}:\n" + "".join(f"  - {value}\n" for value in values)
                         for key, values in (expander.get("priorities") or {}).items())
    scenario["configmap"] = {"metadata": {"labels": {"doks.digitalocean.com/managed": "true"} if expander.get("managed") else {}},
                             "data": {"priorities": priorities}}
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
            f"{started}.1000000Z printf 'NETWORK_PROBE_%s %s\\n' RESULT \"${{REPORT}}\"\n"
            f"{started}.2000000Z NETWORK_PROBE_RESULT {json.dumps(report)}\n")
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
    paginate = args[1:3] == ["--paginate", "--slurp"]
    path = args[3] if paginate else args[1]
    parts = path.split("?")[0].split("/")
    if parts[0] == "repos" and len(parts) >= 5:
        repo = "/".join(parts[1:3])
        if parts[3:5] == ["git", "ref"] and parts[5] == "tags":
            tag = sim.scenario["tags"].get("/".join(parts[6:]))
            return out({"object": {"type": tag["type"], "sha": tag["sha"]}}) if tag else 1
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
            return out([{"workflow_runs": sim.scenario["repo_runs"].get(repo, [])}])
        if parts[3:5] == ["actions", "runs"] and len(parts) >= 6:
            run = sim.find_run(repo, parts[5])
            if run is None:
                for extra in sim.scenario.get("extra_runs", {}).values():
                    if extra["repo"] == repo and str(extra["id"]) == parts[5] and paginate and parts[6:] == ["jobs"]:
                        return out([{"jobs": extra["jobs"]}])
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


def kubectl(sim, args):
    line = " ".join(args)
    scenario = sim.scenario
    if args[:2] == ["config", "use-context"]:
        return 0
    if args == ["config", "current-context"]:
        print("do-sfo3-redducklabs-cluster")
        return 0
    if line == "get nodes -l node-type=github-runner -o json":
        removed = scenario.get("nodes_removed_at") or {}
        return out({"items": [node for node in scenario["nodes"]
                              if sim.clock < removed.get(node["metadata"]["name"], sim.clock + 1)]})
    if line == "get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners -o json":
        return out({"items": scenario["pods"]})
    if line == "get ephemeralrunners.actions.github.com -n arc-runners -o json":
        return out({"items": scenario["ephemeral_runners"]})
    if line == "get events -A -o json":
        return out({"items": scenario["events"]})
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
    if args[:2] == ["auth", "init"] or args[:4] == ["kubernetes", "cluster", "kubeconfig", "save"]:
        return 0
    if line == "kubernetes cluster list -o json":
        return out([sim.scenario["cluster"]])
    if line == "kubernetes cluster node-pool list cluster-1 -o json":
        switch = sim.scenario.get("pools_switch_at") or 0
        return out(sim.scenario["pools_after"] if sim.clock >= switch else sim.scenario["pools_before"])
    return None


def main():
    directory, tool = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    if tool == "init":
        init(directory, args[0], json.loads(args[1]) if len(args) > 1 else {})
        return 0
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
