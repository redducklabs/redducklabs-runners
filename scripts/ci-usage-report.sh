#!/bin/bash
# GitHub Actions job usage across the organization's repositories, for tuning
# the runner fleet's burst ceiling (maxRunners) and warm floor (minRunners).
#
# Usage: ci-usage-report.sh [--org ORG] [--days N] [--end YYYY-MM-DDTHH:MM:SSZ] [--json PATH]
#
# Reports, for the N days (default 7, at most 31) before --end (default now):
# fleet vs GitHub-hosted job-minutes per repository, the estimated hosted cost
# at GitHub's published per-minute prices (source and date recorded in
# scripts/lib/ci_usage_report.py), the time-weighted concurrency profile of
# fleet jobs and the fleet queue wait. Markdown goes to stdout; --json also
# writes the full report as JSON to PATH.
#
# Read-only: only `gh api` GETs (organization repositories, workflow runs,
# jobs of every attempt). gh must be authenticated with a token that can read
# Actions runs of the organization's private repositories. Exit 0 on a complete
# report, 1 when any read failed (the report is then marked INCOMPLETE), 2 on
# a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/lib/ci_usage_report.py" "$@"
