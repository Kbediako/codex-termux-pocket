#!/usr/bin/env python3
"""Run the shared Termux public-release contract against the promoted manifest.

This path is also the permanent push trigger for exact-head post-promotion
release-channel, governance, control-plane, and Fork CI verification. A small
reviewed documentation-only change here can intentionally schedule that complete
read-only verification set after a workflow-token manifest promotion.
"""

from termux_release.publication import public_audit_main


if __name__ == "__main__":
    raise SystemExit(public_audit_main())
