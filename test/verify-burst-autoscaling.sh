#!/bin/bash

# Offline verification for the runner burst-autoscaling change.
#
# Sections are appended by later tasks. Everything here runs without cluster,
# DigitalOcean, or GitHub access: external CLIs are replaced by fakes (see
# with_fakes) that print canned files from a fixture directory.
#
# Usage: ./test/verify-burst-autoscaling.sh

set -uo pipefail

# Windows CreateProcess (used by Python's subprocess under Git Bash/MSYS/Cygwin)
# ignores the extensionless fakes and would resolve the real doctl/kubectl/helm
# on the Windows PATH, i.e. live production reads with the user's credentials.
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        echo "ERROR: verify-burst-autoscaling.sh must not run under Git Bash/MSYS/Cygwin:" >&2
        echo "       the CLI fakes do not shadow the real tools there. Run it in WSL against an" >&2
        echo "       LF clone, as described in CLAUDE.md (\"Running the test suites locally on Windows\")." >&2
        exit 2
        ;;
esac

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${REPO_ROOT}/scripts/validate-runner-isolation-contract.py"
FIXTURES="${SCRIPT_DIR}/fixtures"
DOCTL_ENCODER="${FIXTURES}/doctl_encoding.py"

FAILURES=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }

# with_fakes <fixture-dir> <command...>
# Runs <command> with a temp dir of fake doctl/kubectl/helm/gh binaries first
# on PATH. Every invocation's arguments are appended to
# "<fixture-dir>/<tool>.calls".
#
# If "<fixture-dir>/<tool>.routes" exists, each line is "<glob>|<file>": the
# first glob matching the full argument string selects "<fixture-dir>/<file>"
# to print (exit 1 if that file is missing; exit code from "<file>.rc" if
# present). A call matching no route exits 97 with "unexpected call" on
# stderr, so an unplanned command fails loudly instead of reading stale data.
#
# Without a routes file, the fake prints "<fixture-dir>/<tool>.out" (if
# present) and exits with the code in "<fixture-dir>/<tool>.rc" (default 0).
#
# doctl node-pool list output is printed in doctl's live encoding: a zero
# count/min_nodes/max_nodes, a false auto_scale and an empty nodes list are
# omitted (test/fixtures/doctl_encoding.py, Ruling 39). Fixture files keep the
# explicit values; a "doctl-pools-verbatim" marker in <fixture-dir> serves
# them as written.
#
# If "<fixture-dir>/stateful" exists, it names a hook script that runs first as
# "python3 -B <hook> <fixture-dir> <tool> <args...>". The hook may rewrite fixture
# files (so a mutation changes what the next read returns); exit 100 falls
# through to the routes, any other exit code is the fake's result.
#
# Safety: before running <command>, every tool must resolve (as Python's
# shutil.which sees it, i.e. as the Python helpers will exec it) to the fake;
# otherwise with_fakes prints an error and returns 98 without running it. The
# command runs with credentials scrubbed (KUBECONFIG=/nonexistent, no
# DigitalOcean/GitHub tokens, HOME and XDG_CONFIG_HOME in a temp dir), so even
# a resolution bug cannot reach a real account.
with_fakes() {
    local fixture_dir=$1
    shift
    local fake_dir fake_home tool resolved
    fake_dir="$(mktemp -d "${WORK_DIR}/fakes.XXXXXX")"
    fake_home="$(mktemp -d "${WORK_DIR}/home.XXXXXX")"
    for tool in doctl kubectl helm gh; do
        {
            printf '#!/bin/bash\n'
            printf 'FIXTURE_DIR=%q\nTOOL=%q\nPOOL_ENCODER=%q\n' "$fixture_dir" "$tool" "$DOCTL_ENCODER"
            cat <<'FAKE'
printf '%s\n' "$*" >> "${FIXTURE_DIR}/${TOOL}.calls"
args="$*"
# serve <file>: node-pool list JSON leaves the doctl fake in doctl's live
# encoding (zero count/min_nodes/max_nodes, false auto_scale and empty nodes
# omitted, Ruling 39) unless the fixture dir holds "doctl-pools-verbatim".
serve() {
    case "${TOOL} ${args}" in
        "doctl kubernetes cluster node-pool list "*)
            if [ ! -f "${FIXTURE_DIR}/doctl-pools-verbatim" ]; then
                python3 -B "$POOL_ENCODER" "$1"
                return
            fi
            ;;
    esac
    cat "$1"
}
if [ -f "${FIXTURE_DIR}/stateful" ]; then
    python3 -B "$(cat "${FIXTURE_DIR}/stateful")" "$FIXTURE_DIR" "$TOOL" "$@"
    rc=$?
    [ "$rc" -eq 100 ] || exit "$rc"
fi
if [ -f "${FIXTURE_DIR}/${TOOL}.routes" ]; then
    while IFS='|' read -r pattern file; do
        [ -n "$pattern" ] || continue
        # shellcheck disable=SC2254 # the route is a glob by design
        case "$args" in
            $pattern)
                if [ ! -f "${FIXTURE_DIR}/${file}" ]; then
                    echo "fake ${TOOL}: no fixture ${file}" >&2
                    exit 1
                fi
                serve "${FIXTURE_DIR}/${file}"
                rc=0
                [ -f "${FIXTURE_DIR}/${file}.rc" ] && rc=$(cat "${FIXTURE_DIR}/${file}.rc")
                exit "$rc"
                ;;
        esac
    done < "${FIXTURE_DIR}/${TOOL}.routes"
    echo "fake ${TOOL}: unexpected call: ${args}" >&2
    exit 97
fi
[ -f "${FIXTURE_DIR}/${TOOL}.out" ] && serve "${FIXTURE_DIR}/${TOOL}.out"
rc=0
[ -f "${FIXTURE_DIR}/${TOOL}.rc" ] && rc=$(cat "${FIXTURE_DIR}/${TOOL}.rc")
exit "$rc"
FAKE
        } > "${fake_dir}/${tool}"
        chmod +x "${fake_dir}/${tool}"
    done
    for tool in doctl kubectl helm gh; do
        resolved=$(PATH="${fake_dir}:${PATH}" python3 -c 'import shutil, sys; print(shutil.which(sys.argv[1]))' "$tool")
        if [ "$resolved" != "${fake_dir}/${tool}" ]; then
            echo "with_fakes: ${tool} resolves to '${resolved}', not the fake in ${fake_dir}; refusing to run" >&2
            return 98
        fi
    done
    env -u DIGITALOCEAN_ACCESS_TOKEN -u DO_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
        KUBECONFIG=/nonexistent HOME="$fake_home" XDG_CONFIG_HOME="$fake_home" \
        PATH="${fake_dir}:${PATH}" "$@"
}

# check <contract> <min> <max> <group> <values-file>
# Returns 0 on validator exit 0, 1 on a genuine mismatch (exit 1 with an
# "ERROR:" line), and 2 for anything else (usage error, crash).
check() {
    local contract=$1 min=$2 max=$3 group=$4 file=$5 rc errors
    errors="${WORK_DIR}/validator-stderr"
    python "$VALIDATOR" --contract "$contract" --kind values \
        --min-runners "$min" --max-runners "$max" --runner-group "$group" \
        < "$file" > /dev/null 2> "$errors"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 1 ] && grep -q '^ERROR:' "$errors"; then return 1; fi
    return 2
}

expect_accept() {  # description, then check args
    local description=$1
    shift
    check "$@"
    [ "$?" -eq 0 ] && pass "accepted: ${description}" || fail "not accepted: ${description}"
}

expect_reject() {
    local description=$1
    shift
    check "$@"
    [ "$?" -eq 1 ] && pass "rejected: ${description}" || fail "not rejected with a validator ERROR: ${description}"
}

# mutate <source-values> <output> <python-statements operating on `doc`>
mutate() {
    python - "$1" "$2" "$3" <<'PY'
import sys
import yaml

source, output, statements = sys.argv[1:]
with open(source, encoding="utf-8") as stream:
    doc = yaml.safe_load(stream)
exec(statements)
with open(output, "w", encoding="utf-8") as stream:
    yaml.safe_dump(doc, stream, sort_keys=False)
PY
}

assert_with_fakes_selftest() {
    info "Checking the with_fakes helper..."
    local dir="${WORK_DIR}/selftest"
    mkdir -p "$dir"
    printf 'canned-output\n' > "${dir}/doctl.out"
    printf '3\n' > "${dir}/kubectl.rc"
    local out
    out=$(with_fakes "$dir" doctl kubernetes cluster list)
    [ "$out" = "canned-output" ] && pass "fake doctl prints the canned file" || fail "fake doctl output was '$out'"
    with_fakes "$dir" kubectl get pods
    [ "$?" -eq 3 ] && pass "fake kubectl returns its canned exit code" || fail "fake kubectl exit code was not 3"
    grep -qx 'kubernetes cluster list' "${dir}/doctl.calls" \
        && pass "fake doctl records its arguments" || fail "fake doctl did not record its arguments"

    local routed="${WORK_DIR}/selftest-routes"
    mkdir -p "$routed"
    printf 'get nodes -o json|nodes.json\nget pods *|pods.json\n' > "${routed}/kubectl.routes"
    printf 'node-list\n' > "${routed}/nodes.json"
    printf 'pod-list\n' > "${routed}/pods.json"
    printf '4\n' > "${routed}/pods.json.rc"
    out=$(with_fakes "$routed" kubectl get nodes -o json)
    [ "$out" = "node-list" ] && pass "routed fake selects the file for its arguments" || fail "routed fake printed '$out'"
    out=$(with_fakes "$routed" kubectl get pods -A -o json)
    [ "$?" -eq 4 ] && [ "$out" = "pod-list" ] \
        && pass "routed fake honours a per-file exit code" || fail "routed fake ignored pods.json.rc"
    with_fakes "$routed" kubectl delete node x 2>/dev/null
    [ "$?" -eq 97 ] && pass "routed fake rejects an unplanned call" || fail "routed fake accepted an unplanned call"

    local tool resolved
    for tool in doctl kubectl helm gh; do
        resolved=$(with_fakes "$routed" python3 -c 'import shutil, sys; print(shutil.which(sys.argv[1]))' "$tool")
        case "$resolved" in
            "${WORK_DIR}"/fakes.*/"${tool}") pass "python resolves ${tool} to the fake" ;;
            *) fail "python resolves ${tool} to '${resolved}', not the fake" ;;
        esac
    done
    out=$(DO_TOKEN=leak GITHUB_TOKEN=leak GH_TOKEN=leak DIGITALOCEAN_ACCESS_TOKEN=leak KUBECONFIG="$HOME/.kube/config" \
        with_fakes "$routed" bash -c 'printf "%s|%s|%s|%s|%s|%s|%s" "${DO_TOKEN-}" "${GITHUB_TOKEN-}" "${GH_TOKEN-}" "${DIGITALOCEAN_ACCESS_TOKEN-}" "$KUBECONFIG" "$HOME" "$XDG_CONFIG_HOME"')
    case "$out" in
        "||||/nonexistent|${WORK_DIR}/home."*"|${WORK_DIR}/home."*) pass "fakes run with tokens unset, KUBECONFIG=/nonexistent and a temp HOME" ;;
        *) fail "fakes did not scrub credentials: '${out}'" ;;
    esac
    with_fakes "$routed" true
    [ "$?" -eq 0 ] && pass "with_fakes runs the command when every tool resolves to a fake" || fail "with_fakes refused a safe run"
}

assert_burst_contracts() {
    info "Checking burst, burst-acceptance and drain contracts..."
    local burst="${FIXTURES}/arc-burst-values.yaml"
    local drain="${FIXTURES}/arc-drain-values.yaml"
    local legacy="${FIXTURES}/arc-legacy-isolated-values.yaml"
    local density="${REPO_ROOT}/deploy/density-values.yaml"
    local tmp="${WORK_DIR}/mutated.yaml"

    expect_accept "burst fixture as burst 2/20 private" burst 2 20 private "$burst"
    expect_reject "burst fixture as burst 2/4" burst 2 4 private "$burst"
    expect_reject "burst fixture as burst on the default group" burst 2 20 default "$burst"

    local min
    for min in 8 4 2 6; do
        mutate "$burst" "${WORK_DIR}/acceptance-${min}.yaml" "doc['minRunners'] = ${min}"
    done
    expect_accept "burst-acceptance 8/20" burst-acceptance 8 20 private "${WORK_DIR}/acceptance-8.yaml"
    expect_accept "burst-acceptance 4/20" burst-acceptance 4 20 private "${WORK_DIR}/acceptance-4.yaml"
    expect_reject "burst-acceptance 2/20" burst-acceptance 2 20 private "${WORK_DIR}/acceptance-2.yaml"
    expect_reject "burst-acceptance 6/20" burst-acceptance 6 20 private "${WORK_DIR}/acceptance-6.yaml"
    mutate "$burst" "$tmp" "doc['minRunners'] = 8; doc['maxRunners'] = 10"
    expect_reject "burst-acceptance 8/10" burst-acceptance 8 10 private "$tmp"
    expect_reject "burst fixture 8/20 as burst" burst 8 20 private "${WORK_DIR}/acceptance-8.yaml"

    mutate "$burst" "$tmp" 'del doc["template"]["metadata"]'
    expect_reject "burst without the safe-to-evict annotation" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" 'doc["template"]["metadata"]["annotations"]["cluster-autoscaler.kubernetes.io/safe-to-evict"] = "true"'
    expect_reject "burst with safe-to-evict true" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" 'doc["template"]["spec"]["affinity"]["nodeAffinity"]["preferredDuringSchedulingIgnoredDuringExecution"][0]["weight"] = 50'
    expect_reject "burst with affinity weight 50" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" 'doc["template"]["spec"]["affinity"] = {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [{"key": "doks.digitalocean.com/node-pool", "operator": "In", "values": ["github-runners-pool-16g"]}]}]}}}'
    expect_reject "burst with required instead of preferred affinity" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" 'del doc["template"]["spec"]["affinity"]'
    expect_reject "burst without affinity" burst 2 20 private "$tmp"

    expect_accept "drain fixture as drain 2/4" drain 2 4 private "$drain"
    expect_reject "drain 2/20" drain 2 20 private "$drain"
    expect_reject "drain fixture checked as burst" burst 2 4 private "$drain"
    mutate "$drain" "$tmp" 'doc["template"]["spec"]["affinity"] = {"nodeAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "preference": {"matchExpressions": [{"key": "doks.digitalocean.com/node-pool", "operator": "In", "values": ["github-runners-pool-16g"]}]}}]}}'
    expect_reject "drain with preferred affinity" drain 2 4 private "$tmp"
    mutate "$drain" "$tmp" 'del doc["template"]["metadata"]'
    expect_reject "drain without the annotation" drain 2 4 private "$tmp"

    local mirror='--registry-mirror=https://mirror.gcr.io'
    local dind_args_fn="dind_args = lambda d: [c for c in d['template']['spec']['initContainers'] if c['name'] == 'dind'][0]['args']; "
    mutate "$burst" "$tmp" "${dind_args_fn}dind_args(doc)[-1] = '--registry-mirror=https://example.invalid'"
    expect_reject "burst with a different registry mirror" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${dind_args_fn}dind_args(doc).remove('${mirror}')"
    expect_reject "burst without the registry mirror flag" burst 2 20 private "$tmp"
    mutate "${WORK_DIR}/acceptance-8.yaml" "$tmp" "${dind_args_fn}dind_args(doc).remove('${mirror}')"
    expect_reject "burst-acceptance 8/20 without the registry mirror flag" burst-acceptance 8 20 private "$tmp"
    mutate "${WORK_DIR}/acceptance-4.yaml" "$tmp" "${dind_args_fn}dind_args(doc).remove('${mirror}')"
    expect_reject "burst-acceptance 4/20 without the registry mirror flag" burst-acceptance 4 20 private "$tmp"
    mutate "$drain" "$tmp" "${dind_args_fn}dind_args(doc).remove('${mirror}')"
    expect_reject "drain without the registry mirror flag" drain 2 4 private "$tmp"
    mutate "$burst" "$tmp" "${dind_args_fn}dind_args(doc).append('${mirror}')"
    expect_reject "burst with a duplicated registry mirror flag" burst 2 20 private "$tmp"
    mutate "$density" "$tmp" "${dind_args_fn}dind_args(doc).append('${mirror}')"
    expect_reject "density with the registry mirror flag" density 2 4 private "$tmp"
    mutate "$legacy" "$tmp" "${dind_args_fn}dind_args(doc).append('${mirror}')"
    expect_reject "legacy-isolated with the registry mirror flag" legacy-isolated 2 8 default "$tmp"
    if python - "$burst" "$drain" "${REPO_ROOT}/deploy/dind-values.yaml" "$density" <<'PY'
import sys
import yaml

want = ["dockerd", "--host=unix:///var/run/docker.sock",
        "--group=$(DOCKER_GROUP_GID)", "--registry-mirror=https://mirror.gcr.io"]


def dind_args(path):
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    containers = doc["template"]["spec"]["initContainers"]
    return [c for c in containers if c["name"] == "dind"][0]["args"]


for path in sys.argv[1:4]:
    if dind_args(path) != want:
        raise SystemExit(f"{path}: dind args {dind_args(path)} != {want}")
if dind_args(sys.argv[4]) != want[:3]:
    raise SystemExit("density fixture must not carry the registry mirror")
PY
    then
        pass "burst, drain and deploy values carry exactly the mirror dind args; density does not"
    else
        fail "dind registry-mirror args are not exact across fixtures"
    fi

    if python - "${REPO_ROOT}/.github/workflows/deploy-runners.yml" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
pattern = (
    r'"dockerd", "--host=unix:///var/run/docker\.sock", "--group=\$\(DOCKER_GROUP_GID\)",\s*'
    r'"--registry-mirror=https://mirror\.gcr\.io",\s*\]:'
)
if not re.search(pattern, text):
    raise SystemExit("Deploy admission check does not require the registry mirror dind arg")
PY
    then
        pass "Deploy admission check requires the registry mirror dind arg"
    else
        fail "Deploy admission check does not require the registry mirror dind arg"
    fi

    # Shared actions/setup-* tool cache (burst family only). Container jobs
    # bind-mount the runner's tool directory through the DinD daemon, so the
    # same volume must back RUNNER_TOOL_CACHE in the runner and the same path
    # in dind; otherwise dockerd creates a root-owned directory of its own that
    # a non-root (--user 1001:121) job container cannot write.
    local tc_fns="by = lambda d, n: [c for c in d['template']['spec']['initContainers'] + d['template']['spec']['containers'] if c['name'] == n][0]; "
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'dind')['volumeMounts'] = [m for m in by(doc, 'dind')['volumeMounts'] if m['name'] != 'tool-cache']"
    expect_reject "burst without the dind tool-cache mount (container jobs get a root-owned tool dir)" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'dind')['volumeMounts'][-1]['mountPath'] = '/opt/toolcache'"
    expect_reject "burst with the dind tool-cache mount at a different path" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'runner')['volumeMounts'] = [m for m in by(doc, 'runner')['volumeMounts'] if m['name'] != 'tool-cache']"
    expect_reject "burst without the runner tool-cache mount" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'runner')['env'] = [e for e in by(doc, 'runner')['env'] if e['name'] != 'RUNNER_TOOL_CACHE']"
    expect_reject "burst without RUNNER_TOOL_CACHE" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'runner')['env'] = [e for e in by(doc, 'runner')['env'] if e['name'] != 'AGENT_TOOLSDIRECTORY']"
    expect_reject "burst without AGENT_TOOLSDIRECTORY" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "${tc_fns}by(doc, 'runner')['env'][-1]['value'] = '/home/runner/_work/_tool'"
    expect_reject "burst with AGENT_TOOLSDIRECTORY off the shared tool cache" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "doc['template']['spec']['volumes'] = [v for v in doc['template']['spec']['volumes'] if v['name'] != 'tool-cache']"
    expect_reject "burst without the tool-cache volume" burst 2 20 private "$tmp"
    mutate "$burst" "$tmp" "doc['template']['spec']['volumes'][-1]['emptyDir'] = {'medium': 'Memory'}"
    expect_reject "burst with a memory-backed tool cache (counts against the pod memory budget)" burst 2 20 private "$tmp"
    mutate "$drain" "$tmp" "doc['template']['spec']['volumes'] = [v for v in doc['template']['spec']['volumes'] if v['name'] != 'tool-cache']"
    expect_reject "drain without the tool-cache volume" drain 2 4 private "$tmp"
    mutate "${WORK_DIR}/acceptance-8.yaml" "$tmp" "${tc_fns}by(doc, 'dind')['volumeMounts'] = [m for m in by(doc, 'dind')['volumeMounts'] if m['name'] != 'tool-cache']"
    expect_reject "burst-acceptance 8/20 without the dind tool-cache mount" burst-acceptance 8 20 private "$tmp"
    # Transition variant: the live burst release predates the tool cache until
    # Deploy `deploy` applies it, so the exact pre-tool-cache template (all
    # tool-cache parts absent together) must still classify; partial ones above
    # must not.
    local strip_tc="${tc_fns}spec = doc['template']['spec']; spec['volumes'] = [v for v in spec['volumes'] if v['name'] != 'tool-cache']; by(doc, 'dind')['volumeMounts'] = [m for m in by(doc, 'dind')['volumeMounts'] if m['name'] != 'tool-cache']; by(doc, 'runner')['volumeMounts'] = [m for m in by(doc, 'runner')['volumeMounts'] if m['name'] != 'tool-cache']; by(doc, 'runner')['env'] = [e for e in by(doc, 'runner')['env'] if e['name'] not in ('RUNNER_TOOL_CACHE', 'AGENT_TOOLSDIRECTORY')]"
    mutate "$burst" "$tmp" "$strip_tc"
    expect_accept "pre-tool-cache burst release as burst 2/20 (transition)" burst 2 20 private "$tmp"
    mutate "${WORK_DIR}/acceptance-8.yaml" "$tmp" "$strip_tc"
    expect_accept "pre-tool-cache burst release as burst-acceptance 8/20 (transition)" burst-acceptance 8 20 private "$tmp"
    mutate "$drain" "$tmp" "$strip_tc"
    expect_accept "pre-tool-cache drain release as drain 2/4 (transition)" drain 2 4 private "$tmp"
    mutate "$burst" "$tmp" "${strip_tc}; doc['minRunners'] = 0; doc['maxRunners'] = 0"
    expect_accept "pre-tool-cache burst release stopped as burst-stopped (transition)" burst-stopped 0 0 private "$tmp"
    mutate "$burst" "$tmp" "${strip_tc}; by(doc, 'runner')['env'] += [{'name': 'RUNNER_TOOL_CACHE', 'value': '/opt/hostedtoolcache'}]"
    expect_reject "pre-tool-cache burst with only RUNNER_TOOL_CACHE (dind cannot see it)" burst 2 20 private "$tmp"
    mutate "$density" "$tmp" "${tc_fns}by(doc, 'runner')['env'] += [{'name': 'RUNNER_TOOL_CACHE', 'value': '/opt/hostedtoolcache'}]"
    expect_reject "density with RUNNER_TOOL_CACHE" density 2 4 private "$tmp"
    mutate "$legacy" "$tmp" "doc['template']['spec']['volumes'] += [{'name': 'tool-cache', 'emptyDir': {}}]"
    expect_reject "legacy-isolated with the tool-cache volume" legacy-isolated 2 8 default "$tmp"

    # Non-root container-job tool-cache probe, on the values and on the
    # rendered/live fixtures: the runner's tool directory must be backed by a
    # plain emptyDir (kubelet mode 0777, writable by uid 1001 without a root
    # init container or fsGroup) mounted at that same path in dind, which is
    # where dockerd resolves the `-v <tool dir>:/__t` bind of a container job.
    # Density must keep the runner default <work>/_tool on the shared work
    # volume (no tool-cache env or volume), which dind also mounts.
    if python - "$burst" "$drain" "${REPO_ROOT}/deploy/dind-values.yaml" \
        "${FIXTURES}/pool-state/arc-burst/helm-values.json" \
        "${FIXTURES}/pool-state/arc-burst/asrs.json" \
        "${FIXTURES}/pool-state/arc-drain/asrs.json" \
        "${FIXTURES}/pool-state/arc-burst-acceptance-8/asrs.json" \
        "${FIXTURES}/pool-state/arc-burst/helm-manifest.yaml" \
        -- "$density" "${FIXTURES}/pool-state/arc-density/asrs.json" <<'PY'
import json
import sys

import yaml


def spec_of(path):
    with open(path, encoding="utf-8") as stream:
        if path.endswith(".json"):
            doc = json.load(stream)
            if "items" in doc:
                return doc["items"][0]["spec"]["template"]["spec"]
            return doc["template"]["spec"]
        if path.endswith("helm-manifest.yaml"):
            docs = [d for d in yaml.safe_load_all(stream) if isinstance(d, dict)]
            asrs = [d for d in docs if d.get("kind") == "AutoscalingRunnerSet"][0]
            return asrs["spec"]["template"]["spec"]
        return yaml.safe_load(stream)["template"]["spec"]


def container(spec, name):
    return [c for c in spec["initContainers"] + spec["containers"] if c["name"] == name][0]


def mounts(c):
    return {m["mountPath"]: m["name"] for m in c.get("volumeMounts", [])}


split = sys.argv.index("--")
for path in sys.argv[1:split]:
    spec = spec_of(path)
    runner, dind = container(spec, "runner"), container(spec, "dind")
    env = {e["name"]: e.get("value") for e in runner["env"]}
    tool_dir = env.get("RUNNER_TOOL_CACHE")
    if tool_dir != "/opt/hostedtoolcache" or env.get("AGENT_TOOLSDIRECTORY") != tool_dir:
        raise SystemExit(f"{path}: tool cache env is {env}")
    volume = mounts(runner).get(tool_dir)
    if volume is None or mounts(dind).get(tool_dir) != volume:
        raise SystemExit(f"{path}: {tool_dir} is not the same volume in runner and dind")
    source = [v for v in spec["volumes"] if v["name"] == volume]
    if source != [{"emptyDir": {}, "name": volume}]:
        raise SystemExit(f"{path}: tool-cache volume is {source}, not a plain emptyDir")
    if "securityContext" in spec and "fsGroup" in spec["securityContext"]:
        raise SystemExit(f"{path}: tool cache must not rely on a pod fsGroup")
for path in sys.argv[split + 1:]:
    spec = spec_of(path)
    runner, dind = container(spec, "runner"), container(spec, "dind")
    names = {e["name"] for e in runner["env"]}
    if names & {"RUNNER_TOOL_CACHE", "RUNNER_TOOLSDIRECTORY", "AGENT_TOOLSDIRECTORY"}:
        raise SystemExit(f"{path}: density must not set a tool cache env")
    if any(v["name"] == "tool-cache" for v in spec["volumes"]):
        raise SystemExit(f"{path}: density must not carry the tool-cache volume")
    work = "/home/runner/_work"
    if mounts(runner).get(work) != "work" or mounts(dind).get(work) != "work":
        raise SystemExit(f"{path}: density <work>/_tool is not shared with dind")
PY
    then
        pass "non-root container-job tool-cache probe: burst/drain share one plain emptyDir at RUNNER_TOOL_CACHE with dind; density keeps <work>/_tool on the shared work volume"
    else
        fail "non-root container-job tool-cache probe failed"
    fi

    if python - "${REPO_ROOT}/.github/workflows/deploy-runners.yml" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for needle in (
    '("RUNNER_TOOL_CACHE", "/opt/hostedtoolcache"),',
    '("AGENT_TOOLSDIRECTORY", "/opt/hostedtoolcache"),',
    'expected_volumes = {"work", "dind-sock", "dind-externals", "tool-cache"}',
):
    if text.count(needle) != 1:
        raise SystemExit(f"Deploy admission check lacks {needle}")
if text.count('("tool-cache", "/opt/hostedtoolcache"),') != 2:
    raise SystemExit("Deploy admission check must require the tool-cache mount in runner and dind")
PY
    then
        pass "Deploy admission check requires the shared tool cache in runner and dind"
    else
        fail "Deploy admission check does not require the shared tool cache"
    fi

    # Ruling 26: the stopped state family, as Emergency Stop leaves each base
    # template (helm upgrade --reuse-values --set minRunners=0 --set maxRunners=0).
    local stopped="${FIXTURES}/pool-state/arc-burst-stopped/helm-values.json"
    local density_stopped="${FIXTURES}/pool-state/arc-density-stopped/helm-values.json"
    local drain_stopped="${FIXTURES}/pool-state/arc-drain-stopped/helm-values.json"
    expect_accept "burst-stopped 0/0 (burst template, Emergency Stop)" burst-stopped 0 0 private "$stopped"
    expect_accept "density-stopped 0/0 (density template, Emergency Stop)" density-stopped 0 0 private "$density_stopped"
    expect_accept "drain-stopped 0/0 (drain template, Emergency Stop)" drain-stopped 0 0 private "$drain_stopped"
    expect_reject "burst-stopped on the default group" burst-stopped 0 0 default "$stopped"
    expect_reject "burst-stopped with bounds 0/4" burst-stopped 0 4 private "$stopped"
    expect_reject "burst values 2/20 as burst-stopped" burst-stopped 2 20 private "$burst"
    expect_reject "burst-stopped values as burst 2/20" burst 2 20 private "$stopped"
    expect_reject "density-stopped values as burst-stopped" burst-stopped 0 0 private "$density_stopped"
    expect_reject "drain-stopped values as burst-stopped" burst-stopped 0 0 private "$drain_stopped"
    expect_reject "burst-stopped values as drain-stopped" drain-stopped 0 0 private "$stopped"
    expect_reject "burst-stopped values as density-stopped" density-stopped 0 0 private "$stopped"
    expect_reject "density-stopped values as density 0/0" density 0 0 private "$density_stopped"
    mutate "$stopped" "$tmp" "doc['maxRunners'] = 1"
    expect_reject "burst template 0/1 as burst-stopped" burst-stopped 0 1 private "$tmp"
    mutate "$stopped" "$tmp" 'del doc["template"]["metadata"]'
    expect_reject "burst-stopped without the safe-to-evict annotation" burst-stopped 0 0 private "$tmp"

    expect_accept "density regression: pre-burst values 2/4" density 2 4 private "$density"
    expect_accept "legacy-isolated regression: 2/8 default" legacy-isolated 2 8 default "$legacy"
    expect_reject "density with burst metadata and affinity" density 2 4 private "$drain"
    expect_reject "burst contract against the plain density values" burst 2 20 private "$density"
}

assert_generated_drain_values() {
    info "Checking scripts/render-drain-values.py..."
    local generated="${WORK_DIR}/generated-drain.yaml"
    if ! python "${REPO_ROOT}/scripts/render-drain-values.py" "$generated"; then
        fail "render-drain-values.py failed"
        return
    fi
    expect_accept "generated drain values (as helm get values) as drain 2/4" drain 2 4 private "$generated"
    expect_reject "generated drain values as burst" burst 2 4 private "$generated"
    if python - "$generated" "${REPO_ROOT}/deploy/dind-values.yaml" <<'PY'
import sys
import yaml

generated, source = (yaml.safe_load(open(p, encoding="utf-8")) for p in sys.argv[1:])
generated["maxRunners"] = source["maxRunners"]
generated["template"]["spec"]["affinity"] = source["template"]["spec"]["affinity"]
sys.exit(0 if generated == source else 1)
PY
    then
        pass "generated drain values differ from deploy/dind-values.yaml only in maxRunners and affinity"
    else
        fail "generated drain values differ from deploy/dind-values.yaml beyond maxRunners and affinity"
    fi
    if python "${REPO_ROOT}/scripts/render-drain-values.py" 2>/dev/null; then
        fail "render-drain-values.py accepted a missing output argument"
    else
        pass "render-drain-values.py requires its output argument"
    fi
}

# ---------------------------------------------------------------------------
# Pool-state gate (scripts/verify-runner-pool-state.sh)
#
# Fixtures live in test/fixtures/pool-state/<layer>/. A layer holds whole
# files (cluster.json, pools.json, nodes.json, pods.json, helm-values.json,
# helm-manifest.yaml, asrs.json, helm-releases.json, controller-releases.json,
# controller-deployment.json, expander-configmap.json), "<file>.jq" patches
# applied to the inherited file, and an optional "inherit" file naming parent
# layers (applied first, in order). A scenario is a list of layers.
# ---------------------------------------------------------------------------

POOL_STATE_FIXTURES="${FIXTURES}/pool-state"
POOL_STATE_GATE="${REPO_ROOT}/scripts/verify-runner-pool-state.sh"
POOL_STATE_NOW=1793016000  # 2026-10-26T12:00:00Z, the fixtures' clock
GATE_OUT="${WORK_DIR}/gate.out"
GATE_ERR="${WORK_DIR}/gate.err"

materialize_layer() {  # layer, target dir
    local layer=$1 target=$2 src="${POOL_STATE_FIXTURES}/$1" parent file name
    if [ ! -d "$src" ]; then
        echo "missing pool-state fixture layer '${layer}'" >&2
        return 1
    fi
    if [ -f "${src}/inherit" ]; then
        while IFS= read -r parent; do
            [ -n "$parent" ] || continue
            materialize_layer "$parent" "$target" || return 1
        done < "${src}/inherit"
    fi
    for file in "$src"/*; do
        name=${file##*/}
        case "$name" in
            inherit | *.jq) ;;
            *) cp "$file" "${target}/${name}" ;;
        esac
    done
    for file in "$src"/*.jq; do
        [ -e "$file" ] || continue
        name=${file##*/}
        name=${name%.jq}
        if [ ! -f "${target}/${name}" ] \
            || ! jq -f "$file" "${target}/${name}" > "${target}/${name}.patched"; then
            echo "could not apply ${layer}/${name}.jq" >&2
            return 1
        fi
        mv "${target}/${name}.patched" "${target}/${name}"
    done
}

# pool_state_dir <layer...>: materializes the scenario once and prints its dir.
pool_state_dir() {
    local key dir layer
    key=$(printf '%s+' "$@")
    key=${key%+}
    dir="${WORK_DIR}/pool-state/${key}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        # Ruling 36: by default the server-side fence is installed exactly as
        # committed (layers may replace or patch fence-policy.json and
        # fence-binding.json; an empty file is an absent object).
        python3 - "${REPO_ROOT}/deploy/runner-emergency-stop-fence.yaml" "$dir" <<'PY' || return 1
import json
import sys

import yaml

documents = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
for document in documents:
    document["metadata"].update(uid="fence-uid", generation=1, resourceVersion="7")
    name = "fence-policy.json"
    if document["kind"] == "ValidatingAdmissionPolicy":
        document["status"] = {"observedGeneration": 1, "typeChecking": {}}
    else:
        name = "fence-binding.json"
    with open(f"{sys.argv[2]}/{name}", "w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2)
PY
        for layer in "$@"; do
            materialize_layer "$layer" "$dir" || return 1
        done
        cat > "${dir}/doctl.routes" <<'ROUTES'
kubernetes cluster list -o json|cluster.json
kubernetes cluster node-pool list * -o json|pools.json
ROUTES
        cat > "${dir}/kubectl.routes" <<'ROUTES'
get nodes -o json|nodes.json
get pods -A -o json|pods.json
get autoscalingrunnersets.actions.github.com -n arc-runners -o json|asrs.json
get deployment -n arc-systems -l app.kubernetes.io/name=gha-rs-controller -o json|controller-deployment.json
get configmap cluster-autoscaler-priority-expander -n kube-system -o json|expander-configmap.json
get configmap cluster-autoscaler-priority-expander -n kube-system --ignore-not-found --request-timeout=20s -o json|expander-configmap.json
get crd -o name|crds.txt
get networkpolicies.networking.k8s.io -n arc-runners -o json|networkpolicies.json
get ciliumnetworkpolicies.cilium.io -n arc-runners -o json|cnp.json
get ciliumclusterwidenetworkpolicies.cilium.io -o json|ccnp.json
get pods -n arc-runners -o json|pods.json
get configmap runner-fleet-emergency-stop -n arc-runners --ignore-not-found -o json|stop-marker.json
get validatingadmissionpolicies.admissionregistration.k8s.io runner-fleet-emergency-stop-fence --ignore-not-found -o json|fence-policy.json
get validatingadmissionpolicybindings.admissionregistration.k8s.io runner-fleet-emergency-stop-fence --ignore-not-found -o json|fence-binding.json
ROUTES
        # No Emergency Stop marker (Ruling 33): the read prints nothing.
        : > "${dir}/stop-marker.json"
        cat > "${dir}/helm.routes" <<'ROUTES'
list -n arc-runners -a -o json|helm-releases.json
list -n arc-systems -a -o json|controller-releases.json
get values redducklabs-runners -n arc-runners -o json|helm-values.json
get manifest redducklabs-runners -n arc-runners|helm-manifest.yaml
ROUTES
    fi
    printf '%s\n' "$dir"
}

# run_gate <fixture-dir> <gate args...>: stdout -> GATE_OUT, stderr -> GATE_ERR.
# Fails the suite if the gate ever issued a mutating command.
run_gate() {
    local dir=$1 rc
    shift
    rm -f "$dir"/*.calls
    with_fakes "$dir" env "NOW_CMD=echo ${POOL_STATE_NOW}" \
        bash "$POOL_STATE_GATE" --cluster-name redducklabs-cluster "$@" \
        > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if cat "$dir"/*.calls 2>/dev/null \
        | grep -Eq '(^| )(create|update|delete|patch|apply|upgrade|install|rollback|scale|uninstall|annotate|label|cordon|drain)( |$)'; then
        fail "pool-state gate issued a mutating command in ${dir##*/}"
    fi
    return "$rc"
}

