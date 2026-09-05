//! Bounded host-owned facts outside the model's compaction contract.
//! Checkpoints and live recording use the same admission rules; rendering is a consumer concern.

use std::collections::VecDeque;

use schemars::JsonSchema;
use serde::Deserialize;
use serde::Serialize;

const MAX_FAMILY_RECORDS: usize = 8;
const MAX_RECORD_BYTES: usize = 16_384;
const MAX_FAMILY_BYTES: usize = 65_536;

/// Original assistant question and host-verified user reply, never an inferred permission.
#[derive(Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct VerifiedQuestionAnswer {
    pub question: String,
    pub answer: String,
}

/// One accepted request_user_input response. Identity is local to the owning thread.
/// An omitted payload records incomplete evidence, rather than keeping a partial grant.
#[derive(Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct VerifiedAnswer {
    pub turn_id: String,
    pub call_id: String,
    pub questions: Vec<VerifiedQuestionAnswer>,
}

/// Original user instruction, retained outside model summarization for delegated review.
/// Non-text input is not reconstructed as text; missing evidence remains explicit.
#[derive(Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RetainedUserMessage {
    pub turn_id: String,
    pub message_id: Option<String>,
    pub text: String,
    pub complete: bool,
}

impl std::fmt::Debug for RetainedUserMessage {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RetainedUserMessage")
            .field("complete", &self.complete)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
struct Ordered<T> {
    #[serde(default)]
    order: u64,
    #[serde(flatten)]
    value: T,
}

/// Borrowed host evidence in original arrival order, across retained families.
pub enum RetainedContextEntry<'a> {
    UserMessage(&'a RetainedUserMessage),
    VerifiedAnswer(&'a VerifiedAnswer),
}

impl std::fmt::Debug for VerifiedAnswer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("VerifiedAnswer")
            .field("questions", &self.questions.len())
            .finish_non_exhaustive()
    }
}

/// Sparse, model-invisible updates. Only the host may produce these records.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RetainedContextEvent {
    VerifiedAnswer {
        #[serde(flatten)]
        answer: VerifiedAnswer,
        /// Absent in legacy events, which retain their recorded ordering.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        acceptance_order: Option<u64>,
    },
}

/// Bounded snapshot of retained families, persisted with the parent compaction checkpoint.
/// Facts live until their instruction boundary is rolled back; compaction does not expire them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RetainedContext {
    verified_answers: VecDeque<Ordered<VerifiedAnswer>>,
    /// Lost evidence cannot be treated as a complete authorization history.
    #[serde(rename = "incomplete")]
    verified_answers_incomplete: bool,
    #[serde(default)]
    user_messages: VecDeque<Ordered<RetainedUserMessage>>,
    /// Old checkpoints did not preserve user restrictions for delegated review.
    #[serde(default = "legacy_user_messages_incomplete")]
    user_messages_incomplete: bool,
    #[serde(default)]
    next_order: u64,
}

fn legacy_user_messages_incomplete() -> bool {
    true
}

fn bound_family<T: Serialize>(items: &mut VecDeque<Ordered<T>>, incomplete: &mut bool) {
    // Queued instructions can be recorded after later-accepted answers. Evict by
    // acceptance order, not by the order in which persistence happened to finish.
    items.make_contiguous().sort_by_key(|entry| entry.order);
    while items.len() > MAX_FAMILY_RECORDS
        || serde_json::to_vec(items).map_or(true, |bytes| bytes.len() > MAX_FAMILY_BYTES)
    {
        items.pop_front();
        *incomplete = true;
    }
}

impl RetainedUserMessage {
    fn bound(&mut self) {
        if serde_json::to_vec(self).map_or(true, |bytes| bytes.len() > MAX_RECORD_BYTES) {
            self.text.clear();
            self.complete = false;
            self.turn_id
                .truncate(self.turn_id.floor_char_boundary(1_024));
            if let Some(id) = &mut self.message_id {
                id.truncate(id.floor_char_boundary(1_024));
            }
        }
    }
}

impl RetainedContextEvent {
    /// Bounds a persisted event before it enters the rollout or the live snapshot.
    pub fn bound(&mut self) {
        match self {
            Self::VerifiedAnswer { answer, .. } => {
                if serde_json::to_vec(answer).map_or(true, |bytes| bytes.len() > MAX_RECORD_BYTES) {
                    answer.questions.clear();
                    // IDs are correlation metadata, not model-visible authorization text.
                    answer
                        .turn_id
                        .truncate(answer.turn_id.floor_char_boundary(1_024));
                    answer
                        .call_id
                        .truncate(answer.call_id.floor_char_boundary(1_024));
                }
            }
        }
    }
}

impl RetainedContext {
    /// Reserves order without retaining pending input that hooks may reject or cancel.
    pub fn reserve_order(&mut self) -> u64 {
        let order = self.next_order;
        self.next_order = self.next_order.saturating_add(1);
        order
    }

    fn record_order(&mut self, acceptance_order: Option<u64>) -> u64 {
        let order = acceptance_order.unwrap_or(self.next_order);
        self.next_order = self.next_order.max(order.saturating_add(1));
        order
    }

    pub fn verified_answers(&self) -> impl DoubleEndedIterator<Item = &VerifiedAnswer> {
        self.verified_answers.iter().map(|entry| &entry.value)
    }

    pub fn verified_answers_complete(&self) -> bool {
        !self.verified_answers_incomplete
            && self
                .verified_answers
                .iter()
                .all(|answer| !answer.value.questions.is_empty())
    }

    pub fn user_messages_complete(&self) -> bool {
        !self.user_messages_incomplete
            && self
                .user_messages
                .iter()
                .all(|message| message.value.complete)
    }

