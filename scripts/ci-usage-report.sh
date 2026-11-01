#!/bin/bash
# GitHub Actions job usage across the organization's repositories, for tuning
# the runner fleet's burst ceiling (maxRunners) and warm floor (minRunners).
#
# Usage: ci-usage-report.sh [--org ORG] [--days N] [--end YYYY-MM-DDTHH:MM:SSZ] [--json PATH] [--per-repo]
#
# Reports, for the N days (default 7, at most 31) before --end (default now):
# fleet vs GitHub-hosted job-minutes, the estimated hosted cost
# at GitHub's published per-minute prices (source and date recorded in
# scripts/lib/ci_usage_report.py), the time-weighted concurrency profile of
# fleet jobs and the fleet queue wait. Markdown goes to stdout; --json also
# writes the full report as JSON to PATH.
#
# Output is organization totals only, naming no repository, because this
# repository (and its Actions logs and artifacts) is public. --per-repo adds
# the per-repository breakdown for an operator's own terminal; it is refused
# when GITHUB_ACTIONS=true.
#
# Read-only: only `gh api` GETs (organization repositories, workflow runs,
# jobs of every attempt). gh must be authenticated with a token that can read
# Actions runs of the organization's private repositories. Exit 0 on a complete
# report, 1 when any read failed (the report is then marked INCOMPLETE), 2 on
# a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/lib/ci_usage_report.py" "$@"
