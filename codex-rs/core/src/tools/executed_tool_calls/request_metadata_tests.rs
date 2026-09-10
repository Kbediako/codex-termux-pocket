use codex_protocol::models::FunctionCallOutputPayload;
use codex_protocol::models::ResponseInputItem;
use codex_protocol::models::ToolResultSources;
use pretty_assertions::assert_eq;
use serde_json::json;

use super::*;

fn new_recorder() -> ExecutedToolCalls {
    let mut features = Features::default();
    features.enable(Feature::ExecutedToolCallMetadata);
    ExecutedToolCalls::new(&features)
}

fn output(call_id: &str) -> ResponseItem {
    ResponseItem::from(ResponseInputItem::FunctionCallOutput {
        call_id: call_id.to_string(),
        output: FunctionCallOutputPayload::from_text(String::new()),
    })
}

#[tokio::test]
async fn recorder_preserves_session_and_turn_gates_and_lazy_result_sources() {
    struct SourceLookup(std::cell::Cell<usize>);

    impl ToolOutput for SourceLookup {
        fn log_output(&self) -> String {
            panic!("recording must not read the diagnostic output")
        }

        fn success_for_logging(&self) -> bool {
            panic!("recording must not inspect execution success")
        }

        fn to_response_item(&self, _call_id: &str, _payload: &ToolPayload) -> ResponseInputItem {
            panic!("recording must not rebuild the tool result")
        }

        fn tool_result_sources(&self) -> Option<ToolResultSources> {
            self.0.set(self.0.get() + 1);
            Some(ToolResultSources::new(Vec::new()))
        }
    }

    let (_session, turn) = crate::session::tests::make_session_and_context().await;
    let mut turn = Arc::new(turn);
    assert!(ExecutedToolCalls::default().state.is_none());
    for session_enabled in [false, true] {
        let mut features = Features::default();
        features.set_enabled(Feature::ExecutedToolCallMetadata, session_enabled);
        for turn_enabled in [false, true] {
            let calls = ExecutedToolCalls::new(&features);
            assert_eq!(calls.state.is_some(), session_enabled);
            Arc::make_mut(
                &mut Arc::get_mut(&mut turn)
                    .expect("the previous step must have released its turn")
                    .config,
            )
            .features
            .set_enabled(Feature::ExecutedToolCallMetadata, turn_enabled)
            .expect("test feature must be configurable");
            let step = StepContext::for_test(Arc::clone(&turn));
            assert_eq!(
                ExecutedToolCalls::is_enabled(&step.turn.config.features),
                turn_enabled
            );

            let call = ToolCall {
                tool_name: codex_tools::ToolName::plain("test_tool"),
                call_id: "call".to_string(),
                payload: ToolPayload::Function {
                    arguments: r#"{"value":7}"#.to_string(),
                },
                encrypted_function_args: None,
            };
            calls.record_tool_call(&call, &ToolCallSource::Direct, &step);
            let result = SourceLookup(std::cell::Cell::new(0));
            calls.record_accepted_result(&ToolCallSource::Direct, &call.call_id, &result);
            // Accepted sources follow session availability even when this turn stops recording calls.
            assert_eq!(result.0.get(), usize::from(session_enabled));

            let input = serde_json::from_value(json!({
                "type": "function_call",
                "call_id": "call",
                "name": "test_tool",
                "arguments": "{\"value\":7}",
            }))
            .expect("tool input must deserialize");
            let mut prompt = vec![input, output("call")];
            if !session_enabled {
                prompt[1].mark_tool_calls_complete();
            }
            let original = prompt.clone();
            calls.attach_to_prompt(&mut prompt, &mut HashMap::new());
            if !session_enabled {
                assert_eq!(prompt, original);
            }
            let mut expected_call =
                ExecutedToolCall::new("test_tool".to_string(), json!({"value": 7}));
            assert!(expected_call.set_tool_result_sources(ToolResultSources::new(Vec::new())));
            let expected_calls = vec![expected_call];
            assert_eq!(
                prompt[1]
                    .executed_tool_call_metadata()
                    .and_then(|metadata| metadata.executed_tool_calls.as_ref()),
                (session_enabled && turn_enabled).then_some(&expected_calls),
                "session_enabled={session_enabled}, turn_enabled={turn_enabled}",
            );
        }
    }
}

