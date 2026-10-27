#!/usr/bin/env python3
"""Stateful runner-fleet fake for the Deploy and Scale Runners fixtures.

with_fakes (test/verify-burst-autoscaling.sh) calls this hook from every fake
doctl/kubectl/helm/gh invocation when the fixture directory holds a
"stateful" marker:

    fleet_sim.py <dir> <tool> <args...>     exit 100 = not handled (use routes)
    fleet_sim.py <dir> init <scenario-json>  build fleet.json from the fixture files
    fleet_sim.py <dir> sleep <seconds>       advance the clock and the world

The world is fleet.json: the ARC state (a pool-state "arc-*" layer name), the
Helm revision history, the runners (name, node, busy) and the burst nodes.
Every change rewrites the files the read routes serve (nodes.json, pods.json,
runner-pods.json, ephemeralrunners.json, gh-runners.json, pools.json and the
ARC files helm-values.json, helm-manifest.yaml, asrs.json), so the real gate,
retirement, occupancy and workflow code read a consistent cluster.

Time passes only through "sleep" (the scripts' SLEEP_CMD): the clock file
advances by seconds x knobs.sleep_scale and the world reconciles once:
  - finished busy runners (knobs.busy_until reached) disappear;
  - a burst node without runner pods for two reconciles is scaled down;
  - ARC removes idle surplus runners (knobs.surplus: "baseline-first" keeps
    runners on burst nodes, "burst-first" removes them first) or adds missing
    ones: baseline first, then a burst node with room, then a new burst node
    (primary, then fallback) unless knobs.burst_capacity is false; under the
    drain contract (required baseline affinity) only baseline, else Pending.

Mutations handled here (each appended to mutations.log as one token):
  helm upgrade ... --values deploy/dind-values.yaml   -> burst      "helm-upgrade:burst"
  helm upgrade ... -f <drain values>                  -> drain      "helm-upgrade:drain"
  helm upgrade ... --reuse-values --set minRunners=N  -> 8/4 or 2   "helm-upgrade:min=N"
  helm upgrade ... --reuse-values --set minRunners=0 --set maxRunners=0
                                     -> <base>-stopped (Emergency Stop)  "helm-upgrade:stopped"
  helm upgrade ... --values deploy/density-values.yaml -> density   "helm-upgrade:density"
  helm rollback redducklabs-runners REV ...           -> that rev   "helm-rollback:REV"
Every Helm write keeps at most --history-max revisions (Helm's default, 10,
when the flag is absent), pruning the oldest, as Helm's release storage does.
knobs.prune_on_history_read N: from the Nth "helm history" read on, the
deployed revision is missing from the history (pruned by a concurrent write).
  kubectl delete ephemeralrunner -n arc-runners NAME  -> gone       "delete-er:<suffix>"
  Emergency Stop marker ConfigMap arc-runners/runner-fleet-emergency-stop
  (Ruling 33): "kubectl apply --server-side -f -" writes it ("stop-marker:set"),
  "kubectl delete --raw <path> -f <DeleteOptions>" deletes it only when the
  uid/resourceVersion preconditions match ("stop-marker:delete"), and
  "kubectl get configmap ... --ignore-not-found -o json" reads it (scenario
  "stop_marker" starts with one). knobs.marker_read / marker_write "fail"
  fail those calls (marker_read "fail-after-write": every read after the
  first applied Helm write); knobs.marker_bump_before_delete rewrites the marker (a
  newer stop) just before a delete; knobs.stop_before <token> runs a complete
  Emergency Stop (marker, then 0/0; "injected-stop-marker,injected-stop")
  immediately before the Helm write that would log <token>.
  kubectl apply --server-side -f deploy/runner-network-policy.yaml   "apply-netpol"
    (rewrites networkpolicies.json; knobs.netpol_dry_run "fail" fails the
    server dry run, "defaulted" returns a spec with an extra field;
    knobs.netpol_apply "drift" stores an extra egress rule)
Upgrades that render pass the template through the --post-renderer first.
knobs.fail_helm (a token) makes that write fail unchanged; knobs.cancel_after
(a token) applies the write, creates "cancel-requested" and exits 143, the way
a cancelled job kills the step after the write. knobs.admission
("drop-annotation" | "annotation-true") mutates server dry-run responses.
"""

