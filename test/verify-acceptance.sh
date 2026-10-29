#!/bin/bash

# Offline verification for the burst-rollout acceptance tooling:
#   - scripts/acceptance-verdict.py against test/fixtures/acceptance/
#     (expected.json names each fixture's verdict and violated criteria);
#   - static contracts of .github/workflows/runner-acceptance-evidence.yml
#     and the Phase C evidence upload in scale-runners.yml;
#   - the evidence workflow end to end through test/lib/actions_runner.py,
#     with gh/kubectl/doctl replaced by test/fixtures/acceptance-sim.
#
# Nothing here reaches GitHub, DigitalOcean or a cluster.
# Usage: ./test/verify-acceptance.sh

set -uo pipefail

# Under Git Bash/MSYS/Cygwin Python's subprocess ignores the extensionless
# fakes and would resolve the real CLIs (see verify-burst-autoscaling.sh).
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        echo "ERROR: verify-acceptance.sh must not run under Git Bash/MSYS/Cygwin; run it in WSL against an LF clone." >&2
        exit 2
        ;;
esac

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/acceptance"
SIM="${SCRIPT_DIR}/fixtures/acceptance-sim/acceptance_sim.py"
VERDICT="${REPO_ROOT}/scripts/acceptance-verdict.py"
EVIDENCE_WORKFLOW="${REPO_ROOT}/.github/workflows/runner-acceptance-evidence.yml"
SCALE_WORKFLOW="${REPO_ROOT}/.github/workflows/scale-runners.yml"
ACTIONS_RUNNER="${SCRIPT_DIR}/lib/actions_runner.py"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PROBE_SHA=cccccccccccccccccccccccccccccccccccccccc
TAG=runner-burst-acceptance-2026-11-02-a

FAILURES=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }

# ---------------------------------------------------------------------------
# Verdict fixtures
# ---------------------------------------------------------------------------

assert_verdict_fixtures() {
    info "Checking acceptance verdicts for every fixture..."
    local name phase rc
    while IFS= read -r name; do
        phase=${name%%-*}
        python3 "$VERDICT" --phase "$phase" "${FIXTURES}/${name}.json" > "${WORK_DIR}/verdict.json" 2> "${WORK_DIR}/verdict.err"
        rc=$?
        if python3 - "$FIXTURES/expected.json" "$name" "$rc" "${WORK_DIR}/verdict.json" <<'PY'
import json
import sys

expected_all, name, rc, verdict_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
expected = json.load(open(expected_all, encoding="utf-8"))[name]
verdict = json.load(open(verdict_path, encoding="utf-8"))
prefixes = {failure.split(":", 1)[0] for failure in verdict["failures"]}
problems = []
if verdict["pass"] != expected["pass"] or rc != (0 if expected["pass"] else 1):
    problems.append(f"pass={verdict['pass']} exit={rc}")
if verdict["ready_for_migration"] != expected["ready_for_migration"]:
    problems.append(f"ready_for_migration={verdict['ready_for_migration']}")
if not expected["pass"]:
    if expected["criteria"][0] not in prefixes:
        problems.append(f"does not name {expected['criteria'][0]}")
    if not prefixes <= set(expected["criteria"]):
        problems.append(f"also fails {sorted(prefixes - set(expected['criteria']))}")
if problems:
    print("; ".join(problems), verdict["failures"])
    sys.exit(1)
PY
        then
            pass "verdict ${name}: $(jq -r 'if .pass then "pass" else (.failures[0] | split(":")[0]) end' "${WORK_DIR}/verdict.json")"
        else
            fail "verdict ${name}: $(jq -c '.failures' "${WORK_DIR}/verdict.json" 2>/dev/null) $(head -c 300 "${WORK_DIR}/verdict.err")"
        fi
    done < <(jq -r 'keys[]' "${FIXTURES}/expected.json")

    # Every fixture file is listed, and each phase has a pass and a violation.
    if python3 - "$FIXTURES" <<'PY'
import json
import os
import sys

directory = sys.argv[1]
expected = json.load(open(os.path.join(directory, "expected.json"), encoding="utf-8"))
files = {name[:-5] for name in os.listdir(directory) if name.endswith(".json") and name != "expected.json"}
assert files == set(expected), sorted(files ^ set(expected))
for phase in "ABCDE":
    cases = {name: case for name, case in expected.items() if name.startswith(phase + "-")}
    assert any(case["pass"] for case in cases.values()), phase
    assert any(not case["pass"] for case in cases.values()), phase
ready = [name for name, case in expected.items() if case["ready_for_migration"]]
assert ready == ["E-pass"], ready
for phase in "ABE":
    assert any(case["criteria"] == ["pickup-cold"] for name, case in expected.items() if name.startswith(phase + "-")), phase
assert not any("pickup" in criterion for name, case in expected.items() if name.startswith("D-")
               for criterion in case["criteria"]), "Ruling 22: phase D has no pickup criterion"
for criterion in ("C-arc", "D-arc", "E-arc", "runner-health", "A-network"):
    assert any(criterion in case["criteria"] for case in expected.values()), criterion
# Ruling 43 regressions: idle warm runners on baseline still pass; the
# 16-job overflow into fallback and Pending pods in Phase B fail.
assert expected["A-pass-warm-on-baseline"]["pass"] is True
assert expected["A-16-jobs-fallback-overflow"]["criteria"][0] == "A-primary-only"
assert expected["B-pending-pods"]["criteria"] == ["B-placement"]
# PR #41 review: placement is judged from collections inside the hold.
assert expected["A-pass-idle-pending-early"]["pass"] is True
for name, criterion in (("A-idle-pending-through-hold", "A-primary-only"), ("A-collections-after-hold", "A-primary-only"),
                        ("A-idle-turnover", "A-primary-only"),
                        ("B-pending-then-scheduled-after-hold", "B-placement")):
    assert expected[name]["criteria"] == [criterion], name
PY
    then
        pass "fixtures: every file is expected, each phase has passing and violating cases, cold p95 of 9 minutes fails A/B/E, D has no pickup criterion, only E-pass is ready"
    else
        fail "fixture inventory is inconsistent"
    fi

    python3 "$VERDICT" --phase B "${FIXTURES}/A-pass.json" > "${WORK_DIR}/verdict.json"
    rc=$?
    if [ "$rc" -eq 1 ] && jq -e '.failures[0] | startswith("evidence:")' "${WORK_DIR}/verdict.json" > /dev/null; then
        pass "verdict: phase A evidence evaluated as phase B fails"
    else
        fail "verdict: phase mismatch was not rejected (exit ${rc})"
    fi
    # An evaluation crash still writes a failing verdict and exits 1.
    printf '{"phase": "A", "probe": {"run": {"jobs": "not-a-list"}}}' > "${WORK_DIR}/crash.json"
    python3 "$VERDICT" --phase A "${WORK_DIR}/crash.json" --out "${WORK_DIR}/crash-verdict.json" > /dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 1 ] && jq -e '.pass == false and (.failures[0] | startswith("verdict-error:"))' "${WORK_DIR}/crash-verdict.json" > /dev/null 2>&1; then
        pass "verdict: an evaluation crash writes pass=false with the error and exits 1"
    else
        fail "verdict: evaluation crash exited ${rc}: $(cat "${WORK_DIR}/crash-verdict.json" 2>/dev/null)"
    fi
    printf 'not json' > "${WORK_DIR}/broken.json"
    python3 "$VERDICT" --phase A "${WORK_DIR}/broken.json" > /dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 2 ]; then pass "verdict: unreadable evidence exits 2"; else fail "verdict: unreadable evidence exited ${rc}"; fi
}

