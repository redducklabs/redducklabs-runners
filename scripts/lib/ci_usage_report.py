#!/usr/bin/env python3
"""GitHub Actions job usage across the organization's repositories (read-only).

Invoked through scripts/ci-usage-report.sh. Answers, for one window (default:
the 7 days before now):
  1. job-minutes on the self-hosted fleet (the redducklabs-runners scale set)
     against GitHub-hosted runners;
  2. the estimated GitHub-hosted cost at GitHub's published per-minute prices
     (HOSTED_PRICES below, with source and retrieval date);
  3. the fleet concurrency profile (time-weighted distribution of concurrent
     fleet jobs; minutes at >= 4, >= 16 and >= 20) and the fleet queue wait
     (started_at - created_at), which tune ARC maxRunners (the 20-runner
     ceiling) and minRunners (the warm floor).

Visibility boundary. This repository is public, and anyone who can read it can
read its Actions logs, job summaries and artifacts. By default every output
(stdout, the --json file, stderr progress, retry and error messages) is
aggregate and non-identifying: it never names a repository or attributes a
number to one. --per-repo adds the per-repository breakdown and names
unreadable repositories; it is for an operator's own terminal and is refused
when GITHUB_ACTIONS=true.

Data comes only from read-only REST calls through `gh api`:
  - GET orgs/{org}/repos (archived repositories are skipped);
  - GET repos/{org}/{repo}/actions/runs?created=A..B, bisected while a range's
    total_count exceeds the 1000-result search cap, as
    scripts/acceptance-evidence.py does (bounded ranges overlap at their
    endpoints, so runs are deduplicated by ID);
  - GET repos/{org}/{repo}/actions/runs/{id}/jobs?filter=all, i.e. the jobs of
    every attempt, paginated;
  - GET rate_limit, only after a rate-limited response (it is not counted
    against the limit).
Every call has a timeout (GH_CALL_TIMEOUT_SECONDS) and is retried; a
rate-limited response waits for the primary limit's reset time, or one minute
for a secondary limit, and fails the read if that wait exceeds
RATE_LIMIT_MAX_WAIT_SECONDS.

Run discovery. A re-run keeps its run's original created_at. GitHub allows
re-runs up to 30 days after the initial run, a self-hosted job may then run
for up to 5 days, and a workflow run lives at most 35 days, so a job that
overlaps the window belongs to a run created at most 35 days before the
window starts. Runs are listed from RERUN_LOOKBACK_DAYS (35 days plus one day
for a job to queue and one day of margin) before the window. A completed run
last updated before the window is skipped without reading its jobs.

Selection. Job counts, minutes, cost and queue wait use the jobs that started
in the window. The concurrency profile uses every fleet job whose interval
overlaps the window (including jobs started before it), clipped to the window;
a job still running ends at the report time.

Classification, per job that ran (a job with no runner_name was skipped or
cancelled before pickup and has no minutes):
  - fleet: runner_name starts with "redducklabs-runners-" (ARC names runners
    "<scale set>-<id>-runner-<id>");
  - hosted: runner_group_name "GitHub Actions" or runner_name "GitHub Actions N";
    priced from its labels (HOSTED_LABEL_SKUS); a hosted job whose labels name
    no known standard runner is reported as unpriced, never at $0;
  - other: any other self-hosted runner.
Hosted cost rounds each job up to a whole minute, as GitHub bills. Standard
hosted runners are free in public repositories, so their minutes are reported
separately and excluded from the estimate. Included plan usage is not
subtracted: the figure is list price.

Exit 0 on a complete report; 1 when data is missing (the organization's
repositories cannot be listed, or any repository's runs or jobs cannot be
read: the report is then printed marked INCOMPLETE and its numbers are lower
bounds); 2 on a usage error.
"""

import json
import math
import os
import re
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

