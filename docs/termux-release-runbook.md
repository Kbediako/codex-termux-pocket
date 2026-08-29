# Termux Alpha Release Runbook

This is mandatory reading for any agent or maintainer performing an upstream
alpha sync, repairing Termux CI, publishing a runtime, or declaring a release
complete. It records the release invariants and the failure modes discovered
while publishing the `0.151.0-alpha.*` series.

Treat live GitHub state as authoritative. Do not trust an earlier assistant's
completion claim, a generated verification file, a stale issue body, or an
expected workflow outcome.

## Definition of done

An alpha update is complete only when the live GitHub API proves all of the
following:

1. The newest intended upstream tag was resolved and an annotated tag was peeled
   to its commit.
2. One exact fork source SHA was selected, and the peeled upstream commit is an
   ancestor of that source.
3. The exact source has successful Fork CI, control-plane, Linux sandbox on x64
   and ARM64, production ARM64 artifact, and native Android/Termux runs.
4. The retained production artifact is retrievable and verifies against its
   internal checksums, metadata, SBOM, and expected source identity.
5. The permanent release publisher created the complete release as GitHub
   Latest in its initial draft-to-public transaction.
6. Anonymous public downloads, `SHA256SUMS`, metadata, SBOM, attestations,
   `target_commitish`, the tag ref, and `/releases/latest` all verify.
7. `scripts/termux/release-manifest.env` was promoted only after step 6 and
   references the same release tag and exact source SHA.
8. Release-channel, governance, control-plane, and Fork CI checks are green on
   final cleaned `main`.
9. One maintenance issue records the complete evidence and is closed as
   `completed`; duplicates are closed as duplicates.
10. Temporary jobs, scripts, workflows, staging branches, and gate branches are
    gone, leaving only the permanent workflow inventory.

Anything less is progress, not completion.

## 1. Inventory live state before changing anything

Re-query all of these at the start of every takeover or retry:

- `main` HEAD and recent commits;
- upstream tags, peeled tag objects, fork tags, releases, and `/releases/latest`;
- branches, pull requests, rulesets, and branch protection visibility;
- open maintenance issues and duplicate trackers;
- queued, in-progress, and recent Actions runs;
- every workflow file and the permanent workflow inventory;
- any temporary maintenance scripts, jobs, workflows, or staging branches.

Inspect the complete logs of the newest relevant failed job before editing. A
workflow summary or issue body can report the stage that failed, but only the job
log identifies the actual command and error.

Cancel or isolate raceable orchestration before repair. Re-query after every
write because a commit, issue event, or dispatch may have created new runs.

### Historical ghost runs

GitHub can retain a queued historical run after its workflow YAML has been
deleted, and the cancel or force-cancel endpoints may reject the request. Never
claim such a run was cancelled unless the API confirms it. It need not block a
release only when all of these are proven:

- the workflow file and workflow identity are absent from current `main`;
- no current workflow can dispatch or call it;
- the historical workflow had no release, branch, tag, or issue write path that
  can still execute;
- no current run is in progress;
- the anomaly is recorded honestly in the tracker or handover.

## 2. Pin exact upstream and source identity

Do not treat the annotated tag object SHA as the upstream source commit. Peel it:

```bash
upstream_commit="$(git rev-parse 'refs/tags/rust-vX.Y.Z-alpha.N^{}')"
```

Record all four identities separately:

```text
upstream_tag=<annotated upstream tag>
upstream_commit=<peeled upstream commit>
merge_commit=<fork merge commit, when applicable>
source_sha=<clean exact fork source used for every release gate>
```

The release source may be a cleanup commit after the merge. The durable proof is
ancestry, not a particular parent position:

```bash
git merge-base --is-ancestor "$upstream_commit" "$source_sha"
```

### Never assume `HEAD^2` exists

A first alpha integration may create a merge commit, but a retry after that merge
has already landed can create an ordinary single-parent commit. The alpha.5
orchestrator failed with:

```text
fatal: ambiguous argument 'HEAD^2'
```

Use a second parent only as optional diagnostic evidence:

```bash
if second_parent="$(git rev-parse --verify HEAD^2 2>/dev/null)"; then
  printf 'merge second parent: %s\n' "$second_parent"
fi

git merge-base --is-ancestor "$upstream_commit" "$source_sha"
```

Do not replace the ancestry test with a fallback that merely prints the expected
SHA. The command must actually prove the selected source contains upstream.

## 3. Diagnose and repair CI precisely

### Upstream proxy-control descriptor migration

During the alpha.5 update, upstream proxy routing changed a value previously
used as a readable socket-directory path into preserved proxy-control file
descriptors. The compile signature was:

```text
codex-rs/linux-sandbox/src/linux_run_main.rs:314
E0308: expected &AbsolutePathBuf, found &Vec<File>
```

The correct compatibility model is:

- the returned `File` objects are ownership-bearing control descriptors;
- keep them alive for the sandboxed process lifetime where required;
- pass or preserve them according to the new upstream API;
- do not reinterpret the vector as a directory path;
- do not close or drop the descriptors prematurely;
- validate the repair on hosted Linux x64 and ARM64 as well as the Android and
  production ARM64 paths.

When a later upstream migration touches the same area, inspect the current API
and call sites rather than replaying the alpha.5 patch mechanically.

### Generated script and wrapper failures

A generated transaction can pass compilation and still fail in orchestration.
Always inspect the terminal portion of the complete job log.

Two specific traps have already occurred:

1. **Global token replacement changed control flow.** Adapting an old one-off
   script by replacing every `alpha1515` token also changed internal paths and
   assumptions. Every generated script must pass `bash -n`, and the generated
   lines around the execution point should be inspected before dispatch.
2. **Bootstrap directory collision.** A wrapper and the script it generated used
   the same adapted work directory, so the nested generator could overwrite the
   script currently running. Use distinct paths such as
   `alphaNN-bootstrap` and `alphaNN-maintenance`.

Also validate workflow YAML before push. Shell quoting, heredoc indentation, and
GitHub expression syntax can fail before the intended repair runs.

### Do not let Actions edit workflow YAML

Make workflow changes directly through the connected GitHub write operations or
an ordinary maintainer commit. Do not use an Actions job to rewrite its own or
another workflow file. This produces hard-to-audit recursion, permission, and
branch-protection behaviour.

Do not add a one-off workflow unless the repository owner explicitly approves
it. Prefer the permanent workflows and direct commits. Any explicitly approved
temporary orchestration must be tracked as disposable and removed before the
maintenance issue closes.

## 4. Reuse gates only under exact conditions

A run is reusable only when every condition is true:

- `head_sha` equals the selected `source_sha` exactly;
- the workflow path is the expected permanent workflow;
- status is `completed` and conclusion is `success`;
- the required job matrix completed, including both Linux architectures;
- required artifacts are still retained and unexpired;
- downloaded artifacts verify against their checksums and metadata;
- the run has not been superseded by a source change.

A green run from a neighbouring commit, merge commit, branch head, or previous
alpha is invalid evidence.

Do not dispatch a duplicate while an exact-source run is queued or running. A
failed exact-source run may be deliberately rerun after the failure is repaired;
record the new run ID and do not silently substitute it.

## 5. Publication is one controlled transaction

Only `.github/workflows/termux-release-request.yml` may publish a release.
Populate `scripts/termux/release-publication.env` with the selected source and
successful exact-source run IDs.

The final public asset set is exactly:

```text
codex-termux-aarch64-unknown-linux-musl.tar.gz
codex-termux-sbom.spdx.json
metadata.env
release-manifest.env
SHA256SUMS
```

The publisher must:

1. re-fetch and validate all recorded exact-source runs;
2. download the retained production artifact and verify its internal contents;
3. validate package version, binary identity, target, source SHA, metadata,
   checksums, and SPDX SBOM;
4. generate provenance attestations before publication;
5. upload every final asset while the release is still a draft;
6. publish that complete draft as GitHub Latest in the same update;
7. set `target_commitish` to the exact runtime source SHA;
8. refuse to replace or mutate an already-public conflicting release.

A public release must never be repaired by incrementally uploading assets or
editing its source identity. Delete an abandoned draft when safe; fail on a
conflicting public object.