# expect_gate <layers> <operation> <exit> <expectation>
# exit 0: <expectation> is the exact STATE line; otherwise a stderr substring.
expect_gate() {
    local layers=$1 operation=$2 expected=$3 expectation=$4 dir rc
    local label="${operation} on ${layers// /+}"
    # shellcheck disable=SC2086 # layers is a space-separated list by design
    dir=$(pool_state_dir $layers) || { fail "fixture ${layers} could not be built"; return; }
    run_gate "$dir" --operation "$operation"
    rc=$?
    if [ "$rc" -ne "$expected" ]; then
        fail "${label}: exit ${rc}, expected ${expected} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    elif [ "$expected" -eq 0 ]; then
        if [ "$(grep -c '^STATE:' "$GATE_OUT")" = "1" ] && grep -qxF "$expectation" "$GATE_OUT"; then
            pass "${label}: admitted, ${expectation}"
        else
            fail "${label}: admitted but STATE was '$(grep '^STATE:' "$GATE_OUT")', expected '${expectation}'"
        fi
    elif grep -qF -- "$expectation" "$GATE_ERR"; then
        pass "${label}: rejected (${expectation})"
    else
        fail "${label}: rejected without '${expectation}' ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
}

assert_pool_state_scenarios() {
    info "Checking pool-state gate scenarios..."
    if [ ! -f "$POOL_STATE_GATE" ]; then
        fail "scripts/verify-runner-pool-state.sh does not exist"
        return
    fi
    local layers operation code expectation
    while IFS='|' read -r layers operation code expectation; do
        [ -n "$layers" ] || continue
        expect_gate "$layers" "$operation" "$code" "$expectation"
    done <<'CASES'
valid-density-no-burst|create-burst|0|STATE: arc=density pools=none burst=closed
valid-density-no-burst|deploy|1|requires both burst pools
valid-density-no-burst|record-density|0|STATE: arc=density pools=none burst=closed
valid-burst-mixed|status|0|STATE: arc=burst pools=both burst=open
valid-burst-mixed|rebalance|0|STATE: arc=burst pools=both burst=open
valid-burst-mixed|drain|0|STATE: arc=burst pools=both burst=open
valid-burst-mixed|deploy|0|STATE: arc=burst pools=both burst=open
valid-burst-mixed|remove-burst|1|registered node
unknown-eligible-pool|status|1|unknown eligible pool 'github-runners-extra-16g'
legacy-burst-16g-pool|create-burst|1|unknown eligible pool 'github-runners-burst-16g'
wrong-size|status|1|size is 's-8vcpu-16gb'
missing-taint|status|1|taints are not exactly github-runner=true:NoSchedule
extra-noschedule-taint|status|1|extra NoSchedule/NoExecute taint 'dedicated'
taint-capitalized|status|0|STATE: arc=burst pools=both burst=open
burst-max-over-pool|status|1|max_nodes 7 is outside 0..6
burst-sum-over-8|status|1|sum of burst max_nodes 9 exceeds 8
burst-min-nonzero|status|1|min_nodes must be 0
baseline-drift|status|1|count=min=max=2
baseline-notready|status|1|exactly two Ready nodes
notready-burst-16min|status|1|NotReady for longer than 15 minutes
notready-burst-10min|status|0|STATE: arc=burst pools=both burst=open
node-no-pool-label|status|1|does not belong to a runner pool
node-missing-label|status|1|lacks the runner labels
cluster-upgrading|status|1|cluster status is 'upgrading'
cluster-ambiguous|status|1|exactly one DigitalOcean cluster
surge-underfilled|status|1|has 2 registered nodes but provider count 1
provisioning-unregistered|status|0|STATE: arc=burst pools=both burst=open
headroom-short|status|1|lacks headroom
headroom-short|deploy|1|lacks headroom
kube-1.35-node|status|1|v1.35.4
arc-disagree|status|1|ARC state matches no admissible contract
deploy-expander-unset|deploy|1|expanders
deploy-priorities-wrong|deploy|1|priority expander
drain-for-remove|remove-burst|0|STATE: arc=drain pools=both burst=open
density-closed-pools-remove|remove-burst|0|STATE: arc=density pools=both burst=closed
density-open-pools-remove|remove-burst|1|max_nodes=0
rollback-with-pools|rollback|1|requires no burst pools
acceptance-8-from-drain|acceptance-phase-c|1|does not admit ARC state 'drain'
unknown-operation|scale-up|2|unknown operation
create-one-closed|create-burst|0|STATE: arc=density pools=primary burst=closed
create-one-closed|deploy|1|requires both burst pools
enable-stage-closed|enable-burst|0|STATE: arc=burst pools=both burst=closed
enable-stage-middle|enable-burst|0|STATE: arc=burst pools=both burst=open
enable-stage-fallback-first|enable-burst|1|enable-burst stage
enable-stage-partial|enable-burst|1|enable-burst stage
race-count-1|remove-burst|1|provider count 1
race-node-registered|remove-burst|1|registered node
race-runner-pod|remove-burst|1|runner pod
release-wrong-chart|status|1|gha-runner-scale-set-0.14.1
release-failed|status|1|status 'failed'
release-pending-upgrade|status|1|status 'pending-upgrade'
release-ambiguous|status|1|exactly one
release-second-scale-set|status|1|another scale-set release
release-missing|status|1|exactly one
controller-wrong-chart|status|1|gha-runner-scale-set-controller-0.14.1
controller-missing|status|1|exactly one
controller-failed|status|1|status 'failed'
controller-pending-upgrade|status|1|status 'pending-upgrade'
controller-unavailable|status|1|not fully Ready
controller-stale-generation|status|1|stale
controller-unavailable|drain|1|not fully Ready
burst-ca-to-be-deleted|status|0|STATE: arc=burst pools=both burst=open
burst-ca-deletion-candidate|rebalance|0|STATE: arc=burst pools=both burst=open
burst-ca-unavailable-no-headroom|status|0|STATE: arc=burst pools=both burst=open
burst-heavy-no-ca|status|1|lacks headroom
burst-ca-wrong-effect|status|1|extra NoSchedule/NoExecute taint 'DeletionCandidateOfClusterAutoscaler'
baseline-ca-to-be-deleted|status|1|baseline node 'github-runners-pool-16g-a1b2c' carries cluster-autoscaler taint 'ToBeDeletedByClusterAutoscaler'
baseline-ca-deletion-candidate|status|1|carries cluster-autoscaler taint 'DeletionCandidateOfClusterAutoscaler'
burst-ready-uninitialized-5min|status|0|STATE: arc=burst pools=both burst=open
burst-ready-uninitialized-30min|status|1|extra NoSchedule/NoExecute taint 'node.cloudprovider.kubernetes.io/uninitialized'
burst-ready-not-ready-taint-40min|status|1|extra NoSchedule/NoExecute taint 'node.kubernetes.io/not-ready'
burst-notready-uninitialized-10min|status|0|STATE: arc=burst pools=both burst=open
burst-unreachable-10min|status|1|extra NoSchedule/NoExecute taint 'node.kubernetes.io/unreachable'
wrong-size|deploy|1|size is 's-8vcpu-16gb'
base arc-density pool-primary-closed patch-primary-wrong-size|create-burst|1|size is 's-8vcpu-16gb'
base arc-density pool-primary-closed patch-primary-autoscale-off|create-burst|1|auto_scale must be true
base arc-burst pools-open|create-burst|0|STATE: arc=burst pools=both burst=open
base arc-drain pools-closed patch-primary-wrong-size|remove-burst|0|STATE: arc=drain pools=both burst=closed
base arc-density pools-closed patch-primary-autoscale-off|remove-burst|0|STATE: arc=density pools=both burst=closed
base arc-burst pools-closed patch-primary-wrong-size|remove-burst|1|does not admit ARC state 'burst'
base arc-drain pools-closed patch-primary-wrong-size|status|1|size is 's-8vcpu-16gb'
remove-malformed-with-node|remove-burst|1|registered node
base arc-burst pools-open patch-burst-maxima-1-1|acceptance-phase-c|1|exactly 0/6 and 0/2
base arc-burst pools-open|acceptance-phase-c|0|STATE: arc=burst pools=both burst=open
pool-name-missing|status|1|missing or non-string name
cli-pools-fail|status|1|REJECTED: 'doctl kubernetes cluster node-pool ...' failed with exit 1
cli-pods-fail|status|1|REJECTED: 'kubectl get pods -A ...' failed with exit 1
cli-manifest-fail|status|1|REJECTED: 'helm get manifest redducklabs-runners ...' failed with exit 1
remove-runner-pod-in-pool|remove-burst|1|zero runner pods in 'github-runners-burst-amd-16g'
base arc-burst-stopped pools-open|status|0|STATE: arc=burst-stopped pools=both burst=open
base arc-burst-stopped pools-open|rebalance|0|STATE: arc=burst-stopped pools=both burst=open
base arc-burst-stopped pools-open|deploy|0|STATE: arc=burst-stopped pools=both burst=open
base arc-burst-stopped pools-open|drain|0|STATE: arc=burst-stopped pools=both burst=open
base arc-burst-stopped pools-open|acceptance-phase-c|1|does not admit ARC state 'burst-stopped' (0/0)
base arc-burst-stopped pools-open|enable-burst|1|does not admit ARC state 'burst-stopped'
base arc-burst-stopped pools-open|set-burst-maxima|1|does not admit ARC state 'burst-stopped'
base arc-burst-stopped pools-open|remove-burst|1|does not admit ARC state 'burst-stopped'
base arc-burst-stopped|rollback|1|does not admit ARC state 'burst-stopped'
base arc-burst-stopped|rebalance|0|STATE: arc=burst-stopped pools=none burst=closed
base arc-drain-stopped pools-open|status|0|STATE: arc=drain-stopped pools=both burst=open
base arc-drain-stopped pools-open|drain|1|does not admit ARC state 'drain-stopped'
base arc-drain-stopped pools-open|deploy|1|does not admit ARC state 'drain-stopped'
base arc-drain-stopped pools-closed|remove-burst|0|STATE: arc=drain-stopped pools=both burst=closed
base arc-drain-stopped|rollback|0|STATE: arc=drain-stopped pools=none burst=closed
base arc-drain-stopped pools-closed|rollback|1|requires no burst pools
base arc-density-stopped|status|0|STATE: arc=density-stopped pools=none burst=closed
base arc-density-stopped|rollback|0|STATE: arc=density-stopped pools=none burst=closed
base arc-density-stopped|record-density|1|does not admit ARC state 'density-stopped'
base arc-density-stopped|create-burst|1|does not admit ARC state 'density-stopped'
base arc-density-stopped pools-closed|remove-burst|0|STATE: arc=density-stopped pools=both burst=closed
base arc-density-stopped pools-open|remove-burst|1|max_nodes=0
base arc-density-stopped pools-closed|deploy|1|does not admit ARC state 'density-stopped'
CASES

    # Identity is checked before anything else: no DigitalOcean read happens.
    local dir
    dir=$(pool_state_dir release-wrong-chart)
    run_gate "$dir" --operation status
    if [ -s "${dir}/doctl.calls" ]; then
        fail "gate read DigitalOcean state before the ARC release identity check"
    else
        pass "gate checks ARC release identity before reading pool state"
    fi
}

# The spec's "ARC states admitted per operation" table, evaluated for every
# ARC contract against three pool layouts. Each row: pools|operation|admitted
# ARC layers (space-separated; '-' for none).
assert_pool_state_admission_table() {
    info "Checking the ARC admission table..."
    [ -f "$POOL_STATE_GATE" ] || { fail "scripts/verify-runner-pool-state.sh does not exist"; return; }
    local stopped="arc-burst-stopped arc-density-stopped arc-drain-stopped"
    local all="arc-density arc-burst arc-burst-acceptance-8 arc-burst-acceptance-4 arc-drain ${stopped}"
    local pools operation admitted arc layers expected
    while IFS='|' read -r pools operation admitted; do
        [ -n "$pools" ] || continue
        [ "$admitted" = "all" ] && admitted=$all
        for arc in $all; do
            layers="base ${arc}"
            [ "$pools" = "none" ] || layers="${layers} pools-${pools}"
            expected=1
            case " ${admitted} " in *" ${arc} "*) expected=0 ;; esac
            local dir rc
            # shellcheck disable=SC2086
            dir=$(pool_state_dir $layers)
            run_gate "$dir" --operation "$operation"
            rc=$?
            if [ "$rc" -eq "$expected" ]; then
                pass "admission: ${operation} with ${arc#arc-}, pools ${pools} -> exit ${rc}"
            else
                fail "admission: ${operation} with ${arc#arc-}, pools ${pools} -> exit ${rc}, expected ${expected} ($(head -c 200 "$GATE_ERR" | tr '\n' ' '))"
            fi
        done
    done <<'TABLE'
none|status|all
none|rebalance|arc-burst-stopped arc-density-stopped arc-drain-stopped
none|acceptance-phase-c|-
none|record-density|arc-density
none|set-burst-maxima|-
none|create-burst|arc-density arc-burst
none|configure-expander|-
none|deploy|-
none|enable-burst|-
none|drain|-
none|remove-burst|arc-drain arc-density arc-drain-stopped arc-density-stopped
none|rollback|arc-drain arc-density arc-drain-stopped arc-density-stopped
closed|status|all
closed|rebalance|arc-burst arc-drain arc-burst-stopped arc-density-stopped arc-drain-stopped
closed|acceptance-phase-c|-
closed|record-density|-
closed|set-burst-maxima|arc-burst
closed|create-burst|arc-density arc-burst
closed|configure-expander|arc-density arc-burst
closed|deploy|arc-density arc-burst arc-burst-stopped
closed|enable-burst|arc-burst
closed|drain|arc-burst arc-burst-acceptance-8 arc-burst-acceptance-4 arc-drain arc-burst-stopped
closed|remove-burst|arc-drain arc-density arc-drain-stopped arc-density-stopped
closed|rollback|-
open|status|all
open|rebalance|arc-burst arc-drain arc-burst-stopped arc-density-stopped arc-drain-stopped
open|acceptance-phase-c|arc-burst arc-burst-acceptance-8 arc-burst-acceptance-4
open|record-density|-
open|set-burst-maxima|arc-burst
open|create-burst|arc-density arc-burst
open|configure-expander|arc-density arc-burst
open|deploy|arc-density arc-burst arc-burst-stopped
open|enable-burst|arc-burst
open|drain|arc-burst arc-burst-acceptance-8 arc-burst-acceptance-4 arc-drain arc-burst-stopped
open|remove-burst|arc-drain arc-drain-stopped
open|rollback|-
TABLE
}

# emit_snapshot <layers> <operation> <file>
emit_snapshot() {
    local layers=$1 operation=$2 file=$3 dir
    # shellcheck disable=SC2086
    dir=$(pool_state_dir $layers) || return 1
    rm -f "$file"
    run_gate "$dir" --operation "$operation" --emit-identities "$file"
}

# compare_snapshot <layers> <file> <transition>; returns the gate's exit code.
compare_snapshot() {
    local layers=$1 file=$2 transition=$3 dir
    # shellcheck disable=SC2086
    dir=$(pool_state_dir $layers) || return 1
    run_gate "$dir" --compare-identities "$file" --transition "$transition"
}

assert_pool_state_snapshot() {
    info "Checking pool-state identity snapshots..."
    [ -f "$POOL_STATE_GATE" ] || { fail "scripts/verify-runner-pool-state.sh does not exist"; return; }
    local snap="${WORK_DIR}/snapshot.json" copy="${WORK_DIR}/snapshot.orig.json" rc

    if emit_snapshot valid-burst-mixed status "$snap" && [ -s "$snap" ]; then
        pass "admitted status run writes an identity snapshot"
    else
        fail "admitted status run did not write a snapshot ($(head -c 300 "$GATE_ERR"))"
        return
    fi
    if python - "$snap" <<'PY'
import json
import sys

snap = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(snap) == {"immutable", "pools", "arc"}, snap.keys()
assert set(snap["immutable"]) == {"cluster_id", "baseline_pool_id", "baseline_nodes"}
assert snap["immutable"]["cluster_id"] == "c4e1f0a2-6b3d-4f58-9a07-1d2e3f4a5b60"
assert snap["immutable"]["baseline_pool_id"] == "6c1f5a7e-2b0d-4a3e-9f61-0b5d8e2c4a01"
assert snap["immutable"]["baseline_nodes"] == [
    {"uid": "a0b1c2d3-1111-4aaa-8bbb-000000000001", "providerID": "digitalocean://500000001"},
    {"uid": "a0b1c2d3-2222-4aaa-8bbb-000000000002", "providerID": "digitalocean://500000002"},
]
assert set(snap["pools"]) == {"worker-pool", "github-runners-pool-16g",
                              "github-runners-burst-amd-16g", "github-runners-burst-intel-16g"}
for pool in snap["pools"].values():
    assert set(pool) == {"id", "size", "auto_scale", "min_nodes", "max_nodes", "labels", "taints"}, pool
primary = snap["pools"]["github-runners-burst-amd-16g"]
assert primary["taints"] == [{"key": "github-runner", "value": "true", "effect": "NoSchedule"}]
assert (primary["min_nodes"], primary["max_nodes"], primary["auto_scale"]) == (0, 6, True)
arc = snap["arc"]
assert set(arc) == {"contract", "minRunners", "maxRunners", "values_sha256", "manifest_sha256", "asrs_generation"}
assert (arc["contract"], arc["minRunners"], arc["maxRunners"], arc["asrs_generation"]) == ("burst", 2, 20, 4)
assert len(arc["values_sha256"]) == 64 and len(arc["manifest_sha256"]) == 64
text = open(sys.argv[1], encoding="utf-8").read()
assert "FIXTURE-PLACEHOLDER" not in text and '"count"' not in text
PY
    then
        pass "snapshot has the single authoritative schema, no counts and no token"
    else
        fail "snapshot schema or content is wrong"
    fi
    rm -f "${WORK_DIR}/rejected.json"
    emit_snapshot wrong-size status "${WORK_DIR}/rejected.json"
    rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "${WORK_DIR}/rejected.json" ]; then
        pass "a rejected admission writes no snapshot"
    else
        fail "a rejected admission (exit ${rc}) wrote a snapshot"
    fi

    cp "$snap" "$copy"
    compare_snapshot valid-burst-mixed "$snap" none \
        && pass "unchanged live state equals its snapshot" || fail "unchanged live state differs from its snapshot ($(head -c 300 "$GATE_ERR"))"
    compare_snapshot taint-capitalized "$snap" none \
        && pass "capitalized provider taints normalize to the snapshot" || fail "capitalized taints differ from the snapshot"
    compare_snapshot drift-dynamic-only "$snap" none \
        && pass "provider count changes are dynamic, not identity" || fail "a count-only change failed the identity comparison"

    local scenario field lines
    while IFS='|' read -r scenario field lines; do
        [ -n "$scenario" ] || continue
        cp "$copy" "$snap"
        compare_snapshot "$scenario" "$snap" none
        rc=$?
        if [ "$rc" -eq 3 ] && cmp -s "$snap" "$copy" && grep -qF "IDENTITY: ${field}" "$GATE_ERR" \
            && [ "$(grep -c '^IDENTITY: [a-z_]*\.' "$GATE_ERR")" = "${lines:-1}" ]; then
            pass "identity drift ${scenario#drift-} -> exit 3 on ${field} only"
        else
            fail "identity drift ${scenario#drift-} -> exit ${rc} (expected 3 on ${field} only, snapshot unchanged): $(head -c 300 "$GATE_ERR" | tr '\n' ' ')"
        fi
    done <<'DRIFT'
drift-cluster-id|immutable.cluster_id:
drift-baseline-pool-id|immutable.baseline_pool_id:|2
drift-baseline-node-uid|immutable.baseline_nodes:
drift-baseline-provider-id|immutable.baseline_nodes:
drift-values-hash|arc.values_sha256:
drift-asrs-generation|arc.asrs_generation:
drift-pool-max|pools.github-runners-burst-amd-16g.max_nodes:
drift-pool-min|pools.github-runners-burst-amd-16g.min_nodes:
drift-pool-autoscale|pools.github-runners-burst-amd-16g.auto_scale:
drift-pool-size|pools.github-runners-burst-amd-16g.size:
drift-pool-label|pools.github-runners-burst-amd-16g.labels.workload-type:
drift-pool-taint|pools.github-runners-burst-amd-16g.taints:
DRIFT

    emit_snapshot "base arc-burst-acceptance-8 pools-open" acceptance-phase-c "$snap" \
        || fail "burst-acceptance 8/20 snapshot was not admitted"
    compare_snapshot "base arc-burst-acceptance-4 pools-open" "$snap" none
    rc=$?
    [ "$rc" -eq 3 ] && pass "identity drift burst-acceptance 8/20 -> 4/20 -> exit 3" \
        || fail "identity drift 8/20 -> 4/20 -> exit ${rc}, expected 3"
}

# expect_transition <from-layers> <op> <to-layers> <transition> <exit> [stderr substring]
expect_transition() {
    local from=$1 operation=$2 to=$3 transition=$4 expected=$5 reason=${6:-} rc
    local snap="${WORK_DIR}/transition.json" copy="${WORK_DIR}/transition.orig.json"
    if ! emit_snapshot "$from" "$operation" "$snap"; then
        fail "transition setup: ${from} not admitted for ${operation} ($(head -c 200 "$GATE_ERR"))"
        return
    fi
    cp "$snap" "$copy"
    compare_snapshot "$to" "$snap" "$transition"
    rc=$?
    if [ "$rc" -ne "$expected" ]; then
        fail "transition ${transition} to ${to// /+}: exit ${rc}, expected ${expected} ($(head -c 200 "$GATE_ERR" | tr '\n' ' '))"
    elif [ "$expected" -ne 0 ] && ! cmp -s "$snap" "$copy"; then
        fail "transition ${transition} to ${to// /+}: rejected but the snapshot was rewritten"
    elif [ -n "$reason" ] && ! grep -qF -- "$reason" "$GATE_ERR"; then
        fail "transition ${transition} to ${to// /+}: exit ${rc} without '${reason}' ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    else
        pass "transition ${transition} to ${to// /+} -> exit ${rc}"
    fi
}

