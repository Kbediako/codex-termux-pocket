use super::*;
use pretty_assertions::assert_eq;

fn publish_answer() -> RetainedContextEvent {
    RetainedContextEvent::VerifiedAnswer {
        answer: VerifiedAnswer {
            turn_id: "turn-1".to_owned(),
            call_id: "ask-1".to_owned(),
            questions: vec![VerifiedQuestionAnswer {
                question: "Publish?".to_owned(),
                answer: "Yes, but never publicly.".to_owned(),
            }],
        },
        acceptance_order: None,
    }
}

#[test]
fn retained_evidence_preserves_order_through_recovery_checkpoint_and_rollback() {
    let mut context = RetainedContext::default();
    let first = publish_answer();
    assert!(context.record(&first));
    let before_restriction = context.clone();
    context.record_user_message(
        RetainedUserMessage {
            turn_id: "revocation-turn".to_owned(),
            message_id: Some("revocation".to_owned()),
            text: String::new(),
            complete: false,
        },
        /*acceptance_order*/ None,
    );
    let mut expected = context.clone();
    expected.user_messages[0].value.text = "Do not publish after all.".to_owned();
    context.recover_user_message_excerpts(|id| {
        assert_eq!(id, "revocation");
        Some("Do not publish after all.".to_owned())
    });
    assert_eq!(context, expected);
    context.recover_user_message_excerpts(|_| panic!("existing text must not be replaced"));
    let snapshot = context.clone();
    assert!(!context.record(&first));
    assert_eq!(context, snapshot);
    let checkpoint =
        serde_json::from_str(&serde_json::to_string(&context).expect("retained answer fixture"))
            .expect("retained answer fixture");
    let mut restored = RetainedContext::default();
    restored.restore(Some(&checkpoint));
    assert_eq!(restored, snapshot);
    assert_eq!(
        restored
            .ordered_entries()
            .map(|entry| match entry {
                RetainedContextEntry::VerifiedAnswer(answer) => answer.questions[0].answer.as_str(),
                RetainedContextEntry::UserMessage(message) => message.text.as_str(),
            })
            .collect::<Vec<_>>(),
        vec!["Yes, but never publicly.", "Do not publish after all."]
    );
    restored.rollback(
        &["revocation-turn"],
        Some("revocation"),
        /*acceptance_order*/ None,
    );
    assert_eq!(
        restored,
        RetainedContext {
            next_order: snapshot.next_order,
            ..before_restriction
        }
    );
}

#[test]
fn retained_families_enforce_storage_limits_without_changing_snapshots() {
    let mut context = RetainedContext::default();
    let first = publish_answer();
    context.record(&first);
    let snapshot = context.clone();

    for index in 2..=10 {
        context.record(&RetainedContextEvent::VerifiedAnswer {
            answer: VerifiedAnswer {
                turn_id: "turn-2".to_owned(),
                call_id: format!("ask-{index}"),
                questions: vec![VerifiedQuestionAnswer {
                    question: "Continue?".to_owned(),
                    answer: "Yes".to_owned(),
                }],
            },
            acceptance_order: None,
        });
    }
    assert!(!context.verified_answers_complete());
    assert_eq!(context.verified_answers().count(), MAX_FAMILY_RECORDS);
    context.rollback(
        &["turn-2"],
        /*first_removed_message_id*/ None,
        /*acceptance_order*/ None,
    );
    assert_eq!(context.verified_answers().count(), 0);
    assert!(!context.verified_answers_complete());

    let mut restored = snapshot.clone();
    let mut oversized = first.clone();
    let RetainedContextEvent::VerifiedAnswer { answer, .. } = &mut oversized;
    answer.questions[0].answer = "a".repeat(MAX_RECORD_BYTES);
    restored.record(&oversized);
    assert!(!restored.verified_answers_complete());
    assert!(
        restored
            .verified_answers()
            .next()
            .expect("retained answer fixture")
            .questions
            .is_empty()
    );
    assert_eq!(
        snapshot
            .verified_answers()
            .next()
            .expect("retained answer fixture")
            .questions[0]
            .answer,
        "Yes, but never publicly."
    );
    for index in 0..=MAX_FAMILY_RECORDS {
        restored.record_user_message(
            RetainedUserMessage {
                turn_id: "later-turn".to_owned(),
                message_id: Some(format!("message-{index}")),
                text: "Keep the repository private.".to_owned(),
                complete: true,
            },
            /*acceptance_order*/ None,
        );
    }
    assert!(!restored.user_messages_complete());
    assert_eq!(
        restored
            .ordered_entries()
            .filter(|entry| matches!(entry, RetainedContextEntry::UserMessage(_)))
            .count(),
        MAX_FAMILY_RECORDS
    );
    let recent = restored.clone();
    restored.record_user_message(
        RetainedUserMessage {
            turn_id: "earlier-turn".to_owned(),
            message_id: Some("delayed-message".to_owned()),
            text: "An older queued instruction.".to_owned(),
            complete: true,
        },
        Some(0),
    );
    assert_eq!(
        restored, recent,
        "delayed old input must not evict newer evidence"
    );
    restored.record_user_message(
        RetainedUserMessage {
            turn_id: "oversized-turn".to_owned(),
            message_id: Some("oversized-message".to_owned()),
            text: "restriction ".repeat(MAX_RECORD_BYTES),
            complete: true,
        },
        /*acceptance_order*/ None,
    );
    let Some(RetainedContextEntry::UserMessage(message)) = restored.ordered_entries().next_back()
    else {
        panic!("latest user evidence");
    };
    assert_eq!((&message.text, message.complete), (&String::new(), false));
}

