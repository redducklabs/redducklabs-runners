#!/usr/bin/env python3
"""Runner cost for one cluster from DigitalOcean invoices (read-only).

Invoked through scripts/runner-cost-report.sh. Implements the "Cost model"
section of docs/specs/2026-10-26-runner-burst-autoscaling-design.md: cost is
measured from the monthly invoice, never inferred.

DigitalOcean does not itemize DOKS nodes per droplet or pool. Invoice items
(doctl invoice get <uuid> -o json) have the keys amount, category, description,
duration, duration_unit, end_time, group_description, product, project_name,
resource_id, resource_uuid and start_time. Node lines have product
"Kubernetes Clusters", group_description "<cluster name>" and a description
such as "8 nodes - 16 GB / 8 vCPU / 320 GB SSD"; duration is node-hours. The
same cluster also bills "pvc-... - 10.00GB Volume" and load-balancer lines.

Attribution is therefore per cluster and node size, not per pool:
  - 16 GB / 8 vCPU lines are runner nodes. The baseline pool is s-8vcpu-16gb,
    the primary burst pool s-8vcpu-16gb-amd and the fallback burst pool
    s-8vcpu-16gb-intel: all three have the 16 GB / 8 vCPU / 320 GB shape. How
    DigitalOcean words the AMD and Intel lines is not documented and no invoice
    of this account has carried one, so every line of that shape counts as
    runner cost, with or without a variant word before or after the size. A
    line whose description says AMD is reported as the primary burst size, one
    that says Intel as the fallback burst size, one that says both makes the
    month unavailable; an unmarked line is the baseline (and burst nodes too,
    if the invoice does not mark the variant);
  - 8 GB / 4 vCPU lines are worker nodes, reported separately and not as
    runner cost;
  - every other line of the cluster is summed as "other cluster items".
Burst node-hours are derived: runner node-hours minus two baseline nodes for
every hour of the invoice period (floor 0); estimated burst cost is those hours
at the average runner price per node-hour. Burst sizes cost $0.16667/node-hour
against $0.14286 for the baseline size, so the average understates burst cost
(by more once the baseline is billed at its monthly cap, which lowers its
effective hourly rate); marked AMD/Intel lines show the measured burst cost
directly.

Output is one of: the table for a completed month; the ACCOUNT-WIDE
month-to-date usage for the month in progress (not itemized by DigitalOcean);
or "cost data unavailable: <reason>" for anything missing or unparseable, which
exits 0 and never prints a zero for missing data. Exit 2 is a usage error.
"""

import calendar
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
from decimal import Decimal, InvalidOperation

MONTH_RE = re.compile(r"^(\d{4})-(0[1-9]|1[0-2])$")
CLUSTER_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NODE_RE = re.compile(r"^\d+ nodes? - (?:(.*?)\s)?(\d+) GB / (\d+) vCPU\b(.*)$")
RUNNER_LINES = ("runner", "runner_amd", "runner_intel")
DEFAULT_CLUSTER = "redducklabs-cluster"
BASELINE_NODES = 2
CENT = Decimal("0.01")


class Unavailable(Exception):
    """The data needed for a number is missing or unparseable."""


