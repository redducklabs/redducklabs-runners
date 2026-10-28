#!/usr/bin/env python3
"""Stateful DigitalOcean/Kubernetes fake for test/verify-burst-autoscaling.sh.

with_fakes calls this hook from every fake doctl/kubectl invocation when the
fixture directory holds a "stateful" marker file:

    stateful_provider.py <fixture-dir> <tool> <args...>

The hook first applies scheduled events, then handles the mutating calls that
scripts/burst-pools.sh issues by rewriting the fixture files the read routes
serve (cluster.json, pools.json, expander-configmap.json), so the next read
returns the mutated state. Exit 100 means "not handled here": the fake falls
through to its routes. The only read handled here is the priority-expander
ConfigMap's (see "DOKS ConfigMap model" below); a present ConfigMap is still
served by the routes.

DOKS ConfigMap model (Ruling 40): DOKS creates
kube-system/cluster-autoscaler-priority-expander only after the priority
expander is enabled on the cluster. burst_dir removes expander-configmap.json
when the scenario's cluster expanders lack "priority" (unless the scenario
holds "configmap-preexisting"). While the file is absent a read fails with
kubectl's NotFound error (or prints nothing with --ignore-not-found) and a
patch fails with NotFound. A cluster update whose expanders include
"priority" schedules the starter ConfigMap (the doks labels, "1: [.*]"): it
appears on the first read after "expander-configmap.pending" reaches 0.

Events ("<fixture-dir>/events"): one per line,
    <tool>|<glob over the joined arguments>|<n>|<target file>|<jq patch file>
Before the n-th call that matches, the jq patch (path relative to the fixture
dir) is applied to the target file. Counts live in "<fixture-dir>/events.count".

Flags (files in the fixture dir):
    reject-scale-to-zero     node-pool create with min/max/count 0 fails (422)
    configmap-patch-ignored  kubectl patch of the expander ConfigMap succeeds
                             but changes nothing (readback mismatch)
    reject-create-droplet-limit  node-pool create fails with a 422 droplet-limit
                             error that mentions "account" and "count"
    reset-maintenance-window cluster update moves the maintenance window to
                             any=00:00 whatever --maintenance-window says
    configmap-appear-after   holds N: after the expander update, N ConfigMap
                             reads still see NotFound before it appears
    configmap-never-created  the expander update never creates the ConfigMap
    configmap-read-error     every ConfigMap read fails with a Forbidden error

cluster update requires --update-kubeconfig=false and, like doctl, always
sets the maintenance window (any=00:00 when the flag is omitted).
"""

import fnmatch
import json
import os
import subprocess
import sys

NOT_HANDLED = 100
POOL_IDS = {
    "github-runners-burst-amd-16g": "3e9d7b20-8c4f-4d1a-a6e5-71f2c0b9d802",
    "github-runners-burst-intel-16g": "9a4b2c6d-1e3f-4a5b-8c7d-0e1f2a3b4c03",
}
CLUSTER_TAG = "k8s:c4e1f0a2-6b3d-4f58-9a07-1d2e3f4a5b60"
CONFIGMAP = "cluster-autoscaler-priority-expander"
CONFIGMAP_FILE = "expander-configmap.json"
CONFIGMAP_PENDING = "expander-configmap.pending"
# What DOKS creates (DigitalOcean "Autoscale" how-to, priority expander).
STARTER_CONFIGMAP = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": CONFIGMAP,
        "namespace": "kube-system",
        "labels": {
            "c3.doks.digitalocean.com/component": "cluster-autoscaler",
            "c3.doks.digitalocean.com/plane": "data",
            "doks.digitalocean.com/managed": "true",
        },
    },
    "data": {"priorities": "1:\n  - .*\n"},
}


def path(directory, name):
    return os.path.join(directory, name)


def load(directory, name):
    with open(path(directory, name), encoding="utf-8") as stream:
        return json.load(stream)