# ---------------------------------------------------------------------------
# Static workflow contracts
# ---------------------------------------------------------------------------

assert_evidence_workflow_static() {
    info "Checking the evidence workflow's static contract..."
    if (cd "$REPO_ROOT" && python3 - "$EVIDENCE_WORKFLOW" "$SCALE_WORKFLOW" scripts/acceptance-evidence.py) <<'PY'
import re
import sys

import yaml

workflow_path, scale_path, collector_path = sys.argv[1:4]
text = open(workflow_path, encoding="utf-8").read()
workflow = yaml.safe_load(text)
collector = open(collector_path, encoding="utf-8").read()
trigger = workflow.get("on", workflow.get(True))
inputs = trigger["workflow_dispatch"]["inputs"]
assert set(inputs) == {"phase", "probe_run_id", "drain_run_id", "phase_c_run_id", "rollback_run_id",
                       "baseline_run_id", "dispatch_tag", "expected_workflow_sha", "expected_sha"}, sorted(inputs)
assert inputs["phase"]["options"] == ["A", "B", "C", "D", "E"]
assert set(trigger) == {"workflow_dispatch"}, "evidence workflow is dispatch-only"
assert workflow["permissions"] == {"contents": "read"}, workflow["permissions"]
assert workflow["concurrency"] == {"group": "runner-acceptance-evidence", "cancel-in-progress": False}
(job,) = workflow["jobs"].values()
assert job["runs-on"] == "ubuntu-latest"
assert job["defaults"] == {"run": {"shell": "bash"}}
assert job["timeout-minutes"] <= 360
run_steps = [step for step in job["steps"] if "run" in step]
# SHA-guarded: the first run step compares expected_sha with HEAD before anything else.
first = run_steps[0]["run"]
assert first.index("git rev-parse HEAD") < first.index("INPUT_PROBE_RUN_ID"), "expected_sha is not checked first"
assert '"${INPUT_EXPECTED_SHA}" != "${ACTUAL_SHA}"' in first
names = [step["name"] for step in job["steps"]]
# The probe is verified (and marked for cleanup) before the anchor runs.
assert names.index("Verify probe run") < names.index("Verify anchor runs") \
    < names.index("Configure Kubernetes access (read-only)") \
    < names.index("Capture evidence while the probe holds"), names
verify = next(step for step in job["steps"] if step["name"] == "Verify probe run")
assert "verify-probe" in verify["run"] and 'echo "probe_verified=true"' in verify["run"]
anchors = next(step for step in job["steps"] if step["name"] == "Verify anchor runs")
assert "verify-anchors" in anchors["run"] and "probe_verified" not in anchors["run"]
ready = next(step for step in job["steps"] if step["name"] == "Report migration readiness")
assert ready["if"] == "always() && steps.validate.outputs.phase == 'E'"
assert job["outputs"]["ready_for_migration"] == "${{ steps.ready.outputs.ready_for_migration }}"
for deadline in ("C) DEADLINE=300", "D) DEADLINE=150", "*) DEADLINE=45"):
    assert deadline in first, deadline
cleanup = next(step for step in job["steps"] if step["name"] == "Cancel the probe and verify cleanup")
assert cleanup["if"] == "always() && steps.verify.outputs.probe_verified == 'true' && (failure() || cancelled())"
upload = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/upload-artifact"))
assert upload["uses"] == "actions/upload-artifact@v7" and upload["if"].startswith("always()")
assert upload["with"]["path"] == "acceptance-${{ steps.validate.outputs.phase }}.json"
# headSha, event, attempt, path, repository and the annotated tag are verified.
for needle in ('run_data["head_sha"] != args.expected_workflow_sha', 'run_data["event"] != "workflow_dispatch"',
               'run_data["attempt"] != 1', 'run_data["workflow_path"] != PROBE_WORKFLOW',
               'run_data["repository"] != PROBE_REPOSITORY', "git/ref/tags/", 'obj.get("type") != "tag"',
               "tag_sha != args.expected_workflow_sha"):
    assert needle in collector, needle
# No cluster or provider mutation anywhere in the workflow or the collector.
mutating = re.compile(r"kubectl\s+(delete|apply|patch|edit|scale|label|annotate|cordon|uncordon|drain|create|replace|rollout|set)\b"
                      r"|helm\s+(upgrade|install|rollback|uninstall)\b|doctl\b[^\n]*\b(create|update|delete)\b")
for source in (text, collector):
    assert not mutating.search(source), mutating.search(source).group(0)
for match in re.finditer(r'\["kubectl",\s*"([a-z-]+)"', collector):
    assert match.group(1) == "get", match.group(0)
for match in re.finditer(r'\["doctl",([^\]]*)\]', collector):
    assert match.group(1).count('"list"') == 1, match.group(0)
gh_calls = set(re.findall(r'\["gh",\s*"([a-z]+)",\s*"([a-z-]+)"', collector))
# --allow-escape-sequences (job logs, Ruling 42) only lets gh print the log; it stays a GET.
assert gh_calls <= {("api", "--paginate"), ("api", "--allow-escape-sequences"), ("run", "view"), ("run", "download"),
                    ("run", "cancel")}, gh_calls
assert "--method" not in collector and '"-X"' not in collector
# Scale Runners uploads the Phase C evidence for this workflow.
scale = yaml.safe_load(open(scale_path, encoding="utf-8"))
steps = scale["jobs"]["scale"]["steps"]
upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact"))
assert upload["uses"] == "actions/upload-artifact@v7"
assert upload["with"]["name"] == "phase-c-evidence" and upload["with"]["path"] == "phase-c-evidence.json"
assert upload["if"] == "always() && steps.admit.outputs.cleanup_eligible == 'true'"
assert steps.index(upload) > [step.get("name") for step in steps].index("Restore burst after Phase C")
PY
    then
        pass "evidence workflow: dispatch inputs, ubuntu-latest, contents:read, bash, SHA first, identity before cluster reads, read-only, cancel only a verified probe, record upload; Scale Runners uploads Phase C evidence"
    else
        fail "evidence workflow static contract"
    fi
    local script
    for script in scripts/acceptance-evidence.py scripts/acceptance-verdict.py test/verify-acceptance.sh; do
        if [ -x "${REPO_ROOT}/${script}" ] || git -C "$REPO_ROOT" ls-files -s "$script" 2>/dev/null | grep -q '^100755'; then
            pass "${script} is executable"
        else
            fail "${script} is not executable"
        fi
    done
}

# ---------------------------------------------------------------------------
# Evidence workflow end to end
# ---------------------------------------------------------------------------

REPO_COPY=""
SIM_OUT="${WORK_DIR}/sim.out"
SIM_ERR="${WORK_DIR}/sim.err"