import datetime
import json
import os
import shutil
import subprocess
import sys

import yaml

NOT_HANDLED = 100
HERE = os.path.dirname(os.path.abspath(__file__))
LAYERS = os.path.join(HERE, "..", "pool-state")
BASELINE = "github-runners-pool-16g"
PRIMARY = "github-runners-burst-16g"
FALLBACK = "github-runners-burst-amd-16g"
BURST = (PRIMARY, FALLBACK)
POOL_LABEL = "doks.digitalocean.com/node-pool"
PREFIX = "redducklabs-runners-7xk2p-runner-"
SAFE_TO_EVICT = "cluster-autoscaler.kubernetes.io/safe-to-evict"
ARC_BOUNDS = {
    "arc-burst": (2, 20), "arc-burst-acceptance-8": (8, 20), "arc-burst-acceptance-4": (4, 20),
    "arc-drain": (2, 4), "arc-density": (2, 4),
    "arc-burst-stopped": (0, 0), "arc-density-stopped": (0, 0), "arc-drain-stopped": (0, 0),
}
# Emergency Stop keeps the base template and sets 0/0 (Ruling 26).
STOP_LAYER = {
    "arc-burst": "arc-burst-stopped", "arc-burst-acceptance-8": "arc-burst-stopped",
    "arc-burst-acceptance-4": "arc-burst-stopped", "arc-burst-stopped": "arc-burst-stopped",
    "arc-density": "arc-density-stopped", "arc-density-stopped": "arc-density-stopped",
    "arc-drain": "arc-drain-stopped", "arc-drain-stopped": "arc-drain-stopped",
}
HELM_DEFAULT_HISTORY_MAX = 10
BURST_FAMILY = ("arc-burst", "arc-burst-acceptance-8", "arc-burst-acceptance-4")
MIN_LAYER = {"8": "arc-burst-acceptance-8", "4": "arc-burst-acceptance-4", "2": "arc-burst"}
DENSITY_VALUES = "deploy/density-values.yaml"
STOP_MARKER = "runner-fleet-emergency-stop"


def p(directory, name):
    return os.path.join(directory, name)


def load(directory, name):
    with open(p(directory, name), encoding="utf-8") as stream:
        return json.load(stream)


def save(directory, name, document):
    with open(p(directory, name), "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2)
        stream.write("\n")


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now(directory):
    with open(p(directory, "clock"), encoding="utf-8") as stream:
        return int(stream.read().strip())


def log(directory, token):
    with open(p(directory, "mutations.log"), "a", encoding="utf-8") as stream:
        stream.write(token + "\n")


# --------------------------------------------------------------------------
# Rendering the world into fixture files
# --------------------------------------------------------------------------

def node_pool(world, node_name):
    for node in world["base_nodes"]:
        if node["metadata"]["name"] == node_name:
            return (node["metadata"].get("labels") or {}).get(POOL_LABEL)
    for node in world["burst_nodes"]:
        if node["name"] == node_name:
            return node["pool"]
    return None


def burst_node_document(world, node):
    template = json.loads(json.dumps(world["node_template"]))
    metadata = template["metadata"]
    metadata["name"] = node["name"]
    metadata["uid"] = f"burst-uid-{node['name']}"
    metadata["creationTimestamp"] = iso(node["created"])
    labels = metadata["labels"]
    labels[POOL_LABEL] = node["pool"]
    labels["doks.digitalocean.com/node-pool-id"] = world["pool_ids"][node["pool"]]
    labels["doks.digitalocean.com/node-id"] = f"{node['name']}-id"
    labels["kubernetes.io/hostname"] = node["name"]
    labels["node.kubernetes.io/instance-type"] = "s-8vcpu-16gb-amd" if node["pool"] == FALLBACK else "s-8vcpu-16gb"
    template["spec"]["providerID"] = f"digitalocean://burst-{node['name']}"
    return template


def runner_pod(runner):
    scheduled = bool(runner["node"])
    pod = {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": runner["name"], "namespace": "arc-runners",
                     "labels": {"actions.github.com/scale-set-name": "redducklabs-runners",
                                "actions.github.com/scale-set-namespace": "arc-runners",
                                "app.kubernetes.io/component": "runner"},
                     "annotations": {SAFE_TO_EVICT: "false"}},
        "spec": {"resources": {"requests": {"cpu": "3", "memory": "5Gi"}, "limits": {"memory": "6Gi"}},
                 "containers": [{"name": "runner"}],
                 "initContainers": [{"name": "dind", "restartPolicy": "Always"}]},
        "status": {"phase": "Running" if scheduled else "Pending",
                   "conditions": [{"type": "Ready", "status": "True" if scheduled else "False"}]},
    }
    if scheduled:
        pod["spec"]["nodeName"] = runner["node"]
    return pod


