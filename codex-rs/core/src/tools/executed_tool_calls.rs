//! Records attempted calls at existing execution boundaries. Request metadata policy
//! lives in the private request metadata module; this recorder must never dispatch or await tools.

mod request_metadata;

use std::collections::HashMap;
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::Mutex;

use codex_code_mode::CellId;
use codex_features::Feature;
use codex_features::Features;
use codex_protocol::models::ExecutedToolCall;
use codex_protocol::models::ExecutedToolCallArguments;
use codex_protocol::models::ResponseItem;
use codex_protocol::models::bound_executed_tool_calls_for_prompt;
use codex_protocol::models::bound_executed_tool_calls_for_prompt_prioritizing_recent;
use codex_protocol::models::executed_tool_call_metadata_bytes;
use codex_protocol::openai_models::ToolMode;
use indexmap::IndexMap;
use serde_json::Value as JsonValue;

use crate::session::step_context::StepContext;
use crate::tools::context::ToolCallSource;
use crate::tools::context::ToolOutput;
use crate::tools::context::ToolPayload;
use crate::tools::router::ToolCall;
use crate::utils::json::serialized_json_bytes;

const MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES: usize = 8 * 1024;
const MAX_EXECUTED_TOOL_CALL_FULL_ARGUMENT_BYTES_PER_OUTPUT: usize = 32 * 1024;
const MAX_PENDING_EXECUTED_TOOL_CALLS: usize = 256;

type ExecutedToolCallCache =
    HashMap<(std::mem::Discriminant<ResponseItem>, String), Vec<ExecutedToolCall>>;

/// Best-effort recording shared by a session and its Code Mode broker. Disabled
/// sessions allocate no state; missing calls and truncated evidence remain incomplete.
#[derive(Clone, Default)]
pub(crate) struct ExecutedToolCalls {
    state: Option<Arc<Mutex<ExecutedToolCallRecorderState>>>,
}

#[derive(Default)]
struct ExecutedToolCallRecorderState {
    direct_calls: HashMap<String, ExecutedToolCall>,
    cells: HashMap<CellId, RecordedCell>,
    output_cells: HashMap<String, CellId>,
    retained_calls: HashMap<(std::mem::Discriminant<ResponseItem>, String), RetainedToolCalls>,
    pending_nested_calls: usize,
}

/// Keep each output's calls and completion marker together through replay and pruning.
#[derive(Default)]
struct RetainedToolCalls {
    calls: Vec<ExecutedToolCall>,
    complete: bool,
    cell_id: Option<String>,
    runtime_cell_id: Option<CellId>,
    // Invocation IDs stay local and are retained only with their original output's calls.
    call_index_by_id: HashMap<String, usize>,
    sources_updated: bool,
}

#[derive(Default, PartialEq, Eq)]
enum CellCompletion {
    #[default]
    Unobserved,
    Started,
    Recording,
    Incomplete,
    Complete,
}

#[derive(Default)]
struct RecordedCell {
    pending_calls: IndexMap<String, ExecutedToolCall>,
    pending_full_argument_bytes: usize,
    completion: CellCompletion,
    originating_call_id: Option<String>,
}

impl ExecutedToolCallRecorderState {
    fn register_cell(&mut self, cell_id: &CellId, output_call_id: &str) {
        if self.cells.len() >= MAX_PENDING_EXECUTED_TOOL_CALLS && !self.cells.contains_key(cell_id)
        {
            let output_cells = self.output_cells.values().collect::<HashSet<_>>();
            let finished_cell = self.cells.iter().find_map(|(id, cell)| {
                // A finished cell can still have missing or truncated tool call records.
                (matches!(
                    cell.completion,
                    CellCompletion::Complete | CellCompletion::Incomplete
                ) && cell.pending_calls.is_empty()
                    && !output_cells.contains(id))
                .then(|| id.clone())
            });
            if let Some(id) = finished_cell {
                self.cells.remove(&id);
            }
        }
        if (self.cells.len() >= MAX_PENDING_EXECUTED_TOOL_CALLS
            && !self.cells.contains_key(cell_id))
            || (self.output_cells.len() >= MAX_PENDING_EXECUTED_TOOL_CALLS
                && !self.output_cells.contains_key(output_call_id))
        {
            return;
        }
        self.cells
            .entry(cell_id.clone())
            .or_default()
            .originating_call_id
            .get_or_insert_with(|| output_call_id.to_string());
        self.output_cells
            .insert(output_call_id.to_string(), cell_id.clone());
    }
}

