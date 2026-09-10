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
as `termux-source-export`. It does not modify remote refs. `import-upstream` does
the same and additionally pushes only the unmodified official tag to the fork;
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
