"""Offline coverage for bounded, explicitly incomplete source transport batches."""

import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import maintenance
import source_object_batch as subject
import source_objects as objects


class SourceObjectBatchTests(unittest.TestCase):
    def setUp(self):
        self.base, self.source, self.upstream = (char * 40 for char in "abc")
        self.data = {}
        self.entries = []
        for path, data, mode in (
            ("codex-rs/a.rs", b"first text\n", b"100644"),
            ("codex-rs/z.rs", b"second text\n", b"100644"),
            ("codex-rs/fixture.bin", b"\xff\0\x80", b"100755"),
            ("codex-rs/alias.rs", b"first text\n", b"120000"),
            ("codex-rs/known.rs", b"known\n", b"100644"),
            (".github/workflows/foreign.yml", b"never transport\n", b"100644"),
        ):
            sha = objects.object_sha("blob", data)
            self.data[sha] = data
            self.entries.append((mode, b"blob", sha.encode(), len(data), path.encode()))
        self.known = objects.object_sha("blob", b"known\n").encode()
        self.foreign = objects.object_sha("blob", b"never transport\n")
        self.entries.append((b"160000", b"commit", b"d" * 40, "-", b"submodule"))
        self.git_patch = patch.object(objects, "git_bytes", side_effect=self.git)
        self.git_patch.start()
        self.addCleanup(self.git_patch.stop)
        self.manifest, self.digest, self.total = subject.inventory(
            self.base, self.upstream
        )
        self.api = Mock(side_effect=self.respond)
        self.live = Mock()

    def git(self, *args):
        if args[:2] == ("cat-file", "-t"):
            return b"commit\n"
        if args[:2] == ("merge-base", "--is-ancestor"):
            self.assertEqual(args[2:], (self.base, self.source))
            return b""
        if args[0] == "rev-list":
            return self.known + b"\n"
        if args[0] == "ls-tree":
            return b"".join(
                mode
                + b" "
                + kind
                + b" "
                + sha
                + (b" " + str(size).encode() if "-l" in args else b"")
                + b"\t"
                + path
                + b"\0"
                for mode, kind, sha, size, path in self.entries
            )
        if args[:2] == ("cat-file", "blob"):
            return self.data[args[2]]
        self.fail(f"unexpected Git operation: {args}")

    def respond(self, path, *, method, payload):
        self.assertEqual(method, "POST")
        if path == "repos/owner/repo/git/blobs":
            data = base64.b64decode(payload["content"], validate=True)
            sha = objects.object_sha("blob", data)
            self.assertEqual(data, self.data[sha])
            return {"sha": sha}
        self.assertEqual(path, "repos/owner/repo/git/trees")
        result, raw = [], b""
        for entry in sorted(payload["tree"], key=lambda item: item["path"]):
            sha = objects.object_sha("blob", entry["content"].encode())
            self.assertEqual(entry["path"], sha)
            self.assertEqual(entry["content"].encode(), self.data[sha])
            raw += b"100644 " + sha.encode() + b"\0" + bytes.fromhex(sha)
            result.append({"path": sha, "sha": sha, "mode": "100644", "type": "blob"})
        return {"sha": objects.object_sha("tree", raw), "tree": result}

    def batch(self, offset=0, count=2):
        return {
            "base_source_sha": self.base,
            "inventory_sha256": self.digest,
            "offset": offset,
            "count": count,
        }

    def stage(self, batch):
        return objects.stage(
            "owner/repo",
            self.source,
            self.upstream,
            self.api,
            self.live,
            object_batch=batch,
        )

    def test_exact_slices_cover_inventory_without_relaxing_original_guard(self):
        with patch.object(objects, "MAX_BLOBS", 2):
            with self.assertRaises(ValueError):
                objects.stage(
                    "owner/repo", self.source, self.upstream, self.api, self.live
                )
            self.api.assert_not_called()
            first, last = self.stage(self.batch()), self.stage(self.batch(2, 1))
        self.assertEqual(first["blobs"] + last["blobs"], self.manifest["blobs"])
        self.assertEqual(first["inventory"], last["inventory"])
        self.assertEqual(first["batch"]["next_offset"], 2)
        self.assertIsNone(last["batch"]["next_offset"])
        for receipt in (first, last):
            self.assertEqual(receipt["scope"], "batch")
            self.assertFalse(receipt["batch"]["covers_full_inventory"])
            self.assertEqual(receipt["source_sha"], self.source)
            self.assertEqual(receipt["batch"]["inventory_total_bytes"], self.total)
        self.assertNotIn(
            self.foreign,
            {blob["sha"] for blob in first["blobs"] + last["blobs"]},
        )

    def test_manifest_is_canonical_and_deduplicates_aliases(self):
        encoded = json.dumps(
            self.manifest, sort_keys=True, separators=(",", ":")
        ).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), self.digest)
        self.assertEqual(len(self.manifest["blobs"]), 3)
        first_sha = objects.object_sha("blob", b"first text\n")
        first = next(
            item for item in self.manifest["blobs"] if item["sha"] == first_sha
        )
        self.assertEqual(first["paths"], ["codex-rs/a.rs", "codex-rs/alias.rs"])
        self.entries.reverse()
        self.assertEqual(
            subject.inventory(self.base, self.upstream),
            (self.manifest, self.digest, self.total),
        )

    def test_range_and_digest_fail_before_writes(self):
        for change in (
            {"inventory_sha256": "0" * 64},
            {"offset": 3, "count": 1},
            {"offset": 2, "count": 2},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.stage(self.batch() | change)
            self.api.assert_not_called()

    def test_unselected_bytes_and_metadata_are_still_bounded(self):
        for module, limit, value in (
            (objects, "MAX_BLOB_BYTES", 1),
            (objects, "MAX_TOTAL_BYTES", self.total - 1),
            (subject, "MAX_INVENTORY_BYTES", 1),
        ):
            with self.subTest(limit=limit), patch.object(module, limit, value):
                with self.assertRaises(ValueError):
                    self.stage(self.batch(0, 1))
            self.api.assert_not_called()

    def test_selected_hash_and_size_are_checked_before_any_write(self):
        sha = self.manifest["blobs"][1]["sha"]
        original = self.data[sha]
        for bad in (b"x" * len(original), original + b"x"):
            self.data[sha] = bad
            with self.assertRaises(ValueError):
                self.stage(self.batch())
            self.api.assert_not_called()

    def test_baseline_must_be_a_commit_and_an_ancestor(self):
        with patch.object(objects, "git_bytes", return_value=b"tree\n"):
            with self.assertRaises(ValueError):
                self.stage(self.batch())
        with patch.object(
            objects, "git_bytes", side_effect=RuntimeError("not ancestor")
        ):
            with self.assertRaises(RuntimeError):
                self.stage(self.batch())
        self.api.assert_not_called()

    def test_unsupported_modes_fail_before_writes(self):
        mode, kind, sha, size, path = self.entries[0]
        self.entries[0] = (b"100600", kind, sha, size, path)
        with self.assertRaises(ValueError):
            self.stage(self.batch())
        self.api.assert_not_called()

    def test_stale_main_and_remote_mismatch_keep_existing_guards(self):
        self.live.side_effect = RuntimeError("main moved")
        with self.assertRaises(RuntimeError):
            self.stage(self.batch())
        self.api.assert_not_called()
        self.live.side_effect = None
        self.api.side_effect = None
        self.api.return_value = {"sha": "0" * 40, "tree": []}
        with self.assertRaises(ValueError):
            self.stage(self.batch())

    def test_retries_are_identical_but_do_not_certify_prior_slices(self):
        first = self.stage(self.batch(2, 1))
        self.assertEqual(first, self.stage(self.batch(2, 1)))
        self.assertFalse(first["batch"]["covers_full_inventory"])
        self.assertTrue(self.stage(self.batch(0, 3))["batch"]["covers_full_inventory"])

    def test_request_schema_allows_batch_only_for_export(self):
        request = {
            "format_version": 1,
            "request_id": "batch.1",
            "operation": "export-upstream",
            "upstream_tag": "rust-v0.163.0-alpha.5",
            "upstream_tag_object": "d" * 40,
            "upstream_commit": self.upstream,
            "object_batch": self.batch(),
        }
        self.assertEqual(maintenance.validate_request(request), request)
        for batch in (None, {}, self.batch() | {"shell": "no"}):
            with self.subTest(batch=batch), self.assertRaises(ValueError):
                maintenance.validate_request(request | {"object_batch": batch})
        for operation in ("import-upstream", "record-upstream", "dispatch-checks"):
            with self.subTest(operation=operation), self.assertRaises(ValueError):
                maintenance.validate_request(request | {"operation": operation})
        for change in (
            {"base_source_sha": "main"},
            {"inventory_sha256": "G" * 64},
            {"offset": True},
            {"offset": -1},
            {"count": True},
            {"count": 0},
            {"count": objects.MAX_BLOBS + 1},
            {"count": 1.0},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                maintenance.validate_request(
                    request | {"object_batch": self.batch() | change}
                )

    def test_export_forwards_batch_and_retains_partial_receipt(self):
        request = {
            "operation": "export-upstream",
            "upstream_tag_object": "d" * 40,
            "object_batch": self.batch(),
        }
        receipt = self.stage(self.batch())
        with tempfile.TemporaryDirectory() as folder:

            def command(*args):
                if args[:3] == ("git", "bundle", "create"):
                    Path(args[3]).write_bytes(b"test bundle")
                return ""

            with (
                patch.dict(
                    "os.environ",
                    {"RUNNER_TEMP": folder, "GITHUB_REPOSITORY": "owner/repo"},
                ),
                patch.object(
                    maintenance,
                    "fetch_upstream",
                    return_value=("rust-v0.163.0-alpha.5", self.upstream),
                ),
                patch.object(maintenance, "command", side_effect=command),
                patch.object(objects, "stage", return_value=receipt) as stage,
            ):
                maintenance.export_upstream(request, self.source)
            self.assertEqual(stage.call_args.kwargs, {"object_batch": self.batch()})
            retained = json.loads(
                (Path(folder) / "termux-source-export/source-objects.json").read_text()
            )
            self.assertEqual(retained, receipt)
