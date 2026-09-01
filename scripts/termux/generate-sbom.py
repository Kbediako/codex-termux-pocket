#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 SBOM for the shipped Termux runtime."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SHIPPED_CARGO_PACKAGES = frozenset(
    {
        "codex-cli",
        "codex-code-mode-host",
        "codex-responses-api-proxy",
        "codex-bwrap",
    }
)


def command_output(args: list[str], *, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def spdx_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-.")
    return cleaned or "unnamed"


def cargo_purl(name: str, version: str) -> str:
    return f"pkg:cargo/{urllib.parse.quote(name, safe='')}@{urllib.parse.quote(version, safe='')}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifact-version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()

    workspace = args.workspace.resolve()
    metadata: dict[str, Any] = json.loads(
        command_output(
            ["cargo", "metadata", "--locked", "--format-version=1"],
            cwd=workspace,
        )
    )
    commit_epoch = int(command_output(["git", "show", "-s", "--format=%ct", args.commit], cwd=workspace))
    created = datetime.fromtimestamp(commit_epoch, timezone.utc).isoformat().replace("+00:00", "Z")

    packages_by_id = {package["id"]: package for package in metadata["packages"]}
    ordered_packages = sorted(
        metadata["packages"],
        key=lambda package: (package["name"], package["version"], package["id"]),
    )
    spdx_by_cargo_id: dict[str, str] = {}
    spdx_packages: list[dict[str, Any]] = []

    runtime_spdx_id = "SPDXRef-Package-codex-termux-runtime"
    spdx_packages.append(
        {
            "SPDXID": runtime_spdx_id,
            "name": "codex-termux-runtime",
            "versionInfo": args.artifact_version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        }
    )

    for index, package in enumerate(ordered_packages, start=1):
        identifier = (
            "SPDXRef-Package-"
            + spdx_id(package["name"])
            + "-"
            + spdx_id(package["version"])
            + f"-{index}"
        )
        spdx_by_cargo_id[package["id"]] = identifier
        package_entry: dict[str, Any] = {
            "SPDXID": identifier,
            "name": package["name"],
            "versionInfo": package["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": package.get("license") or "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": cargo_purl(package["name"], package["version"]),
                }
            ],
        }
        if package.get("description"):
            package_entry["description"] = package["description"]
        spdx_packages.append(package_entry)

    relationships: list[dict[str, str]] = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": runtime_spdx_id,
        }
    ]

    resolve = metadata.get("resolve") or {}
    for node in sorted(resolve.get("nodes", []), key=lambda item: item["id"]):
        source = spdx_by_cargo_id.get(node["id"])
        if source is None:
            continue
        dependency_ids = sorted({dependency["pkg"] for dependency in node.get("deps", [])})
        for dependency_id in dependency_ids:
            target = spdx_by_cargo_id.get(dependency_id)
            if target is not None:
                relationships.append(
                    {
                        "spdxElementId": source,
                        "relationshipType": "DEPENDS_ON",
                        "relatedSpdxElement": target,
                    }
                )

    found_shipped: set[str] = set()
    for cargo_id, package in sorted(packages_by_id.items()):
        package_name = package["name"]
        if package_name in SHIPPED_CARGO_PACKAGES:
            found_shipped.add(package_name)
            relationships.append(
                {
                    "spdxElementId": runtime_spdx_id,
                    "relationshipType": "GENERATED_FROM",
                    "relatedSpdxElement": spdx_by_cargo_id[cargo_id],
                }
            )
    missing_shipped = SHIPPED_CARGO_PACKAGES - found_shipped
    if missing_shipped:
        raise SystemExit(
            "Cargo metadata is missing shipped Termux packages: "
            + ", ".join(sorted(missing_shipped))
        )

    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"codex-termux-runtime-{args.commit[:12]}",
        "documentNamespace": (
            f"https://github.com/{args.repository}/attestations/"
            f"codex-termux/{args.commit}"
        ),
        "creationInfo": {
            "created": created,
            "creators": ["Tool: codex-termux-pocket/scripts/termux/generate-sbom.py"],
        },
        "packages": spdx_packages,
        "relationships": sorted(
            relationships,
            key=lambda relationship: (
                relationship["spdxElementId"],
                relationship["relationshipType"],
                relationship["relatedSpdxElement"],
            ),
        ),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
