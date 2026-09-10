//! Coverage for attachment identity, capacity, pagination, and durable lifecycle behavior.

use super::StateRuntime;
use crate::AddThreadAttachmentOutcome;
use crate::MAX_THREAD_ATTACHMENT_IDENTITY_KEY_BYTES;
use crate::MAX_THREAD_ATTACHMENT_PAYLOAD_BYTES;
use crate::MAX_THREAD_ATTACHMENT_TYPE_BYTES;
use crate::MAX_THREAD_ATTACHMENTS_PER_THREAD;
use crate::RemoveThreadAttachmentOutcome;
use crate::runtime::test_support::test_thread_metadata;
use crate::runtime::test_support::unique_temp_dir;
use anyhow::Result;
use codex_protocol::ThreadId;
use codex_utils_absolute_path::test_support::PathExt;
use pretty_assertions::assert_eq;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;

async fn runtime_with_threads(count: usize) -> Result<(Arc<StateRuntime>, PathBuf, Vec<ThreadId>)> {
    let codex_home = unique_temp_dir();
    let runtime = StateRuntime::init(
        crate::SqliteConfig::new_for_testing(codex_home.as_path().abs()),
        "test-provider".to_string(),
    )
    .await?;
    let mut thread_ids = Vec::with_capacity(count);
    for _ in 0..count {
        let thread_id = ThreadId::new();
        runtime
            .upsert_thread(&test_thread_metadata(
                &codex_home,
                thread_id,
                codex_home.clone(),
            ))
            .await?;
        thread_ids.push(thread_id);
    }
    Ok((runtime, codex_home, thread_ids))
}

#[tokio::test]
async fn attachment_attachments_are_idempotent_and_scoped_to_their_thread() -> Result<()> {
    let (runtime, _codex_home, thread_ids) = runtime_with_threads(/*count*/ 2).await?;
    let first = runtime
        .add_thread_attachment(
            thread_ids[0],
            "pull_request",
            "openai/codex#123",
            &json!({ "url": "https://github.com/openai/codex/pull/123" }),
        )
        .await?;
    let AddThreadAttachmentOutcome::Created(first) = first else {
        anyhow::bail!("first attachment should create an attachment");
    };
    assert_eq!(first.thread_id, thread_ids[0]);

    let repeated = runtime
        .add_thread_attachment(
            thread_ids[0],
            "pull_request",
            "openai/codex#123",
            &json!({ "url": "https://github.com/openai/codex/pull/456" }),
        )
        .await?;
    assert_eq!(
        repeated,
        AddThreadAttachmentOutcome::Existing(first.clone())
    );

    let other = runtime
        .add_thread_attachment(
            thread_ids[1],
            "pull_request",
            "openai/codex#123",
            &json!({ "url": "https://github.com/openai/codex/pull/123" }),
        )
        .await?;
    let AddThreadAttachmentOutcome::Created(other) = other else {
        anyhow::bail!("the same identity on another thread should create its own attachment");
    };
    assert_ne!(first.id, other.id);
    Ok(())
}

#[tokio::test]
async fn attachment_removals_return_not_found_or_the_removed_record() -> Result<()> {
    let (runtime, _codex_home, thread_ids) = runtime_with_threads(/*count*/ 1).await?;
    let thread_id = thread_ids[0];
    let removed_before_attach = runtime
        .remove_thread_attachment(thread_id, "pull_request", "openai/codex#123")
        .await?;
    assert_eq!(
        removed_before_attach,
        RemoveThreadAttachmentOutcome::NotFound
    );

    let explicit = runtime
        .add_thread_attachment(
            thread_id,
            "pull_request",
            "openai/codex#123",
            &json!({ "url": "https://github.com/openai/codex/pull/123" }),
        )
        .await?;
    let AddThreadAttachmentOutcome::Created(explicit) = explicit else {
        anyhow::bail!("attachment should create an attachment");
    };
    assert_eq!(
        runtime
            .remove_thread_attachment(thread_id, "pull_request", "openai/codex#123")
            .await?,
        RemoveThreadAttachmentOutcome::Removed(explicit)
    );
    Ok(())
}

