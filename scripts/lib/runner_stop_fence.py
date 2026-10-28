#!/usr/bin/env python3
"""Emergency Stop server-side fence checks (Ruling 36).

The fence is the ValidatingAdmissionPolicy and ValidatingAdmissionPolicyBinding
`runner-fleet-emergency-stop-fence` committed in
deploy/runner-emergency-stop-fence.yaml (see the comments there and the
"Emergency Stop fence" section of
docs/specs/2026-10-26-runner-burst-autoscaling-design.md). This module is used
by the pool-state gate (scripts/lib/runner_pool_state.py imports it), by
Deploy and rollback when they install the fence, and by Emergency Stop.

Read-only: it issues `kubectl get` only.

Usage:
  runner_stop_fence.py verify [--fence-file F] [--require-type-checked]
      The live policy and binding must exist and their specs must equal the
      file. With --require-type-checked the policy's status must also report
      type checking of its current generation without expression warnings.
      Exit 0 exact, 1 absent / different / read failure, 75 type checking of
      the current generation not reported yet (only with
      --require-type-checked; the caller polls).
  runner_stop_fence.py compare-dry-run FILE [--fence-file F]
      FILE is the JSON that `kubectl apply --server-side --dry-run=server -f
      <fence-file> -o json` printed. The objects the server would store must
      carry exactly the file's specs. Exit 0 equal, 1 otherwise.
"""

import argparse
import difflib
import json
import pathlib
import subprocess
import sys

import yaml

NAME = "runner-fleet-emergency-stop-fence"
DEFAULT_FENCE_FILE = pathlib.Path(__file__).resolve().parent.parent.parent / "deploy" / "runner-emergency-stop-fence.yaml"
API_VERSION = "admissionregistration.k8s.io/v1"
KINDS = {
    "policy": ("ValidatingAdmissionPolicy", "validatingadmissionpolicies.admissionregistration.k8s.io"),
    "binding": ("ValidatingAdmissionPolicyBinding", "validatingadmissionpolicybindings.admissionregistration.k8s.io"),
}
TYPE_CHECK_PENDING = 75


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


def load_fence_file(path=DEFAULT_FENCE_FILE):
    """{"policy": document, "binding": document} from the committed file."""
    try:
        with open(path, encoding="utf-8") as stream:
            documents = [doc for doc in yaml.safe_load_all(stream) if doc is not None]
    except (OSError, yaml.YAMLError) as error:
        raise ReadError(f"could not read fence file {path}: {error}") from error
    found = {}
    for document in documents:
        if not isinstance(document, dict):
            raise ReadError(f"fence file {path} holds a non-object document")
        for role, (kind, _) in KINDS.items():
            if document.get("kind") == kind:
                if role in found:
                    raise ReadError(f"fence file {path} holds more than one {kind}")
                found[role] = document
    if len(documents) != 2 or set(found) != set(KINDS):
        raise ReadError(f"fence file {path} must hold exactly one ValidatingAdmissionPolicy and one binding")
    for role, document in found.items():
        metadata = document.get("metadata") or {}
        if document.get("apiVersion") != API_VERSION or metadata.get("name") != NAME \
                or not isinstance(document.get("spec"), dict):
            raise ReadError(f"fence file {path}: {KINDS[role][0]} is not {API_VERSION} {NAME} with a spec")
    if found["binding"]["spec"].get("policyName") != NAME:
        raise ReadError(f"fence file {path}: the binding does not bind {NAME}")
    return found


def read_live():
    """{"policy": object or None, "binding": object or None}. Raises ReadError."""
    live = {}
    for role, (kind, resource) in KINDS.items():
        text = run(["kubectl", "get", resource, NAME, "--ignore-not-found", "-o", "json"])
        if not text.strip():
            live[role] = None
            continue
        try:
            document = json.loads(text)
        except json.JSONDecodeError as error:
            raise ReadError(f"the {kind} {NAME} read is not JSON: {error}") from error
        if not isinstance(document, dict) or document.get("kind") != kind \
                or (document.get("metadata") or {}).get("name") != NAME:
            raise ReadError(f"the {kind} read did not return {NAME}")
        live[role] = document
    return live