# chain <start-layers> <op> then pairs of "<layers>" "<transition>"; after each
# successful step the next exact comparison must pass, and the final snapshot
# must equal a fresh snapshot of the final state.
expect_chain() {
    local label=$1 start=$2 operation=$3
    shift 3
    local snap="${WORK_DIR}/chain.json" fresh="${WORK_DIR}/chain-fresh.json" layers transition last=$start
    if ! emit_snapshot "$start" "$operation" "$snap"; then
        fail "chain ${label}: start not admitted ($(head -c 200 "$GATE_ERR"))"
        return
    fi
    while [ $# -gt 0 ]; do
        layers=$1 transition=$2
        shift 2
        if ! compare_snapshot "$layers" "$snap" "$transition"; then
            fail "chain ${label}: ${transition} failed ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
            return
        fi
        if ! compare_snapshot "$layers" "$snap" none; then
            fail "chain ${label}: exact comparison after ${transition} failed"
            return
        fi
        last=$layers
    done
    emit_snapshot "$last" status "$fresh"
    if python -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$snap" "$fresh"; then
        pass "chain ${label}: every declared transition verified; snapshot equals the final state"
    else
        fail "chain ${label}: chained snapshot differs from a fresh snapshot of the final state"
    fi
}

assert_pool_state_transitions() {
    info "Checking declared identity transitions..."
    [ -f "$POOL_STATE_GATE" ] || { fail "scripts/verify-runner-pool-state.sh does not exist"; return; }
    local none="base arc-density"
    expect_transition "$none" create-burst "base arc-density created-primary-max6" \
        pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-amd:0/0 3 "github-runners-burst-amd-16g.max_nodes: expected=0 live=6"
    expect_transition "$none" create-burst "base arc-density created-primary-no-label" \
        pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-amd:0/0 3 "github-runners-burst-amd-16g.labels.workload-type: expected"
    expect_transition "$none" create-burst "base arc-density created-primary-autoscale-off" \
        pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-amd:0/0 3 "github-runners-burst-amd-16g.auto_scale: expected=true live=false"
    expect_transition "$none" create-burst "base arc-density pools-closed" \
        pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-amd:0/0 3 "pools.github-runners-burst-intel-16g: unexpected"
    expect_transition "$none" create-burst "base arc-density pool-primary-closed" \
        pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-intel:0/0 2 "is not the size of"
    expect_transition "base arc-burst pools-closed" enable-burst "base arc-burst bounds-primary-0-5" \
        pool-bounds:github-runners-burst-amd-16g:0/6 3 "github-runners-burst-amd-16g.max_nodes: expected=6 live=5"
    expect_transition "base arc-burst pools-closed" enable-burst "base arc-burst enable-stage-middle" \
        pool-bounds:github-runners-burst-amd-16g:0/6 0
    expect_transition "base arc-burst pools-closed" enable-burst "base arc-burst enable-stage-middle" \
        pool-bounds:github-runners-burst-intel-16g:0/2 3 "github-runners-burst-amd-16g.max_nodes: expected=0 live=6"
    expect_transition "base arc-density pools-closed" remove-burst "base arc-density pools-closed primary-gone" \
        pool-deleted:github-runners-burst-intel-16g 3 "pools.github-runners-burst-amd-16g: expected, absent live"
    expect_transition "base arc-density pools-closed" remove-burst "base arc-density pools-closed primary-gone" \
        pool-deleted:github-runners-pool-16g 2 "not a burst pool"
    expect_transition "base arc-burst-acceptance-8 pools-open" acceptance-phase-c "base arc-burst-acceptance-4 pools-open" \
        arc:burst:2/20 3 "arc.minRunners: expected=2 live=4"
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open patch-primary-max-5" \
        arc:drain:2/4 3 "github-runners-burst-amd-16g.max_nodes: expected=6 live=5"
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open" \
        arc:drain:2/20 2 "not a canonical ARC state"
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open" \
        arc:drain:2/4 0
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open patch-release-pending-upgrade" \
        arc:drain:2/4 1 "status 'pending-upgrade'"
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open patch-release-failed" \
        arc:drain:2/4 1 "ARC transition not trusted"
    expect_transition "base arc-burst pools-open" drain "base arc-drain pools-open patch-asrs-no-generation" \
        arc:drain:2/4 3 "no metadata.generation"
    expect_transition "base arc-burst pools-open" drain "base arc-burst pools-open patch-release-pending-upgrade" \
        none 0
    expect_transition "base arc-burst pools-open" status "pool-name-missing" \
        none 1 "missing or non-string name"

    expect_chain "create primary then fallback" "$none" create-burst \
        "base arc-density pool-primary-closed" pool-created:github-runners-burst-amd-16g:s-8vcpu-16gb-amd:0/0 \
        "base arc-density pools-closed" pool-created:github-runners-burst-intel-16g:s-8vcpu-16gb-intel:0/0
    expect_chain "delete both" "base arc-density pools-closed" remove-burst \
        "base arc-density pools-closed primary-gone" pool-deleted:github-runners-burst-amd-16g \
        "base arc-density" pool-deleted:github-runners-burst-intel-16g
    expect_chain "density -> burst -> drain -> density" "base arc-density" status \
        "base arc-burst" arc:burst:2/20 \
        "base arc-drain" arc:drain:2/4 \
        "base arc-density" arc:density:2/4
    expect_chain "burst 2/20 -> 8/20 -> 4/20 -> 2/20" "base arc-burst pools-open" acceptance-phase-c \
        "base arc-burst-acceptance-8 pools-open" arc:burst-acceptance:8/20 \
        "base arc-burst-acceptance-4 pools-open" arc:burst-acceptance:4/20 \
        "base arc-burst pools-open" arc:burst:2/20
}

assert_pool_state_usage() {
    info "Checking pool-state gate usage errors..."
    [ -f "$POOL_STATE_GATE" ] || { fail "scripts/verify-runner-pool-state.sh does not exist"; return; }
    local dir snap="${WORK_DIR}/usage.json" args rc
    dir=$(pool_state_dir valid-burst-mixed)
    emit_snapshot valid-burst-mixed status "$snap"
    while IFS= read -r args; do
        [ -n "$args" ] || continue
        rm -f "$dir"/*.calls
        # shellcheck disable=SC2086 # each row is a deliberate argument list
        with_fakes "$dir" env "NOW_CMD=echo ${POOL_STATE_NOW}" bash "$POOL_STATE_GATE" ${args//@SNAP@/$snap} \
            > "$GATE_OUT" 2> "$GATE_ERR"
        rc=$?
        if [ "$rc" -eq 2 ] && ! cat "$dir"/*.calls >/dev/null 2>&1; then
            pass "usage error -> exit 2 before any read: ${args//@SNAP@/snap}"
        else
            fail "usage '${args//@SNAP@/snap}' -> exit ${rc}, expected 2 with no CLI call"
        fi
    done <<'ARGS'
--operation status
--cluster-name --operation --operation status
--cluster-name Bad_Name --operation status
--cluster-name redducklabs-cluster
--cluster-name redducklabs-cluster --operation status --transition none
--cluster-name redducklabs-cluster --compare-identities @SNAP@
--cluster-name redducklabs-cluster --operation status --compare-identities @SNAP@ --transition none
--cluster-name redducklabs-cluster --compare-identities @SNAP@ --transition pool-created:github-runners-burst-amd-16g
--cluster-name redducklabs-cluster --compare-identities @SNAP@ --transition pool-bounds:github-runners-burst-amd-16g:0/7
--cluster-name redducklabs-cluster --compare-identities @SNAP@ --transition arc:burst:2/4
--cluster-name redducklabs-cluster --compare-identities @SNAP@ --transition bogus
--cluster-name redducklabs-cluster --operation status --bogus
ARGS
    rm -f "$dir"/*.calls
    cp "$snap" "${snap}.orig"
    printf '{"immutable": {}}\n' > "$snap"
    compare_snapshot valid-burst-mixed "$snap" none
    rc=$?
    [ "$rc" -ne 0 ] && pass "a malformed snapshot fails closed (exit ${rc})" || fail "a malformed snapshot was accepted"
}

assert_arc_identity_library() {
    info "Checking scripts/lib/arc-identity.sh..."
    local lib="${REPO_ROOT}/scripts/lib/arc-identity.sh" scenario code dir rc
    [ -f "$lib" ] || { fail "scripts/lib/arc-identity.sh does not exist"; return; }
    while IFS='|' read -r scenario code; do
        [ -n "$scenario" ] || continue
        dir=$(pool_state_dir "$scenario")
        # shellcheck disable=SC2016 # expanded by the inner shell
        with_fakes "$dir" bash -c 'source "$1" && verify_arc_identity' _ "$lib" > "$GATE_OUT" 2> "$GATE_ERR"
        rc=$?
        if [ "$rc" -ne "$code" ]; then
            fail "verify_arc_identity on ${scenario}: exit ${rc}, expected ${code}"
        elif [ "$code" -ne 0 ] && ! grep -q . "$GATE_ERR"; then
            fail "verify_arc_identity on ${scenario}: failed without a reason on stderr"
        else
            pass "verify_arc_identity on ${scenario} -> exit ${rc}"
        fi
    done <<'CASES'
valid-burst-mixed|0
release-wrong-chart|1
release-failed|1
release-pending-upgrade|1
release-ambiguous|1
release-missing|1
release-second-scale-set|1
controller-wrong-chart|1
controller-missing|1
controller-failed|1
controller-pending-upgrade|1
controller-unavailable|1
controller-stale-generation|1
CASES
}

# ---------------------------------------------------------------------------
# Idle burst-runner retirement (scripts/retire-idle-burst-runners.sh)
#
# Fixtures live in test/fixtures/retire/<scenario>/ (nodes.json, pods.json,
# ephemeralrunners.json and the gh-runners-<page>.json pages, concatenated the
# way "gh api --paginate" prints them). The ARC identity files come from a
# pool-state layer. The fake kubectl records every call in kubectl.calls, which
# serves as the mutation log: deletions are the lines starting with "delete ".
# ---------------------------------------------------------------------------

RETIRE_FIXTURES="${FIXTURES}/retire"
RETIRE_SCRIPT="${REPO_ROOT}/scripts/retire-idle-burst-runners.sh"
RETIRE_PREFIX="redducklabs-runners-7xk2p-runner-"
RETIRE_SNAPSHOT="${WORK_DIR}/retire-identities.json"

# retire_dir <scenario> <identity-layer>: builds a fixture dir and prints it.
retire_dir() {
    local scenario=$1 layer=$2 dir page
    dir=$(mktemp -d "${WORK_DIR}/retire.XXXXXX")
    cp -r "$(pool_state_dir "$layer")/." "$dir/"
    cp "${RETIRE_FIXTURES}/${scenario}/"{pods,ephemeralrunners}.json "$dir/"
    # Nodes come from the pool-state layer (so the identity compare sees the
    # nodes the snapshot was taken from) unless the scenario overrides them.
    [ ! -f "${RETIRE_FIXTURES}/${scenario}/nodes.json" ] || cp "${RETIRE_FIXTURES}/${scenario}/nodes.json" "$dir/"
    : > "${dir}/gh-runners.json"
    for page in "${RETIRE_FIXTURES}/${scenario}"/gh-runners-*.json; do
        cat "$page" >> "${dir}/gh-runners.json"
        [ ! -f "${page}.rc" ] || cp "${page}.rc" "${dir}/gh-runners.json.rc"
    done
    printf 'ephemeralrunner deleted\n' > "${dir}/delete.out"
    cat > "${dir}/kubectl.routes" <<'ROUTES'
get nodes -o json|nodes.json
get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners -o json|pods.json
get ephemeralrunners.actions.github.com -n arc-runners -o json|ephemeralrunners.json
get deployment -n arc-systems -l app.kubernetes.io/name=gha-rs-controller -o json|controller-deployment.json
get autoscalingrunnersets.actions.github.com -n arc-runners -o json|asrs.json
delete ephemeralrunner -n arc-runners * --wait=false|delete.out
ROUTES
    printf 'api --paginate orgs/redducklabs/actions/runners*|gh-runners.json\n' > "${dir}/gh.routes"
    rm -f "$dir"/*.calls
    printf '%s\n' "$dir"
}

# expect_retire <label> <scenario> <identity-layer> <exit> <summary> <deleted-suffixes> [script args]
# <summary> is the exact last stdout line (ignored when exit is not 0);
# <deleted-suffixes> is the comma-separated, ordered list of runner-name
# suffixes that must be deleted ("-" for none).
expect_retire() {
    local label=$1 scenario=$2 layer=$3 expected=$4 summary=$5 deleted=$6 dir rc actual last
    shift 6
    dir=$(retire_dir "$scenario" "$layer") || { fail "retire fixture ${scenario} could not be built"; return; }
    with_fakes "$dir" env GH_TOKEN=fake-token "NOW_CMD=echo ${POOL_STATE_NOW}" \
        bash "$RETIRE_SCRIPT" --identities "$RETIRE_SNAPSHOT" "$@" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    actual=$(grep '^delete ' "${dir}/kubectl.calls" 2>/dev/null \
        | sed -E "s/^delete ephemeralrunner -n arc-runners ${RETIRE_PREFIX}([a-z0-9]+) --wait=false\$/\\1/" \
        | paste -sd, -)
    [ -n "$actual" ] || actual="-"
    last=$(tail -n 1 "$GATE_OUT")
    if [ "$rc" -ne "$expected" ]; then
        fail "retire ${label}: exit ${rc}, expected ${expected} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    elif [ "$actual" != "$deleted" ]; then
        fail "retire ${label}: deleted '${actual}', expected '${deleted}'"
    elif [ "$expected" -eq 0 ] && [ "$last" != "$summary" ]; then
        fail "retire ${label}: last line '${last}', expected '${summary}'"
    elif [ "$expected" -ne 0 ] && grep -q '^RETIRED=' "$GATE_OUT"; then
        fail "retire ${label}: failed run printed a RETIRED summary"
    elif [ "$expected" -ne 0 ] && ! grep -q '^ERROR:' "$GATE_ERR"; then
        fail "retire ${label}: failed without an ERROR reason on stderr"
    else
        pass "retire ${label}: exit ${rc}, deleted ${deleted}${summary:+, ${summary}}"
    fi
}

assert_retirement() {
    info "Checking scripts/retire-idle-burst-runners.sh..."
    if [ ! -f "$RETIRE_SCRIPT" ]; then
        fail "scripts/retire-idle-burst-runners.sh does not exist"
        return
    fi
    local ok=valid-burst-mixed label scenario layer code summary deleted
    if ! emit_snapshot "$ok" status "$RETIRE_SNAPSHOT"; then
        fail "retire: could not write the identity snapshot ($(head -c 300 "$GATE_ERR"))"
        return
    fi
    while IFS='|' read -r label scenario layer code summary deleted; do
        [ -n "$label" ] || continue
        expect_retire "$label" "$scenario" "${layer:-$ok}" "$code" "$summary" "$deleted"
    done <<'CASES'
idle runner on a burst node is retired|idle-on-burst||0|RETIRED=1 CANDIDATES=1 FREE_BASELINE_SLOTS=2|burstaa
GitHub busy=true is kept|busy-on-burst||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
jobRequestId set with GitHub idle is kept|jobid-set-gh-idle||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
jobRequestId 0 counts as no job|jobid-zero-gh-idle||0|RETIRED=1 CANDIDATES=1 FREE_BASELINE_SLOTS=2|burstaa
no free baseline slot retires nothing|baseline-full||0|RETIRED=0 CANDIDATES=2 FREE_BASELINE_SLOTS=0|-
two idle, one slot: the oldest goes|two-idle-one-slot||0|RETIRED=1 CANDIDATES=2 FREE_BASELINE_SLOTS=1|burstaa
EphemeralRunner without a pod is skipped and holds a slot|pod-missing||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=1|-
runner absent from GitHub is kept|runner-not-in-github||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
runner without status.runnerName is kept|runner-name-unset||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
runner already being deleted is skipped|being-deleted||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
baseline and non-runner-pool runners are never candidates|on-baseline-and-other-pool||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=2|-
busy flag on GitHub page 2 is respected|runners-paginated||0|RETIRED=1 CANDIDATES=1 FREE_BASELINE_SLOTS=2|burstaa
pending runner pod holds a baseline slot|pending-pod-consumes-slot||0|RETIRED=0 CANDIDATES=1 FREE_BASELINE_SLOTS=0|-
EphemeralRunner without a pod holds a baseline slot|er-without-pod-consumes-slot||0|RETIRED=0 CANDIDATES=1 FREE_BASELINE_SLOTS=0|-
terminal pod on a burst node is skipped and holds a slot|terminal-pod-on-burst||0|RETIRED=0 CANDIDATES=0 FREE_BASELINE_SLOTS=1|-
terminating pod on baseline still occupies it|terminating-pod-on-baseline||0|RETIRED=0 CANDIDATES=1 FREE_BASELINE_SLOTS=0|-
missing creationTimestamp is never the oldest|no-creation-timestamp||0|RETIRED=1 CANDIDATES=1 FREE_BASELINE_SLOTS=1|burstbb
two idle, two slots: both go, oldest first|two-idle-two-slots||0|RETIRED=2 CANDIDATES=2 FREE_BASELINE_SLOTS=2|burstaa,burstbb
GitHub API error aborts|gh-api-error||1||-
truncated GitHub runner list aborts|gh-truncated||1||-
wrong scale-set chart aborts|idle-on-burst|release-wrong-chart|1||-
wrong controller chart aborts|idle-on-burst|controller-wrong-chart|1||-
missing controller aborts|idle-on-burst|controller-missing|1||-
failed controller release aborts|idle-on-burst|controller-failed|1||-
unavailable controller aborts|idle-on-burst|controller-unavailable|1||-
CASES
    expect_retire "--dry-run deletes nothing" idle-on-burst "$ok" 0 "RETIRED=0 CANDIDATES=1 FREE_BASELINE_SLOTS=2" "-" --dry-run
    expect_retire "one Ready baseline node halves the slots (dry run)" baseline-node-notready "$ok" 0 "RETIRED=0 CANDIDATES=1 FREE_BASELINE_SLOTS=0" "-" --dry-run
    expect_retire "unknown argument is a usage error" idle-on-burst "$ok" 2 "" "-" --bogus

    # A failed Kubernetes read must also abort with no deletion and no GitHub read.
    local dir rc route
    for route in "get nodes -o json" "get pods -n arc-runners" "get ephemeralrunners.actions.github.com"; do
        dir=$(retire_dir idle-on-burst "$ok")
        printf '%s*|kube-error.json\n' "$route" | cat - "${dir}/kubectl.routes" > "${dir}/kubectl.routes.new"
        mv "${dir}/kubectl.routes.new" "${dir}/kubectl.routes"
        printf 'boom\n' > "${dir}/kube-error.json"
        printf '1\n' > "${dir}/kube-error.json.rc"
        with_fakes "$dir" env GH_TOKEN=fake-token bash "$RETIRE_SCRIPT" --identities "$RETIRE_SNAPSHOT" > "$GATE_OUT" 2> "$GATE_ERR"
        rc=$?
        if [ "$rc" -eq 1 ] && ! grep -q '^delete ' "${dir}/kubectl.calls" && [ ! -f "${dir}/gh.calls" ]; then
            pass "retire: failed read of '${route}' -> exit 1, no deletion, no GitHub read"
        else
            fail "retire: failed read of '${route}' -> exit ${rc}, deletions or GitHub read happened"
        fi
    done

    dir=$(retire_dir idle-on-burst "$ok")
    with_fakes "$dir" bash "$RETIRE_SCRIPT" --identities "$RETIRE_SNAPSHOT" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 1 ] && ! grep -q '^delete ' "${dir}/kubectl.calls" 2>/dev/null; then
        pass "retire: missing GH_TOKEN -> exit 1, no deletion"
    else
        fail "retire: missing GH_TOKEN -> exit ${rc}"
    fi

    local drift
    # A failed deletion stops the run: two candidates, two slots, one delete call.
    dir=$(retire_dir two-idle-two-slots "$ok")
    printf '1\n' > "${dir}/delete.out.rc"
    with_fakes "$dir" env GH_TOKEN=fake-token "NOW_CMD=echo ${POOL_STATE_NOW}" \
        bash "$RETIRE_SCRIPT" --identities "$RETIRE_SNAPSHOT" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 1 ] && [ "$(grep -c '^delete ' "${dir}/kubectl.calls")" = "1" ] \
        && [ "$(tail -n 1 "$GATE_OUT")" = "RETIRED=0 CANDIDATES=2 FREE_BASELINE_SLOTS=2" ]; then
        pass "retire: a failed deletion stops the run (one delete call, exit 1, accurate summary)"
    else
        fail "retire: failed deletion -> exit ${rc}, deletes $(grep -c '^delete ' "${dir}/kubectl.calls"), last line '$(tail -n 1 "$GATE_OUT")'"
    fi

    # --identities is mandatory unless --dry-run.
    dir=$(retire_dir idle-on-burst "$ok")
    with_fakes "$dir" env GH_TOKEN=fake-token bash "$RETIRE_SCRIPT" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 1 ] && ! grep -q '^delete ' "${dir}/kubectl.calls" 2>/dev/null && grep -q -- '--identities' "$GATE_ERR"; then
        pass "retire: missing --identities without --dry-run -> exit 1, no deletion"
    else
        fail "retire: missing --identities -> exit ${rc}"
    fi
    with_fakes "$dir" env GH_TOKEN=fake-token bash "$RETIRE_SCRIPT" --identities "${WORK_DIR}/no-such-snapshot.json" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 1 ] && ! grep -q '^delete ' "${dir}/kubectl.calls" 2>/dev/null; then
        pass "retire: nonexistent --identities file -> exit 1, no deletion"
    else
        fail "retire: nonexistent --identities file -> exit ${rc}"
    fi

    # Identity drift that appears after the first deletion stops before the second.
    dir=$(retire_dir two-idle-two-slots "$ok")
    drift="${WORK_DIR}/drift-wrapper.$$"
    mkdir -p "$drift"
    jq '.items[0].metadata.uid = "drifted-uid"' "${dir}/nodes.json" > "${dir}/nodes-drifted.json"
    cat > "${drift}/kubectl" <<WRAPPER
#!/bin/bash
own=\$(dirname "\$0")
PATH=\${PATH#"\${own}:"}
kubectl "\$@"
rc=\$?
[ "\$1" = delete ] && cp "${dir}/nodes-drifted.json" "${dir}/nodes.json"
exit "\$rc"
WRAPPER
    chmod +x "${drift}/kubectl"
    with_fakes "$dir" env GH_TOKEN=fake-token "NOW_CMD=echo ${POOL_STATE_NOW}" \
        bash -c 'PATH="$1:$PATH"; shift; exec bash "$@"' _ "$drift" \
        "$RETIRE_SCRIPT" --identities "$RETIRE_SNAPSHOT" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 1 ] && [ "$(grep -c '^delete ' "${dir}/kubectl.calls")" = "1" ] && grep -q '^IDENTITY:' "$GATE_ERR"; then
        pass "retire: identity drift before the second delete -> exactly one delete, exit 1"
    else
        fail "retire: identity drift -> exit ${rc}, deletes $(grep -c '^delete ' "${dir}/kubectl.calls"), stderr '$(head -c 300 "$GATE_ERR" | tr '\n' ' ')'"
    fi
}

# ---------------------------------------------------------------------------
# Node Pool Sizing operations (scripts/burst-pools.sh, node-pool-sizing.yml)
#
# Scenarios start from pool-state layers and add test/fixtures/burst-pools/
# layers (flags and scheduled events). Every scenario dir carries a "stateful"
# marker, so test/fixtures/burst-pools/stateful_provider.py turns the fakes
# into a provider: create/update/delete and the expander writes rewrite the
# fixture files the real gate, comparator and script read next. The hook
# appends every attempted mutation to "<dir>/mutations.log" (one JSON argv per
# line, in order across tools); burst_mutations condenses it to tokens such as
# create:primary, update:fallback:2, delete:primary, expanders:priority,random
# and patch-configmap.
# ---------------------------------------------------------------------------

BURST_SCRIPT="${REPO_ROOT}/scripts/burst-pools.sh"
BURST_HOOK="${FIXTURES}/burst-pools/stateful_provider.py"
BURST_WORKFLOW="${REPO_ROOT}/.github/workflows/node-pool-sizing.yml"
BURST_OUT="${WORK_DIR}/burst.out"
BURST_ERR="${WORK_DIR}/burst.err"
BURST_SNAPSHOT="${WORK_DIR}/burst-identities.json"
ACTIONS_RUNNER="${SCRIPT_DIR}/lib/actions_runner.py"

# burst_dir <pool-state layers...> [-- <burst-pools layers...>]: a fresh,
# mutable scenario dir.
burst_dir() {
    local layers=() extra=() after=false layer src dir
    for layer in "$@"; do
        if [ "$layer" = -- ]; then
            after=true
        elif [ "$after" = true ]; then
            extra+=("$layer")
        else
            layers+=("$layer")
        fi
    done
    src=$(pool_state_dir "${layers[@]}") || return 1
    dir=$(mktemp -d "${WORK_DIR}/burst.XXXXXX")
    cp -r "${src}/." "${dir}/"
    rm -f "$dir"/*.calls
    for layer in ${extra[@]+"${extra[@]}"}; do
        materialize_layer "../burst-pools/${layer}" "$dir" || return 1
    done
    # DOKS model (Ruling 40): the priority-expander ConfigMap exists only once
    # the priority expander is enabled; the provider creates it on the
    # expander update. "configmap-preexisting" keeps a scenario's ConfigMap.
    if [ ! -f "${dir}/configmap-preexisting" ] \
        && ! jq -e '.[] | select(.name == "redducklabs-cluster") | (.cluster_autoscaler_configuration.expanders // []) | index("priority")' \
            "${dir}/cluster.json" > /dev/null; then
        rm -f "${dir}/expander-configmap.json"
    fi
    printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %q\n' "${dir}/sleep.calls" > "${dir}/fakesleep"
    chmod +x "${dir}/fakesleep"
    printf '%s\n' "$BURST_HOOK" > "${dir}/stateful"
    printf '%s\n' "$dir"
}

burst_mutations() {  # dir -> comma-separated mutation tokens, "-" for none
    python3 - "${1}/mutations.log" <<'PY'
import json
import os
import sys

names = {"3e9d7b20-8c4f-4d1a-a6e5-71f2c0b9d802": "primary", "9a4b2c6d-1e3f-4a5b-8c7d-0e1f2a3b4c03": "fallback",
         "github-runners-burst-amd-16g": "primary", "github-runners-burst-intel-16g": "fallback"}
tokens = []
if os.path.isfile(sys.argv[1]):
    for line in open(sys.argv[1], encoding="utf-8"):
        argv = json.loads(line)
        tool, args = argv[0], argv[1:]
        if args[:4] == ["kubernetes", "cluster", "node-pool", "create"]:
            tokens.append("create:" + names.get(args[args.index("--name") + 1], "?"))
        elif args[:4] == ["kubernetes", "cluster", "node-pool", "update"]:
            tokens.append(f"update:{names.get(args[5], '?')}:{args[args.index('--max-nodes') + 1]}")
        elif args[:4] == ["kubernetes", "cluster", "node-pool", "delete"]:
            tokens.append("delete:" + names.get(args[5], "?"))
        elif args[:3] == ["kubernetes", "cluster", "update"] and "--expanders" in args:
            tokens.append("expanders:" + args[args.index("--expanders") + 1])
        elif tool == "kubectl" and args[:2] == ["patch", "configmap"]:
            tokens.append("patch-configmap")
        else:
            tokens.append("other:" + " ".join(argv))
print(",".join(tokens) or "-")
PY
}

burst_pools_state() {  # dir -> "primary=<min/max|absent> fallback=<...>"
    jq -r '
        def b($n): ([.[] | select(.name == $n)] | if length == 1 then "\(.[0].min_nodes)/\(.[0].max_nodes)" else "absent" end);
        "primary=\(b("github-runners-burst-amd-16g")) fallback=\(b("github-runners-burst-intel-16g"))"
    ' "${1}/pools.json"
}

# run_burst <dir> <snapshot-file|-> <script args...>; clears the logs first.
run_burst() {
    local dir=$1 snapshot=$2
    shift 2
    rm -f "$dir"/*.calls "${dir}/mutations.log"
    local identities=()
    [ "$snapshot" = - ] || identities=(--identities "$snapshot")
    with_fakes "$dir" env "NOW_CMD=echo ${POOL_STATE_NOW}" "SLEEP_CMD=${dir}/fakesleep" bash "$BURST_SCRIPT" "$@" \
        --cluster-name redducklabs-cluster ${identities[@]+"${identities[@]}"} > "$BURST_OUT" 2> "$BURST_ERR"
}

# burst_snapshot <dir> <operation>: the workflow's admission step.
burst_snapshot() {
    rm -f "$BURST_SNAPSHOT"
    with_fakes "$1" env "NOW_CMD=echo ${POOL_STATE_NOW}" bash "$POOL_STATE_GATE" --cluster-name redducklabs-cluster \
        --operation "$2" --emit-identities "$BURST_SNAPSHOT" > "$GATE_OUT" 2> "$GATE_ERR"
}

# expect_burst <label> <dir> <snapshot-op|-> <exit> <mutations> <pools|-> <text|-> <script args...>
# snapshot-op "-" runs without --apply (dry run); otherwise the snapshot is
# emitted with that operation and the script runs with --apply. <text> must
# appear in stdout or stderr.
expect_burst() {
    local label=$1 dir=$2 snap_op=$3 expected=$4 mutations=$5 pools=$6 text=$7 rc actual state
    shift 7
    if [ "$snap_op" = - ]; then
        run_burst "$dir" - "$@"
    else
        if ! burst_snapshot "$dir" "$snap_op"; then
            fail "burst ${label}: setup snapshot (${snap_op}) not admitted ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
            return
        fi
        run_burst "$dir" "$BURST_SNAPSHOT" "$@" --apply
    fi
    rc=$?
    actual=$(burst_mutations "$dir")
    state=$(burst_pools_state "$dir")
    if [ "$rc" -ne "$expected" ]; then
        fail "burst ${label}: exit ${rc}, expected ${expected} ($(tail -c 400 "$BURST_ERR" | tr '\n' ' '))"
    elif [ "$actual" != "$mutations" ]; then
        fail "burst ${label}: mutations '${actual}', expected '${mutations}'"
    elif [ "$pools" != - ] && [ "$state" != "$pools" ]; then
        fail "burst ${label}: final pools '${state}', expected '${pools}'"
    elif [ "$text" != - ] && ! grep -qF -- "$text" "$BURST_OUT" "$BURST_ERR"; then
        fail "burst ${label}: output lacks '${text}' ($(tail -c 400 "$BURST_ERR" | tr '\n' ' '))"
    elif [ "$expected" -ne 2 ] && ! grep -q '^RESULT: ' "$BURST_OUT"; then
        fail "burst ${label}: no RESULT summary line"
    else
        pass "burst ${label}: exit ${rc}, mutations ${actual}"
    fi
}

assert_burst_pools() {
    info "Checking scripts/burst-pools.sh against the stateful provider..."
    if [ ! -f "$BURST_SCRIPT" ]; then
        fail "scripts/burst-pools.sh does not exist"
        return
    fi
    local label layers snap code mutations pools text args dir
    # layers: pool-state layers, optionally "-- <burst-pools layers>".
    while IFS='|' read -r label layers snap code mutations pools text args; do
        [ -n "$label" ] || continue
        # shellcheck disable=SC2086 # layers and args are space-separated lists by design
        dir=$(burst_dir $layers) || { fail "burst ${label}: fixture could not be built"; continue; }
        # shellcheck disable=SC2086
        expect_burst "$label" "$dir" "$snap" "$code" "$mutations" "$pools" "$text" $args
    done <<'CASES'
create from none creates both closed|valid-density-no-burst|create-burst|0|create:primary,create:fallback|primary=0/0 fallback=0/0|RESULT: create-burst applied|create-burst
create with the primary present creates only the fallback|create-one-closed|create-burst|0|create:fallback|primary=0/0 fallback=0/0|NOOP: pool 'github-runners-burst-amd-16g' already exists closed|create-burst
create with both closed is a no-op|base arc-density pools-closed|create-burst|0|-|primary=0/0 fallback=0/0|-|create-burst
create narrows an open primary to 0/0 and creates the fallback|base arc-density created-primary-max6|create-burst|0|update:primary:0,create:fallback|primary=0/0 fallback=0/0|-|create-burst
create refuses an existing pool with auto_scale off|base arc-density created-primary-autoscale-off|remove-burst|1|-|primary=0/0 fallback=absent|auto_scale must be true|create-burst
create refuses an existing pool with the wrong size|base arc-density pool-primary-closed patch-primary-wrong-size|remove-burst|1|-|primary=0/0 fallback=absent|size is 's-8vcpu-16gb'|create-burst
create treats a 422 droplet-limit error as a plain failure, not SCALE_TO_ZERO_REJECTED|valid-density-no-burst -- create-droplet-limit|create-burst|1|create:primary|primary=absent fallback=absent|failed (exit 1; identities unchanged)|create-burst
create stops on SCALE_TO_ZERO_REJECTED after one attempt|valid-density-no-burst -- scale-to-zero-rejected|create-burst|1|create:primary|primary=absent fallback=absent|SCALE_TO_ZERO_REJECTED|create-burst
create dry run plans and changes nothing|valid-density-no-burst|-|0|-|primary=absent fallback=absent|PLAN: create closed pool github-runners-burst-amd-16g|create-burst
expander from unset writes cluster expanders then the ConfigMap|base arc-density pool-primary-closed pool-fallback-closed|configure-expander|0|expanders:priority,random,patch-configmap|-|READBACK: expanders priority,random|configure-expander
expander already configured is a no-op|base arc-density pools-closed|configure-expander|0|-|-|NOOP: cluster expanders already priority,random|configure-expander
expander already configured leaves the ConfigMap alone|base arc-density pools-closed|configure-expander|0|-|-|NOOP: priority expander ConfigMap already ranks|configure-expander
expander dry run from unset with the ConfigMap absent plans the wait and the write|base arc-density pool-primary-closed pool-fallback-closed|-|0|-|-|PLAN: wait up to 600s for DOKS to create ConfigMap kube-system/cluster-autoscaler-priority-expander (it does so only after the priority expander is enabled), then write priorities 100: 3e9d7b20-8c4f-4d1a-a6e5-71f2c0b9d802 (github-runners-burst-amd-16g), 50: 9a4b2c6d-1e3f-4a5b-8c7d-0e1f2a3b4c03 (github-runners-burst-intel-16g), 1: .*|configure-expander
expander dry run from unset with a ConfigMap present plans the patch|base arc-density pool-primary-closed pool-fallback-closed -- configmap-preexisting|-|0|-|-|PLAN: write priority expander ConfigMap: kubectl patch configmap|configure-expander
expander dry run fails closed on a ConfigMap read error other than NotFound|base arc-density pool-primary-closed pool-fallback-closed -- configmap-read-error|-|1|-|-|could not read ConfigMap kube-system/cluster-autoscaler-priority-expander (a read error other than NotFound)|configure-expander
expander apply fails closed on a ConfigMap read error other than NotFound|base arc-density pools-closed -- configmap-read-error|configure-expander|1|-|-|could not read ConfigMap kube-system/cluster-autoscaler-priority-expander (a read error other than NotFound)|configure-expander
expander apply from unset waits for DOKS to create the ConfigMap, then patches it|base arc-density pool-primary-closed pool-fallback-closed -- configmap-appear-late|configure-expander|0|expanders:priority,random,patch-configmap|-|READBACK: DOKS created ConfigMap kube-system/cluster-autoscaler-priority-expander (read 4)|configure-expander
expander ConfigMap readback mismatch fails|base arc-density pool-primary-closed pool-fallback-closed -- configmap-patch-ignored|configure-expander|1|expanders:priority,random,patch-configmap|-|ConfigMap mismatch|configure-expander
expander update that resets the maintenance window fails|base arc-density pool-primary-closed pool-fallback-closed -- maintenance-window-reset|configure-expander|1|expanders:priority,random|-|changed cluster settings other than the expanders|configure-expander
expander update on a cluster without autoscaler configuration passes when DOKS fills in zero values|base arc-density pool-primary-closed pool-fallback-closed -- no-autoscaler-config|configure-expander|0|expanders:priority,random,patch-configmap|-|READBACK: maintenance window any=4:00, surge_upgrade true and other cluster settings unchanged|configure-expander
expander update that changes the scale-down threshold fails|base arc-density pool-primary-closed pool-fallback-closed -- autoscaler-threshold-changed|configure-expander|1|expanders:priority,random|-|changed cluster settings other than the expanders|configure-expander
expander update that resets a customized threshold to 0 fails|base arc-density pool-primary-closed pool-fallback-closed -- autoscaler-threshold-zeroed|configure-expander|1|expanders:priority,random|-|changed cluster settings other than the expanders|configure-expander
expander update that empties a customized unneeded time fails|base arc-density pool-primary-closed pool-fallback-closed -- autoscaler-time-emptied|configure-expander|1|expanders:priority,random|-|changed cluster settings other than the expanders|configure-expander
expander update that sets a threshold on a cluster without autoscaler configuration fails|base arc-density pool-primary-closed pool-fallback-closed -- no-autoscaler-config autoscaler-threshold-changed|configure-expander|1|expanders:priority,random|-|changed cluster settings other than the expanders|configure-expander
expander update without a maintenance_policy fails closed before updating|base arc-density pool-primary-closed pool-fallback-closed -- no-maintenance-policy|configure-expander|1|-|-|no readable maintenance_policy|configure-expander
remove: an expander reset that moves the maintenance window fails before any delete|drain-for-remove -- maintenance-window-reset|remove-burst|1|expanders:|primary=0/6 fallback=0/2|changed cluster settings other than the expanders|remove-burst
expander requires both pools|create-one-closed|-|1|-|-|requires both burst pools|configure-expander
enable from closed opens primary then fallback|enable-stage-closed|enable-burst|0|update:primary:6,update:fallback:2|primary=0/6 fallback=0/2|-|enable-burst
enable retry from the middle stage opens only the fallback|enable-stage-middle|enable-burst|0|update:fallback:2|primary=0/6 fallback=0/2|-|enable-burst
enable with both open is a no-op|base arc-burst pools-open|enable-burst|0|-|primary=0/6 fallback=0/2|NOOP: both burst pools already open|enable-burst
enable rejects primary 0/5 with no update|base arc-burst bounds-primary-0-5|status|1|-|primary=0/5 fallback=0/0|is not one of closed, primary-open, both-open|enable-burst
enable rejects fallback open while primary closed|enable-stage-fallback-first|status|1|-|primary=0/0 fallback=0/2|is not one of closed, primary-open, both-open|enable-burst
enable from density is rejected|base arc-density pools-closed|-|1|-|-|does not admit ARC state 'density'|enable-burst
set 0/2 from 6/2 lowers the primary|base arc-burst pools-open|set-burst-maxima|0|update:primary:0|primary=0/0 fallback=0/2|-|set-burst-maxima --primary-max 0 --fallback-max 2
set 4/2 from 6/0 lowers the primary before raising the fallback|enable-stage-middle|set-burst-maxima|0|update:primary:4,update:fallback:2|primary=0/4 fallback=0/2|-|set-burst-maxima --primary-max 4 --fallback-max 2
set to the current maxima is a no-op|base arc-burst pools-open|set-burst-maxima|0|-|primary=0/6 fallback=0/2|NOOP: burst maxima already|set-burst-maxima --primary-max 6 --fallback-max 2
set fails explicitly when a pool vanishes after admission|base arc-burst pools-open -- primary-vanishes-after-admission|set-burst-maxima|1|-|-|is absent or has no integer max_nodes|set-burst-maxima --primary-max 0 --fallback-max 2
set 7/1 is rejected|base arc-burst pools-open|-|2|-|primary=0/6 fallback=0/2|exceeds 6|set-burst-maxima --primary-max 7 --fallback-max 1
set 6/3 is rejected|base arc-burst pools-open|-|2|-|primary=0/6 fallback=0/2|exceeds 2|set-burst-maxima --primary-max 6 --fallback-max 3
set maxima flags are refused for other operations|base arc-burst pools-open|-|2|-|-|only valid for set-burst-maxima|enable-burst --primary-max 6 --fallback-max 2
remove with a node in a burst pool deletes nothing|race-node-registered|status|1|-|primary=0/6 fallback=0/2|zero nodes in 'github-runners-burst-amd-16g'|remove-burst
remove after one pool was deleted deletes the other|base arc-drain pool-fallback-closed|remove-burst|0|delete:fallback|primary=absent fallback=absent|-|remove-burst
remove from drain resets expanders then deletes both|drain-for-remove|remove-burst|0|expanders:,delete:primary,delete:fallback|primary=absent fallback=absent|READBACK: only github-runners-pool-16g remains|remove-burst
remove waits while DOKS still lists a deleted pool|drain-for-remove -- pool-delete-lingers|remove-burst|0|expanders:,delete:primary,delete:fallback|primary=absent fallback=absent|READBACK: pool 'github-runners-burst-amd-16g' no longer listed (read 3)|remove-burst
remove fails when a deleted pool stays listed past the deadline|drain-for-remove -- pool-delete-never|remove-burst|1|expanders:,delete:primary|primary=0/6 fallback=0/2|still listed 300s after its delete was accepted|remove-burst
remove from density with open pools is rejected|density-open-pools-remove|-|1|-|primary=0/6 fallback=0/2|at max_nodes=0|remove-burst
remove: provider count becomes 1 before the delete|drain-for-remove -- race-count-before-delete|remove-burst|1|expanders:|primary=0/6 fallback=0/2|provider count 0; found provider count 1|remove-burst
remove: a node registers before the delete|drain-for-remove -- race-node-before-delete|remove-burst|1|expanders:|primary=0/6 fallback=0/2|zero nodes in 'github-runners-burst-amd-16g'|remove-burst
remove: a runner pod schedules into the pool before the delete|drain-for-remove -- race-pod-before-delete|remove-burst|1|expanders:|primary=0/6 fallback=0/2|zero runner pods in 'github-runners-burst-amd-16g'|remove-burst
identity drift after a mutation stops the run|valid-density-no-burst -- drift-after-create|create-burst|3|create:primary|primary=0/0 fallback=absent|RESULT: identity drift after create closed pool github-runners-burst-amd-16g|create-burst
CASES

    # The expander update keeps the live (non-default) maintenance window and
    # leaves kubeconfig alone.
    dir=$(burst_dir base arc-density pool-primary-closed pool-fallback-closed) \
        || { fail "burst maintenance window: fixture could not be built"; return; }
    expect_burst "expander update keeps the maintenance window" "$dir" configure-expander 0 \
        expanders:priority,random,patch-configmap - "READBACK: maintenance window any=4:00" configure-expander
    if grep -q -- '--expanders priority,random --maintenance-window any=4:00 --surge-upgrade=true --update-kubeconfig=false' "${dir}/doctl.calls" \
        && [ "$(jq -c '.[] | select(.name == "redducklabs-cluster") | .maintenance_policy' "${dir}/cluster.json")" \
            = '{"start_time":"4:00","duration":"4h0m0s","day":"any"}' ]; then
        pass "burst expander update passes --maintenance-window any=4:00 and --update-kubeconfig=false; window still 4:00"
    else
        fail "burst expander update did not preserve the maintenance window: $(grep 'cluster update' "${dir}/doctl.calls")"
    fi

    # Ruling 40: DOKS creates the priority-expander ConfigMap only after the
    # expander update. The apply waits for it (bounded), patches data.priorities
    # with a merge patch that keeps the doks labels, and a re-run continues.
    dir=$(burst_dir base arc-density pool-primary-closed pool-fallback-closed -- configmap-appear-late) \
        || { fail "burst ConfigMap wait: fixture could not be built"; return; }
    expect_burst "expander apply waits three reads for the ConfigMap" "$dir" configure-expander 0 \
        expanders:priority,random,patch-configmap - "READBACK: expanders priority,random; ConfigMap priorities and managed label verified" configure-expander
    if [ "$(tr '\n' ' ' < "${dir}/sleep.calls" 2> /dev/null)" = "15 15 15 " ] \
        && [ "$(grep -c '^WAIT: ConfigMap kube-system/cluster-autoscaler-priority-expander not created by DOKS yet' "$BURST_OUT")" -eq 3 ] \
        && [ "$(jq -cS '.metadata.labels' "${dir}/expander-configmap.json")" \
            = '{"c3.doks.digitalocean.com/component":"cluster-autoscaler","c3.doks.digitalocean.com/plane":"data","doks.digitalocean.com/managed":"true"}' ]; then
        pass "burst ConfigMap wait: three 15 s sleeps, three WAIT lines; the merge patch kept all three doks labels"
    else
        fail "burst ConfigMap wait: sleeps '$(tr '\n' ' ' < "${dir}/sleep.calls" 2> /dev/null)', labels $(jq -c '.metadata.labels' "${dir}/expander-configmap.json" 2> /dev/null)"
    fi

    dir=$(burst_dir base arc-density pool-primary-closed pool-fallback-closed -- configmap-never-created) \
        || { fail "burst ConfigMap timeout: fixture could not be built"; return; }
    expect_burst "expander apply times out when DOKS never creates the ConfigMap" "$dir" configure-expander 1 \
        expanders:priority,random "primary=0/0 fallback=0/0" \
        "ConfigMap kube-system/cluster-autoscaler-priority-expander still absent after waiting 600s (41 reads, every 15s)" configure-expander
    if [ "$(wc -l < "${dir}/sleep.calls")" -eq 40 ] && [ "$(sort -u "${dir}/sleep.calls")" = 15 ] \
        && grep -q '^RESULT: failed: ConfigMap kube-system/cluster-autoscaler-priority-expander still absent' "$BURST_OUT" \
        && [ "$(jq -c '.[] | select(.name == "redducklabs-cluster") | .cluster_autoscaler_configuration.expanders' "${dir}/cluster.json")" = '["priority","random"]' ]; then
        pass "burst ConfigMap timeout: 40 sleeps of 15 s (600 s), RESULT failed, expanders set, pools still closed"
    else
        fail "burst ConfigMap timeout: $(wc -l < "${dir}/sleep.calls" 2> /dev/null) sleeps; $(grep '^RESULT' "$BURST_OUT")"
    fi
    # Re-run with the expanders already set: DOKS is still slow (two more
    # NotFound reads), so the re-run waits again, then patches.
    rm -f "${dir}/configmap-never-created"
    printf '2\n' > "${dir}/expander-configmap.pending"
    expect_burst "expander re-run after the timeout waits again, then patches" "$dir" configure-expander 0 \
        patch-configmap - "READBACK: DOKS created ConfigMap kube-system/cluster-autoscaler-priority-expander (read 3)" configure-expander
    if grep -q '^NOOP: cluster expanders already priority,random' "$BURST_OUT" && [ "$(wc -l < "${dir}/sleep.calls")" -eq 2 ]; then
        pass "burst ConfigMap re-run: expanders NOOP, two sleeps, then the patch"
    else
        fail "burst ConfigMap re-run: $(grep -E '^(NOOP|WAIT)' "$BURST_OUT" | tr '\n' '|')"
    fi
    expect_burst "expander re-run after completion is a no-op" "$dir" configure-expander 0 \
        - - "NOOP: priority expander ConfigMap already ranks" configure-expander
    [ ! -s "${dir}/sleep.calls" ] && pass "burst ConfigMap: a completed re-run does not sleep" \
        || fail "burst ConfigMap: a completed re-run slept $(wc -l < "${dir}/sleep.calls") times"

    # Identity drift between the admission snapshot and the run: no mutation.
    local operation start drifted
    while IFS='|' read -r operation layers args; do
        [ -n "$operation" ] || continue
        # shellcheck disable=SC2086
        start=$(burst_dir $layers) && drifted=$(burst_dir $layers -- baseline-uid-drift) \
            || { fail "burst drift ${operation}: fixture could not be built"; continue; }
        if ! burst_snapshot "$start" "$operation"; then
            fail "burst drift ${operation}: snapshot not admitted ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
            continue
        fi
        # shellcheck disable=SC2086
        run_burst "$drifted" "$BURST_SNAPSHOT" $args --apply
        code=$?
        if [ "$code" -eq 3 ] && [ "$(burst_mutations "$drifted")" = - ] && grep -q 'IDENTITY_DRIFT' "$BURST_ERR" \
            && grep -q '^RESULT: identity drift between the admission snapshot' "$BURST_OUT"; then
            pass "burst drift ${operation}: baseline identity drift before mutation -> exit 3, no mutation"
        else
            fail "burst drift ${operation}: exit ${code}, mutations $(burst_mutations "$drifted") ($(tail -c 300 "$BURST_ERR" | tr '\n' ' '))"
        fi
    done <<'CASES'
create-burst|valid-density-no-burst|create-burst
configure-expander|base arc-density pool-primary-closed pool-fallback-closed|configure-expander
enable-burst|enable-stage-closed|enable-burst
set-burst-maxima|base arc-burst pools-open|set-burst-maxima --primary-max 0 --fallback-max 2
remove-burst|density-closed-pools-remove|remove-burst
CASES

    # Partial-rollout recovery through the real gate and script; a re-run on
    # each postcondition is a no-op.
    local sequence
    while IFS='|' read -r sequence layers mutations; do
        [ -n "$sequence" ] || continue
        # shellcheck disable=SC2086
        dir=$(burst_dir $layers) || { fail "burst ${sequence}: fixture could not be built"; continue; }
        expect_burst "${sequence} -> remove-burst" "$dir" remove-burst 0 "$mutations" "primary=absent fallback=absent" - remove-burst
        expect_burst "${sequence} -> remove-burst re-run" "$dir" remove-burst 0 - "primary=absent fallback=absent" "NOOP: pool 'github-runners-burst-amd-16g' already absent" remove-burst
    done <<'CASES'
density + one closed pool|create-one-closed|delete:primary
density + two closed pools + expander|density-closed-pools-remove|expanders:,delete:primary,delete:fallback
CASES

    # The rollout's pool steps and their undo, chained in one stateful dir.
    dir=$(burst_dir base arc-density) || { fail "burst rollout chain: fixture could not be built"; return; }
    expect_burst "chain create-burst" "$dir" create-burst 0 create:primary,create:fallback "primary=0/0 fallback=0/0" - create-burst
    expect_burst "chain create-burst re-run" "$dir" create-burst 0 - "primary=0/0 fallback=0/0" - create-burst
    expect_burst "chain configure-expander" "$dir" configure-expander 0 expanders:priority,random,patch-configmap - - configure-expander
    expect_burst "chain configure-expander re-run" "$dir" configure-expander 0 - - - configure-expander
    expect_burst "chain remove-burst" "$dir" remove-burst 0 expanders:,delete:primary,delete:fallback "primary=absent fallback=absent" - remove-burst
}

# run_node_pool_workflow <dir> <inputs-json> <actual-sha> [kube-context]: runs
# every "run" step of node-pool-sizing.yml in order the way Actions does (the
# step's shell semantics; after a failure later steps are skipped unless
# "if: always()"),
# substituting inputs, step outputs and secrets. "git rev-parse HEAD" prints
# <actual-sha>. Prints "STEP <name>: success|failure|skipped" and the step
# summary on stdout; step output goes to stderr.
run_node_pool_workflow() {
    local dir=$1 inputs=$2 sha=$3 context=${4:-do-sfo3-redducklabs-cluster} gitfake
    gitfake=$(mktemp -d "${WORK_DIR}/gitfake.XXXXXX")
    printf '#!/bin/bash\n[ "$*" = "rev-parse HEAD" ] && { echo %q; exit 0; }\necho "fake git: unexpected $*" >&2\nexit 97\n' "$sha" > "${gitfake}/git"
    chmod +x "${gitfake}/git"
    grep -q '^auth init' "${dir}/doctl.routes" \
        || printf 'auth init --access-token fixture-token|empty.out\nkubernetes cluster kubeconfig save redducklabs-cluster|empty.out\n' >> "${dir}/doctl.routes"
    grep -q '^config use-context' "${dir}/kubectl.routes" \
        || printf 'config use-context do-sfo3-redducklabs-cluster|empty.out\nconfig current-context|current-context.out\n' >> "${dir}/kubectl.routes"
    printf '%s\n' "$context" > "${dir}/current-context.out"
    : > "${dir}/empty.out"
    rm -f "$dir"/*.calls "${dir}/mutations.log"
    with_fakes "$dir" env "NOW_CMD=echo ${POOL_STATE_NOW}" python3 -B "$ACTIONS_RUNNER" "$BURST_WORKFLOW" "$inputs" "$gitfake" "$REPO_ROOT" \
        > "$BURST_OUT" 2> "$BURST_ERR"
}

assert_node_pool_workflow() {
    info "Checking .github/workflows/node-pool-sizing.yml end to end against the stateful provider..."
    local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa other=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb dir rc
    dir=$(burst_dir valid-density-no-burst) || { fail "workflow fixture could not be built"; return; }
    run_node_pool_workflow "$dir" "{\"operation\":\"create-burst\",\"apply\":\"true\",\"expected_sha\":\"${other}\"}" "$sha"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(burst_mutations "$dir")" = - ] && [ ! -s "${dir}/doctl.calls" ] \
        && grep -qx 'STEP Validate inputs and expected SHA: failure' "$BURST_OUT" \
        && grep -qx 'STEP Run burst pool operation: skipped' "$BURST_OUT" \
        && grep -qx 'STEP Summary: success' "$BURST_OUT" && grep -qF "$other" "$BURST_ERR"; then
        pass "workflow: mismatched expected_sha stops before any doctl call; summary still runs"
    else
        fail "workflow: mismatched expected_sha -> exit ${rc}, mutations $(burst_mutations "$dir"), $(tr '\n' ' ' < "$BURST_OUT" | head -c 300)"
    fi

    run_node_pool_workflow "$dir" "{\"operation\":\"create-burst\",\"apply\":\"true\",\"expected_sha\":\"${sha}\"}" "$sha"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(burst_mutations "$dir")" = create:primary,create:fallback ] \
        && [ "$(burst_pools_state "$dir")" = "primary=0/0 fallback=0/0" ] \
        && grep -qF '| `github-runners-burst-amd-16g` | absent | 0/0 |' "$BURST_OUT" \
        && grep -qF '| `github-runners-burst-intel-16g` | absent | 0/0 |' "$BURST_OUT"; then
        pass "workflow: matching expected_sha runs admission then create-burst; summary lists before/after per pool"
    else
        fail "workflow: create-burst apply -> exit ${rc}, mutations $(burst_mutations "$dir"), $(tail -c 600 "$BURST_ERR" | tr '\n' ' ')"
    fi

    run_node_pool_workflow "$dir" "{\"operation\":\"configure-expander\",\"apply\":\"false\",\"expected_sha\":\"${sha}\"}" "$sha"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(burst_mutations "$dir")" = - ] && grep -q '^PLAN: set cluster expanders' "$BURST_ERR" \
        && grep -q '^PLAN: wait up to 600s for DOKS to create ConfigMap' "$BURST_ERR" \
        && grep -qF '**Dry run** `configure-expander`' "$BURST_OUT"; then
        pass "workflow: apply=false is a dry run that plans and changes nothing (ConfigMap not yet created by DOKS)"
    else
        fail "workflow: dry run -> exit ${rc}, mutations $(burst_mutations "$dir")"
    fi

    # A failing script must fail its step and the job (no masking by tee).
    local scenario expect
    while IFS='|' read -r scenario expect; do
        [ -n "$scenario" ] || continue
        dir=$(burst_dir valid-density-no-burst -- "$scenario") || { fail "workflow ${scenario}: fixture could not be built"; continue; }
        run_node_pool_workflow "$dir" "{\"operation\":\"create-burst\",\"apply\":\"true\",\"expected_sha\":\"${sha}\"}" "$sha"
        rc=$?
        if [ "$rc" -ne 0 ] && grep -qx 'STEP Run burst pool operation: failure' "$BURST_OUT" \
            && grep -qx 'STEP Summary: success' "$BURST_OUT" && grep -qF "$expect" "$BURST_OUT"; then
            pass "workflow: ${scenario} fails the operation step and the job; summary reports it"
        else
            fail "workflow: ${scenario} -> exit ${rc}, $(grep '^STEP' "$BURST_OUT" | tr '\n' ' ')"
        fi
    done <<'CASES'
drift-after-admission|**Result:** identity drift between the admission snapshot
scale-to-zero-rejected|**Result:** SCALE_TO_ZERO_REJECTED
CASES

    dir=$(burst_dir valid-density-no-burst) || { fail "workflow context fixture could not be built"; return; }
    run_node_pool_workflow "$dir" "{\"operation\":\"create-burst\",\"apply\":\"true\",\"expected_sha\":\"${sha}\"}" "$sha" some-other-context
    rc=$?
    if [ "$rc" -ne 0 ] && grep -qx 'STEP Configure DigitalOcean access: failure' "$BURST_OUT" \
        && [ "$(burst_mutations "$dir")" = - ] && grep -qF "kubectl context is 'some-other-context'" "$BURST_ERR"; then
        pass "workflow: a kubectl context other than the expected one stops before admission"
    else
        fail "workflow: wrong kubectl context -> exit ${rc}, $(grep '^STEP' "$BURST_OUT" | tr '\n' ' ')"
    fi

    local inputs reason
    while IFS='|' read -r reason inputs; do
        [ -n "$reason" ] || continue
        run_node_pool_workflow "$dir" "${inputs//@SHA@/$sha}" "$sha"
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$(burst_mutations "$dir")" = - ] && [ ! -s "${dir}/doctl.calls" ] \
            && grep -qx 'STEP Validate inputs and expected SHA: failure' "$BURST_OUT"; then
            pass "workflow: ${reason} is rejected during validation"
        else
            fail "workflow: ${reason} -> exit ${rc}, mutations $(burst_mutations "$dir")"
        fi
    done <<'CASES'
set-burst-maxima 7/1|{"operation":"set-burst-maxima","primary_max":"7","fallback_max":"1","apply":"true","expected_sha":"@SHA@"}
set-burst-maxima 6/3|{"operation":"set-burst-maxima","primary_max":"6","fallback_max":"3","apply":"true","expected_sha":"@SHA@"}
maxima on create-burst|{"operation":"create-burst","primary_max":"6","fallback_max":"2","apply":"true","expected_sha":"@SHA@"}
unknown operation|{"operation":"scale-up","apply":"true","expected_sha":"@SHA@"}
short expected_sha|{"operation":"create-burst","apply":"true","expected_sha":"aaaa"}
CASES

    if python3 - "$BURST_WORKFLOW" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    text = stream.read()
workflow = yaml.safe_load(text)
trigger = workflow.get("on", workflow.get(True))["workflow_dispatch"]["inputs"]
assert set(trigger) == {"operation", "primary_max", "fallback_max", "apply", "expected_sha"}, trigger
assert trigger["operation"]["type"] == "choice"
assert trigger["operation"]["options"] == ["create-burst", "configure-expander", "enable-burst",
                                           "set-burst-maxima", "remove-burst"]
assert trigger["apply"]["default"] is False and trigger["expected_sha"]["required"] is True
assert workflow["concurrency"] == {"group": "runner-fleet-mutation", "cancel-in-progress": False}
assert workflow["permissions"] == {"contents": "read"}
(job,) = workflow["jobs"].values()
assert job["runs-on"] == "ubuntu-latest" and "permissions" not in job
assert job.get("defaults") == {"run": {"shell": "bash"}}, "job must run steps with shell: bash (pipefail)"
names = [step.get("name") for step in job["steps"]]
validate = names.index("Validate inputs and expected SHA")
for index, step in enumerate(job["steps"]):
    run = step.get("run", "")
    if any(token in run for token in ("burst-pools.sh", "doctl", "kubectl", "verify-runner-pool-state.sh")):
        assert index > validate, f"{step.get('name')} runs before the expected_sha check"
    assert "${{ inputs." not in run and "${{ secrets." not in run, f"{step.get('name')} interpolates inputs/secrets into shell"
assert "--set-current-context" not in text
PY
    then
        pass "workflow: inputs, choice list, concurrency, permissions, runner and step order match the contract"
    else
        fail "workflow: static contract (inputs, concurrency, permissions, runner, SHA-first order) is violated"
    fi
}

# ---------------------------------------------------------------------------
# Deploy and Scale Runners operations (Task 6)
#
# Scenarios start from pool-state layers; test/fixtures/fleet/fleet_sim.py
# turns the fakes into a small runner fleet (ARC state, Helm history, runner
# pods, EphemeralRunners, GitHub runners, burst nodes) that changes on Helm
# writes, EphemeralRunner deletions and the passage of time (SLEEP_CMD). The
# workflows run end to end through test/lib/actions_runner.py; the
# trust-boundary job and the post-rollback trust read are stubbed (their own
# fixtures live in test/verify-runner-resources.sh). mutations.log is the
# ordered list of Helm/kubectl writes, e.g.
# "helm-upgrade:min=8,helm-upgrade:min=4,delete-er:r7,helm-upgrade:min=2".
# ---------------------------------------------------------------------------

FLEET_SIM="${FIXTURES}/fleet/fleet_sim.py"
DEPLOY_WORKFLOW="${REPO_ROOT}/.github/workflows/deploy-runners.yml"
SCALE_WORKFLOW="${REPO_ROOT}/.github/workflows/scale-runners.yml"
REBALANCE_WORKFLOW="${REPO_ROOT}/.github/workflows/rebalance-runners.yml"
FLEET_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FLEET_OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FLEET_OUT="${WORK_DIR}/fleet.out"
FLEET_ERR="${WORK_DIR}/fleet.err"
PHASE_C_EVIDENCE_FILE="${WORK_DIR}/phase-c-evidence.json"
FLEET_STUBS='{"stub_jobs": {"trust-boundary": "success"}, "stub_steps": {"Verify trust boundary after rollback": "success"}}'

# fleet_dir <scenario-json> <pool-state layers...>: a fresh stateful fleet dir.
fleet_dir() {
    local scenario=$1 src dir
    shift
    src=$(pool_state_dir "$@") || return 1
    dir=$(mktemp -d "${WORK_DIR}/fleet.XXXXXX")
    cp -r "${src}/." "${dir}/"
    rm -f "$dir"/*.calls
    printf '%s\n' "$POOL_STATE_NOW" > "${dir}/clock"
    : > "${dir}/empty.out"
    printf 'do-sfo3-redducklabs-cluster\n' > "${dir}/current-context.out"
    printf '{"serverVersion":{"major":"1","minor":"36"}}\n' > "${dir}/version.json"
    printf '{"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"eyJhdXRocyI6eyJyZWdpc3RyeS5kaWdpdGFsb2NlYW4uY29tIjp7ImF1dGgiOiJmaXh0dXJlIn19fQ=="}}\n' > "${dir}/registry-secret.json"
    printf '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"redducklabs-runners","meta.helm.sh/release-namespace":"arc-runners"}}}\n' > "${dir}/serviceaccount.json"
    printf '{"status":{"conditions":[{"type":"Established","status":"True"}]}}\n' > "${dir}/crd.json"
    cat >> "${dir}/doctl.routes" <<'ROUTES'
auth init --access-token fixture-token|empty.out
kubernetes cluster kubeconfig save redducklabs-cluster|empty.out
ROUTES
    cat >> "${dir}/kubectl.routes" <<'ROUTES'
config use-context do-sfo3-redducklabs-cluster|empty.out
config current-context|current-context.out
get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners -o json|runner-pods.json
get pods -n arc-runners -l actions.github.com/scale-set-name=redducklabs-runners|empty.out
get ephemeralrunners.actions.github.com -n arc-runners -o json|ephemeralrunners.json
get namespace arc-runners|empty.out
get secret do-registry-secret -n arc-runners -o json|registry-secret.json
get serviceaccount redducklabs-runners-gha-rs-no-permission -n arc-runners --ignore-not-found -o json|serviceaccount.json
get crd * -o json|crd.json
version -o json|version.json
ROUTES
    cat >> "${dir}/helm.routes" <<'ROUTES'
history redducklabs-runners -n arc-runners -o json|history.json
ROUTES
    printf '{"total_count": 0, "workflow_runs": []}\n' > "${dir}/gh-workflow-runs-none.json"
    cat > "${dir}/gh.routes" <<'ROUTES'
api repos/redducklabs/redducklabs-runners/actions/workflows/*|gh-workflow-runs-none.json
api user|empty.out
api --paginate --slurp *|gh-runners-slurp.json
api --paginate orgs/redducklabs/actions/runners?per_page=100|gh-runners.json
ROUTES
    printf '#!/bin/bash\nexec python3 -B %q %q sleep "$1"\n' "$FLEET_SIM" "$dir" > "${dir}/fakesleep"
    chmod +x "${dir}/fakesleep"
    python3 -B "$FLEET_SIM" "$dir" init "$scenario" || return 1
    printf '%s\n' "$FLEET_SIM" > "${dir}/stateful"
    printf '%s\n' "$dir"
}

fleet_mutations() {  # dir -> comma-separated mutation tokens, "-" for none
    local tokens
    tokens=$(paste -sd, "${1}/mutations.log" 2>/dev/null)
    printf '%s\n' "${tokens:--}"
}

fleet_arc() {  # dir -> current ARC layer name
    jq -r '.arc' "${1}/fleet.json"
}

# run_fleet_workflow <workflow> <dir> <inputs-json> [sha] [repo] [later-sha]:
# runs the workflow end to end; clears the logs first. "git rev-parse HEAD"
# prints <sha> (default FLEET_SHA); with <later-sha>, every read after the
# first prints <later-sha> (the checkout moved after validate-inputs).
run_fleet_workflow() {
    local workflow=$1 dir=$2 inputs=$3 sha=${4:-$FLEET_SHA} repo=${5:-$REPO_ROOT} later=${6:-} gitfake
    later=${later:-$sha}
    gitfake=$(mktemp -d "${WORK_DIR}/gitfake.XXXXXX")
    printf '#!/bin/bash\n[ "$*" = "rev-parse HEAD" ] || { echo "fake git: unexpected $*" >&2; exit 97; }\nif [ -e %q ]; then echo %q; else : > %q; echo %q; fi\n' \
        "${gitfake}/read" "$later" "${gitfake}/read" "$sha" > "${gitfake}/git"
    chmod +x "${gitfake}/git"
    rm -f "$dir"/*.calls "${dir}/mutations.log" "${dir}/cancel-requested"
    with_fakes "$dir" env "NOW_CMD=cat ${dir}/clock" "SLEEP_CMD=${dir}/fakesleep" \
        "ACTIONS_CANCEL_MARKER=${dir}/cancel-requested" "ACTIONS_GITHUB_CONTEXT=${FLEET_GITHUB_CONTEXT:-{\}}" "PHASE_C_EVIDENCE=${PHASE_C_EVIDENCE_FILE}" \
        GITHUB_REPOSITORY=redducklabs/redducklabs-runners \
        python3 -B "$ACTIONS_RUNNER" "$workflow" "$inputs" "$gitfake" "$repo" "$FLEET_STUBS" \
        > "$FLEET_OUT" 2> "$FLEET_ERR"
}

fleet_steps() { grep -E '^(STEP|JOB) ' "$FLEET_OUT" | tr '\n' ';' | head -c 900; }

# expect_fleet <label> <rc> <expected-rc> <mutations-glob> <final-arc|-> <line in stdout|-> <text in stderr|-> <dir>
expect_fleet() {
    local label=$1 rc=$2 expected_rc=$3 mutations=$4 arc=$5 line=${6:--} text=${7:--} dir=$8 actual
    actual=$(fleet_mutations "$dir")
    # shellcheck disable=SC2053 # <mutations> is a glob by design
    if { [ "$expected_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$expected_rc" != 0 ] && [ "$rc" -eq 0 ]; }; then
        fail "${label}: exit ${rc}, expected ${expected_rc} ($(fleet_steps)) $(grep -E 'ERROR|Error|REJECTED|IDENTITY' "$FLEET_ERR" | head -n 4 | tr '\n' ' ')"
    elif [[ "$actual" != $mutations ]]; then
        fail "${label}: mutations '${actual}', expected '${mutations}'"
    elif [ "$arc" != - ] && [ "$(fleet_arc "$dir")" != "$arc" ]; then
        fail "${label}: final ARC $(fleet_arc "$dir"), expected ${arc}"
    elif [ "$line" != - ] && ! grep -qxF -- "$line" "$FLEET_OUT"; then
        fail "${label}: stdout lacks '${line}' ($(fleet_steps))"
    elif [ "$text" != - ] && ! grep -qF -- "$text" "$FLEET_ERR"; then
        fail "${label}: output lacks '${text}' ($(grep -E 'ERROR|Error|REJECTED' "$FLEET_ERR" | head -n 4 | tr '\n' ' '))"
    else
        pass "${label}: exit ${rc}, mutations ${actual}"
    fi
}

FLEET_IDLE_BURST='{"arc": "arc-burst", "burst_nodes": [{"name": "github-runners-burst-amd-16g-p1q2r", "pool": "github-runners-burst-amd-16g"}], "runners": [{"name": "base0", "node": "baseline-a"}, {"name": "burstaa", "node": "github-runners-burst-amd-16g-p1q2r"}]}'
FLEET_BUSY_BURST='{"arc": "arc-burst", "knobs": {"sleep_scale": 60}, "burst_nodes": [{"name": "github-runners-burst-amd-16g-p1q2r", "pool": "github-runners-burst-amd-16g"}], "runners": [{"name": "base0", "node": "baseline-a"}, {"name": "burstbusy", "node": "github-runners-burst-amd-16g-p1q2r", "busy": true}]}'
FLEET_DENSITY_HISTORY='[{"revision": 12, "arc": "arc-density", "status": "superseded"}, {"revision": 13, "arc": "arc-burst", "status": "superseded"}, {"revision": 14, "arc": "arc-drain", "status": "deployed"}]'

# repo_with_values <python statements on `doc`>: a copy of the repository
# whose deploy/dind-values.yaml is mutated; prints its path.
repo_with_values() {
    local copy
    copy=$(mktemp -d "${WORK_DIR}/repo.XXXXXX")
    (cd "$REPO_ROOT" && tar --exclude=.git -cf - .) | (cd "$copy" && tar -xf -)
    mutate "${REPO_ROOT}/deploy/dind-values.yaml" "${copy}/deploy/dind-values.yaml" "$1" || return 1
    printf '%s\n' "$copy"
}

assert_deploy_ops() {
    info "Checking Deploy GitHub Runners operations end to end against the fleet fake..."
    local dir rc repo op inputs layers label scenario

    # deploy: density with both closed pools and the expander -> burst.
    dir=$(fleet_dir '{"arc": "arc-density", "runners": [{"name": "base0", "node": "baseline-a"}, {"name": "base1", "node": "baseline-b"}]}' base arc-density pools-closed) \
        || { fail "deploy fixture could not be built"; return; }
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "deploy from density" $? 0 apply-fence,apply-netpol,helm-upgrade:burst arc-burst "STEP Verify Helm transition and burst readback: success" - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "deploy re-run on burst" $? 0 apply-fence,apply-netpol,helm-upgrade:burst arc-burst - - "$dir"

    # Non-canonical committed bounds never reach Helm.
    for label in "2/10|doc['maxRunners'] = 10" "4/20|doc['minRunners'] = 4" "8/20|doc['minRunners'] = 8"; do
        repo=$(repo_with_values "${label#*|}") || { fail "deploy ${label%%|*}: repo copy failed"; continue; }
        dir=$(fleet_dir '{"arc": "arc-burst"}' base arc-burst pools-open)
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}" "$FLEET_SHA" "$repo"
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = - ] \
            && grep -qx 'STEP Validate committed burst values: failure' "$FLEET_OUT" \
            && ! grep -q '^template' "${dir}/helm.calls"; then
            pass "deploy rejects committed bounds ${label%%|*} before any Helm render or write"
        else
            fail "deploy with committed bounds ${label%%|*}: exit ${rc}, mutations $(fleet_mutations "$dir") ($(fleet_steps))"
        fi
        rm -rf "$repo"
    done

    # Admission webhook changes the safe-to-evict annotation -> no Helm write.
    for scenario in drop-annotation annotation-true; do
        dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"admission\": \"${scenario}\"}}" base arc-burst pools-open)
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
        expect_fleet "deploy with admission ${scenario}" $? 1 - arc-burst "STEP Server-side preflight candidate: failure" "safe-to-evict" "$dir"
    done

    # deploy is not admitted without the burst pools or from drain.
    dir=$(fleet_dir '{"arc": "arc-density"}' valid-density-no-burst)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "deploy without burst pools" $? 1 - arc-density "STEP Admit pool state and record identities: failure" "requires both burst pools" "$dir"
    dir=$(fleet_dir '{"arc": "arc-drain"}' base arc-drain pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "deploy from drain" $? 1 - arc-drain - "does not admit ARC state 'drain'" "$dir"

    # Mismatched SHA: no doctl/kubectl/helm call at all, for every operation.
    for op in deploy prepare-trust-boundary drain rollback; do
        dir=$(fleet_dir '{"arc": "arc-burst"}' base arc-burst pools-open)
        inputs="{\"operation\":\"${op}\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_OTHER_SHA}\"}"
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$inputs"
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = - ] && ! ls "$dir"/*.calls >/dev/null 2>&1 \
            && grep -qx 'JOB validate-inputs: failure' "$FLEET_OUT"; then
            pass "deploy ${op}: mismatched expected_sha stops before any doctl, kubectl or helm call"
        else
            fail "deploy ${op}: mismatched expected_sha -> exit ${rc}, mutations $(fleet_mutations "$dir"), calls $(cat "$dir"/*.calls 2>/dev/null | head -c 200)"
        fi
    done

    # drain: an idle runner on a burst node, no demand -> retired, pools reach zero.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain with an idle burst runner" $? 0 helm-upgrade:drain,delete-er:burstaa arc-drain "STEP Drain runners: success" "DRAIN_COMPLETE" "$dir"
    if [ "$(jq '[.runners[] | select(.node | startswith("github-runners-pool-16g"))] | length' "${dir}/fleet.json")" = 2 ] \
        && [ "$(jq '.burst_nodes | length' "${dir}/fleet.json")" = 0 ]; then
        pass "drain: the warm floor was replaced on baseline and the burst node scaled down"
    else
        fail "drain: final placement $(jq -c '[.runners[].node, .burst_nodes]' "${dir}/fleet.json")"
    fi
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain re-run on its postcondition" $? 0 - arc-drain - "NOOP: ARC is already drain" "$dir"

    # drain: a busy job on a burst node never finishes -> deadline, ARC left in drain.
    dir=$(fleet_dir "$FLEET_BUSY_BURST" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain deadline with a busy burst runner" $? 1 helm-upgrade:drain arc-drain "STEP Drain runners: failure" "DRAIN_DEADLINE" "$dir"
    if [ $(( $(cat "${dir}/clock") - POOL_STATE_NOW )) -ge 18000 ] && ! grep -q '^rollback' "${dir}/helm.calls"; then
        pass "drain deadline: stopped at 300 minutes of the fake clock with no rollback attempted"
    else
        fail "drain deadline: clock advanced $(( $(cat "${dir}/clock") - POOL_STATE_NOW ))s; helm calls $(grep -c . "${dir}/helm.calls")"
    fi
    # The job finishes later; the retry resumes the wait without another Helm write.
    jq '.knobs.busy_until = 0' "${dir}/fleet.json" > "${dir}/fleet.next" && mv "${dir}/fleet.next" "${dir}/fleet.json"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain retry after the deadline" $? 0 - arc-drain - "DRAIN_COMPLETE" "$dir"

    # drain admits an interrupted Phase C at 8/20 and 4/20.
    for layers in arc-burst-acceptance-8 arc-burst-acceptance-4; do
        dir=$(fleet_dir "{\"arc\": \"${layers}\"}" base "$layers" pools-open)
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
        expect_fleet "drain from interrupted ${layers#arc-}" $? 0 helm-upgrade:drain arc-drain - - "$dir"
    done

    # Ruling 34: drain no longer takes rollback_revision. The input is not
    # declared, so a dispatch that names it is rejected before anything runs
    # (GitHub answers "Unexpected inputs provided"), and the drain job has no
    # rollback-revision step.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"drain\",\"rollback_revision\":\"12\",\"expected_sha\":\"${FLEET_SHA}\"}"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = - ] && ! ls "$dir"/*.calls >/dev/null 2>&1 \
        && grep -q '^DISPATCH REJECTED: Unexpected inputs provided' "$FLEET_OUT"; then
        pass "drain with rollback_revision: rejected as an undeclared input before any call"
    else
        fail "drain with rollback_revision: exit ${rc}, mutations $(fleet_mutations "$dir") ($(fleet_steps))"
    fi
    if python3 - "$DEPLOY_WORKFLOW" <<'PY'
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert "rollback_revision" not in workflow[True]["workflow_dispatch"]["inputs"]
assert "rollback_revision" not in workflow["jobs"]["validate-inputs"]["outputs"]
for job in ("drain", "rollback"):
    for step in workflow["jobs"][job]["steps"]:
        assert "rollback_revision" not in str(step), (job, step.get("name"))
        assert step.get("name") != "Validate rollback revision", job
PY
    then
        pass "Deploy declares no rollback_revision input and drain/rollback never read one"
    else
        fail "Deploy still declares or reads rollback_revision"
    fi

    # Ruling 34: the rollback target is independent of Helm history. More than
    # 100 revisions, none of them density: drain and rollback still complete,
    # and rollback upgrades to deploy/density-values.yaml.
    local long_history
    long_history=$(jq -nc '[range(21; 120) | {"revision": ., "arc": (if . % 2 == 0 then "arc-burst" else "arc-burst-acceptance-8" end), "status": "superseded"}]
        + [{"revision": 120, "arc": "arc-burst", "status": "deployed"}]')
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"history\": ${long_history}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}]}" base arc-burst pools-open)
    if [ "$(jq '[.history[] | select(.arc == "arc-density")] | length' "${dir}/fleet.json")" = 0 ] \
        && [ "$(jq '.history | max_by(.revision) | .revision' "${dir}/fleet.json")" -gt 100 ]; then
        pass "history fixture: revisions past 100 and no density revision left in helm history"
    else
        fail "history fixture: $(jq -c '[.history[] | .revision] | [min, max, length]' "${dir}/fleet.json")"
    fi
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain with no density revision in a >100-revision history" $? 0 helm-upgrade:drain arc-drain "STEP Drain runners: success" "DRAIN_COMPLETE" "$dir"
    remove_burst_pools "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rollback after more than 100 revisions" $? 0 apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"
    if grep -q -- '--values deploy/density-values.yaml' "${dir}/helm.calls" \
        && grep -E '^upgrade .*--values deploy/density-values.yaml' "${dir}/helm.calls" | grep -q -- '--history-max 100' \
        && grep -E '^upgrade .*--values deploy/density-values.yaml' "${dir}/helm.calls" | grep -q -- '--post-renderer' \
        && ! grep -q '^rollback' "${dir}/helm.calls" && [ "$(jq '.history | length' "${dir}/fleet.json")" -le 100 ]; then
        pass "rollback: helm upgrade to deploy/density-values.yaml behind the hash post-renderer, --history-max 100, no helm rollback"
    else
        fail "rollback Helm calls: $(grep -E '^(upgrade|rollback|template)' "${dir}/helm.calls" | cut -c1-160 | tr '\n' ' ')"
    fi

    # rollback.
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}}" base arc-drain pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rollback with burst pools present" $? 1 - arc-drain "STEP Admit rollback state and record identities: failure" "requires no burst pools" "$dir"
    # Ruling 34: committed density values that fail validation never reach Helm.
    for label in "2/10|doc['maxRunners'] = 10" "burst affinity|doc['template']['spec']['affinity'] = {'nodeAffinity': {}}" "private group|doc['runnerGroup'] = 'default'"; do
        repo=$(mktemp -d "${WORK_DIR}/repo.XXXXXX")
        (cd "$REPO_ROOT" && tar --exclude=.git -cf - .) | (cd "$repo" && tar -xf -)
        mutate "${REPO_ROOT}/deploy/density-values.yaml" "${repo}/deploy/density-values.yaml" "${label#*|}" \
            || { fail "rollback ${label%%|*}: repo copy failed"; continue; }
        dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}}" base arc-drain)
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}" "$FLEET_SHA" "$repo"
        expect_fleet "rollback with committed density values (${label%%|*})" $? 1 - arc-drain "STEP Roll back to committed density values: failure" "is not the density contract (2/4)" "$dir"
        if grep -Eq '^(upgrade|rollback|template)' "${dir}/helm.calls"; then
            fail "rollback with invalid density values (${label%%|*}) reached helm template/upgrade"
        else
            pass "rollback with invalid density values (${label%%|*}) stops before any Helm render or write"
        fi
        rm -rf "$repo"
    done
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}}" base arc-drain)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rollback from drain without pools" $? 0 apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rollback re-run on density" $? 0 - arc-density "STEP Roll back to committed density values: success" "rollback is a no-op" "$dir"

    # A momentarily Pending runner pod does not fail the density postcondition.
    dir=$(fleet_dir "{\"arc\": \"arc-density\", \"history\": ${FLEET_DENSITY_HISTORY}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}, {\"name\": \"pending0\", \"node\": \"\"}]}" valid-density-no-burst)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(fleet_mutations "$dir")" = - ] && ! grep -Eq '^(rollback|upgrade)' "${dir}/helm.calls" \
        && [ "$(jq '[.items[] | select(.status.phase == "Pending")] | length' "${dir}/runner-pods.json")" = 1 ]; then
        pass "rollback re-run on density with a Pending runner pod: success, no Helm call"
    else
        fail "rollback re-run on density with a Pending runner pod: exit ${rc}, mutations $(fleet_mutations "$dir") ($(fleet_steps))"
    fi

    # The checkout moves after validate-inputs: each mutating job re-checks the SHA first.
    dir=$(fleet_dir '{"arc": "arc-density"}' base arc-density pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}" "$FLEET_SHA" "$REPO_ROOT" "$FLEET_OTHER_SHA"
    expect_fleet "deploy with the checkout moved after validation" $? 1 - arc-density "STEP Apply Emergency Stop fence: failure" "does not match checked-out SHA" "$dir"
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS" "$FLEET_SHA" "$REPO_ROOT" "$FLEET_OTHER_SHA"
    expect_fleet "drain with the checkout moved after validation" $? 1 - arc-burst "STEP Drain runners: failure" "checked-out SHA changed" "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}}" base arc-drain)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}" "$FLEET_SHA" "$REPO_ROOT" "$FLEET_OTHER_SHA"
    expect_fleet "rollback with the checkout moved after validation" $? 1 - arc-drain "STEP Roll back to committed density values: failure" "does not match checked-out SHA" "$dir"
}

assert_rebalance_workflow() {
    info "Checking the Rebalance Runners workflow..."
    local dir rc ctx_schedule ctx_branch ctx_dispatch
    ctx_schedule="{\"event_name\":\"schedule\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\"}"
    ctx_branch="{\"event_name\":\"schedule\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/feature\"}"
    ctx_dispatch="{\"event_name\":\"workflow_dispatch\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\"}"

    if (cd "$REPO_ROOT" && python3 - "$REBALANCE_WORKFLOW") <<'PY'
import os
import re
import sys

import yaml

text = open(sys.argv[1], encoding="utf-8").read()
workflow = yaml.safe_load(text)
on = workflow[True]
assert on["schedule"] == [{"cron": "17 * * * *"}]
assert on["workflow_dispatch"]["inputs"]["expected_sha"]["required"] is True
# Ruling 28: Rebalance has its own group, so it never queues behind (or
# displaces a pending run of) a long fleet mutation in runner-fleet-mutation.
assert workflow["concurrency"] == {"group": "runner-rebalance", "cancel-in-progress": False}
assert workflow["permissions"] == {"contents": "read", "actions": "read"}
(job,) = workflow["jobs"].values()
assert job["runs-on"] == "ubuntu-latest" and "permissions" not in job
assert job["defaults"] == {"run": {"shell": "bash"}}
names = [s.get("name") for s in job["steps"]]
runs = {s.get("name"): s.get("run", "") for s in job["steps"]}
assert names.index("Validate run source and SHA") < names.index("Check for in-flight fleet mutations") \
    < names.index("Configure Kubernetes access") \
    < names.index("Admit pool state and record identities") < names.index("Retire idle burst runners")
inflight = job["steps"][names.index("Check for in-flight fleet mutations")]
assert inflight["env"]["GH_TOKEN"] == "${{ secrets.GITHUB_TOKEN }}"
assert "if" not in inflight, "the in-flight check runs for scheduled and dispatched runs"
for name in ("deploy-runners.yml", "scale-runners.yml", "node-pool-sizing.yml", "emergency-stop.yml"):
    assert name in inflight["run"], name
for status in ("queued", "in_progress", "waiting", "pending", "requested"):
    assert status in inflight["run"], status
for later in ("Configure Kubernetes access", "Check whether there is anything to rebalance",
              "Admit pool state and record identities", "Retire idle burst runners"):
    assert "steps.inflight.outputs.busy != 'true'" in job["steps"][names.index(later)]["if"], later
gate = runs["Admit pool state and record identities"]
assert "--operation rebalance" in gate and "--emit-identities" in gate
retire = job["steps"][names.index("Retire idle burst runners")]
assert "--identities" in retire["run"] and retire["env"]["GH_TOKEN"] == "${{ secrets.RUNNER_TOKEN }}"
assert retire["run"].index("git rev-parse HEAD") < retire["run"].index("retire-idle-burst-runners.sh")
validate = runs["Validate run source and SHA"]
assert "refs/heads/main" in validate and "EVENT_SHA" in validate
for step in job["steps"]:
    run = step.get("run", "")
    assert "${{ inputs." not in run and "${{ secrets." not in run and "${{ github." not in run, step.get("name")
assert "--set-current-context" not in text
assert not re.search(r"(kubectl (delete|patch|apply)|helm (install|upgrade|rollback|uninstall))", text)
for script in set(re.findall(r"\./(scripts/[a-z0-9-]+\.sh)", text)):
    assert os.access(script, os.X_OK), f"{script} is not executable"
PY
    then
        pass "Rebalance Runners: schedule, dispatch SHA input, own lock, in-flight check, hosted runner, gate operation and token match the contract"
    else
        fail "Rebalance Runners static workflow contract is violated"
    fi
    if [ "$(git -C "$REPO_ROOT" ls-files -s scripts/retire-idle-burst-runners.sh | cut -c1-6)" = 100755 ]; then
        pass "scripts/retire-idle-burst-runners.sh is committed executable"
    else
        fail "scripts/retire-idle-burst-runners.sh is not committed with mode 100755"
    fi

    # Scheduled main run: the idle burst runner is retired.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "rebalance on schedule from main" $? 0 delete-er:burstaa arc-burst "STEP Retire idle burst runners: success" - "$dir"

    # Dispatch with the matching SHA works.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    FLEET_GITHUB_CONTEXT=$ctx_dispatch run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "{\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rebalance dispatch with the matching expected_sha" $? 0 delete-er:burstaa arc-burst - - "$dir"

    # Nothing runs before the SHA/ref checks: no doctl, kubectl, helm or gh call at all.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    rebalance_rejected "dispatch with a mismatched expected_sha" "$ctx_dispatch" "{\"expected_sha\":\"${FLEET_OTHER_SHA}\"}" "$dir"
    rebalance_rejected "dispatch with a non-SHA expected_sha" "$ctx_dispatch" '{"expected_sha":"main"}' "$dir"
    rebalance_rejected "dispatch without expected_sha" "$ctx_dispatch" '{}' "$dir"
    rebalance_rejected "schedule with github.ref not main" "$ctx_branch" '{}' "$dir"
    rebalance_rejected "schedule with HEAD different from github.sha" "$ctx_schedule" '{}' "$dir" "$FLEET_OTHER_SHA"

    # The checkout moves after validation: the deleting step re-checks.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}' "$FLEET_SHA" "$REPO_ROOT" "$FLEET_OTHER_SHA"
    expect_fleet "rebalance with the checkout moved after validation" $? 1 - arc-burst "STEP Retire idle burst runners: failure" "checked-out SHA changed" "$dir"

    # Dispatch never takes the skip path: density is rejected by the gate.
    dir=$(fleet_dir '{"arc": "arc-density"}' valid-density-no-burst)
    FLEET_GITHUB_CONTEXT=$ctx_dispatch run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "{\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rebalance dispatch on density (gate rejects)" $? 1 - arc-density "STEP Admit pool state and record identities: failure" - "$dir"
    if grep -qx 'STEP Retire idle burst runners: skipped' "$FLEET_OUT" && grep -qx 'STEP Check whether there is anything to rebalance: skipped' "$FLEET_OUT"; then
        pass "rebalance dispatch gate failure skips the status probe and retirement"
    else
        fail "rebalance dispatch on density did not skip probe and retirement ($(fleet_steps))"
    fi

    # Schedule with nothing to rebalance (density, no pools / density with closed pools): success + notice.
    for layers in "valid-density-no-burst" "base arc-density pools-closed"; do
        # shellcheck disable=SC2086 # layers is a word list by design
        dir=$(fleet_dir '{"arc": "arc-density"}' $layers)
        FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
        expect_fleet "rebalance schedule with nothing to rebalance (${layers})" $? 0 - arc-density "STEP Check whether there is anything to rebalance: success" - "$dir"
        if grep -q '^nothing to rebalance: arc=density' "$FLEET_OUT" "$FLEET_ERR" \
            && sed -n '/^SUMMARY-BEGIN/,$p' "$FLEET_OUT" | grep -q '^nothing to rebalance: arc=density' \
            && grep -qx 'STEP Admit pool state and record identities: skipped' "$FLEET_OUT" \
            && grep -qx 'STEP Retire idle burst runners: skipped' "$FLEET_OUT" \
            && ! grep -q 'actions/runners' "${dir}/gh.calls" 2>/dev/null; then
            pass "rebalance nothing-to-rebalance: notice in the summary, gate and retirement skipped, no runner API call"
        else
            fail "rebalance nothing-to-rebalance (${layers}) lacks the notice or ran the gate/retirement ($(fleet_steps))"
        fi
    done

    # Schedule on a state the status read accepts but rebalance does not: the run fails.
    dir=$(fleet_dir '{"arc": "arc-burst-acceptance-8"}' base arc-burst-acceptance-8 pools-open)
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "rebalance schedule when the rebalance gate rejects a burst-pool state" $? 1 - arc-burst-acceptance-8 "STEP Admit pool state and record identities: failure" - "$dir"
    if grep -qx 'STEP Check whether there is anything to rebalance: success' "$FLEET_OUT" \
        && grep -qx 'STEP Retire idle burst runners: skipped' "$FLEET_OUT"; then
        pass "rebalance gate rejection after the probe fails the run and skips retirement"
    else
        fail "rebalance gate rejection path wrong ($(fleet_steps))"
    fi

    # Ruling 29: drain with no burst pools is also nothing to rebalance.
    dir=$(fleet_dir '{"arc": "arc-drain"}' base arc-drain)
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "rebalance schedule on drain without burst pools" $? 0 - arc-drain "STEP Admit pool state and record identities: skipped" - "$dir"
    if fleet_summary | grep -q '^nothing to rebalance: arc=drain pools=none'; then
        pass "rebalance on drain without burst pools: notice in the summary"
    else
        fail "rebalance on drain without burst pools lacks the notice ($(fleet_steps))"
    fi
    # Ruling 29: any other state goes to the gate; burst with no pools fails red.
    for layers in "base arc-burst" "base arc-burst-acceptance-8" "base arc-drain pools-open"; do
        # shellcheck disable=SC2086 # layers is a word list by design
        dir=$(fleet_dir "{\"arc\": \"$(cut -d' ' -f2 <<<"$layers")\"}" $layers)
        FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
        rc=$?
        case "$layers" in
            "base arc-drain pools-open")
                expect_fleet "rebalance schedule on drain with burst pools (gate admits)" $rc 0 - arc-drain "STEP Admit pool state and record identities: success" - "$dir"
                ;;
            *)
                expect_fleet "rebalance schedule on ${layers#base } (gate rejects, run fails)" $rc 1 - - "STEP Admit pool state and record identities: failure" - "$dir"
                ;;
        esac
    done

    # Ruling 28: a queued or running fleet mutation -> notice, no cluster access at all.
    local ctx
    for ctx in "$ctx_schedule" "$ctx_dispatch"; do
        dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
        printf '{"total_count": 1, "workflow_runs": [{"id": 4242, "status": "in_progress", "html_url": "https://github.com/redducklabs/redducklabs-runners/actions/runs/4242"}]}\n' \
            > "${dir}/gh-workflow-runs-active.json"
        sed -i '1i api repos/redducklabs/redducklabs-runners/actions/workflows/deploy-runners.yml/runs?status=in_progress*|gh-workflow-runs-active.json' "${dir}/gh.routes"
        FLEET_GITHUB_CONTEXT=$ctx run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "{\"expected_sha\":\"${FLEET_SHA}\"}"
        expect_fleet "rebalance while Deploy is in progress ($(jq -r .event_name <<<"$ctx"))" $? 0 - arc-burst "STEP Retire idle burst runners: skipped" - "$dir"
        if [ ! -s "${dir}/kubectl.calls" ] && [ ! -s "${dir}/doctl.calls" ] && [ ! -s "${dir}/helm.calls" ] \
            && fleet_summary | grep -q '^nothing to rebalance: a fleet mutation is queued or running (deploy-runners.yml in_progress)'; then
            pass "rebalance in-flight skip ($(jq -r .event_name <<<"$ctx")): notice, no doctl/kubectl/helm call"
        else
            fail "rebalance in-flight skip ($(jq -r .event_name <<<"$ctx")): calls or notice wrong ($(fleet_steps))"
        fi
    done
    # Each fleet mutator and status is queried.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    local wf status missing=""
    for wf in deploy-runners.yml scale-runners.yml node-pool-sizing.yml emergency-stop.yml; do
        for status in queued in_progress waiting pending requested; do
            grep -q "^api repos/redducklabs/redducklabs-runners/actions/workflows/${wf}/runs?status=${status}&per_page=1$" "${dir}/gh.calls" \
                || missing="${missing} ${wf}:${status}"
        done
    done
    if [ -z "$missing" ]; then
        pass "rebalance queries every fleet mutator for queued, in-progress, waiting, pending and requested runs"
    else
        fail "rebalance in-flight check misses:${missing}"
    fi
    # A failed run-listing read fails the run before any cluster access.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    echo 1 > "${dir}/gh-workflow-runs-none.json.rc"
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "rebalance with a failed workflow-run read" $? 1 - arc-burst "STEP Check for in-flight fleet mutations: failure" - "$dir"
    if [ ! -s "${dir}/kubectl.calls" ] && [ ! -s "${dir}/doctl.calls" ]; then
        pass "rebalance failed workflow-run read stops before any cluster access"
    else
        fail "rebalance failed workflow-run read still reached the cluster"
    fi

    # Schedule with a failed status read: the run fails and nothing is deleted.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    rm -f "${dir}/nodes.json"
    FLEET_GITHUB_CONTEXT=$ctx_schedule run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "rebalance schedule with a failed status read" $? 1 - arc-burst "STEP Check whether there is anything to rebalance: failure" - "$dir"
    if grep -qx 'STEP Admit pool state and record identities: skipped' "$FLEET_OUT"; then
        pass "rebalance failed status read stops before the gate and retirement"
    else
        fail "rebalance failed status read ran later steps ($(fleet_steps))"
    fi
}

# Operator docs must not describe retired behaviour: the first-install
# bootstrap at zero runners (Ruling 15), Deploy min/max inputs with a ceiling
# of 4, or a fleet fixed at two nodes and four runners.
assert_operator_docs_current() {
    info "Checking README, SETUP, SECURITY, runbook and AOR-2 for retired behaviour..."
    if (cd "$REPO_ROOT" && python3 -) <<'PY'
import re

def flat(path):
    return " ".join(open(path, encoding="utf-8").read().split())

readme, setup, security = flat("README.md"), flat("docs/SETUP.md"), flat("docs/SECURITY.md")
runbook, dismissals = flat("docs/runbooks/node-pool-sizing.md"), flat("docs/security/vulnerability-dismissals.md")
problems = []
for name, text in (("README.md", readme), ("docs/SETUP.md", setup), ("docs/SECURITY.md", security)):
    for retired in ("at zero runners", "bootstrapped at zero", "with `minRunners=0` and `maxRunners=0`, verifies exact Helm ownership",
                    "Min runners", "Max runners", "default and ceiling: 4", "4 maximum by default"):
        if retired in text:
            problems.append(f"{name} still says: {retired}")
    if "no first-install bootstrap" not in text:
        problems.append(f"{name} does not state that there is no first-install bootstrap (Ruling 15)")
for name, text in (("README.md", readme), ("docs/SETUP.md", setup), ("docs/SECURITY.md", security), ("runbook", runbook)):
    for retired in ("scale-up", "scale-custom", "rollout-quiesce", "Emergency Stop is unchanged"):
        if re.search(r"`" + re.escape(retired) + r"`|action=" + re.escape(retired), text) or retired == "Emergency Stop is unchanged" and retired in text:
            problems.append(f"{name} mentions retired {retired}")
raw = open("docs/security/vulnerability-dismissals.md", encoding="utf-8").read()
start = raw.index("### AOR-2")
following = re.search(r"^### ", raw[start + 5:], re.M)
aor2 = " ".join(raw[start:start + 5 + following.start() if following else len(raw)].split())
if "fixed-capacity checks" in aor2 or "fixes the fleet at two $96 nodes and four runners" in aor2:
    problems.append("AOR-2 still describes the fixed 2-node / 4-runner fleet")
for required in ("up to eight burst nodes", "at most 10 runner nodes and 20 runners", "pool-state gate", "identity bracket"):
    if required not in aor2:
        problems.append(f"AOR-2 lacks: {required}")
# Rulings 33-34 and PR #35 review finding 3.
spec = flat("docs/specs/2026-10-26-runner-burst-autoscaling-design.md")
for name, text in (("README.md", readme), ("docs/SETUP.md", setup), ("runbook", runbook)):
    if "rollback_revision" in text or "ROLLBACK_REVISION" in text:
        problems.append(f"{name} still passes a rollback_revision (Ruling 34)")
for name, text in (("runbook", runbook), ("spec", spec)):
    for required in ("runner-fleet-emergency-stop", "acknowledge_emergency_stop=true", "deploy/density-values.yaml",
                     "no alternate Phase B shape", "--reuse-values"):
        if required not in text:
            problems.append(f"{name} lacks: {required}")
    for retired in ("primary_max=1", "`max_nodes=1` with N=10", "jobs=10"):
        if retired in text:
            problems.append(f"{name} still documents the alternate Phase B shape: {retired}")
if "STOP_FENCE" not in runbook:
    problems.append("runbook does not explain a STOP_FENCE failure")
for problem in problems:
    print(problem)
assert not problems
PY
    then
        pass "README, SETUP, SECURITY, runbook and AOR-2 describe the burst fleet (no bootstrap, no min/max inputs, no fixed 2/4)"
    else
        fail "operator docs still describe retired behaviour"
    fi
}

# Ruling 30: public docs record collaborator counts and roles, never an
# individual collaborator's login (the owner's is the repository owner).
assert_admission_docs_name_no_collaborator() {
    info "Checking that admission records do not name individual collaborators..."
    if (cd "$REPO_ROOT" && python3 -) <<'PY'
import re

phrase = "one write collaborator besides the owner (accepted by the owner as a trusted co-tenant on 2026-10-26)"
evidence = open("docs/security/runner-admission/superfood-shred.md", encoding="utf-8").read()
dismissals = open("docs/security/vulnerability-dismissals.md", encoding="utf-8").read()
flat = lambda text: " ".join(text.split())  # Markdown wraps lines
assert phrase in flat(evidence) and phrase in flat(dismissals), "the agreed wording is missing"
section = evidence[evidence.index("## Collaborators with write access"):evidence.index("## Workflow trigger audit")]
rows = [line for line in section.splitlines() if line.startswith("| ") and "---" not in line][1:]
assert len(rows) == 2, rows
assert rows[0] == "| `aronweiler` | admin (owner) |", rows[0]
assert rows[1] == f"| {phrase} | write (organization member) |", rows[1]
# Prose names the collaborator only by count and role.
prose = re.sub(r"\s+", " ", section.split("|")[-1])
assert re.search(r"The write collaborator can push branches", prose), prose[:200]
PY
    then
        pass "superfood-shred admission record and AOR-2 name no individual write collaborator (counts and roles kept)"
    else
        fail "an admission record names an individual collaborator or lost the count/role wording"
    fi
}

# CI's bash -n loop and shellcheck pass must cover the sourced libraries in
# scripts/lib as well as the top-level scripts.
assert_ci_lint_coverage() {
    info "Checking that Validate Configuration lints scripts/lib/*.sh..."
    if (cd "$REPO_ROOT" && python3 -) <<'PY'
import yaml

workflow = yaml.safe_load(open(".github/workflows/validate-config.yml", encoding="utf-8"))
steps = {step.get("name"): step.get("run", "") for job in workflow["jobs"].values() for step in job["steps"]}
syntax = steps["Check shell script syntax"]
assert "for s in scripts/*.sh scripts/lib/*.sh test/*.sh deploy/*.sh" in syntax, "bash -n loop misses scripts/lib/*.sh"
lint = steps["Shellcheck (errors only)"]
assert "shellcheck -S error scripts/*.sh scripts/lib/*.sh test/*.sh deploy/*.sh" in lint, "shellcheck misses scripts/lib/*.sh"
PY
    then
        pass "Validate Configuration runs bash -n and shellcheck over scripts/lib/*.sh"
    else
        fail "Validate Configuration does not lint scripts/lib/*.sh"
    fi
}

# Ruling 27: every Helm write in the repository keeps 100 revisions, so the
# density revision recorded before a rollout is never pruned before rollback.
assert_helm_history_max() {
    info "Checking that every helm upgrade/rollback passes --history-max 100..."
    if (cd "$REPO_ROOT" && python3 -) <<'PY'
import glob
import re

files = sorted(set(
    glob.glob(".github/workflows/*.yml") + glob.glob("scripts/*.sh") + glob.glob("scripts/lib/*.sh")
    + glob.glob("deploy/*.sh") + glob.glob("docs/**/*.md", recursive=True) + ["README.md"]
))
found, missing = 0, []
for path in files:
    path = path.replace("\\", "/")
    if path.startswith("docs/plans/") or path.startswith("docs/specs/"):
        continue  # historical design records, not commands anyone runs
    lines = open(path, encoding="utf-8").read().split("\n")
    if path.endswith(".md"):
        # Markdown: only commands inside fenced code blocks.
        fenced, inside = [], False
        for line in lines:
            if line.lstrip().startswith("```"):
                inside = not inside
                fenced.append("")
            else:
                fenced.append(line if inside else "")
        lines = fenced
    index = 0
    while index < len(lines):
        line = lines[index]
        start = index
        command = line
        while command.rstrip().endswith("\\") and index + 1 < len(lines):
            index += 1
            command = command.rstrip()[:-1] + " " + lines[index].strip()
        index += 1
        stripped = command.strip()
        if stripped.startswith(("#", "echo ")) or re.match(r"^fleet_helm_bracket\(\)", stripped):
            continue
        is_write = re.search(r"\bhelm\s+(upgrade|rollback)\b", command) or (
            re.search(r"\bfleet_helm_bracket\b", command) and re.search(r"\b(upgrade|rollback)\b", command))
        if not is_write or "helm upgrade/rollback" in command:
            continue
        found += 1
        if "--history-max 100" not in command:
            missing.append(f"{path}:{start + 1}: {stripped[:120]}")
