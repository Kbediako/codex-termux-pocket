//! Review requests preserve required evidence while fitting the aggregate budget.
//! Parent token-budget mode must not replace Guardian's summary compaction.

use anyhow::Result;
use codex_core::config::Constrained;
use codex_core::config::CurrentTimeReminderConfig;
use codex_core::config::RolloutBudgetConfig;
use codex_features::Feature;
use codex_protocol::config_types::ApprovalsReviewer;
use codex_protocol::openai_models::AutoReviewMessages;
use codex_protocol::protocol::AskForApproval;
use core_test_support::responses;
use core_test_support::responses::ev_assistant_message;
use core_test_support::responses::ev_completed;
use core_test_support::responses::ev_custom_tool_call;
use core_test_support::responses::ev_function_call;
use core_test_support::responses::ev_response_created;
use core_test_support::responses::sse;
use core_test_support::skip_if_no_network;
use core_test_support::skip_if_wine_exec;
use core_test_support::test_codex::test_codex;
use pretty_assertions::assert_eq;
use serde_json::json;
use test_case::test_case;

#[derive(Clone, Copy)]
enum ReviewerResponse {
    Decision,
    ToolContinuation,
    UncompactableContinuation,
    NextReview,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[test_case(1, ReviewerResponse::Decision; "required_context_fails_closed")]
#[test_case(4_500, ReviewerResponse::ToolContinuation; "oversized_tool_continuation_compacts")]
#[test_case(4_500, ReviewerResponse::UncompactableContinuation; "ineffective_compaction_fails_closed")]
#[test_case(6_000, ReviewerResponse::NextReview; "incoming_review_compacts_existing_history")]
async fn review_respects_complete_context_budget(
    window: i64,
    reviewer_response: ReviewerResponse,
) -> Result<()> {
    skip_if_no_network!(Ok(()));
    skip_if_wine_exec!(
        Ok(()),
        "Guardian approval actions require host-native paths"
    );
    let server = responses::start_mock_server().await;
    let mut builder = test_codex()
        .with_model_info_override("gpt-5.6-luna", move |model| {
            model.context_window = Some(window);
            model
                .model_messages
                .as_mut()
                .expect("bundled reviewer model messages")
                .auto_review = Some(AutoReviewMessages {
                policy: Some("Review actions against user authorization.".to_owned()),
                policy_template: Some("{{ tenant_policy_config }}".to_owned()),
                node_repl_policy: None,
                rejection_instructions: None,
                timeout_instructions: None,
            });
        })
        .with_model_info_override("gpt-5.5", |model| {
            model.auto_review_model_override = Some("gpt-5.6-luna".to_owned());
        })
        .with_config(move |config| {
            config
                .features
                .enable(Feature::TokenBudget)
                .expect("parent uses token-budget mode while Guardian uses summary compaction");
            config.permissions.approval_policy = Constrained::allow_any(AskForApproval::OnRequest);
            config.approvals_reviewer = ApprovalsReviewer::AutoReview;
            config
                .features
                .enable(Feature::CurrentTimeReminder)
                .expect("test permits time reminders");
            config.current_time_reminder = Some(CurrentTimeReminderConfig::default());
            config.rollout_budget = Some(RolloutBudgetConfig {
                limit_tokens: 1_000_000,
                reminder_at_remaining_tokens: Vec::new(),
                sampling_token_weight: 1.0,
                prefill_token_weight: 1.0,
            });
        });
    if matches!(
        reviewer_response,
        ReviewerResponse::ToolContinuation | ReviewerResponse::UncompactableContinuation
    ) {
        builder = builder
            .with_code_mode_host_program(codex_utils_cargo_bin::cargo_bin("codex-code-mode-host")?);
    }
    let test = builder.build_with_auto_env(&server).await?;
    let command = json!({"cmd": "echo guardian-budget-test", "sandbox_permissions": "require_escalated", "justification": "Run the requested command."}).to_string();
    let mut commentary =
        ev_assistant_message("commentary", &"optional old commentary ".repeat(/*n*/ 900));
    commentary["item"]["phase"] = json!("commentary");
    let mut events = vec![
        sse(vec![
            ev_response_created("parent-action"),
            commentary,
            ev_function_call("exec-over-budget", "exec_command", &command),
            ev_completed("parent-action"),
        ]),
        sse(vec![
            ev_response_created("parent-done"),
            ev_assistant_message("done", "done"),
            ev_completed("parent-done"),
        ]),
    ];
    if window > 1 {
        events.insert(
            /*index*/ 1,
            sse(vec![
                ev_response_created("review"),
                match reviewer_response {
                    ReviewerResponse::Decision => ev_assistant_message(
                        "decision",
                        r#"{"risk_level":"low","user_authorization":"high","outcome":"allow"}"#,
                    ),
                    // V2 retains user review inputs. Give it assistant history to
                    // discard so compaction makes room for the next review.
                    ReviewerResponse::NextReview => ev_assistant_message(
                        "decision",
                        &json!({
                            "risk_level": "low",
                            "user_authorization": "high",
                            "outcome": "allow",
                            "rationale": "Previous review reasoning. ".repeat(/*n*/ 256),
                        })
                        .to_string(),
                    ),
                    ReviewerResponse::ToolContinuation
                    | ReviewerResponse::UncompactableContinuation => ev_custom_tool_call(
                        "reviewer-inspect",
                        "exec",
                        "text('inspection-output'.repeat(600));",
                    ),
                },
                ev_completed("review"),
            ]),
        );
    }
    if matches!(reviewer_response, ReviewerResponse::ToolContinuation) {
        events.insert(
            /*index*/ 2,
            sse(vec![
                ev_assistant_message(
                    "after-compaction",
                    r#"{"risk_level":"low","user_authorization":"high","outcome":"allow"}"#,
                ),
                ev_completed("after-compaction"),
            ]),
        );
    }
    if matches!(
        reviewer_response,
        ReviewerResponse::UncompactableContinuation | ReviewerResponse::NextReview
    ) {
        events.extend([
            sse(vec![
                ev_function_call("retry-command", "exec_command", &command),
                ev_completed("retry-action"),
            ]),
            sse(vec![
                ev_assistant_message(
                    "retry-decision",
                    r#"{"risk_level":"low","user_authorization":"high","outcome":"allow"}"#,
                ),
                ev_completed("retry-review"),
            ]),
            sse(vec![
                ev_assistant_message("retry-done", "done"),
                ev_completed("retry-done"),
            ]),
        ]);
    }
    if !matches!(reviewer_response, ReviewerResponse::Decision) {
        let summary = if matches!(
            reviewer_response,
            ReviewerResponse::UncompactableContinuation
        ) {
            "still oversized ".repeat(/*n*/ 4_000)
        } else {
            "Previous review evidence and inspection results.".to_owned()
        };
        let index = if matches!(reviewer_response, ReviewerResponse::NextReview) {
            4
        } else {
            2
        };
        events.insert(
            index,
            sse(vec![
                json!({
                    "type": "response.output_item.done",
                    "item": {"type": "compaction", "encrypted_content": summary},
                }),
                ev_completed("review-compaction"),
            ]),
        );
    }
    let responses = responses::mount_sse_sequence(&server, events).await;
    test.submit_text_turn("Run the command if the approval reviewer allows it.")
        .await?;
    let (compact_requests, requests): (Vec<_>, Vec<_>) = responses
        .requests()
        .into_iter()
        .partition(|request| !request.inputs_of_type("compaction_trigger").is_empty());
    let guardian_requests = requests
        .iter()
        .filter(|request| {
            request.body_json()["client_metadata"]["x-openai-subagent"].as_str() == Some("guardian")
        })
        .collect::<Vec<_>>();
    if window == 1 {
        assert_eq!(requests.len(), 2);
        assert!(guardian_requests.is_empty());
        let output = requests[1].function_call_output("exec-over-budget");
        assert!(
            output
                .to_string()
                .contains("evidence exceeds limits for section request_budget"),
            "expected required-evidence budget rejection: {output}"
        );
    } else {
        let recovered = matches!(reviewer_response, ReviewerResponse::ToolContinuation);
        assert_eq!(requests.len(), if recovered { 4 } else { 3 });
        assert_eq!(guardian_requests.len(), if recovered { 2 } else { 1 });
        if recovered {
            assert_eq!(compact_requests.len(), 1);
            let compact = &compact_requests[0];
            assert!(
                compact
                    .body_json()
                    .to_string()
                    .contains("inspection-output")
            );
            let recovered = guardian_requests[1].body_json();
            assert!(
                recovered["input"]
                    .to_string()
                    .contains("Previous review evidence")
            );
            assert_eq!(
                guardian_requests[0].body_json()["client_metadata"]["thread_id"],
                recovered["client_metadata"]["thread_id"]
            );
            assert!(
                requests
                    .last()
                    .expect("parent resumes after review")
                    .function_call_output("exec-over-budget")
                    .to_string()
                    .contains("guardian-budget-test")
            );
        }
        if matches!(
            reviewer_response,
            ReviewerResponse::UncompactableContinuation
        ) {
            let output = requests
                .last()
                .expect("parent continues after the rejected review")
                .function_call_output("exec-over-budget");
            assert!(
                output
                    .to_string()
                    .contains("Codex ran out of room in the model's context window"),
                "expected context-budget rejection: {output}"
            );
        }
        let request = guardian_requests[0];
        let context = request.message_input_texts("user").join("\n");
        assert!(context.contains("<guardian_context_omission>"));
        assert!(!context.contains("optional old commentary"));
        assert!(context.contains("Run the command if the approval reviewer allows it."));
        assert!(context.contains("echo guardian-budget-test"));
        let developer_context = request.message_input_texts("developer").join("\n");
        assert!(developer_context.contains("<current_time_reminder>"));
        assert!(developer_context.contains("<rollout_budget>"));
        if matches!(
            reviewer_response,
            ReviewerResponse::UncompactableContinuation | ReviewerResponse::NextReview
        ) {
            let instruction = if matches!(reviewer_response, ReviewerResponse::NextReview) {
                "New instructions: retry the requested command and keep all files private. "
                    .repeat(/*n*/ 12)
            } else {
                "Retry the requested command.".to_owned()
            };
            test.submit_text_turn(&instruction).await?;
            let (compact_requests, requests): (Vec<_>, Vec<_>) = responses
                .requests()
                .into_iter()
                .partition(|request| !request.inputs_of_type("compaction_trigger").is_empty());
            assert_eq!(
                requests.len(),
                6,
                "parent resumed with: {}",
                requests
                    .last()
                    .expect("parent resumes after the retry")
                    .function_call_output("retry-command")
            );
            assert_eq!(compact_requests.len(), 1);
            if matches!(reviewer_response, ReviewerResponse::NextReview) {
                let compact = &compact_requests[0];
                assert!(
                    !compact
                        .body_json()
                        .to_string()
                        .contains("New instructions:"),
                    "incoming evidence must remain pending during compaction"
                );
                assert!(
                    requests[4].body_json()["input"]
                        .to_string()
                        .contains("New instructions:")
                );
                assert!(
                    requests[4].body_json()["input"]
                        .to_string()
                        .contains("Previous review evidence")
                );
                assert_eq!(
                    request.body_json()["client_metadata"]["thread_id"],
                    requests[4].body_json()["client_metadata"]["thread_id"]
                );
            } else {
                assert_ne!(
                    request.body_json()["client_metadata"]["thread_id"],
                    requests[4].body_json()["client_metadata"]["thread_id"],
                    "failed compaction must retire the reviewer"
                );
            }
            assert!(
                requests[5]
                    .function_call_output("retry-command")
                    .to_string()
                    .contains("guardian-budget-test")
            );
        }
    }
    test.codex.shutdown_and_wait().await?;
    Ok(())
}