def history_document(entries):
    return [{"revision": h["revision"], "updated": "2026-10-20 09:12:44 +0000 UTC", "status": h["status"],
             "chart": h.get("chart", "gha-runner-scale-set-0.14.2"), "app_version": "0.14.2",
             "description": "fixture"} for h in entries]


def write_world(directory, world):
    burst_names = {node["name"] for node in world["burst_nodes"]}
    nodes = list(world["base_nodes"]) + [burst_node_document(world, n) for n in world["burst_nodes"]]
    save(directory, "nodes.json", {"apiVersion": "v1", "kind": "List", "items": nodes})
    known = {n["metadata"]["name"] for n in world["base_nodes"]} | burst_names
    base_pods = [pod for pod in world["base_pods"] if (pod.get("spec") or {}).get("nodeName") in known]
    runner_pods = [runner_pod(r) for r in world["runners"]]
    save(directory, "pods.json", {"apiVersion": "v1", "kind": "List", "items": base_pods + runner_pods})
    save(directory, "runner-pods.json", {"apiVersion": "v1", "kind": "List", "items": runner_pods})
    runners = []
    for runner in world["runners"]:
        status = {"phase": "Running", "runnerName": runner["name"]}
        if runner["busy"]:
            status.update({"jobRequestId": 4242, "jobRepositoryName": "redducklabs/aurolegal.ai"})
        runners.append({"apiVersion": "actions.github.com/v1alpha1", "kind": "EphemeralRunner",
                        "metadata": {"name": runner["name"], "namespace": "arc-runners",
                                     "creationTimestamp": iso(runner["created"])},
                        "status": status})
    save(directory, "ephemeralrunners.json", {"apiVersion": "actions.github.com/v1alpha1", "items": runners})
    github = [{"id": 1000 + i, "name": r["name"], "status": "online", "busy": r["busy"]}
              for i, r in enumerate(world["runners"])]
    save(directory, "gh-runners.json", {"total_count": len(github), "runners": github})
    save(directory, "gh-runners-slurp.json", [{"total_count": len(github), "runners": github}])
    pools = json.loads(json.dumps(world["base_pools"]))
    for pool in pools:
        if pool.get("name") in BURST:
            members = [n for n in world["burst_nodes"] if n["pool"] == pool["name"]]
            pool["count"] = len(members)
            pool["nodes"] = [{"id": n["name"], "name": n["name"], "status": {"state": "running"},
                              "droplet_id": f"burst-{n['name']}"} for n in members]
    save(directory, "pools.json", pools)
    for name in ("helm-values.json", "helm-manifest.yaml", "asrs.json"):
        shutil.copyfile(os.path.join(LAYERS, world["arc"], name), p(directory, name))
    save(directory, "history.json", history_document(world["history"]))
    save(directory, "fleet.json", world)


# --------------------------------------------------------------------------
# World dynamics
# --------------------------------------------------------------------------

def free_on(world, node_name):
    return 2 - sum(1 for r in world["runners"] if r["node"] == node_name)


