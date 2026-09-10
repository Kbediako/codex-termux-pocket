//! Compaction checkpoints retain the summary captured after a mid-turn settings update.

use super::*;
use codex_history::RolloutItem;
use core_test_support::responses;
use pretty_assertions::assert_eq;
use test_case::test_case;

#[derive(Clone, Copy)]
enum CompactionMode {
    Local,
    Remote,
    RemoteV2,
}

#[test_case(CompactionMode::Local; "local")]
#[test_case(CompactionMode::Remote; "remote")]
#[test_case(CompactionMode::RemoteV2; "remote v2")]
#[tokio::test]
async fn compaction_preserves_updated_summary(mode: CompactionMode) -> Result<()> {
    skip_if_no_network!(Ok(()));
    let server = start_mock_server().await;
    let mut bodies = vec![
        paused_response("pause", "pause-call"),
        sse(vec![
            ev_function_call(
                "plan",
                "update_plan",
                &json!({"plan": [{"step": "Finish the answer", "status": "in_progress"}]})
                    .to_string(),
            ),
            responses::ev_completed_with_tokens("plan-response", /*total_tokens*/ 330_000),
        ]),
    ];
    let compact = match mode {
        CompactionMode::Local => {
            bodies.push(sse(vec![
                responses::ev_assistant_message("summary", "Compacted history"),
                ev_completed("compact"),
            ]));
            None
        }
        CompactionMode::Remote => Some(
            responses::mount_compact_user_history_with_summary_once(&server, "encrypted-summary")
                .await,
        ),
        CompactionMode::RemoteV2 => {
            bodies.push(sse(vec![json!({"type": "response.output_item.done", "item": {"type": "compaction", "encrypted_content": "encrypted-summary"}}), ev_completed("compact")]));
            None
        }
    };
    bodies.push(sse_completed("done"));
    let responses = mount_sse_sequence(&server, bodies).await;
    let test = step_settings_test()
        .with_auth(CodexAuth::create_dummy_chatgpt_auth_for_testing())
        .with_config(move |config| {
            config.model_auto_compact_token_limit = Some(200_000);
            config
                .features
                .disable(Feature::TokenBudget)
                .expect("disable token budget");
            config.model_provider.name = match mode {
                CompactionMode::Local => "Local compaction test",
                CompactionMode::Remote | CompactionMode::RemoteV2 => "OpenAI",
            }
            .to_string();
            if matches!(mode, CompactionMode::RemoteV2) {
                config
                    .features
                    .enable(Feature::RemoteCompactionV2)
                    .expect("enable v2");
            } else {
                config
                    .features
                    .disable(Feature::RemoteCompactionV2)
                    .expect("disable v2");
            }
        })
        .build_with_auto_env(&server)
        .await?;
    let pause = start_paused_turn(&test.codex).await?;
    assert_eq!(
        submit_turn_settings(
            &test.codex,
            &pause.turn_id,
            TurnSettingsUpdate {
                summary: Some(ReasoningSummary::Detailed),
                ..Default::default()
            }
        )
        .await?,
        TurnSettingsUpdateOutcome::Applied
    );
    answer_paused_turn(&test.codex, &pause.turn_id).await?;
    wait_for_event(&test.codex, |event| {
        matches!(event, EventMsg::TurnComplete(_))
    })
    .await;
    test.codex.shutdown_and_wait().await?;

    let requests = responses.requests();
    assert_eq!(
        [
            requests[0].body_json()["reasoning"]["summary"].clone(),
            requests[1].body_json()["reasoning"]["summary"].clone()
        ],
        [json!("concise"), json!("detailed")]
    );
    if let Some(compact) = compact {
        compact.single_request();
    }
    let rollout =
        std::fs::read_to_string(test.session_configured.rollout_path.expect("rollout path"))?;
    let items = rollout
        .lines()
        .map(codex_rollout::parse_rollout_line)
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let checkpoint = items
        .iter()
        .skip_while(|line| !matches!(line.item, RolloutItem::Compacted(_)))
        .skip(/*n*/ 1)
        .take_while(|line| !matches!(line.item, RolloutItem::EventMsg(_)))
        .find_map(|line| match &line.item {
            RolloutItem::TurnContext(context) => Some(context.summary),
            _ => None,
        });
    assert_eq!(checkpoint, Some(ReasoningSummary::Detailed));
    Ok(())
}