def spec_diff(expected, actual, label):
    return "\n".join(difflib.unified_diff(
        json.dumps(expected, indent=2, sort_keys=True).splitlines(),
        json.dumps(actual, indent=2, sort_keys=True).splitlines(),
        f"{label} (committed)", f"{label} (live)", lineterm=""))


def evaluate(expected, live):
    """("exact" | "absent" | "drift", [errors]) for the live objects against the file."""
    if live["policy"] is None and live["binding"] is None:
        return "absent", [f"the ValidatingAdmissionPolicy and binding {NAME} are not installed"]
    errors = []
    for role, (kind, _) in KINDS.items():
        if live[role] is None:
            errors.append(f"the {kind} {NAME} is missing")
        elif live[role].get("spec") != expected[role]["spec"]:
            errors.append(f"the {kind} {NAME} spec differs from deploy/runner-emergency-stop-fence.yaml")
    policy = live["policy"]
    if policy is not None:
        warnings = ((policy.get("status") or {}).get("typeChecking") or {}).get("expressionWarnings") or []
        if warnings:
            errors.append(f"the ValidatingAdmissionPolicy {NAME} reports {len(warnings)} type-checking expression warning(s)")
    return ("drift" if errors else "exact"), errors


def type_checked(policy):
    """True when the policy status reports type checking of its current generation."""
    status = policy.get("status") or {}
    generation = (policy.get("metadata") or {}).get("generation")
    return "typeChecking" in status and generation is not None and status.get("observedGeneration") == generation


def verify(args):
    expected = load_fence_file(args.fence_file)
    live = read_live()
    state, errors = evaluate(expected, live)
    for role in KINDS:
        if live[role] is not None and live[role].get("spec") != expected[role]["spec"]:
            print(spec_diff(expected[role]["spec"], live[role].get("spec"), KINDS[role][0]), file=sys.stderr)
    if errors:
        for error in errors:
            print(f"REJECTED: Emergency Stop fence: {error}", file=sys.stderr)
        return 1
    if args.require_type_checked and not type_checked(live["policy"]):
        print(f"FENCE: {NAME} matches the file; type checking of its current generation is not reported yet",
              file=sys.stderr)
        return TYPE_CHECK_PENDING
    print(f"FENCE: {NAME} (policy and binding) matches deploy/runner-emergency-stop-fence.yaml"
          + ("; type checked without expression warnings" if args.require_type_checked else ""))
    return 0


def compare_dry_run(args):
    expected = load_fence_file(args.fence_file)
    try:
        with open(args.dry_run, encoding="utf-8") as stream:
            returned = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise ReadError(f"could not read the server dry run {args.dry_run}: {error}") from error
    items = returned.get("items") if isinstance(returned, dict) and returned.get("kind") == "List" else None
    if not isinstance(items, list) or len(items) != 2:
        print("ERROR: the server dry run did not return the policy and the binding", file=sys.stderr)
        return 1
    failed = False
    for role, (kind, _) in KINDS.items():
        matches = [item for item in items if isinstance(item, dict) and item.get("kind") == kind
                   and (item.get("metadata") or {}).get("name") == NAME]
        if len(matches) != 1:
            print(f"ERROR: the server dry run did not return exactly one {kind} {NAME}", file=sys.stderr)
            failed = True
            continue
        if matches[0].get("spec") != expected[role]["spec"]:
            print(spec_diff(expected[role]["spec"], matches[0].get("spec"), kind), file=sys.stderr)
            print(f"ERROR: the server would store a different {kind} spec; nothing was applied", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"FENCE: {NAME} passed the server-side dry run with both specs unchanged")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--fence-file", default=str(DEFAULT_FENCE_FILE))
    verify_parser.add_argument("--require-type-checked", action="store_true")
    dry_run_parser = sub.add_parser("compare-dry-run")
    dry_run_parser.add_argument("dry_run")
    dry_run_parser.add_argument("--fence-file", default=str(DEFAULT_FENCE_FILE))
    try:
        args = parser.parse_args()
    except SystemExit as error:
        return 0 if error.code == 0 else 2
    try:
        return verify(args) if args.mode == "verify" else compare_dry_run(args)
    except ReadError as error:
        print(f"REJECTED: Emergency Stop fence: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
