"""Atomic publication, anonymous audit, and promotion operations."""

from __future__ import annotations

import argparse
import base64
import json
import os
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any

from .artifact import validate_local_bundle, validate_manifest
from .common import (
    ARCHIVE, MANIFEST_FIELDS, PACKAGE_RE, PUBLISHER_WORKFLOW_PATH,
    RELEASE_ASSETS, RELEASE_MANIFEST, SHA_RE, append_summary, fail,
    file_sha256, package_version_from_tag, parse_env, require_repo,
    require_token, write_output,
)
from .github import (
    api_url, download_anonymous, peel_tag_ref, public_release_ready,
    release_assets_by_name, request_bytes, request_json, request_json_optional,
    upload_release_asset, validate_release_object, verify_attestations,
)

def publish(args: argparse.Namespace) -> int:
    repo = require_repo()
    require_token()
    root = Path(args.dist)
    manifest = parse_env(root / RELEASE_MANIFEST, allowed=MANIFEST_FIELDS)
    validate_manifest(manifest, repo=repo)
    source_sha = manifest["head_sha"]
    tag = manifest["release_tag"]
    package_version = package_version_from_tag(tag, source_sha)
    if package_version != args.package_version:
        fail("published package version disagrees with the candidate manifest")
    for name in RELEASE_ASSETS:
        path = root / name
        if not path.is_file() or path.is_symlink():
            fail(f"missing or unsafe release file: {name}")

    releases = request_json(api_url(repo, "/releases?per_page=100"), authenticated=True)
    if not isinstance(releases, list):
        fail("GitHub releases response is malformed")
    matching = [release for release in releases if release.get("tag_name") == tag]
    if len(matching) > 1:
        fail(f"multiple releases exist for {tag}")
    if matching:
        existing = matching[0]
        if existing.get("draft") is False and existing.get("prerelease") is False:
            assets = validate_release_object(existing, tag=tag, source_sha=source_sha, require_public=True)
            for name, asset in assets.items():
                if asset.get("size") != (root / name).stat().st_size:
                    fail(f"existing public asset size mismatch for {name}")
                digest = asset.get("digest")
                if digest and digest != f"sha256:{file_sha256(root / name)}":
                    fail(f"existing public asset digest mismatch for {name}")
            latest = request_json(api_url(repo, "/releases/latest"), authenticated=True)
            if latest.get("id") != existing.get("id") or latest.get("tag_name") != tag:
                fail("existing exact release is not GitHub Latest")
            write_output("release_id", existing["id"])
            write_output("html_url", existing["html_url"])
            append_summary([f"Reused already-public exact release `{tag}` without modifying it."])
            return 0
        if existing.get("draft") is True and existing.get("target_commitish") == source_sha:
            request_bytes(
                api_url(repo, f"/releases/{existing['id']}"),
                method="DELETE",
                authenticated=True,
            )
        else:
            fail(f"release {tag} already exists in a conflicting state")

    tag_ref_url = api_url(repo, f"/git/ref/tags/{urllib.parse.quote(tag, safe='')}")
    if request_json_optional(tag_ref_url, authenticated=True) is not None:
        fail(f"protected tag {tag} already exists; refusing to move or delete it")

    notes = (
        f"Verified complete Termux runtime for OpenAI Codex CLI {package_version}.\n\n"
        "Exact-source Fork CI, Termux control-plane, Linux sandbox on x64 and ARM64, "
        "production ARM64 artifact, and native Android/Termux validation all completed "
        "successfully before publication.\n\n"
        f"Runtime source: {source_sha}\n"
        f"Binary identity: {manifest['codex_version']}"
    )
    created = request_json(
        api_url(repo, "/releases"),
        method="POST",
        payload={
            "tag_name": tag,
            "target_commitish": source_sha,
            "name": f"Codex Termux {package_version} ({manifest['codex_version']})",
            "body": notes,
            "draft": True,
            "prerelease": False,
        },
        authenticated=True,
    )
    release_id = created.get("id")
    upload_url = str(created.get("upload_url", "")).split("{", 1)[0]
    if not isinstance(release_id, int) or not upload_url or created.get("draft") is not True:
        fail("GitHub did not create the expected draft release")

    for name in RELEASE_ASSETS:
        upload_release_asset(upload_url, root / name)

    draft = request_json(api_url(repo, f"/releases/{release_id}"), authenticated=True)
    assets = validate_release_object(draft, tag=tag, source_sha=source_sha, require_public=False)
    if draft.get("draft") is not True:
        fail("release left draft state before the complete asset set was verified")
    for name, asset in assets.items():
        if asset.get("size") != (root / name).stat().st_size:
            fail(f"uploaded draft asset size mismatch for {name}")
        digest = asset.get("digest")
        if digest and digest != f"sha256:{file_sha256(root / name)}":
            fail(f"uploaded draft asset digest mismatch for {name}")

    published = request_json(
        api_url(repo, f"/releases/{release_id}"),
        method="PATCH",
        payload={"draft": False, "prerelease": False, "make_latest": "true"},
        authenticated=True,
    )
    validate_release_object(published, tag=tag, source_sha=source_sha, require_public=True)
    latest = request_json(api_url(repo, "/releases/latest"), authenticated=True, attempts=5)
    if latest.get("id") != release_id or latest.get("tag_name") != tag:
        fail("the initial draft-to-public transaction did not make the release GitHub Latest")
    write_output("release_id", release_id)
    write_output("html_url", published.get("html_url", ""))
    append_summary(
        [
            "### Complete release published atomically",
            "",
            f"- Release: `{tag}`",
            f"- Release ID: `{release_id}`",
            f"- target_commitish: `{source_sha}`",
            "- Initial public asset set: `complete (5/5)`",
            "- GitHub Latest: `set in the draft-to-public update`",
        ]
    )
    return 0