def doctl_json(argv):
    try:
        completed = subprocess.run(["doctl", *argv, "-o", "json"], capture_output=True, text=True, check=False)
    except OSError as error:
        raise Unavailable(f"could not run doctl: {error.strerror}") from error
    if completed.returncode != 0:
        raise Unavailable(f"doctl {' '.join(argv[:2])} failed with exit {completed.returncode}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise Unavailable(f"doctl {' '.join(argv[:2])} did not return JSON") from error


def current_month():
    command = shlex.split(os.environ.get("NOW_CMD") or "date +%s")
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        epoch = int(completed.stdout.strip())
    except (OSError, ValueError) as error:
        raise Unavailable("could not determine the current month") from error
    now = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    return (now.year, now.month)


def decimal(value, what):
    try:
        number = Decimal(value) if isinstance(value, str) else None
    except InvalidOperation:
        number = None
    if number is None or not number.is_finite() or number < 0:
        raise Unavailable(f"a cluster invoice item has an unparseable {what}")
    return number


def money(value):
    return f"{value.quantize(CENT):.2f}"


def invoice_uuid(month):
    listing = doctl_json(["invoice", "list"])
    invoices = listing.get("invoices") if isinstance(listing, dict) else None
    if not isinstance(invoices, list):
        raise Unavailable("invoice list is not in the expected shape")
    matches = [i for i in invoices if isinstance(i, dict) and i.get("invoice_period") == month]
    if not matches:
        raise Unavailable(f"no invoice for {month}")
    if len(matches) > 1:
        raise Unavailable(f"more than one invoice for {month}")
    uuid = matches[0].get("invoice_uuid")
    if not isinstance(uuid, str) or not UUID_RE.match(uuid):
        raise Unavailable(f"the invoice for {month} has no valid identifier")
    return uuid


def empty():
    return {"hours": Decimal(0), "usd": Decimal(0), "lines": 0}


def add(total, item, with_hours=True):
    total["usd"] += decimal(item.get("amount"), "amount")
    if with_hours:
        if item.get("duration_unit") != "Hours":
            raise Unavailable("a cluster node line is not measured in hours")
        total["hours"] += decimal(item.get("duration"), "duration")
    total["lines"] += 1


def runner_line(variant_text):
    """The runner total a 16 GB / 8 vCPU line belongs to, from the words around the size."""
    words = set(re.findall(r"[A-Z]+", variant_text.upper()))
    if "AMD" in words and "INTEL" in words:
        raise Unavailable("a cluster runner-size line names both AMD and Intel")
    return "runner_amd" if "AMD" in words else "runner_intel" if "INTEL" in words else "runner"


def cluster_costs(month, cluster):
    document = doctl_json(["invoice", "get", invoice_uuid(month)])
    items = document.get("invoice_items") if isinstance(document, dict) else None
    if not isinstance(items, list):
        raise Unavailable(f"the invoice for {month} has no itemization")
    totals = {"runner": empty(), "runner_amd": empty(), "runner_intel": empty(), "worker": empty(), "other": empty()}
    for item in items:
        if not isinstance(item, dict) or item.get("product") != "Kubernetes Clusters":
            continue
        if item.get("group_description") != cluster:
            continue
        description = item.get("description")
        match = NODE_RE.match(description) if isinstance(description, str) else None
        size = (match.group(2), match.group(3)) if match else None
        if size == ("16", "8"):
            add(totals[runner_line(f"{match.group(1) or ''} {match.group(4)}")], item)
        elif size == ("8", "4"):
            add(totals["worker"], item)
        else:
            add(totals["other"], item, with_hours=False)
    if not any(totals[line]["lines"] for line in RUNNER_LINES):
        raise Unavailable(f"the invoice for {month} has no runner-size (16 GB / 8 vCPU) line for cluster {cluster}")
    return totals


def table(month, cluster, totals):
    year, number = (int(part) for part in month.split("-"))
    period_hours = calendar.monthrange(year, number)[1] * 24
    runner_hours = sum(totals[line]["hours"] for line in RUNNER_LINES)
    runner_usd = sum(totals[line]["usd"] for line in RUNNER_LINES)
    if runner_hours <= 0:
        raise Unavailable(f"the runner-size lines of the invoice for {month} have no hours")
    burst_hours = max(Decimal(0), runner_hours - BASELINE_NODES * period_hours)
    burst_usd = burst_hours * (runner_usd / runner_hours)
    lines = [
        f"Runner cost for {month}, cluster {cluster} (DigitalOcean invoice; includes nodes that no longer exist)",
        "Granularity is per cluster and node size, not per pool; burst lines are split out only where the invoice marks AMD or Intel.",
        f"{'LINE':<56} {'HOURS':>10} {'USD':>10}",
    ]

    def row(label, total):
        lines.append(f"{label:<56} {money(total['hours']):>10} {money(total['usd']):>10}")

    row("runner 16 GB / 8 vCPU (baseline; unmarked burst)", totals["runner"])
    if totals["runner_amd"]["lines"]:
        row("runner 16 GB / 8 vCPU AMD (primary burst)", totals["runner_amd"])
    if totals["runner_intel"]["lines"]:
        row("runner 16 GB / 8 vCPU Intel (fallback burst)", totals["runner_intel"])
    lines.append(f"{'RUNNER TOTAL':<56} {money(runner_hours):>10} {money(runner_usd):>10}")
    if totals["worker"]["lines"]:
        row("worker 8 GB / 4 vCPU (not runner cost)", totals["worker"])
    lines.append(f"{'other cluster items (volumes, load balancers, other)':<56} {'':>10} {money(totals['other']['usd']):>10}")
    lines.append(f"{'burst node-hours, derived (baseline assumed 2 nodes)':<56} {money(burst_hours):>10} {'':>10}")
    lines.append(f"{'burst cost, estimated (derived hours x average price)':<56} {'':>10} {money(burst_usd):>10}")
    return lines


def report(month, cluster):
    year, number = (int(part) for part in month.split("-"))
    now = current_month()
    if (year, number) > now:
        raise Unavailable(f"{month} is in the future")
    if (year, number) == now:
        balance = doctl_json(["balance", "get"])
        usage = balance.get("month_to_date_usage") if isinstance(balance, dict) else None
        if not isinstance(usage, str):
            raise Unavailable("doctl balance get has no month_to_date_usage")
        amount = decimal(usage, "month_to_date_usage")
        return [
            f"ACCOUNT-WIDE month-to-date usage for {month}: ${money(amount)}",
            "This figure covers the whole DigitalOcean account, not only the runner nodes.",
            f"Cluster cost is not itemized for the month in progress; rerun with --month {month} after the invoice closes.",
        ]
    return table(month, cluster, cluster_costs(month, cluster))


def main(argv):
    cluster = DEFAULT_CLUSTER
    if len(argv) == 4 and argv[2] == "--cluster-name":
        cluster = argv[3]
        argv = argv[:2]
    if len(argv) != 2 or argv[0] != "--month" or not MONTH_RE.match(argv[1]) or not CLUSTER_RE.match(cluster):
        print("usage: runner-cost-report.sh --month YYYY-MM [--cluster-name NAME]", file=sys.stderr)
        return 2
    try:
        lines = report(argv[1], cluster)
    except Unavailable as error:
        lines = [f"cost data unavailable: {error}"]
    print("\n".join(line.rstrip() for line in lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
