#!/usr/bin/env python3
"""Validate explicit legacy-isolated, density, burst, drain and stopped ARC runner contracts."""

import argparse
import json
import sys

import yaml


def common_template(rendered: bool) -> dict:
    template = {
        "imagePullSecrets": [{"name": "do-registry-secret"}],
        "nodeSelector": {"node-type": "github-runner"},
        "tolerations": [
            {
                "effect": "NoSchedule",
                "key": "github-runner",
                "operator": "Equal",
                "value": "true",
            }
        ],
        "initContainers": [
            {
                "args": ["-r", "/home/runner/externals/.", "/home/runner/tmpDir/"],
                "command": ["cp"],
                "image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "name": "init-dind-externals",
                "volumeMounts": [
                    {"mountPath": "/home/runner/tmpDir", "name": "dind-externals"}
                ],
            },
            {
                "args": [
                    "dockerd",
                    "--host=unix:///var/run/docker.sock",
                    "--group=$(DOCKER_GROUP_GID)",
                ],
                "env": [{"name": "DOCKER_GROUP_GID", "value": "123"}],
                "image": "docker:29.7.2-dind",
                "name": "dind",
                "restartPolicy": "Always",
                "securityContext": {"privileged": True},
                "startupProbe": {
                    "exec": {"command": ["docker", "info"]},
                    "failureThreshold": 24,
                    "initialDelaySeconds": 0,
                    "periodSeconds": 5,
                },
                "volumeMounts": [
                    {"mountPath": "/home/runner/_work", "name": "work"},
                    {"mountPath": "/var/run", "name": "dind-sock"},
                    {"mountPath": "/home/runner/externals", "name": "dind-externals"},
                ],
            },
        ],
        "containers": [
            {
                "name": "runner",
                "command": ["/home/runner/run.sh"],
                "image": "registry.digitalocean.com/redducklabs/github-runner:latest",
                "imagePullPolicy": "Always",
                "securityContext": {
                    "allowPrivilegeEscalation": True,
                    "readOnlyRootFilesystem": False,
                    "runAsGroup": 121,
                    "runAsUser": 1001,
                },
                "env": [
                    {"name": "DOCKER_HOST", "value": "unix:///var/run/docker.sock"},
                    {"name": "RUNNER_WAIT_FOR_DOCKER_IN_SECONDS", "value": "120"},
                ],
                "volumeMounts": [
                    {"mountPath": "/home/runner/_work", "name": "work"},
                    {"mountPath": "/var/run", "name": "dind-sock"},
                ],
            }
        ],
        "volumes": [
            {"emptyDir": {}, "name": "work"},
            {"emptyDir": {}, "name": "dind-sock"},
            {"emptyDir": {}, "name": "dind-externals"},
        ],
    }
    if rendered:
        template["restartPolicy"] = "Never"
        template["serviceAccountName"] = "redducklabs-runners-gha-rs-no-permission"
    return template


def density_template(rendered: bool) -> dict:
    template = common_template(rendered)
    template["resources"] = {
        "requests": {"cpu": "3", "memory": "5Gi"},
        "limits": {"memory": "6Gi"},
    }
    template["automountServiceAccountToken"] = False
    return template


BASELINE_POOL_EXPRESSION = {
    "key": "doks.digitalocean.com/node-pool",
    "operator": "In",
    "values": ["github-runners-pool-16g"],
}


# Burst, burst-acceptance and drain pull Docker Hub images through Google's
# public pull-through cache. Density and legacy-isolated do not carry it, so
# recorded revisions of earlier releases still validate as rollback targets.
DOCKER_HUB_MIRROR_FLAG = "--registry-mirror=https://mirror.gcr.io"


# Burst, burst-acceptance and drain carry the actions/setup-* tool cache: one
# plain emptyDir mounted at the same path in the runner and the dind sidecar
# (container jobs bind-mount the tool directory and dockerd resolves bind
# sources in its own filesystem), with RUNNER_TOOL_CACHE and
# AGENT_TOOLSDIRECTORY naming it. Density and legacy-isolated do not, so their
# pods keep the runner default <work>/_tool and recorded releases still match.
TOOL_CACHE_PATH = "/opt/hostedtoolcache"
TOOL_CACHE_VOLUME = "tool-cache"
TOOL_CACHE_ENV = [
    {"name": "RUNNER_TOOL_CACHE", "value": TOOL_CACHE_PATH},
    {"name": "AGENT_TOOLSDIRECTORY", "value": TOOL_CACHE_PATH},
]


def add_tool_cache(template: dict) -> None:
    mount = {"mountPath": TOOL_CACHE_PATH, "name": TOOL_CACHE_VOLUME}
    for container in template["initContainers"]:
        if container["name"] == "dind":
            container["volumeMounts"] = container["volumeMounts"] + [dict(mount)]
    for container in template["containers"]:
        if container["name"] == "runner":
            container["env"] = container["env"] + [dict(item) for item in TOOL_CACHE_ENV]
            container["volumeMounts"] = container["volumeMounts"] + [dict(mount)]
    template["volumes"] = template["volumes"] + [
        {"emptyDir": {}, "name": TOOL_CACHE_VOLUME}
    ]


def burst_metadata() -> dict:
    return {
        "annotations": {"cluster-autoscaler.kubernetes.io/safe-to-evict": "false"}
    }


def burst_template(rendered: bool) -> dict:
    """Density template plus the Docker Hub mirror, the shared tool cache and a
    preferred (weight 100) baseline-pool affinity."""
    template = density_template(rendered)
    for container in template["initContainers"]:
        if container["name"] == "dind":
            container["args"] = container["args"] + [DOCKER_HUB_MIRROR_FLAG]
    add_tool_cache(template)
    template["affinity"] = {
        "nodeAffinity": {
            "preferredDuringSchedulingIgnoredDuringExecution": [
                {
                    "weight": 100,
                    "preference": {"matchExpressions": [dict(BASELINE_POOL_EXPRESSION)]},
                }
            ]
        }
    }
    return template


