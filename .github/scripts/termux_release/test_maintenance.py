"""Offline tests for release request routing and destructive-operation guards."""

import copy
import unittest
from unittest.mock import patch

import maintenance as subject


class MaintenanceTests(unittest.TestCase):
    def upstream(self):
        return {"format_version": 1, "request_id": "test.1", "operation": "import-upstream",
                "upstream_tag": "rust-v0.154.0-alpha.6.1", "upstream_tag_object": "b" * 40,
                "upstream_commit": "a" * 40}

    def test_pinned_dotted_alpha(self):
        value = self.upstream()
        self.assertEqual(subject.validate_request(value), value)

    def test_rejects_unexpected_fields_and_operations(self):
        for patch_value in ({"shell": "echo unsafe"}, {"operation": "publish"},
                            {"upstream_tag": "../main"}, {"upstream_commit": "main"},
                            {"upstream_tag_object": "short"}, {"request_id": "a\nb"},
                            {"format_version": True}, {"format_version": 2}):
            value = self.upstream() | patch_value
            with self.subTest(value=patch_value), self.assertRaises(ValueError):
                subject.validate_request(value)

    def test_missing_field(self):
        value = self.upstream()
        del value["upstream_commit"]
        with self.assertRaises(ValueError):
            subject.validate_request(value)

    def test_publication_and_maintenance_are_exclusive(self):
        self.assertEqual(subject.route("push", {subject.REQUEST}), "maintenance")
        self.assertEqual(subject.route("push", {subject.PUBLICATION}), "publication")
        self.assertEqual(subject.route("workflow_dispatch", set()), "publication")
        for changed in (set(), {subject.REQUEST, subject.PUBLICATION}):
            with self.assertRaises(ValueError):
                subject.route("push", changed)
        with self.assertRaises(ValueError):
            subject.route("issues", {subject.PUBLICATION})

    def branch_request(self):
        return {"format_version": 1, "request_id": "cleanup.1", "operation": "retire-branches",
                "branches": [{"name": "dependabot/cargo/example", "sha": "a" * 40, "pr_number": 1}]}

    def test_retirement_rejects_unsafe_targets(self):
        for name in ("main", "master", "../main", "refs/heads/../main", "x.lock", "x//y", "-x"):
            value = self.branch_request()
            value["branches"][0]["name"] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                subject.validate_request(value)
        value = self.branch_request()
        value["branches"] *= 2
        with self.assertRaises(ValueError):
            subject.validate_request(value)

    def test_retirement_refuses_open_pr_before_delete(self):
        request = self.branch_request()
        pr = {"state": "open", "head": {"ref": "dependabot/cargo/example", "sha": "a" * 40}}
        with patch.object(subject, "api", return_value=pr) as api:
            with self.assertRaises(RuntimeError):
                subject.retire_branches(request, "owner/repo")
            self.assertEqual(api.call_count, 1)

    def test_retirement_refuses_moved_branch(self):
        request = self.branch_request()
        pr = {"state": "closed", "head": {"ref": "dependabot/cargo/example", "sha": "a" * 40,
                                            "repo": {"full_name": "owner/repo"}}}
        refs = [{"ref": "refs/heads/dependabot/cargo/example", "object": {"sha": "b" * 40}}]
        with patch.object(subject, "api", side_effect=[pr, refs]) as api:
            with self.assertRaises(RuntimeError):
                subject.retire_branches(request, "owner/repo")
            self.assertTrue(all(call.kwargs.get("method", "GET") == "GET" for call in api.call_args_list))

    def test_live_main_rejects_stale_source(self):
        with patch.object(subject, "api", return_value={"object": {"sha": "b" * 40}}):
            with self.assertRaises(RuntimeError):
                subject.live_main("owner/repo", "a" * 40)

    def test_dispatch_reuses_running_exact_source(self):
        source = "a" * 40
        def answer(path, **kwargs):
            self.assertNotIn("method", kwargs)
            if "git/ref/heads/main" in path:
                return {"object": {"sha": source}}
            workflow = path.split("/workflows/")[1].split("/")[0]
            return {"workflow_runs": [{"id": 123, "head_sha": source, "status": "in_progress",
                                       "conclusion": None, "path": ".github/workflows/" + workflow}]}
        with patch.object(subject, "api", side_effect=answer):
            subject.dispatch_checks("owner/repo", source, "post")

    def test_dispatch_preserves_failed_exact_source(self):
        source = "a" * 40
        run = {"id": 123, "head_sha": source, "status": "completed", "conclusion": "failure",
               "path": ".github/workflows/blocking-ci.yml"}
        with patch.object(subject, "api", side_effect=[{"object": {"sha": source}}, {"workflow_runs": [run]}]) as api:
            with self.assertRaises(RuntimeError):
                subject.dispatch_checks("owner/repo", source, "pre")
            self.assertEqual(api.call_count, 2)

    def test_record_rejects_unreviewed_source_changes(self):
        value = self.upstream() | {"operation": "record-upstream", "prepared_commit": "c" * 40}
        with patch.object(subject, "command", side_effect=["", subject.REQUEST + "\ncodex-rs/core/src/lib.rs"]):
            with self.assertRaises(RuntimeError):
                subject.record_upstream(value, "owner/repo", "a" * 40)


if __name__ == "__main__":
    unittest.main()