A retry may reuse an already-public exact release only when it is already Latest
and every source, tag, asset, digest, and public verification check passes. The
retry must not modify that release.

## 6. Anonymous verification precedes manifest promotion

Authenticated API success is not proof that end users can install the release.
Before promoting the updater manifest, verify as an anonymous client:

- `/releases/latest` resolves to the expected tag;
- every `browser_download_url` returns the public bytes;
- the downloaded release manifest matches the candidate manifest byte-for-byte;
- `sha256sum --check --strict SHA256SUMS` passes;
- the archive digest and size match GitHub metadata and the manifest;
- `metadata.env` reports the selected source, binary identity, and target;
- the SBOM parses and identifies the expected package/source;
- the tag ref resolves to the selected source commit;
- attestations verify with the permanent release publisher as signer.

Only after those checks may `scripts/termux/release-manifest.env` be committed.
Closing the tracker before manifest promotion is incorrect.

## 7. Post-promotion verification and Actions recursion

Commits created with the workflow `GITHUB_TOKEN` do not recursively trigger new
workflow runs. Therefore, do not assume the manifest promotion commit started the
release-channel, governance, control-plane, or Fork CI checks.

Explicitly dispatch the permanent post-promotion workflows against final cleaned
`main`, then wait for their live conclusions:

```text
termux-release-channel.yml
termux-governance.yml
termux-control-plane.yml
blocking-ci.yml
```

Pre-publication gates run against the exact runtime `source_sha`. Post-promotion
checks run against final cleaned `main`, which may include the publication
request, promoted manifest, documentation, and temporary-file cleanup. Keep
those two identities separate in the tracker.

The release-channel and governance checks must independently download and verify
the public bytes; success from the publisher alone is not sufficient.

## 8. Cleanup and tracker hygiene

Before completion, prove all of the following:

- only the permanent workflows listed in `.github/workflows/README.md` remain;
- no temporary maintenance job remains in `blocking-ci.yml`;
- no temporary maintenance script, generated part file, or proxy helper remains;
- no staging or gate branch remains;
- no obsolete orchestration is still capable of racing the permanent publisher;
- only one maintenance tracker represented the work;
- the tracker body contains the final evidence rather than stale `state=failed`
  text;
- the tracker is closed with reason `completed` only after post-promotion checks
  pass.

Recommended final tracker body:

```text
state=completed
detail=published-and-independently-verified
upstream_tag=<tag>
upstream_commit=<peeled commit>
package_version=<version>
merge_commit=<merge commit>
source_sha=<exact runtime source>
release_tag=<public tag>
fork_ci_run_id=<id>
control_run_id=<id>
sandbox_run_id=<id>
artifact_run_id=<id>
android_run_id=<id>
release_run_id=<id>
post_fork_ci_run_id=<id>
post_control_run_id=<id>
release_channel_run_id=<id>
governance_run_id=<id>
final_main_sha=<clean final main>
```

## 9. Connected GitHub tooling discipline

When operating through a connected GitHub tool:

- discover the available mutation schemas before declaring the connection
  read-only; file writes, Git-data commits/ref updates, issue mutation, and
  workflow controls may be exposed separately from repository reads;
- a failed tool-discovery query is not proof that a write operation is absent;
- use direct GitHub mutations for repository edits and re-fetch the affected
  resource after each write;
- never report a branch deletion, issue closure, cancellation, publication, or
  successful run until a live read confirms it;
- if an operation genuinely cannot be performed, state exactly which mutation
  was unavailable and leave the repository state unchanged rather than claiming
  expected completion.

## Final release audit

The final response or handover should quote live evidence for:

- current `main` SHA;
- upstream tag and peeled commit;
- exact runtime source SHA and ancestry;
- every required pre-publication run ID and conclusion;
- publisher run ID and conclusion;
- Latest release tag, name, `target_commitish`, asset names, digests, and sizes;
- promoted manifest values;
- permanent post-promotion run IDs and conclusions;
- issue state;
- workflow inventory and branch inventory;
- absence of temporary orchestration.

Do not replace this audit with “the workflow should have done it.”