DEFAULT_ORG = "redducklabs"
DEFAULT_DAYS = 7
MAX_DAYS = 31
ORG_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
TIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
FLEET_RUNNER_PREFIX = "redducklabs-runners-"
HOSTED_GROUP = "GitHub Actions"
RUN_LIST_CAP = 1000
RUN_MIN_SLICE_SECONDS = 3600
# 35-day workflow-run lifetime (a re-run up to 30 days after creation, then
# up to 5 days of self-hosted job execution), plus one day for a job to queue
# (GitHub fails a job still queued after 24 hours) and one day of margin.
RERUN_LOOKBACK_DAYS = 37
READ_ATTEMPTS = 3
READ_BACKOFF_SECONDS = (5, 15)
JOB_READ_WORKERS = 6
GH_CALL_TIMEOUT_SECONDS = 120
RATE_LIMIT_MAX_WAIT_SECONDS = 900
SECONDARY_RATE_LIMIT_WAIT_SECONDS = 60
RATE_LIMITED = re.compile(r"rate limit|HTTP 429|secondary rate", re.IGNORECASE)
# Fleet thresholds: the baseline's two nodes run 4 jobs; ARC maxRunners is 20.
CONCURRENCY_THRESHOLDS = (4, 16, 20)

# GitHub-hosted per-minute list prices, USD.
# Source: https://docs.github.com/en/billing/reference/actions-runner-pricing
# ("Standard GitHub-hosted runners" and macOS larger runners), retrieved
# 2026-10-29. Free use of standard runners in public repositories:
# https://docs.github.com/en/billing/concepts/product-billing/github-actions
# (retrieved 2026-10-29). Update both the prices and the date together.
PRICING_SOURCE = "https://docs.github.com/en/billing/reference/actions-runner-pricing"
PRICING_RETRIEVED = "2026-10-29"
HOSTED_PRICES = {
    "actions_linux_slim": ("Linux 1-core (x64)", 0.002),
    "actions_linux": ("Linux 2-core (x64)", 0.006),
    "actions_linux_arm": ("Linux 2-core (arm64)", 0.005),
    "actions_windows": ("Windows 2-core (x64)", 0.010),
    "actions_windows_arm": ("Windows 2-core (arm64)", 0.010),
    "actions_macos": ("macOS 3-core or 4-core", 0.062),
    "macos_l": ("macOS 12-core (large)", 0.077),
    "macos_xl": ("macOS 5-core M2 Pro (xlarge)", 0.102),
}
# Larger runners are not free in public repositories (same source). The macOS
# ones have fixed labels and are priced; the Linux and Windows ones are named
# by custom labels, so their jobs match no pattern below and are unpriced.
LARGER_SKUS = ("macos_l", "macos_xl")
HOSTED_LABEL_SKUS = (
    (re.compile(r"^ubuntu-slim$"), "actions_linux_slim"),
    (re.compile(r"^ubuntu-(?:latest|\d{2}\.\d{2})-arm$"), "actions_linux_arm"),
    (re.compile(r"^ubuntu-(?:latest|\d{2}\.\d{2})$"), "actions_linux"),
    (re.compile(r"^windows-(?:latest|\d{2})-arm$"), "actions_windows_arm"),
    (re.compile(r"^windows-(?:latest|\d{4})$"), "actions_windows"),
    (re.compile(r"^macos-(?:latest|\d{2})-xlarge$"), "macos_xl"),
    (re.compile(r"^macos-(?:latest|\d{2})-large$"), "macos_l"),
    (re.compile(r"^macos-(?:latest|\d{2})(?:-intel)?$"), "actions_macos"),
)
USAGE = ("usage: ci-usage-report.sh [--org ORG] [--days N] [--end YYYY-MM-DDTHH:MM:SSZ] [--json PATH] [--per-repo]\n"
         "--per-repo names repositories; it is refused when GITHUB_ACTIONS=true")

# Set by main(): whether diagnostics may name repositories (--per-repo).
NAME_REPOSITORIES = False


class ReadError(Exception):
    """A read the report depends on failed or returned something unexpected.

    str() may name a repository; public() is the non-identifying form."""

    def __init__(self, message, public="a read failed", rate_limited=False):
        super().__init__(message)
        self.public_message = public
        self.rate_limited = rate_limited

    def public(self):
        return str(self) if NAME_REPOSITORIES else self.public_message


def log(message):
    print(message, file=sys.stderr, flush=True)


# --- process helpers (the read pattern of scripts/acceptance-evidence.py) ----


