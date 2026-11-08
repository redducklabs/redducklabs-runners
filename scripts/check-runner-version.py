#!/usr/bin/env python3
"""Compare the pinned Actions runner with upstream releases, and apply a bump.

GitHub rejects runners more than 30 days behind the latest release, and ARC
runners cannot update themselves, so the pin in docker/Dockerfile.custom-runner
has to move before that clock runs out. The rejection is silent: runners stay
online and jobs stay queued. See docs/runbooks/node-pool-sizing.md,
"Jobs are assigned but no runner receives them".

check prints KEY=VALUE lines. The clock starts at the oldest stable release
newer than the pin, which is the earliest date GitHub's rule could apply.
apply rewrites every file that records the pinned version.

Exit codes: 0 pin is current or inside the warning window, 1 pin is overdue,
2 the data could not be read. Unreadable data is never reported as current.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ENFORCEMENT_DAYS = 30
OVERDUE_AFTER_DAYS = 7
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
TAG_RE = re.compile(rf"^v({VERSION})$")
DOCKERFILE = "docker/Dockerfile.custom-runner"
PIN_RE = re.compile(
    rf"^ARG ACTIONS_RUNNER_BASE=ghcr\.io/actions/actions-runner:({VERSION})$",
    re.MULTILINE,
)
# Every file that records the version, with the text around it.
PIN_FILES = {
    DOCKERFILE: "ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:{}",
    "docs/toolchain/dockerfile-security-refactor.md": (
        "ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:{}"
    ),
    "README.md": "| GitHub Actions Runner | {} |",
}


class DataError(RuntimeError):
    """Input that cannot support a verdict."""


def parse_version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def read_pin(root: Path) -> str:
    try:
        matches = PIN_RE.findall((root / DOCKERFILE).read_text(encoding="utf-8"))
    except OSError as exc:
        raise DataError(f"cannot read {DOCKERFILE}: {exc}") from None
    if len(matches) != 1:
        raise DataError(f"expected one runner pin in {DOCKERFILE}, found {len(matches)}")
    return matches[0]


def stable_releases(path: Path) -> list[tuple[str, datetime]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise DataError(f"cannot read releases: {exc}") from None
    if not isinstance(data, list) or not data:
        raise DataError("releases data is empty or malformed")
    releases = []
    for item in data:
        if not isinstance(item, dict):
            raise DataError("releases data is malformed")
        if item.get("draft") or item.get("prerelease"):
            continue
        match = TAG_RE.match(str(item.get("tag_name", "")))
        if not match:
            raise DataError(f"unexpected stable release tag: {item.get('tag_name')!r}")
        try:
            published = datetime.fromisoformat(
                str(item.get("published_at")).replace("Z", "+00:00")
            )
        except ValueError:
            raise DataError(f"release {match[1]} has no valid date") from None
        if published.tzinfo is None:
            raise DataError(f"release {match[1]} has no valid date")
        releases.append((match[1], published))
    if not releases:
        raise DataError("no stable releases found")
    return sorted(releases, key=lambda release: parse_version(release[0]))


def check(root: Path, releases_file: Path, now: datetime) -> int:
    pinned = read_pin(root)
    releases = stable_releases(releases_file)
    latest = releases[-1][0]
    newer = [r for r in releases if parse_version(r[0]) > parse_version(pinned)]
    print(f"PINNED={pinned}")
    print(f"LATEST={latest}")
    if not newer:
        print("STATUS=current")
        return 0
    started = min(published for _, published in newer)
    age_days = (now - started).days
    deadline = started + timedelta(days=ENFORCEMENT_DAYS)
    overdue = age_days >= OVERDUE_AFTER_DAYS
    print(f"AGE_DAYS={age_days}")
    print(f"DEADLINE={deadline.date().isoformat()}")
    print(f"STATUS={'overdue' if overdue else 'update-available'}")
    return 1 if overdue else 0


def apply(root: Path, version: str) -> None:
    if not re.fullmatch(VERSION, version):
        raise DataError(f"invalid version: {version}")
    pinned = read_pin(root)
    if parse_version(version) <= parse_version(pinned):
        raise DataError(f"{version} is not newer than the pin {pinned}")
    updated = {}
    for name, template in PIN_FILES.items():
        path = root / name
        text = path.read_bytes().decode("utf-8")
        old = template.format(pinned)
        if text.count(old) != 1:
            raise DataError(f"expected one pinned version in {name}")
        updated[path] = text.replace(old, template.format(version))
    for path, text in updated.items():
        path.write_bytes(text.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    commands = parser.add_subparsers(dest="command", required=True)
    check_parser = commands.add_parser("check")
    check_parser.add_argument("--releases", type=Path, required=True)
    check_parser.add_argument("--now", help="ISO 8601 time, for tests")
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        if args.command == "apply":
            apply(args.root, args.version)
            return 0
        now = (
            datetime.fromisoformat(args.now.replace("Z", "+00:00"))
            if args.now
            else datetime.now(timezone.utc)
        )
        return check(args.root, args.releases, now)
    except (DataError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("STATUS=unavailable")
        return 2


if __name__ == "__main__":
    sys.exit(main())
