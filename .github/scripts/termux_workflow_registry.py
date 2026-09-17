#!/usr/bin/env python3
"""Collect read-only Actions registry evidence; never authorize a release."""

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

MAX_BYTES = 2 * 1024 * 1024
MAX_ITEMS = 2000
ACTIVE_STATUSES = ("queued", "in_progress", "waiting", "pending", "requested")
ROUTE = re.compile(
    r"/actions/(?:workflows(?:/[1-9][0-9]*)?|runs\?status="
    r"(?:queued|in_progress|waiting|pending|requested))"
    r"(?:[?&]per_page=100&page=[1-9][0-9]*)?"
)


class AuditError(RuntimeError):
    """Evidence could not be collected completely and must not be accepted."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep the read token on the exact GitHub API endpoint."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def positive_id(value):
    if type(value) is not int or value <= 0:
        raise AuditError(f"invalid GitHub object ID: {value!r}")
    return value


class GitHubReads:
    """Bounded GET-only client; retained evidence never contains request headers."""

    def __init__(self, repo, token, responses):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise AuditError("invalid repository identity")
        if not token:
            raise AuditError("GH_TOKEN is required for authenticated registry evidence")
        self.repo = repo
        self.token = token
        self.responses = responses
        self.opener = urllib.request.build_opener(NoRedirect())

    def get(self, route):
        if not ROUTE.fullmatch(route):
            raise AuditError("unsupported registry read route")
        url = f"https://api.github.com/repos/{self.repo}{route}"
        record = {"url": url, "status": None, "body": None}
        self.responses.append(record)
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "codex-termux-workflow-registry-audit",
            },
        )
        try:
            response = self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            record["status"] = response.code
            record["date"] = response.headers.get("Date")
            record["request_id"] = response.headers.get("X-GitHub-Request-Id")
            raw = response.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise AuditError("GitHub response exceeded the evidence size limit")
        try:
            record["body"] = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AuditError("GitHub returned invalid JSON") from exc
        return record


def collection(client, route, key):
    """Read every page once; reject truncation, duplicates and changing totals."""
    items = []
    seen = set()
    expected = None
    for page in range(1, MAX_ITEMS // 100 + 2):
        separator = "&" if "?" in route else "?"
        response = client.get(f"{route}{separator}per_page=100&page={page}")
        body = response["body"]
        if response["status"] != 200 or not isinstance(body, dict):
            raise AuditError(f"collection {route}: HTTP {response['status']}")
        total = body.get("total_count")
        batch = body.get(key)
        if type(total) is not int or not 0 <= total <= MAX_ITEMS:
            raise AuditError(f"collection {route}: invalid or excessive total")
        if expected is not None and total != expected:
            raise AuditError(f"collection {route}: changed during pagination")
        expected = total
        if not isinstance(batch, list) or len(batch) > 100:
            raise AuditError(f"collection {route}: invalid page")
        for item in batch:
            if not isinstance(item, dict):
                raise AuditError(f"collection {route}: invalid object")
            identity = positive_id(item.get("id"))
            if identity in seen:
                raise AuditError(f"collection {route}: duplicate ID {identity}")
            seen.add(identity)
            items.append(item)
        if len(batch) < 100 or len(items) >= expected:
            if len(items) != expected:
                raise AuditError(f"collection {route}: incomplete inventory")
            return items
    raise AuditError(f"collection {route}: page limit exceeded")


def collect(client, workflow_dir, report):
    paths = sorted(
        f".github/workflows/{path.name}"
        for path in workflow_dir.iterdir()
        if path.is_file() and path.suffix in {".yml", ".yaml"}
    )
    if not paths:
        raise AuditError("checkout contains no workflow YAML")
    report["workflow_files"] = paths
    workflows = collection(client, "/actions/workflows", "workflows")
    report["registered_workflows"] = workflows
    runs = report["unfinished_runs"] = {}
    for status in ACTIVE_STATUSES:
        runs[status] = collection(
            client, f"/actions/runs?status={status}", "workflow_runs"
        )
    # Obtain exact metadata for every observed identity whose file is absent.
    # An identity returned by the registry remains present even if disabled.
    missing = {
        positive_id(item["id"]) for item in workflows if item.get("path") not in paths
    }
    for batch in runs.values():
        missing.update(
            positive_id(item.get("workflow_id"))
            for item in batch
            if item.get("path") not in paths
        )
    if len(missing) > 100:
        raise AuditError(
            "too many missing-file workflow identities for one bounded audit"
        )
    lookups = report["missing_file_workflow_lookups"] = {}
    for identity in sorted(missing):
        response = client.get(f"/actions/workflows/{identity}")
        lookups[str(identity)] = response
        if response["status"] not in {200, 404}:
            raise AuditError(f"workflow {identity}: HTTP {response['status']}")
        if response["status"] == 200:
            body = response["body"]
            if not isinstance(body, dict) or body.get("id") != identity:
                raise AuditError(f"workflow {identity}: mismatched response identity")
    report["collection_complete"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {
        "format_version": 1,
        "purpose": "evidence-only-not-release-approval",
        "repository": os.environ.get("GITHUB_REPOSITORY", ""),
        "audit_sha": os.environ.get("GITHUB_SHA", ""),
        "audit_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "collection_complete": False,
        "responses": [],
    }
    result = 0
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", report["audit_sha"]):
            raise AuditError("GITHUB_SHA must identify the exact audit checkout")
        client = GitHubReads(
            report["repository"], os.environ.get("GH_TOKEN"), report["responses"]
        )
        collect(client, Path(__file__).resolve().parents[1] / "workflows", report)
    except (AuditError, OSError, urllib.error.URLError) as exc:
        report["error"] = str(exc)
        result = 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"workflow-registry: collection_complete={report['collection_complete']}; {args.output}"
    )
    if result:
        print(f"workflow-registry: {report['error']}", file=sys.stderr)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