def call_timeout():
    value = os.environ.get("GH_CALL_TIMEOUT_SECONDS", "")
    return int(value) if value.isdigit() and int(value) > 0 else GH_CALL_TIMEOUT_SECONDS


def run_once(argv, timeout=None):
    what = " ".join(argv[:5])
    try:
        completed = subprocess.run(argv, capture_output=True, check=False, timeout=timeout or call_timeout())
    except subprocess.TimeoutExpired as error:
        raise ReadError(f"'{what}' timed out", "a gh call timed out") from error
    except OSError as error:
        raise ReadError(f"could not run {argv[0]}: {error.strerror}", f"could not run {argv[0]}") from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip().splitlines()
        limited = any(RATE_LIMITED.search(line) for line in detail)
        raise ReadError(f"'{what}' failed (exit {completed.returncode})" + (f": {detail[0][:200]}" if detail else ""),
                        "a gh call was rate limited" if limited else f"a gh call failed (exit {completed.returncode})",
                        rate_limited=limited)
    # gh prints UTF-8 (job and workflow names may hold any character), whatever
    # the locale; decoding with the locale default (cp1252 on Windows) fails.
    try:
        return completed.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReadError(f"'{what}' did not print UTF-8", "a gh call did not print UTF-8") from error


def sleep(seconds):
    run_once(shlex.split(os.environ.get("SLEEP_CMD") or "sleep") + [str(seconds)], timeout=seconds + 60)


def now():
    text = run_once(shlex.split(os.environ.get("NOW_CMD") or "date +%s")).strip()
    if not text.isdigit():
        raise ReadError("NOW_CMD did not print an integer epoch", "NOW_CMD did not print an integer epoch")
    return int(text)


def rate_limit_wait():
    """Seconds to wait after a rate-limited response.

    The primary limit's reset time comes from GET rate_limit (the
    x-ratelimit-reset value; the call does not count against the limit). If
    the primary limit is not exhausted, the response was a secondary limit,
    for which GitHub says to wait at least one minute."""
    try:
        core = json.loads(run_once(["gh", "api", "rate_limit"])).get("resources", {}).get("core", {})
        remaining, reset = int(core.get("remaining")), int(core.get("reset"))
    except (ReadError, ValueError, TypeError, AttributeError) as error:
        raise ReadError("rate limited, and the rate limit could not be read",
                        "rate limited, and the rate limit could not be read") from error
    wait = max(1, reset - now() + 1) if remaining == 0 else SECONDARY_RATE_LIMIT_WAIT_SECONDS
    if wait > RATE_LIMIT_MAX_WAIT_SECONDS:
        raise ReadError(f"rate limited until {iso(reset)}, more than {RATE_LIMIT_MAX_WAIT_SECONDS} s away",
                        f"rate limited for more than {RATE_LIMIT_MAX_WAIT_SECONDS} s")
    return wait


def run(argv):
    """A read-only call, retried on failure (READ_ATTEMPTS; backoff, or the
    rate-limit wait, between attempts)."""
    for attempt in range(1, READ_ATTEMPTS + 1):
        try:
            return run_once(argv)
        except ReadError as error:
            if attempt == READ_ATTEMPTS:
                raise
            wait = rate_limit_wait() if error.rate_limited else READ_BACKOFF_SECONDS[attempt - 1]
            log(f"RETRY: attempt {attempt}/{READ_ATTEMPTS} failed: {error.public()}; waiting {wait} s")
            sleep(wait)
    raise AssertionError("unreachable")


def gh_pages(path, what):
    """Every page of a paginated GET, as a list of JSON pages. `what` names the
    read in errors that may name a repository."""
    text = run(["gh", "api", "--paginate", "--slurp", path])
    try:
        pages = json.loads(text)
    except json.JSONDecodeError as error:
        raise ReadError(f"{what} did not return JSON", "a read did not return JSON") from error
    if not isinstance(pages, list):
        raise ReadError(f"{what} is not a list of pages", "a read is not a list of pages")
    return pages


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_of(value):
    """A GitHub timestamp as an integer epoch, or None if absent or unparseable."""
    if not isinstance(value, str):
        return None
    match = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", value)
    if not match:
        return None
    try:
        parsed = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return int(parsed.replace(tzinfo=timezone.utc).timestamp())


