#!/usr/bin/env python3
"""Executable control plane for exact-source Codex Termux releases."""

from __future__ import annotations

import argparse

from termux_release.publication import audit, promote, publish
from termux_release.request import prepare, self_test, validate_request

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate-request")
    validate_parser.add_argument("--request", default="scripts/termux/release-publication.env")
    validate_parser.set_defaults(func=validate_request)

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--dist", required=True)
    prepare_parser.add_argument("--source-sha", required=True)
    prepare_parser.add_argument("--release-tag", required=True)
    prepare_parser.add_argument("--package-version", required=True)
    prepare_parser.add_argument("--codex-version", required=True)
    prepare_parser.set_defaults(func=prepare)

    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--dist", required=True)
    publish_parser.add_argument("--package-version", required=True)
    publish_parser.set_defaults(func=publish)

    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("--manifest", required=True)
    audit_parser.add_argument("--local-dir")
    audit_parser.add_argument("--verify-attestations", action="store_true")
    audit_parser.add_argument("--receipt")
    audit_parser.set_defaults(func=audit)

    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--manifest", required=True)
    promote_parser.add_argument("--receipt", required=True)
    promote_parser.set_defaults(func=promote)

    self_test_parser = subparsers.add_parser("self-test")
    self_test_parser.set_defaults(func=self_test)
    return parser

def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