def audit_public_release(
    *,
    manifest_path: Path,
    local_dir: Path | None,
    verify_provenance: bool,
    receipt_path: Path | None,
) -> dict[str, Any]:
    repo = require_repo()
    manifest = parse_env(manifest_path, allowed=MANIFEST_FIELDS)
    validate_manifest(manifest, repo=repo)
    tag = manifest["release_tag"]
    source_sha = manifest["head_sha"]
    package_version = package_version_from_tag(tag, source_sha)

    release, latest = public_release_ready(repo, tag)
    assets = validate_release_object(release, tag=tag, source_sha=source_sha, require_public=True)
    if latest.get("id") != release.get("id"):
        fail("public /releases/latest does not resolve to the audited release")

    with tempfile.TemporaryDirectory(prefix="termux-public-release-") as temp_name:
        public_dir = Path(temp_name)
        asset_evidence: dict[str, dict[str, Any]] = {}
        for name in RELEASE_ASSETS:
            asset = assets[name]
            url = asset.get("browser_download_url")
            if not isinstance(url, str) or not url.startswith("https://github.com/"):
                fail(f"asset {name} has an invalid public download URL")
            path = public_dir / name
            download_anonymous(url, path)
            size = path.stat().st_size
            digest = file_sha256(path)
            if size != asset.get("size"):
                fail(f"GitHub asset size mismatch for {name}: {size} != {asset.get('size')}")
            if asset.get("digest") != f"sha256:{digest}":
                fail(f"GitHub asset digest mismatch for {name}")
            asset_evidence[name] = {"size": size, "digest": f"sha256:{digest}"}
            if local_dir is not None:
                local = local_dir / name
                if not local.is_file() or local.is_symlink():
                    fail(f"local candidate file is missing or unsafe: {name}")
                if local.read_bytes() != path.read_bytes():
                    fail(f"anonymous public bytes differ from the attested local candidate: {name}")

        if (public_dir / RELEASE_MANIFEST).read_bytes() != manifest_path.read_bytes():
            fail("published release-manifest.env differs from the audited manifest")
        public_manifest = parse_env(public_dir / RELEASE_MANIFEST, allowed=MANIFEST_FIELDS)
        if public_manifest != manifest:
            fail("published release manifest values differ from the audited manifest")
        archive_sha, archive_size, runtime_size = validate_local_bundle(
            public_dir,
            repo=repo,
            source_sha=source_sha,
            package_version=package_version,
            codex_version=manifest["codex_version"],
        )
        if archive_sha != manifest["archive_sha256"]:
            fail("public archive digest disagrees with the release manifest")
        if archive_size != int(manifest["archive_size_bytes"]):
            fail("public archive size disagrees with the release manifest")
        if runtime_size != int(manifest["runtime_size_bytes"]):
            fail("public runtime size disagrees with the release manifest")
        if peel_tag_ref(repo, tag) != source_sha:
            fail("release tag ref does not resolve to the selected source commit")
        if verify_provenance:
            verify_attestations(public_dir, repo=repo)

    receipt = {
        "format_version": 1,
        "repository": repo,
        "release_id": release["id"],
        "release_tag": tag,
        "head_sha": source_sha,
        "manifest_sha256": file_sha256(manifest_path),
        "assets": asset_evidence,
        "tag_commit": source_sha,
        "latest_release_id": latest["id"],
        "publisher_workflow": f"{repo}/{PUBLISHER_WORKFLOW_PATH}",
        "attestations_verified": verify_provenance,
    }
    if receipt_path is not None:
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_output("release_id", release["id"])
    write_output("release_tag", tag)
    write_output("head_sha", source_sha)
    write_output("manifest_sha256", receipt["manifest_sha256"])
    append_summary(
        [
            "### Anonymous public release audit",
            "",
            f"- Release: `{tag}`",
            f"- Runtime source and tag ref: `{source_sha}`",
            "- `/releases/latest`: `verified against public release metadata`",
            "- Asset set, bytes, API digests, and sizes: `verified (5/5)`",
            "- SHA256SUMS, metadata, archive contents, and runtime checksums: `verified`",
            "- SPDX package/source identity: `verified`",
            f"- Publisher attestations: `{'verified' if verify_provenance else 'not requested'}`",
        ]
    )
    return receipt