# --- reads -------------------------------------------------------------------


def org_repositories(org):
    repos = []
    for page in gh_pages(f"orgs/{org}/repos?type=all&per_page=100", f"repository list of {org}"):
        if not isinstance(page, list):
            raise ReadError(f"repository list of {org} is not a list", "the repository list is not a list")
        for repo in page:
            if not isinstance(repo, dict) or not isinstance(repo.get("name"), str):
                raise ReadError(f"repository list of {org} has an entry without a name",
                                "the repository list has an entry without a name")
            if repo.get("archived"):
                continue
            repos.append({"name": repo["name"], "private": repo.get("visibility") != "public"})
    return sorted(repos, key=lambda repo: repo["name"].lower())


def runs_created_between(org, repo, start, end):
    """Workflow runs of org/repo created in [start, end] (epochs), complete.

    The list endpoint returns at most RUN_LIST_CAP results for a search with
    the created filter, so a range whose total_count exceeds it is bisected
    (bounded ranges overlap at their endpoints; callers deduplicate by ID)."""
    pages = gh_pages(f"repos/{org}/{repo}/actions/runs?created={iso(start)}..{iso(end)}&per_page=100",
                     f"workflow run list of {org}/{repo}")
    if not all(isinstance(page, dict) for page in pages):
        raise ReadError(f"workflow run list of {org}/{repo} is not a list of pages",
                        "a workflow run list is not a list of pages")
    total = max((page.get("total_count") or 0 for page in pages), default=0)
    if total > RUN_LIST_CAP:
        if end - start <= RUN_MIN_SLICE_SECONDS:
            raise ReadError(f"{org}/{repo} has {total} runs created in {iso(start)}..{iso(end)}, "
                            f"more than the {RUN_LIST_CAP}-result search limit",
                            f"a repository has more runs in one {RUN_MIN_SLICE_SECONDS} s slice "
                            f"than the {RUN_LIST_CAP}-result search limit")
        middle = start + (end - start) // 2
        return runs_created_between(org, repo, start, middle) + runs_created_between(org, repo, middle, end)
    return [run_data for page in pages for run_data in page.get("workflow_runs") or []]


def run_jobs(org, repo, run_id):
    jobs = []
    for page in gh_pages(f"repos/{org}/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page=100",
                         f"job list of run {run_id} in {org}/{repo}"):
        if not isinstance(page, dict) or not isinstance(page.get("jobs") or [], list):
            raise ReadError(f"job list of run {run_id} in {org}/{repo} is not in the expected shape",
                            "a job list is not in the expected shape")
        jobs.extend(job for job in page.get("jobs") or [] if isinstance(job, dict))
    return jobs


def job_interval(job, report_time):
    """(start, end) epochs of a job that ran; a running job ends at report_time."""
    started = epoch_of(job.get("started_at"))
    completed = epoch_of(job.get("completed_at")) if job.get("status") == "completed" else None
    end = completed if completed is not None else report_time
    return started, max(started, end)


def window_jobs(org, repo, start, end, report_time):
    """Jobs (every attempt) of org/repo relevant to [start, end): those that
    started in it, and fleet jobs that started before it but ran into it."""
    seen, to_read, jobs = set(), [], []
    for run_data in runs_created_between(org, repo, start - RERUN_LOOKBACK_DAYS * 86400, end):
        run_id = run_data.get("id") if isinstance(run_data, dict) else None
        if not isinstance(run_id, int):
            raise ReadError(f"a workflow run of {org}/{repo} has no ID", "a workflow run has no ID")
        if run_id in seen:
            continue
        seen.add(run_id)
        updated = epoch_of(run_data.get("updated_at"))
        if run_data.get("status") == "completed" and updated is not None and updated < start:
            continue
        to_read.append(run_id)
    # Job lists are independent reads; a few in parallel keep a busy week well
    # inside the workflow timeout without approaching GitHub's concurrency limits.
    with ThreadPoolExecutor(max_workers=JOB_READ_WORKERS) as pool:
        for run_job_list in pool.map(lambda run_id: run_jobs(org, repo, run_id), to_read):
            for job in run_job_list:
                started = epoch_of(job.get("started_at"))
                if started is None or started >= end:
                    continue
                if started >= start or (classify(job) == "fleet" and job_interval(job, report_time)[1] > start):
                    jobs.append(job)
    return jobs


