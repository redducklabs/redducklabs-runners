#!/bin/bash
# Runner network policy-set validation (read-only).
#
# Implements the policy-set rules of "Runner network isolation" in
# docs/specs/2026-10-26-runner-burst-autoscaling-design.md:
#   - exactly one NetworkPolicy in arc-runners, redducklabs-runner-isolation,
#     whose spec equals deploy/runner-network-policy.yaml;
#   - zero CiliumNetworkPolicies in arc-runners;
#   - every CiliumClusterwideNetworkPolicy deny-only;
#   - a missing Cilium CRD counts as zero objects, any other API error fails;
#   - no pod in arc-runners labeled doks.digitalocean.com/allow-imds-egress=true;
#   - every runner pod in arc-runners carries the selector label
#     actions.github.com/scale-set-name=redducklabs-runners.
#
# Deploy `deploy` runs it after applying the policy and before the Helm
# upgrade; the pool-state gate runs it on admission for enable-burst,
# rebalance and acceptance-phase-c.
#
# Usage: verify-runner-network-policy.sh [--policy-file FILE]
# Exit codes: 0 valid, 1 invalid or a read failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "${SCRIPT_DIR}/lib/runner_network_policy.py" "$@"
