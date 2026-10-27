#!/bin/bash
# Read-only per-pool node counts, bounds and expander readback.
#
# Usage: report-runner-pools.sh --cluster-name NAME
#
# Prints one line per runner pool (the baseline and both burst pools):
#   POOL <name> provider_count=<n> min=<n> max=<n> auto_scale=<bool> registered=<n> ready=<n>
#   POOL <name> absent
# followed by one EXPANDER line: "EXPANDER ok: ...", "EXPANDER n/a: ..." or an
# "EXPANDER drift: ..." line per problem, using the same expander check the
# pool-state gate applies. Drift is reported, not rejected: admission is the
# gate's job (verify-runner-pool-state.sh). Never mutates anything. It does not
# report node-hours; use runner-cost-report.sh for cost.
# Exit codes: 0 reported, 1 a read failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 2 ] || [ "$1" != "--cluster-name" ]; then
    echo "usage: $0 --cluster-name NAME" >&2
    exit 2
fi

exec python3 "${SCRIPT_DIR}/lib/runner_pool_state.py" report --cluster-name "$2"