# --- classification and arithmetic --------------------------------------------


def classify(job):
    name = job.get("runner_name") or ""
    if not name:
        return None
    if name.startswith(FLEET_RUNNER_PREFIX):
        return "fleet"
    if job.get("runner_group_name") == HOSTED_GROUP or re.match(r"^GitHub Actions \d+$", name):
        return "hosted"
    return "other"


def hosted_sku(job):
    labels = [label for label in job.get("labels") or [] if isinstance(label, str)]
    for label in labels:
        for pattern, sku in HOSTED_LABEL_SKUS:
            if pattern.match(label):
                return sku
    return None


def percentile(values, fraction):
    """Nearest-rank percentile of a non-empty list."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def concurrency_profile(intervals, start, end):
    """Seconds spent at each concurrency level over [start, end).

    Intervals are clipped to the window; an interval's end is processed before
    another's start at the same second, so back-to-back jobs do not overlap."""
    events = []
    for low, high in intervals:
        low, high = max(low, start), min(high, end)
        if high > low:
            events.append((low, 1))
            events.append((high, -1))
    events.sort(key=lambda event: (event[0], event[1]))
    seconds, level, cursor = {}, 0, start
    for moment, delta in events:
        if moment > cursor:
            seconds[level] = seconds.get(level, 0) + moment - cursor
            cursor = moment
        level += delta
    if end > cursor:
        seconds[level] = seconds.get(level, 0) + end - cursor
    return seconds


def weighted_percentile(seconds, fraction):
    total = sum(seconds.values())
    if total <= 0:
        return 0
    cumulative = 0
    for level in sorted(seconds):
        cumulative += seconds[level]
        if cumulative >= fraction * total:
            return level
    return max(seconds)


TOTAL_KEYS = ("fleet_jobs", "fleet_minutes", "hosted_jobs", "hosted_minutes", "hosted_billable_minutes",
              "hosted_cost_usd", "hosted_unpriced_minutes", "public_free_billable_minutes", "other_jobs",
              "other_minutes", "not_run_jobs")


