"""Shared constants and pure helpers for the Termux release contract."""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import NoReturn

API_VERSION = "2022-11-28"
ARCHIVE = "codex-termux-aarch64-unknown-linux-musl.tar.gz"
METADATA = "metadata.env"
CHECKSUMS = "SHA256SUMS"
SBOM = "codex-termux-sbom.spdx.json"
RELEASE_MANIFEST = "release-manifest.env"
ARTIFACT_ASSETS = (ARCHIVE, METADATA, CHECKSUMS, SBOM)
RELEASE_ASSETS = (ARCHIVE, SBOM, METADATA, RELEASE_MANIFEST, CHECKSUMS)
EXPECTED_CHECKSUM_ENTRIES = {ARCHIVE, METADATA}
ARTIFACT_NAME = "codex-termux-aarch64-unknown-linux-musl"
TARGET = "aarch64-unknown-linux-musl"
PUBLISHER_WORKFLOW_PATH = ".github/workflows/termux-release-request.yml"
RUN_PATHS = {
    "fork_ci_run_id": ".github/workflows/blocking-ci.yml",
    "control_run_id": ".github/workflows/termux-control-plane.yml",
    "sandbox_run_id": ".github/workflows/termux-linux-sandbox.yml",
    "artifact_run_id": ".github/workflows/termux-mobile-artifact.yml",
    "android_run_id": ".github/workflows/termux-android-emulator.yml",
}
REQUIRED_RUN_JOBS = {
    "fork_ci_run_id": {"Termux fork checks"},
    "control_run_id": {"Termux helpers and artifact contract"},
    "sandbox_run_id": {
        "x86_64-unknown-linux-gnu",
        "aarch64-unknown-linux-gnu",
    },
    "android_run_id": {
        "Build fixture from triggering source",
        "Real Termux app on Android emulator",
    },
}
REQUEST_FIELDS = {
    "format_version",
    "source_sha",
    "release_tag",
    "expected_package_version",
    "expected_codex_version",
    *RUN_PATHS,
}
MANIFEST_FIELDS = {
    "format_version",
    "repository",
    "release_tag",
    "head_sha",
    "codex_version",
    "archive_sha256",
    "archive_size_bytes",
    "runtime_size_bytes",
}
METADATA_FIELDS = {
    "format_version",
    "source_repository",
    "head_sha",
    "git_describe",
    "codex_version",
    "target",
    "source_ref",
    "archive_size_bytes",
    "runtime_size_bytes",
}
SHA_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PACKAGE_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+(?:\.[0-9]+)*")
TAG_RE = re.compile(r"termux-v[0-9A-Za-z._-]+")

def fail(message: str) -> NoReturn:
    print(f"termux-release-control: {message}", file=sys.stderr)
    raise SystemExit(1)

def require_repo() -> str:
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        fail("GITHUB_REPOSITORY must contain owner/repository")
    return repo

def require_token() -> str:
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        fail("GH_TOKEN is required for authenticated GitHub operations")
    return token

def append_summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines).rstrip() + "\n")

def write_output(key: str, value: str | int) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    text = str(value)
    if "\n" in text or "\r" in text:
        fail(f"refusing multiline workflow output for {key}")
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(f"{key}={text}\n")

def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = True,
    env: dict[str, str] | None = None,
) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=env,
    )
    if completed.returncode != 0:
        detail = ""
        if capture:
            detail = (completed.stderr or completed.stdout or "").strip()
        fail(f"command failed ({completed.returncode}): {' '.join(args)}{': ' + detail if detail else ''}")
    return completed.stdout.strip() if capture and completed.stdout else ""