def place(world, directory):
    """Placement for a new or Pending runner; "" means it stays Pending."""
    baseline = [n["metadata"]["name"] for n in world["base_nodes"]
                if (n["metadata"].get("labels") or {}).get(POOL_LABEL) == BASELINE]
    for name in baseline:
        if free_on(world, name) > 0:
            return name
    if world["arc"] in ("arc-drain", "arc-drain-stopped"):
        return ""
    for node in world["burst_nodes"]:
        if free_on(world, node["name"]) > 0:
            return node["name"]
    if not world["knobs"].get("burst_capacity", True):
        return ""
    pools = {pool["name"]: pool for pool in world["base_pools"]}
    for pool_name in BURST:
        pool = pools.get(pool_name)
        if pool is None:
            continue
        members = sum(1 for n in world["burst_nodes"] if n["pool"] == pool_name)
        if members < (pool.get("max_nodes") or 0):
            world["seq"] += 1
            node = {"name": f"{pool_name}-n{world['seq']}", "pool": pool_name,
                    "created": now(directory), "empty_ticks": 0}
            world["burst_nodes"].append(node)
            return node["name"]
    return ""


def reconcile(world, directory):
    clock = now(directory)
    busy_until = world["knobs"].get("busy_until")
    if busy_until is not None and clock >= busy_until:
        world["runners"] = [r for r in world["runners"] if not r["busy"]]
    for node in list(world["burst_nodes"]):
        if any(r["node"] == node["name"] for r in world["runners"]):
            node["empty_ticks"] = 0
            continue
        node["empty_ticks"] += 1
        if node["empty_ticks"] >= 2:
            world["burst_nodes"].remove(node)
    minimum, maximum = ARC_BOUNDS[world["arc"]]
    busy = sum(1 for r in world["runners"] if r["busy"])
    desired = min(max(minimum, busy), maximum)
    surplus = len(world["runners"]) - desired
    if surplus > 0:
        burst_first = world["knobs"].get("surplus", "burst-first") == "burst-first"

        def order(runner):
            on_burst = node_pool(world, runner["node"]) in BURST
            return (0 if on_burst == burst_first else 1, -runner["created"])
        for runner in sorted([r for r in world["runners"] if not r["busy"]], key=order)[:surplus]:
            world["runners"].remove(runner)
    for runner in world["runners"]:
        if not runner["node"]:
            runner["node"] = place(world, directory)
    while len(world["runners"]) < desired:
        world["seq"] += 1
        runner = {"name": f"{PREFIX}r{world['seq']}", "node": "", "busy": False, "created": clock}
        world["runners"].append(runner)
        runner["node"] = place(world, directory)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def option(args, name):
    return args[args.index(name) + 1] if name in args else None


def post_render(directory, args, template_name):
    renderer = option(args, "--post-renderer")
    if renderer is None:
        print("fake helm: rendering upgrade without the hash post-renderer", file=sys.stderr)
        return False
    with open(p(directory, template_name), "rb") as stream:
        completed = subprocess.run([renderer], stdin=stream, capture_output=True, check=False)
    sys.stderr.write(completed.stderr.decode())
    return completed.returncode == 0


def finish_write(directory, world, token, apply):
    knobs = world["knobs"]
    if knobs.get("fail_helm") == token:
        print(f"fake helm: injected failure for {token}", file=sys.stderr)
        log(directory, f"{token}:failed")
        return 1
    apply()
    world["helm_writes"] = world.get("helm_writes", 0) + 1
    log(directory, token)
    write_world(directory, world)
    if knobs.get("cancel_after") == token:
        open(p(directory, "cancel-requested"), "w").close()
        return 143
    return 0


def new_revision(world, arc, history_max):
    for entry in world["history"]:
        if entry["status"] == "deployed":
            entry["status"] = "superseded"
    revision = max([h["revision"] for h in world["history"]] or [0]) + 1
    world["history"].append({"revision": revision, "arc": arc, "status": "deployed"})
    world["arc"] = arc
    # Helm's release storage keeps at most history_max revisions, dropping the oldest.
    world["history"].sort(key=lambda h: h["revision"])
    while len(world["history"]) > history_max:
        world["history"].pop(0)


def history_max_of(args):
    value = option(args, "--history-max")
    return int(value) if value is not None else HELM_DEFAULT_HISTORY_MAX