def summarize(org, repos, start, end, report_time, jobs_by_repo, unreadable, per_repo_output):
    window_end = min(end, report_time)
    per_repo, skus, unpriced, fleet_intervals, queue_waits = [], {}, {"jobs": 0, "minutes": 0}, [], []
    running = 0
    for repo in repos:
        jobs = jobs_by_repo.get(repo["name"])
        if jobs is None:
            continue
        row = {"repository": repo["name"], "private": repo["private"]}
        row.update({key: 0 for key in TOTAL_KEYS})
        for job in jobs:
            kind = classify(job)
            started = epoch_of(job.get("started_at"))
            if kind == "fleet":
                fleet_intervals.append(job_interval(job, report_time))
            if started < start:
                continue  # a carry-in fleet job: concurrency only
            if kind is None:
                row["not_run_jobs"] += 1
                continue
            low, high = job_interval(job, report_time)
            if job.get("status") != "completed":
                running += 1
            minutes = (high - low) / 60
            row[f"{kind}_jobs"] += 1
            row[f"{kind}_minutes"] += minutes
            if kind == "fleet":
                created = epoch_of(job.get("created_at"))
                if created is not None:
                    queue_waits.append(max(0, low - created))
            elif kind == "hosted":
                billable = math.ceil(minutes) if high > low else 0
                row["hosted_billable_minutes"] += billable
                sku = hosted_sku(job)
                if sku is None:
                    row["hosted_unpriced_minutes"] += billable
                    unpriced["jobs"] += 1
                    unpriced["minutes"] += billable
                    continue
                entry = skus.setdefault(sku, {"jobs": 0, "billable_minutes": 0, "private_billable_minutes": 0,
                                              "cost_usd": 0.0})
                entry["jobs"] += 1
                entry["billable_minutes"] += billable
                if repo["private"] or sku in LARGER_SKUS:
                    cost = billable * HOSTED_PRICES[sku][1]
                    entry["private_billable_minutes"] += billable
                    entry["cost_usd"] += cost
                    row["hosted_cost_usd"] += cost
                else:
                    row["public_free_billable_minutes"] += billable
        per_repo.append(row)

    seconds = concurrency_profile(fleet_intervals, start, window_end)
    concurrency = {
        "window_seconds": max(0, window_end - start),
        "p50": weighted_percentile(seconds, 0.50),
        "p95": weighted_percentile(seconds, 0.95),
        "max": max((level for level, spent in seconds.items() if spent > 0), default=0),
        "minutes_at_or_above": {str(threshold): sum(spent for level, spent in seconds.items() if level >= threshold) / 60
                                for threshold in CONCURRENCY_THRESHOLDS},
        "minutes_by_level": {str(level): seconds[level] / 60 for level in sorted(seconds)},
    }
    queue = {"jobs": len(queue_waits),
             "p50_seconds": percentile(queue_waits, 0.50) if queue_waits else None,
             "p95_seconds": percentile(queue_waits, 0.95) if queue_waits else None,
             "max_seconds": max(queue_waits) if queue_waits else None}
    report = {
        "organization": org,
        "window": {"start": iso(start), "end": iso(end), "report_time": iso(report_time),
                   "rerun_lookback_days": RERUN_LOOKBACK_DAYS},
        "complete": not unreadable,
        "unreadable_repository_count": len(unreadable),
        "repositories_read": len(per_repo),
        "repositories_with_jobs": sum(1 for row in per_repo if row["fleet_jobs"] or row["hosted_jobs"] or row["other_jobs"]),
        "running_jobs": running,
        "pricing": {"source": PRICING_SOURCE, "retrieved": PRICING_RETRIEVED,
                    "usd_per_minute": {sku: price for sku, (_, price) in HOSTED_PRICES.items()}},
        "totals": {key: sum(row[key] for row in per_repo) for key in TOTAL_KEYS},
        "hosted_by_sku": skus,
        "hosted_unpriced": unpriced,
        "fleet_concurrency": concurrency,
        "fleet_queue_wait": queue,
        "per_repository": per_repo_output,
    }
    if per_repo_output:
        report["repositories"] = per_repo
        report["unreadable_repositories"] = unreadable
    return report


# --- output ------------------------------------------------------------------


def fmt_minutes(value):
    return f"{value:,.1f}"


def fmt_usd(value):
    return f"${value:,.2f}"


def fmt_wait(seconds):
    if seconds is None:
        return "n/a (no fleet jobs)"
    return f"{seconds} s" if seconds < 120 else f"{seconds} s ({seconds / 60:.1f} min)"


def unpriced_suffix(minutes):
    return f" + {minutes} unpriced min" if minutes else ""