impl ExecutedToolCalls {
    pub(crate) fn new(features: &Features) -> Self {
        Self {
            state: Self::is_enabled(features)
                .then(|| Arc::new(Mutex::new(ExecutedToolCallRecorderState::default()))),
        }
    }

    /// The turn's feature policy is independent of whether this session has a recorder.
    pub(crate) fn is_enabled(features: &Features) -> bool {
        features.enabled(Feature::ExecutedToolCallMetadata)
    }

    pub(crate) fn record_tool_call(
        &self,
        call: &ToolCall,
        source: &ToolCallSource,
        step_context: &StepContext,
    ) {
        if Self::is_enabled(&step_context.turn.config.features) && self.state.is_some() {
            self.record_call(call, source, step_context.tool_router.tool_mode());
        }
    }

    pub(crate) fn record_accepted_result(
        &self,
        source: &ToolCallSource,
        call_id: &str,
        result: &dyn ToolOutput,
    ) {
        if self.state.is_some()
            && let Some(sources) = result.tool_result_sources()
        {
            self.record_tool_result_sources(source, call_id, sources);
        }
    }

    fn record_call(&self, call: &ToolCall, source: &ToolCallSource, tool_mode: ToolMode) {
        let Some(state) = &self.state else {
            return;
        };
        if matches!(source, ToolCallSource::Direct)
            && matches!(tool_mode, ToolMode::CodeMode | ToolMode::CodeModeOnly)
            && call.tool_name.is_default_namespace()
            && matches!(
                (call.tool_name.name.as_str(), &call.payload),
                (
                    crate::tools::code_mode::PUBLIC_TOOL_NAME,
                    ToolPayload::Custom { .. }
                ) | (
                    crate::tools::code_mode::WAIT_TOOL_NAME,
                    ToolPayload::Function { .. }
                )
            )
        {
            return;
        }

        let original_bytes = match &call.payload {
            ToolPayload::Function { arguments } => arguments.len(),
            ToolPayload::Custom { input } => serialized_json_bytes(input).unwrap_or(usize::MAX),
            ToolPayload::ToolSearch { arguments } => {
                serialized_json_bytes(arguments).unwrap_or(usize::MAX)
            }
        };
        let name = codex_tools::code_mode_name_for_tool_name(&call.tool_name);
        let recorded_call = if original_bytes > MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES {
            ExecutedToolCall::truncated(name, original_bytes, MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES)
        } else {
            let arguments = match &call.payload {
                ToolPayload::Function { arguments } => serde_json::from_str(arguments)
                    .unwrap_or_else(|_| JsonValue::String(arguments.clone())),
                ToolPayload::Custom { input } => JsonValue::String(input.clone()),
                ToolPayload::ToolSearch { arguments } => {
                    serde_json::to_value(arguments).unwrap_or_default()
                }
            };
            ExecutedToolCall::new(name, arguments)
        };
        match source {
            ToolCallSource::Direct | ToolCallSource::DirectPlaintextMessage => {
                let mut state = state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if state.direct_calls.len() < MAX_PENDING_EXECUTED_TOOL_CALLS {
                    state
                        .direct_calls
                        .entry(call.call_id.clone())
                        .or_insert(recorded_call);
                } else if state.direct_calls.len() == MAX_PENDING_EXECUTED_TOOL_CALLS
                    && !state.direct_calls.contains_key(&call.call_id)
                {
                    state.direct_calls.insert(
                        call.call_id.clone(),
                        ExecutedToolCall::truncated(
                            recorded_call.name,
                            original_bytes,
                            /*max_bytes*/ 0,
                        ),
                    );
                }
            }
            ToolCallSource::CodeMode { cell_id, .. } => {
                self.record_nested_tool_call(
                    CellId::new(cell_id.clone()),
                    call.call_id.clone(),
                    recorded_call,
                    original_bytes,
                );
            }
        }
    }