#[test]
fn executed_tool_call_recorder_bounds_pending_calls_and_preserves_overflow() {
    let recorder = new_recorder();

    for index in 0..MAX_PENDING_EXECUTED_TOOL_CALLS + 2 {
        recorder.record_call(
            &ToolCall {
                tool_name: codex_tools::ToolName::plain("direct_tool"),
                call_id: format!("direct-{index}"),
                payload: ToolPayload::Function {
                    arguments: "{}".to_string(),
                },
                encrypted_function_args: None,
            },
            &ToolCallSource::Direct,
            ToolMode::Direct,
        );
    }
    assert!(recorder.record_tool_result_sources(
        &ToolCallSource::Direct,
        "direct-0",
        ToolResultSources::new(Vec::new())
    ));

    let cell_id = CellId::new("bounded-cell".to_string());
    recorder.start_cell(&cell_id, "bounded-output");
    for index in 0..MAX_PENDING_EXECUTED_TOOL_CALLS + 2 {
        recorder.record_nested_tool_call(
            cell_id.clone(),
            format!("nested-{index}"),
            ExecutedToolCall::new("nested_tool".to_string(), json!({})),
            /*original_bytes*/ 2,
        );
    }

    for index in 0..MAX_PENDING_EXECUTED_TOOL_CALLS + 2 {
        recorder.register_cell(
            &CellId::new(format!("cell-{index}")),
            &format!("output-{index}"),
        );
    }

    {
        let state = recorder
            .state
            .as_ref()
            .unwrap()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(
            state.direct_calls.len(),
            MAX_PENDING_EXECUTED_TOOL_CALLS + 1
        );
        assert_eq!(
            serde_json::to_value(
                state
                    .direct_calls
                    .get(&format!("direct-{MAX_PENDING_EXECUTED_TOOL_CALLS}"))
                    .expect("first excess direct call must be marked"),
            )
            .expect("direct overflow marker must serialize"),
            json!({
                "name": "direct_tool",
                "arguments": {
                    "_codex_executed_tool_call_truncated": {
                        "original_bytes": 2,
                        "max_bytes": 0,
                    },
                },
            }),
        );
        assert_eq!(
            state.pending_nested_calls,
            MAX_PENDING_EXECUTED_TOOL_CALLS + 1
        );
        assert_eq!(state.cells.len(), MAX_PENDING_EXECUTED_TOOL_CALLS);
        assert_eq!(state.output_cells.len(), MAX_PENDING_EXECUTED_TOOL_CALLS);
    }

    let mut items = [ResponseItem::FunctionCallOutput {
        id: None,
        call_id: Some("bounded-output".to_string()),
        name: None,
        namespace: None,
        output: FunctionCallOutputPayload::from_text(String::new()),
        internal_chat_message_metadata_passthrough: None,
    }];
    let mut retry_cache = HashMap::new();
    recorder.finish_cell_recording(&cell_id);
    recorder.attach_pending_to_prompt(&mut items, &mut retry_cache);

    assert_eq!(
        items[0]
            .executed_tool_call_metadata()
            .and_then(|metadata| metadata.tool_calls_complete),
        None,
    );
    let calls = items[0]
        .executed_tool_call_metadata()
        .and_then(|metadata| metadata.executed_tool_calls.as_ref())
        .expect("bounded nested calls must attach to their own output");
    assert_eq!(calls.len(), MAX_PENDING_EXECUTED_TOOL_CALLS + 1);
    assert_eq!(
        serde_json::to_value(calls.last().expect("overflow marker must be retained"))
            .expect("nested overflow marker must serialize"),
        json!({
            "name": "nested_tool",
            "arguments": {
                "_codex_executed_tool_call_truncated": {
                    "original_bytes": 2,
                    "max_bytes": 0,
                },
            },
        }),
    );
    let expected_calls = calls.clone();

    {
        let state = recorder
            .state
            .as_ref()
            .unwrap()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(state.pending_nested_calls, 0);
        assert!(!state.cells.contains_key(&cell_id));
        assert_eq!(retry_cache.len(), 1);
    }

    let mut replayed_items = [ResponseItem::FunctionCallOutput {
        id: None,
        call_id: Some("bounded-output".to_string()),
        name: None,
        namespace: None,
        output: FunctionCallOutputPayload::from_text(String::new()),
        internal_chat_message_metadata_passthrough: None,
    }];
    let mut replay_retry_cache = HashMap::new();
    assert!(recorder.attach_pending_to_prompt(&mut replayed_items, &mut replay_retry_cache));
    assert_eq!(
        replayed_items[0]
            .executed_tool_call_metadata()
            .and_then(|metadata| metadata.executed_tool_calls.as_ref()),
        Some(&expected_calls),
    );

    let mut compacted_retry_cache = HashMap::new();
    assert!(!recorder.attach_pending_to_prompt(&mut [], &mut compacted_retry_cache));
    let state = recorder
        .state
        .as_ref()
        .unwrap()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert!(state.retained_calls.is_empty());
}

