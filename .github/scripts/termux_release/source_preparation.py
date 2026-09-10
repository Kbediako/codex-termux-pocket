"""Materialize reviewed text edits and regenerate locks without advancing refs."""

import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?")
LOCKS = {"codex-rs/Cargo.lock", "MODULE.bazel.lock"}


def blob_sha(data):
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def safe_path(path):
    if not isinstance(path, str):
        return False
    parts = PurePosixPath(path).parts
    return (path == "AGENTS.md" or (
        path.startswith("codex-rs/") and path.endswith((".rs", ".toml", ".md"))
        and all(part not in (".", "..", ".git", ".github") for part in parts)
        and str(PurePosixPath(path)) == path and "\\" not in path))


def validate(value):
    for name in ("base_main", "prepared_commit", "expected_input_tree"):
        if not isinstance(value[name], str) or not SHA.fullmatch(value[name]):
            raise ValueError(f"invalid {name}")
    edits = value["edits"]
    if not isinstance(edits, list) or not 0 <= len(edits) <= 10:
        raise ValueError("expected at most ten reviewed text edits")
    paths = set()
    for edit in edits:
        if not isinstance(edit, dict) or set(edit) != {"path", "before", "after", "replacements"}:
            raise ValueError("invalid reviewed edit")
        path = edit["path"]
        if not safe_path(path) or path in paths:
            raise ValueError("unsafe or repeated edit path")
        paths.add(path)
        for key in ("before", "after"):
            if not isinstance(edit[key], str) or not SHA.fullmatch(edit[key]):
                raise ValueError("invalid edit blob identity")
        replacements = edit["replacements"]
        if not isinstance(replacements, list) or not 1 <= len(replacements) <= 20:
            raise ValueError("expected 1-20 exact replacements")
        for pair in replacements:
            if (not isinstance(pair, dict) or set(pair) != {"old", "new"}
                    or not all(isinstance(pair[key], str) for key in ("old", "new"))
                    or not pair["old"]):
                raise ValueError("replacement needs nonempty old and literal new text")
    updates = value["package_updates"]
    if not isinstance(updates, list) or not 0 <= len(updates) <= 20:
        raise ValueError("expected at most twenty exact package updates")
    names = set()
    for item in updates:
        if not isinstance(item, dict) or set(item) != {"name", "version"}:
            raise ValueError("invalid package update")
        name = item["name"]
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*(?:@[0-9]+\.[0-9]+\.[0-9]+)?", name)
                or name in names or not isinstance(item["version"], str)
                or not VERSION.fullmatch(item["version"])):
            raise ValueError("unsafe or repeated package update")
        names.add(name)


def apply_edit(data, edit):
    if blob_sha(data) != edit["before"]:
        raise ValueError("reviewed preimage differs")
    text = data.decode("utf-8")
    for pair in edit["replacements"]:
        if text.count(pair["old"]) != 1:
            raise ValueError("reviewed replacement must match exactly once")
        text = text.replace(pair["old"], pair["new"], 1)
    result = text.encode("utf-8")
    if blob_sha(result) != edit["after"]:
        raise ValueError("reviewed postimage differs")
    return result


def execute(request, repo, source, api, live_main):
    validate(request)
    root = Path.cwd()
    folder = Path(os.environ["RUNNER_TEMP"]) / "termux-prepared-source"
    folder.mkdir(exist_ok=False)
    work = Path(os.environ["RUNNER_TEMP"]) / "termux-source-worktree"

    def run(*args, cwd=root):
        print("source-preparation:", " ".join(args), flush=True)
        result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, check=False)
        if result.returncode:
            (folder / "failure.log").write_text(result.stdout)
            print(result.stdout, flush=True)
            raise RuntimeError(f"source preparation command failed: {args[0]}")
        return result.stdout.strip()

    base, prepared = request["base_main"], request["prepared_commit"]
    run("git", "merge-base", "--is-ancestor", base, source)
    if set(run("git", "diff", "--name-only", base, source).splitlines()) != {"scripts/termux/release-maintenance.json"}:
        raise ValueError("only the request may change after the approved base main")
    run("git", "fetch", "--no-tags", "origin", prepared)
    run("git", "merge-base", "--is-ancestor", base, prepared)
    for path in (".github/workflows", ".github/scripts/termux_release"):
        if run("git", "rev-parse", f"{source}:{path}") != run("git", "rev-parse", f"{prepared}:{path}"):
            raise ValueError("prepared workflows or release controls differ from main")
    run("git", "worktree", "add", "--detach", str(work), prepared)
    for edit in request["edits"]:
        path = work / edit["path"]
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(work.resolve()):
            raise ValueError("edit target must be a tracked regular file")
        path.write_bytes(apply_edit(path.read_bytes(), edit))
        run("git", "add", "--", edit["path"], cwd=work)
    if run("git", "write-tree", cwd=work) != request["expected_input_tree"]:
        raise ValueError("complete prepared source tree differs from reviewed input")
    cargo = work / "codex-rs"
    # Resolve the complete graph, including target-specific and git dependencies.
    run("cargo", "metadata", "--format-version=1", cwd=cargo)
    for item in request["package_updates"]:
        run("cargo", "update", "--package", item["name"], "--precise", item["version"], cwd=cargo)
    run("cargo", "metadata", "--locked", "--format-version=1", cwd=cargo)
    run("just", "fmt", cwd=cargo)
    run("just", "bazel-lock-update", cwd=work)
    run("cargo", "metadata", "--locked", "--format-version=1", cwd=cargo)
    import tomllib
    lock = tomllib.loads((cargo / "Cargo.lock").read_text())
    versions = {(item["name"], item["version"]) for item in lock["package"]}
    for item in request["package_updates"]:
        if (item["name"].split("@", 1)[0], item["version"]) not in versions:
            raise ValueError("requested package version is absent from generated lock")
    changed = set(run("git", "diff", "--name-only", prepared, cwd=work).splitlines())
    allowed = LOCKS | {edit["path"] for edit in request["edits"]}
    if not changed <= allowed or run("git", "ls-files", "--others", "--exclude-standard", cwd=work):
        raise ValueError(f"generation changed unapproved paths: {sorted(changed - allowed)}")
    run("git", "diff", "--check", cwd=work)
    run("git", "add", "--", *sorted(changed), cwd=work)
    output_tree = run("git", "write-tree", cwd=work)
    live_main(repo, source)
    records = []
    for name in sorted(changed):
        path = work / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("generated output must be a regular file")
        data = path.read_bytes()
        identity = blob_sha(data)
        result = api(f"repos/{repo}/git/blobs", method="POST",
                     payload={"content": base64.b64encode(data).decode(), "encoding": "base64"})
        if result["sha"] != identity:
            raise ValueError("uploaded blob identity differs from generated bytes")
        destination = folder / "files" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        records.append({"path": name, "sha": identity, "size": len(data)})
    receipt = {"request_sha": source, "prepared_commit": prepared,
               "input_tree": request["expected_input_tree"], "output_tree": output_tree,
               "package_updates": request["package_updates"], "files": records}
    (folder / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True), flush=True)
    # No ref, issue, publication, or manifest promotion mutation is performed.
