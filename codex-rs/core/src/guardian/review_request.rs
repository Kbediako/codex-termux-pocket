//! Captures and reports one review on the host's original action and authorization state.
//! Guardian's extension owns orchestration; this adapter preserves event and evidence behavior.

use super::*;
use crate::codex_thread::GuardianAuthorizationVersion;
use codex_guardian_reviewer::ReviewHost;
use codex_protocol::approvals::GuardianAssessmentAction;
use codex_protocol::approvals::GuardianReviewReason;

pub(in crate::guardian) struct PreparedApproval {
    request: GuardianApprovalRequest,
    turn: Arc<TurnContext>,
    review_reason: GuardianReviewReason,
    assessment_turn_id: String,
    target_item_id: Option<String>,
    plugin_id: Option<String>,
    script_path: Option<String>,
    action_summary: GuardianAssessmentAction,
    reviewed_action: GuardianReviewedAction,
    review_tracking: GuardianReviewTrackContext,
    started_at_ms: i64,
    root_authorization_version: Option<GuardianAuthorizationVersion>,
    user_message_revision: u64,
    review_evidence: Option<(
        Arc<GuardianReviewEvidence>,
        String,
        GuardianAuthorizationVersion,
        Option<GuardianAuthorizationVersion>,
    )>,
}

impl ReviewHost for super::super::runtime::ReviewRuntime {
    type Prepared = PreparedApproval;

    fn cancellation(&self) -> Option<&CancellationToken> {
        self.options.external_cancel.as_ref()
    }

    async fn prepare(
        &self,
        review_reason: GuardianReviewReason,
        deadline: Instant,
    ) -> Result<PreparedApproval, ReviewDecision> {
        let super::super::runtime::ReviewRuntime {
            session,
            context,
            review_id,
            request,
            reasons: _,
            options,
        } = self.clone();
        let request = match request.validate(&context) {
            Ok(request) => request.clone(),
            Err(decision) => return Err(decision),
        };
        let turn = Arc::clone(context.turn());
        let GuardianReviewOptions {
            plugin_attribution_override,
            approval_request_source,
            external_cancel,
            require_synchronous_review: _,
            require_guardian: _,
        } = options;
        let target_item_id = guardian_request_target_item_id(&request).map(str::to_string);
        let assessment_turn_id = guardian_request_turn_id(&request, &turn.sub_id).to_string();
        let plugin_attribution = match plugin_attribution_override {
            Some(attribution) => Some(attribution),
            None if matches!(&request, GuardianApprovalRequest::ExecCommand { .. }) => {
                let cancellation = external_cancel
                    .clone()
                    .unwrap_or_else(CancellationToken::new);
                let attribution_deadline = std::cmp::min(
                    deadline,
                    Instant::now() + GUARDIAN_PLUGIN_ATTRIBUTION_TIMEOUT,
                );
                let attribution = tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => return Err(ReviewDecision::Abort),
                    attribution = tokio::time::timeout_at(
                        attribution_deadline,
                        plugin_attribution_for_guardian_request(&context, &request),
                    ) => attribution,
                };
                match attribution {
                    Ok(attribution) => attribution,
                    Err(_) => {
                        tracing::warn!(
                            timeout_ms = GUARDIAN_PLUGIN_ATTRIBUTION_TIMEOUT.as_millis(),
                            "Guardian plugin attribution timed out"
                        );
                        None
                    }
                }
            }
            None => plugin_attribution_for_guardian_request(&context, &request).await,
        };
        let (plugin_id, script_path) = plugin_attribution
            .as_ref()
            .map(PluginCommandAttribution::serialized_fields)
            .unzip();
        let action_summary = guardian_assessment_action(&request);
        let reviewed_action = guardian_reviewed_action(&request);
        let review_tracking = GuardianReviewTrackContext::new(
            session.thread_id.to_string(),
            assessment_turn_id.clone(),
            review_id.clone(),
            target_item_id.clone(),
            approval_request_source,
            reviewed_action.clone(),
            GUARDIAN_REVIEW_TIMEOUT.as_millis() as u64,
        );
        let started_at_ms = review_tracking.started_at_ms.try_into().unwrap_or_default();
        session
            .send_event(
                turn.as_ref(),
                EventMsg::GuardianAssessment(GuardianAssessmentEvent {
                    review_reason: Some(review_reason),
                    id: review_id.clone(),
                    target_item_id: target_item_id.clone(),
                    plugin_id: plugin_id.clone(),
                    script_path: script_path.clone(),
                    turn_id: assessment_turn_id.clone(),
                    started_at_ms,
                    completed_at_ms: None,
                    status: GuardianAssessmentStatus::InProgress,
                    risk_level: None,
                    user_authorization: None,
                    rationale: None,
                    decision_source: None,
                    action: action_summary.clone(),
                }),
            )
            .await;