#[test]
fn recovered_excerpts_obey_record_and_family_limits() {
    let mut context = RetainedContext::default();
    for index in 0..MAX_FAMILY_RECORDS {
        context.record_user_message(
            RetainedUserMessage {
                turn_id: "turn-1".to_owned(),
                message_id: Some(format!("message-{index}")),
                text: String::new(),
                complete: false,
            },
            /*acceptance_order*/ None,
        );
    }
    let unchanged = context.clone();
    context.recover_user_message_excerpts(|_| Some("x".repeat(MAX_RECORD_BYTES)));
    assert_eq!(context, unchanged);
    context.recover_user_message_excerpts(|_| Some("x".repeat(MAX_RECORD_BYTES - 1_024)));
    assert!(context.user_messages_incomplete);
    assert!(context.user_messages.len() < MAX_FAMILY_RECORDS);
    assert!(serde_json::to_vec(&context.user_messages).unwrap().len() <= MAX_FAMILY_BYTES);
}

#[test]
fn legacy_checkpoints_mark_user_messages_incomplete() {
    let RetainedContextEvent::VerifiedAnswer { answer, .. } = publish_answer();
    let mut wire = serde_json::json!({
        "verified_answers": [answer], "incomplete": false
    });
    let legacy: RetainedContext =
        serde_json::from_value(wire.clone()).expect("legacy retained-answer checkpoint");
    assert!(legacy.verified_answers_complete());
    assert!(!legacy.user_messages_complete());

    // Retain the original wire key even though the internal field names its family.
    wire["verified_answers"][0]["order"] = serde_json::json!(0);
    wire["user_messages"] = serde_json::json!([]);
    wire["user_messages_incomplete"] = serde_json::json!(true);
    wire["next_order"] = serde_json::json!(0);
    assert_eq!(serde_json::to_value(&legacy).unwrap(), wire);

    let mut restored = RetainedContext::default();
    restored.restore(/*checkpoint*/ None);
    assert!(!restored.user_messages_complete());
}

#[test]
fn accepted_order_survives_delayed_recording_and_checkpoint_replay() {
    let mut context = RetainedContext::default();
    // Rejected/canceled input consumes a sequence but never becomes evidence.
    context.reserve_order();
    let steer_order = context.reserve_order();
    let answer_order = context.reserve_order();
    let RetainedContextEvent::VerifiedAnswer { answer, .. } = publish_answer();
    let event = RetainedContextEvent::VerifiedAnswer {
        answer,
        acceptance_order: Some(answer_order),
    };
    context.record(&event);
    let checkpoint = context.clone();
    let instruction = RetainedUserMessage {
        turn_id: "turn-1".to_owned(),
        message_id: Some("steer".to_owned()),
        text: "Keep the repository private.".to_owned(),
        complete: true,
    };
    context.record_user_message(instruction.clone(), Some(steer_order));
    let mut resumed = RetainedContext::default();
    resumed.restore(Some(&checkpoint));
    resumed.record_user_message(instruction, Some(steer_order));
    assert_eq!(resumed, context);
    assert_eq!(
        resumed
            .ordered_entries()
            .map(|entry| match entry {
                RetainedContextEntry::UserMessage(message) => message.text.as_str(),
                RetainedContextEntry::VerifiedAnswer(answer) => answer.questions[0].answer.as_str(),
            })
            .collect::<Vec<_>>(),
        vec!["Keep the repository private.", "Yes, but never publicly."],
    );
    // This checkpoint predates model delivery of the queued instruction. Rollback
    // still removes its later-accepted answer using the persisted boundary order.
    let mut before_delivery = checkpoint;
    before_delivery.rollback(&["turn-1"], Some("steer"), Some(steer_order));
    resumed.rollback(&["turn-1"], Some("steer"), Some(steer_order));
    assert_eq!(before_delivery, resumed);
    assert_eq!(
        resumed,
        RetainedContext {
            next_order: 3,
            ..Default::default()
        }
    );
}
