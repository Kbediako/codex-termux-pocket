#!/usr/bin/env python3
"""Audit the promoted Termux release without requiring repository immutability."""

from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
from pathlib import Path

REPO = os.environ["GITHUB_REPOSITORY"]
MANIFEST = Path("scripts/termux/release-manifest.env")
SUMMARY = Path(os.environ["GITHUB_STEP_SUMMARY"])
API_VERSION = "2022-11-28"
GH_TOKEN = os.environ.get("GH_TOKEN", "")


def fail(message: str) -> None:
    raise SystemExit(message)


def parse_env(path: Path, allowed: set[str], required: set[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"{path}:{line_number}: malformed key/value line")
        key, value = line.split("=", 1)
        if key not in allowed or key in values or not value:
            fail(f"{path}:{line_number}: invalid {key or 'entry'}")
        values[key] = value
    missing = required - values.keys()
    if missing:
        fail(f"{path}: missing keys: {', '.join(sorted(missing))}")
    return values


def request(
    url: str,
    *,
    json_result: bool = False,
    method: str = "GET",
    authenticated: bool = False,
):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "codex-termux-governance-audit",
        "X-GitHub-Api-Version": API_VERSION,
    }
    if authenticated:
        if not GH_TOKEN:
            fail("GH_TOKEN is required for GitHub API audit requests")
        headers["Authorization"] = f"Bearer {GH_TOKEN}"
    req = urllib.request.Request(url, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=120) as response:
        if method == "HEAD":
            return response.status
        body = response.read()
    return json.loads(body) if json_result else body


def main() -> None:
    allowed = {
        "format_version",
        "repository",
        "release_tag",
        "head_sha",
        "codex_version",
        "archive_sha256",
        "archive_size_bytes",
        "runtime_size_bytes",
    }
    required = {
        "format_version",
        "repository",
        "release_tag",
        "head_sha",
        "codex_version",
        "archive_sha256",
    }
    manifest = parse_env(MANIFEST, allowed, required)
    if manifest["format_version"] not in {"1", "2"}:
        fail("unsupported release manifest format")
    if manifest["repository"] != REPO:
        fail("release manifest repository mismatch")
    if not re.fullmatch(r"termux-v[0-9A-Za-z._-]+", manifest["release_tag"]):
        fail("invalid release tag")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["head_sha"]):
        fail("invalid release commit SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", manifest["archive_sha256"]):
        fail("invalid archive SHA-256")
    if manifest["format_version"] == "2":
        for key in ("archive_size_bytes", "runtime_size_bytes"):
            if key not in manifest or not manifest[key].isdigit() or int(manifest[key]) <= 0:
                fail(f"invalid {key}")

    tag = urllib.parse.quote(manifest["release_tag"], safe="")
    api = f"https://api.github.com/repos/{REPO}"
    release = request(
        f"{api}/releases/tags/{tag}",
        json_result=True,
        authenticated=True,
    )
    latest = request(
        f"{api}/releases/latest",
        json_result=True,
        authenticated=True,
    )
    if release.get("draft") or release.get("prerelease"):
        fail("promoted release is not a final public release")
    if release.get("tag_name") != manifest["release_tag"]:
        fail("release tag identity mismatch")
    if release.get("target_commitish") != manifest["head_sha"]:
        fail("release target commit mismatch")
    if latest.get("tag_name") != manifest["release_tag"]:
        fail("GitHub Latest does not match the promoted manifest")

    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    expected = {
        "codex-termux-aarch64-unknown-linux-musl.tar.gz",
        "metadata.env",
        "release-manifest.env",
        "SHA256SUMS",
        "codex-termux-sbom.spdx.json",
    }
    if set(assets) != expected:
        fail(
            "release asset set mismatch; "
            f"missing={sorted(expected - assets.keys())}, "
            f"unexpected={sorted(assets.keys() - expected)}"
        )

    archive = assets["codex-termux-aarch64-unknown-linux-musl.tar.gz"]
    remote_digest = archive.get("digest")
    expected_digest = f"sha256:{manifest['archive_sha256']}"
    if remote_digest and remote_digest != expected_digest:
        fail("GitHub archive digest disagrees with the promoted manifest")
    if "archive_size_bytes" in manifest and archive.get("size") != int(manifest["archive_size_bytes"]):
        fail("GitHub archive size disagrees with the promoted manifest")

    temp = Path(os.environ["RUNNER_TEMP"])
    downloaded: dict[str, Path] = {}
    for name in ("release-manifest.env", "metadata.env", "SHA256SUMS", "codex-termux-sbom.spdx.json"):
        path = temp / name
        path.write_bytes(request(assets[name]["browser_download_url"]))
        downloaded[name] = path
    json.loads(downloaded["codex-termux-sbom.spdx.json"].read_text(encoding="utf-8"))

    if parse_env(downloaded["release-manifest.env"], allowed, required) != manifest:
        fail("published release manifest differs from repository promotion")
    metadata = parse_env(
        downloaded["metadata.env"],
        {
            "format_version",
            "source_repository",
            "head_sha",
            "git_describe",
            "codex_version",
            "target",
            "source_ref",
            "archive_size_bytes",
            "runtime_size_bytes",
        },
        {"format_version", "head_sha", "codex_version", "target"},
    )
    if metadata["head_sha"] != manifest["head_sha"]:
        fail("release metadata commit mismatch")
    if metadata["codex_version"] != manifest["codex_version"]:
        fail("release metadata version mismatch")
    if metadata["target"] != "aarch64-unknown-linux-musl":
        fail("release metadata target mismatch")

    sums: dict[str, str] = {}
    for line in downloaded["SHA256SUMS"].read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match.group(2) in sums:
            fail("malformed or duplicate SHA256SUMS entry")
        sums[match.group(2)] = match.group(1)
    if sums.get("codex-termux-aarch64-unknown-linux-musl.tar.gz") != manifest["archive_sha256"]:
        fail("SHA256SUMS archive digest mismatch")

    tag_ref = request(
        f"{api}/git/ref/tags/{tag}",
        json_result=True,
        authenticated=True,
    )["object"]
    if tag_ref["type"] == "tag":
        tag_ref = request(
            tag_ref["url"],
            json_result=True,
            authenticated=True,
        )["object"]
    if tag_ref["type"] != "commit" or tag_ref["sha"] != manifest["head_sha"]:
        fail("release tag no longer resolves to the promoted commit")
    if request(archive["browser_download_url"], method="HEAD") != 200:
        fail("anonymous archive download is unavailable")

    with SUMMARY.open("a", encoding="utf-8") as summary:
        summary.write("### Termux public channel audit\n\n")
        summary.write(f"- Release: `{manifest['release_tag']}`\n")
        summary.write(f"- Runtime commit: `{manifest['head_sha']}`\n")
        summary.write(f"- Runtime version: `{manifest['codex_version']}`\n")
        summary.write(f"- Archive digest: `{manifest['archive_sha256']}`\n")
        summary.write("- GitHub Latest: `verified`\n")
        summary.write("- Repository release editing: `enabled by owner policy`\n")


if __name__ == "__main__":
    main()