def stop(world, history_max):
    new_revision(world, STOP_LAYER[world["arc"]], history_max)
    # maxRunners=0: ARC deletes every idle runner; a busy one finishes its job first.
    world["runners"] = [r for r in world["runners"] if r["busy"]]


def write_token(args):
    """The mutation token a Helm write would log, before it is applied."""
    if args[:2] == ["rollback", "redducklabs-runners"]:
        return f"helm-rollback:{args[2]}"
    if args[:2] != ["upgrade", "redducklabs-runners"]:
        return None
    if "--reuse-values" in args and "maxRunners=0" in args:
        return "helm-upgrade:stopped"
    if "--reuse-values" in args:
        values = [a for a in args if a.startswith("minRunners=")]
        return f"helm-upgrade:min={values[0][11:]}" if len(values) == 1 else None
    if option(args, "--values") == "deploy/dind-values.yaml":
        return "helm-upgrade:burst"
    if option(args, "--values") == DENSITY_VALUES:
        return "helm-upgrade:density"
    return "helm-upgrade:drain" if option(args, "-f") else None


def marker_document(marker):
    return {"apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": STOP_MARKER, "namespace": "arc-runners", "uid": marker["uid"],
                         "resourceVersion": str(marker["resourceVersion"])},
            "data": dict(marker["data"])}


def set_marker(world, data):
    """Emergency Stop's marker write (an update keeps the uid, bumps the resourceVersion)."""
    world["rv"] = world.get("rv", 100) + 1
    marker = world.get("stop_marker")
    uid = marker["uid"] if marker else f"stop-marker-uid-{world['rv']}"
    world["stop_marker"] = {"uid": uid, "resourceVersion": world["rv"], "data": data}


def inject_stop(directory, world):
    """knobs.stop_before: a complete Emergency Stop (marker, then 0/0) that lands
    after the run's final admission and immediately before its Helm write."""
    set_marker(world, {"run-id": "injected", "time": "2026-10-27T00:00:00Z"})
    log(directory, "injected-stop-marker")
    stop(world, 100)
    log(directory, "injected-stop")
    world["injected"] = True
    write_world(directory, world)


