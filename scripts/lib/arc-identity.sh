#!/bin/bash
# shellcheck shell=bash
#
# ARC release and controller identity check, shared by the pool-state gate
# (scripts/verify-runner-pool-state.sh) and every script that deletes
# EphemeralRunners. Source this file, then call verify_arc_identity.
#
# Semantics are those of the prepared-platform prerequisite check in
# .github/workflows/deploy-runners.yml, plus the scale-set release identity
# from the burst design's global constraints:
#   - exactly one release named redducklabs-runners in arc-runners, chart
#     gha-runner-scale-set-0.14.2, status deployed, and no other scale-set
#     release in that namespace;
#   - exactly one release named arc in arc-systems, chart
#     gha-runner-scale-set-controller-0.14.2, status deployed;
#   - exactly one controller Deployment (app.kubernetes.io/name=gha-rs-controller)
#     with observedGeneration == generation and
#     readyReplicas == availableReplicas == replicas >= 1.
#
# Releases are listed with --all so a pending-* or failed release is seen and
# rejected by its status rather than silently hidden by Helm's default filter.
#
# verify_arc_identity returns 0 when every check holds; otherwise it prints one
# "ERROR: ..." reason per failed check on stderr and returns 1. It reads
# release metadata and Deployment status only; it never reads values or
# Secrets.

ARC_IDENTITY_CHART_VERSION="0.14.2"
ARC_IDENTITY_RUNNER_NAMESPACE="arc-runners"
ARC_IDENTITY_RUNNER_RELEASE="redducklabs-runners"
ARC_IDENTITY_CONTROLLER_NAMESPACE="arc-systems"
ARC_IDENTITY_CONTROLLER_RELEASE="arc"

# _arc_identity_release <namespace> <release> <chart> <label>
_arc_identity_release() {
    local namespace=$1 release=$2 chart=$3 label=$4 releases reason
    if ! releases=$(helm list -n "$namespace" -a -o json); then
        echo "ERROR: could not list Helm releases in ${namespace}" >&2
        return 1
    fi
    if ! reason=$(jq -r --arg name "$release" --arg chart "$chart" '
        if type != "array" then "Helm release list is not a JSON array"
        else
          [.[] | select(.name == $name)] as $matches
          | if ($matches | length) != 1 then
              "expected exactly one release named \($name), found \($matches | length)"
            elif $matches[0].chart != $chart then
              "release \($name) is chart \($matches[0].chart), expected \($chart)"
            elif $matches[0].status != "deployed" then
              "release \($name) has status '\''\($matches[0].status)'\'', expected deployed"
            else "" end
        end
    ' <<<"$releases"); then
        echo "ERROR: could not parse the Helm release list in ${namespace}" >&2
        return 1
    fi
    if [ -n "$reason" ]; then
        echo "ERROR: ${label}: ${reason}" >&2
        return 1
    fi
    if [ "$namespace" = "$ARC_IDENTITY_RUNNER_NAMESPACE" ] && ! jq -e --arg name "$release" '
        [.[] | select(.name != $name
          and ((.chart // "") | test("^gha-runner-scale-set-[0-9]")))] | length == 0
    ' <<<"$releases" >/dev/null; then
        echo "ERROR: ${label}: another scale-set release exists in ${namespace}" >&2
        return 1
    fi
}

verify_arc_identity() {
    local status=0 controller
    _arc_identity_release "$ARC_IDENTITY_RUNNER_NAMESPACE" "$ARC_IDENTITY_RUNNER_RELEASE" \
        "gha-runner-scale-set-${ARC_IDENTITY_CHART_VERSION}" "runner scale-set release" || status=1
    _arc_identity_release "$ARC_IDENTITY_CONTROLLER_NAMESPACE" "$ARC_IDENTITY_CONTROLLER_RELEASE" \
        "gha-runner-scale-set-controller-${ARC_IDENTITY_CHART_VERSION}" "ARC controller release" || status=1

    if ! controller=$(kubectl get deployment -n "$ARC_IDENTITY_CONTROLLER_NAMESPACE" \
        -l app.kubernetes.io/name=gha-rs-controller -o json); then
        echo "ERROR: could not read the ARC controller Deployment" >&2
        return 1
    fi
    if ! jq -e '
        .items | length == 1
        and .[0].status.observedGeneration == .[0].metadata.generation
    ' <<<"$controller" >/dev/null 2>&1; then
        echo "ERROR: ARC controller Deployment is missing, ambiguous, or stale (observedGeneration != generation)" >&2
        status=1
    elif ! jq -e '
        .items[0]
        | (.spec.replicas // 1) > 0
        and (.status.readyReplicas // 0) == (.spec.replicas // 1)
        and (.status.availableReplicas // 0) == (.spec.replicas // 1)
    ' <<<"$controller" >/dev/null 2>&1; then
        echo "ERROR: ARC controller Deployment is not fully Ready (ready/available replicas != replicas >= 1)" >&2
        status=1
    fi
    return "$status"
}