    /// A skipped instruction leaves a gap that later checkpoints must preserve.
    pub fn mark_user_messages_incomplete(&mut self) {
        self.user_messages_incomplete = true;
    }

    pub fn ordered_entries(&self) -> impl DoubleEndedIterator<Item = RetainedContextEntry<'_>> {
        let mut entries = self
            .verified_answers
            .iter()
            .map(|entry| {
                (
                    entry.order,
                    RetainedContextEntry::VerifiedAnswer(&entry.value),
                )
            })
            .chain(
                self.user_messages
                    .iter()
                    .map(|entry| (entry.order, RetainedContextEntry::UserMessage(&entry.value))),
            )
            .collect::<Vec<_>>();
        entries.sort_by_key(|(order, _)| *order);
        entries.into_iter().map(|(_, entry)| entry)
    }

    /// Records a delivered user item with its acceptance order. Legacy items without
    /// this metadata use recording order; checkpoint/suffix replay uses the same path.
    pub fn record_user_message(
        &mut self,
        mut message: RetainedUserMessage,
        acceptance_order: Option<u64>,
    ) {
        message.bound();
        if let Some(index) = self.user_messages.iter().position(|entry| {
            message.message_id.is_some() && entry.value.message_id == message.message_id
        }) {
            if self.user_messages[index].value == message {
                return;
            }
            self.user_messages.remove(index);
        }
        let order = self.record_order(acceptance_order);
        self.user_messages.push_back(Ordered {
            order,
            value: message,
        });
        bound_family(&mut self.user_messages, &mut self.user_messages_incomplete);
    }

    /// Recovers omitted text from an exact source without changing identity, order, or
    /// completeness. Recovered excerpts must still satisfy the retained storage limits.
    pub fn recover_user_message_excerpts(
        &mut self,
        mut excerpt_for_id: impl FnMut(&str) -> Option<String>,
    ) {
        for entry in &mut self.user_messages {
            let message = &mut entry.value;
            if message.text.is_empty()
                && !message.complete
                && let Some(text) = message.message_id.as_deref().and_then(&mut excerpt_for_id)
            {
                message.text = text;
                message.bound();
            }
        }
        bound_family(&mut self.user_messages, &mut self.user_messages_incomplete);
    }

    /// Same-event delivery is idempotent; changed contents replace that source's record.
    pub fn record(&mut self, event: &RetainedContextEvent) -> bool {
        let mut event = event.clone();
        event.bound();
        match event {
            RetainedContextEvent::VerifiedAnswer {
                answer,
                acceptance_order,
            } => {
                if let Some(index) = self.verified_answers.iter().position(|existing| {
                    existing.value.turn_id == answer.turn_id
                        && existing.value.call_id == answer.call_id
                }) {
                    if self.verified_answers[index].value == answer {
                        return false;
                    }
                    self.verified_answers.remove(index);
                }
                let order = self.record_order(acceptance_order);
                self.verified_answers.push_back(Ordered {
                    order,
                    value: answer,
                });
                bound_family(
                    &mut self.verified_answers,
                    &mut self.verified_answers_incomplete,
                );
            }
        }
        true
    }

    /// Restoring a saved thread must not bypass the live storage limits.
    /// A missing checkpoint cannot establish complete historical user instructions.
    pub fn restore(&mut self, checkpoint: Option<&Self>) {
        *self = checkpoint.cloned().unwrap_or_else(|| Self {
            user_messages_incomplete: true,
            ..Self::default()
        });
        for entry in &mut self.verified_answers {
            let mut event = RetainedContextEvent::VerifiedAnswer {
                answer: entry.value.clone(),
                acceptance_order: Some(entry.order),
            };
            event.bound();
            let RetainedContextEvent::VerifiedAnswer { answer, .. } = event;
            entry.value = answer;
            self.next_order = self.next_order.max(entry.order.saturating_add(1));
        }
        for entry in &mut self.user_messages {
            entry.value.bound();
            self.next_order = self.next_order.max(entry.order.saturating_add(1));
        }
        bound_family(
            &mut self.verified_answers,
            &mut self.verified_answers_incomplete,
        );
        bound_family(&mut self.user_messages, &mut self.user_messages_incomplete);
    }

    /// Keeps legacy answers whose source calls survive when no retained instruction boundary exists.
    pub fn retain_answers(&mut self, mut keep: impl FnMut(&VerifiedAnswer) -> bool) {
        self.verified_answers.retain(|answer| keep(&answer.value));
    }

    /// Rolls back at the original user-message boundary, including later-accepted facts.
    /// The explicit order also covers checkpoints made before a queued message was delivered.
    /// Steering can share a turn ID. Legacy sources without message identity fall back to
    /// source-turn removal and cannot establish complete retained user instructions.
    pub fn rollback(
        &mut self,
        turn_ids: &[&str],
        first_removed_message_id: Option<&str>,
        acceptance_order: Option<u64>,
    ) {
        if let Some(order) = acceptance_order.or_else(|| {
            first_removed_message_id.and_then(|id| {
                self.user_messages
                    .iter()
                    .find(|message| message.value.message_id.as_deref() == Some(id))
                    .map(|message| message.order)
            })
        }) {
            self.verified_answers.retain(|entry| entry.order < order);
            self.user_messages.retain(|entry| entry.order < order);
            return;
        }
        self.user_messages_incomplete |= first_removed_message_id.is_some()
            || self
                .user_messages
                .iter()
                .any(|message| turn_ids.contains(&message.value.turn_id.as_str()));
        self.verified_answers
            .retain(|answer| !turn_ids.contains(&answer.value.turn_id.as_str()));
        self.user_messages
            .retain(|message| !turn_ids.contains(&message.value.turn_id.as_str()));
    }
}

#[cfg(test)]
#[path = "retained_context_tests.rs"]
mod tests;