def helm(directory, world, args):
    token = write_token(args)
    if token is not None and token != "helm-upgrade:stopped" and world["knobs"].get("stop_before") == token \
            and not world.get("injected"):
        inject_stop(directory, world)
    if args[:2] == ["upgrade", "redducklabs-runners"]:
        history_max = history_max_of(args)
        if "--reuse-values" in args and "maxRunners=0" in args:
            if "minRunners=0" not in args or option(args, "--version") != "0.14.2" \
                    or world["arc"] not in STOP_LAYER:
                print(f"fake helm: unexpected stop upgrade from {world['arc']}: {args}", file=sys.stderr)
                return 1
            return finish_write(directory, world, "helm-upgrade:stopped", lambda: stop(world, history_max))
        if "--reuse-values" in args:
            values = [a for a in args if a.startswith("minRunners=")]
            if len(values) != 1 or values[0][11:] not in MIN_LAYER or world["arc"] not in BURST_FAMILY \
                    or option(args, "--version") != "0.14.2" or "--wait" in args:
                print(f"fake helm: unexpected reuse-values upgrade from {world['arc']}: {args}", file=sys.stderr)
                return 1
            target = MIN_LAYER[values[0][11:]]
            return finish_write(directory, world, f"helm-upgrade:min={values[0][11:]}",
                                lambda: new_revision(world, target, history_max))
        if option(args, "--values") == "deploy/dind-values.yaml":
            if not post_render(directory, args, "template-burst.yaml"):
                return 1
            return finish_write(directory, world, "helm-upgrade:burst",
                                lambda: new_revision(world, "arc-burst", history_max))
        if option(args, "--values") == DENSITY_VALUES:
            # Ruling 34: rollback upgrades to the committed density values.
            if world["arc"] not in ("arc-drain", "arc-drain-stopped", "arc-density-stopped") \
                    or option(args, "--version") != "0.14.2":
                print(f"fake helm: unexpected density upgrade from {world['arc']}: {args}", file=sys.stderr)
                return 1
            if not post_render(directory, args, "template-density.yaml"):
                return 1
            return finish_write(directory, world, "helm-upgrade:density",
                                lambda: new_revision(world, "arc-density", history_max))
        drain_file = option(args, "-f")
        if drain_file:
            with open(drain_file, encoding="utf-8") as stream:
                values = yaml.safe_load(stream)
            affinity = values["template"]["spec"].get("affinity", {}).get("nodeAffinity", {})
            if values.get("maxRunners") != 4 or "requiredDuringSchedulingIgnoredDuringExecution" not in affinity:
                print("fake helm: the -f file is not the drain values", file=sys.stderr)
                return 1
            if not post_render(directory, args, "template-drain.yaml"):
                return 1
            return finish_write(directory, world, "helm-upgrade:drain",
                                lambda: new_revision(world, "arc-drain", history_max))
        print(f"fake helm: unexpected upgrade: {args}", file=sys.stderr)
        return 1
    if args[:2] == ["rollback", "redducklabs-runners"]:
        revision = int(args[2])
        target = [h for h in world["history"] if h["revision"] == revision]
        if len(target) != 1:
            return 1
        return finish_write(directory, world, f"helm-rollback:{revision}",
                            lambda: new_revision(world, target[0]["arc"], history_max_of(args)))
    if args[:3] == ["history", "redducklabs-runners", "-n"]:
        threshold = world["knobs"].get("prune_on_history_read")
        if threshold is None:
            return NOT_HANDLED
        world["history_reads"] = world.get("history_reads", 0) + 1
        save(directory, "fleet.json", world)
        entries = world["history"]
        if world["history_reads"] >= threshold:
            entries = [h for h in entries if h["status"] != "deployed"]
        print(json.dumps(history_document(entries)))
        return 0
    if args[:1] == ["template"]:
        name = {"deploy/dind-values.yaml": "template-burst.yaml",
                DENSITY_VALUES: "template-density.yaml"}.get(option(args, "--values"), "template-drain.yaml")
        with open(p(directory, name), encoding="utf-8") as stream:
            sys.stdout.write(stream.read())
        return 0
    if args[:2] in (["get", "values"], ["get", "manifest"]) and "--revision" in args:
        revision = int(option(args, "--revision"))
        target = [h for h in world["history"] if h["revision"] == revision]
        if len(target) != 1:
            print("fake helm: revision not found", file=sys.stderr)
            return 1
        name = "helm-values.json" if args[1] == "values" else "helm-manifest.yaml"
        with open(os.path.join(LAYERS, target[0]["arc"], name), encoding="utf-8") as stream:
            sys.stdout.write(stream.read())
        return 0
    if args[:1] == ["status"]:
        print("STATUS: fixture")
        return 0
    return NOT_HANDLED