for item in missing:
    print(f"missing --history-max 100: {item}")
assert found >= 8, f"only {found} Helm writes found; the scan is broken"
assert not missing
PY
    then
        pass "every helm upgrade/rollback in workflows, scripts, deploy scripts and docs passes --history-max 100"
    else
        fail "a helm upgrade/rollback lacks --history-max 100"
    fi
}

# ---------------------------------------------------------------------------
# Emergency Stop (Rulings 26 and 28): it runs in its own non-cancelling
# concurrency group, leaves the fleet in a stopped state the gate classifies,
# and the CI recovery paths admit that state.
# ---------------------------------------------------------------------------

EMERGENCY_WORKFLOW="${REPO_ROOT}/.github/workflows/emergency-stop.yml"
EMERGENCY_CTX="{\"event_name\":\"workflow_dispatch\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\",\"actor\":\"fixture-operator\",\"run_id\":\"9876543210\"}"
DRAIN_INPUTS="{\"operation\":\"drain\",\"expected_sha\":\"${FLEET_SHA}\"}"
DEPLOY_INPUTS="{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
DEPLOY_ACK_INPUTS="{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"acknowledge_emergency_stop\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
ROLLBACK_ACK_INPUTS="{\"operation\":\"rollback\",\"acknowledge_emergency_stop\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"