def drain_template(rendered: bool) -> dict:
    """Burst template with the baseline affinity made required."""
    template = burst_template(rendered)
    template["affinity"] = {
        "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
                "nodeSelectorTerms": [
                    {"matchExpressions": [dict(BASELINE_POOL_EXPRESSION)]}
                ]
            }
        }
    }
    return template


# contract -> permitted (min, max) runner bounds; all require the private group.
BURST_BOUNDS = {
    "burst": {(2, 20)},
    "burst-acceptance": {(8, 20), (4, 20)},
    "drain": {(2, 4)},
}


# Ruling 26: the stopped state family. Emergency Stop runs
# "helm upgrade --reuse-values --set minRunners=0 --set maxRunners=0", which
# keeps whichever base template the release had. Each stopped contract is that
# base template, exactly, with minRunners=maxRunners=0 and the private group.
STOPPED_BASE = {
    "burst-stopped": "burst",
    "density-stopped": "density",
    "drain-stopped": "drain",
}


def legacy_isolated_template(rendered: bool, private: bool) -> dict:
    template = common_template(rendered)
    by_name = {
        item["name"]: item
        for item in template["containers"] + template["initContainers"]
    }
    by_name["runner"]["resources"] = {
        "requests": {"cpu": "2", "memory": "5Gi"},
        "limits": {"memory": "10Gi"},
    }
    by_name["dind"]["resources"] = {
        "requests": {"cpu": "1", "memory": "5Gi"},
        "limits": {"memory": "10Gi"},
    }
    if private:
        template["automountServiceAccountToken"] = False
    return template


def parse_input(kind: str) -> tuple[dict, bool]:
    if kind == "values":
        data = yaml.safe_load(sys.stdin)
        if not isinstance(data, dict):
            raise ValueError("Helm values must be an object")
        return data, False
    if kind == "manifest":
        documents = [
            item
            for item in yaml.safe_load_all(sys.stdin)
            if isinstance(item, dict) and item.get("kind") == "AutoscalingRunnerSet"
        ]
        if len(documents) != 1:
            raise ValueError("manifest must contain exactly one AutoscalingRunnerSet")
        return documents[0].get("spec", {}), True
    data = json.load(sys.stdin)
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list) or len(items) != 1:
        raise ValueError("live state must contain exactly one AutoscalingRunnerSet")
    return items[0].get("spec", {}), True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--contract",
        choices=("legacy-isolated", "density", "burst", "burst-acceptance", "drain") + tuple(STOPPED_BASE),
        required=True,
    )
    parser.add_argument(
        "--kind", choices=("values", "manifest", "asrs-list"), required=True
    )
    parser.add_argument("--min-runners", type=int, required=True)
    parser.add_argument("--max-runners", type=int, required=True)
    parser.add_argument(
        "--runner-group",
        choices=("default", "private"),
        required=True,
    )
    args = parser.parse_args()

    try:
        state, rendered = parse_input(args.kind)
        if (
            state.get("minRunners") != args.min_runners
            or state.get("maxRunners") != args.max_runners
        ):
            raise ValueError("runner bounds do not match")
        if args.runner_group == "default":
            if state.get("runnerGroup", "Default") != "Default":
                raise ValueError("runner group does not match Default semantics")
        elif state.get("runnerGroup") != "redducklabs-private-runners":
            raise ValueError("runner group does not match")
        private = args.runner_group == "private"
        base = STOPPED_BASE.get(args.contract, args.contract)
        if args.contract in STOPPED_BASE:
            if not private or (args.min_runners, args.max_runners) != (0, 0):
                raise ValueError(f"{args.contract} bounds/group are not permitted")
        elif args.contract in BURST_BOUNDS:
            if not private or (args.min_runners, args.max_runners) not in BURST_BOUNDS[
                args.contract
            ]:
                raise ValueError(f"{args.contract} bounds/group are not permitted")
        elif args.contract == "density":
            if not private or not (
                0 <= args.min_runners <= args.max_runners <= 4 and args.max_runners >= 1
            ):
                raise ValueError("density bounds/group are not permitted")
        elif (args.min_runners, args.max_runners, args.runner_group) not in (
            (2, 8, "default"),
            (2, 2, "private"),
        ):
            raise ValueError("legacy isolation bounds/group are not permitted")
        if rendered:
            if state.get("runnerScaleSetName") != "redducklabs-runners":
                raise ValueError("runner scale-set name does not match")
            if state.get("githubConfigUrl") != "https://github.com/redducklabs":
                raise ValueError("GitHub configuration URL does not match")
            if (
                state.get("githubConfigSecret")
                != "redducklabs-runners-gha-rs-github-secret"
            ):
                raise ValueError("GitHub configuration secret does not match")
        template_metadata = state.get("template", {}).get("metadata")
        expected_metadata = burst_metadata() if base in BURST_BOUNDS else None
        if template_metadata != expected_metadata:
            raise ValueError("template metadata does not match the contract")
        template = state.get("template", {}).get("spec")
        if base in ("burst", "burst-acceptance"):
            expected = burst_template(rendered)
        elif base == "drain":
            expected = drain_template(rendered)
        elif base == "density":
            expected = density_template(rendered)
        else:
            expected = legacy_isolated_template(rendered, private)
        if template != expected:
            raise ValueError("security/resource/placement template is not exact")
    except (
        KeyError,
        TypeError,
        ValueError,
        yaml.YAMLError,
        json.JSONDecodeError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
