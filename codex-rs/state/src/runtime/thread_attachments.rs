//! Transactional thread attachment storage using the attachment SQL schema.

use super::StateRuntime;
use crate::AddThreadAttachmentOutcome;
use crate::MAX_THREAD_ATTACHMENT_IDENTITY_KEY_BYTES;
use crate::MAX_THREAD_ATTACHMENT_PAYLOAD_BYTES;
use crate::MAX_THREAD_ATTACHMENT_TYPE_BYTES;
use crate::MAX_THREAD_ATTACHMENTS_PER_THREAD;
use crate::RemoveThreadAttachmentOutcome;
use crate::ThreadAttachment;
use anyhow::Context;
use chrono::Utc;
use codex_protocol::ThreadId;
use serde_json::Value;
use sqlx::Row;
use sqlx::sqlite::SqliteRow;
use uuid::Uuid;

impl StateRuntime {
    /// Attach an attachment once, returning an existing attachment for repeated requests.
    pub async fn add_thread_attachment(
        &self,
        thread_id: ThreadId,
        attachment_type: &str,
        identity_key: &str,
        payload: &Value,
    ) -> anyhow::Result<AddThreadAttachmentOutcome> {
        validate_attachment_identity(attachment_type, identity_key)?;
        let serialized_payload = serde_json::to_string(payload).context(
            "invalid thread attachment request: attachment payload cannot be serialized",
        )?;
        if serialized_payload.len() > MAX_THREAD_ATTACHMENT_PAYLOAD_BYTES {
            anyhow::bail!(
                "invalid thread attachment request: attachment payload exceeds {MAX_THREAD_ATTACHMENT_PAYLOAD_BYTES} bytes"
            );
        }

        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let thread_id_string = thread_id.to_string();
        let thread_exists = sqlx::query_scalar::<_, i64>("SELECT 1 FROM threads WHERE id = ?")
            .bind(&thread_id_string)
            .fetch_optional(&mut *transaction)
            .await?
            .is_some();
        if !thread_exists {
            anyhow::bail!("thread not found: {thread_id}");
        }

        let existing = sqlx::query(
            "SELECT id, thread_id, attachment_type, identity_key, payload, created_at FROM thread_attachments WHERE thread_id = ? AND attachment_type = ? AND identity_key = ?",
        )
        .bind(&thread_id_string)
        .bind(attachment_type)
        .bind(identity_key)
        .fetch_optional(&mut *transaction)
        .await?;
        if let Some(existing) = existing {
            let attachment = attachment_from_row(&existing)?;
            transaction.commit().await?;
            return Ok(AddThreadAttachmentOutcome::Existing(attachment));
        }

        let identity_count = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM thread_attachments WHERE thread_id = ?",
        )
        .bind(&thread_id_string)
        .fetch_one(&mut *transaction)
        .await?;
        if usize::try_from(identity_count)? >= MAX_THREAD_ATTACHMENTS_PER_THREAD {
            anyhow::bail!(
                "invalid thread attachment request: thread attachment identity count exceeds {MAX_THREAD_ATTACHMENTS_PER_THREAD}"
            );
        }

        let attachment = ThreadAttachment {
            id: Uuid::now_v7().to_string(),
            thread_id,
            attachment_type: attachment_type.to_string(),
            identity_key: identity_key.to_string(),
            payload: payload.clone(),
            created_at: Utc::now().timestamp(),
        };
        sqlx::query(
            "INSERT INTO thread_attachments (id, thread_id, attachment_type, identity_key, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&attachment.id)
        .bind(&thread_id_string)
        .bind(attachment_type)
        .bind(identity_key)
        .bind(&serialized_payload)
        .bind(attachment.created_at)
        .execute(&mut *transaction)
        .await?;
        transaction.commit().await?;
        Ok(AddThreadAttachmentOutcome::Created(attachment))
    }

    /// Remove an attached attachment, immediately freeing its slot.
    pub async fn remove_thread_attachment(
        &self,
        thread_id: ThreadId,
        attachment_type: &str,
        identity_key: &str,
    ) -> anyhow::Result<RemoveThreadAttachmentOutcome> {
        validate_attachment_identity(attachment_type, identity_key)?;
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let thread_id_string = thread_id.to_string();
        let thread_exists = sqlx::query_scalar::<_, i64>("SELECT 1 FROM threads WHERE id = ?")
            .bind(&thread_id_string)
            .fetch_optional(&mut *transaction)
            .await?
            .is_some();
        if !thread_exists {
            anyhow::bail!("thread not found: {thread_id}");
        }

        let removed = sqlx::query(
            "DELETE FROM thread_attachments WHERE thread_id = ? AND attachment_type = ? AND identity_key = ? RETURNING id, thread_id, attachment_type, identity_key, payload, created_at",
        )
        .bind(&thread_id_string)
        .bind(attachment_type)
        .bind(identity_key)
        .fetch_optional(&mut *transaction)
        .await?;
        let outcome = match removed {
            Some(row) => RemoveThreadAttachmentOutcome::Removed(attachment_from_row(&row)?),
            None => RemoveThreadAttachmentOutcome::NotFound,
        };
        transaction.commit().await?;
        Ok(outcome)
    }
}

fn validate_attachment_identity(attachment_type: &str, identity_key: &str) -> anyhow::Result<()> {
    if attachment_type.trim().is_empty() {
        anyhow::bail!("invalid thread attachment request: attachment type must not be empty");
    }
    if attachment_type.len() > MAX_THREAD_ATTACHMENT_TYPE_BYTES {
        anyhow::bail!(
            "invalid thread attachment request: attachment type exceeds {MAX_THREAD_ATTACHMENT_TYPE_BYTES} bytes"
        );
    }
    if identity_key.trim().is_empty() {
        anyhow::bail!(
            "invalid thread attachment request: attachment identity key must not be empty"
        );
    }
    if identity_key.len() > MAX_THREAD_ATTACHMENT_IDENTITY_KEY_BYTES {
        anyhow::bail!(
            "invalid thread attachment request: attachment identity key exceeds {MAX_THREAD_ATTACHMENT_IDENTITY_KEY_BYTES} bytes"
        );
    }
    Ok(())
}

fn attachment_from_row(row: &SqliteRow) -> anyhow::Result<ThreadAttachment> {
    let thread_id: String = row.try_get("thread_id")?;
    let payload: String = row.try_get("payload")?;
    Ok(ThreadAttachment {
        id: row.try_get("id")?,
        thread_id: ThreadId::from_string(&thread_id)
            .context("invalid persisted thread attachment owner")?,
        attachment_type: row.try_get("attachment_type")?,
        identity_key: row.try_get("identity_key")?,
        payload: serde_json::from_str(&payload)
            .context("invalid persisted thread attachment payload")?,
        created_at: row.try_get("created_at")?,
    })
}

#[cfg(test)]
#[path = "thread_attachments_tests.rs"]
mod tests;