    fn record_nested_tool_call(
        &self,
        cell_id: CellId,
        call_id: String,
        call: ExecutedToolCall,
        original_bytes: usize,
    ) {
        let Some(state) = &self.state else {
            return;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.pending_nested_calls > MAX_PENDING_EXECUTED_TOOL_CALLS
            || (state.cells.len() >= MAX_PENDING_EXECUTED_TOOL_CALLS
                && !state.cells.contains_key(&cell_id))
        {
            if let Some(cell) = state.cells.get_mut(&cell_id) {
                cell.completion = CellCompletion::Incomplete;
            }
            return;
        }
        let at_pending_call_limit = state.pending_nested_calls == MAX_PENDING_EXECUTED_TOOL_CALLS;
        let cell = state.cells.entry(cell_id).or_default();
        let max_bytes = MAX_EXECUTED_TOOL_CALL_ARGUMENT_BYTES.min(
            MAX_EXECUTED_TOOL_CALL_FULL_ARGUMENT_BYTES_PER_OUTPUT
                .saturating_sub(cell.pending_full_argument_bytes),
        );
        let call = if at_pending_call_limit {
            ExecutedToolCall::truncated(call.name, original_bytes, /*max_bytes*/ 0)
        } else if original_bytes <= max_bytes {
            cell.pending_full_argument_bytes = cell
                .pending_full_argument_bytes
                .saturating_add(original_bytes);
            call
        } else {
            ExecutedToolCall::truncated(call.name, original_bytes, max_bytes)
        };
        cell.completion = if matches!(
            cell.completion,
            CellCompletion::Started | CellCompletion::Recording
        ) && !matches!(
            call.arguments(),
            ExecutedToolCallArguments::Truncated { .. }
        ) {
            CellCompletion::Recording
        } else {
            CellCompletion::Incomplete
        };
        cell.pending_calls.insert(call_id, call);
        state.pending_nested_calls += 1;
    }

    fn record_tool_result_sources(
        &self,
        source: &ToolCallSource,
        call_id: &str,
        result_sources: codex_protocol::models::ToolResultSources,
    ) -> bool {
        let Some(state) = &self.state else {
            return false;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let call = match source {
            ToolCallSource::Direct | ToolCallSource::DirectPlaintextMessage => {
                state.direct_calls.get_mut(call_id)
            }
            ToolCallSource::CodeMode { cell_id, .. } => state
                .cells
                .get_mut(&CellId::new(cell_id.clone()))
                .and_then(|cell| cell.pending_calls.get_mut(call_id)),
        };
        if let Some(call) = call {
            return call.set_tool_result_sources(result_sources);
        }
        let ToolCallSource::CodeMode { cell_id, .. } = source else {
            return false;
        };
        let Some((retained, index)) = state.retained_calls.values_mut().find_map(|retained| {
            if retained.runtime_cell_id.as_ref()?.as_str() != cell_id.as_str() {
                return None;
            }
            let index = *retained.call_index_by_id.get(call_id)?;
            Some((retained, index))
        }) else {
            return false;
        };
        // Older retry copies must not overwrite this output's accepted result metadata.
        retained.sources_updated = true;
        retained.calls[index].set_tool_result_sources(result_sources)
    }

    pub(crate) fn register_cell(&self, cell_id: &CellId, output_call_id: &str) {
        let Some(state) = &self.state else {
            return;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.register_cell(cell_id, output_call_id);
    }

    pub(crate) fn start_cell(&self, cell_id: &CellId, output_call_id: &str) {
        let Some(state) = &self.state else {
            return;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.register_cell(cell_id, output_call_id);
        if let Some(cell) = state.cells.get_mut(cell_id) {
            cell.completion = CellCompletion::Started;
        }
    }

    pub(crate) fn finish_cell_recording(&self, cell_id: &CellId) {
        let Some(state) = &self.state else {
            return;
        };
        let mut state = state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(cell) = state.cells.get_mut(cell_id) {
            if cell.completion == CellCompletion::Recording {
                cell.completion = CellCompletion::Complete;
            } else if cell.completion != CellCompletion::Complete && cell.pending_calls.is_empty() {
                state.cells.remove(cell_id);
            }
        }
    }
}
