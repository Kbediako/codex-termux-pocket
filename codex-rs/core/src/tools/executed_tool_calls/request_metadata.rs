//! Attaches host observations to request metadata and applies its byte budget.
//! Final request budgeting runs after the recorder lock is released; it never changes tool execution.

use super::*;

impl ExecutedToolCalls {
    /// Attaches host-recorded calls within the existing request metadata budget.
    pub(crate) fn attach_to_prompt(
        &self,
        items: &mut [ResponseItem],
        retry_cache: &mut ExecutedToolCallCache,
    ) {
        if self.attach_pending_to_prompt(items, retry_cache) {
            bound_executed_tool_calls_for_prompt(items);
        }
    }

    fn attach_pending_to_prompt(
        &self,
        items: &mut [ResponseItem],
        retry_cache: &mut ExecutedToolCallCache,
    ) -> bool {
        let Some(state) = &self.state else {
            return false;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.direct_calls.is_empty()
            && state.output_cells.is_empty()
            && state.retained_calls.is_empty()
            && retry_cache.is_empty()
        {
            return false;
        }

        // Updated records supersede older retry snapshots.
        retry_cache.retain(|key, _| {
            !state
                .retained_calls
                .get(key)
                .is_some_and(|retained| retained.sources_updated)
        });
        let mut pending_retry_outputs = retry_cache.keys().cloned().collect::<HashSet<_>>();
        let mut pending_retained_outputs =
            state.retained_calls.keys().cloned().collect::<HashSet<_>>();
        let mut attached = false;
        let mut retained_bytes = 0_usize;
        for item in items.iter_mut().rev() {
            if state.direct_calls.is_empty()
                && state.output_cells.is_empty()
                && pending_retry_outputs.is_empty()
                && pending_retained_outputs.is_empty()
            {
                break;
            }
            let call_id = match &*item {
                ResponseItem::FunctionCallOutput {
                    call_id: Some(call_id),
                    ..
                }
                | ResponseItem::CustomToolCallOutput { call_id, .. }
                | ResponseItem::ToolSearchOutput {
                    call_id: Some(call_id),
                    ..
                } => call_id,
                _ => continue,
            };
            let key = (std::mem::discriminant(&*item), call_id.clone());
            let retained = state.retained_calls.get(&key);
            let mut complete = retained.is_some_and(|retained| retained.complete);
            let mut cell_id = retained.and_then(|retained| retained.cell_id.clone());
            let mut runtime_cell_id =
                retained.and_then(|retained| retained.runtime_cell_id.clone());
            let calls = if let Some(cached) = retry_cache.get(&key) {
                if !pending_retry_outputs.remove(&key) {
                    continue;
                }
                pending_retained_outputs.remove(&key);
                cached.clone()
            } else if let Some(retained) = retained {
                if !pending_retained_outputs.remove(&key) {
                    continue;
                }
                retained.calls.clone()
            } else {
                let mut calls = state
                    .direct_calls
                    .remove(call_id)
                    .into_iter()
                    .collect::<Vec<_>>();
                let mut call_index_by_id = HashMap::new();
                if let Some(output_cell_id) = state.output_cells.remove(call_id)
                    && let Some(cell) = state.cells.get_mut(&output_cell_id)
                {
                    cell_id = cell.originating_call_id.clone();
                    runtime_cell_id = Some(output_cell_id.clone());
                    let pending_calls = cell.pending_calls.len();
                    for (call_id, call) in cell.pending_calls.drain(..) {
                        if matches!(call.arguments(), ExecutedToolCallArguments::Raw(_)) {
                            call_index_by_id.insert(call_id, calls.len());
                        }
                        calls.push(call);
                    }
                    cell.pending_full_argument_bytes = 0;
                    complete = cell.completion == CellCompletion::Complete;
                    if matches!(
                        cell.completion,
                        CellCompletion::Complete | CellCompletion::Incomplete
                    ) {
                        state.cells.remove(&output_cell_id);
                    }
                    state.pending_nested_calls =
                        state.pending_nested_calls.saturating_sub(pending_calls);
                    state
                        .output_cells
                        .retain(|_, registered_cell_id| registered_cell_id != &output_cell_id);
                }
                if calls.is_empty() && !complete {
                    continue;
                }
                retry_cache.insert(key.clone(), calls.clone());
                state.retained_calls.insert(
                    key,
                    RetainedToolCalls {
                        calls: calls.clone(),
                        complete,
                        cell_id: cell_id.clone(),
                        runtime_cell_id,
                        call_index_by_id,
                        sources_updated: false,
                    },
                );
                calls
            };
            item.append_executed_tool_calls(calls);
            if let Some(cell_id) = cell_id {
                item.set_tool_call_cell_id(&cell_id);
            }
            if complete {
                item.mark_tool_calls_complete();
            }
            retained_bytes = retained_bytes.saturating_add(executed_tool_call_metadata_bytes(item));
            attached = true;
        }
        if !pending_retained_outputs.is_empty() {
            state
                .retained_calls
                .retain(|key, _| !pending_retained_outputs.contains(key));
        }
        if retained_bytes > MAX_EXECUTED_TOOL_CALL_FULL_ARGUMENT_BYTES_PER_OUTPUT {
            bound_executed_tool_calls_for_prompt_prioritizing_recent(items);
            let retained_before_bounding = std::mem::take(&mut state.retained_calls);
            let mut bounded_outputs = HashSet::new();
            for item in items {
                let call_id = match &*item {
                    ResponseItem::FunctionCallOutput {
                        call_id: Some(call_id),
                        ..
                    }
                    | ResponseItem::CustomToolCallOutput { call_id, .. }
                    | ResponseItem::ToolSearchOutput {
                        call_id: Some(call_id),
                        ..
                    } => call_id,
                    _ => continue,
                };
                let key = (std::mem::discriminant(&*item), call_id.clone());
                let metadata = item.executed_tool_call_metadata();
                let unique_output = bounded_outputs.insert(key.clone());
                if !unique_output && let Some(retained) = state.retained_calls.get_mut(&key) {
                    retained.call_index_by_id.clear();
                }
                let previous = retained_before_bounding.get(&key);
                if let Some(retained) = previous
                    && let Some(runtime_cell_id) = &retained.runtime_cell_id
                    && metadata
                        .is_none_or(|metadata| !metadata.has_same_tool_calls(&retained.calls))
                    && let Some(cell) = state.cells.get_mut(runtime_cell_id)
                {
                    cell.completion = CellCompletion::Incomplete;
                }
                if let Some(metadata) = metadata
                    && (metadata
                        .executed_tool_calls
                        .as_ref()
                        .is_some_and(|calls| !calls.is_empty())
                        || metadata.tool_calls_complete.is_some())
                {
                    let runtime_cell_id =
                        previous.and_then(|retained| retained.runtime_cell_id.clone());
                    // Budget rewriting or duplicate outputs invalidate the original index slots.
                    let call_index_by_id = previous
                        .filter(|retained| {
                            unique_output
                                && metadata.executed_tool_calls.as_ref() == Some(&retained.calls)
                        })
                        .map(|retained| retained.call_index_by_id.clone())
                        .unwrap_or_default();
                    let retained = state.retained_calls.entry(key).or_default();
                    retained.runtime_cell_id = runtime_cell_id;
                    retained.calls = metadata.executed_tool_calls.clone().unwrap_or_default();
                    if let Some(cell_id) = metadata.cell_id.as_ref() {
                        retained.cell_id = Some(cell_id.clone());
                    }
                    retained.complete |= metadata.tool_calls_complete == Some(true);
                    retained.call_index_by_id = call_index_by_id;
                    retained.sources_updated =
                        previous.is_some_and(|retained| retained.sources_updated);
                }
            }
        }

        attached
    }
}

#[cfg(test)]
#[path = "request_metadata_tests.rs"]
mod tests;
