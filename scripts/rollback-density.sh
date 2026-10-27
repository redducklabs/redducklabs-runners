#!/bin/bash
# Deploy `rollback` and Scale Runners `record-density`: the committed density
# release (docs/specs/2026-10-26-runner-burst-autoscaling-design.md, "Rollback"
# and Ruling 34). The rollback target is deploy/density-values.yaml, the
# reviewed values of the pre-burst release, not a Helm history revision, so it
# cannot be pruned by --history-max.
#
# Usage (from the repository root):
#   RUNNER_TOKEN=<token> [CLUSTER_NAME=<cluster>] \
#     rollback-density.sh --identities FILE [--acknowledge-emergency-stop]
#   RUNNER_TOKEN=<token> [CLUSTER_NAME=<cluster>] rollback-density.sh --verify-live
#
# Rollback (FILE is the snapshot written by "verify-runner-pool-state.sh
# --operation rollback --emit-identities" in the calling workflow):
#   1. re-check ARC release identity and classify the live ARC state;
#   2. unless it is already `density`, validate deploy/density-values.yaml as
#      the density contract, render it with the production overlays and
#      validate the manifest as density 2/4;
#   3. with --acknowledge-emergency-stop, delete the Emergency Stop marker
#      inside the identity bracket (Ruling 33; a no-op when there is none);
#   4. unless already `density`: "helm upgrade" with exactly that file behind a
#      manifest-hash post-renderer, --history-max 100, inside the identity
#      bracket (compare none, re-admit `rollback`, the upgrade, the Emergency
#      Stop fence, compare arc:density:2/4);
#   5. read back density 2/4 from Helm values, manifest and the live
#      AutoscalingRunnerSet.
#
# --verify-live is read-only: the live release must be density 2/4 and its
# manifest (Secret payloads removed) must equal the render of
# deploy/density-values.yaml.
#
# Exit codes: 0 success, 1 failure, 2 usage error, 3 identity drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fleet-ops.sh
source "${SCRIPT_DIR}/lib/fleet-ops.sh"
# shellcheck source=lib/arc-identity.sh
source "${SCRIPT_DIR}/lib/arc-identity.sh"

CLUSTER_NAME="${CLUSTER_NAME:-redducklabs-cluster}"
IDENTITIES=""
ACKNOWLEDGE=false
VERIFY_LIVE=false

usage() {
    echo "ERROR: $1" >&2
    echo "usage: $0 --identities FILE [--acknowledge-emergency-stop]" >&2
    echo "       $0 --verify-live" >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --identities)
            [ $# -ge 2 ] || usage "--identities requires a file"
            IDENTITIES=$2
            shift 2
            ;;
        --acknowledge-emergency-stop) ACKNOWLEDGE=true; shift ;;
        --verify-live) VERIFY_LIVE=true; shift ;;
        *) usage "unknown argument '$1'" ;;
    esac
done
if [ "$VERIFY_LIVE" = true ]; then
    [ -z "$IDENTITIES" ] && [ "$ACKNOWLEDGE" = false ] || usage "--verify-live takes no other argument"
else
    [ -n "$IDENTITIES" ] || usage "--identities is required"
    if [ ! -f "$IDENTITIES" ]; then
        echo "ERROR: identity snapshot ${IDENTITIES} does not exist; nothing was changed" >&2
        exit 1
    fi
fi
export CLUSTER_NAME

WORK=$(umask 077 && mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/density.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

if ! verify_arc_identity; then
    echo "ERROR: ARC release or controller identity check failed; nothing was changed" >&2
    exit 1
fi

if [ "$VERIFY_LIVE" = true ]; then
    fleet_render_density "$WORK" || exit 1
    if ! fleet_readback density 2 4; then
        exit 1
    fi
    if ! RENDERED=$(python3 "${SCRIPT_DIR}/lib/runner_pool_state.py" manifest-digest < "${WORK}/density-candidate.yaml") \
        || ! LIVE=$(helm get manifest "$FLEET_RELEASE" -n "$FLEET_NAMESPACE" \
            | python3 "${SCRIPT_DIR}/lib/runner_pool_state.py" manifest-digest); then
        echo "ERROR: could not digest the rendered or the live manifest" >&2
        exit 1
    fi
    if [ "$RENDERED" != "$LIVE" ]; then
        echo "ERROR: the live release manifest differs from the render of ${FLEET_DENSITY_VALUES} (Secret payloads excluded); it is not the committed density release" >&2
        exit 1
    fi
    echo "DENSITY_RELEASE: the live release is density 2/4 and equals the render of ${FLEET_DENSITY_VALUES}"
    exit 0
fi

if ! STATE=$(fleet_current_state); then
    exit 1
fi

case "$STATE" in
    density:2/4) ;;
    drain:2/4 | drain-stopped:0/0 | density-stopped:0/0)
        echo "PLAN: helm upgrade ${FLEET_RELEASE} from ${STATE} to ${FLEET_DENSITY_VALUES} (density 2/4)"
        fleet_render_density "$WORK" || exit 1
        EXPECTED_HASH=$(sha256sum "${WORK}/density-candidate.yaml" | awk '{print $1}')
        cat > "${WORK}/hash-gate.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
INPUT=\$(mktemp "${WORK}/postrender.XXXXXX")
trap 'rm -f "\${INPUT}"' EXIT
cat > "\${INPUT}"
ACTUAL=\$(sha256sum "\${INPUT}" | awk '{print \$1}')
if [ "\${ACTUAL}" != "${EXPECTED_HASH}" ]; then
    echo "ERROR: density manifest hash mismatch: expected ${EXPECTED_HASH}, got \${ACTUAL}" >&2
    exit 1
fi
cat "\${INPUT}"
SH
        chmod 0700 "${WORK}/hash-gate.sh"
        ;;
    *)
        echo "ERROR: rollback does not start from ARC state ${STATE}; nothing was changed" >&2
        exit 1
        ;;
esac

if [ "$ACKNOWLEDGE" = true ]; then
    fleet_acknowledge_stop "$IDENTITIES" rollback
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
fi

if [ "$STATE" = density:2/4 ]; then
    # The re-run is a verified no-op, but not while an Emergency Stop is in
    # effect that this run did not acknowledge.
    fleet_refuse_if_stopped || exit 1
    fleet_readback density 2 4 || exit 1
    echo "NOOP: ARC is already density 2/4 with no burst pools; rollback is a no-op"
    exit 0
fi

mapfile -t OVERLAYS < <(fleet_density_overlays "$FLEET_DENSITY_VALUES" "$RUNNER_TOKEN")
fleet_helm_bracket "$IDENTITIES" rollback none arc:density:2/4 \
    upgrade "$FLEET_RELEASE" "$FLEET_CHART" "${OVERLAYS[@]}" \
    --post-renderer "${WORK}/hash-gate.sh" --history-max 100 --wait --timeout 300s
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if ! fleet_readback density 2 4; then
    exit 1
fi
echo "READBACK: ARC is density 2/4 from ${FLEET_DENSITY_VALUES}"