# run_emergency_stop <dir>: dispatches Emergency Stop with the confirmation text.
run_emergency_stop() {
    FLEET_GITHUB_CONTEXT=$EMERGENCY_CTX run_fleet_workflow "$EMERGENCY_WORKFLOW" "$1" \
        '{"confirm":"STOP-RUNNERS","reason":"fixture emergency"}'
}

# fleet_summary: the step summary of the last fleet workflow run.
fleet_summary() { sed -n '/^SUMMARY-BEGIN/,$p' "$FLEET_OUT"; }

# remove_burst_pools <dir>: the effect of Node Pool Sizing remove-burst on the fake.
remove_burst_pools() {
    local dir=$1
    jq '.base_pools |= map(select(.name | startswith("github-runners-burst") | not))' \
        "${dir}/fleet.json" > "${dir}/fleet.next" && mv "${dir}/fleet.next" "${dir}/fleet.json"
    jq 'map(select(.name | startswith("github-runners-burst") | not))' \
        "${dir}/pools.json" > "${dir}/pools.next" && mv "${dir}/pools.next" "${dir}/pools.json"
}

assert_emergency_stop() {
    info "Checking Emergency Stop and recovery from the stopped state..."
    local dir rc

    if (cd "$REPO_ROOT" && python3 - "$EMERGENCY_WORKFLOW") <<'PY'
import re
import sys

import yaml

text = open(sys.argv[1], encoding="utf-8").read()
workflow = yaml.safe_load(text)
assert workflow["concurrency"] == {"group": "runner-emergency-stop", "cancel-in-progress": False}, workflow["concurrency"]
assert workflow["permissions"] == {"contents": "read"}
for name, job in workflow["jobs"].items():
    assert job.get("defaults") == {"run": {"shell": "bash"}}, f"{name} must run steps with shell: bash"
    for step in job["steps"]:
        run = step.get("run", "")
        assert "${{ secrets." not in run and "${{ inputs." not in run, step.get("name")
assert "wc -l" not in text, "pod counts must not turn read failures into 0"
assert not re.search(r"helm list[^\n]*2>/dev/null", text), "a failed helm list must fail the run"
upgrades = re.findall(r"helm upgrade (?:[^\n]*\\\n)+[^\n]*", text)
assert len(upgrades) == 1, upgrades
for flag in ("--reuse-values", "--set minRunners=0", "--set maxRunners=0",
             '--version "${ARC_CHART_VERSION}"', "--history-max 100"):
    assert flag in upgrades[0], f"Emergency Stop upgrade lacks {flag}"
PY
    then
        pass "Emergency Stop: own non-cancelling group, shell: bash, pinned chart, --history-max 100, no masked reads"
    else
        fail "Emergency Stop static contract is violated"
    fi

    # Emergency Stop from burst -> burst-stopped. Ruling 33: the marker is
    # written before the Helm write; Deploy `deploy` restores burst only with
    # acknowledge_emergency_stop=true, deleting the marker first.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open) || { fail "emergency fixture could not be built"; return; }
    run_emergency_stop "$dir"
    expect_fleet "emergency stop from burst (marker before the Helm write)" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-burst-stopped "STEP Read back stopped state: success" - "$dir"
    if [ "$(jq '.runners | length' "${dir}/fleet.json")" = 0 ] \
        && fleet_summary | grep -q 'arc=burst-stopped' \
        && fleet_summary | grep -q 'operation=deploy' && fleet_summary | grep -q 'acknowledge_emergency_stop=true' \
        && ! fleet_summary | grep -q 'rollback_revision' \
        && [ "$(jq -r '.stop_marker.data["run-id"] // empty' "${dir}/fleet.json")" != "" ]; then
        pass "emergency stop from burst: no runners left; marker written; the summary names burst-stopped and the acknowledged Deploy recovery"
    else
        fail "emergency stop from burst: runners $(jq -c '.runners' "${dir}/fleet.json"), marker $(jq -c '.stop_marker' "${dir}/fleet.json"), summary $(fleet_summary | tr '\n' ' ' | head -c 400)"
    fi
    run_gate "$dir" --operation status
    if [ "$?" -eq 0 ] && grep -qx 'STATE: arc=burst-stopped pools=both burst=open' "$GATE_OUT" \
        && grep -q '^STOP: Emergency Stop marker arc-runners/runner-fleet-emergency-stop present' "$GATE_OUT"; then
        pass "after Emergency Stop the gate classifies burst-stopped and reports the stop marker"
    else
        fail "after Emergency Stop the gate did not report burst-stopped with the marker ($(cat "$GATE_OUT" | tr '\n' ' ') $(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy without the acknowledgement is refused while the marker exists" $? 1 - arc-burst-stopped \
        "STEP Admit pool state and record identities: failure" "refused while the Emergency Stop marker" "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fleet "deploy with acknowledge_emergency_stop recovers burst-stopped to burst" $? 0 stop-marker:delete,probe:allowed,apply-fence,apply-netpol,helm-upgrade:burst arc-burst "STEP Verify Helm transition and burst readback: success" "STOP_MARKER: acknowledged and deleted" "$dir"
    if [ "$(jq -c '.stop_marker' "${dir}/fleet.json")" = null ]; then
        pass "the acknowledged deploy deleted the stop marker"
    else
        fail "the acknowledged deploy left the stop marker $(jq -c '.stop_marker' "${dir}/fleet.json")"
    fi

    # Emergency Stop from burst: Deploy `drain` is refused while the marker exists.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop before a drain" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-burst-stopped - - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain is refused while the marker exists" $? 1 - arc-burst-stopped "STEP Admit pool state and record identities: failure" "refused while the Emergency Stop marker" "$dir"
    # Without a marker (Ruling 26 unchanged), drain still starts from burst-stopped.
    dir=$(fleet_dir '{"arc": "arc-burst-stopped"}' base arc-burst-stopped pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain from burst-stopped without a marker" $? 0 helm-upgrade:drain arc-drain "STEP Drain runners: success" "DRAIN_COMPLETE" "$dir"

    # Emergency Stop during drain -> drain-stopped; remove-burst and an
    # acknowledged rollback still work.
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}]}" base arc-drain pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop during drain" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-drain-stopped "STEP Read back stopped state: success" - "$dir"
    if fleet_summary | grep -q 'arc=drain-stopped' && fleet_summary | grep -q 'remove-burst' \
        && fleet_summary | grep -q 'operation=rollback'; then
        pass "emergency stop during drain: the summary names drain-stopped and the remove-burst/rollback recovery"
    else
        fail "emergency stop during drain: summary lacks the drain-stopped recovery ($(fleet_summary | tr '\n' ' ' | head -c 400))"
    fi
    run_gate "$dir" --operation remove-burst
    if [ "$?" -eq 0 ] && grep -qx 'STATE: arc=drain-stopped pools=both burst=open' "$GATE_OUT"; then
        pass "remove-burst admits drain-stopped with empty burst pools while the marker exists"
    else
        fail "remove-burst does not admit drain-stopped ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain is not admitted from drain-stopped" $? 1 - arc-drain-stopped - "does not admit ARC state 'drain-stopped'" "$dir"
    remove_burst_pools "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rollback without the acknowledgement is refused while the marker exists" $? 1 - arc-drain-stopped \
        "STEP Admit rollback state and record identities: failure" "refused while the Emergency Stop marker" "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$ROLLBACK_ACK_INPUTS"
    expect_fleet "acknowledged rollback from drain-stopped" $? 0 stop-marker:delete,probe:allowed,apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"

    # Emergency Stop on density without pools -> density-stopped; an
    # acknowledged rollback restores density.
    dir=$(fleet_dir '{"arc": "arc-density", "history": [{"revision": 12, "arc": "arc-density", "status": "deployed"}]}' valid-density-no-burst)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop on density" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-density-stopped - - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$ROLLBACK_ACK_INPUTS"
    expect_fleet "acknowledged rollback from density-stopped" $? 0 stop-marker:delete,probe:allowed,apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"

    # Rebalance on a stopped fleet: admitted, notice, nothing retired.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_emergency_stop "$dir"
    FLEET_GITHUB_CONTEXT="{\"event_name\":\"schedule\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\"}" \
        run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" '{}'
    expect_fleet "scheduled rebalance on burst-stopped" $? 0 - arc-burst-stopped "STEP Retire idle burst runners: skipped" - "$dir"
    if fleet_summary | grep -q '^nothing to rebalance: ARC is stopped (arc=burst-stopped'; then
        pass "rebalance on burst-stopped: notice in the summary"
    else
        fail "rebalance on burst-stopped lacks the stopped notice ($(fleet_steps))"
    fi
    FLEET_GITHUB_CONTEXT="{\"event_name\":\"workflow_dispatch\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\"}" \
        run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "{\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "dispatched rebalance on burst-stopped" $? 0 - arc-burst-stopped "STEP Retire idle burst runners: skipped" - "$dir"

    # A failed helm list fails the run; it is never reported as "no deployment".
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    echo 1 > "${dir}/helm-releases.json.rc"
    run_emergency_stop "$dir"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = - ] \
        && grep -qx 'STEP Record current state: failure' "$FLEET_OUT" \
        && ! grep -q 'No Active Deployment' "$FLEET_OUT"; then
        pass "emergency stop: a failed helm list fails the run instead of reporting no deployment"
    else
        fail "emergency stop with a failed helm list: exit ${rc}, mutations $(fleet_mutations "$dir") ($(fleet_steps))"
    fi

    # A release that is genuinely absent is reported, and nothing is written.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    echo '[]' > "${dir}/helm-releases.json"
    run_emergency_stop "$dir"
    expect_fleet "emergency stop without a release" $? 0 - arc-burst "STEP Handle non-existent deployment: success" - "$dir"

    # Failed runner-pod reads fail the run instead of counting as zero pods;
    # the stop itself is still applied.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    echo 1 > "${dir}/runner-pods.json.rc"
    run_emergency_stop "$dir"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = stop-marker:set,probe:denied,helm-upgrade:stopped ] \
        && grep -qx 'STEP Verify shutdown: failure' "$FLEET_OUT" \
        && ! grep -q 'All runner pods have been terminated' "$FLEET_ERR"; then
        pass "emergency stop: failed runner-pod reads fail the run (stop still applied, never counted as 0 pods)"
    else
        fail "emergency stop with failed pod reads: exit ${rc}, mutations $(fleet_mutations "$dir") ($(fleet_steps))"
    fi
}

# rebalance_rejected <label> <github-context> <inputs> <dir> [head-sha]
rebalance_rejected() {
    local label=$1 ctx=$2 inputs=$3 dir=$4 head=${5:-$FLEET_SHA} rc
    FLEET_GITHUB_CONTEXT=$ctx run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "$inputs" "$head"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(fleet_mutations "$dir")" = - ] && ! ls "$dir"/*.calls >/dev/null 2>&1 \
        && grep -qx 'STEP Validate run source and SHA: failure' "$FLEET_OUT"; then
        pass "rebalance ${label}: stops before any doctl, kubectl, helm or gh call; no deletion"
    else
        fail "rebalance ${label}: exit ${rc}, mutations $(fleet_mutations "$dir"), calls $(cat "$dir"/*.calls 2>/dev/null | head -c 200) ($(fleet_steps))"
    fi
}

