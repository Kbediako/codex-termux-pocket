"""Regression coverage for the package consumed by background-server startup."""

import hashlib
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from termux_release.artifact import verify_archive


class DaemonPackageTests(unittest.TestCase):
    def verify_package(self, version, *, include_rg=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "codex-termux-runtime"
            files = {
                "bin/codex": b"codex executable",
                "bin/codex-code-mode-host": b"code mode executable",
                "bin/codex-responses-api-proxy": b"proxy executable",
                "codex-resources/bwrap": b"bubblewrap executable",
                "codex-package.json": json.dumps(
                    {
                        "layoutVersion": 1,
                        "version": version,
                        "target": "aarch64-unknown-linux-musl",
                        "variant": "primary",
                        "entrypoint": "bin/codex",
                        "resourcesDir": "codex-resources",
                    }
                ).encode(),
            }
            if include_rg:
                files["codex-path/rg"] = b"Termux ripgrep launcher"
            files["runtime-files.sha256"] = "".join(
                f"{hashlib.sha256(data).hexdigest()}  {name}\n"
                for name, data in sorted(files.items())
            ).encode()
            for name, data in files.items():
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                if name not in ("codex-package.json", "runtime-files.sha256"):
                    path.chmod(0o755)
            archive = root / "runtime.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                output.add(runtime, arcname=runtime.name)
            verify_archive(
                archive,
                runtime_size_bytes=sum(map(len, files.values())),
                package_version="0.164.0-alpha.12",
            )

    def test_accepts_exact_package_semver(self):
        self.verify_package("0.164.0-alpha.12")

    def test_rejects_display_banner_and_source_hash(self):
        for version in ("codex-cli 9202678", "9202678", "0.164.0-alpha.11"):
            with self.subTest(version=version), self.assertRaises(SystemExit):
                self.verify_package(version)

    def test_rejects_package_without_required_ripgrep_entrypoint(self):
        with self.assertRaises(SystemExit):
            self.verify_package("0.164.0-alpha.12", include_rg=False)


if __name__ == "__main__":
    unittest.main()
