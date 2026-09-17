"""Offline tests for the read-only registry evidence collector."""

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from termux_workflow_registry import ACTIVE_STATUSES, AuditError, GitHubReads, collect, collection


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / "current.yml").write_text("name: current\n", encoding="utf-8")
        self.workflow = {"id": 1, "path": ".github/workflows/current.yml", "state": "active"}

    def client(self, workflows=None, run=None, lookup_status=404):
        entries = [self.workflow] if workflows is None else workflows
        responses = {
            "/actions/workflows?per_page=100&page=1": {
                "status": 200, "body": {"total_count": len(entries), "workflows": entries}
            }
        }
        for status in ACTIVE_STATUSES:
            batch = [run] if run and status == "queued" else []
            responses[f"/actions/runs?status={status}&per_page=100&page=1"] = {
                "status": 200, "body": {"total_count": len(batch), "workflow_runs": batch}
            }
        responses["/actions/workflows/2"] = {
            "status": lookup_status,
            "body": {"id": 2, "state": "disabled_manually"} if lookup_status == 200 else {"message": "Not Found"},
        }
        return Mock(get=Mock(side_effect=lambda route: responses[route]))

    def test_current_inventory_needs_no_missing_identity_lookup(self):
        client = self.client()
        report = {}
        collect(client, self.directory, report)
        self.assertTrue(report["collection_complete"])
        self.assertEqual(report["registered_workflows"], [self.workflow])
        self.assertEqual(report["missing_file_workflow_lookups"], {})
        self.assertEqual(client.get.call_count, 1 + len(ACTIVE_STATUSES))

    def test_orphan_exact_404_is_retained_not_invented(self):
        run = {"id": 9, "workflow_id": 2, "path": ".github/workflows/removed.yml"}
        report = {}
        collect(self.client(run=run), self.directory, report)
        self.assertEqual(report["missing_file_workflow_lookups"]["2"], {
            "status": 404, "body": {"message": "Not Found"}
        })
        self.assertEqual(report["unfinished_runs"]["queued"], [run])
        self.assertTrue(report["collection_complete"])

    def test_disabled_identity_remains_present_and_is_queried_once(self):
        old = {"id": 2, "path": ".github/workflows/removed.yml", "state": "disabled_manually"}
        run = {"id": 9, "workflow_id": 2, "path": old["path"]}
        client = self.client([self.workflow, old], run, 200)
        report = {}
        collect(client, self.directory, report)
        self.assertIn(old, report["registered_workflows"])
        self.assertEqual(report["missing_file_workflow_lookups"]["2"]["status"], 200)
        self.assertEqual(client.get.call_count, 2 + len(ACTIVE_STATUSES))

    def test_denied_exact_lookup_is_not_absence(self):
        run = {"id": 9, "workflow_id": 2, "path": ".github/workflows/removed.yml"}
        report = {"collection_complete": False}
        with self.assertRaisesRegex(AuditError, "HTTP 403"):
            collect(self.client(run=run, lookup_status=403), self.directory, report)
        self.assertFalse(report["collection_complete"])
        self.assertEqual(report["missing_file_workflow_lookups"]["2"]["status"], 403)

    def test_all_pages_are_collected(self):
        entries = [{"id": n} for n in range(1, 103)]
        client = Mock(get=Mock(side_effect=[
            {"status": 200, "body": {"total_count": 102, "workflows": entries[:100]}},
            {"status": 200, "body": {"total_count": 102, "workflows": entries[100:]}},
        ]))
        self.assertEqual(collection(client, "/actions/workflows", "workflows"), entries)
        self.assertEqual(client.get.call_args.args[0], "/actions/workflows?per_page=100&page=2")

    def test_invalid_or_incomplete_collection_fails(self):
        cases = [
            {"status": 404, "body": {"message": "Not Found"}},
            {"status": 200, "body": {"total_count": 2, "workflows": [{"id": 1}]}},
            {"status": 200, "body": {"total_count": 2, "workflows": [{"id": 1}, {"id": 1}]}},
            {"status": 200, "body": {"total_count": 2001, "workflows": []}},
            {"status": 200, "body": {"total_count": 1, "workflows": [{"id": True}]}},
        ]
        for response in cases:
            with self.subTest(response=response), self.assertRaises(AuditError):
                collection(Mock(get=Mock(return_value=response)), "/actions/workflows", "workflows")

    def test_changed_total_fails(self):
        client = Mock(get=Mock(side_effect=[
            {"status": 200, "body": {"total_count": 101, "workflows": [{"id": n} for n in range(1, 101)]}},
            {"status": 200, "body": {"total_count": 100, "workflows": []}},
        ]))
        with self.assertRaisesRegex(AuditError, "changed during pagination"):
            collection(client, "/actions/workflows", "workflows")

    def test_http_transport_is_get_only_and_does_not_retain_token(self):
        records = []
        client = GitHubReads("owner/repo", "private-test-value", records)
        response = io.BytesIO(b'{"id": 2}')
        response.code = 200
        response.headers = {"X-GitHub-Request-Id": "test-request"}
        client.opener = Mock(open=Mock(return_value=response))
        self.assertEqual(client.get("/actions/workflows/2")["status"], 200)
        request = client.opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertNotIn("private-test-value", json.dumps(records))
        self.assertEqual(records[0]["request_id"], "test-request")

    def test_unsupported_routes_and_repository_values_fail_before_network(self):
        for repo in ("owner/repo/extra", "owner/repo?token=x", "https://evil.invalid/repo"):
            with self.subTest(repo=repo), self.assertRaises(AuditError):
                GitHubReads(repo, "test", [])
        client = GitHubReads("owner/repo", "test", [])
        client.opener = Mock()
        for route in ("/actions/workflows/2/disable", "/actions/runs/9/cancel", "/../secrets", "https://evil.invalid"):
            with self.subTest(route=route), self.assertRaises(AuditError):
                client.get(route)
        client.opener.open.assert_not_called()


if __name__ == "__main__":
    unittest.main()