# sim_dir <fixture-name> [overrides-json]: a fresh scenario directory.
sim_dir() {
    local dir
    dir=$(mktemp -d "${WORK_DIR}/sim.XXXXXX")
    python3 -B "$SIM" "$dir" init "${FIXTURES}/${1}.json" "${2:-{\}}" || return 1
    printf '#!/bin/bash\necho "STATE: arc=%s pools=both burst=open"\n' "${3:-burst}" > "${dir}/gate"
    printf '#!/bin/bash\necho "trust boundary verified"\n' > "${dir}/trust"
    chmod +x "${dir}/gate" "${dir}/trust"
    printf '%s\n' "$dir"
}

# run_evidence <dir> <inputs-json> [sha]: runs the workflow against the sim.
run_evidence() {
    local dir=$1 inputs=$2 sha=${3:-$SHA} fake_dir fake_home tool resolved
    if [ -z "$REPO_COPY" ]; then
        REPO_COPY=$(mktemp -d "${WORK_DIR}/repo.XXXXXX")
        (cd "$REPO_ROOT" && tar --exclude=.git -cf - .) | (cd "$REPO_COPY" && tar -xf -)
    fi
    rm -f "${REPO_COPY}"/acceptance-*.json "${dir}/calls.log"
    fake_dir=$(mktemp -d "${WORK_DIR}/fakes.XXXXXX")
    fake_home=$(mktemp -d "${WORK_DIR}/home.XXXXXX")
    for tool in gh kubectl doctl helm; do
        printf '#!/bin/bash\nexec python3 -B %q %q %q "$@"\n' "$SIM" "$dir" "$tool" > "${fake_dir}/${tool}"
        chmod +x "${fake_dir}/${tool}"
    done
    printf '#!/bin/bash\n[ "$*" = "rev-parse HEAD" ] || { echo "fake git: unexpected $*" >&2; exit 97; }\necho %q\n' "$sha" > "${fake_dir}/git"
    chmod +x "${fake_dir}/git"
    printf '#!/bin/bash\nexec python3 -B %q %q sleep "$1"\n' "$SIM" "$dir" > "${dir}/fakesleep"
    chmod +x "${dir}/fakesleep"
    for tool in gh kubectl doctl helm; do
        resolved=$(PATH="${fake_dir}:${PATH}" python3 -c 'import shutil, sys; print(shutil.which(sys.argv[1]))' "$tool")
        if [ "$resolved" != "${fake_dir}/${tool}" ]; then
            echo "run_evidence: ${tool} resolves to '${resolved}', not the fake; refusing to run" >&2
            return 98
        fi
    done
    env -u DIGITALOCEAN_ACCESS_TOKEN -u DO_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
        KUBECONFIG=/nonexistent HOME="$fake_home" XDG_CONFIG_HOME="$fake_home" PATH="${fake_dir}:${PATH}" \
        "NOW_CMD=cat ${dir}/clock" "SLEEP_CMD=${dir}/fakesleep" \
        "POOL_STATE_CMD=${dir}/gate" "TRUST_VERIFY_CMD=${dir}/trust" \
        python3 -B "$ACTIONS_RUNNER" "$EVIDENCE_WORKFLOW" "$inputs" "$fake_dir" "$REPO_COPY" \
        > "$SIM_OUT" 2> "$SIM_ERR"
}

steps_of() { grep -E '^(STEP|JOB) ' "$SIM_OUT" | tr '\n' ';' | head -c 700; }