#[tokio::test]
async fn active_attachment_limit_is_freed_by_removal() -> Result<()> {
    let (runtime, _codex_home, thread_ids) = runtime_with_threads(/*count*/ 1).await?;
    let thread_id = thread_ids[0];

    for index in 0..MAX_THREAD_ATTACHMENTS_PER_THREAD {
        runtime
            .add_thread_attachment(
                thread_id,
                "pull_request",
                &format!("attachment-{index}"),
                &json!({ "index": index }),
            )
            .await?;
    }

    let existing = runtime
        .add_thread_attachment(
            thread_id,
            "pull_request",
            "attachment-0",
            &json!({ "index": "different" }),
        )
        .await?;
    assert!(matches!(existing, AddThreadAttachmentOutcome::Existing(_)));
    let attachment_limit = runtime
        .add_thread_attachment(thread_id, "pull_request", "one-too-many", &json!({}))
        .await
        .expect_err("a new attachment must not exceed the per-thread limit");
    assert!(
        attachment_limit.to_string().contains(
            "invalid thread attachment request: thread attachment identity count exceeds"
        )
    );

    let removed = runtime
        .remove_thread_attachment(thread_id, "pull_request", "attachment-0")
        .await?;
    assert!(matches!(removed, RemoveThreadAttachmentOutcome::Removed(_)));
    assert_eq!(
        runtime
            .remove_thread_attachment(thread_id, "pull_request", "attachment-0")
            .await?,
        RemoveThreadAttachmentOutcome::NotFound
    );
    let replacement = runtime
        .add_thread_attachment(thread_id, "pull_request", "one-too-many", &json!({}))
        .await?;
    assert!(matches!(
        replacement,
        AddThreadAttachmentOutcome::Created(_)
    ));

    Ok(())
}

#[tokio::test]
async fn attachment_mutations_reject_invalid_identity_payload_and_unknown_threads() -> Result<()> {
    let (runtime, _codex_home, thread_ids) = runtime_with_threads(/*count*/ 1).await?;
    let thread_id = thread_ids[0];
    for (attachment_type, identity_key, expected) in [
        (" ".to_string(), "pr".to_string(), "type must not be empty"),
        (
            "x".repeat(MAX_THREAD_ATTACHMENT_TYPE_BYTES + 1),
            "pr".to_string(),
            "type exceeds",
        ),
        (
            "pull_request".to_string(),
            " ".to_string(),
            "key must not be empty",
        ),
        (
            "pull_request".to_string(),
            "x".repeat(MAX_THREAD_ATTACHMENT_IDENTITY_KEY_BYTES + 1),
            "key exceeds",
        ),
    ] {
        let error = runtime
            .add_thread_attachment(thread_id, &attachment_type, &identity_key, &json!({}))
            .await
            .expect_err("invalid attachment identities must be rejected");
        assert!(error.to_string().contains(expected));
    }

    let too_large = runtime
        .add_thread_attachment(
            thread_id,
            "pull_request",
            "pr",
            &json!("x".repeat(MAX_THREAD_ATTACHMENT_PAYLOAD_BYTES)),
        )
        .await
        .expect_err("oversized attachment payload must be rejected");
    assert!(too_large.to_string().contains("payload exceeds"));
    let missing = ThreadId::new();
    let missing_error = runtime
        .add_thread_attachment(missing, "pull_request", "pr", &json!({}))
        .await
        .expect_err("missing owners must be rejected");
    assert!(missing_error.to_string().contains("thread not found"));
    Ok(())
}

#[tokio::test]
async fn concurrent_attachment_attachments_preserve_one_deterministic_identity() -> Result<()> {
    let (runtime, _codex_home, thread_ids) = runtime_with_threads(/*count*/ 1).await?;
    let thread_id = thread_ids[0];
    let mut joins = Vec::new();
    for _ in 0..8 {
        let runtime = Arc::clone(&runtime);
        joins.push(tokio::spawn(async move {
            runtime
                .add_thread_attachment(
                    thread_id,
                    "pull_request",
                    "openai/codex#123",
                    &json!({ "url": "https://github.com/openai/codex/pull/123" }),
                )
                .await
        }));
    }

    let mut created = 0;
    for join in joins {
        match join.await?? {
            AddThreadAttachmentOutcome::Created(_) => created += 1,
            AddThreadAttachmentOutcome::Existing(_) => {}
        }
    }
    assert_eq!(created, 1);
    Ok(())
}