def markdown(report):
    window, totals = report["window"], report["totals"]
    lines = [f"# CI usage report: {report['organization']}", "",
             f"Window: `{window['start']}` to `{window['end']}` (jobs that started in it; reported at `{window['report_time']}`).", ""]
    if not report["complete"]:
        lines += [f"**INCOMPLETE:** {report['unreadable_repository_count']} repositories could not be read; "
                  "every number below is a lower bound.", ""]
        if report["per_repository"]:
            lines += [f"- `{item['repository']}`: {item['reason']}" for item in report["unreadable_repositories"]]
            lines.append("")
    lines += ["## Fleet vs GitHub-hosted job-minutes", ""]
    if report["per_repository"]:
        lines += ["| Repository | Visibility | Fleet jobs | Fleet min | Hosted jobs | Hosted min | Hosted billable min | Est. hosted cost | Other self-hosted min |",
                  "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
        for row in report["repositories"]:
            if not (row["fleet_jobs"] or row["hosted_jobs"] or row["other_jobs"]):
                continue
            cost = fmt_usd(row["hosted_cost_usd"]) + unpriced_suffix(row["hosted_unpriced_minutes"])
            if row["public_free_billable_minutes"]:
                cost += " (public: standard runners free)"
            lines.append(f"| `{row['repository']}` | {'private' if row['private'] else 'public'} | {row['fleet_jobs']} | "
                         f"{fmt_minutes(row['fleet_minutes'])} | {row['hosted_jobs']} | {fmt_minutes(row['hosted_minutes'])} | "
                         f"{row['hosted_billable_minutes']} | {cost} | {fmt_minutes(row['other_minutes'])} |")
        lines.append(f"| **Total** | | {totals['fleet_jobs']} | {fmt_minutes(totals['fleet_minutes'])} | {totals['hosted_jobs']} | "
                     f"{fmt_minutes(totals['hosted_minutes'])} | {totals['hosted_billable_minutes']} | "
                     f"{fmt_usd(totals['hosted_cost_usd'])}{unpriced_suffix(totals['hosted_unpriced_minutes'])} | "
                     f"{fmt_minutes(totals['other_minutes'])} |")
    else:
        lines += ["Organization totals only; per-repository figures are not published "
                  "(run the script locally with `--per-repo`).", "",
                  "| Runner class | Jobs | Job-minutes | Billable min |", "|---|---:|---:|---:|",
                  f"| Self-hosted fleet | {totals['fleet_jobs']} | {fmt_minutes(totals['fleet_minutes'])} | n/a |",
                  f"| GitHub-hosted | {totals['hosted_jobs']} | {fmt_minutes(totals['hosted_minutes'])} | "
                  f"{totals['hosted_billable_minutes']} |",
                  f"| GitHub-hosted, public repositories (free) | | | {totals['public_free_billable_minutes']} |",
                  f"| Other self-hosted | {totals['other_jobs']} | {fmt_minutes(totals['other_minutes'])} | n/a |"]
    lines += ["", f"{report['repositories_read']} repositories read, {report['repositories_with_jobs']} with jobs in the window; "
              f"{totals['not_run_jobs']} skipped or never-picked-up jobs carry no minutes; "
              f"{report['running_jobs']} jobs still running are counted up to the report time.", ""]

    lines += ["## Estimated GitHub-hosted cost", "",
              f"List prices from {PRICING_SOURCE} (retrieved {PRICING_RETRIEVED}). Each job is rounded up to a whole "
              "minute. Standard runners in public repositories are free and excluded; included plan usage is not subtracted.", "",
              "| Runner (SKU) | USD/min | Jobs | Billable min | Billed min (private) | Est. cost |",
              "|---|---:|---:|---:|---:|---:|"]
    for sku in sorted(report["hosted_by_sku"]):
        entry, (label, price) = report["hosted_by_sku"][sku], HOSTED_PRICES[sku]
        lines.append(f"| {label} (`{sku}`) | {price:.3f} | {entry['jobs']} | {entry['billable_minutes']} | "
                     f"{entry['private_billable_minutes']} | {fmt_usd(entry['cost_usd'])} |")
    if report["hosted_unpriced"]["jobs"]:
        lines.append(f"| unpriced (labels name no standard runner) | n/a | {report['hosted_unpriced']['jobs']} | "
                     f"{report['hosted_unpriced']['minutes']} | n/a | not estimated |")
    lines.append(f"| **Total** | | {totals['hosted_jobs']} | {totals['hosted_billable_minutes']} | | "
                 f"**{fmt_usd(totals['hosted_cost_usd'])}**{unpriced_suffix(totals['hosted_unpriced_minutes'])} |")

    concurrency, queue = report["fleet_concurrency"], report["fleet_queue_wait"]
    lines += ["", "## Fleet concurrency profile", "",
              "Time-weighted over the whole window (idle time counts as 0), including fleet jobs that started "
              "before the window and ran into it. The baseline's two nodes hold 4 jobs; ARC `maxRunners` is 20.", "",
              "| Measure | Value |", "|---|---:|",
              f"| p50 concurrent fleet jobs | {concurrency['p50']} |",
              f"| p95 concurrent fleet jobs | {concurrency['p95']} |",
              f"| max concurrent fleet jobs | {concurrency['max']} |"]
    for threshold in CONCURRENCY_THRESHOLDS:
        lines.append(f"| minutes at >= {threshold} | {fmt_minutes(concurrency['minutes_at_or_above'][str(threshold)])} |")
    lines += [f"| fleet queue wait p50 | {fmt_wait(queue['p50_seconds'])} |",
              f"| fleet queue wait p95 | {fmt_wait(queue['p95_seconds'])} |",
              f"| fleet queue wait max | {fmt_wait(queue['max_seconds'])} |", "",
              "<details><summary>Minutes at each concurrency level</summary>", "",
              "| Concurrent fleet jobs | Minutes |", "|---:|---:|"]
    lines += [f"| {level} | {fmt_minutes(minutes)} |" for level, minutes in concurrency["minutes_by_level"].items()]
    lines += ["", "</details>", "",
              f"Runs are discovered from {RERUN_LOOKBACK_DAYS} days before the window (GitHub's 35-day workflow-run "
              "lifetime plus queueing margin). Queue wait is started_at - created_at of each fleet job that started in the "
              "window, including any wait for a burst node to boot."]
    return "\n".join(lines) + "\n"


# --- main --------------------------------------------------------------------


def valid_time(value):
    if not TIME_RE.match(value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def parse_args(argv):
    options = {"org": DEFAULT_ORG, "days": DEFAULT_DAYS, "end": None, "json": None, "per_repo": False}
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag == "--per-repo":
            options["per_repo"] = True
            index += 1
            continue
        if flag not in ("--org", "--days", "--end", "--json") or index + 1 >= len(argv):
            return None
        value = argv[index + 1]
        if flag == "--org" and ORG_RE.match(value):
            options["org"] = value
        elif flag == "--days" and value.isdigit() and 1 <= int(value) <= MAX_DAYS:
            options["days"] = int(value)
        elif flag == "--end" and valid_time(value):
            options["end"] = value
        elif flag == "--json" and value and not value.startswith("-"):
            options["json"] = value
        else:
            return None
        index += 2
    return options


def report_main(options):
    try:
        report_time = now()
    except ReadError as error:
        print(f"usage data unavailable: {error.public()}")
        return 1
    end = epoch_of(options["end"]) if options["end"] else report_time
    if end is None or end > report_time:
        print(f"{USAGE}\n--end must be a valid time no later than now", file=sys.stderr)
        return 2
    start = end - options["days"] * 86400
    org = options["org"]
    try:
        repos = org_repositories(org)
    except ReadError as error:
        print(f"usage data unavailable: {error.public()}")
        return 1
    jobs_by_repo, unreadable = {}, []
    for index, repo in enumerate(repos, 1):
        label = f"{org}/{repo['name']}" if NAME_REPOSITORIES else f"repository {index}/{len(repos)}"
        try:
            jobs_by_repo[repo["name"]] = window_jobs(org, repo["name"], start, end, report_time)
        except ReadError as error:
            unreadable.append({"repository": repo["name"], "reason": str(error)})
            log(f"UNREADABLE: {label}: {error.public()}")
            continue
        log(f"READ: {label}" + (f": {len(jobs_by_repo[repo['name']])} jobs" if NAME_REPOSITORIES else ""))
    report = summarize(org, repos, start, end, report_time, jobs_by_repo, unreadable, options["per_repo"])
    if options["json"]:
        with open(options["json"], "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=1, sort_keys=True)
            stream.write("\n")
    sys.stdout.write(markdown(report))
    return 0 if report["complete"] else 1


def main(argv):
    global NAME_REPOSITORIES
    options = parse_args(argv)
    if options is None:
        print(USAGE, file=sys.stderr)
        return 2
    if options["per_repo"] and os.environ.get("GITHUB_ACTIONS") == "true":
        print("--per-repo names private repositories and is refused in GitHub Actions (GITHUB_ACTIONS=true)",
              file=sys.stderr)
        return 2
    NAME_REPOSITORIES = options["per_repo"]
    if NAME_REPOSITORIES:
        return report_main(options)
    # Aggregate mode: an unexpected exception's message or traceback could
    # carry a repository name into a public log, so only its type is printed.
    try:
        return report_main(options)
    except Exception as error:  # noqa: BLE001 - reported (type only), exit 1
        print(f"usage report failed: {type(error).__name__} (rerun locally with --per-repo for details)",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
