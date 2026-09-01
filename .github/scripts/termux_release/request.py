"""Exact-source request and retained-artifact preparation operations."""

from __future__ import annotations

import argparse
import tempfile
from pathlib import Path

from .artifact import validate_local_bundle
from .common import (
    ARCHIVE, ARTIFACT_ASSETS, ARTIFACT_NAME, CHECKSUMS, PACKAGE_RE,
    RELEASE_MANIFEST, REQUEST_FIELDS, RUN_PATHS, SHA_RE, append_summary,
    file_sha256, parse_env, parse_sha256sums, require_repo, require_token, run,
    validate_request_values, workspace_package_version, write_output,
)
from .github import api_url, paginated_items, verify_run

def validate_request(args: argparse.Namespace) -> int:
    repo = require_repo()
    require_token()
    request_path = Path(args.request)
    values = parse_env(request_path, allowed=REQUEST_FIELDS)
    validate_request_values(values)
    source_sha = values["source_sha"]

    run(["git", "fetch", "--no-tags", "origin", "main"])
    run(["git", "cat-file", "-e", f"{source_sha}^{{commit}}"])
    run(["git", "merge-base", "--is-ancestor", source_sha, "origin/main"])
    cargo_toml = run(["git", "show", f"{source_sha}:codex-rs/Cargo.toml"])
    actual_package_version = workspace_package_version(cargo_toml)
    if actual_package_version != values["expected_package_version"]:
        fail(
            "source package version mismatch: "
            f"{actual_package_version} != {values['expected_package_version']}"
        )

    for field in RUN_PATHS:
        verify_run(
            repo,
            field=field,
            run_id=int(values[field]),
            source_sha=source_sha,
        )

    artifacts = paginated_items(
        repo,
        f"/actions/runs/{values['artifact_run_id']}/artifacts",
        "artifacts",
    )
    matches = [
        artifact
        for artifact in artifacts
        if artifact.get("name") == ARTIFACT_NAME and artifact.get("expired") is False
    ]
    if len(matches) != 1:
        fail(f"expected one retained {ARTIFACT_NAME} artifact, found {len(matches)}")

    for key, value in values.items():
        write_output(key, value)
    write_output("artifact_id", matches[0]["id"])
    append_summary(
        [
            "### Exact-source release request validated",
            "",
            f"- Runtime source: `{source_sha}`",
            f"- Package: `{values['expected_package_version']}`",
            f"- Release tag: `{values['release_tag']}`",
            "- Required gates: `Fork CI, control-plane, Linux x64+ARM64, ARM64 artifact, Android/Termux`",
            f"- Retained artifact ID: `{matches[0]['id']}`",
        ]
    )
    return 0

def prepare(args: argparse.Namespace) -> int:
    repo = require_repo()
    root = Path(args.dist)
    actual_files = {path.name for path in root.iterdir() if path.is_file()}
    unexpected = actual_files - set(ARTIFACT_ASSETS)
    missing = set(ARTIFACT_ASSETS) - actual_files
    if missing or unexpected:
        fail(f"artifact file set mismatch; missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    if not SHA_RE.fullmatch(args.source_sha):
        fail("invalid --source-sha")
    if not PACKAGE_RE.fullmatch(args.package_version):
        fail("invalid --package-version")
    if args.codex_version != f"codex-cli {args.source_sha[:7]}":
        fail("invalid --codex-version")
    expected_tag = f"termux-v{args.package_version}-{args.source_sha[:10]}"
    if args.release_tag != expected_tag:
        fail(f"invalid --release-tag; expected {expected_tag}")

    archive_sha, archive_size, runtime_size = validate_local_bundle(
        root,
        repo=repo,
        source_sha=args.source_sha,
        package_version=args.package_version,
        codex_version=args.codex_version,
    )
    manifest_text = "\n".join(
        [
            "format_version=2",
            f"repository={repo}",
            f"release_tag={args.release_tag}",
            f"head_sha={args.source_sha}",
            f"codex_version={args.codex_version}",
            f"archive_sha256={archive_sha}",
            f"archive_size_bytes={archive_size}",
            f"runtime_size_bytes={runtime_size}",
            "",
        ]
    )
    (root / RELEASE_MANIFEST).write_text(manifest_text, encoding="utf-8")
    write_output("archive_sha256", archive_sha)
    write_output("archive_size_bytes", archive_size)
    write_output("runtime_size_bytes", runtime_size)
    append_summary(
        [
            "### Candidate release bundle prepared",
            "",
            f"- Archive SHA-256: `{archive_sha}`",
            f"- Archive size: `{archive_size}` bytes",
            f"- Installed runtime size: `{runtime_size}` bytes",
            "- Metadata, internal runtime checksums, package descriptor, and SPDX identity: `verified`",
        ]
    )
    return 0

def self_test(_: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory(prefix="termux-release-self-test-") as temp_name:
        root = Path(temp_name)
        request_path = root / "request.env"
        source = "0123456789abcdef0123456789abcdef01234567"
        values = {
            "format_version": "2",
            "source_sha": source,
            "release_tag": f"termux-v0.152.0-alpha.7.2-{source[:10]}",
            "expected_package_version": "0.152.0-alpha.7.2",
            "expected_codex_version": f"codex-cli {source[:7]}",
            "fork_ci_run_id": "1",
            "control_run_id": "2",
            "sandbox_run_id": "3",
            "artifact_run_id": "4",
            "android_run_id": "5",
        }
        request_path.write_text(
            "\n".join(f"{key}={value}" for key, value in values.items()) + "\n",
            encoding="utf-8",
        )
        parsed = parse_env(request_path, allowed=REQUEST_FIELDS)
        validate_request_values(parsed)
        if workspace_package_version('[workspace.package]\nversion = "0.152.0-alpha.7.2"\n') != "0.152.0-alpha.7.2":
            fail("workspace version parser self-test failed")
        payload = root / "payload"
        payload.write_text("payload\n", encoding="utf-8")
        digest = file_sha256(payload)
        (root / CHECKSUMS).write_text(f"{digest}  payload\n", encoding="utf-8")
        if parse_sha256sums(root / CHECKSUMS) != {"payload": digest}:
            fail("SHA256SUMS parser self-test failed")
    print("termux-release-control: self-test passed")
    return 0