# expect_evidence <label> <rc> <expected-rc> <stdout line|-> <stderr text|-> [<calls.log regex that must match|->] [<regex that must not match|->] <dir>
expect_evidence() {
    local label=$1 rc=$2 expected=$3 line=$4 text=$5 must=$6 mustnot=$7 dir=$8
    if { [ "$expected" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$expected" != 0 ] && [ "$rc" -eq 0 ]; }; then
        fail "${label}: exit ${rc}, expected ${expected} ($(steps_of)) $(grep -E 'ERROR|REJECTED|DEADLINE|CLEANUP|❌|^[A-E]-[a-z-]+:|^pickup|^probe-identity|^evidence:' "$SIM_ERR" | head -n 6 | tr '\n' ' ')"
    elif [ "$line" != - ] && ! grep -qF -- "$line" "$SIM_OUT"; then
        fail "${label}: stdout lacks '${line}' ($(steps_of))"
    elif [ "$text" != - ] && ! grep -qF -- "$text" "$SIM_ERR"; then
        fail "${label}: output lacks '${text}' ($(grep -E 'ERROR|REJECTED|DEADLINE|CLEANUP|❌|^[A-E]-[a-z-]+:|^pickup|^probe-identity|^evidence:' "$SIM_ERR" | head -n 6 | tr '\n' ' '))"
    elif [ "$must" != - ] && ! grep -qE -- "$must" "${dir}/calls.log" 2>/dev/null; then
        fail "${label}: no call matching '${must}'"
    elif [ "$mustnot" != - ] && grep -qE -- "$mustnot" "${dir}/calls.log" 2>/dev/null; then
        fail "${label}: unexpected call $(grep -E -- "$mustnot" "${dir}/calls.log" | head -n 1)"
    else
        pass "${label}"
    fi
}

probe_inputs() {  # phase [extra json members]
    printf '{"phase":"%s","probe_run_id":"777","dispatch_tag":"%s","expected_workflow_sha":"%s","expected_sha":"%s"%s}' \
        "$1" "$TAG" "$PROBE_SHA" "$SHA" "${2:-}"
}

# Read-only: every cluster/provider call is a get/list or kubeconfig setup.
READ_ONLY_VIOLATION='^(kubectl (delete|apply|patch|edit|scale|label|annotate|cordon|drain|create|replace|rollout)|doctl .*(create|update|delete)|helm )'

assert_evidence_workflow_runs() {
    info "Running the evidence workflow end to end against the acceptance simulator..."
    local dir rc

    dir=$(sim_dir A-pass)
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A passes end to end" $? 0 "STEP Cancel the probe and verify cleanup: skipped" \
        "✅ Phase A passed acceptance" '^kubectl get pods' "${READ_ONLY_VIOLATION}|^gh run cancel" "$dir"
    if jq -e '.verdict.pass == true and .cleanup == null and (.pods | length) == 16 and .arc_contract_after == "burst"' \
        "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1; then
        pass "phase A record: evidence, verdict and no cleanup in acceptance-A.json"
    else
        fail "phase A record: $(head -c 300 "${REPO_COPY}/acceptance-A.json" 2>/dev/null)"
    fi
    # Ruling 43: 14 jobs run 16 runner pods (minRunners 2 + 14); the record
    # keeps the two idle runners, and the verdict counts every pod in the hold.
    if jq -e '([.probe.run.jobs[] | select(.name | test("^batch "))] | length) == 14
              and ([.probe.run.jobs[].runner_name] as $busy | [.pods[] | select(.runner_name as $n | ($busy | index($n)) == null)] | length) == 2
              and all(.pods[]; .last_seen != null and .pool != null)
              and any(.verdict.notes[]; test("by pool .{2}github-runners-pool-16g.: 4, .github-runners-burst-amd-16g.: 12. .*minRunners 2 . 14 jobs"))' \
        "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1; then
        pass "phase A record: 14 jobs, 16 runner pods (2 idle) with pool and last_seen; placement counted every pod in the hold"
    else
        fail "phase A record: hold placement $(jq -c '.verdict.notes' "${REPO_COPY}/acceptance-A.json" 2>/dev/null | head -c 400)"
    fi

    # Phase A network probe: the job log result and the targets resolved in the cluster.
    if jq -e '.network_probe.pass == true and .network_probe.job.name == "network-probe"
              and (.network_probe.results | length) == 11
              and .network_probe.target_checks.worker_node.pool == "worker-pool"
              and .network_probe.target_checks.runner_node.pool == "github-runners-pool-16g"
              and .network_probe.target_checks.runner_node_public.address_type == "ExternalIP"
              and .network_probe.target_checks.kubernetes_service.address == "10.245.0.1:443"
              and .network_probe.target_checks.service.port_declared == true
              and .network_probe.target_checks.pod.name == "metrics-server-7c9f8d5b4-q2w3e"
              and .network_probe.target_checks.pod.allowed_by_dns_rule == false' "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1 \
        && grep -q '^gh api --allow-escape-sequences repos/redducklabs/aurolegal.ai/actions/jobs/9100/logs$' "${dir}/calls.log" \
        && grep -q '^kubectl get pods -A --field-selector status.podIP=10.244.0.150 -o json$' "${dir}/calls.log"; then
        pass "phase A record: network probe result read from the job log, targets resolved read-only in the cluster"
    else
        fail "phase A record: network probe $(jq -c '.network_probe' "${REPO_COPY}/acceptance-A.json" 2>/dev/null | head -c 400)"
    fi
    local label network_case
    while IFS='|' read -r label network_case; do
        [ -n "$label" ] || continue
        dir=$(sim_dir A-pass "$network_case")
        run_evidence "$dir" "$(probe_inputs A)"
        expect_evidence "phase A fails A-network when ${label}" $? 1 - "A-network:" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"
    done <<'CASES'
the network-probe log has no result line|{"logs.9100": "2026-11-02T18:20:20.1000000Z printf 'NETWORK_PROBE_%s %s\\n' RESULT\n"}
the probe address is not a worker-pool node|{"cluster_nodes": []}
the service port is not declared|{"services": [{"metadata": {"name": "metrics-server", "namespace": "kube-system"}, "spec": {"type": "ClusterIP", "clusterIP": "10.245.31.20", "ports": [{"port": 4443}]}}]}
the pod address is not a pod|{"all_pods": []}
the pod is a kube-dns pod the DNS rule allows|{"all_pods": [{"metadata": {"name": "coredns-6d4b75cb6d-k8s2m", "namespace": "kube-system", "labels": {"k8s-app": "kube-dns"}}, "spec": {"containers": [{"name": "coredns", "ports": [{"containerPort": 10250}]}]}, "status": {"phase": "Running", "podIP": "10.244.0.150"}}]}
the public address is not a node ExternalIP|{"cluster_nodes": [{"metadata": {"name": "worker-pool-x1y2z", "labels": {"doks.digitalocean.com/node-pool": "worker-pool"}}, "status": {"addresses": [{"type": "InternalIP", "address": "10.124.0.4"}]}}, {"metadata": {"name": "baseline-b", "labels": {"doks.digitalocean.com/node-pool": "github-runners-pool-16g"}}, "status": {"addresses": [{"type": "InternalIP", "address": "10.124.0.7"}, {"type": "InternalIP", "address": "203.0.113.17"}]}}]}
the default/kubernetes Service differs from the probed address|{"services": [{"metadata": {"name": "kubernetes", "namespace": "default"}, "spec": {"type": "ClusterIP", "clusterIP": "10.245.0.9", "ports": [{"port": 443}]}}, {"metadata": {"name": "metrics-server", "namespace": "kube-system"}, "spec": {"type": "ClusterIP", "clusterIP": "10.245.31.20", "ports": [{"port": 443}]}}]}
CASES
    dir=$(sim_dir A-network-imds-connected)
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A fails when the metadata service was reachable" $? 1 - "A-network: forbidden connection to imds" '^gh run cancel 777' - "$dir"
    dir=$(sim_dir B-pass)
    run_evidence "$dir" "$(probe_inputs B)"
    if ! grep -qE '^gh api --allow-escape-sequences repos/redducklabs/aurolegal.ai/actions/jobs/[0-9]+/logs|^kubectl get services' "${dir}/calls.log" \
        && jq -e '.network_probe == null' "${REPO_COPY}/acceptance-B.json" > /dev/null 2>&1; then
        pass "phase B: no network probe evidence is read"
    else
        fail "phase B read network probe evidence"
    fi

    # A verdict failure cancels the verified probe and waits for completed.
    dir=$(sim_dir A-fallback-node)
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A verdict failure cancels the probe" $? 1 "STEP Cancel the probe and verify cleanup: success" \
        "CLEANUP: clean" '^gh run cancel 777 -R redducklabs/aurolegal.ai' "$READ_ONLY_VIOLATION" "$dir"
    if grep -n '' "${dir}/calls.log" | grep -A50 'gh run cancel 777' | grep -q 'gh api repos/redducklabs/aurolegal.ai/actions/runs/777$' \
        && jq -e '.verdict.pass == false and .cleanup.status == "clean"' "${REPO_COPY}/acceptance-A.json" > /dev/null; then
        pass "phase A verdict failure: run status read after the cancel; record carries the failed verdict and clean cleanup"
    else
        fail "phase A verdict failure: no status read after cancel or record incomplete"
    fi

    # The deadline cancels a probe that is still running; cleanup waits for completed.
    dir=$(sim_dir A-pass '{"runs.probe.complete_at": null}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "deadline: probe still running at 45 minutes is cancelled and cleanup waits for completed" $? 1 \
        "STEP Capture evidence while the probe holds: failure" "CLEANUP: clean" '^gh run cancel 777' - "$dir"
    if grep -q 'DEADLINE: redducklabs/aurolegal.ai#777 not completed within 45 minutes' "$SIM_ERR" \
        && grep -q 'STEP Evaluate acceptance verdict: skipped' "$SIM_OUT"; then
        pass "deadline: DEADLINE reported, no verdict evaluated"
    else
        fail "deadline: $(steps_of)"
    fi

    # A run that never completes after the cancel fails cleanup.
    dir=$(sim_dir A-pass '{"runs.probe.complete_at": null, "runs.probe.cancel": "ignored"}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "cleanup fails when the probe never reaches completed" $? 1 \
        "STEP Cancel the probe and verify cleanup: failure" "did not reach status completed within 10 minutes" '^gh run cancel 777' - "$dir"

    # Jobs still in progress after completion, or a runner still assigned, fail cleanup.
    dir=$(sim_dir A-fallback-node '{"runs.probe.live_jobs_after_cancel": true}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "cleanup fails when probe jobs are still in progress" $? 1 \
        "STEP Cancel the probe and verify cleanup: failure" "jobs still queued or in progress" - - "$dir"
    dir=$(sim_dir A-fallback-node '{"ephemeral_runners": [{"metadata": {"name": "ar9"}, "status": {"phase": "Running", "workflowRunId": 777}}]}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "cleanup fails when a runner is still assigned to the probe run" $? 1 \
        "STEP Cancel the probe and verify cleanup: failure" "runner pods still assigned to the probe run: ar9" - - "$dir"

    # Probe identity rejections happen before any cluster read and never cancel.
    local override label
    while IFS='|' read -r label override; do
        [ -n "$label" ] || continue
        dir=$(sim_dir A-pass "$override")
        run_evidence "$dir" "$(probe_inputs A)"
        expect_evidence "probe from ${label} is rejected before evidence collection" $? 1 \
            "STEP Capture evidence while the probe holds: skipped" "REJECTED:" - '^(kubectl|doctl)|^gh run cancel' "$dir"
    done <<'CASES'
another workflow path|{"runs.probe.api.path": ".github/workflows/runner-fleet-probe.yml"}
another repository|{"runs.probe.api.repository": {"full_name": "redducklabs/keel"}}
another SHA|{"runs.probe.api.head_sha": "dddddddddddddddddddddddddddddddddddddddd"}
another event|{"runs.probe.api.event": "push"}
a re-run attempt|{"runs.probe.api.run_attempt": 2}
a branch instead of the tag|{"runs.probe.api.head_branch": "main"}
a lightweight tag|{"tags.runner-burst-acceptance-2026-11-02-a.type": "commit"}
a tag that targets another commit|{"tags.runner-burst-acceptance-2026-11-02-a.commit": "dddddddddddddddddddddddddddddddddddddddd"}
CASES

    dir=$(sim_dir A-pass)
    run_evidence "$dir" "$(probe_inputs A)" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    expect_evidence "mismatched expected_sha fails before any read" $? 1 "STEP Verify probe run: skipped" \
        "does not match checked-out SHA" - '.' "$dir"
    dir=$(sim_dir A-pass)
    run_evidence "$dir" "$(probe_inputs A ',"drain_run_id":"444"')"
    expect_evidence "phase A rejects a drain_run_id" $? 1 "STEP Verify probe run: skipped" "drain_run_id is not used by phase A" - '.' "$dir"

    # Phase B waits for the operator's restore and passes.
    dir=$(sim_dir B-pass)
    run_evidence "$dir" "$(probe_inputs B)"
    expect_evidence "phase B passes with primary restored after the probe" $? 0 - "✅ Phase B passed acceptance" - "$READ_ONLY_VIOLATION" "$dir"
    # Two of the eight runner pods never schedule (Ruling 43 regression).
    dir=$(sim_dir B-pending-pods)
    run_evidence "$dir" "$(probe_inputs B)"
    expect_evidence "phase B fails B-placement when runner pods stay Pending through the hold" $? 1 - \
        "B-placement: runner pods in the latest collection inside the hold by pool" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"

    # The simulator models ARC 0.14.2: a batch of N jobs holds minRunners + N pods.
    jq 'del(.pod_collections[].pods[-1])' "${FIXTURES}/B-pass.json" > "${WORK_DIR}/B-seven-pods.json"
    dir=$(mktemp -d "${WORK_DIR}/sim.XXXXXX")
    python3 -B "$SIM" "$dir" init "${WORK_DIR}/B-seven-pods.json" '{}' 2> "${WORK_DIR}/sim-init.err"
    rc=$?
    if [ "$rc" -eq 97 ] && grep -qF "6 batch jobs need 8 runner pods during the hold" "${WORK_DIR}/sim-init.err" \
        && [ ! -e "${dir}/scenario.json" ]; then
        pass "simulator refuses a batch scenario without minRunners + jobs runner pods"
    else
        fail "simulator accepted 7 runner pods for 6 jobs (exit ${rc}): $(head -c 200 "${WORK_DIR}/sim-init.err")"
    fi

    # Placement is judged from the collections inside the hold (PR #41 review).
    # Idle pods Pending through the hold and scheduled afterwards fail although
    # their final node is a primary node.
    local pending_after
    pending_after='{"changes": ['
    pending_after+='{"at": "2026-11-02T18:00:00Z", "kind": "pods", "name": "ar15", "merge": {"spec": {"nodeName": null}}},'
    pending_after+='{"at": "2026-11-02T18:00:00Z", "kind": "pods", "name": "ar16", "merge": {"spec": {"nodeName": null}}},'
    pending_after+='{"at": "2026-11-02T18:21:00Z", "kind": "pods", "name": "ar15", "merge": {"spec": {"nodeName": "p6"}}},'
    pending_after+='{"at": "2026-11-02T18:21:00Z", "kind": "pods", "name": "ar16", "merge": {"spec": {"nodeName": "p6"}}}]}'
    dir=$(sim_dir A-pass "$pending_after")
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A fails when idle pods stay Pending through the hold and schedule afterwards" $? 1 - \
        "A-primary-only: runner pods in the latest collection inside the hold" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"
    if jq -e '[.pods[] | select(.runner_name == "ar15" or .runner_name == "ar16") | .node] == ["p6", "p6"]
              and any(.pod_collections[]; any(.pods[]; .runner_name == "ar15" and .node == null))
              and any(.pod_collections[]; any(.pods[]; .runner_name == "ar15" and .node == "p6"))' \
        "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1; then
        pass "phase A record: pod_collections keep the Pending observations although the final node is p6"
    else
        fail "phase A record: pod_collections $(jq -c '[.pod_collections[] | {at, n: (.pods | length)}]' "${REPO_COPY}/acceptance-A.json" 2>/dev/null | head -c 300)"
    fi
    # The collector starts after the hold ended (clock 2026-11-02T18:21:00Z).
    dir=$(sim_dir A-pass '{"clock": 1793643660}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A fails when no collection lies inside the hold" $? 1 - \
        "A-primary-only: no runner-pod collection inside the hold" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"
    # Idle-pod turnover: a Pending replacement appears before the idle pod
    # it replaces is gone, so collections inside the hold list 17 pods.
    local turnover
    turnover='{"changes": ['
    turnover+='{"at": "2026-11-02T18:11:00Z", "kind": "pods", "add": {"metadata": {"name": "ar17", "uid": "uid-ar17", "creationTimestamp": "2026-11-02T18:11:00Z", "annotations": {}}, "spec": {"nodeName": null, "containers": []}, "status": {"phase": "Pending"}}},'
    turnover+='{"at": "2026-11-02T18:14:00Z", "kind": "pods", "name": "ar16", "remove": true},'
    turnover+='{"at": "2026-11-02T18:14:00Z", "kind": "pods", "name": "ar17", "merge": {"spec": {"nodeName": "p6"}, "status": {"phase": "Running"}}}]}'
    dir=$(sim_dir A-pass "$turnover")
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A fails on idle-pod turnover inside the hold" $? 1 - \
        "inside the hold saw runner pods" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"

    # Phase D: drain anchors from the Deploy drain run.
    dir=$(sim_dir D-pass '{}' drain)
    run_evidence "$dir" "$(probe_inputs D ',"drain_run_id":"444"')"
    expect_evidence "phase D passes with the drain overlapping continuous load" $? 0 - "✅ Phase D passed acceptance" \
        '^gh run view 444 -R redducklabs/redducklabs-runners --json jobs' "$READ_ONLY_VIOLATION" "$dir"
    # The READBACK line is colored (inside the marker and around the
    # timestamp); its time is parsed after stripping.
    if jq -e --arg effective "$(jq -r '.probe.drain.effective' "${FIXTURES}/D-pass.json")" \
        '.probe.drain.operation_job == "Drain Burst Runners" and .probe.drain.effective == $effective and .verdict.pickup.in_flight_at_drain_started >= 8' \
        "${REPO_COPY}/acceptance-D.json" > /dev/null 2>&1; then
        pass "phase D record: drain step anchors and READBACK time captured"
    else
        fail "phase D record: $(jq -c '.probe.drain' "${REPO_COPY}/acceptance-D.json" 2>/dev/null)"
    fi
    # A bad anchor run after a verified probe: no evidence is collected, but
    # the verified probe is cancelled and cleanup is verified.
    dir=$(sim_dir D-pass '{"runs.drain.api.path": ".github/workflows/rebalance-runners.yml"}' drain)
    run_evidence "$dir" "$(probe_inputs D ',"drain_run_id":"444"')"
    expect_evidence "phase D with a drain run from another workflow cancels the verified probe" $? 1 \
        "STEP Cancel the probe and verify cleanup: success" "REJECTED: drain run 444" '^gh run cancel 777 -R redducklabs/aurolegal.ai' \
        '^doctl|^kubectl get (pods|nodes|events)' "$dir"
    if grep -q 'STEP Capture evidence while the probe holds: skipped' "$SIM_OUT" && grep -q 'CLEANUP: clean' "$SIM_ERR"; then
        pass "phase D bad drain: no evidence collected; cleanup verified clean"
    else
        fail "phase D bad drain: $(steps_of)"
    fi
    dir=$(sim_dir D-pass '{"runs.drain.complete_at": 0, "runs.drain.api.conclusion": "failure"}' drain)
    run_evidence "$dir" "$(probe_inputs D ',"drain_run_id":"444"')"
    expect_evidence "phase D with a failed drain run cancels the verified probe" $? 1 \
        "STEP Cancel the probe and verify cleanup: success" "concluded 'failure'" '^gh run cancel 777' \
        '^doctl|^kubectl get (pods|nodes|events)' "$dir"
    # The drain completes five minutes after the last probe entry finished.
    local late
    late=$(python3 - "${FIXTURES}/D-pass.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta

evidence = json.load(open(sys.argv[1], encoding="utf-8"))
last = max(job["completed_at"] for job in evidence["probe"]["run"]["jobs"])
end = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ") + timedelta(minutes=5)
drain = evidence["probe"]["drain"]
steps = [{"name": "Drain runners", "conclusion": "success", "startedAt": drain["started"],
          "completedAt": end.strftime("%Y-%m-%dT%H:%M:%SZ")}]
print(json.dumps({"runs.drain.view_jobs": [{"name": "Drain Burst Runners", "databaseId": 4441,
                                            "conclusion": "success", "steps": steps}],
                  "runs.drain.complete_at": int((end - datetime(1970, 1, 1)).total_seconds()) + 30}))
PY
)
    dir=$(sim_dir D-pass "$late" drain)
    run_evidence "$dir" "$(probe_inputs D ',"drain_run_id":"444"')"
    expect_evidence "phase D fails when the probe exhausts its matrix before the drain completes" $? 1 - \
        "D-overlap-end" '^gh run cancel 777' - "$dir"

    # Phase C: Phase C evidence artifact plus measured jobs_killed.
    local phase_c='{"phase":"C","phase_c_run_id":"555","expected_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    dir=$(sim_dir C-pass-retired)
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C passes with jobs_killed measured as 0" $? 0 "STEP Cancel the probe and verify cleanup: skipped" \
        "✅ Phase C passed acceptance" '^gh run download 555 -R redducklabs/redducklabs-runners -n phase-c-evidence' "$READ_ONLY_VIOLATION|^gh run cancel" "$dir"
    if jq -e '.phase_c.jobs_killed == 0 and (.phase_c.jobs_killed_note | test("runner-acceptance-evidence"))' "${REPO_COPY}/acceptance-C.json" > /dev/null 2>&1; then
        pass "phase C record: jobs_killed replaced the script's null"
    else
        fail "phase C record: $(jq -c '.phase_c' "${REPO_COPY}/acceptance-C.json" 2>/dev/null)"
    fi
    # jobs_killed matches the scale-set runner-name prefix, not snapshot names.
    dir=$(sim_dir C-pass-retired '{"repo_runs": {"redducklabs/keel": [{"id": 91, "created_at": "2026-11-02T17:50:00Z", "updated_at": "2026-11-02T18:20:00Z"}]}, "extra_runs": {"k": {"repo": "redducklabs/keel", "id": 91, "jobs": [{"id": 9101, "runner_name": "redducklabs-runners-x7k2p-runner-abcde", "conclusion": "failure", "completed_at": "2026-11-02T18:05:00Z"}, {"id": 9102, "runner_name": "GitHub Actions 12", "conclusion": "failure", "completed_at": "2026-11-02T18:05:00Z"}]}}}')
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C fails when a fleet job failed during the run (hosted failures ignored)" $? 1 - "C-jobs-killed: 1 fleet job(s)" - - "$dir"
    # Runs are selected by the 65-day lookback, not a recent created_at: the
    # simulator applies the created filter, so a narrower query misses these.
    local run_list='^gh api --paginate --slurp repos/redducklabs/keel/actions/runs\?created=2026-08-29T18:00:00Z\.\.2026-11-02T18:10:00Z&per_page=100$'
    dir=$(sim_dir C-pass-retired '{"repo_runs": {"redducklabs/keel": [{"id": 92, "created_at": "2026-10-30T09:00:00Z", "updated_at": "2026-11-02T18:07:00Z", "run_attempt": 2}]}, "extra_runs": {"k": {"repo": "redducklabs/keel", "id": 92, "jobs": [{"id": 9201, "run_attempt": 1, "runner_name": "redducklabs-runners-x7k2p-runner-aaaaa", "conclusion": "success", "completed_at": "2026-10-30T09:20:00Z"}, {"id": 9202, "run_attempt": 2, "runner_name": "redducklabs-runners-x7k2p-runner-bbbbb", "conclusion": "failure", "completed_at": "2026-11-02T18:06:00Z"}]}}}')
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C fails when a run created three days earlier is re-run and its fleet job fails during Phase C" $? 1 - \
        "C-jobs-killed: 1 fleet job(s)" "$run_list" - "$dir"
    dir=$(sim_dir C-pass-retired '{"repo_runs": {"redducklabs/keel": [{"id": 93, "created_at": "2026-11-01T12:00:00Z", "updated_at": "2026-11-02T18:08:00Z", "run_attempt": 2}]}, "extra_runs": {"k": {"repo": "redducklabs/keel", "id": 93, "jobs": [{"id": 9301, "run_attempt": 1, "runner_name": "redducklabs-runners-x7k2p-runner-ccccc", "conclusion": "cancelled", "completed_at": "2026-11-02T18:04:00Z"}, {"id": 9302, "run_attempt": 2, "runner_name": "redducklabs-runners-x7k2p-runner-ddddd", "conclusion": "success", "completed_at": "2026-11-02T18:08:00Z"}]}}}')
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C fails when a killed attempt was superseded by a successful re-run (every attempt is read)" $? 1 - \
        "C-jobs-killed: 1 fleet job(s)" '^gh api --paginate --slurp repos/redducklabs/keel/actions/runs/93/jobs\?filter=all&per_page=100$' - "$dir"
    # More runs than the search cap in the lookback: the range is bisected
    # until each query is complete, and the re-run failure is still found.
    dir=$(sim_dir C-pass-retired '{"run_overflow": {"redducklabs/keel": {"over_seconds": 3456000, "total_count": 1500}}, "repo_runs": {"redducklabs/keel": [{"id": 92, "created_at": "2026-10-30T09:00:00Z", "updated_at": "2026-11-02T18:07:00Z", "run_attempt": 2}]}, "extra_runs": {"k": {"repo": "redducklabs/keel", "id": 92, "jobs": [{"id": 9202, "run_attempt": 2, "runner_name": "redducklabs-runners-x7k2p-runner-bbbbb", "conclusion": "failure", "completed_at": "2026-11-02T18:06:00Z"}]}}}')
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C bisects a run list over the search cap and still finds the failed fleet job" $? 1 - \
        "C-jobs-killed: 1 fleet job(s)" '^gh api --paginate --slurp repos/redducklabs/keel/actions/runs\?created=2026-10-01T06:05:00Z\.\.2026-11-02T18:10:00Z&per_page=100$' - "$dir"
    # A run last updated before Phase C cannot hold a job completed in it.
    dir=$(sim_dir C-pass-retired '{"repo_runs": {"redducklabs/keel": [{"id": 94, "created_at": "2026-10-23T10:00:00Z", "updated_at": "2026-10-24T10:00:00Z"}]}, "extra_runs": {"k": {"repo": "redducklabs/keel", "id": 94, "jobs": [{"id": 9401, "runner_name": "redducklabs-runners-x7k2p-runner-eeeee", "conclusion": "failure", "completed_at": "2026-10-24T10:00:00Z"}]}}}')
    run_evidence "$dir" "$phase_c"
    expect_evidence "phase C passes when the only failed fleet job ended before the run (its jobs are not read)" $? 0 - \
        "✅ Phase C passed acceptance" "$run_list" '^gh api --paginate --slurp repos/redducklabs/keel/actions/runs/94/jobs' "$dir"

    # Transient read errors during the watch are retried; persistent ones fail.
    dir=$(sim_dir A-pass '{"faults": {"kubectl get events -A -o json": 2}}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "a read that fails twice is retried and the phase passes" $? 0 - "RETRY: attempt 2/3" - - "$dir"
    dir=$(sim_dir A-pass '{"faults": {"kubectl get events -A -o json": 99}}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "a persistently failing read fails the watch and cancels the probe" $? 1 \
        "STEP Capture evidence while the probe holds: failure" "CLEANUP: clean" '^gh run cancel 777' - "$dir"

    # Pod specs (literal env values redacted) and container statuses are recorded;
    # an OOMKilled container fails the phase.
    dir=$(sim_dir A-container-oomkilled)
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A with an OOMKilled container fails runner-health" $? 1 - "runner-health: container ar8/dind was OOMKilled" \
        '^gh run cancel 777' - "$dir"
    if jq -e '[.pods[] | select(.runner_name == "ar8") | .container_statuses[] | select(.name == "dind")][0]
              | .last_terminated_reason == "OOMKilled" and .last_terminated_exit_code == 137' "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1 \
        && jq -e '[.pods[].spec.containers[0].env[]] | (map(select(.name == "LITERAL_SETTING"))[0].value == "<redacted>")
              and (map(select(.name == "FROM_REF"))[0].valueFrom.secretKeyRef.name == "ref")' "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1 \
        && ! grep -q 'literal-env-value-must-not-appear' "${REPO_COPY}/acceptance-A.json" \
        && ! grep -q 'kernel log text' "${REPO_COPY}/acceptance-A.json"; then
        pass "record: pod spec captured with literal env values redacted and valueFrom kept; container statuses carry OOMKilled/137; no termination message"
    else
        fail "record: spec/statuses not captured as required"
    fi
    # Health events: only runner pods/nodes inside the phase window count;
    # the others stay in the record as diagnostics.
    local oom_event='{"metadata": {"uid": "ev-oom", "namespace": "default"}, "reason": "OOMKilling", "type": "Warning", "message": "Memory cgroup out of memory", "involvedObject": {"kind": "Node", "name": "%s"}, "firstTimestamp": "%s", "lastTimestamp": "%s", "count": 1}'
    dir=$(sim_dir A-pass "{\"events\": [$(printf "$oom_event" worker-pool-x1y2z 2026-11-02T18:10:00Z 2026-11-02T18:10:00Z)]}")
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A passes with a worker-node OOM event (diagnostic only)" $? 0 - "✅ Phase A passed acceptance" - - "$dir"
    if jq -e '[.events[] | select(.uid == "ev-oom" and .involved_name == "worker-pool-x1y2z")] | length == 1' "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1 \
        && jq -e '.verdict.notes | any(startswith("runner-health: diagnostic only"))' "${REPO_COPY}/acceptance-A.json" > /dev/null 2>&1; then
        pass "phase A record: the worker-node OOM event is kept and reported as a diagnostic"
    else
        fail "phase A record: worker-node OOM event $(jq -c '{events, notes: .verdict.notes}' "${REPO_COPY}/acceptance-A.json" 2>/dev/null | head -c 300)"
    fi
    dir=$(sim_dir A-pass "{\"events\": [$(printf "$oom_event" baseline-a 2026-11-02T17:10:00Z 2026-11-02T17:12:00Z)]}")
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A passes with a runner-node OOM event that ended before the probe run" $? 0 - "✅ Phase A passed acceptance" - - "$dir"
    dir=$(sim_dir A-pass "{\"events\": [$(printf "$oom_event" p2 2026-11-02T18:10:00Z 2026-11-02T18:10:00Z)]}")
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A fails runner-health with a runner-node OOM event inside the phase" $? 1 - "runner-health: OOMKilling event on Node p2" \
        '^gh run cancel 777' - "$dir"

    # Phase E: READY_FOR_MIGRATION output.
    dir=$(sim_dir E-pass)
    run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
    expect_evidence "phase E passes and reports READY_FOR_MIGRATION=true" $? 0 "OUTPUT evidence.ready_for_migration=true" \
        "READY_FOR_MIGRATION=true" - "$READ_ONLY_VIOLATION" "$dir"
    if jq -e '.latest_collection_at != null and (.warm_after | length) == 2
              and all(.warm_after[]; .observed_at == $latest and .ready == true and .terminating == false and .idle == true)' \
        --arg latest "$(jq -r '.latest_collection_at' "${REPO_COPY}/acceptance-E.json" 2>/dev/null)" \
        "${REPO_COPY}/acceptance-E.json" > /dev/null 2>&1; then
        pass "phase E record: warm_after observed in the final collection (latest_collection_at), Ready, not terminating, idle"
    else
        fail "phase E record: $(jq -c '{latest_collection_at, warm_after}' "${REPO_COPY}/acceptance-E.json" 2>/dev/null)"
    fi
    # Warm runners seen earlier in the phase but not current, Ready and
    # non-terminating at finalization never authorize migration.
    while IFS='|' read -r label override; do
        [ -n "$label" ] || continue
        dir=$(sim_dir E-pass "$override")
        run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
        expect_evidence "phase E fails E-warm when ${label} before finalization" $? 1 "OUTPUT evidence.ready_for_migration=false" \
            "E-warm:" - "$READ_ONLY_VIOLATION" "$dir"
    done <<'CASES'
every runner pod and EphemeralRunner disappears (empty latest lists)|{"changes": [{"at": "2026-11-02T18:15:00Z", "kind": "pods", "name": "*", "remove": true}, {"at": "2026-11-02T18:15:00Z", "kind": "ephemeral_runners", "name": "*", "remove": true}]}
a warm runner pod becomes unready|{"changes": [{"at": "2026-11-02T18:15:00Z", "kind": "pods", "name": "w1", "merge": {"status": {"conditions": [{"type": "Ready", "status": "False"}]}}}]}
a warm runner pod begins terminating|{"changes": [{"at": "2026-11-02T18:15:00Z", "kind": "pods", "name": "w1", "merge": {"metadata": {"deletionTimestamp": "2026-11-02T18:15:00Z"}}}]}
a warm EphemeralRunner begins terminating|{"changes": [{"at": "2026-11-02T18:15:00Z", "kind": "ephemeral_runners", "name": "w2", "merge": {"metadata": {"deletionTimestamp": "2026-11-02T18:15:00Z"}}}]}
CASES
    dir=$(sim_dir E-trust-failed)
    printf '#!/bin/bash\necho "ERROR: runner-group readback failed" >&2\nexit 1\n' > "${dir}/trust"
    run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
    expect_evidence "phase E with a failed trust readback reports READY_FOR_MIGRATION=false" $? 1 "OUTPUT evidence.ready_for_migration=false" \
        "E-trust" - - "$dir"
    # READY_FOR_MIGRATION=false whenever finalize (and so the verdict) never ran.
    dir=$(sim_dir E-pass '{"faults": {"kubectl get configmap cluster-autoscaler-priority-expander -n kube-system -o json": 99}}')
    run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
    expect_evidence "phase E reports READY_FOR_MIGRATION=false when finalize fails" $? 1 "OUTPUT evidence.ready_for_migration=false" \
        "READY_FOR_MIGRATION=false" - - "$dir"
    if grep -q 'STEP Evaluate acceptance verdict: skipped' "$SIM_OUT" && grep -q 'STEP Report migration readiness: success' "$SIM_OUT"; then
        pass "phase E: readiness step ran although the verdict was skipped"
    else
        fail "phase E readiness: $(steps_of)"
    fi
    # A rollback run that has not completed, or no passing Phase A record, is rejected.
    dir=$(sim_dir E-pass '{"runs.rollback.complete_at": null}')
    run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
    expect_evidence "phase E rejects a rollback run that has not completed" $? 1 - "rollback run 333 has not completed" '^gh run cancel 777' - "$dir"
    dir=$(sim_dir E-pass '{"artifacts.222/acceptance-A": {"phase": "A", "verdict": {"pass": false}, "pools_before": {}}}')
    run_evidence "$dir" "$(probe_inputs E ',"rollback_run_id":"333","baseline_run_id":"222"')"
    expect_evidence "phase E rejects a baseline run without a passing Phase A record" $? 1 - "does not hold a passing Phase A record" - - "$dir"
}

# ---------------------------------------------------------------------------
# Job log normalization (Ruling 42)
# ---------------------------------------------------------------------------

assert_job_log_normalization() {
    info "Checking job log escape normalization..."
    if (cd "$REPO_ROOT" && python3 -B - scripts/acceptance-evidence.py) <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("acceptance_evidence", sys.argv[1])
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
ESC = "\x1b"
payload = {"pass": True, "targets": {}, "results": []}
colored = (f"2026-11-02T18:20:20.2000000Z {ESC}[32mNETWORK_PROBE{ESC}[1m_RESULT{ESC}[0m "
           f"{ESC}[33m{{{ESC}[0m{json.dumps(payload)[1:]}{ESC}[0m\n"
           f"{ESC}[0m2026-11-02T18:31:00.2000000Z {ESC}[1;32mREAD{ESC}[0;32mBACK:{ESC}[0m ARC is drain 2/4{ESC}[0m\n")


def parse(text):
    """The collector's two parsers over a log text."""
    result, effective = None, None
    for line in text.splitlines():
        index = line.find(evidence.NETWORK_PROBE_MARKER)
        if index >= 0:
            result = json.loads(line[index + len(evidence.NETWORK_PROBE_MARKER):].strip())
        if evidence.DRAIN_READBACK in line:
            effective = evidence.trim_ts(line.split(" ", 1)[0])
    return result, effective


def logs_of(text):
    evidence.run = lambda argv: text
    return evidence.job_logs("redducklabs/aurolegal.ai", 1)


# Stripped, both records parse; unstripped (stripping removed), neither does.
assert parse(logs_of(colored)) == (payload, "2026-11-02T18:31:00Z"), parse(logs_of(colored))
assert parse(colored) == (None, None), parse(colored)
# Escapes the CSI normalization does not cover fail the read (fail closed).
for bad in (f"x {ESC}]8;;https://example.invalid{ESC}\\link{ESC}]8;;{ESC}\\ y\n",
            f"x {ESC}]0;title\a NETWORK_PROBE_RESULT {{}}\n", f"x {ESC} y\n", f"x {ESC}[\n"):
    try:
        logs_of(bad)
    except evidence.ReadError as error:
        assert "unsupported terminal escape sequence" in str(error), error
    else:
        raise AssertionError(f"accepted {bad!r}")
PY
    then
        pass "job logs: CSI escapes inside markers, payload and timestamp are stripped before parsing (unstripped text does not parse); OSC, lone and truncated escapes fail the read"
    else
        fail "job log normalization"
    fi

    # End to end: an OSC sequence in the network-probe log fails the evidence step.
    local dir
    dir=$(sim_dir A-pass '{"logs.9100": "2026-11-02T18:20:20.2000000Z \u001b]0;title\u0007NETWORK_PROBE_RESULT {\"pass\": true}\n"}')
    run_evidence "$dir" "$(probe_inputs A)"
    expect_evidence "phase A evidence fails on an unsupported escape in a job log" $? 1 - \
        "contains an unsupported terminal escape sequence" '^gh run cancel 777' "$READ_ONLY_VIOLATION" "$dir"
}

assert_verdict_fixtures
assert_evidence_workflow_static
assert_job_log_normalization
assert_evidence_workflow_runs

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All acceptance checks passed${NC}"
    exit 0
fi
echo -e "${RED}${FAILURES} acceptance check(s) failed${NC}"
exit 1