def parse_env(
    path: Path,
    *,
    allowed: set[str],
    required: set[str] | None = None,
    allow_empty: set[str] | None = None,
) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        fail(f"missing or unsafe key/value file: {path}")
    values: dict[str, str] = {}
    empty_ok = allow_empty or set()
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw != raw.strip() or "=" not in raw:
            fail(f"{path}:{line_number}: malformed key/value line")
        key, value = raw.split("=", 1)
        if key not in allowed:
            fail(f"{path}:{line_number}: unknown key {key!r}")
        if key in values:
            fail(f"{path}:{line_number}: duplicate key {key!r}")
        if not value and key not in empty_ok:
            fail(f"{path}:{line_number}: empty value for {key!r}")
        values[key] = value
    missing = (required or allowed) - values.keys()
    if missing:
        fail(f"{path}: missing keys: {', '.join(sorted(missing))}")
    return values

def parse_positive_int(value: str, label: str) -> int:
    if not value.isdigit() or int(value) <= 0:
        fail(f"invalid positive integer for {label}: {value!r}")
    return int(value)

def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def parse_sha256sums(path: Path, *, allow_paths: bool = False) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            fail(f"{path}:{line_number}: malformed SHA256SUMS entry")
        digest, name = match.groups()
        if allow_paths:
            candidate = PurePosixPath(name)
            if candidate.is_absolute() or ".." in candidate.parts or not candidate.parts:
                fail(f"{path}:{line_number}: unsafe checksum path {name!r}")
        elif not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            fail(f"{path}:{line_number}: unsafe checksum filename {name!r}")
        if name in entries:
            fail(f"{path}:{line_number}: duplicate SHA256SUMS entry for {name}")
        entries[name] = digest
    return entries

def verify_sha256sums(root: Path, *, expected_names: set[str]) -> dict[str, str]:
    entries = parse_sha256sums(root / CHECKSUMS)
    if set(entries) != expected_names:
        fail(
            "SHA256SUMS entry set mismatch; "
            f"missing={sorted(expected_names - entries.keys())}, "
            f"unexpected={sorted(entries.keys() - expected_names)}"
        )
    for name, expected in entries.items():
        path = root / name
        if not path.is_file() or path.is_symlink():
            fail(f"SHA256SUMS references a missing or unsafe file: {name}")
        actual = file_sha256(path)
        if actual != expected:
            fail(f"SHA256SUMS digest mismatch for {name}: {actual} != {expected}")
    return entries

def workspace_package_version(text: str) -> str:
    in_package = False
    for raw in text.splitlines():
        line = raw.strip()
        if line == "[workspace.package]":
            in_package = True
            continue
        if in_package and line.startswith("["):
            break
        if in_package:
            match = re.fullmatch(r'version\s*=\s*"([^"]+)"', line)
            if match:
                return match.group(1)
    fail("cannot resolve [workspace.package] version")

def package_version_from_tag(tag: str, source_sha: str) -> str:
    suffix = f"-{source_sha[:10]}"
    if not tag.startswith("termux-v") or not tag.endswith(suffix):
        fail("release tag does not encode the exact source prefix")
    version = tag[len("termux-v") : -len(suffix)]
    if not PACKAGE_RE.fullmatch(version):
        fail(f"release tag contains an invalid package version: {version!r}")
    return version

def validate_request_values(values: dict[str, str]) -> None:
    if values["format_version"] != "2":
        fail("release publication request must use format_version=2")
    source_sha = values["source_sha"]
    package_version = values["expected_package_version"]
    if not SHA_RE.fullmatch(source_sha):
        fail("source_sha must be a full lowercase commit SHA")
    if not PACKAGE_RE.fullmatch(package_version):
        fail("expected_package_version is not an official Rust alpha version")
    expected_tag = f"termux-v{package_version}-{source_sha[:10]}"
    if values["release_tag"] != expected_tag:
        fail(f"release_tag must be exactly {expected_tag}")
    expected_binary = f"codex-cli {source_sha[:7]}"
    if values["expected_codex_version"] != expected_binary:
        fail(f"expected_codex_version must be exactly {expected_binary}")
    run_ids: list[int] = []
    for field in RUN_PATHS:
        run_ids.append(parse_positive_int(values[field], field))
    if len(set(run_ids)) != len(run_ids):
        fail("every pre-publication workflow run ID must be distinct")
