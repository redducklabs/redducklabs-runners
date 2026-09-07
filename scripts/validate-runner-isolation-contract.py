#!/usr/bin/env python3
"""Validate the complete private-runner ARC isolation contract."""

import argparse
import json
import sys

import yaml


def expected_template(rendered: bool, require_automount: bool) -> dict:
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
        "resources": {
            "requests": {"cpu": "3", "memory": "5Gi"},
            "limits": {"memory": "6Gi"},
        },
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
    if require_automount:
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
        "--kind", choices=("values", "manifest", "asrs-list"), required=True
    )
    parser.add_argument("--max-runners", type=int, choices=(2, 8), required=True)
    parser.add_argument(
        "--runner-group",
        choices=("Default", "redducklabs-private-runners"),
        required=True,
    )
    parser.add_argument("--require-automount", action="store_true")
    args = parser.parse_args()

    try:
        state, rendered = parse_input(args.kind)
        if state.get("minRunners") != 2 or state.get("maxRunners") != args.max_runners:
            raise ValueError("runner bounds do not match")
        if state.get("runnerGroup", "Default") != args.runner_group:
            raise ValueError("runner group does not match")
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
        template = state.get("template", {}).get("spec")
        expected = expected_template(rendered, args.require_automount)
        if not args.require_automount and isinstance(template, dict):
            if template.get("automountServiceAccountToken") is False:
                expected["automountServiceAccountToken"] = False
            elif "automountServiceAccountToken" in template:
                raise ValueError("legacy automount value is unsafe")
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