def audit(args: argparse.Namespace) -> int:
    audit_public_release(
        manifest_path=Path(args.manifest),
        local_dir=Path(args.local_dir) if args.local_dir else None,
        verify_provenance=args.verify_attestations,
        receipt_path=Path(args.receipt) if args.receipt else None,
    )
    return 0

def validate_receipt_live(receipt: dict[str, Any], manifest_path: Path) -> None:
    repo = require_repo()
    if receipt.get("format_version") != 1 or receipt.get("repository") != repo:
        fail("audit receipt format or repository mismatch")
    if receipt.get("manifest_sha256") != file_sha256(manifest_path):
        fail("candidate manifest changed after the anonymous audit")
    if receipt.get("attestations_verified") is not True:
        fail("audit receipt does not prove publisher attestations")
    tag = receipt.get("release_tag")
    source_sha = receipt.get("head_sha")
    release_id = receipt.get("release_id")
    if not isinstance(tag, str) or not isinstance(source_sha, str) or not isinstance(release_id, int):
        fail("audit receipt release identity is malformed")
    release = request_json(
        api_url(repo, f"/releases/{release_id}"),
        authenticated=True,
        attempts=4,
    )
    latest = request_json(api_url(repo, "/releases/latest"), authenticated=True, attempts=4)
    assets = validate_release_object(release, tag=tag, source_sha=source_sha, require_public=True)
    if latest.get("id") != release_id or latest.get("tag_name") != tag:
        fail("GitHub Latest changed after the anonymous audit")
    expected_assets = receipt.get("assets")
    if not isinstance(expected_assets, dict) or set(expected_assets) != set(RELEASE_ASSETS):
        fail("audit receipt asset evidence is malformed")
    for name, asset in assets.items():
        evidence = expected_assets.get(name)
        if not isinstance(evidence, dict):
            fail(f"audit receipt has no evidence for {name}")
        if asset.get("size") != evidence.get("size") or asset.get("digest") != evidence.get("digest"):
            fail(f"public asset metadata changed after the anonymous audit: {name}")
    if peel_tag_ref(repo, tag) != source_sha:
        fail("release tag ref changed after the anonymous audit")

def promote(args: argparse.Namespace) -> int:
    repo = require_repo()
    require_token()
    manifest_path = Path(args.manifest)
    manifest = parse_env(manifest_path, allowed=MANIFEST_FIELDS)
    validate_manifest(manifest, repo=repo)
    receipt_path = Path(args.receipt)
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid audit receipt: {exc}")
    validate_receipt_live(receipt, manifest_path)

    contents_url = api_url(repo, "/contents/scripts/termux/release-manifest.env?ref=main")
    current = request_json(contents_url, authenticated=True)
    blob_sha = current.get("sha")
    encoded = current.get("content")
    if not isinstance(blob_sha, str) or not isinstance(encoded, str):
        fail("cannot read the current promoted manifest from main")
    current_bytes = base64.b64decode(encoded.replace("\n", ""))
    candidate = manifest_path.read_bytes()
    if current_bytes == candidate:
        write_output("promotion_commit_sha", "unchanged")
        append_summary([f"Promoted manifest already identifies `{manifest['release_tag']}`."])
        return 0

    response = request_json(
        api_url(repo, "/contents/scripts/termux/release-manifest.env"),
        method="PUT",
        payload={
            "message": f"termux: promote {manifest['release_tag']}",
            "content": base64.b64encode(candidate).decode("ascii"),
            "sha": blob_sha,
            "branch": "main",
        },
        authenticated=True,
    )
    commit_sha = ((response.get("commit") or {}).get("sha"))
    if not isinstance(commit_sha, str) or not SHA_RE.fullmatch(commit_sha):
        fail("manifest promotion did not return a commit SHA")
    write_output("promotion_commit_sha", commit_sha)
    append_summary(
        [
            "### Verified manifest promoted",
            "",
            f"- Release: `{manifest['release_tag']}`",
            f"- Runtime source: `{manifest['head_sha']}`",
            f"- Promotion commit: `{commit_sha}`",
            "- Promotion prerequisite: `same-job anonymous audit receipt revalidated against live GitHub state`",
        ]
    )
    return 0

def public_audit_main() -> int:
    audit_public_release(
        manifest_path=Path(
            os.environ.get(
                "CODEX_TERMUX_RELEASE_MANIFEST",
                "scripts/termux/release-manifest.env",
            )
        ),
        local_dir=None,
        verify_provenance=True,
        receipt_path=None,
    )
    return 0
