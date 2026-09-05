//! Opaque parent-inference receipts kept out of persisted and model-visible context.

use std::fmt;

/// Header carried on the parent response's metadata, for both SSE and WebSocket.
pub const GUARDIAN_TICKET_HEADER: &str = "x-codex-guardian-ticket";
/// Request metadata consumed by Codex backend before forwarding reviewer inference.
pub const GUARDIAN_TICKET_METADATA_KEY: &str = "guardian_ticket";

/// A server-issued receipt. Parsing checks its shape, not its authenticity.
///
/// Only the backend can validate ownership, expiry, and remaining allowance. This
/// type intentionally has no serialization implementation or unredacted Debug.
#[derive(Clone, PartialEq, Eq)]
pub struct GuardianTicket(String);

impl GuardianTicket {
    /// Accept the bounded URL-safe representation used by the receipt issuer.
    pub fn from_server(value: &str) -> Option<Self> {
        (value.len() == 43
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')))
        .then(|| Self(value.to_owned()))
    }

    /// Expose the receipt only when writing transport metadata.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for GuardianTicket {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GuardianTicket([REDACTED])")
    }
}
