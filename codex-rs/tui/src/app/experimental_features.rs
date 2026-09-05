//! Menu-only feature persistence. Configured readback never replaces task state,
//! and an accepted save finishes even if its popup closes or the user navigates.

use super::*;
use crate::experimental_features::FeatureWriteResult;
use tokio::sync::oneshot;

impl App {
    pub(super) fn fetch_experimental_features(
        &self,
        app_server: &AppServerSession,
        thread_id: ThreadId,
        mut response_tx: oneshot::Sender<
            Result<Vec<codex_app_server_protocol::ExperimentalFeature>, String>,
        >,
    ) {
        let lock = self.feature_write_lock.clone();
        let handle = app_server.request_handle();
        tokio::spawn(async move {
            // A reopened popup must discover values after the outstanding save.
            tokio::select! {
                _ = response_tx.closed() => {},
                _guard = lock.lock() => crate::experimental_features::fetch(
                    handle, thread_id, "tui-experimental-features", response_tx,
                ),
            }
        });
    }

    pub(super) fn save_experimental_features(
        &mut self,
        app_server: &AppServerSession,
        thread_id: ThreadId,
        updates: Vec<(String, bool)>,
        response_tx: oneshot::Sender<Result<FeatureWriteResult, String>>,
    ) {
        let Ok(guard) = self.feature_write_lock.clone().try_lock_owned() else {
            let error =
                "An experimental feature save is still in progress. Retry after it finishes.";
            self.chat_widget.add_warning_message(error.to_string());
            let _ = response_tx.send(Err(error.to_string()));
            return;
        };
        let request_handle = app_server.request_handle();
        let tx = self.app_event_tx.clone();
        tokio::spawn(async move {
            let result =
                crate::experimental_features::write(request_handle, thread_id, updates).await;
            drop(guard);
            // Report unresolved outcomes even if the popup closes before its next draw.
            let warning = match &result {
                Ok(result) => result.warning.as_ref(),
                Err(error) => Some(error),
            };
            if let Some(warning) = warning {
                tx.send(AppEvent::InsertHistoryCell(Box::new(
                    history_cell::new_warning_event(warning.clone()),
                )));
            }
            let _ = response_tx.send(result);
        });
    }
}

#[cfg(test)]
#[path = "experimental_features_tests.rs"]
mod tests;
