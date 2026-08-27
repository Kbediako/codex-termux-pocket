#!/usr/bin/env python3
"""Validate the permanent GitHub Actions topology for the Termux fork."""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
TEMP_ALPHA1515_SCRIPT = REPO_ROOT / ".github" / "scripts" / "alpha1515-maintenance.sh"

EXPECTED_WORKFLOWS = {
    "blocking-ci.yml",
    "termux-android-emulator.yml",
    "termux-control-plane.yml",
    "termux-governance-audit.yml",
    "termux-linux-sandbox.yml",
    "termux-mobile-artifact.yml",
    "termux-release-channel.yml",
    "termux-release-request.yml",
}

FORBIDDEN_NAME_PARTS = (
    "observe",
    "observer",
    "monitor",
    "detector",
    "repair",
    "trigger",
    "-once",
    "publish-alpha",
)

FORBIDDEN_RUN_NAME_PARTS = (
    "make fork workflows lightweight",
)


def fail(message: str) -> None:
    print(f"workflow-topology: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(name: str) -> str:
    return (WORKFLOW_DIR / name).read_text(encoding="utf-8")


def main() -> None:
    actual = {
        path.name
        for pattern in ("*.yml", "*.yaml")
        for path in WORKFLOW_DIR.glob(pattern)
    }
    missing = sorted(EXPECTED_WORKFLOWS - actual)
    unexpected = sorted(actual - EXPECTED_WORKFLOWS)
    if missing or unexpected:
        fail(f"workflow set mismatch; missing={missing}, unexpected={unexpected}")

    suspicious = sorted(
        name
        for name in actual
        if any(part in name.lower() for part in FORBIDDEN_NAME_PARTS)
    )
    if suspicious:
        fail(f"temporary observer/repair workflow names are forbidden: {suspicious}")

    display_names: dict[str, str] = {}
    run_names: dict[str, str] = {}
    for filename in sorted(actual):
        text = read(filename)

        match = re.search(r"(?m)^name:\s*(.+?)\s*$", text)
        if not match:
            fail(f"{filename} has no top-level workflow name")
        display_name = match.group(1).strip("\"'")
        previous = display_names.get(display_name)
        if previous:
            fail(
                f"duplicate workflow display name {display_name!r}: "
                f"{previous} and {filename}"
            )
        display_names[display_name] = filename

        run_match = re.search(r"(?m)^run-name:\s*(.+?)\s*$", text)
        if not run_match:
            fail(
                f"{filename} has no explicit run-name; push runs would inherit "
                "an unrelated commit message"
            )
        run_name = run_match.group(1).strip("\"'")
        if not run_name:
            fail(f"{filename} has an empty run-name")
        forbidden_run_name = next(
            (
                part
                for part in FORBIDDEN_RUN_NAME_PARTS
                if part in run_name.lower()
            ),
            None,
        )
        if forbidden_run_name:
            fail(
                f"{filename} contains generic run-name token "
                f"{forbidden_run_name!r}"
            )
        previous_run = run_names.get(run_name)
        if previous_run:
            fail(
                f"duplicate workflow run-name {run_name!r}: "
                f"{previous_run} and {filename}"
            )
        run_names[run_name] = filename

    artifact = read("termux-mobile-artifact.yml")
    for forbidden in (
        "publish_release",
        "release_tag:",
        "publish-termux-release:",
        "gh release create",
        "contents: write",
        "--latest=false",
    ):
        if forbidden in artifact:
            fail(
                "termux-mobile-artifact.yml contains forbidden publisher token "
                f"{forbidden!r}"
            )

    channel = read("termux-release-channel.yml")
    for forbidden in (
        "actions: write",
        "gh workflow run termux-governance-audit.yml",
        "--method PATCH",
        "make_latest",
        "expected true (API",
        ".immutable == true",
    ):
        if forbidden in channel:
            fail(
                "termux-release-channel.yml is not read-only current-state "
                f"verification: {forbidden!r}"
            )

    publisher = read("termux-release-request.yml")
    required_publisher_tokens = (
        "Stage complete draft and publish it as Latest once",
        "draft: true",
        'make_latest:"true"',
        "Verify anonymous public downloads byte-for-byte",
        "Promote verified release manifest on protected main",
    )
    for required in required_publisher_tokens:
        if required not in publisher:
            fail(f"termux-release-request.yml is missing {required!r}")

    temporary_alpha1515 = (
        TEMP_ALPHA1515_SCRIPT.is_file()
        and "alpha1515-maintenance:" in read("blocking-ci.yml")
    )
    for filename in sorted(actual - {"termux-release-request.yml"}):
        text = read(filename)
        for forbidden in (
            "gh release create",
            "make_latest",
            '"/repos/${GITHUB_REPOSITORY}/releases"',
            "contents: write",
        ):
            if (
                filename == "blocking-ci.yml"
                and forbidden == "contents: write"
                and temporary_alpha1515
            ):
                continue
            if forbidden in text:
                fail(f"{filename} contains release-writer token {forbidden!r}")

    print(
        "workflow-topology: permanent workflow set, run naming, and release "
        "ownership are valid"
    )


if __name__ == "__main__":
    main()