#[test]
fn executed_tool_call_recorder_bounds_retained_history_and_reports_omissions() {
    let recorder = new_recorder();
    let mut history = Vec::new();
    let arguments = serde_json::to_string(&json!({ "payload": "x".repeat(1024) }))
        .expect("tool arguments must serialize");
    let mut prompt = Vec::new();

    for index in 0..512 {
        let call_id = format!("retained-{index}");
        recorder.record_call(
            &ToolCall {
                tool_name: codex_tools::ToolName::plain(format!("retained_tool_{index}")),
                call_id: call_id.clone(),
                payload: ToolPayload::Function {
                    arguments: arguments.clone(),
                },
                encrypted_function_args: None,
            },
            &ToolCallSource::Direct,
            ToolMode::Direct,
        );
        history.push(ResponseItem::FunctionCallOutput {
            id: None,
            call_id: Some(call_id),
            name: None,
            namespace: None,
            output: FunctionCallOutputPayload::from_text(String::new()),
            internal_chat_message_metadata_passthrough: None,
        });
        prompt = history.clone();
        assert!(recorder.attach_pending_to_prompt(&mut prompt, &mut HashMap::new()));
        codex_protocol::models::bound_executed_tool_calls_for_prompt(&mut prompt);
        let latest_call = prompt
            .last()
            .and_then(ResponseItem::executed_tool_call_metadata)
            .and_then(|metadata| metadata.executed_tool_calls.as_ref())
            .and_then(|calls| calls.first())
            .map(serde_json::to_value)
            .transpose()
            .expect("latest tool call must serialize")
            .expect("latest tool call must remain in retained metadata");
        assert_eq!(latest_call["name"], format!("retained_tool_{index}"));
        assert_eq!(
            latest_call["arguments"],
            json!({ "payload": "x".repeat(1024) }),
        );
    }

    let state = recorder
        .state
        .as_ref()
        .unwrap()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let retained_bytes = state
        .retained_calls
        .values()
        .map(|retained| serialized_json_bytes(&retained.calls))
        .sum::<serde_json::Result<usize>>()
        .expect("retained calls must serialize");
    assert!(retained_bytes <= MAX_EXECUTED_TOOL_CALL_FULL_ARGUMENT_BYTES_PER_OUTPUT);

    let metadata = prompt
        .iter()
        .filter_map(ResponseItem::executed_tool_call_metadata)
        .filter_map(|metadata| metadata.executed_tool_calls.as_ref())
        .flatten()
        .map(|call| serde_json::to_value(call).expect("retained call must serialize"))
        .collect::<Vec<_>>();
    let omitted_calls = metadata
        .iter()
        .filter_map(|call| {
            call["arguments"]["_codex_executed_tool_call_truncated"]["omitted_calls"].as_u64()
        })
        .sum::<u64>();
    assert!(omitted_calls > 0);
    assert_eq!(metadata.len() as u64 + omitted_calls, 512);
}

