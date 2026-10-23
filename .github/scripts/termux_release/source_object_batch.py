"""Validate explicit slices of a pinned inventory without relaxing write limits."""

import hashlib
import json
import re

import source_objects as objects


MAX_INVENTORY_BYTES = 2 * 1024 * 1024


def validate(batch):
    if not isinstance(batch, dict) or set(batch) != {
        "base_source_sha",
        "inventory_sha256",
        "offset",
        "count",
    }:
        raise ValueError("object_batch requires a pinned inventory and exact range")
    for key, length in (("base_source_sha", 40), ("inventory_sha256", 64)):
        if not isinstance(batch[key], str) or not re.fullmatch(
            rf"[0-9a-f]{{{length}}}", batch[key]
        ):
            raise ValueError(f"invalid object_batch {key}")
    if type(batch["offset"]) is not int or batch["offset"] < 0:
        raise ValueError("object_batch offset must be a nonnegative integer")
    if type(batch["count"]) is not int or not 1 <= batch["count"] <= objects.MAX_BLOBS:
        raise ValueError("object_batch count exceeds transport limit")


def inventory(base, upstream):
    # The baseline is fixed across requests, not the moving request commit.
    if objects.git_bytes("cat-file", "-t", base).strip() != b"commit":
        raise ValueError("object_batch baseline is not a commit")
    known = set(
        objects.git_bytes(
            "rev-list", "--objects", "--no-object-names", base
        ).splitlines()
    )
    found = {}
    total = 0
    for entry in objects.git_bytes("ls-tree", "-r", "-l", "-z", upstream).split(b"\0"):
        if not entry:
            continue
        header, path = entry.split(b"\t", 1)
        mode, kind, sha, size = header.split()
        if path.startswith(b".github/workflows/") or kind != b"blob" or sha in known:
            continue
        if mode not in (b"100644", b"100755", b"120000"):
            raise ValueError("unsupported upstream file mode")
        name, path, size = sha.decode("ascii"), path.decode("utf-8"), int(size)
        if not re.fullmatch(r"[0-9a-f]{40}", name) or size < 0:
            raise ValueError("invalid upstream blob metadata")
        if name in found:
            if found[name]["size"] != size:
                raise ValueError("inconsistent upstream blob size")
            found[name]["paths"].append(path)
            continue
        total += size
        # These remain whole-inventory bounds, even for a small requested slice.
        if size > objects.MAX_BLOB_BYTES or total > objects.MAX_TOTAL_BYTES:
            raise ValueError("upstream bytes exceed transport limit")
        found[name] = {"sha": name, "paths": [path], "size": size}
    blobs = sorted(found.values(), key=lambda item: item["sha"])
    for item in blobs:
        item["paths"].sort()
    result = {"base_source_sha": base, "upstream_commit": upstream, "blobs": blobs}
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
    if len(encoded) > MAX_INVENTORY_BYTES:
        raise ValueError("upstream inventory metadata exceeds limit")
    return result, hashlib.sha256(encoded).hexdigest(), total


def collect(source, upstream, batch):
    validate(batch)
    base = batch["base_source_sha"]
    objects.git_bytes("merge-base", "--is-ancestor", base, source)
    manifest, digest, total = inventory(base, upstream)
    if digest != batch["inventory_sha256"]:
        raise ValueError("upstream inventory differs from approved digest")
    start, count = batch["offset"], batch["count"]
    end = start + count
    if end > len(manifest["blobs"]):
        raise ValueError("object_batch range exceeds inventory")
    selected = []
    for item in manifest["blobs"][start:end]:
        data = objects.git_bytes("cat-file", "blob", item["sha"])
        if len(data) != item["size"] or objects.object_sha("blob", data) != item["sha"]:
            raise ValueError("upstream blob bytes differ from Git identity")
        selected.append(item | {"data": data})
    # The last slice is not proof that earlier slices were ever transported.
    receipt = {
        "format_version": 2,
        "scope": "batch",
        "inventory": manifest,
        "batch": batch
        | {
            "inventory_blob_count": len(manifest["blobs"]),
            "inventory_total_bytes": total,
            "end_offset": end,
            "next_offset": end if end < len(manifest["blobs"]) else None,
            "covers_full_inventory": start == 0 and end == len(manifest["blobs"]),
        },
    }
    return selected, receipt