def save(directory, name, document):
    with open(path(directory, name), "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2)
        stream.write("\n")


def apply_events(directory, tool, joined):
    events_file = path(directory, "events")
    if not os.path.isfile(events_file):
        return
    counts_file = path(directory, "events.count")
    counts = {}
    if os.path.isfile(counts_file):
        with open(counts_file, encoding="utf-8") as stream:
            counts = json.load(stream)
    with open(events_file, encoding="utf-8") as stream:
        lines = [line.rstrip("\n") for line in stream if line.strip()]
    for index, line in enumerate(lines):
        event_tool, glob, nth, target, patch = line.split("|")
        if event_tool != tool or not fnmatch.fnmatchcase(joined, glob):
            continue
        key = str(index)
        counts[key] = counts.get(key, 0) + 1
        if counts[key] != int(nth):
            continue
        patched = subprocess.run(
            ["jq", "-f", path(directory, patch), path(directory, target)],
            capture_output=True, text=True, check=True,
        ).stdout
        with open(path(directory, target), "w", encoding="utf-8") as stream:
            stream.write(patched)
    with open(counts_file, "w", encoding="utf-8") as stream:
        json.dump(counts, stream)


def parse_flags(args):
    """Parse --flag value / --flag=value / bare --flag into (positionals, flags)."""
    positionals, flags = [], {}
    index = 0
    while index < len(args):
        arg = args[index]
        if arg.startswith("--"):
            name, eq, value = arg[2:].partition("=")
            if not eq:
                if name in ("auto-scale", "force") or index + 1 >= len(args):
                    value = "true"
                else:
                    index += 1
                    value = args[index]
            flags.setdefault(name, []).append(value)
        else:
            positionals.append(arg)
        index += 1
    return positionals, flags


def parse_taint(text):
    key_value, _, effect = text.rpartition(":")
    key, _, value = key_value.partition("=")
    return {"key": key, "value": value, "effect": effect}


def find_pool(pools, reference):
    matches = [p for p in pools if reference in (p.get("id"), p.get("name"))]
    return matches[0] if len(matches) == 1 else None


def doctl(directory, args):
    if args[:4] == ["kubernetes", "cluster", "node-pool", "create"]:
        positionals, flags = parse_flags(args[4:])
        name = flags["name"][-1]
        minimum = int(flags.get("min-nodes", ["0"])[-1])
        maximum = int(flags.get("max-nodes", ["0"])[-1])
        count = int(flags["count"][-1])
        if os.path.isfile(path(directory, "reject-scale-to-zero")) and 0 in (minimum, maximum, count):
            print(
                "Error: POST https://api.digitalocean.com/v2/kubernetes/clusters/"
                f"{positionals[0]}/node_pools: 422 (request \"fixture\") "
                "validation error: min_nodes must be greater than 0",
                file=sys.stderr,
            )
            return 1
        if os.path.isfile(path(directory, "reject-create-droplet-limit")):
            print(
                "Error: POST https://api.digitalocean.com/v2/kubernetes/clusters/"
                f"{positionals[0]}/node_pools: 422 (request \"fixture\") "
                "creating this node pool would exceed your account's droplet limit (node count)",
                file=sys.stderr,
            )
            return 1
        pools = load(directory, "pools.json")
        if find_pool(pools, name) is not None:
            print(f"Error: node pool {name} already exists", file=sys.stderr)
            return 1
        pools.append({
            "id": POOL_IDS.get(name, f"fixture-{name}"),
            "name": name,
            "size": flags["size"][-1],
            "count": count,
            "tags": ["k8s", CLUSTER_TAG, "k8s:worker"],
            "labels": dict(label.split("=", 1) for label in flags.get("label", [])),
            "taints": [parse_taint(t) for t in flags.get("taint", [])],
            "auto_scale": flags.get("auto-scale", ["false"])[-1] == "true",
            "min_nodes": minimum,
            "max_nodes": maximum,
            "nodes": [],
        })
        save(directory, "pools.json", pools)
        print(f"created node pool {name}")
        return 0
    if args[:4] == ["kubernetes", "cluster", "node-pool", "update"]:
        positionals, flags = parse_flags(args[4:])
        pools = load(directory, "pools.json")
        pool = find_pool(pools, positionals[1])
        if pool is None:
            print(f"Error: node pool {positionals[1]} not found", file=sys.stderr)
            return 1
        if "min-nodes" in flags:
            pool["min_nodes"] = int(flags["min-nodes"][-1])
        if "max-nodes" in flags:
            pool["max_nodes"] = int(flags["max-nodes"][-1])
        if "auto-scale" in flags:
            pool["auto_scale"] = flags["auto-scale"][-1] == "true"
        # doctl replaces labels and taints with exactly the flags given.
        pool["labels"] = dict(label.split("=", 1) for label in flags.get("label", []))
        pool["taints"] = [parse_taint(t) for t in flags.get("taint", [])]
        save(directory, "pools.json", pools)
        print(f"updated node pool {pool['name']}")
        return 0
    if args[:4] == ["kubernetes", "cluster", "node-pool", "delete"]:
        positionals, flags = parse_flags(args[4:])
        pools = load(directory, "pools.json")
        pool = find_pool(pools, positionals[1])
        if pool is None or flags.get("force") != ["true"]:
            print(f"Error: cannot delete node pool {positionals[1]}", file=sys.stderr)
            return 1
        save(directory, "pools.json", [p for p in pools if p is not pool])
        print(f"deleted node pool {pool['name']}")
        return 0
    if args[:3] == ["kubernetes", "cluster", "update"]:
        positionals, flags = parse_flags(args[3:])
        if "expanders" not in flags or not set(flags) <= {
            "expanders", "maintenance-window", "update-kubeconfig", "surge-upgrade",
        }:
            return NOT_HANDLED
        if flags.get("update-kubeconfig") != ["false"]:
            print("fake doctl: cluster update without --update-kubeconfig=false would rewrite kubeconfig",
                  file=sys.stderr)
            return 1
        clusters = load(directory, "cluster.json")
        matches = [c for c in clusters if positionals[0] in (c.get("id"), c.get("name"))]
        if len(matches) != 1:
            print(f"Error: cluster {positionals[0]} not found", file=sys.stderr)
            return 1
        cluster = matches[0]
        expanders = [e for e in flags["expanders"][-1].split(",") if e]
        configuration = cluster.setdefault("cluster_autoscaler_configuration", {})
        if expanders:
            configuration["expanders"] = expanders
        else:
            configuration.pop("expanders", None)
        if ("priority" in expanders and not os.path.isfile(path(directory, CONFIGMAP_FILE))
                and not os.path.isfile(path(directory, CONFIGMAP_PENDING))
                and not os.path.isfile(path(directory, "configmap-never-created"))):
            delay = "0"
            if os.path.isfile(path(directory, "configmap-appear-after")):
                with open(path(directory, "configmap-appear-after"), encoding="utf-8") as stream:
                    delay = stream.read().strip()
            with open(path(directory, CONFIGMAP_PENDING), "w", encoding="utf-8") as stream:
                stream.write(f"{int(delay)}\n")
        # Like doctl, always send a maintenance window: the flag's default is
        # any=00:00, so omitting it moves the window.
        day, _, start = flags.get("maintenance-window", ["any=00:00"])[-1].partition("=")
        if os.path.isfile(path(directory, "reset-maintenance-window")):
            day, start = "any", "00:00"
        policy = cluster.setdefault("maintenance_policy", {"duration": "4h0m0s"})
        policy["day"], policy["start_time"] = day, start
        if "surge-upgrade" in flags:
            cluster["surge_upgrade"] = flags["surge-upgrade"][-1] == "true"
        save(directory, "cluster.json", clusters)
        print("cluster updated")
        return 0
    return NOT_HANDLED


def configmap_present(directory):
    """Materializes a scheduled starter ConfigMap when its delay has run out."""
    if os.path.isfile(path(directory, CONFIGMAP_FILE)):
        return True
    pending = path(directory, CONFIGMAP_PENDING)
    if not os.path.isfile(pending):
        return False
    with open(pending, encoding="utf-8") as stream:
        remaining = int(stream.read().strip())
    if remaining > 0:
        with open(pending, "w", encoding="utf-8") as stream:
            stream.write(f"{remaining - 1}\n")
        return False
    save(directory, CONFIGMAP_FILE, STARTER_CONFIGMAP)
    os.remove(pending)
    return True


def not_found():
    print(f'Error from server (NotFound): configmaps "{CONFIGMAP}" not found', file=sys.stderr)
    return 1


def kubectl(directory, args):
    reads = {
        ("get", "configmap", CONFIGMAP, "-n", "kube-system", "-o", "json"): False,
        ("get", "configmap", CONFIGMAP, "-n", "kube-system", "--ignore-not-found", "-o", "json"): True,
    }
    if tuple(args) in reads:
        if os.path.isfile(path(directory, "configmap-read-error")):
            print(f'Error from server (Forbidden): configmaps "{CONFIGMAP}" is forbidden: '
                  'User "fixture" cannot get resource "configmaps" in API group "" in the namespace "kube-system"',
                  file=sys.stderr)
            return 1
        if configmap_present(directory):
            return NOT_HANDLED  # the routes serve expander-configmap.json
        return 0 if reads[tuple(args)] else not_found()
    # Only the exact patch shape burst-pools.sh issues is accepted.
    expected = ["patch", "configmap", CONFIGMAP,
                "-n", "kube-system", "--type", "merge", "-p"]
    if args[:-1] != expected:
        return NOT_HANDLED
    if not configmap_present(directory):
        return not_found()
    patch = json.loads(args[-1])
    if not os.path.isfile(path(directory, "configmap-patch-ignored")):
        configmap = load(directory, "expander-configmap.json")
        configmap.setdefault("data", {}).update(patch.get("data") or {})
        save(directory, "expander-configmap.json", configmap)
    print("configmap/cluster-autoscaler-priority-expander patched")
    return 0


MUTATING_WORDS = {
    "create", "update", "delete", "patch", "apply", "upgrade", "install", "rollback",
    "scale", "uninstall", "annotate", "label", "cordon", "drain", "replace", "edit",
}


def main():
    directory, tool, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    # Ordered mutation log across tools: every attempted mutation, one JSON
    # argv per line, recorded before it is handled (so refused calls count).
    if tool in ("doctl", "kubectl", "helm") and MUTATING_WORDS.intersection(args):
        with open(path(directory, "mutations.log"), "a", encoding="utf-8") as stream:
            stream.write(json.dumps([tool] + args) + "\n")
    apply_events(directory, tool, " ".join(args))
    if tool == "doctl":
        return doctl(directory, args)
    if tool == "kubectl":
        return kubectl(directory, args)
    return NOT_HANDLED


if __name__ == "__main__":
    raise SystemExit(main())