        if external_cancel
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
        {
            let completed_at_ms = now_unix_timestamp_ms();
            track_guardian_review(
                session.as_ref(),
                &review_tracking,
                approval_request_source,
                &reviewed_action,
                GuardianReviewAnalyticsResult {
                    decision: GuardianReviewDecision::Aborted,
                    terminal_status: GuardianReviewTerminalStatus::Aborted,
                    failure_reason: Some(GuardianReviewFailureReason::Cancelled),
                    ..GuardianReviewAnalyticsResult::without_session()
                },
                completed_at_ms.try_into().unwrap_or_default(),
            );
            session
                .send_event(
                    turn.as_ref(),
                    EventMsg::GuardianAssessment(GuardianAssessmentEvent {
                        review_reason: Some(review_reason),
                        id: review_id,
                        target_item_id,
                        plugin_id: plugin_id.clone(),
                        script_path: script_path.clone(),
                        turn_id: assessment_turn_id.clone(),
                        started_at_ms,
                        completed_at_ms: Some(completed_at_ms),
                        status: GuardianAssessmentStatus::Aborted,
                        risk_level: None,
                        user_authorization: None,
                        rationale: None,
                        decision_source: Some(GuardianAssessmentDecisionSource::Agent),
                        action: action_summary,
                    }),
                )
                .await;
            record_guardian_non_denial(&session, &assessment_turn_id).await;
            return Err(ReviewDecision::Abort);
        }

        let root_authorization_version = session
            .services
            .agent_control
            .root_user_authorization(session.thread_id)
            .await
            .map(|snapshot| snapshot.authorization_version);
        // Keep the authorization revision even when no cacheable review evidence exists.
        let history = session.conversation_history_snapshot().await;
        let user_message_revision = history.user_message_revision();
        let review_evidence = if let Some(evidence) = session
            .services
            .thread_extension_data
            .get::<GuardianReviewEvidence>()
        {
            let authorization_version = evidence.authorization_version(history.as_ref());
            format_guardian_action_pretty(&request).ok().map(|action| {
                (
                    evidence,
                    action.text,
                    authorization_version,
                    root_authorization_version,
                )
            })
        } else {
            None
        };
        drop(history);
        Ok(PreparedApproval {
            request,
            turn,
            review_reason,
            assessment_turn_id,
            target_item_id,
            plugin_id,
            script_path,
            action_summary,
            reviewed_action,
            review_tracking,
            started_at_ms,
            root_authorization_version,
            user_message_revision,
            review_evidence,
        })
    }

    async fn attempt(
        &self,
        prepared: &PreparedApproval,
        deadline: Instant,
    ) -> (GuardianReviewOutcome, GuardianReviewAnalyticsResult) {
        run_guardian_review_session_before_deadline(
            Arc::clone(&self.session),
            self.context.clone(),
            prepared.request.clone(),
            self.reasons.clone(),
            guardian_output_schema(),
            self.options.external_cancel.clone(),
            deadline,
        )
        .await
    }

    async fn complete(
        &self,
        prepared: PreparedApproval,
        mut outcome: GuardianReviewOutcome,
        analytics_result: GuardianReviewAnalyticsResult,
    ) -> ReviewDecision {
        let PreparedApproval {
            request: _,
            turn,
            review_reason,
            assessment_turn_id,
            target_item_id,
            plugin_id,
            script_path,
            action_summary,
            reviewed_action,
            review_tracking,
            started_at_ms,
            root_authorization_version,
            user_message_revision,
            review_evidence,
        } = prepared;
        let session = Arc::clone(&self.session);
        let review_id = self.review_id.clone();
        let approval_request_source = self.options.approval_request_source;
        let terminal_action = action_summary.clone();
        if session.guardian_context_mode == GuardianContextMode::ThreadOwned
            && matches!(&outcome, GuardianReviewOutcome::Completed(assessment) if assessment.outcome == GuardianAssessmentOutcome::Allow)
            && (root_authorization_version
                != session
                    .services
                    .agent_control
                    .root_user_authorization(session.thread_id)
                    .await
                    .map(|snapshot| snapshot.authorization_version)
                || user_message_revision
                    != session
                        .conversation_history_snapshot()
                        .await
                        .user_message_revision())
        {
            // A completed approval cannot outlive the owning-session or root evidence
            // it evaluated, including when either changed before prompt construction.
            outcome = GuardianReviewOutcome::Error(GuardianReviewError::Cancelled);
        }

        let completed_at_ms = now_unix_timestamp_ms();
        let completed = codex_guardian_reviewer::complete_review(
            outcome,
            turn.model_info(),
            GuardianAssessmentEvent {
                review_reason: Some(review_reason),
                id: review_id,
                target_item_id,
                plugin_id,
                script_path,
                turn_id: assessment_turn_id.clone(),
                started_at_ms,
                completed_at_ms: Some(completed_at_ms),
                status: GuardianAssessmentStatus::InProgress,
                risk_level: None,
                user_authorization: None,
                rationale: None,
                decision_source: Some(GuardianAssessmentDecisionSource::Agent),
                action: terminal_action,
            },
            analytics_result,
        );
        track_guardian_review(
            session.as_ref(),
            &review_tracking,
            approval_request_source,
            &reviewed_action,
            completed.analytics,
            completed_at_ms.try_into().unwrap_or_default(),
        );
        if let Some(message) = completed.warning {
            session
                .send_event(
                    turn.as_ref(),
                    EventMsg::GuardianWarning(WarningEvent { message }),
                )
                .await;
        }
        if completed.assessment_outcome.is_some()
            && let Some((evidence, action, authorization_version, root_authorization_version)) =
                review_evidence
        {
            evidence.record(
                &completed.event,
                &action,
                authorization_version,
                root_authorization_version,
            );
        }
        session
            .send_event(turn.as_ref(), EventMsg::GuardianAssessment(completed.event))
            .await;
        if completed.assessment_outcome == Some(GuardianAssessmentOutcome::Deny) {
            record_guardian_denial(&session, &turn, &assessment_turn_id).await;
        } else {
            record_guardian_non_denial(&session, &assessment_turn_id).await;
        }
        completed.decision
    }
}