assert_phase_c() {
    info "Checking Scale Runners record-density and acceptance-phase-c against the fleet fake..."
    local dir rc case_label repo

    # Ruling 34: record-density is a read-only check that the live release is
    # density 2/4 and equals the render of deploy/density-values.yaml. It no
    # longer reads or emits a Helm revision.
    local record="{\"action\":\"record-density\",\"expected_sha\":\"${FLEET_SHA}\"}"
    dir=$(fleet_dir '{"arc": "arc-density", "history": [{"revision": 14, "arc": "arc-density", "status": "deployed"}]}' valid-density-no-burst)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$record"
    expect_fleet "record-density on the committed density release" $? 0 - arc-density \
        "STEP Verify the live release is the committed density release: success" "DENSITY_RELEASE: the live release is density 2/4" "$dir"
    if no_mutating_calls "$dir" && grep -q -- '^template .*--values deploy/density-values.yaml' "${dir}/helm.calls" \
        && ! grep -q '^history' "${dir}/helm.calls" && ! grep -q 'rollback_revision' "$FLEET_OUT"; then
        pass "record-density: renders deploy/density-values.yaml, reads no helm history, emits no revision, mutates nothing"
    else
        fail "record-density calls: $(cut -c1-120 "${dir}/helm.calls" | tr '\n' ' ')"
    fi
    # The live release differs from the committed render: fail, read-only.
    dir=$(fleet_dir '{"arc": "arc-density", "history": [{"revision": 14, "arc": "arc-density", "status": "deployed"}]}' valid-density-no-burst)
    sed -i '0,/app.kubernetes.io\/instance: redducklabs-runners/s//&\n    fixture.example\/drift: "true"/' "${dir}/template-density.yaml"
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$record"
    expect_fleet "record-density when the live release differs from the committed render" $? 1 - arc-density \
        "STEP Verify the live release is the committed density release: failure" "differs from the render of deploy/density-values.yaml" "$dir"
    # Committed density values that fail validation fail the check.
    repo=$(mktemp -d "${WORK_DIR}/repo.XXXXXX")
    (cd "$REPO_ROOT" && tar --exclude=.git -cf - .) | (cd "$repo" && tar -xf -)
    mutate "${REPO_ROOT}/deploy/density-values.yaml" "${repo}/deploy/density-values.yaml" "doc['maxRunners'] = 10"
    dir=$(fleet_dir '{"arc": "arc-density", "history": [{"revision": 14, "arc": "arc-density", "status": "deployed"}]}' valid-density-no-burst)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$record" "$FLEET_SHA" "$repo"
    expect_fleet "record-density with invalid committed density values" $? 1 - arc-density - "is not the density contract (2/4)" "$dir"
    rm -rf "$repo"
    dir=$(fleet_dir '{"arc": "arc-burst"}' base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$record"
    expect_fleet "record-density on burst" $? 1 - arc-burst "STEP Admit pool state and record identities: failure" - "$dir"

    local phase_c="{\"action\":\"acceptance-phase-c\",\"expected_sha\":\"${FLEET_SHA}\"}"
    local two='"runners": [{"name": "base0", "node": "baseline-a"}, {"name": "base1", "node": "baseline-b"}]'

    # Success with a burst survivor retired in the first cycle.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"surplus\": \"baseline-first\"}, ${two}}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C with a burst survivor" $? 0 \
        "helm-upgrade:min=8,helm-upgrade:min=4,delete-er:*,helm-upgrade:min=2" arc-burst \
        "STEP Restore burst after Phase C: success" "RESTORE: ARC is already burst 2/20 (verified no-op)" "$dir"
    if grep -qx 'PHASE_C_RESULT=retired' "$FLEET_ERR" && python3 - "$PHASE_C_EVIDENCE_FILE" <<'PY'
import json
import sys

evidence = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(evidence) == {"cycles", "result", "jobs_killed", "jobs_killed_note"} and evidence["result"] == "retired"
assert evidence["jobs_killed"] is None and "not measured" in evidence["jobs_killed_note"]
assert len(evidence["cycles"]) == 1
(cycle,) = evidence["cycles"]
assert cycle["min8"] == {"baseline": 4, "burst": 4, "retired": 0}, cycle
assert cycle["after4"] == {"survivor_on_burst": True, "retired": 4}, cycle
assert isinstance(cycle["pools_zero_at"], str) and cycle["pools_zero_at"].endswith("Z")
PY
    then
        pass "phase C: evidence matches the Ruling 2 schema with jobs_killed null per Ruling 17 (retired, 4/4 at min 8, survivor retired)"
    else
        fail "phase C: evidence $(cat "$PHASE_C_EVIDENCE_FILE" 2>/dev/null)"
    fi
    rm -f "$PHASE_C_EVIDENCE_FILE"

    # No survivor in three cycles -> fixture-only.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"surplus\": \"burst-first\"}, ${two}}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C without a burst survivor" $? 0 \
        "helm-upgrade:min=8,helm-upgrade:min=4,helm-upgrade:min=2,helm-upgrade:min=8,helm-upgrade:min=4,helm-upgrade:min=2,helm-upgrade:min=8,helm-upgrade:min=4,helm-upgrade:min=2" \
        arc-burst - "PHASE_C_RESULT=fixture-only" "$dir"
    if [ "$(jq -c '[.result, (.cycles | length), [.cycles[].after4.survivor_on_burst]]' "$PHASE_C_EVIDENCE_FILE" 2>/dev/null)" = '["fixture-only",3,[false,false,false]]' ]; then
        pass "phase C: three cycles without a survivor are recorded as fixture-only"
    else
        fail "phase C fixture-only evidence: $(cat "$PHASE_C_EVIDENCE_FILE" 2>/dev/null)"
    fi
    rm -f "$PHASE_C_EVIDENCE_FILE"

    # Failure at the 8-runner wait (no burst capacity): cleanup restores 2.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"burst_capacity\": false, \"sleep_scale\": 10}, ${two}}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C fails at the 8-runner wait" $? 1 helm-upgrade:min=8,helm-upgrade:min=2 arc-burst \
        "STEP Restore burst after Phase C: success" "8 Ready idle runners: not reached within 20 minutes" "$dir"

    # Deadline at 270 minutes: cleanup restores burst.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"sleep_scale\": 600}, ${two}}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C deadline" $? 1 helm-upgrade:min=8,helm-upgrade:min=2 arc-burst \
        "STEP Restore burst after Phase C: success" "PHASE_C_DEADLINE" "$dir"

    # Interrupted runs left 8/20 or 4/20: a re-run restores burst first.
    for case_label in 8 4; do
        dir=$(fleet_dir "{\"arc\": \"arc-burst-acceptance-${case_label}\", \"knobs\": {\"surplus\": \"baseline-first\"}, ${two}}" base "arc-burst-acceptance-${case_label}" pools-open)
        run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
        rc=$?
        if [ "$rc" -eq 0 ] && [ "$(fleet_mutations "$dir" | cut -d, -f1-2)" = helm-upgrade:min=2,helm-upgrade:min=8 ] \
            && [ "$(fleet_arc "$dir")" = arc-burst ]; then
            pass "phase C re-run from interrupted ${case_label}/20 restores burst first, then completes"
        else
            fail "phase C re-run from ${case_label}/20: exit ${rc}, mutations $(fleet_mutations "$dir")"
        fi
        rm -f "$PHASE_C_EVIDENCE_FILE"
    done

    # Cancellation right after each authorized transition restores burst.
    local token expected
    while IFS='|' read -r token expected; do
        [ -n "$token" ] || continue
        dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"surplus\": \"baseline-first\", \"cancel_after\": \"${token}\"}, ${two}}" base arc-burst pools-open)
        run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
        expect_fleet "phase C cancelled after ${token}" $? 1 "$expected" arc-burst \
            "STEP Restore burst after Phase C: success" - "$dir"
        rm -f "$PHASE_C_EVIDENCE_FILE"
    done <<'CASES'
helm-upgrade:min=8|helm-upgrade:min=8,helm-upgrade:min=2
helm-upgrade:min=4|helm-upgrade:min=8,helm-upgrade:min=4,helm-upgrade:min=2
helm-upgrade:min=2|helm-upgrade:min=8,helm-upgrade:min=4,delete-er:*,helm-upgrade:min=2
CASES

    # Restoration failure propagates as a failed run.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"burst_capacity\": false, \"sleep_scale\": 10, \"fail_helm\": \"helm-upgrade:min=2\"}, ${two}}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C restoration failure" $? 1 helm-upgrade:min=8,helm-upgrade:min=2:failed arc-burst-acceptance-8 \
        "STEP Restore burst after Phase C: failure" "RESTORE: could not return ARC to burst" "$dir"

    # Cleanup eligibility: no Helm write when Phase C was never admitted.
    dir=$(fleet_dir '{"arc": "arc-burst-acceptance-8"}' base arc-burst-acceptance-8 pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "{\"action\":\"acceptance-phase-c\",\"expected_sha\":\"${FLEET_OTHER_SHA}\"}"
    expect_fleet "phase C cleanup with a mismatched SHA" $? 1 - arc-burst-acceptance-8 "STEP Restore burst after Phase C: skipped" - "$dir"
    dir=$(fleet_dir '{"arc": "arc-drain"}' base arc-drain pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C cleanup when entered from drain" $? 1 - arc-drain "STEP Restore burst after Phase C: skipped" "does not admit ARC state 'drain'" "$dir"
    dir=$(fleet_dir '{"arc": "arc-burst-acceptance-8"}' base arc-burst-acceptance-8 pools-closed)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C cleanup when burst is not enabled" $? 1 - arc-burst-acceptance-8 "STEP Restore burst after Phase C: skipped" "enabled at exactly 0/6 and 0/2" "$dir"
    dir=$(fleet_dir '{"arc": "arc-density"}' base arc-density pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C cleanup from a non-Phase-C state (density)" $? 1 - arc-density "STEP Restore burst after Phase C: skipped" - "$dir"
    dir=$(fleet_dir '{"arc": "arc-burst-acceptance-8"}' base arc-burst-acceptance-8 pools-open)
    printf '1\n' > "${dir}/pools.json.rc"
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "$phase_c"
    expect_fleet "phase C cleanup after a failed gate read" $? 1 - arc-burst-acceptance-8 "STEP Restore burst after Phase C: skipped" - "$dir"
    rm -f "$PHASE_C_EVIDENCE_FILE"
}

assert_fleet_workflow_contracts() {
    info "Checking the Deploy and Scale Runners workflow contracts..."
    if (cd "$REPO_ROOT" && python3 - "$DEPLOY_WORKFLOW" "$SCALE_WORKFLOW") <<'PY'
import os
import re
import sys

import yaml


def load(path):
    with open(path, encoding="utf-8") as stream:
        return yaml.safe_load(stream)


deploy, scale = load(sys.argv[1]), load(sys.argv[2])
for workflow in (deploy, scale):
    assert workflow["concurrency"] == {"group": "runner-fleet-mutation", "cancel-in-progress": False}
    assert workflow["permissions"] == {"contents": "read"}
    for name, job in workflow["jobs"].items():
        assert job["runs-on"] == "ubuntu-latest" and "permissions" not in job, name
        assert job.get("defaults") == {"run": {"shell": "bash"}}, f"{name} must run steps with shell: bash"
        for step in job["steps"]:
            run = step.get("run", "")
            assert "${{ inputs." not in run and "${{ secrets." not in run, step.get("name")

inputs = deploy[True]["workflow_dispatch"]["inputs"]
assert inputs["operation"]["options"] == ["deploy", "prepare-trust-boundary", "drain", "rollback"]
assert "min_runners" not in inputs and "max_runners" not in inputs and "rollback_revision" not in inputs
assert inputs["acknowledge_emergency_stop"]["type"] == "boolean" and inputs["acknowledge_emergency_stop"]["default"] is False
jobs = deploy["jobs"]
assert jobs["drain"]["timeout-minutes"] == 330

# Each operation calls the gate with its own name, after validate-inputs.
for job, operation in (("deploy", "deploy"), ("drain", "drain"), ("rollback", "rollback")):
    assert jobs[job]["needs"] in ("validate-inputs", ["validate-inputs", "trust-boundary"])
    runs = [step.get("run", "") for step in jobs[job]["steps"]]
    gate_steps = [run for run in runs if "verify-runner-pool-state.sh" in run and "--operation" in run]
    assert gate_steps and all(f"--operation {operation}" in run for run in gate_steps), job
    assert "--emit-identities" in gate_steps[0], job
    for run in runs:
        assert "--operation" not in run or f"--operation {operation}" in run, (job, run)

# Every Helm write is bracketed: compare none + admission before, declared transition after.
steps = jobs["deploy"]["steps"]
names = [step["name"] for step in steps]
before, write, after = (names.index(n) for n in (
    "Re-admit immediately before Helm", "Deploy runners", "Verify Helm transition and burst readback"))
assert before + 1 == write and write + 1 == after
assert "--transition none" in steps[before]["run"] and "--operation deploy" in steps[before]["run"]
assert "--transition arc:burst:2/20" in steps[after]["run"]
helm_writes = [n for n, s in zip(names, steps) if re.search(r"helm (upgrade|rollback|install)", s.get("run", ""))]
assert helm_writes == ["Deploy runners"], helm_writes
assert "Check node pool capacity" not in names and not any("Bootstrap" in n for n in names)
prereq = steps[names.index("Verify prepared platform prerequisites")]["run"]
assert "verify_arc_identity" in prereq and "scripts/lib/arc-identity.sh" in prereq
assert "gha-rs-controller" not in prereq and "helm list" not in prereq, "inline ARC identity check is duplicated"
preflight = steps[names.index("Render and validate candidate")]["run"] + steps[names.index("Server-side preflight candidate")]["run"]
assert "--dry-run=server" not in steps[names.index("Render and validate candidate")]["run"], "the render step must stay local"
assert "safe-to-evict" in preflight and '"annotations"' in preflight and "--contract burst --kind manifest" in preflight
assert "get nodes" not in preflight and "get pods -A" not in preflight, "headroom belongs to the pool-state gate"

rsteps = jobs["rollback"]["steps"]
rnames = [step["name"] for step in rsteps]
i = rnames.index("Roll back to committed density values")
assert "./scripts/rollback-density.sh --identities" in rsteps[i]["run"]
assert rsteps[i]["run"].index("git rev-parse HEAD") < rsteps[i]["run"].index("rollback-density.sh")
assert "arc:density:2/4" in rsteps[i + 1]["run"]
assert not any(re.search(r"helm (upgrade|rollback)", step.get("run", "")) for step in rsteps), "rollback writes only through scripts/rollback-density.sh"
rollback_script = open("scripts/rollback-density.sh", encoding="utf-8").read()
assert 'fleet_helm_bracket "$IDENTITIES" rollback none arc:density:2/4' in rollback_script
assert "helm rollback" not in rollback_script and "--history-max 100" in rollback_script
assert "--post-renderer" in rollback_script and "fleet_render_density" in rollback_script
# Ruling 33: the acknowledgement deletes the marker before the first write,
# and the Deploy Helm write is followed by the stop fence.
ack = names.index("Acknowledge Emergency Stop")
assert names.index("Admit pool state and record identities") < ack < names.index("Apply runner network policy")
assert steps[ack]["if"] == "needs.validate-inputs.outputs.acknowledge_emergency_stop == 'true'"
assert "fleet_acknowledge_stop" in steps[ack]["run"]
assert rnames.index("Verify trust boundary after rollback") > i

deploy_write = steps[write]["run"]
assert deploy_write.index("git rev-parse HEAD") < deploy_write.index("helm upgrade"), "Deploy must re-check expected_sha before Helm"
assert deploy_write.index("helm upgrade") < deploy_write.index("fleet_stop_fence"), "the stop fence must follow the Deploy Helm write"
post = rsteps[rnames.index("Verify pool state after rollback")]["run"]
assert "Pending" not in post.replace("momentarily Pending", ""), "rollback postcondition must not require zero Pending pods"

phase_c = open("scripts/acceptance-phase-c.sh", encoding="utf-8").read()
upgrade = phase_c[phase_c.index("upgrade \"$FLEET_RELEASE\""):phase_c.index("rc=$?", phase_c.index("upgrade \"$FLEET_RELEASE\""))]
assert "--wait" not in upgrade, "Phase C Helm writes must not use --wait"
for path in (".github/workflows/emergency-stop.yml", "docs/SETUP.md"):
    text = open(path, encoding="utf-8").read()
    assert "scale-custom" not in text and "rollout-quiesce" not in text.replace("`rollout-quiesce` are retired", ""), path

drain_steps = jobs["drain"]["steps"]
assert any("scripts/drain-runners.sh" in s.get("run", "") for s in drain_steps)

sinputs = scale[True]["workflow_dispatch"]["inputs"]
assert set(sinputs) == {"action", "expected_sha"}
assert sinputs["action"]["options"] == ["record-density", "acceptance-phase-c"]
(sjob,) = scale["jobs"].values()
assert sjob["timeout-minutes"] == 300
assert "outputs" not in sjob, "record-density emits no rollback revision (Ruling 34)"
snames = [s.get("name") for s in sjob["steps"]]
admit = sjob["steps"][snames.index("Admit pool state and record identities")]
assert "OPERATION=record-density" in admit["run"] and "OPERATION=acceptance-phase-c" in admit["run"]
assert snames.index("Validate and sanitize inputs") < snames.index("Configure Kubernetes access") < snames.index("Admit pool state and record identities")
# Restore is the last run step; only the Phase C evidence upload follows it.
cleanup = sjob["steps"][snames.index("Restore burst after Phase C")]
assert [s.get("uses") for s in sjob["steps"][snames.index("Restore burst after Phase C") + 1:]] == ["actions/upload-artifact@v7"]
assert cleanup["if"] == "always() && steps.admit.outputs.cleanup_eligible == 'true'"
assert "--restore" in cleanup["run"]
text = open(sys.argv[2], encoding="utf-8").read()
assert "maxRunners" not in text and "scale-custom" not in text and "rollout-quiesce" not in text
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    assert "--set-current-context" not in text
    # Steps run "./scripts/<name>.sh" directly, so the committed mode must be executable.
    for script in set(re.findall(r"\./(scripts/[a-z0-9-]+\.sh)", text)):
        assert os.access(script, os.X_OK), f"{script} is not executable"
PY
    then
        pass "Deploy and Scale Runners: operations, gate names, identity brackets, shell: bash and cleanup guard match the contract"
    else
        fail "Deploy/Scale Runners static workflow contract is violated"
    fi
}

# Gate headroom arithmetic for non-runner request shapes (moved from Deploy's
# former two-node preflight; the gate now evaluates every Ready eligible node).
assert_gate_request_shapes() {
    info "Checking pool-state gate headroom for non-runner request shapes..."
    local shape patch expected dir rc
    while IFS='|' read -r shape expected patch; do
        [ -n "$shape" ] || continue
        dir=$(mktemp -d "${WORK_DIR}/shape.XXXXXX")
        cp -r "$(pool_state_dir valid-burst-mixed)/." "$dir/"
        if ! jq --argjson pod "$patch" '.items += [$pod]' "${dir}/pods.json" > "${dir}/pods.next"; then
            fail "request shape ${shape}: fixture could not be built"
            continue
        fi
        mv "${dir}/pods.next" "${dir}/pods.json"
        run_gate "$dir" --operation deploy
        rc=$?
        if { [ "$expected" = admit ] && [ "$rc" -eq 0 ]; } \
            || { [ "$expected" != admit ] && [ "$rc" -eq 1 ] && grep -qF "$expected" "$GATE_ERR"; }; then
            pass "gate headroom: ${shape} -> ${expected}"
        else
            fail "gate headroom: ${shape} -> exit ${rc}, expected ${expected} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
        fi
    done <<'CASES'
pod-level requests|lacks headroom|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","resources":{"requests":{"cpu":"2","memory":"1500Mi"}},"containers":[{}]},"status":{"phase":"Running"}}
restartable sidecar|lacks headroom|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","containers":[{}],"initContainers":[{"restartPolicy":"Always","resources":{"requests":{"cpu":"2","memory":"1500Mi"}}}]},"status":{"phase":"Running"}}
regular init peak|lacks headroom|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","containers":[{}],"initContainers":[{"resources":{"requests":{"cpu":"2","memory":"3000Mi"}}}]},"status":{"phase":"Running"}}
overhead|lacks headroom|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","overhead":{"cpu":"2","memory":"1500Mi"},"containers":[{}]},"status":{"phase":"Running"}}
malformed quantity|headroom could not be computed|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","containers":[{"resources":{"requests":{"memory":"not-a-quantity"}}}]},"status":{"phase":"Running"}}
alternate valid quantities|admit|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-pool-16g-a1b2c","containers":[{"resources":{"requests":{"cpu":"100000u","memory":"104857600"}}}]},"status":{"phase":"Running"}}
headroom on a burst node|lacks headroom|{"metadata":{"name":"x","namespace":"kube-system"},"spec":{"nodeName":"github-runners-burst-intel-16g-s3t4u","containers":[{"resources":{"requests":{"cpu":"2","memory":"1500Mi"}}}]},"status":{"phase":"Running"}}
CASES
}


# run_cost <fixture> <month> [now-epoch]: runs the cost report against the fakes.
COST_OUT="${WORK_DIR}/cost.out"
COST_ERR="${WORK_DIR}/cost.err"
run_cost() {
    local scenario=$1 month=$2 now=${3:-1792022400} dir
    dir=$(mktemp -d "${WORK_DIR}/cost.XXXXXX")
    cp -r "${FIXTURES}/cost/${scenario}/." "${dir}/"
    COST_DIR=$dir
    with_fakes "$dir" env "NOW_CMD=echo ${now}" bash "${REPO_ROOT}/scripts/runner-cost-report.sh" --month "$month" \
        > "$COST_OUT" 2> "$COST_ERR"
}

# run_cost_args <scenario> <args...>: like run_cost with explicit arguments.
run_cost_args() {
    local scenario=$1 dir
    shift
    dir=$(mktemp -d "${WORK_DIR}/cost.XXXXXX")
    cp -r "${FIXTURES}/cost/${scenario}/." "${dir}/"
    COST_DIR=$dir
    with_fakes "$dir" env "NOW_CMD=echo 1792022400" bash "${REPO_ROOT}/scripts/runner-cost-report.sh" "$@" \
        > "$COST_OUT" 2> "$COST_ERR"
}

# expect_cost <label> <scenario> <month> <expected-rc> <required stdout regexes, one per argument...>
# Whitespace runs in the output are squeezed to one space before matching.
expect_cost() {
    local label=$1 scenario=$2 month=$3 expected_rc=$4 rc pattern normalized
    shift 4
    run_cost "$scenario" "$month"
    rc=$?
    normalized=$(tr -s ' ' < "$COST_OUT")
    if [ "$rc" -ne "$expected_rc" ]; then
        fail "cost report ${label}: exit ${rc}, expected ${expected_rc} ($(head -c 300 "$COST_ERR" | tr '\n' ' '))"
        return
    fi
    for pattern in "$@"; do
        if ! grep -Eq -- "$pattern" <<<"$normalized"; then
            fail "cost report ${label}: output lacks /${pattern}/ ($(head -c 400 <<<"$normalized" | tr '\n' '|'))"
            return
        fi
    done
    pass "cost report ${label}"
}

assert_cost_report() {
    info "Checking the runner cost report against synthetic invoice fixtures..."
    local script="${REPO_ROOT}/scripts/runner-cost-report.sh" usage rc

    if [ "$(git -C "$REPO_ROOT" ls-files -s scripts/runner-cost-report.sh | cut -c1-6)" = 100755 ]; then
        pass "scripts/runner-cost-report.sh is committed executable"
    else
        fail "scripts/runner-cost-report.sh is not committed with mode 100755"
    fi

    expect_cost "sums runner node lines, separates workers and derives burst" burst-derived 2026-09 0 \
        'Granularity is per cluster and node size, not per pool' \
        '^runner 16 GB / 8 vCPU \(baseline; unmarked burst\) 1460\.00 194\.67$' \
        '^RUNNER TOTAL 1460\.00 194\.67$' \
        '^worker 8 GB / 4 vCPU \(not runner cost\) 1440\.00 48\.00$' \
        '^other cluster items \(volumes, load balancers, other\) 13\.00$' \
        '^burst node-hours, derived \(baseline assumed 2 nodes\) 20\.00$' \
        '^burst cost, estimated \(derived hours x average price\) 2\.67$'
    if ! grep -Eq 'unrelated|synthetic|pvc-' "$COST_OUT"; then
        pass "cost report prints only aggregate lines, no unrelated invoice item names"
    else
        fail "cost report leaked invoice item names"
    fi
    if ! grep -Eq '[0-9a-f]{8}-[0-9a-f]{4}-' "$COST_OUT" "$COST_ERR"; then
        pass "cost report never prints invoice UUIDs"
    else
        fail "cost report printed an invoice UUID"
    fi
    expect_cost "excludes other clusters' and non-cluster 16 GB lines" other-cluster 2026-09 0 \
        '^RUNNER TOTAL 1440\.00 192\.00$' \
        '^burst node-hours, derived \(baseline assumed 2 nodes\) 0\.00$'
    if ! grep -q '^worker' "$COST_OUT"; then
        pass "cost report omits the worker line when the cluster bills none"
    else
        fail "cost report printed a worker line for a cluster without workers"
    fi
    # The AMD and Intel invoice wording is undocumented: a variant word before
    # or after the size is accepted, and every 16 GB / 8 vCPU line is runner cost.
    expect_cost "reports the AMD primary and Intel fallback burst sizes on their own lines" burst-variants 2026-09 0 \
        '^runner 16 GB / 8 vCPU \(baseline; unmarked burst\) 1440\.00 192\.00$' \
        '^runner 16 GB / 8 vCPU AMD \(primary burst\) 10\.00 1\.67$' \
        '^runner 16 GB / 8 vCPU Intel \(fallback burst\) 2\.00 0\.33$' \
        '^RUNNER TOTAL 1452\.00 194\.00$' \
        '^burst node-hours, derived \(baseline assumed 2 nodes\) 12\.00$' \
        '^burst cost, estimated \(derived hours x average price\) 1\.60$'
    expect_cost "a runner-size line naming both AMD and Intel makes the month unavailable" variant-ambiguous 2026-09 0 \
        '^cost data unavailable: a cluster runner-size line names both AMD and Intel$'
    if ! grep -q 'RUNNER TOTAL' "$COST_OUT"; then
        pass "cost report prints no runner total for an ambiguous runner-size line"
    else
        fail "cost report printed a runner total for an ambiguous runner-size line"
    fi
    expect_cost "floors derived burst hours at zero" below-baseline 2026-09 0 \
        '^burst node-hours, derived \(baseline assumed 2 nodes\) 0\.00$'
    expect_cost "no runner-size line is unavailable, not zero" no-runner-line 2026-09 0 '^cost data unavailable'
    if ! grep -q 'RUNNER TOTAL' "$COST_OUT"; then
        pass "cost report prints no runner total without a runner-size line"
    else
        fail "cost report printed a runner total without a runner-size line"
    fi
    expect_cost "an explicit --cluster-name selects that cluster's lines" other-cluster 2026-09 0 '^RUNNER TOTAL 1440\.00 192\.00$'
    run_cost_args other-cluster --month 2026-09 --cluster-name othercluster
    if tr -s ' ' < "$COST_OUT" | grep -q '^RUNNER TOTAL 500\.00 66\.67$'; then
        pass "cost report --cluster-name override selects the other cluster"
    else
        fail "cost report --cluster-name override is wrong ($(head -c 300 "$COST_OUT" | tr '\n' '|'))"
    fi
    expect_cost "missing invoice is unavailable, not zero" missing-invoice 2026-09 0 \
        '^cost data unavailable'
    if ! grep -Eq '(^| )0(\.00)?( |$)' "$COST_OUT"; then
        pass "cost report prints no zero for a missing invoice"
    else
        fail "cost report printed a zero for a missing invoice"
    fi
    expect_cost "unparseable itemization is unavailable" unparseable-invoice 2026-09 0 '^cost data unavailable'
    expect_cost "an unparseable runner line makes the month unavailable" bad-item 2026-09 0 '^cost data unavailable'
    expect_cost "a runner line not measured in hours makes the month unavailable" bad-unit 2026-09 0 '^cost data unavailable'
    expect_cost "current month reports account-wide month to date" current-month 2026-10 0 \
        'ACCOUNT-WIDE' '123\.45' 'not itemized'
    if ! grep -q 'invoice get' "${COST_DIR}/doctl.calls"; then
        pass "cost report does not itemize the month in progress"
    else
        fail "cost report fetched an itemized invoice for the month in progress"
    fi
    expect_cost "current month without balance data is unavailable" current-month-no-balance 2026-10 0 '^cost data unavailable'
    expect_cost "a future month is unavailable" missing-invoice 2027-01 0 '^cost data unavailable'

    for usage in "" "--month" "--month 2026-13" "--month 2026-9" "--month 2026-09 extra" "--month ../x" "--month 2026-09 --cluster-name Bad_Name"; do
        # shellcheck disable=SC2086 # usage is an argument list by design
        with_fakes "$(mktemp -d "${WORK_DIR}/cost.XXXXXX")" bash "$script" $usage >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 2 ]; then
            pass "cost report rejects usage '${usage:-no arguments}' with exit 2"
        else
            fail "cost report exit ${rc} (expected 2) for usage '${usage:-no arguments}'"
        fi
    done

    # doctl failing is unavailable data, still exit 0.
    run_cost burst-derived 2026-09
    printf '1\n' > "${COST_DIR}/invoice-list.json.rc"
    with_fakes "$COST_DIR" env "NOW_CMD=echo 1792022400" bash "$script" --month 2026-09 > "$COST_OUT" 2> "$COST_ERR"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^cost data unavailable' "$COST_OUT"; then
        pass "cost report treats a failing doctl as unavailable data"
    else
        fail "cost report did not report unavailable data when doctl failed (exit ${rc})"
    fi

    if ! grep -Eq 'doctl.*(create|update|delete)|--access-token' "$script" "${REPO_ROOT}/scripts/lib/runner_cost_report.py"; then
        pass "cost report issues only read-only doctl commands"
    else
        fail "cost report contains a mutating doctl command"
    fi
}


STATUS_WORKFLOW="${REPO_ROOT}/.github/workflows/runner-status.yml"

# status_dir <scenario-json> <pool-state layers...>: a fleet dir plus the extra
# read routes the Runner Status steps use (releases, metrics, events, autoscaler).
status_dir() {
    local dir
    dir=$(fleet_dir "$@") || return 1
    printf '{"items":[]}\n' > "${dir}/empty-list.json"
    printf 'health:\n  status: Healthy\nscaleUp:\n  status: NoActivity\n' > "${dir}/autoscaler-status.txt"
    cat >> "${dir}/kubectl.routes" <<'ROUTES'
top *|empty.out
get pods -n arc-runners -o json|empty-list.json
get events -n arc-runners *|empty.out
get configmap cluster-autoscaler-status *|autoscaler-status.txt
ROUTES
    cat >> "${dir}/helm.routes" <<'ROUTES'
list -n arc-runners -o json|helm-releases.json
ROUTES
    printf '%s\n' "$dir"
}

# no_mutating_calls <dir>: true when no recorded doctl/kubectl/helm/gh call uses a
# mutating subcommand (this also covers argv-array calls the static check cannot see).
no_mutating_calls() {
    ! cat "$1"/doctl.calls "$1"/kubectl.calls "$1"/helm.calls 2>/dev/null \
        | grep -Eq '(^| )(create|update|delete|patch|apply|upgrade|install|rollback|scale|uninstall|annotate|label|cordon|drain|replace|edit|set|taint)( |$)' \
        && ! grep -Eq -- '--method|(^| )(-X|--input)( |$)' "$1"/gh.calls 2>/dev/null
}

# run_status <dir>: runs Runner Status as the daily schedule would.
run_status() {
    FLEET_GITHUB_CONTEXT='{"event_name":"schedule","sha":"'"${FLEET_SHA}"'","ref":"refs/heads/main"}' \
        run_fleet_workflow "$STATUS_WORKFLOW" "$1" '{}'
}

status_summary() { sed -n '/^SUMMARY-BEGIN/,$p' "$FLEET_OUT"; }

assert_status_workflow() {
    info "Checking the Runner Status workflow..."
    local dir script

    if (cd "$REPO_ROOT" && python3 - "$STATUS_WORKFLOW") <<'PY'
import os
import re
import sys

import yaml

text = open(sys.argv[1], encoding="utf-8").read()
workflow = yaml.safe_load(text)
assert workflow["permissions"] == {"contents": "read", "id-token": "write"}
job = workflow["jobs"]["status"]
assert job["runs-on"] == "ubuntu-latest" and job["defaults"] == {"run": {"shell": "bash"}}
names = [s.get("name") for s in job["steps"]]
runs = {s.get("name"): s.get("run", "") for s in job["steps"]}
assert names.index("Configure Kubernetes access") < names.index("Admit pool state (status)") \
    < names.index("Report pool node counts, bounds and expander") < names.index("Check deployment status")
gate = runs["Admit pool state (status)"]
assert "--operation status" in gate and "--emit-identities" not in gate
assert "report-runner-pools.sh" in runs["Report pool node counts, bounds and expander"]
assert "Report autoscaler diagnostics" in names and "Fail on rejected pool state or unreadable pool report" in names
assert "CAPACITY DRIFT" not in text and "POOL_COUNT" not in text
assert "--set-current-context" not in text
assert "current-context" in runs["Configure Kubernetes access"]
assert not re.search(r"(kubectl (delete|patch|apply|scale|label|annotate|drain|cordon)|helm (install|upgrade|rollback|uninstall)|doctl [a-z -]*(create|update|delete))", text)
for script in set(re.findall(r"\./(scripts/[a-z0-9-]+\.sh)", text)):
    assert os.access(script, os.X_OK), f"{script} is not executable"
for step in job["steps"]:
    assert "${{ secrets.DO_TOKEN" not in step.get("run", ""), step.get("name")
PY
    then
        pass "Runner Status: gate status admission, pool report, no fixed two-node drift check, read-only"
    else
        fail "Runner Status static workflow contract is violated"
    fi
    for script in scripts/report-runner-pools.sh scripts/runner-cost-report.sh; do
        if [ "$(git -C "$REPO_ROOT" ls-files -s "$script" | cut -c1-6)" = 100755 ]; then
            pass "${script} is committed executable"
        else
            fail "${script} is not committed with mode 100755"
        fi
    done

    # Baseline plus one running burst node (three runner nodes): no fixed two-node drift.
    dir=$(status_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_status "$dir"
    expect_fleet "status with open burst pools and a burst node" $? 0 - arc-burst "STEP Admit pool state (status): success" - "$dir"
    if status_summary | grep -qF 'Pool state**: `arc=burst pools=both burst=open` (admitted)' \
        && status_summary | grep -Eq '^POOL github-runners-pool-16g provider_count=2 min=2 max=2 auto_scale=[a-z]+ registered=2 ready=2$' \
        && status_summary | grep -Eq '^POOL github-runners-burst-amd-16g provider_count=1 min=0 max=6 auto_scale=true registered=1 ready=1$' \
        && status_summary | grep -Eq '^POOL github-runners-burst-intel-16g provider_count=0 min=0 max=2 ' \
        && status_summary | grep -q '^EXPANDER ' \
        && ! grep -qi 'capacity drift' "$FLEET_OUT" "$FLEET_ERR" \
        && grep -qx 'STEP Fail on rejected pool state or unreadable pool report: success' "$FLEET_OUT"; then
        pass "Runner Status reports the gate state, per-pool counts and bounds, and no fixed-capacity drift"
    else
        fail "Runner Status report lacks the gate state, pool counts or expander line ($(status_summary | grep -E '^(POOL|EXPANDER)|Pool state' | head -n 8 | tr '\n' '|'))"
    fi
    if status_summary | grep -q 'cost'; then
        pass "Runner Status points at the cost report instead of claiming node-hours"
    else
        fail "Runner Status does not point at the cost report"
    fi
    if grep -q 'Autoscaler diagnostics' "$FLEET_OUT" "$FLEET_ERR"; then
        pass "Runner Status still reports the allow-listed autoscaler diagnostics"
    else
        fail "Runner Status lost the autoscaler diagnostics step"
    fi

    if no_mutating_calls "$dir"; then
        pass "Runner Status issued only read-only doctl, kubectl, helm and gh calls"
    else
        fail "Runner Status issued a mutating call: $(cat "$dir"/doctl.calls "$dir"/kubectl.calls "$dir"/helm.calls 2>/dev/null | grep -E '(^| )(create|update|delete|patch|apply|upgrade|install|scale|set)( |$)' | head -n 3 | tr '\n' '|')"
    fi

    # Density, no burst pools: still admitted, burst pools absent.
    dir=$(status_dir '{"arc": "arc-density"}' valid-density-no-burst)
    run_status "$dir"
    expect_fleet "status on the density baseline" $? 0 - arc-density "STEP Admit pool state (status): success" - "$dir"
    if status_summary | grep -qF '`arc=density pools=none burst=closed`' \
        && status_summary | grep -qx 'POOL github-runners-burst-amd-16g absent' \
        && status_summary | grep -qx 'EXPANDER n/a: no burst pools'; then
        pass "Runner Status on density reports absent burst pools"
    else
        fail "Runner Status on density report is wrong ($(status_summary | grep -E '^(POOL|EXPANDER)|Pool state' | head -n 8 | tr '\n' '|'))"
    fi

    # Baseline drift: the gate rejects, the report still renders, the run fails.
    dir=$(status_dir '{"arc": "arc-density"}' baseline-drift)
    run_status "$dir"
    expect_fleet "status with baseline drift" $? 1 - - "STEP Admit pool state (status): success" "REJECTED" "$dir"
    if grep -qx 'STEP Fail on rejected pool state or unreadable pool report: failure' "$FLEET_OUT" \
        && status_summary | grep -q 'not admitted' \
        && status_summary | grep -q '^POOL github-runners-pool-16g '; then
        pass "Runner Status keeps reporting after a rejection and fails the run at the end"
    else
        fail "Runner Status rejection path is wrong ($(fleet_steps))"
    fi

    # A helm failure fails the deployment step instead of reading as "not deployed".
    dir=$(status_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    printf '1\n' > "${dir}/helm-releases.json.rc"
    run_status "$dir"
    if grep -qx 'STEP Check deployment status: failure' "$FLEET_OUT"; then
        pass "Runner Status fails the deployment step on a helm error"
    else
        fail "Runner Status treated a helm error as an absent release ($(fleet_steps))"
    fi

    # Explicitly null count/min/max print as unknown (an omitted key is a zero,
    # Ruling 39); duplicate pool names are flagged.
    dir=$(pool_state_dir valid-burst-mixed) || { fail "report fixture could not be built"; return; }
    local edited
    edited=$(mktemp -d "${WORK_DIR}/report.XXXXXX")
    cp -r "${dir}/." "${edited}/"
    jq 'map(if .name == "github-runners-burst-amd-16g" then .count = null | .min_nodes = null | .max_nodes = null else . end)
        + [(.[] | select(.name == "github-runners-pool-16g"))]' "${dir}/pools.json" > "${edited}/pools.json"
    with_fakes "$edited" env "NOW_CMD=echo ${POOL_STATE_NOW}" bash "${REPO_ROOT}/scripts/report-runner-pools.sh" \
        --cluster-name redducklabs-cluster > "$GATE_OUT" 2> "$GATE_ERR"
    if grep -q '^POOL github-runners-burst-amd-16g provider_count=unknown min=unknown max=unknown ' "$GATE_OUT" \
        && grep -q '^POOL github-runners-pool-16g duplicate: 2 pools share this name' "$GATE_OUT" \
        && ! grep -q 'None' "$GATE_OUT"; then
        pass "pool report prints unknown for explicitly null fields and flags a duplicated pool name"
    else
        fail "pool report edge cases are wrong ($(head -c 400 "$GATE_OUT" | tr '\n' '|'))"
    fi

    # Expander drift is reported as drift, not as a crash.
    dir=$(status_dir '{"arc": "arc-burst"}' deploy-priorities-wrong)
    run_status "$dir"
    if status_summary | grep -q '^EXPANDER drift: '; then
        pass "Runner Status reports a drifted priority expander"
    else
        fail "Runner Status did not report the drifted priority expander ($(status_summary | grep -E '^EXPANDER' | head -n 3 | tr '\n' '|'))"
    fi

    # A failed pool read fails the run after the rest of the report.
    dir=$(status_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    printf '1\n' > "${dir}/nodes.json.rc"
    run_status "$dir"
    expect_fleet "status with an unreadable node list" $? 1 - - "STEP Fail on rejected pool state or unreadable pool report: failure" - "$dir"
}


# ---------------------------------------------------------------------------
# Runner network isolation (Task 12)
#
# deploy/runner-network-policy.yaml is the spec's policy; the policy-set
# validator (scripts/verify-runner-network-policy.sh) reads NetworkPolicies,
# Cilium policies, the CRD list and arc-runners pods through the fakes. The
# pool-state base layer carries the valid set (our policy plus the DOKS-managed
# deny-imds-egress CCNP); the layers below each break one rule.
# ---------------------------------------------------------------------------

NETWORK_POLICY_FILE="${REPO_ROOT}/deploy/runner-network-policy.yaml"
NETWORK_POLICY_VALIDATOR="${REPO_ROOT}/scripts/verify-runner-network-policy.sh"

# expect_network_policy <layers> <exit> <expectation>: exit 0 -> stdout
# substring, otherwise a stderr substring.
expect_network_policy() {
    local layers=$1 expected=$2 expectation=$3 dir rc
    # shellcheck disable=SC2086 # layers is a space-separated list by design
    dir=$(pool_state_dir $layers) || { fail "network policy fixture ${layers} could not be built"; return; }
    rm -f "$dir"/*.calls
    with_fakes "$dir" bash "$NETWORK_POLICY_VALIDATOR" > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if cat "$dir"/*.calls 2>/dev/null | grep -Ev '^get ' | grep -q .; then
        fail "network policy ${layers// /+}: the validator issued a call other than get"
    elif [ "$rc" -ne "$expected" ]; then
        fail "network policy ${layers// /+}: exit ${rc}, expected ${expected} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    elif [ "$expected" -eq 0 ] && grep -qF -- "$expectation" "$GATE_OUT"; then
        pass "network policy ${layers// /+}: valid (${expectation})"
    elif [ "$expected" -ne 0 ] && grep -qF -- "$expectation" "$GATE_ERR"; then
        pass "network policy ${layers// /+}: rejected (${expectation})"
    else
        fail "network policy ${layers// /+}: output lacks '${expectation}' ($(cat "$GATE_OUT" "$GATE_ERR" | head -c 300 | tr '\n' ' '))"
    fi
}

assert_network_policy() {
    info "Checking runner network isolation..."
    if python3 - "$NETWORK_POLICY_FILE" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    documents = [d for d in yaml.safe_load_all(stream) if d is not None]
assert len(documents) == 1, "exactly one object"
(policy,) = documents
assert policy["apiVersion"] == "networking.k8s.io/v1" and policy["kind"] == "NetworkPolicy"
assert policy["metadata"] == {"name": "redducklabs-runner-isolation", "namespace": "arc-runners"}
spec = policy["spec"]
assert set(spec) == {"podSelector", "policyTypes", "egress"}, "no ingress rules, nothing else"
assert spec["podSelector"] == {"matchLabels": {"actions.github.com/scale-set-name": "redducklabs-runners"}}
assert spec["policyTypes"] == ["Ingress", "Egress"]
assert spec["egress"] == [
    {
        "to": [{
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
            "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
        }],
        "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}],
    },
    {
        "to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": [
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]}}],
    },
], spec["egress"]
PY
    then
        pass "deploy/runner-network-policy.yaml is exactly the spec's policy (selector, both policy types, no ingress, DNS rule, except list)"
    else
        fail "deploy/runner-network-policy.yaml does not match the spec"
    fi

    if [ ! -f "$NETWORK_POLICY_VALIDATOR" ]; then
        fail "scripts/verify-runner-network-policy.sh does not exist"
        return
    fi
    local layers code expectation
    while IFS='|' read -r layers code expectation; do
        [ -n "$layers" ] || continue
        expect_network_policy "$layers" "$code" "$expectation"
    done <<'CASES'
base|0|NETWORK_POLICY: valid: arc-runners/redducklabs-runner-isolation matches the file; Cilium policy CRDs installed
base netpol-missing|1|NetworkPolicies in arc-runners must be exactly ['redducklabs-runner-isolation']; found []
base netpol-renamed|1|found ['runner-isolation']
base netpol-second-vpc-egress|1|found ['allow-vpc', 'redducklabs-runner-isolation']
base netpol-second-ingress|1|found ['allow-ingress', 'redducklabs-runner-isolation']
base netpol-extra-egress-rule|1|NetworkPolicy 'redducklabs-runner-isolation' spec differs from runner-network-policy.yaml
base cnp-in-namespace|1|CiliumNetworkPolicies in arc-runners must be none; found ['allow-vpc']
base ccnp-allow-egress|1|CiliumClusterwideNetworkPolicy 'allow-vpc-everywhere' is not deny-only: it sets egress
base ccnp-allow-in-specs|1|CiliumClusterwideNetworkPolicy 'mixed-specs' is not deny-only: it sets ingress
base cilium-crds-absent|0|Cilium policy CRDs absent
base crd-list-error|1|'kubectl get crd -o ...' failed with exit 1
base cnp-list-error|1|'kubectl get ciliumnetworkpolicies.cilium.io -n ...' failed with exit 1
base runner-pod-imds-label|1|in arc-runners is labeled doks.digitalocean.com/allow-imds-egress=true
base imds-label-other-namespace|0|NETWORK_POLICY: valid
base runner-pod-missing-selector|1|runner pod 'redducklabs-runners-7xk2p-runner-abcde' in arc-runners lacks the policy selector label actions.github.com/scale-set-name=redducklabs-runners
base arc-runners-other-pod|0|NETWORK_POLICY: valid
CASES

    # Absent CRDs are zero objects: their (failing) lists are never read.
    local dir
    dir=$(pool_state_dir base cilium-crds-absent)
    rm -f "$dir"/*.calls
    with_fakes "$dir" bash "$NETWORK_POLICY_VALIDATOR" > /dev/null 2>&1
    if grep -q 'cilium' "${dir}/kubectl.calls"; then
        fail "network policy: a Cilium list was read although its CRD is absent"
    else
        pass "network policy: absent Cilium CRDs are not listed"
    fi

    # Gate: the policy set is required for enable-burst, rebalance and
    # acceptance-phase-c, not for deploy (Deploy installs it).
    local operation
    for operation in enable-burst rebalance acceptance-phase-c; do
        expect_gate "base arc-burst pools-open netpol-missing" "$operation" 1 "runner network policy set is not valid"
        expect_gate "base arc-burst pools-open ccnp-allow-egress" "$operation" 1 "is not deny-only"
    done
    for operation in deploy drain status; do
        expect_gate "base arc-burst pools-open netpol-missing" "$operation" 0 "STATE: arc=burst pools=both burst=open"
    done

    # Deploy installs the policy behind a server-side dry run, bracketed by the
    # identity contract, and validates the whole set before the Helm upgrade.
    if (cd "$REPO_ROOT" && python3 - "$DEPLOY_WORKFLOW") <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    steps = yaml.safe_load(stream)["jobs"]["deploy"]["steps"]
names = [step["name"] for step in steps]
order = ["Render and validate candidate", "Dry-run runner network policy", "Apply runner network policy",
         "Verify runner network policy set", "Re-admit immediately before Helm", "Deploy runners"]
indices = [names.index(name) for name in order]
assert indices == sorted(indices), names
assert indices[1] + 1 == indices[2] and indices[2] + 1 == indices[3] and indices[3] + 1 == indices[4], names
dry, apply, verify = (steps[i]["run"] for i in indices[1:4])
assert "kubectl apply --server-side --dry-run=server" in dry and "-f deploy/runner-network-policy.yaml" in dry
assert "-o json" in dry and 'returned.get("spec") != committed["spec"]' in dry and "unified_diff" in dry, \
    "the dry-run spec must be compared with the file before the apply"
assert "--dry-run" not in apply
sha = apply.index("git rev-parse HEAD")
compare_before = apply.index("--transition none")
admit = apply.index("--operation deploy")
write = apply.index("kubectl apply --server-side")
compare_after = apply.index("--transition none", write)
assert sha < write and compare_before < write and admit < write < compare_after, apply
assert "-f deploy/runner-network-policy.yaml" in apply[write:compare_after]
assert "scripts/verify-runner-network-policy.sh" in verify
for step in steps:
    run = step.get("run", "")
    if "runner-network-policy.yaml" in run:
        assert step["name"] in ("Dry-run runner network policy", "Apply runner network policy"), step["name"]
PY
    then
        pass "Deploy: network policy dry run, bracketed apply and policy-set validation precede the Helm re-admission"
    else
        fail "Deploy network policy step order or bracketing is wrong"
    fi

    local deploy_inputs="{\"operation\":\"deploy\",\"accept_privileged_runner_co_tenancy\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    dir=$(fleet_dir '{"arc": "arc-density"}' base arc-density pools-closed netpol-missing) \
        || { fail "network policy deploy fixture could not be built"; return; }
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$deploy_inputs"
    expect_fleet "first deploy with no network policy installs it, then Helm" $? 0 apply-fence,apply-netpol,helm-upgrade:burst arc-burst \
        "STEP Verify runner network policy set: success" - "$dir"
    if [ "$(jq -r '[.items[].metadata.name] | join(",")' "${dir}/networkpolicies.json")" = redducklabs-runner-isolation ]; then
        pass "first deploy: the live policy set holds exactly the runner policy"
    else
        fail "first deploy: live NetworkPolicies are $(jq -c '[.items[].metadata.name]' "${dir}/networkpolicies.json")"
    fi

    dir=$(fleet_dir '{"arc": "arc-density", "knobs": {"netpol_dry_run": "fail"}}' base arc-density pools-closed netpol-missing)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$deploy_inputs"
    expect_fleet "network policy dry-run failure" $? 1 apply-fence arc-density "STEP Dry-run runner network policy: failure" - "$dir"
    if grep -q -- '--dry-run=server -f deploy/runner-network-policy.yaml' "${dir}/kubectl.calls" \
        && ! grep -q '^upgrade' "${dir}/helm.calls"; then
        pass "network policy dry-run failure: no apply and no Helm upgrade"
    else
        fail "network policy dry-run failure: unexpected calls ($(grep -hE '^(apply|upgrade)' "$dir"/*.calls | head -n 3 | tr '\n' ' '))"
    fi

    # The server would default an extra field: the spec comparison stops the
    # run before the real apply, so the policy never lands half-valid.
    dir=$(fleet_dir '{"arc": "arc-density", "knobs": {"netpol_dry_run": "defaulted"}}' base arc-density pools-closed netpol-missing)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$deploy_inputs"
    expect_fleet "network policy dry run returns a defaulted spec" $? 1 apply-fence arc-density "STEP Dry-run runner network policy: failure" \
        "the server would store a different runner NetworkPolicy spec" "$dir"
    if grep -q -- '--dry-run=server -f deploy/runner-network-policy.yaml' "${dir}/kubectl.calls" \
        && [ "$(grep -c '^apply --server-side -f deploy/runner-network-policy.yaml' "${dir}/kubectl.calls")" = 0 ] \
        && ! grep -q '^upgrade' "${dir}/helm.calls" && grep -qF '"endPort": 53' "$FLEET_ERR" \
        && [ "$(jq '.items | length' "${dir}/networkpolicies.json")" = 0 ]; then
        pass "defaulted dry-run spec: diff printed, no apply, no Helm upgrade, no policy stored"
    else
        fail "defaulted dry-run spec: unexpected calls or no diff ($(grep -hE '^(apply|upgrade)' "$dir"/*.calls | head -n 3 | tr '\n' ' '))"
    fi

    dir=$(fleet_dir '{"arc": "arc-density"}' base arc-density pools-closed netpol-second-vpc-egress)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$deploy_inputs"
    expect_fleet "policy set invalid after apply" $? 1 apply-fence,apply-netpol arc-density "STEP Verify runner network policy set: failure" \
        "found ['allow-vpc', 'redducklabs-runner-isolation']" "$dir"

    dir=$(fleet_dir '{"arc": "arc-density", "knobs": {"netpol_apply": "drift"}}' base arc-density pools-closed netpol-missing)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$deploy_inputs"
    expect_fleet "applied policy reads back different" $? 1 apply-fence,apply-netpol arc-density "STEP Verify runner network policy set: failure" \
        "spec differs" "$dir"
}


# ---------------------------------------------------------------------------
# Emergency Stop fence (Ruling 33): the marker ConfigMap
# arc-runners/runner-fleet-emergency-stop refuses every fleet mutator except an
# acknowledged Deploy `deploy`/`rollback` (and remove-burst), and every fleet
# Helm write re-reads it afterwards, re-applying 0/0 and failing when a stop is
# in effect. The regressions inject a completed Emergency Stop after the run's
# final admission and immediately before its Helm write (knobs.stop_before).
# ---------------------------------------------------------------------------

# expect_fenced <label> <rc> <mutations> <final-arc> <dir>: the run failed, its
# write was followed by a re-applied stop, and the fleet ends 0/0 with the marker.
expect_fenced() {
    local label=$1 rc=$2 mutations=$3 arc=$4 dir=$5
    expect_fleet "$label" "$rc" 1 "$mutations" "$arc" - "STOP_FENCE" "$dir"
    run_gate "$dir" --operation status
    if grep -Eq "^STATE: arc=${arc#arc-} " "$GATE_OUT" && grep -q '^STOP: Emergency Stop marker' "$GATE_OUT" \
        && [ "$(jq '[.runners[] | select(.busy | not)] | length' "${dir}/fleet.json")" = 0 ]; then
        pass "${label}: the fleet ends at ${arc#arc-} (0/0) with the stop marker and no idle runner"
    else
        fail "${label}: final gate $(tr '\n' ' ' < "$GATE_OUT") runners $(jq -c '.runners' "${dir}/fleet.json")"
    fi
}

assert_stop_fence() {
    info "Checking the Emergency Stop fence (Ruling 33)..."
    local dir rc op marker='"stop_marker": {"run-id": "4242", "time": "2026-10-27T10:00:00Z"}'

    # Static: Emergency Stop writes the marker before its Helm write.
    if python3 - "$EMERGENCY_WORKFLOW" <<'PY'
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["emergency-stop"]["steps"]
names = [step.get("name") for step in steps]
marker = steps[names.index("Write stop marker")]
assert names.index("Record current state") < names.index("Write stop marker") < names.index("Scale to zero")
assert "runner-fleet-emergency-stop" in marker["run"] and '--arg run "${RUN_ID}"' in marker["run"]
assert marker["env"]["RUN_ID"] == "${{ github.run_id }}"
assert "kubectl apply --server-side" in marker["run"]
assert steps[names.index("Report marker failure")]["if"] == "always() && steps.marker.outputs.marker_failed == 'true'"
PY
    then
        pass "Emergency Stop: the marker step runs after the state record and before the Helm write"
    else
        fail "Emergency Stop: the marker step is missing or not before the Helm write"
    fi

    # The gate while the marker exists.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", ${marker}}" base arc-burst pools-open)
    for op in acceptance-phase-c record-density set-burst-maxima create-burst configure-expander deploy enable-burst drain rollback; do
        run_gate "$dir" --operation "$op"
        rc=$?
        if [ "$rc" -eq 1 ] && grep -q "operation '${op}' is refused while the Emergency Stop marker arc-runners/runner-fleet-emergency-stop exists" "$GATE_ERR"; then
            pass "gate: ${op} is refused while the stop marker exists"
        else
            fail "gate: ${op} with the stop marker -> exit ${rc} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
        fi
    done
    run_gate "$dir" --operation status
    if [ "$?" -eq 0 ] && grep -qx 'STOP: Emergency Stop marker arc-runners/runner-fleet-emergency-stop present (run 4242 at 2026-10-27T10:00:00Z)' "$GATE_OUT" \
        && grep -qx 'STATE: arc=burst pools=both burst=open' "$GATE_OUT"; then
        pass "gate: status is admitted and reports the stop marker"
    else
        fail "gate: status with the marker -> $(tr '\n' ' ' < "$GATE_OUT") $(head -c 200 "$GATE_ERR")"
    fi
    run_gate "$dir" --operation rebalance
    if [ "$?" -eq 0 ] && grep -q '^STOP: ' "$GATE_OUT"; then
        pass "gate: rebalance is admitted as a stopped condition while the marker exists"
    else
        fail "gate: rebalance with the marker ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
    run_gate "$dir" --operation deploy --acknowledge-emergency-stop
    if [ "$?" -eq 0 ] && grep -qx 'STATE: arc=burst pools=both burst=open' "$GATE_OUT"; then
        pass "gate: deploy with --acknowledge-emergency-stop is admitted while the marker exists"
    else
        fail "gate: acknowledged deploy with the marker ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
    run_gate "$dir" --operation drain --acknowledge-emergency-stop
    if [ "$?" -eq 2 ] && grep -q 'valid only for deploy and rollback' "$GATE_ERR"; then
        pass "gate: --acknowledge-emergency-stop is a usage error for drain"
    else
        fail "gate: acknowledged drain was not a usage error ($(head -c 200 "$GATE_ERR"))"
    fi
    dir=$(fleet_dir '{"arc": "arc-burst", "knobs": {"marker_read": "fail"}}' base arc-burst pools-open)
    run_gate "$dir" --operation status
    if [ "$?" -eq 1 ] && grep -q '^REJECTED: .*configmap runner-fleet-emergency-stop' "$GATE_ERR"; then
        pass "gate: an unreadable stop marker rejects (fail closed)"
    else
        fail "gate: unreadable marker -> $(head -c 300 "$GATE_ERR" | tr '\n' ' ')"
    fi

    # Codex PR #35 finding 1, the regression: a completed Emergency Stop lands
    # after the run's final admission and before its Helm write. The old run
    # must re-stop and fail, and the fleet must end 0/0.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:burst\", \"fence_unenforced\": true}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}, {\"name\": \"base1\", \"node\": \"baseline-b\"}]}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fenced "deploy whose Helm write lands after a completed stop" $? \
        apply-fence,apply-netpol,injected-stop-marker,injected-stop,helm-upgrade:burst,helm-upgrade:stopped arc-burst-stopped "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:drain\", \"fence_unenforced\": true}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}]}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fenced "drain whose Helm write lands after a completed stop" $? \
        injected-stop-marker,injected-stop,helm-upgrade:drain,helm-upgrade:stopped arc-drain-stopped "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:min=8\", \"fence_unenforced\": true}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}, {\"name\": \"base1\", \"node\": \"baseline-b\"}]}" base arc-burst pools-open)
    run_fleet_workflow "$SCALE_WORKFLOW" "$dir" "{\"action\":\"acceptance-phase-c\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fenced "Phase C whose Helm write lands after a completed stop" $? \
        injected-stop-marker,injected-stop,helm-upgrade:stopped arc-burst-stopped "$dir"
    if grep -qx 'STEP Restore burst after Phase C: failure' "$FLEET_OUT"; then
        pass "Phase C after a stop: the always-run restore refuses to reopen the fleet"
    else
        fail "Phase C after a stop: restore step $(grep 'Restore burst' "$FLEET_OUT")"
    fi
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"knobs\": {\"stop_before\": \"helm-upgrade:density\", \"fence_unenforced\": true}}" base arc-drain)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fenced "rollback whose Helm write lands after a completed stop" $? \
        apply-fence,injected-stop-marker,injected-stop,helm-upgrade:density,helm-upgrade:stopped arc-density-stopped "$dir"
    # A newer stop after the acknowledged delete is not acknowledged by it.
    dir=$(fleet_dir "{\"arc\": \"arc-burst-stopped\", ${marker}, \"knobs\": {\"stop_before\": \"helm-upgrade:burst\", \"fence_unenforced\": true}}" base arc-burst-stopped pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fenced "acknowledged deploy with a newer stop before its Helm write" $? \
        stop-marker:delete,probe:allowed,apply-fence,apply-netpol,injected-stop-marker,injected-stop,helm-upgrade:burst,helm-upgrade:stopped arc-burst-stopped "$dir"
    # The marker cannot be read after the write: fail closed (re-stop).
    dir=$(fleet_dir '{"arc": "arc-burst", "knobs": {"marker_read": "fail-after-write"}}' base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy whose post-write marker read fails" $? 1 apply-fence,apply-netpol,helm-upgrade:burst,helm-upgrade:stopped arc-burst-stopped - "could not be read after the Helm write" "$dir"

    # A newer stop rewrites the marker between the acknowledging read and the
    # delete: the guarded delete fails and nothing is written.
    dir=$(fleet_dir "{\"arc\": \"arc-burst-stopped\", ${marker}, \"knobs\": {\"marker_bump_before_delete\": true}}" base arc-burst-stopped pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fleet "acknowledged deploy racing a newer stop's marker write" $? 1 - arc-burst-stopped "STEP Acknowledge Emergency Stop: failure" "the fleet stays stopped" "$dir"
    if [ "$(jq -r '.stop_marker.data["run-id"]' "${dir}/fleet.json")" = newer ] && ! grep -q '^upgrade' "${dir}/helm.calls"; then
        pass "the newer stop's marker survives and no Helm write ran"
    else
        fail "after the marker race: marker $(jq -c '.stop_marker' "${dir}/fleet.json"), helm $(grep -c '^upgrade' "${dir}/helm.calls")"
    fi
    # acknowledge_emergency_stop is rejected for operations that cannot use it.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", ${marker}}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"drain\",\"acknowledge_emergency_stop\":\"true\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "drain with acknowledge_emergency_stop" $? 1 - arc-burst "JOB validate-inputs: failure" - "$dir"

    # Emergency Stop whose marker write fails: the stop is still applied, and
    # the run fails so the missing fence is visible.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"marker_write\": \"fail\"}}" base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop whose marker write fails" $? 1 helm-upgrade:stopped arc-burst-stopped "STEP Report marker failure: failure" - "$dir"

    # Rebalance and Runner Status report the marker as a stopped condition.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", ${marker}, \"burst_nodes\": [{\"name\": \"github-runners-burst-amd-16g-p1q2r\", \"pool\": \"github-runners-burst-amd-16g\"}], \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}, {\"name\": \"burstaa\", \"node\": \"github-runners-burst-amd-16g-p1q2r\"}]}" base arc-burst pools-open)
    FLEET_GITHUB_CONTEXT="{\"event_name\":\"workflow_dispatch\",\"sha\":\"${FLEET_SHA}\",\"ref\":\"refs/heads/main\"}" \
        run_fleet_workflow "$REBALANCE_WORKFLOW" "$dir" "{\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "rebalance on burst with the stop marker" $? 0 - arc-burst "STEP Retire idle burst runners: skipped" - "$dir"
    if fleet_summary | grep -q '^nothing to rebalance: the Emergency Stop marker is present'; then
        pass "rebalance with the stop marker: notice in the summary, nothing retired"
    else
        fail "rebalance with the stop marker lacks the notice ($(fleet_steps))"
    fi
    dir=$(status_dir "{\"arc\": \"arc-burst\", ${marker}}" base arc-burst pools-open)
    run_status "$dir"
    if status_summary | grep -q 'Emergency Stop in effect' && no_mutating_calls "$dir"; then
        pass "Runner Status reports the stop marker read-only"
    else
        fail "Runner Status with the stop marker: $(status_summary | grep -i 'pool state' | head -c 300)"
    fi
}


# ---------------------------------------------------------------------------
# Server-side Emergency Stop fence (Ruling 36): the ValidatingAdmissionPolicy
# and binding in deploy/runner-emergency-stop-fence.yaml make the API server
# deny every AutoscalingRunnerSet write that is not 0/0 while the stop marker
# exists. The fleet fake enforces it (test/fixtures/fleet/fleet_sim.py), so a
# stale writer terminated right after its Helm call is denied by the "server".
# ---------------------------------------------------------------------------

# fence_gate_dir <mode> <layers...>: a pool-state dir whose fence objects are
# changed: absent, policy-only, binding-drift, policy-drift, type-warning,
# read-fail.
fence_gate_dir() {
    local mode=$1 src dir
    shift
    src=$(pool_state_dir "$@") || return 1
    dir=$(mktemp -d "${WORK_DIR}/fence.XXXXXX")
    cp -r "${src}/." "${dir}/"
    rm -f "$dir"/*.calls
    case "$mode" in
        absent) : > "${dir}/fence-policy.json"; : > "${dir}/fence-binding.json" ;;
        policy-only) : > "${dir}/fence-binding.json" ;;
        binding-drift)
            jq '.spec.validationActions = ["Warn"]' "${dir}/fence-binding.json" > "${dir}/next" && mv "${dir}/next" "${dir}/fence-binding.json" ;;
        policy-drift)
            jq '.spec.validations[0].expression = "true"' "${dir}/fence-policy.json" > "${dir}/next" && mv "${dir}/next" "${dir}/fence-policy.json" ;;
        type-warning)
            jq '.status.typeChecking.expressionWarnings = [{"fieldRef": "spec.validations[0].expression", "warning": "fixture"}]' \
                "${dir}/fence-policy.json" > "${dir}/next" && mv "${dir}/next" "${dir}/fence-policy.json" ;;
        read-fail) echo 1 > "${dir}/fence-policy.json.rc" ;;
    esac
    printf '%s\n' "$dir"
}

# expect_fence_gate <label> <dir> <operation> <exit> <stderr-or-STATE-line>
expect_fence_gate() {
    local label=$1 dir=$2 operation=$3 expected=$4 text=$5 rc
    run_gate "$dir" --operation "$operation"
    rc=$?
    if [ "$rc" -ne "$expected" ]; then
        fail "${label}: ${operation} exit ${rc}, expected ${expected} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    elif [ "$expected" -eq 0 ] && grep -qxF -- "$text" "$GATE_OUT"; then
        pass "${label}: ${operation} admitted"
    elif [ "$expected" -ne 0 ] && grep -qF -- "$text" "$GATE_ERR"; then
        pass "${label}: ${operation} rejected (${text})"
    else
        fail "${label}: ${operation} lacks '${text}' ($(head -c 300 "$GATE_ERR" | tr '\n' ' ') $(tr '\n' ' ' < "$GATE_OUT"))"
    fi
}

assert_server_fence() {
    info "Checking the server-side Emergency Stop fence (Ruling 36)..."
    local dir op rc mode marker='"stop_marker": {"run-id": "4242", "time": "2026-10-27T10:00:00Z"}'
    local fenced='requires the Emergency Stop fence runner-fleet-emergency-stop-fence'

    # The exact manifest contract.
    if (cd "$REPO_ROOT" && python3 -) <<'PY'
import yaml

documents = [d for d in yaml.safe_load_all(open("deploy/runner-emergency-stop-fence.yaml", encoding="utf-8")) if d]
assert len(documents) == 2, len(documents)
policy, binding = documents
selector = {"matchLabels": {"kubernetes.io/metadata.name": "arc-runners"}}
assert policy == {
    "apiVersion": "admissionregistration.k8s.io/v1",
    "kind": "ValidatingAdmissionPolicy",
    "metadata": {"name": "runner-fleet-emergency-stop-fence"},
    "spec": {
        "failurePolicy": "Fail",
        "paramKind": {"apiVersion": "v1", "kind": "ConfigMap"},
        "matchConstraints": {
            "matchPolicy": "Equivalent",
            "namespaceSelector": selector,
            "objectSelector": {},
            "resourceRules": [{
                "apiGroups": ["actions.github.com"], "apiVersions": ["v1alpha1"],
                "operations": ["CREATE", "UPDATE"], "resources": ["autoscalingrunnersets"], "scope": "Namespaced",
            }],
        },
        "validations": [{
            "expression": "has(object.spec.maxRunners) && object.spec.maxRunners == 0 && "
                          "(!has(object.spec.minRunners) || object.spec.minRunners == 0)",
            "message": policy["spec"]["validations"][0]["message"],
            "reason": "Forbidden",
        }],
    },
}, policy
message = policy["spec"]["validations"][0]["message"]
assert message.startswith("runner-fleet-emergency-stop-fence: ") and "arc-runners/runner-fleet-emergency-stop" in message
assert binding == {
    "apiVersion": "admissionregistration.k8s.io/v1",
    "kind": "ValidatingAdmissionPolicyBinding",
    "metadata": {"name": "runner-fleet-emergency-stop-fence"},
    "spec": {
        "policyName": "runner-fleet-emergency-stop-fence",
        "paramRef": {"name": "runner-fleet-emergency-stop", "namespace": "arc-runners",
                     "parameterNotFoundAction": "Allow"},
        "validationActions": ["Deny"],
        "matchResources": {"matchPolicy": "Equivalent", "namespaceSelector": selector, "objectSelector": {}},
    },
}, binding
PY
    then
        pass "fence manifest: VAP (ConfigMap param, Fail, ASRS v1alpha1 CREATE/UPDATE in arc-runners, 0/0 rule) and Deny binding on the marker with parameterNotFoundAction Allow"
    else
        fail "deploy/runner-emergency-stop-fence.yaml does not match the Ruling 36 contract"
    fi

    # The rule itself, evaluated over the shapes ARC writes (a CEL-equivalent
    # check of the committed expression's three clauses).
    if python3 - <<'PY'
def allowed(spec):
    return "maxRunners" in spec and spec["maxRunners"] == 0 and ("minRunners" not in spec or spec["minRunners"] == 0)

assert allowed({"minRunners": 0, "maxRunners": 0}) and allowed({"maxRunners": 0})
for spec in ({"minRunners": 2, "maxRunners": 20}, {"minRunners": 0, "maxRunners": 1}, {"minRunners": 2, "maxRunners": 0}, {}):
    assert not allowed(spec), spec
PY
    then
        pass "fence rule: only 0/0 (or max 0 with min absent) passes while the marker exists"
    else
        fail "fence rule truth table is wrong"
    fi

    # Workflow static order: Deploy installs the fence after the
    # acknowledgement and before the network policy, the re-admission and Helm.
    if (cd "$REPO_ROOT" && python3 - "$DEPLOY_WORKFLOW" "$EMERGENCY_WORKFLOW") <<'PY'
import sys

import yaml

steps = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]["deploy"]["steps"]
names = [step["name"] for step in steps]
order = ["Render and validate candidate", "Acknowledge Emergency Stop", "Server-side preflight candidate",
         "Dry-run Emergency Stop fence", "Apply Emergency Stop fence",
         "Dry-run runner network policy", "Re-admit immediately before Helm", "Deploy runners"]
indices = [names.index(name) for name in order]
assert indices == sorted(indices), names
assert "--dry-run=server" not in steps[indices[0]]["run"] and "helm template" in steps[indices[0]]["run"]
assert "--dry-run=server" in steps[indices[2]]["run"]
assert "fleet_fence_dry_run" in steps[indices[3]]["run"]
apply = steps[indices[4]]["run"]
assert apply.index("git rev-parse HEAD") < apply.index('fleet_install_fence "${RUNNER_TEMP}/pool-identities.json" deploy')
stop = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))["jobs"]["emergency-stop"]["steps"]
names = [step.get("name") for step in stop]
assert names.index("Write stop marker") < names.index("Verify stop fence") < names.index("Scale to zero")
fence = stop[names.index("Verify stop fence")]
assert fence.get("continue-on-error") is True, "the fence check must never block the stop"
assert "fleet_fence_wait denied" in fence["run"] and "runner_stop_fence.py verify" in fence["run"]
report = stop[names.index("Report fence failure")]
assert report["if"] == "always() && steps.fence.outputs.fence_failed == 'true'"
assert stop[names.index("Scale to zero")]["if"] == "steps.backup.outputs.deployment_exists == 'true'"
config = yaml.safe_load(open(".github/workflows/validate-config.yml", encoding="utf-8"))
syntax = next(step["run"] for job in config["jobs"].values() for step in job["steps"]
              if step.get("name") == "Validate YAML syntax")
assert "yaml.safe_load_all(" in syntax and "deploy/*.yaml" in syntax, "the two-document fence must be parsed"
PY
    then
        pass "workflows: Deploy installs the fence before the NetworkPolicy and Helm; Emergency Stop proves it between the marker and its write, never blocking the stop"
    else
        fail "fence step order in Deploy or Emergency Stop is wrong"
    fi

    # Gate: mutators require the exact fence; status, record-density, deploy,
    # rollback and remove-burst do not.
    dir=$(fence_gate_dir absent valid-burst-mixed) || { fail "fence gate fixture could not be built"; return; }
    for op in drain rebalance; do
        expect_fence_gate "fence absent on burst" "$dir" "$op" 1 "$fenced"
    done
    expect_fence_gate "fence absent on burst" "$dir" deploy 0 "STATE: arc=burst pools=both burst=open"
    expect_fence_gate "fence absent on burst" "$dir" status 0 "STATE: arc=burst pools=both burst=open"
    if ! grep -q validatingadmission "${dir}/kubectl.calls" 2>/dev/null; then
        pass "fence absent on burst: status does not read the fence"
    else
        fail "status read the fence objects"
    fi
    dir=$(fence_gate_dir absent base arc-burst pools-open)
    for op in set-burst-maxima acceptance-phase-c configure-expander create-burst; do
        expect_fence_gate "fence absent on burst (pools open)" "$dir" "$op" 1 "$fenced"
    done
    dir=$(fence_gate_dir absent enable-stage-closed)
    expect_fence_gate "fence absent on burst (closed stage)" "$dir" enable-burst 1 "$fenced"
    dir=$(fence_gate_dir absent valid-density-no-burst)
    expect_fence_gate "fence absent before the first burst deploy" "$dir" create-burst 0 "STATE: arc=density pools=none burst=closed"
    expect_fence_gate "fence absent before the first burst deploy" "$dir" record-density 0 "STATE: arc=density pools=none burst=closed"
    dir=$(fence_gate_dir absent drain-for-remove)
    expect_fence_gate "fence absent on drain" "$dir" remove-burst 0 "STATE: arc=drain pools=both burst=open"
    for mode in policy-only binding-drift policy-drift type-warning; do
        dir=$(fence_gate_dir "$mode" valid-burst-mixed)
        expect_fence_gate "fence ${mode}" "$dir" drain 1 "$fenced"
        dir=$(fence_gate_dir "$mode" valid-density-no-burst)
        expect_fence_gate "fence ${mode} before the first burst deploy" "$dir" create-burst 1 "$fenced"
    done
    dir=$(fence_gate_dir binding-drift valid-burst-mixed)
    expect_fence_gate "fence binding-drift" "$dir" drain 1 "ValidatingAdmissionPolicyBinding runner-fleet-emergency-stop-fence spec differs"
    dir=$(fence_gate_dir read-fail valid-burst-mixed)
    expect_fence_gate "fence read failure" "$dir" drain 1 "REJECTED: Emergency Stop fence:"
    expect_fence_gate "fence read failure" "$dir" status 0 "STATE: arc=burst pools=both burst=open"

    # A drain run refuses at admission when the fence is missing.
    dir=$(fleet_dir '{"arc": "arc-burst", "fence": "absent"}' base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain with the fence missing" $? 1 - arc-burst "STEP Admit pool state and record identities: failure" "$fenced" "$dir"
    dir=$(fleet_dir '{"arc": "arc-burst", "fence": "drift"}' base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "drain with a drifted fence" $? 1 - arc-burst "STEP Admit pool state and record identities: failure" "$fenced" "$dir"

    # Deploy installs the fence (bootstrap) with a dry-run comparison first.
    dir=$(fleet_dir '{"arc": "arc-density", "fence": "absent"}' base arc-density pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy installs a missing fence before Helm" $? 0 apply-fence,apply-netpol,helm-upgrade:burst arc-burst "STEP Apply Emergency Stop fence: success" - "$dir"
    if [ "$(grep -n -- '--dry-run=server -f deploy/runner-emergency-stop-fence.yaml' "${dir}/kubectl.calls" | cut -d: -f1)" \
        -lt "$(grep -n -- '^apply --server-side -f deploy/runner-emergency-stop-fence.yaml' "${dir}/kubectl.calls" | cut -d: -f1)" ] \
        && grep -q 'FENCE: runner-fleet-emergency-stop-fence (policy and binding) matches deploy/runner-emergency-stop-fence.yaml; type checked without expression warnings' "$FLEET_ERR"; then
        pass "deploy: the fence dry run precedes the apply, and the type-checked readback passed"
    else
        fail "deploy fence calls out of order or no type-checked readback ($(grep -n 'fence' "${dir}/kubectl.calls" | head -n 4 | tr '\n' ' '))"
    fi
    run_gate "$dir" --operation drain
    if [ "$?" -eq 0 ]; then
        pass "after deploy installed it, drain admission accepts the fence"
    else
        fail "drain after the fence install: $(head -c 300 "$GATE_ERR")"
    fi
    for mode in fail defaulted; do
        dir=$(fleet_dir "{\"arc\": \"arc-density\", \"fence\": \"absent\", \"knobs\": {\"fence_dry_run\": \"${mode}\"}}" base arc-density pools-closed)
        run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
        expect_fleet "deploy with a fence dry run that ${mode}s" $? 1 - arc-density "STEP Dry-run Emergency Stop fence: failure" - "$dir"
    done
    if grep -qF '"scope": "*"' "$FLEET_ERR" && grep -qF 'the server would store a different ValidatingAdmissionPolicy spec' "$FLEET_ERR"; then
        pass "defaulted fence dry run: the diff is printed and nothing is applied"
    else
        fail "defaulted fence dry run: no diff or wrong message"
    fi
    dir=$(fleet_dir '{"arc": "arc-density", "fence": "absent", "knobs": {"fence_apply": "drift"}}' base arc-density pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy whose applied fence reads back different" $? 1 apply-fence arc-density "STEP Apply Emergency Stop fence: failure" "spec differs" "$dir"
    dir=$(fleet_dir '{"arc": "arc-density", "fence": "absent", "knobs": {"fence_type_check": "warning"}}' base arc-density pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy whose fence reports a type-check warning" $? 1 apply-fence arc-density "STEP Apply Emergency Stop fence: failure" "type-checking expression warning" "$dir"
    dir=$(fleet_dir '{"arc": "arc-density", "fence": "absent", "knobs": {"fence_type_check": "pending"}}' base arc-density pools-closed)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "deploy waits for the fence's type checking" $? 0 apply-fence,apply-netpol,helm-upgrade:burst arc-burst - "type checking of its current generation is not reported yet" "$dir"
    # Rollback (the other installer) from drain-stopped with a drifted fence.
    dir=$(fleet_dir "{\"arc\": \"arc-drain-stopped\", \"fence\": \"drift\", ${marker}}" base arc-drain-stopped)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$ROLLBACK_ACK_INPUTS"
    expect_fleet "acknowledged rollback reinstalls a drifted fence" $? 0 stop-marker:delete,probe:allowed,apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"

    # Emergency Stop proves the denial; missing, drifted or unenforced fences
    # end red with the stop applied.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop proves the fence" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-burst-stopped "STEP Verify stop fence: success" "STOP_FENCE_PROBE: a dry-run maxRunners=1 write is denied" "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"fence_lag\": 2}}" base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop waits out informer lag" $? 0 stop-marker:set,probe:allowed,probe:allowed,probe:denied,helm-upgrade:stopped arc-burst-stopped "STEP Report fence failure: skipped" - "$dir"
    for mode in absent drift; do
        dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"fence\": \"${mode}\"}" base arc-burst pools-open)
        run_emergency_stop "$dir"
        expect_fleet "emergency stop with the fence ${mode}" $? 1 stop-marker:set,helm-upgrade:stopped arc-burst-stopped "STEP Report fence failure: failure" "this stop is NOT enforced server-side" "$dir"
    done
    dir=$(fleet_dir '{"arc": "arc-burst", "knobs": {"fence_unenforced": true}}' base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop whose fence never denies" $? 1 "stop-marker:set,probe:allowed,probe:allowed,*,probe:allowed,helm-upgrade:stopped" arc-burst-stopped "STEP Report fence failure: failure" "still allowed after 30s" "$dir"
    if grep -qx 'STEP Scale to zero: success' "$FLEET_OUT" && grep -qx 'STEP Read back stopped state: success' "$FLEET_OUT"; then
        pass "emergency stop whose fence never denies: the stop was still applied and read back"
    else
        fail "emergency stop whose fence never denies: $(fleet_steps)"
    fi
    dir=$(fleet_dir '{"arc": "arc-burst", "knobs": {"fence_probe": "error"}}' base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "emergency stop whose fence probe errors" $? 1 stop-marker:set,helm-upgrade:stopped arc-burst-stopped "STEP Report fence failure: failure" "failed for another reason" "$dir"

    # Codex PR #35 review 3 finding 1: recovery through the enforced fence.
    # Emergency Stop runs for real (the fake API server enforces the fence,
    # including for Deploy's nonzero ASRS server-side preflight); the
    # acknowledged Deploy must delete the marker before that preflight.
    dir=$(fleet_dir "$FLEET_IDLE_BURST" base arc-burst pools-open)
    run_emergency_stop "$dir"
    expect_fleet "enforced stop before an acknowledged recovery" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-burst-stopped "STEP Verify stop fence: success" - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fleet "acknowledged deploy recovers an enforced burst-stopped fleet" $? 0 \
        stop-marker:delete,probe:allowed,apply-fence,apply-netpol,helm-upgrade:burst arc-burst "STEP Verify Helm transition and burst readback: success" - "$dir"
    if python3 - "$FLEET_OUT" <<'PY'
import sys

steps = [line.split(": ")[0][5:] for line in open(sys.argv[1], encoding="utf-8") if line.startswith("STEP ")]
order = ["Render and validate candidate", "Acknowledge Emergency Stop", "Server-side preflight candidate",
         "Dry-run Emergency Stop fence", "Deploy runners"]
assert [steps.index(name) for name in order] == sorted(steps.index(name) for name in order), steps
PY
    then
        pass "acknowledged deploy: local render and validation, then the acknowledgement, then the ASRS server-side preflight"
    else
        fail "acknowledged deploy ran its steps out of order ($(fleet_steps))"
    fi
    # Rollback renders and validates locally before its acknowledgement and
    # has no ASRS server-side preflight; its recovery passes the enforced fence.
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"history\": ${FLEET_DENSITY_HISTORY}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}]}" base arc-drain)
    run_emergency_stop "$dir"
    expect_fleet "enforced stop on drain without pools" $? 0 stop-marker:set,probe:denied,helm-upgrade:stopped arc-drain-stopped - - "$dir"
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$ROLLBACK_ACK_INPUTS"
    expect_fleet "acknowledged rollback recovers an enforced drain-stopped fleet" $? 0 \
        stop-marker:delete,probe:allowed,apply-fence,helm-upgrade:density arc-density "STEP Verify pool state after rollback: success" - "$dir"
    # The fake judges ASRS server-side dry runs: with the marker present and
    # the fence enforcing, a nonzero preflight is denied.
    dir=$(fleet_dir "{\"arc\": \"arc-burst-stopped\", ${marker}}" base arc-burst-stopped pools-open)
    printf '%s\n' '{"apiVersion": "actions.github.com/v1alpha1", "kind": "AutoscalingRunnerSet", "metadata": {"name": "redducklabs-runners-compatibility-preflight", "namespace": "arc-runners"}, "spec": {"minRunners": 2, "maxRunners": 20}}' > "${dir}/preflight-asrs.json"
    if ! with_fakes "$dir" kubectl apply --server-side --force-conflicts --dry-run=server -f "${dir}/preflight-asrs.json" -o json > /dev/null 2> "${WORK_DIR}/preflight.err" \
        && grep -q "ValidatingAdmissionPolicy 'runner-fleet-emergency-stop-fence'" "${WORK_DIR}/preflight.err"; then
        pass "fleet fake: a nonzero ASRS server-side dry run is denied by the enforced fence while the marker exists"
    else
        fail "fleet fake accepted a nonzero ASRS dry run under the marker"
    fi

    # An acknowledged deploy waits until the fence allows writes after the
    # delete; if it never does, nothing is written.
    dir=$(fleet_dir "{\"arc\": \"arc-burst-stopped\", ${marker}, \"knobs\": {\"fence_lag\": 2}}" base arc-burst-stopped pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fleet "acknowledged deploy waits out informer lag" $? 0 stop-marker:delete,probe:denied,probe:denied,probe:allowed,apply-fence,apply-netpol,helm-upgrade:burst arc-burst - - "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-burst-stopped\", ${marker}, \"knobs\": {\"fence_lag\": 100}}" base arc-burst-stopped pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_ACK_INPUTS"
    expect_fleet "acknowledged deploy whose fence keeps denying" $? 1 "stop-marker:delete,probe:denied,*,probe:denied" arc-burst-stopped "STEP Acknowledge Emergency Stop: failure" "no acknowledgement is needed" "$dir"

    # Codex PR #35 re-review finding 1: a completed Emergency Stop lands after
    # the old run's final admission; its stale Helm write follows and the
    # writer is terminated right after the Helm call, before its client-side
    # fence. The API server denies the write, so the fleet stays 0/0.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:burst\", \"term_after\": \"helm-upgrade:burst\"}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}, {\"name\": \"base1\", \"node\": \"baseline-b\"}]}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "stale deploy terminated after its denied Helm write" $? 1 \
        apply-fence,apply-netpol,injected-stop-marker,injected-stop,helm-upgrade:burst:denied,writer-terminated arc-burst-stopped "STEP Deploy runners: cancelled" - "$dir"
    if [ "$(jq '[.runners[] | select(.busy | not)] | length' "${dir}/fleet.json")" = 0 ] && [ "$(jq -r '.stop_marker.data["run-id"]' "${dir}/fleet.json")" = injected ]; then
        pass "stale deploy terminated after its Helm call: the fleet is still 0/0 with the marker, no runner started"
    else
        fail "stale deploy terminated: runners $(jq -c '.runners' "${dir}/fleet.json")"
    fi
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:drain\", \"term_after\": \"helm-upgrade:drain\"}, \"runners\": [{\"name\": \"base0\", \"node\": \"baseline-a\"}]}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DRAIN_INPUTS"
    expect_fleet "stale drain terminated after its denied Helm write" $? 1 \
        injected-stop-marker,injected-stop,helm-upgrade:drain:denied,writer-terminated arc-burst-stopped - - "$dir"
    dir=$(fleet_dir "{\"arc\": \"arc-drain\", \"knobs\": {\"stop_before\": \"helm-upgrade:density\", \"term_after\": \"helm-upgrade:density\"}}" base arc-drain)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "{\"operation\":\"rollback\",\"expected_sha\":\"${FLEET_SHA}\"}"
    expect_fleet "stale rollback terminated after its denied Helm write" $? 1 \
        apply-fence,injected-stop-marker,injected-stop,helm-upgrade:density:denied,writer-terminated arc-drain-stopped - - "$dir"
    # Control: the same interleaving against an API server that does not
    # enforce the fence reopens the fleet; this is the gap the fence closes.
    dir=$(fleet_dir "{\"arc\": \"arc-burst\", \"knobs\": {\"stop_before\": \"helm-upgrade:burst\", \"term_after\": \"helm-upgrade:burst\", \"fence_unenforced\": true}}" base arc-burst pools-open)
    run_fleet_workflow "$DEPLOY_WORKFLOW" "$dir" "$DEPLOY_INPUTS"
    expect_fleet "control: stale deploy terminated with the fence not enforced" $? 1 \
        apply-fence,apply-netpol,injected-stop-marker,injected-stop,helm-upgrade:burst,writer-terminated arc-burst - - "$dir"
}

# ---------------------------------------------------------------------------
# Ruling 39: doctl omits zero-valued node-pool fields (godo omitempty). The
# fakes serve every node-pool list in that encoding (doctl_encoding.py); these
# cases pin the incident shapes and the fail-closed explicit null.
# ---------------------------------------------------------------------------

PRIMARY_POOL=github-runners-burst-amd-16g
FALLBACK_POOL=github-runners-burst-intel-16g

served_pool_keys() {  # dir pool-name -> the sorted keys the doctl fake prints for that pool
    with_fakes "$1" doctl kubernetes cluster node-pool list fixture-cluster -o json \
        | jq -c --arg n "$2" '[.[] | select(.name == $n) | keys] | if length == 1 then .[0] else "absent" end'
}

assert_doctl_zero_encoding() {
    info "Checking readers against doctl's omitted-zero node-pool encoding (Ruling 39)..."
    local dir keys rc occupancy
    local closed_keys='["auto_scale","id","labels","name","size","tags","taints"]'

    # The fake prints a closed pool with exactly the keys the live pool had.
    dir=$(pool_state_dir create-one-closed) || { fail "zero encoding: fixture could not be built"; return; }
    keys=$(served_pool_keys "$dir" "$PRIMARY_POOL")
    if [ "$keys" = "$closed_keys" ]; then
        pass "zero encoding: the doctl fake prints a closed pool with only ${closed_keys}"
    else
        fail "zero encoding: the doctl fake printed keys ${keys} for a closed pool, expected ${closed_keys}"
    fi

    # (1) The incident: create-burst from no burst pools. The primary's readback
    # arrives with count/min_nodes/max_nodes omitted; identity must still hold
    # and the fallback must be created next.
    dir=$(burst_dir valid-density-no-burst) || { fail "zero encoding create: fixture could not be built"; return; }
    expect_burst "zero encoding: create-burst from no pools creates the primary then the fallback" "$dir" create-burst 0 \
        create:primary,create:fallback "primary=0/0 fallback=0/0" "RESULT: create-burst applied" create-burst
    if grep -qx "READBACK: pool '${PRIMARY_POOL}' is 0/0" "$BURST_OUT" \
        && grep -qx "READBACK: pool '${FALLBACK_POOL}' is 0/0" "$BURST_OUT" \
        && ! grep -q 'IDENTITY_DRIFT' "$BURST_OUT" "$BURST_ERR" \
        && [ "$(served_pool_keys "$dir" "$PRIMARY_POOL")" = "$closed_keys" ] \
        && [ "$(served_pool_keys "$dir" "$FALLBACK_POOL")" = "$closed_keys" ]; then
        pass "zero encoding: both closed pools read back 0/0 from omitted keys, no IDENTITY_DRIFT"
    else
        fail "zero encoding: create-burst readback is wrong ($(grep -E 'READBACK|IDENTITY_DRIFT|RESULT' "$BURST_OUT" "$BURST_ERR" | head -n 6 | tr '\n' '|'))"
    fi
    expect_burst "zero encoding: create-burst re-run on two omitted-zero pools is a no-op" "$dir" create-burst 0 - \
        "primary=0/0 fallback=0/0" "NOOP: pool '${FALLBACK_POOL}' already exists closed" create-burst

    # (3) The live state after the failed run: ARC density, the primary closed
    # with its zero keys omitted, the fallback absent.
    expect_gate "create-one-closed" create-burst 0 "STATE: arc=density pools=primary burst=closed"
    expect_gate "create-one-closed" remove-burst 0 "STATE: arc=density pools=primary burst=closed"
    expect_gate "create-one-closed" status 0 "STATE: arc=density pools=primary burst=closed"
    dir=$(burst_dir create-one-closed) || { fail "zero encoding live state: fixture could not be built"; return; }
    expect_burst "zero encoding: create-burst on the live state creates only the fallback" "$dir" create-burst 0 \
        create:fallback "primary=0/0 fallback=0/0" "NOOP: pool '${PRIMARY_POOL}' already exists closed (0/0)" create-burst
    dir=$(burst_dir create-one-closed) || { fail "zero encoding live remove: fixture could not be built"; return; }
    expect_burst "zero encoding: remove-burst on the live state deletes the closed primary" "$dir" remove-burst 0 \
        delete:primary "primary=absent fallback=absent" - remove-burst

    # (2) An explicitly present null is not an omitted zero: it fails closed.
    local field operation start
    for field in max_nodes min_nodes count; do
        dir=$(burst_dir create-one-closed) || { fail "zero encoding null ${field}: fixture could not be built"; continue; }
        jq --arg n "$PRIMARY_POOL" --arg f "$field" 'map(if .name == $n then .[$f] = null else . end)' \
            "${dir}/pools.json" > "${dir}/pools.json.new" && mv "${dir}/pools.json.new" "${dir}/pools.json"
        for operation in create-burst remove-burst status; do
            run_gate "$dir" --operation "$operation"
            rc=$?
            if [ "$rc" -eq 1 ] && grep -qF "pool '${PRIMARY_POOL}' ${field} is not a non-negative integer" "$GATE_ERR"; then
                pass "zero encoding: explicit \"${field}\": null is rejected by ${operation}"
            else
                fail "zero encoding: explicit \"${field}\": null under ${operation} exited ${rc} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
            fi
        done
    done
    # A null that appears after admission stops burst-pools.sh before any mutation.
    start=$(burst_dir create-one-closed) || { fail "zero encoding null after admission: fixture could not be built"; return; }
    if burst_snapshot "$start" create-burst; then
        jq --arg n "$PRIMARY_POOL" 'map(if .name == $n then .max_nodes = null else . end)' \
            "${start}/pools.json" > "${start}/pools.json.new" && mv "${start}/pools.json.new" "${start}/pools.json"
        run_burst "$start" "$BURST_SNAPSHOT" create-burst --apply
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$(burst_mutations "$start")" = - ] && grep -qF 'max_nodes' "$BURST_ERR"; then
            pass "zero encoding: an explicit max_nodes null after admission stops create-burst (exit ${rc}) with no mutation"
        else
            fail "zero encoding: explicit null after admission: exit ${rc}, mutations $(burst_mutations "$start") ($(tail -c 300 "$BURST_ERR" | tr '\n' ' '))"
        fi
    else
        fail "zero encoding null after admission: snapshot not admitted ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
    # The same explicit zeros printed verbatim (not omitted) are still admitted.
    dir=$(burst_dir create-one-closed) || { fail "zero encoding verbatim: fixture could not be built"; return; }
    : > "${dir}/doctl-pools-verbatim"
    expect_burst "zero encoding: explicit zeros (verbatim) still create only the fallback" "$dir" create-burst 0 \
        create:fallback "primary=0/0 fallback=0/0" - create-burst

    # (4) Runner Status and the pool report print 0/0 for an omitted-zero pool.
    dir=$(status_dir '{"arc": "arc-density"}' create-one-closed) || { fail "zero encoding status: fixture could not be built"; return; }
    run_status "$dir"
    expect_fleet "zero encoding: Runner Status on the live state" $? 0 - arc-density "STEP Admit pool state (status): success" - "$dir"
    if status_summary | grep -qx "POOL ${PRIMARY_POOL} provider_count=0 min=0 max=0 auto_scale=true registered=0 ready=0" \
        && status_summary | grep -qx "POOL ${FALLBACK_POOL} absent" \
        && ! status_summary | grep -q 'unknown'; then
        pass "zero encoding: Runner Status prints provider_count=0 min=0 max=0 for the omitted-zero primary"
    else
        fail "zero encoding: Runner Status pool lines are wrong ($(status_summary | grep -E '^POOL' | tr '\n' '|'))"
    fi
    dir=$(pool_state_dir create-one-closed) || { fail "zero encoding report: fixture could not be built"; return; }
    with_fakes "$dir" env "NOW_CMD=echo ${POOL_STATE_NOW}" bash "${REPO_ROOT}/scripts/report-runner-pools.sh" \
        --cluster-name redducklabs-cluster > "$GATE_OUT" 2> "$GATE_ERR"
    rc=$?
    if [ "$rc" -eq 0 ] \
        && grep -qx "POOL ${PRIMARY_POOL} provider_count=0 min=0 max=0 auto_scale=true registered=0 ready=0" "$GATE_OUT"; then
        pass "zero encoding: report-runner-pools.sh prints 0/0 for the omitted-zero primary"
    else
        fail "zero encoding: pool report exit ${rc} ($(head -c 400 "$GATE_OUT" | tr '\n' '|'))"
    fi

    # fleet_occupancy (Deploy drain, Phase C) reads the omitted count as 0.
    dir=$(fleet_dir '{"arc": "arc-density"}' create-one-closed) || { fail "zero encoding occupancy: fixture could not be built"; return; }
    occupancy=$(with_fakes "$dir" python3 -B "${REPO_ROOT}/scripts/lib/fleet_occupancy.py" --cluster-name redducklabs-cluster 2> "$GATE_ERR")
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(jq -c '.burst_pool_counts' <<<"$occupancy" 2>/dev/null)" = "{\"${PRIMARY_POOL}\":0,\"${FALLBACK_POOL}\":null}" ]; then
        pass "zero encoding: fleet_occupancy reports count 0 for the omitted-zero primary and null for the absent fallback"
    else
        fail "zero encoding: fleet_occupancy exit ${rc}: ${occupancy} ($(head -c 300 "$GATE_ERR" | tr '\n' ' '))"
    fi
}


# run_usage <scenario> <now-epoch> <args...>: runs the CI usage report against
# the gh fake with test/fixtures/usage/<scenario>; JSON goes to USAGE_JSON.
# A fixture hook.py becomes the fake's stateful hook. SLEEP_CMD appends each
# requested wait to <dir>/sleeps instead of sleeping. USAGE_ENV adds one
# VAR=value assignment to the report's environment.
USAGE_OUT="${WORK_DIR}/usage.out"
USAGE_ERR="${WORK_DIR}/usage.err"
USAGE_JSON="${WORK_DIR}/usage.json"
USAGE_ENV="USAGE_UNUSED=1"
# Repository names in test/fixtures/usage; none may reach aggregate output.
USAGE_REPOS="zz-alpha-app zz-beta-site zz-gamma-tool zz-delta-old zz-epsilon-secret"
run_usage() {
    local scenario=$1 now=$2 dir
    shift 2
    dir=$(mktemp -d "${WORK_DIR}/usage.XXXXXX")
    cp -r "${FIXTURES}/usage/${scenario}/." "${dir}/"
    [ -f "${dir}/hook.py" ] && printf '%s' "${dir}/hook.py" > "${dir}/stateful"
    USAGE_DIR=$dir
    rm -f "$USAGE_JSON"
    with_fakes "$dir" env -u GITHUB_ACTIONS "NOW_CMD=echo ${now}" "SLEEP_CMD=sh -c 'printf \"%s\\n\" \"\$0\" >> ${dir}/sleeps'" "$USAGE_ENV" \
        bash "${REPO_ROOT}/scripts/ci-usage-report.sh" "$@" > "$USAGE_OUT" 2> "$USAGE_ERR"
}

# usage_json_check <label> <python assertions over `r`, the JSON report>
usage_json_check() {
    local label=$1 code=$2
    if python3 - "$USAGE_JSON" "$code" <<'PY'
import json
import sys

r = json.load(open(sys.argv[1], encoding="utf-8"))
exec(sys.argv[2])
PY
    then
        pass "usage report ${label}"
    else
        fail "usage report ${label} ($(head -c 300 "$USAGE_ERR" | tr '\n' ' '))"
    fi
}

# usage_names_hidden <label> <files...>: no fixture repository name in the files.
usage_names_hidden() {
    local label=$1 name
    shift
    for name in $USAGE_REPOS; do
        if grep -q -- "$name" "$@" 2>/dev/null; then
            fail "usage report ${label}: '${name}' appears in $(grep -l -- "$name" "$@" | xargs -n1 basename | tr '\n' ' ')"
            return
        fi
    done
    pass "usage report ${label}"
}

assert_ci_usage_report() {
    info "Checking the CI usage report against synthetic Actions fixtures..."
    local rc usage workflow="${REPO_ROOT}/.github/workflows/ci-usage-report.yml"
    # 2026-10-26T00:00:00Z and one hour later.
    local end_epoch=1792972800 later_epoch=1792976400

    if [ "$(git -C "$REPO_ROOT" ls-files -s scripts/ci-usage-report.sh | cut -c1-6)" = 100755 ]; then
        pass "scripts/ci-usage-report.sh is committed executable"
    else
        fail "scripts/ci-usage-report.sh is not committed with mode 100755"
    fi

    # main with --per-repo: run and job pagination, attempts, a re-run inside
    # the window of a run created 10 days before it, a carry-in fleet job, a
    # run updated before the window (jobs not read), an archived repository,
    # the 1000-result split with an overlapping run, fleet/hosted/other/not-run
    # classification, pricing, public free use and a running job.
    run_usage main "$later_epoch" --end 2026-10-26T00:00:00Z --per-repo --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$USAGE_JSON" ]; then
        pass "usage report main scenario exits 0 and writes JSON"
    else
        fail "usage report main scenario exit ${rc} ($(head -c 300 "$USAGE_ERR" | tr '\n' ' '))"
        return
    fi
    usage_json_check "reports the 7-day window ending at --end and reads every non-archived repository" '
assert r["window"]["start"] == "2026-10-19T00:00:00Z" and r["window"]["end"] == "2026-10-26T00:00:00Z", r["window"]
assert r["window"]["rerun_lookback_days"] == 37
assert r["complete"] and r["repositories_read"] == 3 and r["per_repository"], r
assert [row["repository"] for row in r["repositories"]] == ["zz-alpha-app", "zz-beta-site", "zz-gamma-tool"]'
    usage_json_check "counts fleet jobs of every attempt that started in the window, including a re-run of a 10-day-old run" '
app = r["repositories"][0]
assert app["fleet_jobs"] == 5 and abs(app["fleet_minutes"] - 79.5) < 1e-9, app
assert app["not_run_jobs"] == 1, app'
    usage_json_check "rounds each hosted job up to a whole minute and prices it by label" '
app, site, tool = r["repositories"]
assert app["hosted_jobs"] == 1 and app["hosted_billable_minutes"] == 2 and abs(app["hosted_cost_usd"] - 0.012) < 1e-9, app
assert tool["hosted_jobs"] == 3 and tool["hosted_billable_minutes"] == 19, tool
assert abs(tool["hosted_cost_usd"] - (10 * 0.010 + 4 * 0.062)) < 1e-9, tool
s = r["hosted_by_sku"]
assert set(s) == {"actions_linux", "actions_windows", "actions_macos"}, s
assert s["actions_linux"]["billable_minutes"] == 32 and s["actions_linux"]["private_billable_minutes"] == 2, s'
    usage_json_check "treats standard hosted minutes in a public repository as free" '
site = r["repositories"][1]
assert site["hosted_billable_minutes"] == 30 and site["public_free_billable_minutes"] == 30 and site["hosted_cost_usd"] == 0, site'
    usage_json_check "reports a hosted job with no standard-runner label as unpriced, not as zero" '
assert r["hosted_unpriced"] == {"jobs": 1, "minutes": 5}, r["hosted_unpriced"]
assert r["repositories"][2]["hosted_unpriced_minutes"] == 5'
    usage_json_check "classifies a non-fleet self-hosted runner as other" '
tool = r["repositories"][2]
assert tool["other_jobs"] == 1 and abs(tool["other_minutes"] - 20) < 1e-9, tool'
    usage_json_check "counts a running fleet job up to the report time and clips it to the window" '
tool = r["repositories"][2]
assert tool["fleet_jobs"] == 1 and abs(tool["fleet_minutes"] - 70) < 1e-9 and r["running_jobs"] == 1, tool'
    # Level 1: 10:00-10:10, 10:25-10:40 (back to back at 10:30), the re-run
    # (19.5 min), the running job clipped to 10 min and the carry-in job
    # clipped to its 30 in-window minutes; the job that ended before the
    # window contributes nothing.
    usage_json_check "computes concurrency on overlapping, back-to-back and carry-in fleet intervals clipped to the window" '
c = r["fleet_concurrency"]
assert c["window_seconds"] == 7 * 86400, c
assert c["minutes_by_level"] == {"0": 10080 - 99.5, "1": 84.5, "2": 10, "3": 5}, c["minutes_by_level"]
assert (c["p50"], c["p95"], c["max"]) == (0, 0, 3), c
assert c["minutes_at_or_above"] == {"4": 0, "16": 0, "20": 0}, c'
    usage_json_check "reports fleet queue wait percentiles (nearest rank) over jobs started in the window" '
q = r["fleet_queue_wait"]
assert q == {"jobs": 6, "p50_seconds": 30, "p95_seconds": 600, "max_seconds": 600}, q'
    usage_json_check "records the pricing source and retrieval date" '
p = r["pricing"]
assert p["source"] == "https://docs.github.com/en/billing/reference/actions-runner-pricing" and p["retrieved"] == "2026-10-29", p
assert p["usd_per_minute"]["actions_linux"] == 0.006'
    if [ "$(grep -c 'zz-gamma-tool/actions/runs/10/jobs' "${USAGE_DIR}/gh.calls")" -eq 1 ] \
        && grep -q 'zz-gamma-tool/actions/runs?created=2026-09-12T00:00:00Z..2026-10-04T00:00:00Z' "${USAGE_DIR}/gh.calls" \
        && grep -q 'zz-gamma-tool/actions/runs?created=2026-10-04T00:00:00Z..2026-10-26T00:00:00Z' "${USAGE_DIR}/gh.calls"; then
        pass "usage report bisects a created range over the 1000-result cap and reads an overlapping run once"
    else
        fail "usage report range split or deduplication is wrong ($(tr '\n' '|' < "${USAGE_DIR}/gh.calls" | head -c 600))"
    fi
    if grep -q 'zz-alpha-app/actions/runs?created=2026-09-12T00:00:00Z..2026-10-26T00:00:00Z' "${USAGE_DIR}/gh.calls"; then
        pass "usage report discovers runs from 37 days before the window (35-day run lifetime plus queueing margin)"
    else
        fail "usage report run discovery does not start 37 days before the window"
    fi
    if ! grep -Eq 'runs/3/jobs|repos/redducklabs/zz-delta-old/' "${USAGE_DIR}/gh.calls"; then
        pass "usage report skips completed runs updated before the window and archived repositories"
    else
        fail "usage report read a run updated before the window or an archived repository"
    fi
    if ! grep -qv '^api --paginate --slurp ' "${USAGE_DIR}/gh.calls"; then
        pass "usage report issues only paginated gh api GETs"
    else
        fail "usage report issued an unexpected gh call ($(grep -v '^api --paginate --slurp ' "${USAGE_DIR}/gh.calls" | head -3 | tr '\n' '|'))"
    fi
    if grep -q '^| `zz-alpha-app` | private | 5 | 79.5 | 1 | 1.0 | 2 | \$0.01 | 0.0 |$' "$USAGE_OUT" \
        && grep -q '^| `zz-beta-site` | public | 0 | 0.0 | 1 | 30.0 | 30 | \$0.00 (public: standard runners free) | 0.0 |$' "$USAGE_OUT" \
        && grep -q '^| \*\*Total\*\* | | 6 | 149.5 | 5 | 49.5 | 51 | \$0.36 + 5 unpriced min | 20.0 |$' "$USAGE_OUT" \
        && grep -q '^| max concurrent fleet jobs | 3 |$' "$USAGE_OUT" \
        && grep -q '^| fleet queue wait p95 | 600 s (10.0 min) |$' "$USAGE_OUT" \
        && ! grep -q 'INCOMPLETE' "$USAGE_OUT"; then
        pass "usage report --per-repo Markdown carries the per-repository, cost and concurrency tables"
    else
        fail "usage report --per-repo Markdown is wrong ($(head -c 900 "$USAGE_OUT" | tr '\n' '|'))"
    fi

    # Visibility boundary: without --per-repo (what the workflow runs), no
    # output, JSON or log line names a repository or attributes a number to one.
    run_usage main "$later_epoch" --end 2026-10-26T00:00:00Z --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^| Self-hosted fleet | 6 | 149.5 | n/a |$' "$USAGE_OUT" \
        && grep -q '^| GitHub-hosted | 5 | 49.5 | 51 |$' "$USAGE_OUT" \
        && grep -q '^| \*\*Total\*\* | | 5 | 51 | | \*\*\$0.36\*\* + 5 unpriced min |$' "$USAGE_OUT"; then
        pass "usage report aggregate Markdown carries organization totals and the cost table"
    else
        fail "usage report aggregate Markdown is wrong: exit ${rc} ($(head -c 900 "$USAGE_OUT" | tr '\n' '|'))"
    fi
    usage_names_hidden "aggregate stdout, stderr and JSON name no repository" "$USAGE_OUT" "$USAGE_ERR" "$USAGE_JSON"
    usage_json_check "aggregate JSON has no per-repository section" '
assert "repositories" not in r and "unreadable_repositories" not in r and r["per_repository"] is False, sorted(r)
assert r["totals"]["fleet_jobs"] == 6 and r["fleet_concurrency"]["max"] == 3'

    # A run created before the old 32-day cutoff, re-run 29.5 days later; its
    # fleet job runs 5 days and carries 12 hours into the window.
    run_usage long-carry-in "$end_epoch" --end 2026-10-26T00:00:00Z --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        usage_json_check "counts a fleet job of a run created 34 days before the window in concurrency only, complete" '
assert r["complete"], r
c = r["fleet_concurrency"]
assert c["minutes_by_level"] == {"0": 10080 - 720, "1": 720}, c["minutes_by_level"]
assert c["max"] == 1, c
assert r["totals"]["fleet_jobs"] == 0 and r["fleet_queue_wait"]["jobs"] == 0, (r["totals"], r["fleet_queue_wait"])'
    else
        fail "usage report long carry-in scenario exit ${rc} ($(head -c 300 "$USAGE_ERR" | tr '\n' ' '))"
    fi

    # saturated: concurrency 4 all day, 16 for 11 hours and 20 for one hour.
    run_usage saturated "$end_epoch" --days 1 --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        usage_json_check "computes time-weighted p50/p95/max and minutes at >= 4, >= 16 and >= 20" '
c = r["fleet_concurrency"]
assert c["minutes_by_level"] == {"4": 720, "16": 660, "20": 60}, c["minutes_by_level"]
assert (c["p50"], c["p95"], c["max"]) == (4, 16, 20), c
assert c["minutes_at_or_above"] == {"4": 1440, "16": 720, "20": 60}, c
q = r["fleet_queue_wait"]
assert q == {"jobs": 20, "p50_seconds": 90, "p95_seconds": 180, "max_seconds": 190}, q'
    else
        fail "usage report saturated scenario exit ${rc} ($(head -c 300 "$USAGE_ERR" | tr '\n' ' '))"
    fi

    # empty window: measured zeros and no queue-wait percentiles.
    run_usage empty "$end_epoch" --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^| fleet queue wait p50 | n/a (no fleet jobs) |$' "$USAGE_OUT" \
        && grep -q '^| max concurrent fleet jobs | 0 |$' "$USAGE_OUT"; then
        usage_json_check "handles an empty window" '
assert r["complete"] and r["totals"]["fleet_jobs"] == 0 and r["totals"]["hosted_jobs"] == 0, r["totals"]
assert r["fleet_concurrency"]["minutes_by_level"] == {"0": 10080}, r["fleet_concurrency"]
assert r["fleet_queue_wait"]["p50_seconds"] is None'
    else
        fail "usage report empty window exit ${rc} ($(head -c 400 "$USAGE_OUT" | tr '\n' '|'))"
    fi

    # An unreadable repository: retried, counted, INCOMPLETE, exit 1, unnamed.
    run_usage unreadable "$end_epoch" --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 1 ] && grep -q '^\*\*INCOMPLETE:\*\* 1 repositories could not be read' "$USAGE_OUT" \
        && [ "$(grep -c 'zz-epsilon-secret/actions/runs' "${USAGE_DIR}/gh.calls")" -eq 5 ] \
        && grep -q '^UNREADABLE: repository 2/2: a gh call failed (exit 1)$' "$USAGE_ERR"; then
        pass "usage report retries, then counts an unreadable repository INCOMPLETE and exits 1"
    else
        fail "usage report unreadable repository: exit ${rc} ($(head -c 400 "$USAGE_OUT" | tr '\n' '|') $(head -c 300 "$USAGE_ERR" | tr '\n' '|'))"
    fi
    usage_names_hidden "names no unreadable repository in aggregate output, logs or JSON" "$USAGE_OUT" "$USAGE_ERR" "$USAGE_JSON"
    if grep -q '^RETRY: attempt 4/5 failed: a gh call failed (exit 1); waiting 60 s$' "$USAGE_ERR"; then
        pass "usage report backs off 5, 15, 30 and 60 s across five attempts"
    else
        fail "usage report retry backoff is wrong ($(grep RETRY "$USAGE_ERR" | tr '\n' '|'))"
    fi
    run_usage unreadable "$end_epoch" --per-repo
    if grep -q '^- `zz-epsilon-secret`: ' "$USAGE_OUT"; then
        pass "usage report --per-repo names the unreadable repository"
    else
        fail "usage report --per-repo does not name the unreadable repository"
    fi

    # The 1000-result cap below the minimum slice fails that repository closed.
    run_usage capped "$end_epoch"
    rc=$?
    if [ "$rc" -eq 1 ] && grep -q 'more runs in one 3600 s slice than the 1000-result search limit' "$USAGE_ERR"; then
        pass "usage report fails closed when a minimum slice still exceeds the 1000-result cap"
    else
        fail "usage report capped range: exit ${rc} ($(head -c 400 "$USAGE_ERR" | tr '\n' '|'))"
    fi
    usage_names_hidden "names no repository when the cap cannot be split" "$USAGE_OUT" "$USAGE_ERR"

    run_usage no-org "$end_epoch"
    rc=$?
    if [ "$rc" -eq 1 ] && grep -q '^usage data unavailable: ' "$USAGE_OUT" && ! grep -q '|' "$USAGE_OUT"; then
        pass "usage report prints no tables when the organization's repositories cannot be listed"
    else
        fail "usage report without a repository list: exit ${rc} ($(head -c 300 "$USAGE_OUT" | tr '\n' '|'))"
    fi

    # Rate limits: the primary limit waits for its reset (x-ratelimit-reset via
    # GET rate_limit), a secondary limit waits a minute, a reset too far away
    # fails the repository; a hung call times out.
    run_usage rate-limited "$end_epoch" --days 1 --json "$USAGE_JSON"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "${USAGE_DIR}/sleeps" 2>/dev/null)" = 31 ] \
        && grep -q '^RETRY: attempt 1/5 failed: a gh call was rate limited; waiting 31 s$' "$USAGE_ERR" \
        && [ "$(grep -c '^api rate_limit$' "${USAGE_DIR}/gh.calls")" -eq 1 ]; then
        usage_json_check "waits for the primary rate limit's reset, then completes" '
assert r["complete"] and r["totals"]["fleet_jobs"] == 20, r["totals"]'
    else
        fail "usage report primary rate limit: exit ${rc}, sleeps '$(tr '\n' ' ' < "${USAGE_DIR}/sleeps" 2>/dev/null)' ($(head -c 300 "$USAGE_ERR" | tr '\n' '|'))"
    fi
    run_usage secondary-limited "$end_epoch" --days 1
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "${USAGE_DIR}/sleeps" 2>/dev/null)" = 60 ]; then
        pass "usage report waits one minute on a secondary rate limit"
    else
        fail "usage report secondary rate limit: exit ${rc}, sleeps '$(tr '\n' ' ' < "${USAGE_DIR}/sleeps" 2>/dev/null)'"
    fi
    run_usage rate-limit-too-long "$end_epoch" --days 1
    rc=$?
    if [ "$rc" -eq 1 ] && [ ! -s "${USAGE_DIR}/sleeps" ] && grep -q 'INCOMPLETE' "$USAGE_OUT" \
        && grep -q 'rate limited for more than 900 s' "$USAGE_ERR"; then
        pass "usage report fails a repository whose rate-limit reset exceeds the maximum wait"
    else
        fail "usage report long rate limit: exit ${rc} ($(head -c 300 "$USAGE_ERR" | tr '\n' '|'))"
    fi
    USAGE_ENV="GH_CALL_TIMEOUT_SECONDS=1"
    run_usage hung "$end_epoch" --days 1
    rc=$?
    USAGE_ENV="USAGE_UNUSED=1"
    if [ "$rc" -eq 1 ] && [ "$(grep -c 'a gh call timed out' "$USAGE_ERR")" -eq 5 ] && grep -q 'INCOMPLETE' "$USAGE_OUT"; then
        pass "usage report times out a hung gh call, retries it, then marks the report INCOMPLETE"
    else
        fail "usage report hung call: exit ${rc} ($(head -c 300 "$USAGE_ERR" | tr '\n' '|'))"
    fi

    for usage in "--days" "--days 0" "--days 32" "--days x" "--org bad_org!" "--end 2026-10-26" "--end 2026-10-27T00:00:00Z" \
        "--end 2026-99-26T00:00:00Z" "--end 2026-02-30T00:00:00Z" "--end 2026-10-26T25:00:00Z" "--json" "--extra 1"; do
        # shellcheck disable=SC2086 # usage is an argument list by design
        run_usage empty "$end_epoch" $usage
        rc=$?
        if [ "$rc" -eq 2 ] && [ ! -s "${USAGE_DIR}/gh.calls" ] && ! grep -q Traceback "$USAGE_ERR"; then
            pass "usage report rejects '${usage}' with exit 2 before any read"
        else
            fail "usage report exit ${rc} (expected 2, no reads) for '${usage}'"
        fi
    done
    USAGE_ENV="GITHUB_ACTIONS=true"
    run_usage empty "$end_epoch" --per-repo
    rc=$?
    USAGE_ENV="USAGE_UNUSED=1"
    if [ "$rc" -eq 2 ] && [ ! -s "${USAGE_DIR}/gh.calls" ] && grep -q 'refused in GitHub Actions' "$USAGE_ERR"; then
        pass "usage report refuses --per-repo when GITHUB_ACTIONS=true"
    else
        fail "usage report accepted --per-repo under GITHUB_ACTIONS=true (exit ${rc})"
    fi

    if ! grep -Eq -- '(-X|--method)[ =]|"(POST|PUT|PATCH|DELETE)"|--input' "${REPO_ROOT}/scripts/ci-usage-report.sh" "${REPO_ROOT}/scripts/lib/ci_usage_report.py"; then
        pass "usage report contains no mutating gh api call"
    else
        fail "usage report contains a mutating gh api call"
    fi

    if python3 - "$workflow" <<'PY'
import re
import sys

import yaml

text = open(sys.argv[1], encoding="utf-8").read()
workflow = yaml.safe_load(text)
triggers = workflow[True]  # PyYAML reads the bare key `on` as True
assert set(triggers) == {"schedule", "workflow_dispatch"}, triggers
assert triggers["schedule"] == [{"cron": "0 8 * * 1"}], triggers["schedule"]
assert workflow["permissions"] == {"contents": "read"}, workflow["permissions"]
job = workflow["jobs"]["report"]
assert job["runs-on"] == "ubuntu-latest" and job["defaults"] == {"run": {"shell": "bash"}}
steps = {step.get("name"): step for step in job["steps"]}
build = steps["Build usage report"]
assert build["env"]["GH_TOKEN"] == "${{ secrets.RUNNER_TOKEN }}"
assert "./scripts/ci-usage-report.sh" in build["run"] and "--json" in build["run"]
assert "--per-repo" not in text, "the public workflow must never request per-repository output"
assert "GITHUB_STEP_SUMMARY" in steps["Write job summary"]["run"]
assert steps["Upload report"]["uses"].startswith("actions/upload-artifact@")
assert "${{ inputs." not in "".join(step.get("run", "") for step in job["steps"]), "inputs interpolated into a run block"
assert not re.search(r"\b(kubectl|helm|doctl)\b|gh (run|workflow|pr|issue|release|secret|variable) |--method|-X ", text)
PY
    then
        pass "CI Usage Report workflow is weekly + manual, contents: read, aggregate only, RUNNER_TOKEN only for the report, no mutations"
    else
        fail "CI Usage Report workflow contract is wrong"
    fi
}


assert_with_fakes_selftest
assert_burst_contracts
assert_generated_drain_values
assert_arc_identity_library
assert_pool_state_scenarios
assert_pool_state_admission_table
assert_pool_state_snapshot
assert_pool_state_transitions
assert_pool_state_usage
assert_retirement
assert_burst_pools
assert_node_pool_workflow
assert_gate_request_shapes
assert_fleet_workflow_contracts
assert_deploy_ops
assert_phase_c
assert_rebalance_workflow
assert_emergency_stop
assert_stop_fence
assert_server_fence
assert_helm_history_max
assert_ci_lint_coverage
assert_admission_docs_name_no_collaborator
assert_operator_docs_current
assert_cost_report
assert_ci_usage_report
assert_status_workflow
assert_doctl_zero_encoding
assert_network_policy

echo ""
if [ "$FAILURES" -eq 0 ]; then
    pass "All burst autoscaling checks passed"
else
    echo -e "${RED}❌ ${FAILURES} burst autoscaling check(s) failed${NC}"
    exit 1
fi
