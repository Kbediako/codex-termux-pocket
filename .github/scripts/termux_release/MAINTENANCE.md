# Permanent release maintenance requests

The eight-workflow inventory and the release runbook's definition of done are
unchanged. `termux-release-request.yml` now has a separate, permanent
`maintain-release` job implemented by
`.github/scripts/termux_release/maintenance.py`. Its fixed request schema provides
Git-object transport, exact-head workflow dispatch, and closed-PR branch
retirement for maintainers whose connected client exposes Git writes but not all
Actions/ref operations. It is not an alternate publisher or an arbitrary-command
runner. Only `publish-validated-runtime` can publish and promote releases.

Commit `scripts/termux/release-maintenance.json` to `main` with `format_version: 1`,
a unique `request_id`, and one `operation`. Never change the maintenance and
publication request files in the same push: the router rejects ambiguity. A
manual dispatch of the publisher retains its existing publication meaning.
Every maintenance operation refuses a checkout or live `main` different from the
triggering commit. Do not move `main` while an operation or its exact-source gate
set is running.

`export-upstream` requires `upstream_tag`, `upstream_tag_object`, and
`upstream_commit`. It checks the official public alpha release, fetches the exact
annotated tag, peels it, and retains a Git bundle plus identity/checksum receipt
as `termux-source-export`. It also stages original non-workflow file blobs that
are not reachable from the triggering main, using bounded Git-data writes with
independently computed blob and batch-tree hashes. `source-objects.json` records
the exact staged objects. UTF-8 blobs are batched in unreferenced flat trees;
binary blobs use the blob endpoint. No commit, ref, checkout, workflow file,
publication or promoted manifest is changed. The limits are 2,000 blobs, 8 MiB
per blob and 64 MiB total; a moved main or mismatched hash fails closed.

These stored objects are transport only, not an integrated or validated source.
A maintainer must review the actual merge, construct its complete tree through
direct Git writes and use the ordinary preparation process. `record-upstream`
still records the original upstream commit only after source review. A retry may
recreate identical unreferenced objects but must never substitute this receipt
for the five exact-source gates. This path avoids requiring permission to push
an upstream tag containing foreign workflow YAML.

`export-upstream` does not modify remote refs. `import-upstream` retains the
bundle and additionally pushes only the unmodified official tag to the fork;
it fails rather than forcing a conflicting tag or weakening permissions. Neither
operation rewrites workflow files or changes the runtime on `main`.

`record-upstream` additionally requires a `prepared_commit`: a maintainer must
first inspect and commit the complete resolved source tree through direct Git
writes. Only the request file may differ from that reviewed commit. The job
checks package identity and locked metadata, retains the prepared bytes exactly,
records the official upstream commit as a merge parent, proves ancestry,
fast-forwards `main`, and dispatches all five permanent pre-publication gates.
This operation is not a merge-conflict resolver and does not certify an
unreviewed source tree. Prefer an ordinary direct two-parent merge when the
original upstream objects are already available to the connected client.

`dispatch-checks` requires `phase: "pre"` or `phase: "post"`. It dispatches the
runbook's five pre-publication or four post-promotion permanent workflows against
its exact current `main`. It does not duplicate an existing queued/running or
successful exact-source run, and it refuses to silently replace failed evidence.
Returned run IDs must still be inspected for all required jobs, artifacts and
final conclusions. Dispatch success is never gate success.

`retire-branches` requires `branches`, a list of objects with `name`, exact `sha`,
and `pr_number`. The job verifies every PR is closed, belongs to this repository,
and matches its branch/head before any deletion. It refuses protected default
branch names, moved heads, or open PRs and re-reads refs after deleting. Closing a
proposal as unmerged is a maintainer decision, not an automatic cleanup policy.

The maintenance job has contents/Actions write permissions but no attestation or
OIDC permission. The request router is read-only; publication retains its former
job-scoped permissions and unchanged prepare/attest/draft/public-audit/promote
steps. All YAML changes remain direct maintainer writes. No disposable workflow,
issue trigger, staging branch, or injected startup helper is required.

Run the offline guard tests with:

    python3 -m unittest discover -s .github/scripts/termux_release -p test_maintenance.py

The router and Fork CI execute these tests. The original workflow-topology
validator and every existing release check remain enabled without relaxed rules.

## Reviewed source preparation

`prepare-source` accepts `base_main`, `prepared_commit`, `expected_input_tree`,
`edits` and `package_updates`. The prepared commit must descend from base_main;
only the request can have changed on main since that base. Its workflow and
release-control trees must exactly match the triggering main. Each bounded text
edit names a Rust/Markdown/TOML file, pre/post Git blob hashes, and literal
replacements that each match exactly once. The entire resulting input tree is
hash-checked before any dependency command runs. No workflow edits are allowed.

The job runs full Cargo resolution, explicit package/version updates, `just fmt`,
and `just bazel-lock-update`, then verifies locked metadata and requested package
versions. Only reviewed edit paths and the two generated lockfiles may change.
The output files are stored as unreferenced Git blobs and retained with a receipt
in `termux-prepared-source`. A maintainer must independently review these bytes
and create the final source commit through direct Git writes. This operation
never advances refs, publishes, promotes, or closes issues. The ordinary five
exact-source runtime gates are still mandatory after source selection.

## Pinned pre-merge production builds

`dispatch-pr-build` accepts only `pr_number` and `source_sha` in addition to the
format, request ID and operation. Commit the request to main through the normal
maintainer path. The existing read-only router runs the maintenance guard tests
before the bounded maintenance job can execute it.

This operation starts only `termux-mobile-artifact.yml`. The PR must be open,
owned by this repository, and target main. Its current head and actual branch ref
must both equal the full reviewed source SHA. Its entire workflow-definition tree
must match the trusted controller checkout. The controller never checks out or
executes candidate code. The build itself executes the explicitly reviewed source
on the existing hosted runner, with the existing workflow permissions unchanged.

Before dispatch, require a complete exact-source run inventory. Reuse a matching
unfinished or successful build; refuse failed/cancelled or ambiguous existing
evidence instead of silently replacing it. Recheck main and the PR head/ref
immediately before the sole dispatch. The ref is the resolved PR branch and
`source_ref` is the exact SHA, so the run and artifact identities can be inspected
without merging the PR. Main-only release gate dispatch remains unchanged.

Record dispatch acceptance in the job log before attempting readback. Recheck
main/head, then perform one immediate run-list lookup, with no sleeping or
polling. An accepted dispatch whose run is not yet visible is not resubmitted;
on the next resume, locate it by its pinned source and workflow. A failed lookup
or moved ref after acceptance must likewise be investigated before any retry.
Do not advance main or the candidate while this validation is unresolved.

The receipt is scheduling evidence only. Independently inspect the actual run,
required build/validation steps and retained checksums, metadata, SBOM and payload.
It does not approve a merge, provide affected-consumer coverage, or replace the
final dependency source's five runtime gates. No release, manifest, tag, branch,
issue or workflow file is mutated by this operation. Retrying a failed build
requires log inspection and the ordinary explicit Actions retry operation.
