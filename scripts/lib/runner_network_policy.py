#!/usr/bin/env python3
"""Runner network policy-set validation for scripts/verify-runner-network-policy.sh.

Implements the policy-set rules of the "Runner network isolation" section of
docs/specs/2026-10-26-runner-burst-autoscaling-design.md. Kubernetes and
Cilium policies are additive for allows, so reading back one object does not
establish the boundary; this validates every policy that can apply to runner
pods:

  - NetworkPolicies in arc-runners: exactly one, named
    redducklabs-runner-isolation, whose spec equals the committed file;
  - CiliumNetworkPolicies in arc-runners: none;
  - CiliumClusterwideNetworkPolicies: each deny-only (only egressDeny /
    ingressDeny rules; any egress or ingress allow section fails);
  - a missing Cilium CRD counts as zero objects of that kind; any other API
    error (including the CRD list itself failing) fails;
  - no pod in arc-runners carries doks.digitalocean.com/allow-imds-egress=true;
  - every runner pod in arc-runners carries the policy's selector label
    actions.github.com/scale-set-name=redducklabs-runners (see is_runner_pod).

Read-only: it issues `kubectl get` only and never reads Secrets.
Exit codes: 0 valid, 1 invalid or a read failed, 2 usage error.
"""

import argparse
import json
import pathlib
import subprocess
import sys

import yaml

NAMESPACE = "arc-runners"
POLICY_NAME = "redducklabs-runner-isolation"
DEFAULT_POLICY_FILE = pathlib.Path(__file__).resolve().parent.parent.parent / "deploy" / "runner-network-policy.yaml"
CNP_CRD = "ciliumnetworkpolicies.cilium.io"
CCNP_CRD = "ciliumclusterwidenetworkpolicies.cilium.io"
CRD_PREFIX = "customresourcedefinition.apiextensions.k8s.io/"
IMDS_LABEL = "doks.digitalocean.com/allow-imds-egress"
RELEASE = "redducklabs-runners"
SCALE_SET_LABEL = "actions.github.com/scale-set-name"
SCALE_SET_NAMESPACE_LABEL = "actions.github.com/scale-set-namespace"
COMPONENT_LABEL = "app.kubernetes.io/component"
# Keys a deny-only Cilium rule may carry. Anything else (egress, ingress, or a
# field this validator does not know) fails closed.
DENY_ONLY_KEYS = {"endpointSelector", "nodeSelector", "egressDeny", "ingressDeny", "enableDefaultDeny",
                  "description", "labels"}


class ReadError(Exception):
    """A live read failed or returned something unparseable."""