#[test]
fn tool_call_completeness_requires_finished_lossless_recording() {
    for scenario in ["empty", "unobserved", "late_call"] {
        let recorder = new_recorder();
        let cell_id = CellId::new(scenario.to_string());
        if scenario == "unobserved" {
            recorder.register_cell(&cell_id, "output");
        } else {
            recorder.start_cell(&cell_id, "output");
        }
        if scenario == "late_call" {
            recorder.finish_cell_recording(&cell_id);
        }
        if scenario != "empty" {
            recorder.record_nested_tool_call(
                cell_id.clone(),
                "nested-call".to_string(),
                ExecutedToolCall::new("nested_tool".to_string(), json!({})),
                /*original_bytes*/ 2,
            );
        }
        recorder.finish_cell_recording(&cell_id);

        let mut items = [output("output")];
        recorder.attach_pending_to_prompt(&mut items, &mut HashMap::new());
        assert_eq!(
            items[0]
                .executed_tool_call_metadata()
                .and_then(|metadata| metadata.tool_calls_complete),
            None,
            "{scenario} must not claim complete recording",
        );
    }
}

#[test]
fn tool_call_completeness_survives_waits_without_changing_deltas() {
    let sources = ToolResultSources::new(vec![codex_protocol::models::ToolResultSource {
        r#type: "test_channel".to_string(),
        id: "CLATE".to_string(),
    }]);
    for (truncated, sources) in [
        (false, sources.clone()),
        (true, sources),
        (false, ToolResultSources::parse_failed()),
        (true, ToolResultSources::parse_failed()),
    ] {
        let recorder = new_recorder();
        let cell_id = CellId::new("multi-wait".to_string());
        recorder.start_cell(&cell_id, "exec");
        let mut history = Vec::new();
        let mut expected = Vec::new();
        let mut retry_cache = HashMap::new();
        for (index, call_id) in ["exec", "wait-1", "wait-2", "wait-3"]
            .into_iter()
            .enumerate()
        {
            recorder.register_cell(&cell_id, call_id);
            let mut expected_output = output(call_id);
            history.push(expected_output.clone());
            if index < 2 {
                // Identical calls are distinct submissions; truncation stays sticky across waits.
                let original_bytes = if truncated && index == 1 { 9_000 } else { 2 };
                let call = if original_bytes > MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES {
                    ExecutedToolCall::truncated(
                        "nested_tool".to_string(),
                        original_bytes,
                        MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES,
                    )
                } else {
                    ExecutedToolCall::new("nested_tool".to_string(), json!({}))
                };
                recorder.record_nested_tool_call(
                    cell_id.clone(),
                    format!("nested-{index}"),
                    call.clone(),
                    original_bytes,
                );
                let mut call = call;
                if index == 1 {
                    let source = |cell_id: &str| ToolCallSource::CodeMode {
                        cell_id: cell_id.to_string(),
                        runtime_tool_call_id: "runtime-call".to_string(),
                    };
                    assert!(!recorder.record_tool_result_sources(
                        &source("other-cell"),
                        "nested-0",
                        ToolResultSources::new(Vec::new()),
                    ));
                    let source = source(cell_id.as_str());
                    assert!(recorder.record_tool_result_sources(
                        &source,
                        "nested-0",
                        sources.clone(),
                    ));
                    let mut delayed_call =
                        ExecutedToolCall::new("nested_tool".to_string(), json!({}));
                    assert!(delayed_call.set_tool_result_sources(sources.clone()));
                    let mut delayed_output = output("exec");
                    delayed_output.append_executed_tool_calls(vec![delayed_call]);
                    delayed_output.set_tool_call_cell_id("exec");
                    expected[0] = delayed_output;
                    assert!(recorder.record_tool_result_sources(
                        &source,
                        "nested-1",
                        ToolResultSources::new(Vec::new())
                    ));
                    assert!(call.set_tool_result_sources(ToolResultSources::new(Vec::new())));
                }
                expected_output.append_executed_tool_calls(vec![call]);
            } else if index == 3 {
                recorder.finish_cell_recording(&cell_id);
            }
            if index < 2 || index == 3 && !truncated {
                expected_output.set_tool_call_cell_id("exec");
            }
            if index == 3 && !truncated {
                expected_output.mark_tool_calls_complete();
            }
            expected.push(expected_output);
            for _ in 0..2 {
                let mut prompt = history.clone();
                assert!(recorder.attach_pending_to_prompt(&mut prompt, &mut retry_cache));
                assert_eq!(prompt, expected);
            }
        }
        let state = recorder.state.as_ref().unwrap().lock().unwrap();
        assert!(state.cells.is_empty());
        assert_eq!(state.pending_nested_calls, 0);
    }
}

