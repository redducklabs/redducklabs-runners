#!/bin/bash
# Runner cost for one month and one cluster, measured from the DigitalOcean invoice.
#
# Usage: runner-cost-report.sh --month YYYY-MM [--cluster-name NAME]
#
# DigitalOcean bills DOKS nodes per cluster and node size, not per pool. For a
# completed month the report sums the cluster's "Kubernetes Clusters" node lines
# (16 GB / 8 vCPU = runner nodes, 8 GB / 4 vCPU = workers, reported separately)
# and derives burst node-hours as runner node-hours minus two baseline nodes for
# the whole period. For the month in progress, which DigitalOcean does not
# itemize, it prints the account-wide month-to-date usage from `doctl balance
# get`. Missing or unparseable data prints "cost data unavailable: <reason>" and
# exits 0; it never prints a zero for missing data. Read-only: only `doctl
# invoice list|get` and `doctl balance get` are run. Exit 2 is a usage error.
# See docs/specs/2026-10-26-runner-burst-autoscaling-design.md, "Cost model".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/lib/runner_cost_report.py" "$@"
