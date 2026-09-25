"""Dispatch the permanent build-only workflow for an owner-pinned open PR.

This module never checks out PR code, changes refs, or requests publication.
The maintenance router and its existing main-only guards remain authoritative.
"""

import json
import re
from urllib.parse import quote

WORKFLOW = "termux-mobile-artifact.yml"
WORKFLOW_PATH = f".github/workflows/{WORKFLOW}"


def validate(request):
    if type(request["pr_number"]) is not int or request["pr_number"] <= 0:
        raise ValueError("PR build requires a positive PR number")
    source = request["source_sha"]
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("PR build requires a full source SHA")
    if source == "0" * 40:
        raise ValueError("PR build source cannot be the null SHA")


def checked_branch(request, repo, main_sha, api, live_main):
    live_main(repo, main_sha)
    pr = api(f"repos/{repo}/pulls/{request['pr_number']}")
    head, base = pr["head"], pr["base"]
    if (
        pr["state"] != "open"
        or pr.get("merged", False)
        or not head.get("repo")
        or head["repo"]["full_name"] != repo
        or not base.get("repo")
        or base["repo"]["full_name"] != repo
        or base["ref"] != "main"
        or head["sha"] != request["source_sha"]
    ):
        raise RuntimeError("PR build requires the pinned open same-repository PR")
    branch = head["ref"]
    if (
        not isinstance(branch, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}", branch)
        or branch in ("main", "master")
        or ".." in branch
        or "//" in branch
        or branch.endswith(("/", "."))
        or any(p.startswith(".") or p.endswith(".lock") for p in branch.split("/"))
    ):
        raise RuntimeError("unsafe PR build branch")
    ref = api(f"repos/{repo}/git/ref/heads/{quote(branch, safe='')}")
    if ref["object"]["sha"] != request["source_sha"]:
        raise RuntimeError("PR build branch moved after review")
    return branch


def exact_runs(repo, source, branch, api):
    data = api(
        f"repos/{repo}/actions/workflows/{WORKFLOW}/runs"
        f"?head_sha={source}&per_page=100"
    )
    runs = data["workflow_runs"]
    if (
        not isinstance(runs, list)
        or type(data.get("total_count")) is not int
        or data["total_count"] != len(runs)
        or len(runs) > 100
    ):
        raise RuntimeError("incomplete PR build run inventory; refusing dispatch")
    for run in runs:
        if (
            run["head_sha"] != source
            or run["head_branch"] != branch
            or run["path"].split("@", 1)[0] != WORKFLOW_PATH
            or run["event"] != "workflow_dispatch"
            or run["display_title"] != f"Termux runtime {source}"
            or type(run["id"]) is not int
            or run["id"] <= 0
        ):
            raise RuntimeError("ambiguous PR build run identity; inspect existing runs")
    return sorted(runs, key=lambda run: run["id"], reverse=True)


def execute(request, repo, main_sha, api, live_main, command):
    validate(request)
    branch = checked_branch(request, repo, main_sha, api, live_main)
    # A pinned source is owner-reviewed, but must not introduce foreign workflow
    # definitions or permissions into this privileged dispatch path.
    trusted_tree = command("git", "rev-parse", "HEAD:.github/workflows")
    entries = api(f"repos/{repo}/contents/.github?ref={request['source_sha']}")
    workflows = [entry for entry in entries if entry.get("path") == ".github/workflows"]
    if (
        len(workflows) != 1
        or workflows[0]["type"] != "dir"
        or workflows[0]["sha"] != trusted_tree
    ):
        raise RuntimeError("PR workflow definitions differ from trusted main")
    source = request["source_sha"]
    runs = exact_runs(repo, source, branch, api)
    receipt = {
        "request_id": request["request_id"],
        "controller_sha": main_sha,
        "pr_number": request["pr_number"],
        "source_sha": source,
        "branch": branch,
        "workflow": WORKFLOW,
    }
    if runs:
        run = runs[0]
        if run["status"] == "completed" and run["conclusion"] != "success":
            raise RuntimeError("PR build failed/cancelled; inspect logs before retry")
        print(
            json.dumps(receipt | {"reused_run_id": run["id"], "status": run["status"]}),
            flush=True,
        )
        return
    if checked_branch(request, repo, main_sha, api, live_main) != branch:
        raise RuntimeError("PR branch changed before dispatch")
    result = api(
        f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
        method="POST",
        payload={"ref": branch, "inputs": {"source_ref": source}},
    )
    # Persist acceptance before any readback can fail. Never blindly retry an
    # accepted dispatch, including older API versions that return no run ID.
    print(
        json.dumps(receipt | {"dispatch_accepted": True, "response": result}),
        flush=True,
    )
    if checked_branch(request, repo, main_sha, api, live_main) != branch:
        raise RuntimeError("PR branch changed after dispatch; inspect accepted run")
    runs = exact_runs(repo, source, branch, api)  # One lookup; no sleep or polling.
    if runs:
        print(
            json.dumps(receipt | {"run_id": runs[0]["id"], "status": runs[0]["status"]}),
            flush=True,
        )
    else:
        print(
            json.dumps(receipt | {
                "run_not_yet_visible": True,
                "next_action": "locate accepted run; do not redispatch",
            }),
            flush=True,
        )