def run(argv):
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as error:
        raise ReadError(f"could not run {argv[0]}: {error}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip().splitlines()
        hint = f": {detail[0][:200]}" if detail else ""
        raise ReadError(f"'{' '.join(argv[:4])} ...' failed with exit {completed.returncode}{hint}")
    return completed.stdout


def run_items(argv, what):
    text = run(argv)
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise ReadError(f"'{' '.join(argv[:4])} ...' did not return JSON: {error}") from error
    items = document.get("items") if isinstance(document, dict) else None
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ReadError(f"{what} is not a Kubernetes list")
    return items


def name_of(item):
    return (item.get("metadata") or {}).get("name")


def is_runner_pod(pod):
    """An ARC runner pod, recognised without relying on the policy's selector label.

    The pool-state gate counts runner pods by the selector label
    (actions.github.com/scale-set-name), which is the label under test here, so
    a runner pod is also recognised by the other marks ARC 0.14.2 puts on it:
    the scale-set namespace label, the runner component label, an owning
    EphemeralRunner, or the scale set's "<release>-<id>-runner-<suffix>" name.
    """
    metadata = pod.get("metadata") or {}
    labels = metadata.get("labels") or {}
    owners = metadata.get("ownerReferences") or []
    name = str(metadata.get("name") or "")
    return (
        SCALE_SET_LABEL in labels
        or labels.get(SCALE_SET_NAMESPACE_LABEL) == NAMESPACE
        or labels.get(COMPONENT_LABEL) == "runner"
        or any(isinstance(owner, dict) and owner.get("kind") == "EphemeralRunner" for owner in owners)
        or (name.startswith(f"{RELEASE}-") and "-runner-" in name)
    )


def load_policy_file(path):
    try:
        with open(path, encoding="utf-8") as stream:
            document = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as error:
        raise ReadError(f"could not read policy file {path}: {error}") from error
    if not isinstance(document, dict):
        raise ReadError(f"policy file {path} is not a single YAML object")
    metadata = document.get("metadata") or {}
    if (document.get("apiVersion"), document.get("kind")) != ("networking.k8s.io/v1", "NetworkPolicy") \
            or metadata.get("name") != POLICY_NAME or metadata.get("namespace") != NAMESPACE \
            or not isinstance(document.get("spec"), dict):
        raise ReadError(f"policy file {path} is not NetworkPolicy {NAMESPACE}/{POLICY_NAME} with a spec")
    return document


def installed_crds():
    """Names of installed CRDs. A failure of the CRD list itself is an API error."""
    text = run(["kubectl", "get", "crd", "-o", "name"])
    names = set()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith(CRD_PREFIX):
            raise ReadError(f"unexpected CRD list entry '{line[:120]}'")
        names.add(line[len(CRD_PREFIX):])
    return names


def cilium_rules(item):
    """The rule objects of a Cilium policy: `spec` and every entry of `specs`."""
    rules = []
    if "spec" in item:
        rules.append(item["spec"])
    if "specs" in item:
        if not isinstance(item["specs"], list):
            return None
        rules.extend(item["specs"])
    return rules


def clusterwide_errors(items):
    errors = []
    for item in items:
        name = name_of(item)
        rules = cilium_rules(item)
        if not rules:
            errors.append(f"CiliumClusterwideNetworkPolicy '{name}' has no readable spec")
            continue
        for rule in rules:
            if not isinstance(rule, dict):
                errors.append(f"CiliumClusterwideNetworkPolicy '{name}' has a malformed rule")
                continue
            extra = sorted(set(rule) - DENY_ONLY_KEYS)
            if extra:
                errors.append(
                    f"CiliumClusterwideNetworkPolicy '{name}' is not deny-only: it sets {', '.join(extra)}; "
                    "a clusterwide allow can match runner pods"
                )
            elif not (rule.get("egressDeny") or rule.get("ingressDeny")):
                errors.append(f"CiliumClusterwideNetworkPolicy '{name}' has no deny rules")
    return errors


def validate(policy_file):
    """Return the list of violations. Raises ReadError on any read failure."""
    expected = load_policy_file(policy_file)
    crds = installed_crds()
    errors = []

    policies = run_items(
        ["kubectl", "get", "networkpolicies.networking.k8s.io", "-n", NAMESPACE, "-o", "json"],
        "NetworkPolicy list",
    )
    names = sorted(str(name_of(item)) for item in policies)
    if names != [POLICY_NAME]:
        errors.append(
            f"NetworkPolicies in {NAMESPACE} must be exactly ['{POLICY_NAME}']; found {names}"
        )
    for item in policies:
        if name_of(item) == POLICY_NAME and item.get("spec") != expected["spec"]:
            errors.append(f"NetworkPolicy '{POLICY_NAME}' spec differs from {pathlib.Path(policy_file).name}")

    if CNP_CRD in crds:
        cnps = run_items(["kubectl", "get", CNP_CRD, "-n", NAMESPACE, "-o", "json"], "CiliumNetworkPolicy list")
        if cnps:
            errors.append(
                f"CiliumNetworkPolicies in {NAMESPACE} must be none; found {sorted(str(name_of(i)) for i in cnps)}"
            )

    if CCNP_CRD in crds:
        errors += clusterwide_errors(
            run_items(["kubectl", "get", CCNP_CRD, "-o", "json"], "CiliumClusterwideNetworkPolicy list")
        )

    pods = run_items(["kubectl", "get", "pods", "-n", NAMESPACE, "-o", "json"], f"pod list in {NAMESPACE}")
    for pod in pods:
        metadata = pod.get("metadata") or {}
        if metadata.get("namespace", NAMESPACE) != NAMESPACE:
            continue
        labels = metadata.get("labels") or {}
        if labels.get(IMDS_LABEL) == "true":
            errors.append(f"pod '{name_of(pod)}' in {NAMESPACE} is labeled {IMDS_LABEL}=true")
        if is_runner_pod(pod) and labels.get(SCALE_SET_LABEL) != RELEASE:
            errors.append(
                f"runner pod '{name_of(pod)}' in {NAMESPACE} lacks the policy selector label "
                f"{SCALE_SET_LABEL}={RELEASE}, so {POLICY_NAME} does not isolate it"
            )

    return errors, crds


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--policy-file", default=str(DEFAULT_POLICY_FILE))
    try:
        args = parser.parse_args()
    except SystemExit as error:
        return 0 if error.code == 0 else 2
    try:
        errors, crds = validate(args.policy_file)
    except ReadError as error:
        print(f"REJECTED: runner network policy set: {error}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(f"REJECTED: runner network policy set: {error}", file=sys.stderr)
        return 1
    cilium = "installed" if {CNP_CRD, CCNP_CRD} & crds else "absent"
    print(f"NETWORK_POLICY: valid: {NAMESPACE}/{POLICY_NAME} matches the file; Cilium policy CRDs {cilium}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
