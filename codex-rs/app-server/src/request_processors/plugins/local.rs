use super::*;

impl PluginRequestProcessor {
    pub(super) async fn load_catalog_config(
        &self,
        cwds: &[AbsolutePathBuf],
    ) -> Result<Config, JSONRPCErrorError> {
        if cwds.is_empty() {
            self.config_manager
                .load_non_project_config()
                .await
                .map_err(|err| internal_error(format!("failed to reload config: {err}")))
        } else {
            self.load_latest_config(/*fallback_cwd*/ None).await
        }
    }
}
