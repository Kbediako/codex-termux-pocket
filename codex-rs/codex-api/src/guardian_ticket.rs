//! Adds opaque receipts only to Guardian requests at the transport boundary.

use std::collections::HashMap;

use crate::endpoint::responses::ResponsesEndpoint;

use codex_protocol::guardian_ticket::GUARDIAN_TICKET_METADATA_KEY;
use codex_protocol::guardian_ticket::GuardianTicket;

pub(crate) fn attach(
    metadata: &mut Option<HashMap<String, String>>,
    ticket: Option<&GuardianTicket>,
    endpoint: ResponsesEndpoint,
) {
    if let Some(metadata) = metadata.as_mut() {
        metadata.remove(GUARDIAN_TICKET_METADATA_KEY);
        if endpoint != ResponsesEndpoint::Responses {
            metadata.remove("guardian_ticket_requested");
        }
    }
    if endpoint != ResponsesEndpoint::Responses
        && let Some(ticket) = ticket
    {
        metadata.get_or_insert_with(HashMap::new).insert(
            GUARDIAN_TICKET_METADATA_KEY.to_owned(),
            ticket.as_str().to_owned(),
        );
    }
}

#[cfg(test)]
#[path = "guardian_ticket_tests.rs"]
mod tests;
