"""Artifact, archive, metadata, and SPDX validation."""

from __future__ import annotations

import json
import shutil
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

from .common import (
    ARCHIVE, ARTIFACT_ASSETS, CHECKSUMS, EXPECTED_CHECKSUM_ENTRIES,
    MANIFEST_FIELDS, METADATA, METADATA_FIELDS, PACKAGE_RE, RELEASE_MANIFEST,
    SBOM, SHA256_RE, SHA_RE, TAG_RE, TARGET, fail, file_sha256,
    package_version_from_tag, parse_env, parse_positive_int, parse_sha256sums,
    verify_sha256sums,
)

def validate_sbom(
    path: Path,
    *,
    repo: str,
    source_sha: str,
    package_version: str,
    codex_version: str,
) -> None:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid SPDX SBOM {path}: {exc}")
    expected_namespace = f"https://github.com/{repo}/attestations/codex-termux/{source_sha}"
    expected_document_name = f"codex-termux-runtime-{source_sha[:12]}"
    checks = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": expected_document_name,
        "documentNamespace": expected_namespace,
    }
    for key, expected in checks.items():
        if document.get(key) != expected:
            fail(f"SBOM {key} mismatch: {document.get(key)!r} != {expected!r}")
    packages = document.get("packages")
    if not isinstance(packages, list):
        fail("SBOM packages must be a list")
    by_name: dict[str, list[dict[str, Any]]] = {}
    by_id: dict[str, dict[str, Any]] = {}
    for package in packages:
        if not isinstance(package, dict):
            fail("SBOM package entry is not an object")
        name = package.get("name")
        identifier = package.get("SPDXID")
        if not isinstance(name, str) or not isinstance(identifier, str) or identifier in by_id:
            fail("SBOM package identity is malformed or duplicated")
        by_name.setdefault(name, []).append(package)
        by_id[identifier] = package
    runtime_packages = by_name.get("codex-termux-runtime", [])
    if len(runtime_packages) != 1 or runtime_packages[0].get("versionInfo") != codex_version:
        fail("SBOM runtime package identity mismatch")
    for shipped in ("codex-cli", "codex-code-mode-host", "codex-responses-api-proxy", "bwrap"):
        candidates = by_name.get(shipped, [])
        if len(candidates) != 1 or candidates[0].get("versionInfo") != package_version:
            fail(f"SBOM shipped package identity mismatch for {shipped}")

    relationships = document.get("relationships")
    if not isinstance(relationships, list):
        fail("SBOM relationships must be a list")
    runtime_id = runtime_packages[0]["SPDXID"]
    described = any(
        relationship.get("spdxElementId") == "SPDXRef-DOCUMENT"
        and relationship.get("relationshipType") == "DESCRIBES"
        and relationship.get("relatedSpdxElement") == runtime_id
        for relationship in relationships
        if isinstance(relationship, dict)
    )
    if not described:
        fail("SBOM does not describe the Termux runtime package")
    generated_ids = {
        relationship.get("relatedSpdxElement")
        for relationship in relationships
        if isinstance(relationship, dict)
        and relationship.get("spdxElementId") == runtime_id
        and relationship.get("relationshipType") == "GENERATED_FROM"
    }
    expected_generated = {
        by_name[name][0]["SPDXID"]
        for name in ("codex-cli", "codex-code-mode-host", "codex-responses-api-proxy", "bwrap")
    }
    if not expected_generated.issubset(generated_ids):
        fail("SBOM is missing GENERATED_FROM relationships for shipped packages")

