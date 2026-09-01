"""GitHub API, workflow-run, release, and attestation helpers."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from .common import (
    API_VERSION, ARTIFACT_NAME, PUBLISHER_WORKFLOW_PATH, RELEASE_ASSETS,
    REQUIRED_RUN_JOBS, RUN_PATHS, SHA_RE, fail, file_sha256, require_token, run,
)

def api_url(repo: str, path: str) -> str:
    return f"https://api.github.com/repos/{repo}{path}"

def request_bytes(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    authenticated: bool = False,
    attempts: int = 1,
) -> tuple[bytes, Any]:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    last_error = ""
    for attempt in range(1, attempts + 1):
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "codex-termux-release-control",
            "X-GitHub-Api-Version": API_VERSION,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        if authenticated:
            headers["Authorization"] = f"Bearer {require_token()}"
        request = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return response.read(), response.headers
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", "replace")
            last_error = f"HTTP {exc.code}: {error_body[:1000]}"
            if exc.code not in {404, 409, 429, 500, 502, 503, 504} or attempt == attempts:
                fail(f"GitHub request failed for {url}: {last_error}")
        except urllib.error.URLError as exc:
            last_error = str(exc)
            if attempt == attempts:
                fail(f"GitHub request failed for {url}: {last_error}")
        time.sleep(min(2 * attempt, 10))
    fail(f"GitHub request failed for {url}: {last_error}")

def request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    authenticated: bool = False,
    attempts: int = 1,
) -> Any:
    content, _ = request_bytes(
        url,
        method=method,
        payload=payload,
        authenticated=authenticated,
        attempts=attempts,
    )
    try:
        return json.loads(content)
    except json.JSONDecodeError as exc:
        fail(f"GitHub returned invalid JSON for {url}: {exc}")

def request_json_optional(url: str, *, authenticated: bool = False) -> Any | None:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "codex-termux-release-control",
        "X-GitHub-Api-Version": API_VERSION,
    }
    if authenticated:
        headers["Authorization"] = f"Bearer {require_token()}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        error_body = exc.read().decode("utf-8", "replace")
        fail(f"GitHub request failed for {url}: HTTP {exc.code}: {error_body[:1000]}")
    except urllib.error.URLError as exc:
        fail(f"GitHub request failed for {url}: {exc}")

def download_anonymous(url: str, output: Path, *, attempts: int = 8) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_name(output.name + ".part")
    last_error = ""
    for attempt in range(1, attempts + 1):
        partial.unlink(missing_ok=True)
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "codex-termux-anonymous-release-audit"},
        )
        try:
            with urllib.request.urlopen(request, timeout=300) as response, partial.open("wb") as handle:
                shutil.copyfileobj(response, handle, length=1024 * 1024)
            partial.replace(output)
            return
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            last_error = str(exc)
            if attempt == attempts:
                fail(f"anonymous download failed for {url}: {last_error}")
            time.sleep(min(2 * attempt, 10))
    fail(f"anonymous download failed for {url}: {last_error}")

def paginated_items(repo: str, path: str, key: str) -> list[dict[str, Any]]:
    page = 1
    items: list[dict[str, Any]] = []
    while True:
        separator = "&" if "?" in path else "?"
        response = request_json(
            api_url(repo, f"{path}{separator}per_page=100&page={page}"),
            authenticated=True,
        )
        batch = response.get(key)
        if not isinstance(batch, list):
            fail(f"GitHub response for {path} has no {key} list")
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1

def verify_run(
    repo: str,
    *,
    field: str,
    run_id: int,
    source_sha: str,
) -> dict[str, Any]:
    expected_path = RUN_PATHS[field]
    run_data = request_json(
        api_url(repo, f"/actions/runs/{run_id}"),
        authenticated=True,
    )
    checks = {
        "head_sha": source_sha,
        "path": expected_path,
        "status": "completed",
        "conclusion": "success",
    }
    for key, expected in checks.items():
        actual = run_data.get(key)
        if actual != expected:
            fail(f"{field} {run_id} has {key}={actual!r}, expected {expected!r}")
    if field == "fork_ci_run_id" and run_data.get("event") == "issues":
        fail("Fork CI evidence may not come from a maintenance issue trigger")

    required_jobs = REQUIRED_RUN_JOBS.get(field)
    if required_jobs:
        jobs = paginated_items(repo, f"/actions/runs/{run_id}/jobs", "jobs")
        successful_names = {
            str(job.get("name"))
            for job in jobs
            if job.get("status") == "completed" and job.get("conclusion") == "success"
        }
        missing = required_jobs - successful_names
        if missing:
            fail(f"{field} {run_id} is missing successful jobs: {sorted(missing)}")
        duplicates = {
            name
            for name in required_jobs
            if sum(1 for job in jobs if job.get("name") == name) != 1
        }
        if duplicates:
            fail(f"{field} {run_id} has duplicate or ambiguous required jobs: {sorted(duplicates)}")
    return run_data

def release_assets_by_name(release: dict[str, Any]) -> dict[str, dict[str, Any]]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("GitHub release assets are malformed")
    result: dict[str, dict[str, Any]] = {}
    for asset in assets:
        name = asset.get("name")
        if not isinstance(name, str) or name in result:
            fail("GitHub release contains malformed or duplicate asset names")
        result[name] = asset
    return result

def validate_release_object(
    release: dict[str, Any],
    *,
    tag: str,
    source_sha: str,
    require_public: bool,
) -> dict[str, dict[str, Any]]:
    if release.get("tag_name") != tag:
        fail("release tag identity mismatch")
    if release.get("target_commitish") != source_sha:
        fail("release target_commitish mismatch")
    if require_public and (release.get("draft") is not False or release.get("prerelease") is not False):
        fail("release is not a final public release")
    assets = release_assets_by_name(release)
    if set(assets) != set(RELEASE_ASSETS):
        fail(
            "release asset set mismatch; "
            f"missing={sorted(set(RELEASE_ASSETS) - assets.keys())}, "
            f"unexpected={sorted(assets.keys() - set(RELEASE_ASSETS))}"
        )
    return assets

def upload_release_asset(upload_url: str, path: Path) -> None:
    token = require_token()
    encoded = urllib.parse.quote(path.name, safe="")
    env = os.environ.copy()
    env["GH_TOKEN"] = token
    run(
        [
            "gh",
            "api",
            "--method",
            "POST",
            f"{upload_url}?name={encoded}",
            "--header",
            "Content-Type: application/octet-stream",
            "--input",
            str(path),
        ],
        capture=False,
        env=env,
    )

def public_release_ready(repo: str, tag: str) -> tuple[dict[str, Any], dict[str, Any]]:
    encoded = urllib.parse.quote(tag, safe="")
    last_problem = ""
    for attempt in range(1, 13):
        release = request_json(
            api_url(repo, f"/releases/tags/{encoded}"),
            authenticated=False,
            attempts=3,
        )
        latest = request_json(api_url(repo, "/releases/latest"), authenticated=False, attempts=3)
        try:
            assets = release_assets_by_name(release)
            complete = set(assets) == set(RELEASE_ASSETS)
            digests_ready = complete and all(
                isinstance(asset.get("digest"), str)
                and re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"])
                and isinstance(asset.get("size"), int)
                and asset["size"] > 0
                for asset in assets.values()
            )
            latest_ready = latest.get("tag_name") == tag and latest.get("id") == release.get("id")
            if complete and digests_ready and latest_ready:
                return release, latest
            last_problem = (
                f"complete={complete}, digests_ready={digests_ready}, latest_ready={latest_ready}"
            )
        except (KeyError, TypeError) as exc:
            last_problem = str(exc)
        time.sleep(min(2 * attempt, 10))
    fail(f"public release metadata did not become complete: {last_problem}")

def peel_tag_ref(repo: str, tag: str) -> str:
    encoded = urllib.parse.quote(tag, safe="")
    ref = request_json(api_url(repo, f"/git/ref/tags/{encoded}"), authenticated=False, attempts=4)
    obj = ref.get("object")
    for _ in range(8):
        if not isinstance(obj, dict):
            fail("release tag ref object is malformed")
        if obj.get("type") == "commit":
            sha = obj.get("sha")
            if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
                fail("release tag resolves to an invalid commit SHA")
            return sha
        if obj.get("type") != "tag" or not isinstance(obj.get("url"), str):
            fail("release tag does not resolve to a commit")
        tag_object = request_json(obj["url"], authenticated=False, attempts=4)
        obj = tag_object.get("object")
    fail("release tag contains an unexpectedly deep tag-object chain")

def verify_attestations(root: Path, *, repo: str) -> None:
    signer = f"{repo}/{PUBLISHER_WORKFLOW_PATH}"
    token = require_token()
    env = os.environ.copy()
    env["GH_TOKEN"] = token
    pending = set(RELEASE_ASSETS)
    diagnostics = ""
    for attempt in range(1, 13):
        failed: set[str] = set()
        messages: list[str] = []
        for name in sorted(pending):
            completed = subprocess.run(
                [
                    "gh",
                    "attestation",
                    "verify",
                    str(root / name),
                    "--repo",
                    repo,
                    "--signer-workflow",
                    signer,
                ],
                check=False,
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                env=env,
            )
            if completed.returncode != 0:
                failed.add(name)
                messages.append(f"{name}: {(completed.stderr or '').strip()[:500]}")
        if not failed:
            return
        pending = failed
        diagnostics = "; ".join(messages)
        if attempt < 12:
            time.sleep(min(2 * attempt, 10))
    fail(f"publisher attestation verification failed: {diagnostics}")
