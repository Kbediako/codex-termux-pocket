"""Additional guards discovered by the existing maintenance test command."""

import copy
import unittest
from unittest.mock import patch

import maintenance as subject


class PrBuildTests(unittest.TestCase):
    """Exercise the bounded dispatcher without network access or PR execution."""

    def setUp(self):
        self.source, self.main, self.tree = "a" * 40, "b" * 40, "c" * 40
        self.branch = "dependabot/cargo/example"
        self.request = {
            "format_version": 1, "request_id": "pr-build.1",
            "operation": "dispatch-pr-build", "pr_number": 7,
            "source_sha": self.source,
        }
        self.pr = {
            "state": "open", "merged": False,
            "head": {"ref": self.branch, "sha": self.source,
                     "repo": {"full_name": "owner/repo"}},
            "base": {"ref": "main", "sha": self.main,
                     "repo": {"full_name": "owner/repo"}},
        }
        self.entries = [{"path": ".github/workflows", "type": "dir", "sha": self.tree}]
        self.run = {
            "id": 123, "head_sha": self.source, "head_branch": self.branch,
            "path": ".github/workflows/termux-mobile-artifact.yml",
            "display_title": f"Termux runtime {self.source}",
            "event": "workflow_dispatch", "status": "queued", "conclusion": None,
        }
        self.inventory = {"total_count": 0, "workflow_runs": []}
        self.after = {"total_count": 1, "workflow_runs": [self.run]}
        self.posts, self.lookups, self.ref_reads = [], 0, 0
        self.ref_sha = self.source
        self.response = None

    def api(self, path, *, method="GET", payload=None):
        if method == "POST":
            self.assertEqual(path, "repos/owner/repo/actions/workflows/termux-mobile-artifact.yml/dispatches")
            self.assertEqual(payload, {"ref": self.branch, "inputs": {"source_ref": self.source}})
            self.posts.append((path, payload))
            return self.response
        self.assertEqual(method, "GET")
        if path.endswith("/pulls/7"):
            return self.pr
        if "/git/ref/heads/" in path:
            self.ref_reads += 1
            return {"object": {"sha": self.ref_sha}}
        if "/contents/.github?ref=" in path:
            return self.entries
        if "/runs?head_sha=" in path:
            self.lookups += 1
            return self.after if self.posts else self.inventory
        self.fail(f"unexpected API operation: {method} {path}")

    def execute(self):
        import contextlib
        import io
        import pr_build

        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output), patch.object(
            subject, "command", return_value=self.tree
        ) as command, patch.object(subject, "live_main") as live:
            pr_build.execute(self.request, "owner/repo", self.main, self.api, live, command)
            command.assert_called_once_with("git", "rev-parse", "HEAD:.github/workflows")
            live.assert_called_with("owner/repo", self.main)

    def test_schema_is_bounded(self):
        self.assertEqual(subject.validate_request(self.request), self.request)
        for changes in (
            {"pr_number": True}, {"pr_number": 0}, {"pr_number": "7"},
            {"source_sha": "main"}, {"source_sha": "0" * 40},
            {"source_sha": "A" * 40}, {"source_sha": None},
            {"workflow": "termux-release-request.yml"}, {"shell": "echo unsafe"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                subject.validate_request(self.request | changes)

    def test_dispatch_is_exact_and_does_not_wait(self):
        self.execute()
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.lookups, 2)
        self.assertIn('"dispatch_accepted": true', self.output.getvalue())
        self.assertIn('"run_id": 123', self.output.getvalue())

    def test_dispatch_accepts_new_api_receipt(self):
        self.response = {"workflow_run_id": 123, "html_url": "https://github.com/owner/repo/actions/runs/123"}
        self.execute()
        self.assertEqual(len(self.posts), 1)
        self.assertIn('"workflow_run_id": 123', self.output.getvalue())

    def test_invisible_accepted_dispatch_is_not_retried(self):
        self.after = {"total_count": 0, "workflow_runs": []}
        self.execute()
        self.assertEqual((len(self.posts), self.lookups), (1, 2))
        self.assertIn('"run_not_yet_visible": true', self.output.getvalue())

    def test_existing_unfinished_or_successful_build_is_reused(self):
        for status, conclusion in (("queued", None), ("in_progress", None), ("completed", "success")):
            with self.subTest(status=status):
                self.run.update(status=status, conclusion=conclusion)
                self.inventory = {"total_count": 1, "workflow_runs": [self.run]}
                self.lookups = 0
                self.execute()
                self.assertEqual(self.posts, [])
                self.assertEqual(self.lookups, 1)
                self.assertIn('"reused_run_id": 123', self.output.getvalue())

    def test_failed_or_cancelled_evidence_is_not_replaced(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped"):
            self.run.update(status="completed", conclusion=conclusion)
            self.inventory = {"total_count": 1, "workflow_runs": [self.run]}
            with self.subTest(conclusion=conclusion), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_incomplete_inventory_fails_before_write(self):
        for total in (1, 101, True, None):
            self.inventory = {"total_count": total, "workflow_runs": []}
            with self.subTest(total=total), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_ambiguous_run_identity_fails_before_write(self):
        for changes in (
            {"head_sha": self.main}, {"head_branch": "main"},
            {"event": "push"}, {"display_title": "Termux runtime another-source"},
            {"path": ".github/workflows/termux-release-request.yml"}, {"id": True},
        ):
            self.inventory = {"total_count": 1, "workflow_runs": [self.run | changes]}
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_closed_foreign_or_changed_pr_fails_before_write(self):
        original = copy.deepcopy(self.pr)
        cases = [
            {"state": "closed"}, {"merged": True},
            {"head": original["head"] | {"sha": self.main}},
            {"head": original["head"] | {"repo": None}},
            {"head": original["head"] | {"repo": {"full_name": "other/repo"}}},
            {"base": original["base"] | {"ref": "release"}},
            {"base": original["base"] | {"repo": {"full_name": "other/repo"}}},
        ]
        for changes in cases:
            self.pr = original | changes
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_unsafe_branch_names_are_rejected(self):
        for branch in ("main", "master", "x//y", "x/.hidden", "x.lock/y", "../x", "x.", "x/", "x\n"):
            self.pr["head"]["ref"] = branch
            with self.subTest(branch=branch), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_workflow_tree_change_is_rejected(self):
        for entries in ([], [{"path": ".github/workflows", "type": "dir", "sha": self.source}],
                        [{"path": ".github/workflows", "type": "symlink", "sha": self.tree}]):
            self.entries = entries
            with self.subTest(entries=entries), self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(self.posts, [])

    def test_moved_branch_and_main_are_rejected(self):
        import pr_build
        self.ref_sha = self.main
        with self.assertRaises(RuntimeError):
            self.execute()
        self.assertEqual(self.posts, [])
        self.ref_sha = self.source
        with patch.object(subject, "command", return_value=self.tree), patch.object(
            subject, "live_main", side_effect=[None, RuntimeError("main moved")]
        ) as live, self.assertRaises(RuntimeError):
            pr_build.execute(self.request, "owner/repo", self.main, self.api, live, subject.command)
        self.assertEqual(self.posts, [])

    def test_pre_dispatch_recheck_rejects_branch_move(self):
        import pr_build
        original_api = self.api
        def api(path, **kwargs):
            if "/git/ref/heads/" in path and self.ref_reads == 1:
                self.ref_sha = self.main
            return original_api(path, **kwargs)
        with self.assertRaises(RuntimeError):
            pr_build.execute(self.request, "owner/repo", self.main, api, lambda *_: None, lambda *_: self.tree)
        self.assertEqual(self.posts, [])