def safe_member_name(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        fail(f"archive contains unsafe path: {name!r}")
    if path.parts[0] != "codex-termux-runtime":
        fail(f"archive path is outside codex-termux-runtime: {name!r}")
    return path

def verify_archive(path: Path, *, runtime_size_bytes: int, codex_version: str) -> None:
    required = {
        "codex-termux-runtime/bin/codex",
        "codex-termux-runtime/bin/codex-code-mode-host",
        "codex-termux-runtime/bin/codex-responses-api-proxy",
        "codex-termux-runtime/codex-resources/bwrap",
        "codex-termux-runtime/codex-package.json",
        "codex-termux-runtime/runtime-files.sha256",
    }
    with tempfile.TemporaryDirectory(prefix="termux-release-archive-") as temp_name:
        temp = Path(temp_name)
        seen: set[str] = set()
        file_names: set[str] = set()
        total = 0
        try:
            archive = tarfile.open(path, mode="r:gz")
        except (tarfile.TarError, OSError) as exc:
            fail(f"invalid runtime archive: {exc}")
        with archive:
            for member in archive.getmembers():
                safe = safe_member_name(member.name)
                normalized = safe.as_posix().rstrip("/")
                if normalized in seen:
                    fail(f"archive contains duplicate path: {normalized}")
                seen.add(normalized)
                if member.isdir():
                    (temp / safe).mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    fail(f"archive contains a link or special entry: {member.name}")
                file_names.add(normalized)
                total += member.size
                destination = temp / safe
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    fail(f"cannot read archive member: {member.name}")
                with source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
        if total != runtime_size_bytes:
            fail(f"archive runtime size mismatch: {total} != {runtime_size_bytes}")
        missing = required - file_names
        if missing:
            fail(f"archive is missing required runtime files: {sorted(missing)}")

        runtime = temp / "codex-termux-runtime"
        internal = parse_sha256sums(runtime / "runtime-files.sha256", allow_paths=True)
        expected_internal = {
            PurePosixPath(name).relative_to("codex-termux-runtime").as_posix()
            for name in file_names
            if name != "codex-termux-runtime/runtime-files.sha256"
        }
        if set(internal) != expected_internal:
            fail("runtime-files.sha256 does not cover exactly the shipped runtime files")
        for relative, expected in internal.items():
            candidate = PurePosixPath(relative)
            if candidate.is_absolute() or ".." in candidate.parts:
                fail(f"unsafe runtime checksum path: {relative!r}")
            actual = file_sha256(runtime / candidate)
            if actual != expected:
                fail(f"runtime checksum mismatch for {relative}")

        try:
            package = json.loads((runtime / "codex-package.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"invalid codex-package.json: {exc}")
        expected_package = {
            "layoutVersion": 1,
            "version": codex_version,
            "target": TARGET,
            "variant": "primary",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
        }
        if package != expected_package:
            fail("codex-package.json does not match the release metadata")

def validate_manifest(values: dict[str, str], *, repo: str) -> None:
    if values["format_version"] != "2":
        fail("release manifest must use format_version=2")
    if values["repository"] != repo:
        fail("release manifest repository mismatch")
    if not TAG_RE.fullmatch(values["release_tag"]):
        fail("release manifest tag is invalid")
    if not SHA_RE.fullmatch(values["head_sha"]):
        fail("release manifest source SHA is invalid")
    if values["codex_version"] != f"codex-cli {values['head_sha'][:7]}":
        fail("release manifest binary identity mismatch")
    if not SHA256_RE.fullmatch(values["archive_sha256"]):
        fail("release manifest archive digest is invalid")
    parse_positive_int(values["archive_size_bytes"], "archive_size_bytes")
    parse_positive_int(values["runtime_size_bytes"], "runtime_size_bytes")
    package_version_from_tag(values["release_tag"], values["head_sha"])

def validate_local_bundle(
    root: Path,
    *,
    repo: str,
    source_sha: str,
    package_version: str,
    codex_version: str,
) -> tuple[str, int, int]:
    for name in ARTIFACT_ASSETS:
        path = root / name
        if not path.is_file() or path.is_symlink():
            fail(f"missing or unsafe artifact file: {name}")
    checksum_entries = verify_sha256sums(root, expected_names=EXPECTED_CHECKSUM_ENTRIES)
    metadata = parse_env(
        root / METADATA,
        allowed=METADATA_FIELDS,
        allow_empty={"git_describe", "source_ref"},
    )
    if metadata["format_version"] != "2":
        fail("metadata.env must use format_version=2")
    checks = {
        "source_repository": repo,
        "head_sha": source_sha,
        "codex_version": codex_version,
        "target": TARGET,
    }
    for key, expected in checks.items():
        if metadata[key] != expected:
            fail(f"metadata {key} mismatch: {metadata[key]!r} != {expected!r}")
    archive_size = parse_positive_int(metadata["archive_size_bytes"], "archive_size_bytes")
    runtime_size = parse_positive_int(metadata["runtime_size_bytes"], "runtime_size_bytes")
    actual_archive_size = (root / ARCHIVE).stat().st_size
    if actual_archive_size != archive_size:
        fail(f"archive size mismatch: {actual_archive_size} != {archive_size}")
    archive_sha = file_sha256(root / ARCHIVE)
    if checksum_entries[ARCHIVE] != archive_sha:
        fail("archive digest disagrees with SHA256SUMS")
    if checksum_entries[METADATA] != file_sha256(root / METADATA):
        fail("metadata digest disagrees with SHA256SUMS")
    verify_archive(root / ARCHIVE, runtime_size_bytes=runtime_size, codex_version=codex_version)
    validate_sbom(
        root / SBOM,
        repo=repo,
        source_sha=source_sha,
        package_version=package_version,
        codex_version=codex_version,
    )
    return archive_sha, archive_size, runtime_size