#[test]
fn cell_correlation_uses_originating_exec_across_runtime_restarts() {
    let runtime_cell_id = CellId::new("1".to_string());

    for originating_call_id in ["first-exec", "resumed-exec"] {
        let recorder = new_recorder();
        recorder.start_cell(&runtime_cell_id, originating_call_id);
        recorder.record_nested_tool_call(
            runtime_cell_id.clone(),
            "nested-call".to_string(),
            ExecutedToolCall::new("nested_tool".to_string(), json!({})),
            /*original_bytes*/ 2,
        );

        let mut initial = [output(originating_call_id)];
        recorder.attach_pending_to_prompt(&mut initial, &mut HashMap::new());
        assert_eq!(
            initial[0]
                .executed_tool_call_metadata()
                .and_then(|metadata| metadata.cell_id.as_deref()),
            Some(originating_call_id),
        );

        recorder.register_cell(&runtime_cell_id, "wait");
        recorder.finish_cell_recording(&runtime_cell_id);
        let mut final_output = [output("wait")];
        recorder.attach_pending_to_prompt(&mut final_output, &mut HashMap::new());
        let metadata = final_output[0]
            .executed_tool_call_metadata()
            .expect("completed cell must have metadata");
        assert_eq!(metadata.cell_id.as_deref(), Some(originating_call_id));
        assert_eq!(metadata.tool_calls_complete, Some(true));
    }
}

