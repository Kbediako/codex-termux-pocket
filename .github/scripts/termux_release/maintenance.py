#!/usr/bin/env python3
"""Owner-committed release maintenance requests; never publish or edit workflows.

This permanent companion to the single publisher exports original Git objects,
records a maintainer-reviewed source merge, schedules the ordinary exact-source
checks, and retires explicitly closed PR branches. Publication remains entirely
in termux_release_control.py and is never an operation of this module.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import quote

REQUEST = "scripts/termux/release-maintenance.json"
PUBLICATION = "scripts/termux/release-publication.env"
SHA = re.compile(r"[0-9a-f]{40}")
TAG = re.compile(r"rust-v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+(?:\.[0-9]+)*")
PRE = ("blocking-ci.yml", "termux-control-plane.yml", "termux-linux-sandbox.yml",
       "termux-mobile-artifact.yml", "termux-android-emulator.yml")
POST = ("termux-release-channel.yml", "termux-governance.yml",
        "termux-control-plane.yml", "blocking-ci.yml")
FIELDS = {
    "export-upstream": {"upstream_tag", "upstream_tag_object", "upstream_commit"},
    "import-upstream": {"upstream_tag", "upstream_tag_object", "upstream_commit"},
    "record-upstream": {"upstream_tag", "upstream_tag_object", "upstream_commit", "prepared_commit"},
    "prepare-source": {"base_main", "prepared_commit", "expected_input_tree", "edits", "package_updates"},
    "dispatch-checks": {"phase"},
    "retire-branches": {"branches"},
}


def command(*args, data=None):
    result = subprocess.run(args, input=data, text=True, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def api(path, *, method="GET", payload=None):
    args = ["gh", "api", "--method", method, path]
    if payload is not None:
        args += ["--input", "-"]
    text = command(*args, data=None if payload is None else json.dumps(payload))
    return json.loads(text) if text else None


def validate_request(value):
    if not isinstance(value, dict) or type(value.get("format_version")) is not int or value["format_version"] != 1:
        raise ValueError("maintenance request must be a format-1 object")
    operation = value.get("operation")
    if operation not in FIELDS:
        raise ValueError("unknown maintenance operation")
    if set(value) != {"format_version", "request_id", "operation"} | FIELDS[operation]:
        raise ValueError("missing or unexpected maintenance fields")
    if not isinstance(value["request_id"], str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", value["request_id"]):
        raise ValueError("invalid request_id")
    for key in ("upstream_commit", "upstream_tag_object", "prepared_commit"):
        if key in value and (not isinstance(value[key], str) or not SHA.fullmatch(value[key])):
            raise ValueError(f"invalid {key}")
    if "upstream_tag" in value and (not isinstance(value["upstream_tag"], str) or not TAG.fullmatch(value["upstream_tag"])):
        raise ValueError("invalid official alpha tag")
    if operation == "prepare-source":
        from source_preparation import validate
        validate(value)
    if operation == "dispatch-checks" and value["phase"] not in ("pre", "post"):
        raise ValueError("phase must be pre or post")
    if operation == "retire-branches":
        branches = value["branches"]
        if not isinstance(branches, list) or not 1 <= len(branches) <= 20:
            raise ValueError("expected 1-20 explicit PR branches")
        names = set()
        for item in branches:
            if not isinstance(item, dict) or set(item) != {"name", "sha", "pr_number"}:
                raise ValueError("branch retirement needs name, sha, and pr_number")
            name = item["name"]
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}", name) or name in ("main", "master"):
                raise ValueError("unsafe branch name")
            if ".." in name or name.endswith(("/", ".lock")) or "//" in name or name in names:
                raise ValueError("unsafe or repeated branch")
            names.add(name)
            if not isinstance(item["sha"], str) or not SHA.fullmatch(item["sha"]):
                raise ValueError("invalid branch SHA")
            if type(item["pr_number"]) is not int or item["pr_number"] <= 0:
                raise ValueError("invalid PR number")
    return value


def route(event_name, changed):
    if event_name == "workflow_dispatch":
        return "publication"
    if event_name != "push":
        raise ValueError("unsupported event")
    maintenance, publication = REQUEST in changed, PUBLICATION in changed
    if maintenance == publication:
        raise ValueError("change exactly one request type per push")
    return "maintenance" if maintenance else "publication"


def live_main(repo, expected):
    if api(f"repos/{repo}/git/ref/heads/main")["object"]["sha"] != expected:
        raise RuntimeError("main moved; refusing a stale maintenance request")


def fetch_upstream(request):
    tag, commit = request["upstream_tag"], request["upstream_commit"]
    release = api(f"repos/openai/codex/releases/tags/{quote(tag, safe='')}")
    if release["draft"] or not release["prerelease"] or release["tag_name"] != tag:
        raise RuntimeError("upstream alpha is not an official public prerelease")
    command("git", "fetch", "--no-tags", "https://github.com/openai/codex.git",
            f"refs/tags/{tag}:refs/tags/{tag}")
    if command("git", "rev-parse", f"refs/tags/{tag}") != request["upstream_tag_object"]:
        raise RuntimeError("upstream annotated tag object changed")
    peeled = command("git", "rev-parse", f"refs/tags/{tag}^{{}}")
    if peeled != commit or command("git", "cat-file", "-t", commit) != "commit":
        raise RuntimeError("upstream tag does not peel to the approved commit")
    return tag, commit


def export_upstream(request, source):
    tag, commit = fetch_upstream(request)
    folder = Path(os.environ["RUNNER_TEMP"]) / "termux-source-export"
    folder.mkdir(exist_ok=False)
    bundle = folder / "source.bundle"
    command("git", "bundle", "create", str(bundle), "HEAD", f"refs/tags/{tag}")
    command("git", "bundle", "verify", str(bundle))
    with bundle.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    receipt = {"source_sha": source, "upstream_tag": tag, "upstream_commit": commit, "upstream_tag_object": request["upstream_tag_object"],
               "bundle_sha256": digest, "bundle_size": bundle.stat().st_size}
    (folder / "identity.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True), flush=True)
    if request["operation"] == "import-upstream":
        # Transfer the unmodified official tag and original Git objects only.
        # This does not check out, rewrite, or update any workflow on main.
        repo = os.environ["GITHUB_REPOSITORY"]
        live_main(repo, source)
        command("gh", "auth", "setup-git")
        command("git", "push", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
        ref = api(f"repos/{repo}/git/ref/tags/{quote(tag, safe='')}")
        if ref["object"]["sha"] != request["upstream_tag_object"]:
            raise RuntimeError("imported official tag identity did not verify")
        if api(f"repos/{repo}/git/commits/{commit}")["sha"] != commit:
            raise RuntimeError("imported official source object is not retrievable")
        print(json.dumps({"imported_upstream_tag": tag, "upstream_commit": commit}), flush=True)


def dispatch_checks(repo, source, phase):
    paths = PRE if phase == "pre" else POST
    for workflow in paths:
        live_main(repo, source)
        endpoint = f"repos/{repo}/actions/workflows/{workflow}/runs?head_sha={source}&per_page=100"
        runs = api(endpoint)["workflow_runs"]
        exact = [run for run in runs if run["head_sha"] == source and
                 run["path"].split("@", 1)[0] == f".github/workflows/{workflow}"]
        reusable = [run for run in exact if run["status"] != "completed" or run["conclusion"] == "success"]
        if reusable:
            print(json.dumps({"workflow": workflow, "reused_run_id": reusable[0]["id"],
                              "status": reusable[0]["status"], "source_sha": source}))
            continue
        if exact:
            raise RuntimeError(f"{workflow} has failed/cancelled exact-source evidence; inspect it before retry")
        inputs = {"source_ref": source} if workflow in ("termux-linux-sandbox.yml", "termux-mobile-artifact.yml") else {}
        api(f"repos/{repo}/actions/workflows/{workflow}/dispatches", method="POST",
            payload={"ref": "main", "inputs": inputs})
        for attempt in range(20):
            time.sleep(2)
            live_main(repo, source)
            runs = api(endpoint)["workflow_runs"]
            found = [run for run in runs if run["head_sha"] == source and
                     run["path"].split("@", 1)[0] == f".github/workflows/{workflow}"]
            if found:
                print(json.dumps({"workflow": workflow, "run_id": found[0]["id"], "source_sha": source}))
                break
        else:
            raise RuntimeError(f"dispatch accepted but {workflow} run not yet visible; do not blindly redispatch")


def record_upstream(request, repo, source):
    prepared = request["prepared_commit"]
    command("git", "merge-base", "--is-ancestor", prepared, source)
    changed = set(command("git", "diff", "--name-only", prepared, source).splitlines())
    if changed != {REQUEST}:
        raise RuntimeError("only the maintenance request may differ from the reviewed prepared commit")
    tag, commit = fetch_upstream(request)
    import tomllib
    package = tomllib.loads(Path("codex-rs/Cargo.toml").read_text())["workspace"]["package"]["version"]
    if package != tag.removeprefix("rust-v"):
        raise RuntimeError("prepared source package version differs from the approved upstream alpha")
    command("cargo", "metadata", "--locked", "--format-version=1", "--manifest-path", "codex-rs/Cargo.toml")
    tree = command("git", "rev-parse", "HEAD^{tree}")
    command("git", "config", "user.name", "github-actions[bot]")
    command("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    message = f"termux: record reviewed upstream ancestry\n\nReviewed prepared source: {prepared}\nUpstream tag: {tag}\nUpstream commit: {commit}\n"
    merged = command("git", "commit-tree", tree, "-p", source, "-p", commit, data=message)
    command("git", "merge-base", "--is-ancestor", commit, merged)
    if command("git", "diff", "--name-only", source, merged):
        raise RuntimeError("ancestry recording must not change any reviewed source bytes")
    live_main(repo, source)
    command("gh", "auth", "setup-git")
    command("git", "push", "origin", f"{merged}:refs/heads/main")
    live_main(repo, merged)
    print(json.dumps({"source_sha": merged, "upstream_commit": commit, "prepared_commit": prepared}))
    dispatch_checks(repo, merged, "pre")


def retire_branches(request, repo):
    # Validate the whole batch before the first deletion. Never delete unreviewed
    # work, a moved head, an open PR's branch, or a branch belonging to a fork.
    for item in request["branches"]:
        pr = api(f"repos/{repo}/pulls/{item['pr_number']}")
        if pr["state"] != "closed" or pr["head"]["ref"] != item["name"] or pr["head"]["sha"] != item["sha"]:
            raise RuntimeError("branch does not match the explicitly closed PR and expected head")
        if pr["head"]["repo"] is None or pr["head"]["repo"]["full_name"] != repo:
            raise RuntimeError("refusing to delete a branch from another repository")
        branches = api(f"repos/{repo}/git/matching-refs/heads/{quote(item['name'], safe='')}")
        exact = [ref for ref in branches if ref["ref"] == f"refs/heads/{item['name']}"]
        if exact and exact[0]["object"]["sha"] != item["sha"]:
            raise RuntimeError("branch moved after review")
    for item in request["branches"]:
        endpoint = f"repos/{repo}/git/matching-refs/heads/{quote(item['name'], safe='')}"
        exact = [ref for ref in api(endpoint) if ref["ref"] == f"refs/heads/{item['name']}"]
        if exact:
            if exact[0]["object"]["sha"] != item["sha"]:
                raise RuntimeError("branch moved before deletion")
            api(f"repos/{repo}/git/refs/heads/{quote(item['name'], safe='')}", method="DELETE")
        if any(ref["ref"] == f"refs/heads/{item['name']}" for ref in api(endpoint)):
            raise RuntimeError("branch deletion was not confirmed")
        print(json.dumps({"absent_branch": item["name"], "expected_sha": item["sha"]}))


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("route", "run"):
        raise ValueError("usage: maintenance.py route|run")
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("maintenance and publication controls require main")
    source, repo = os.environ["GITHUB_SHA"], os.environ["GITHUB_REPOSITORY"]
    if not SHA.fullmatch(source) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid Actions source or repository")
    if command("git", "rev-parse", "HEAD") != source:
        raise ValueError("checkout differs from triggering source")
    if sys.argv[1] == "route":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        before = event.get("before", "")
        changed = set()
        if os.environ["GITHUB_EVENT_NAME"] == "push":
            if not SHA.fullmatch(before) or before == "0" * 40:
                raise ValueError("a normal main push is required")
            command("git", "merge-base", "--is-ancestor", before, source)
            changed = set(command("git", "diff", "--name-only", before, source).splitlines())
        mode = route(os.environ["GITHUB_EVENT_NAME"], changed)
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"mode={mode}\n")
            if mode == "maintenance":
                request = validate_request(json.loads(Path(REQUEST).read_text()))
                output.write(f"operation={request['operation']}\n")
        print(f"request_mode={mode}")
        return
    raw = Path(REQUEST).read_bytes()
    if len(raw) > 32768:
        raise ValueError("maintenance request exceeds 32 KiB")
    request = validate_request(json.loads(raw))
    live_main(repo, source)
    operation = request["operation"]
    if operation in ("export-upstream", "import-upstream"):
        export_upstream(request, source)
    elif operation == "record-upstream":
        record_upstream(request, repo, source)
    elif operation == "prepare-source":
        from source_preparation import execute
        execute(request, repo, source, api, live_main)
    elif operation == "dispatch-checks":
        dispatch_checks(repo, source, request["phase"])
    elif operation == "retire-branches":
        retire_branches(request, repo)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, KeyError) as error:
        print(f"release-maintenance: {error}", file=sys.stderr)
        raise SystemExit(1)
