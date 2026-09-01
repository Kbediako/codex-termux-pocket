#!/usr/bin/env python3
"""Validate the permanent, single-writer GitHub Actions topology."""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
SCRIPT_DIR = REPO_ROOT / ".github" / "scripts"

EXPECTED_WORKFLOWS = {
    "blocking-ci.yml",
    "termux-android-emulator.yml",
    "termux-control-plane.yml",
    "termux-governance.yml",
    "termux-linux-sandbox.yml",
    "termux-mobile-artifact.yml",
    "termux-release-channel.yml",
    "termux-release-request.yml",
}

FORBIDDEN_WORKFLOW_NAME_PARTS = (
    "observe",
    "observer",
    "monitor",
    "detector",
    "repair",
    "trigger",
    "-once",
    "publish-alpha",
)
FORBIDDEN_RUN_NAME_PARTS = ("make fork workflows lightweight",)
TEMPORARY_SCRIPT_NAME = re.compile(
    r"(?i)(?:^|[-_])(?:alpha[0-9].*(?:integrat|maintenan|bootstrap|repair)|"
    r"one[-_]?time|temporary|release[-_]?repair|staging[-_]?worker|gate[-_]?worker)"
)


def fail(message: str) -> None:
    print(f"workflow-topology: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_workflow(name: str) -> str:
    return (WORKFLOW_DIR / name).read_text(encoding="utf-8")


def require_tokens(path: Path, tokens: tuple[str, ...]) -> None:
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        if token not in text:
            fail(f"{path.relative_to(REPO_ROOT)} is missing {token!r}")


def workflow_inventory() -> set[str]:
    return {
        path.name
        for pattern in ("*.yml", "*.yaml")
        for path in WORKFLOW_DIR.glob(pattern)
    }


def validate_names(actual: set[str]) -> None:
    suspicious = sorted(
        name
        for name in actual
        if any(part in name.lower() for part in FORBIDDEN_WORKFLOW_NAME_PARTS)
    )
    if suspicious:
        fail(f"temporary observer/repair workflow names are forbidden: {suspicious}")

    display_names: dict[str, str] = {}
    run_names: dict[str, str] = {}
    for filename in sorted(actual):
        text = read_workflow(filename)
        match = re.search(r"(?m)^name:\s*(.+?)\s*$", text)
        if not match:
            fail(f"{filename} has no top-level workflow name")
        display_name = match.group(1).strip("\"'")
        previous = display_names.get(display_name)
        if previous:
            fail(f"duplicate workflow display name {display_name!r}: {previous} and {filename}")
        display_names[display_name] = filename

        run_match = re.search(r"(?m)^run-name:\s*(.+?)\s*$", text)
        if not run_match:
            fail(f"{filename} has no explicit run-name")
        run_name = run_match.group(1).strip("\"'")
        if not run_name:
            fail(f"{filename} has an empty run-name")
        forbidden = next(
            (part for part in FORBIDDEN_RUN_NAME_PARTS if part in run_name.lower()),
            None,
        )
        if forbidden:
            fail(f"{filename} contains generic run-name token {forbidden!r}")
        previous_run = run_names.get(run_name)
        if previous_run:
            fail(f"duplicate workflow run-name {run_name!r}: {previous_run} and {filename}")
        run_names[run_name] = filename


def validate_no_temporary_orchestration() -> None:
    suspicious = sorted(
        path.name
        for path in SCRIPT_DIR.iterdir()
        if path.is_file() and TEMPORARY_SCRIPT_NAME.search(path.name)
    )
    if suspicious:
        fail(f"temporary maintenance scripts remain: {suspicious}")

    blocking = read_workflow("blocking-ci.yml")
    if re.search(r"(?m)^\s{2}issues:\s*$", blocking):
        fail("blocking-ci.yml must not use maintenance issue events")
    jobs_text = blocking.split("\njobs:\n", 1)
    if len(jobs_text) != 2:
        fail("blocking-ci.yml has no jobs mapping")
    job_ids = set(re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs_text[1]))
    if job_ids != {"validate"}:
        fail(f"blocking-ci.yml contains non-permanent jobs: {sorted(job_ids)}")


def validate_release_ownership(actual: set[str]) -> None:
    artifact = read_workflow("termux-mobile-artifact.yml")
    for forbidden in (
        "publish_release",
        "release_tag:",
        "publish-termux-release:",
        "gh release create",
        "contents: write",
        "--latest=false",
    ):
        if forbidden in artifact:
            fail(f"termux-mobile-artifact.yml contains forbidden publisher token {forbidden!r}")

    channel = read_workflow("termux-release-channel.yml")
    for forbidden in (
        "actions: write",
        "contents: write",
        "--method PATCH",
        "make_latest",
    ):
        if forbidden in channel:
            fail(f"termux-release-channel.yml is not read-only: {forbidden!r}")

    for filename in sorted(actual - {"termux-release-request.yml"}):
        text = read_workflow(filename)
        for forbidden in (
            "gh release create",
            "make_latest",
            '"/repos/${GITHUB_REPOSITORY}/releases"',
            "contents: write",
        ):
            if forbidden in text:
                fail(f"{filename} contains release-writer token {forbidden!r}")


def validate_executable_contract() -> None:
    control = SCRIPT_DIR / "termux_release_control.py"
    common = SCRIPT_DIR / "termux_release" / "common.py"
    github = SCRIPT_DIR / "termux_release" / "github.py"
    publication = SCRIPT_DIR / "termux_release" / "publication.py"
    audit = SCRIPT_DIR / "audit-termux-public-channel.py"
    publisher = WORKFLOW_DIR / "termux-release-request.yml"
    channel = WORKFLOW_DIR / "termux-release-channel.yml"

    require_tokens(
        common,
        (
            '"fork_ci_run_id"',
            '"control_run_id"',
            '"sandbox_run_id"',
            '"artifact_run_id"',
            '"android_run_id"',
            '"x86_64-unknown-linux-gnu"',
            '"aarch64-unknown-linux-gnu"',
        ),
    )
    require_tokens(
        publication,
        (
            'payload={"draft": False, "prerelease": False, "make_latest": "true"}',
            "anonymous public bytes differ from the attested local candidate",
            "verify_attestations",
            "validate_receipt_live",
        ),
    )
    require_tokens(github, ("gh", "attestation", "verify"))
    require_tokens(control, ("validate-request", "prepare", "publish", "audit", "promote"))
    require_tokens(
        publisher,
        (
            "validate-request",
            "prepare",
            "publish",
            "--verify-attestations",
            "promote",
            "termux-release-audit-receipt.json",
        ),
    )
    require_tokens(audit, ("from termux_release.publication import public_audit_main",))
    require_tokens(channel, ("python3 .github/scripts/audit-termux-public-channel.py",))


def main() -> None:
    actual = workflow_inventory()
    missing = sorted(EXPECTED_WORKFLOWS - actual)
    unexpected = sorted(actual - EXPECTED_WORKFLOWS)
    if missing or unexpected:
        fail(f"workflow set mismatch; missing={missing}, unexpected={unexpected}")

    validate_names(actual)
    validate_no_temporary_orchestration()
    validate_release_ownership(actual)
    validate_executable_contract()
    print(
        "workflow-topology: permanent inventory, disposable-orchestration cleanup, "
        "exact-gate contract, and single-writer release ownership are valid"
    )


if __name__ == "__main__":
    main()
