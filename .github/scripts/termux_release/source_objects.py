"""Stage original non-workflow blobs for direct maintainer writes; never move refs."""

import base64
import hashlib
import json
import subprocess


MAX_BLOBS = 2000
MAX_BLOB_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_BATCH_BYTES = 2 * 1024 * 1024
MAX_BATCH_BLOBS = 100


def git_bytes(*args):
    result = subprocess.run(
        ["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def object_sha(kind, data):
    return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).hexdigest()


def collect(source, upstream):
    known = set(
        git_bytes("rev-list", "--objects", "--no-object-names", source).splitlines()
    )
    objects = {}
    total = 0
    for entry in git_bytes("ls-tree", "-r", "-z", upstream).split(b"\0"):
        if not entry:
            continue
        header, path = entry.split(b"\t", 1)
        mode, kind, sha = header.split()
        # Transport never installs files. Still exclude workflow file objects
        # entirely so Actions cannot serve as a workflow-editing intermediary.
        if path.startswith(b".github/workflows/") or kind != b"blob" or sha in known:
            continue
        if mode not in (b"100644", b"100755", b"120000"):
            raise ValueError("unsupported upstream file mode")
        name = sha.decode("ascii")
        if name in objects:
            objects[name]["paths"].append(path.decode("utf-8"))
            continue
        if len(objects) >= MAX_BLOBS:
            raise ValueError("upstream blob count exceeds transport limit")
        data = git_bytes("cat-file", "blob", name)
        total += len(data)
        if len(data) > MAX_BLOB_BYTES or total > MAX_TOTAL_BYTES:
            raise ValueError("upstream bytes exceed transport limit")
        if object_sha("blob", data) != name:
            raise ValueError("upstream blob bytes differ from Git identity")
        objects[name] = {
            "sha": name,
            "paths": [path.decode("utf-8")],
            "size": len(data),
            "data": data,
        }
    return sorted(objects.values(), key=lambda item: item["sha"])


def upload_batch(repo, source, entries, api, live_main):
    # Content-addressed flat names cannot name a workflow, branch or release.
    raw_tree = b"".join(
        b"100644 " + entry["path"].encode() + b"\0" + bytes.fromhex(entry["path"])
        for entry in sorted(entries, key=lambda entry: entry["path"])
    )
    expected = object_sha("tree", raw_tree)
    live_main(repo, source)
    tree = api(f"repos/{repo}/git/trees", method="POST", payload={"tree": entries})
    actual = tree.get("tree", [])
    wanted = {entry["path"] for entry in entries}
    if (
        tree.get("sha") != expected
        or tree.get("truncated")
        or len(actual) != len(wanted)
        or {entry["path"] for entry in actual} != wanted
        or any(
            entry.get("sha") != entry["path"]
            or entry.get("type") != "blob"
            or entry.get("mode") != "100644"
            for entry in actual
        )
    ):
        raise ValueError("staged tree or blob identities differ from original bytes")
    return expected


def stage(repo, source, upstream, api, live_main):
    # Complete bounded local verification before making the first API write.
    objects = collect(source, upstream)
    batches, pending, pending_size = [], [], 0
    for item in objects:
        data, sha = item["data"], item["sha"]
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        entry = {"path": sha, "mode": "100644", "type": "blob", "content": text}
        size = len(json.dumps(entry).encode("utf-8"))
        if text is None or b"\0" in data or size > MAX_BATCH_BYTES:
            live_main(repo, source)
            result = api(
                f"repos/{repo}/git/blobs",
                method="POST",
                payload={
                    "content": base64.b64encode(data).decode(),
                    "encoding": "base64",
                },
            )
            if result.get("sha") != sha:
                raise ValueError("staged binary blob identity differs")
            continue
        if pending and (
            pending_size + size > MAX_BATCH_BYTES or len(pending) >= MAX_BATCH_BLOBS
        ):
            batches.append(upload_batch(repo, source, pending, api, live_main))
            pending, pending_size = [], 0
        pending.append(entry)
        pending_size += size
    if pending:
        batches.append(upload_batch(repo, source, pending, api, live_main))
    live_main(repo, source)
    return {
        "source_sha": source,
        "upstream_commit": upstream,
        "blob_count": len(objects),
        "total_bytes": sum(item["size"] for item in objects),
        "unreferenced_batch_trees": batches,
        "blobs": [
            {key: value for key, value in item.items() if key != "data"}
            for item in objects
        ],
    }
