#!/usr/bin/env python3
"""Run a GitHub Actions workflow's shell steps locally, the way Actions would.

Used by test/verify-burst-autoscaling.sh against fake CLIs (see with_fakes).
Only "run" steps execute; "uses" steps are skipped. The model covers what the
fleet workflows rely on:

  - jobs in dependency order (needs), each with a fresh RUNNER_TEMP;
  - job and step "if" expressions: ==, !=, &&, ||, !, parentheses, string
    literals, inputs.*, needs.<job>.outputs.* / .result, steps.<id>.outputs.*,
    vars.* (always empty), secrets.* ("fixture-token"), github.repository_owner,
    github.<key> from $ACTIONS_GITHUB_CONTEXT (JSON, e.g. event_name, sha, ref),
    job.status and the status functions success(), failure(), cancelled(),
    always(); an expression without a status function means
    "success() && (<expression>)", as in Actions;
  - ${{ ... }} substitution in env values and run scripts;
  - shell semantics: no shell -> "bash -e {0}" (no pipefail);
    "shell: bash" (step or defaults.run) -> "bash --noprofile --norc -eo pipefail {0}";
  - step and job outputs through GITHUB_OUTPUT, one shared GITHUB_STEP_SUMMARY;
  - cancellation: if the file named by $ACTIONS_CANCEL_MARKER exists after a
    step, the run is cancelled: the step counts as cancelled, later steps and
    jobs run only when their condition contains always() or cancelled().

Usage: actions_runner.py WORKFLOW INPUTS_JSON GITFAKE_DIR REPO_DIR [OPTIONS_JSON]
OPTIONS_JSON: {"stub_jobs": {"<job>": "success"}, "stub_steps": {"<step name>": "success"}}

Prints "JOB <id>: <result>" and "STEP <name>: success|failure|cancelled|skipped"
on stdout, then "SUMMARY-BEGIN" and the step summary; step output goes to
stderr. Exits 1 if any job did not succeed.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

STATUS_FUNCTIONS = ("success()", "failure()", "cancelled()", "always()")


class Expr:
    """A small evaluator for the expression subset the workflows use."""

    TOKEN = re.compile(r"\s*(?:(\'(?:[^\']|\'\')*\')|(==|!=|&&|\|\||!|\(|\))|([A-Za-z_][A-Za-z0-9_.\-]*\(\))|([A-Za-z_][A-Za-z0-9_.\-]*)|(\d+))")

    def __init__(self, text, lookup, functions):
        self.tokens = []
        position = 0
        text = text.strip()
        while position < len(text):
            match = self.TOKEN.match(text, position)
            if not match or match.end() == position:
                raise SystemExit(f"unsupported expression: {text!r} at {position}")
            position = match.end()
            literal, operator, function, name, number = match.groups()
            if literal is not None:
                self.tokens.append(("value", literal[1:-1].replace("''", "'")))
            elif operator is not None:
                self.tokens.append(("op", operator))
            elif function is not None:
                if function not in functions:
                    raise SystemExit(f"unsupported function in expression: {function}")
                self.tokens.append(("value", functions[function]()))
            elif name is not None:
                if name in ("true", "false"):
                    self.tokens.append(("value", name == "true"))
                elif name == "null":
                    self.tokens.append(("value", None))
                else:
                    self.tokens.append(("value", lookup(name)))
            else:
                self.tokens.append(("value", int(number)))
        self.index = 0

    def peek(self):
        return self.tokens[self.index] if self.index < len(self.tokens) else (None, None)

    def take(self):
        token = self.peek()
        self.index += 1
        return token

    def evaluate(self):
        value = self.parse_or()
        if self.index != len(self.tokens):
            raise SystemExit("trailing tokens in expression")
        return value

    def parse_or(self):
        value = self.parse_and()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.parse_and()
            value = value if truthy(value) else right
        return value

    def parse_and(self):
        value = self.parse_compare()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.parse_compare()
            value = right if truthy(value) else value
        return value

    def parse_compare(self):
        value = self.parse_unary()
        while self.peek() in (("op", "=="), ("op", "!=")):
            operator = self.take()[1]
            right = self.parse_unary()
            equal = normalize(value) == normalize(right)
            value = equal if operator == "==" else not equal
        return value

    def parse_unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.parse_unary())
        if self.peek() == ("op", "("):
            self.take()
            value = self.parse_or()
            if self.take() != ("op", ")"):
                raise SystemExit("unbalanced parentheses in expression")
            return value
        kind, value = self.take()
        if kind != "value":
            raise SystemExit(f"unexpected token in expression: {value}")
        return value


def truthy(value):
    return value not in (None, False, "", 0)


def normalize(value):
    return value.lower() if isinstance(value, str) else value


def main():
    workflow_path, inputs_json, gitfake, repo = sys.argv[1:5]
    options = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
    inputs = json.loads(inputs_json)
    with open(workflow_path, encoding="utf-8") as stream:
        workflow = yaml.safe_load(stream)
    # Unset dispatch inputs take their declared defaults, as in Actions.
    trigger = workflow.get("on", workflow.get(True)) or {}
    declared = ((trigger.get("workflow_dispatch") or {}).get("inputs") or {}) if isinstance(trigger, dict) else {}
    for name, spec in declared.items():
        if name not in inputs and isinstance(spec, dict) and "default" in spec:
            default = spec["default"]
            inputs[name] = ("true" if default else "false") if isinstance(default, bool) else default
    cancel_marker = os.environ.get("ACTIONS_CANCEL_MARKER", "")
    # github.event_name / github.sha / github.ref come from $ACTIONS_GITHUB_CONTEXT (JSON).
    github_context = json.loads(os.environ.get("ACTIONS_GITHUB_CONTEXT", "{}"))
    summary_dir = tempfile.mkdtemp()
    summary_file = os.path.join(summary_dir, "step-summary.md")
    open(summary_file, "w").close()

    state = {"cancelled": False}
    jobs = workflow["jobs"]
    results, job_outputs = {}, {}

    def needs_of(job):
        needs = job.get("needs") or []
        return [needs] if isinstance(needs, str) else list(needs)

    def make_lookup(context):
        def lookup(name):
            parts = name.split(".")
            if parts[0] == "inputs":
                return str(inputs.get(parts[1], ""))
            if parts[:3] == ["github", "event", "inputs"] and len(parts) == 4:
                return str(inputs.get(parts[3], ""))
            if parts[0] == "vars":
                return ""
            if parts[0] == "secrets":
                return "fixture-token"
            if name == "github.repository_owner":
                return "redducklabs"
            if parts[0] == "github" and len(parts) == 2 and parts[1] in github_context:
                return github_context[parts[1]]
            if parts[0] == "needs" and len(parts) >= 3:
                if parts[2] == "result":
                    return results.get(parts[1], "skipped")
                if parts[2] == "outputs" and len(parts) == 4:
                    return job_outputs.get(parts[1], {}).get(parts[3], "")
            if parts[0] == "steps" and len(parts) == 4 and parts[2] == "outputs":
                return context.get("steps", {}).get(parts[1], {}).get(parts[3], "")
            if name == "job.status":
                return context.get("job_status", "success")
            if parts[0] == "env" and len(parts) == 2:
                return context.get("env", {}).get(parts[1], "")
            raise SystemExit(f"unsupported expression reference: {name}")
        return lookup

    def condition(text, context, ok):
        text = str(text if text is not None else "success()").strip()
        if text.startswith("${{") and text.endswith("}}"):
            text = text[3:-2]
        if not any(function in text for function in STATUS_FUNCTIONS):
            text = f"success() && ({text})"
        functions = {
            "success()": lambda: ok and not state["cancelled"],
            "failure()": lambda: not ok and not state["cancelled"],
            "cancelled()": lambda: state["cancelled"],
            "always()": lambda: True,
        }
        return truthy(Expr(text, make_lookup(context), functions).evaluate())

    def render(text, context):
        def substitute(match):
            functions = {"always()": lambda: True}
            value = Expr(match.group(1), make_lookup(context), functions).evaluate()
            if value is None:
                return ""
            if isinstance(value, bool):
                return "true" if value else "false"
            return str(value)
        return re.sub(r"\$\{\{\s*(.*?)\s*\}\}", substitute, str(text))

    workflow_env = {key: render(value, {}) for key, value in (workflow.get("env") or {}).items()}

    pending = list(jobs)
    while pending:
        progressed = False
        for job_id in list(pending):
            job = jobs[job_id]
            deps = needs_of(job)
            if any(dep not in results for dep in deps):
                continue
            pending.remove(job_id)
            progressed = True
            deps_ok = all(results[dep] == "success" for dep in deps)
            if job_id in options.get("stub_jobs", {}):
                results[job_id] = options["stub_jobs"][job_id] if condition(job.get("if"), {}, deps_ok) else "skipped"
                print(f"JOB {job_id}: {results[job_id]} (stubbed)")
                continue
            if not condition(job.get("if"), {}, deps_ok):
                results[job_id] = "skipped"
                print(f"JOB {job_id}: skipped")
                continue
            results[job_id] = run_job(job_id, job, workflow_env, condition, render, options,
                                      gitfake, repo, summary_file, cancel_marker, state, job_outputs)
            print(f"JOB {job_id}: {results[job_id]}")
        if not progressed:
            raise SystemExit("workflow job graph has a cycle or an unknown need")

    print("SUMMARY-BEGIN")
    with open(summary_file, encoding="utf-8") as stream:
        print(stream.read())
    return 0 if all(result in ("success", "skipped") for result in results.values()) \
        and any(result == "success" for result in results.values()) else 1


def run_job(job_id, job, workflow_env, condition, render, options, gitfake, repo,
            summary_file, cancel_marker, state, job_outputs):
    runner_temp = tempfile.mkdtemp()
    context = {"steps": {}, "job_status": "success", "env": dict(workflow_env)}
    ok = True
    default_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
    for step in job.get("steps") or []:
        if "run" not in step:
            continue
        name = step.get("name", "")
        if not condition(step.get("if"), context, ok):
            print(f"STEP {name}: skipped")
            continue
        if name in options.get("stub_steps", {}):
            result = options["stub_steps"][name]
            print(f"STEP {name}: {result} (stubbed)")
            if result != "success":
                ok = False
                context["job_status"] = "failure"
            continue
        output_file = os.path.join(runner_temp, "output")
        open(output_file, "w").close()
        env = dict(os.environ)
        env.update(workflow_env)
        env.update({key: render(value, context) for key, value in (step.get("env") or {}).items()})
        env.update({"GITHUB_OUTPUT": output_file, "GITHUB_STEP_SUMMARY": summary_file,
                    "RUNNER_TEMP": runner_temp, "PATH": gitfake + os.pathsep + env["PATH"]})
        shell = step.get("shell", default_shell)
        if shell == "bash":
            argv = ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]
        elif shell is None:
            argv = ["bash", "-e", "-c"]
        else:
            raise SystemExit(f"unsupported shell in workflow step: {shell}")
        completed = subprocess.run(argv + [render(step["run"], context)], cwd=repo, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stderr.write(completed.stdout)
        if step.get("id"):
            values = {}
            with open(output_file, encoding="utf-8") as stream:
                for line in stream:
                    key, _, value = line.rstrip("\n").partition("=")
                    values[key] = value
            context["steps"][step["id"]] = values
        if cancel_marker and os.path.exists(cancel_marker) and not state["cancelled"]:
            state["cancelled"] = True
            result = "cancelled"
        elif step.get("continue-on-error") and completed.returncode != 0:
            result = "failure (continue-on-error)"
        else:
            result = "success" if completed.returncode == 0 else "failure"
        print(f"STEP {name}: {result}")
        if result in ("failure", "cancelled"):
            ok = False
            context["job_status"] = "cancelled" if state["cancelled"] else "failure"
    outputs = {key: render(value, context) for key, value in (job.get("outputs") or {}).items()}
    job_outputs[job_id] = outputs
    for key, value in sorted(outputs.items()):
        print(f"OUTPUT {job_id}.{key}={value}")
    if state["cancelled"]:
        return "cancelled"
    return "success" if ok else "failure"


if __name__ == "__main__":
    raise SystemExit(main())
