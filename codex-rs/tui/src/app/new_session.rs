//! New-session configuration from server defaults and explicit launch settings.
//!
//! Build the replacement configuration without replacing the active task's settings.

use super::*;
use codex_config::ConfigLayerSource;

impl App {
    pub(super) async fn load_new_session_config(
        &mut self,
        app_server: &AppServerSession,
    ) -> Result<Config> {
        let cwd = self.chat_widget.config_ref().cwd.to_path_buf();
        let defaults_cwd = match app_server.thread_params_mode() {
            crate::app_server_session::ThreadParamsMode::Embedded => cwd.as_path(),
            crate::app_server_session::ThreadParamsMode::Remote => {
                app_server.remote_cwd_override().unwrap_or(Path::new("."))
            }
        };
        // config/read resolves relative paths on the server. With no remote launch override,
        // "." uses the same server process directory as thread/start's omitted cwd.
        let defaults = match crate::config_update::read_effective_config(
            app_server.request_handle(),
            defaults_cwd.display().to_string(),
        )
        .await
        {
            Ok(response) => Some(response.config),
            Err(err)
                if matches!(
                    err.downcast_ref::<TypedRequestError>(),
                    Some(TypedRequestError::Server { source, .. })
                        if source.code == -32601
                            || source.code == -32600
                                && source.message.contains("config/read")
                                && (source.message.contains("unknown variant")
                                    || source.message.contains("unknown method"))
                ) =>
            {
                // Older servers can still start threads using the existing local defaults.
                None
            }
            Err(err) => return Err(err),
        };
        // Stage local preferences and permission carryover without changing the active task.
        let mut config = match self.rebuild_config_for_cwd(cwd).await {
            Ok(config) => config,
            Err(err) => {
                tracing::warn!(%err, "failed to refresh local settings before a new thread");
                self.config.clone()
            }
        };
        self.apply_runtime_policy_overrides(&mut config, RuntimePolicyOverrideScope::All);
        config.service_tier = self.chat_widget.configured_service_tier();
        if let Some(defaults) = defaults {
            // A remote server cannot resolve this invocation's explicitly selected local profile.
            let has_launch_setting = |key: &str| {
                self.cli_kv_overrides.iter().any(|(path, _)| path == key)
                    || config.config_layer_stack.layers_high_to_low().any(|layer| {
                        layer.disabled_reason.is_none()
                            && matches!(
                                layer.name,
                                ConfigLayerSource::User {
                                    profile: Some(_),
                                    ..
                                }
                            )
                            && layer.config.get(key).is_some()
                    })
            };
            if self.harness_overrides.model.is_none() && !has_launch_setting("model") {
                config.model = defaults.model;
            }
            if !has_launch_setting("model_reasoning_effort") {
                config.model_reasoning_effort = defaults.model_reasoning_effort;
            }
        }
        Ok(config)
    }
}