#[test]
fn request_truncation_prevents_completion_after_compaction() {
    let recorder = new_recorder();
    let cell_id = CellId::new("compacted-cell".to_string());
    recorder.start_cell(&cell_id, "exec");

    let arguments = json!({
        "payload": "x".repeat(MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES - r#"{"payload":""}"#.len()),
    });
    for index in 0..4 {
        recorder.record_nested_tool_call(
            cell_id.clone(),
            format!("nested-{index}"),
            ExecutedToolCall::new("nested_tool".to_string(), arguments.clone()),
            MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES,
        );
    }

    let mut initial = [output("exec")];
    assert!(recorder.attach_pending_to_prompt(&mut initial, &mut HashMap::new()));
    assert!(
        initial[0]
            .executed_tool_call_metadata()
            .and_then(|metadata| metadata.executed_tool_calls.as_ref())
            .is_some_and(|calls| calls.iter().any(|call| matches!(
                call.arguments(),
                ExecutedToolCallArguments::Truncated { .. }
            )))
    );
    let source = ToolCallSource::CodeMode {
        cell_id: cell_id.as_str().to_string(),
        runtime_tool_call_id: "runtime-call".to_string(),
    };
    for index in 0..4 {
        assert!(!recorder.record_tool_result_sources(
            &source,
            &format!("nested-{index}"),
            ToolResultSources::new(Vec::new()),
        ));
    }

    recorder.attach_pending_to_prompt(&mut [], &mut HashMap::new());
    recorder.register_cell(&cell_id, "wait");
    recorder.finish_cell_recording(&cell_id);
    let mut final_output = [output("wait")];
    recorder.attach_pending_to_prompt(&mut final_output, &mut HashMap::new());
    assert_eq!(
        final_output[0]
            .executed_tool_call_metadata()
            .and_then(|metadata| metadata.tool_calls_complete),
        None,
    );
}

#[test]
fn source_shedding_preserves_completion_after_compaction() {
    let recorder = new_recorder();
    let cell_id = CellId::new("compacted-cell".to_string());
    recorder.start_cell(&cell_id, "exec");

    let argument_bytes = MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES - 256;
    let arguments = json!({
        "payload": "x".repeat(argument_bytes - r#"{"payload":""}"#.len()),
    });
    for index in 0..4 {
        recorder.record_nested_tool_call(
            cell_id.clone(),
            format!("nested-{index}"),
            ExecutedToolCall::new("nested_tool".to_string(), arguments.clone()),
            argument_bytes,
        );
    }
    let source = ToolCallSource::CodeMode {
        cell_id: cell_id.as_str().to_string(),
        runtime_tool_call_id: "runtime-call".to_string(),
    };
    let mut retry_cache = HashMap::new();
    recorder.attach_pending_to_prompt(&mut [output("exec")], &mut retry_cache);
    assert!(
        recorder.record_tool_result_sources(
            &source,
            "nested-0",
            ToolResultSources::new(
                (0..32)
                    .map(|index| codex_protocol::models::ToolResultSource {
                        r#type: "test_channel".to_string(),
                        id: format!("C{index:063}"),
                    })
                    .collect()
            ),
        )
    );

    assert!(recorder.record_tool_result_sources(
        &source,
        "nested-1",
        ToolResultSources::parse_failed()
    ));
    let mut initial = [output("exec")];
    assert!(recorder.attach_pending_to_prompt(&mut initial, &mut retry_cache));
    let calls = initial[0]
        .executed_tool_call_metadata()
        .and_then(|metadata| metadata.executed_tool_calls.as_ref())
        .expect("source shedding must preserve recorded calls");
    assert_eq!(
        calls,
        &vec![ExecutedToolCall::new("nested_tool".to_string(), arguments); 4]
    );
    assert!(!recorder.record_tool_result_sources(
        &source,
        "nested-0",
        ToolResultSources::new(Vec::new())
    ));
    let mut retry = [output("exec")];
    assert!(recorder.attach_pending_to_prompt(&mut retry, &mut retry_cache));
    assert_eq!(retry, initial);

    recorder.attach_pending_to_prompt(&mut [], &mut retry_cache);
    assert!(retry_cache.is_empty());
    assert!(!recorder.record_tool_result_sources(
        &source,
        "nested-1",
        ToolResultSources::new(Vec::new())
    ));
    recorder.register_cell(&cell_id, "wait");
    recorder.finish_cell_recording(&cell_id);
    let mut final_output = [output("wait")];
    recorder.attach_pending_to_prompt(&mut final_output, &mut HashMap::new());
    assert_eq!(
        final_output[0]
            .executed_tool_call_metadata()
            .and_then(|metadata| metadata.tool_calls_complete),
        Some(true),
    );
}

#[test]
fn finished_cells_without_more_waits_do_not_block_new_calls() {
    let recorder = new_recorder();
    let call = ExecutedToolCall::new("nested_tool".to_string(), json!({}));
    for index in 0..MAX_PENDING_EXECUTED_TOOL_CALLS {
        let cell = CellId::new(format!("cell-{index}"));
        recorder.start_cell(&cell, cell.as_str());
        recorder.record_nested_tool_call(
            cell.clone(),
            format!("nested-{index}"),
            call.clone(),
            /*original_bytes*/ 2,
        );
        recorder.attach_pending_to_prompt(&mut [output(cell.as_str())], &mut HashMap::new());
        recorder.finish_cell_recording(&cell);
    }
    let fresh = CellId::new("fresh".to_string());
    recorder.start_cell(&fresh, "fresh-output");
    recorder.record_nested_tool_call(
        fresh.clone(),
        "fresh-call".to_string(),
        call.clone(),
        /*original_bytes*/ 2,
    );
    recorder.finish_cell_recording(&fresh);
    let mut expected = output("fresh-output");
    expected.append_executed_tool_calls(vec![call]);
    expected.set_tool_call_cell_id("fresh-output");
    expected.mark_tool_calls_complete();
    let mut items = [output("fresh-output")];
    assert!(recorder.attach_pending_to_prompt(&mut items, &mut HashMap::new()));
    assert_eq!(items, [expected]);
}