def network_policy(directory, world, args, document):
    """Server-side dry run and apply of deploy/runner-network-policy.yaml."""
    knobs = world["knobs"]
    if "--server-side" not in args:
        print("fake kubectl: the network policy must be applied server-side", file=sys.stderr)
        return 1
    if "--dry-run=server" in args:
        if knobs.get("netpol_dry_run") == "fail":
            print("fake kubectl: injected server dry-run failure for the network policy", file=sys.stderr)
            return 1
        returned = json.loads(json.dumps(document))
        returned["metadata"].update(uid="netpol-dry-run-uid", generation=1, resourceVersion="0")
        if knobs.get("netpol_dry_run") == "defaulted":
            # The server would add a field the committed file does not carry.
            returned["spec"]["egress"][0]["ports"][0]["endPort"] = 53
        if option(args, "-o") != "json":
            print("fake kubectl: the network policy dry run must print the object (-o json)", file=sys.stderr)
            return 1
        print(json.dumps(returned))
        return 0
    applied = json.loads(json.dumps(document))
    if knobs.get("netpol_apply") == "drift":
        applied["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "10.124.0.0/20"}}]})
    policies = load(directory, "networkpolicies.json")
    name = applied["metadata"]["name"]
    policies["items"] = [item for item in policies["items"] if item["metadata"]["name"] != name] + [applied]
    save(directory, "networkpolicies.json", policies)
    log(directory, "apply-netpol")
    print("networkpolicy.networking.k8s.io/redducklabs-runner-isolation serverside-applied")
    return 0


def stop_marker_command(directory, world, args):
    """The Emergency Stop marker ConfigMap (Ruling 33): read, write, guarded delete."""
    knobs = world["knobs"]
    marker = world.get("stop_marker")
    if args[:3] == ["get", "configmap", STOP_MARKER]:
        if args[3:] != ["-n", "arc-runners", "--ignore-not-found", "-o", "json"]:
            print(f"fake kubectl: unexpected marker read {args}", file=sys.stderr)
            return 1
        if knobs.get("marker_read") == "fail" or (
                knobs.get("marker_read") == "fail-after-write" and world.get("helm_writes", 0) > 0):
            print("fake kubectl: injected marker read failure", file=sys.stderr)
            return 1
        if marker:
            print(json.dumps(marker_document(marker)))
        return 0
    if args[:1] == ["apply"] and option(args, "-f") == "-":
        document = json.loads(sys.stdin.read())
        if document.get("kind") != "ConfigMap" or document["metadata"].get("name") != STOP_MARKER \
                or "--server-side" not in args:
            print(f"fake kubectl: unexpected apply from stdin {args}", file=sys.stderr)
            return 1
        if knobs.get("marker_write") == "fail":
            print("fake kubectl: injected marker write failure", file=sys.stderr)
            return 1
        set_marker(world, document.get("data") or {})
        log(directory, "stop-marker:set")
        write_world(directory, world)
        print(f"configmap/{STOP_MARKER} serverside-applied")
        return 0
    if args[:2] == ["delete", "--raw"] and args[2] == f"/api/v1/namespaces/arc-runners/configmaps/{STOP_MARKER}":
        with open(option(args, "-f"), encoding="utf-8") as stream:
            preconditions = json.load(stream).get("preconditions") or {}
        if knobs.get("marker_bump_before_delete") and marker:
            # A newer Emergency Stop rewrote the marker after this run read it.
            set_marker(world, {"run-id": "newer", "time": "2026-10-27T00:00:01Z"})
            marker = world["stop_marker"]
            write_world(directory, world)
        if not marker:
            print("Error from server (NotFound): configmaps not found", file=sys.stderr)
            return 1
        if preconditions != {"uid": marker["uid"], "resourceVersion": str(marker["resourceVersion"])}:
            print("Error from server (Conflict): Precondition failed", file=sys.stderr)
            return 1
        world["stop_marker"] = None
        log(directory, "stop-marker:delete")
        write_world(directory, world)
        return 0
    return NOT_HANDLED


def kubectl(directory, world, args):
    handled = stop_marker_command(directory, world, args)
    if handled != NOT_HANDLED:
        return handled
    if args[:1] == ["apply"] and option(args, "-f") == "deploy/runner-network-policy.yaml":
        with open(option(args, "-f"), encoding="utf-8") as stream:
            return network_policy(directory, world, args, yaml.safe_load(stream))
    if args[:1] == ["apply"] and "--dry-run=server" in args:
        with open(option(args, "-f"), encoding="utf-8") as stream:
            document = yaml.safe_load(stream)
        mutation = world["knobs"].get("admission", "none")
        if mutation != "none":
            if document.get("kind") == "Pod":
                annotations = document.setdefault("metadata", {}).setdefault("annotations", {})
            else:
                annotations = document["spec"]["template"].setdefault("metadata", {}).setdefault("annotations", {})
            if mutation == "drop-annotation":
                annotations.pop(SAFE_TO_EVICT, None)
            elif mutation == "annotation-true":
                annotations[SAFE_TO_EVICT] = "true"
        print(json.dumps(document))
        return 0
    if args[:2] == ["delete", "ephemeralrunner"]:
        name = args[4]
        runner = [r for r in world["runners"] if r["name"] == name]
        if len(runner) != 1:
            print(f"fake kubectl: ephemeralrunner {name} not found", file=sys.stderr)
            return 1
        if not runner[0]["busy"]:
            world["runners"].remove(runner[0])
        log(directory, "delete-er:" + name[len(PREFIX):])
        write_world(directory, world)
        print(f"ephemeralrunner.actions.github.com \"{name}\" deleted")
        return 0
    if args[:1] in (["apply"], ["delete"], ["patch"], ["create"], ["scale"]):
        log(directory, "unexpected-kubectl:" + " ".join(args))
        print(f"fake kubectl: unexpected mutation {args}", file=sys.stderr)
        return 1
    return NOT_HANDLED


def init(directory, scenario):
    nodes = load(directory, "nodes.json")["items"]
    pods = load(directory, "pods.json")["items"]
    pools = load(directory, "pools.json")
    base_nodes = [n for n in nodes if (n["metadata"].get("labels") or {}).get(POOL_LABEL) not in BURST]
    template = next(n for n in nodes if (n["metadata"].get("labels") or {}).get(POOL_LABEL) == BASELINE)
    pool_ids = {pool["name"]: pool.get("id") for pool in pools}
    baseline = sorted(n["metadata"]["name"] for n in base_nodes
                      if (n["metadata"].get("labels") or {}).get(POOL_LABEL) == BASELINE)
    world = {
        "arc": scenario["arc"],
        # Default history: a recorded density revision 12 (the rollback target
        # Deploy `drain` requires), then the scenario's ARC state at 14.
        "history": scenario.get("history") or (
            [{"revision": 12, "arc": "arc-density", "status": "superseded"}] if scenario["arc"] != "arc-density" else []
        ) + [{"revision": 14, "arc": scenario["arc"], "status": "deployed"}],
        "knobs": scenario.get("knobs") or {},
        "seq": 0,
        "base_nodes": base_nodes,
        "node_template": template,
        "pool_ids": pool_ids,
        "base_pods": [pod for pod in pods
                      if (pod.get("metadata") or {}).get("namespace") != "arc-runners"],
        "base_pools": [dict(pool, count=0, nodes=[]) if pool.get("name") in BURST else pool for pool in pools],
        "burst_nodes": [],
        "runners": [],
    }
    clock = now(directory)
    for spec in scenario.get("burst_nodes", []):
        world["burst_nodes"].append({"name": spec["name"], "pool": spec["pool"], "created": clock - 3600,
                                     "empty_ticks": 0})
    for index, spec in enumerate(scenario.get("runners", [])):
        node = spec["node"]
        if node in ("baseline-a", "baseline-b"):
            node = baseline[0 if node == "baseline-a" else 1]
        world["runners"].append({"name": PREFIX + spec["name"], "node": node, "busy": spec.get("busy", False),
                                 "created": clock - 3600 + index})
    shutil.copyfile(os.path.join(LAYERS, "arc-burst", "helm-manifest.yaml"), p(directory, "template-burst.yaml"))
    shutil.copyfile(os.path.join(LAYERS, "arc-drain", "helm-manifest.yaml"), p(directory, "template-drain.yaml"))
    shutil.copyfile(os.path.join(LAYERS, "arc-density", "helm-manifest.yaml"), p(directory, "template-density.yaml"))
    if scenario.get("stop_marker"):
        set_marker(world, scenario["stop_marker"])
    write_world(directory, world)
    return 0


def main():
    directory, tool, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if tool == "init":
        return init(directory, json.loads(args[0]))
    world = load(directory, "fleet.json")
    if tool == "sleep":
        target = now(directory) + int(float(args[0]) * world["knobs"].get("sleep_scale", 1))
        with open(p(directory, "clock"), "w", encoding="utf-8") as stream:
            stream.write(f"{target}\n")
        reconcile(world, directory)
        write_world(directory, world)
        return 0
    if tool == "helm":
        return helm(directory, world, args)
    if tool == "kubectl":
        return kubectl(directory, world, args)
    return NOT_HANDLED


if __name__ == "__main__":
    raise SystemExit(main())
