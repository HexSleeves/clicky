//
//  MiloAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog wrapper. Every event flows through `capture(...)`,
//  which consults `AnalyticsConsent` before firing. Only the pre-decision
//  allowlist (`app_opened`, `onboarding_video_completed`) fires before
//  the user answers the consent prompt — those carry only version /
//  empty payloads.
//
//  PII rules:
//  - Free-text user content (transcripts, responses, element labels,
//    error.localizedDescription) MUST NOT appear in any property.
//  - Use UILabelCategorizer to bucket labels into UICategory before sending.
//  - Errors are tracked by MiloError.analyticsCode (stable, enumerated).
//

import Foundation
import PostHog

@MainActor
enum MiloAnalytics {

    /// Set once in app launch so `capture(...)` can gate sends on the
    /// user's consent decision. Tests can inject a fresh instance.
    static var consent: AnalyticsConsent = AnalyticsConsent()

    // MARK: - Setup

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    /// Central gate. Every event in this file routes through here. The
    /// gate is the single auditable point where consent is consulted.
    private static func capture(_ eventName: String, properties: [String: Any]? = nil) {
        switch consent.state {
        case .granted:
            PostHogSDK.shared.capture(eventName, properties: properties)
        case .undecided where AnalyticsConsent.preDecisionAllowlist.contains(eventName):
            PostHogSDK.shared.capture(eventName, properties: properties)
        case .undecided, .denied:
            return
        }
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    /// Pre-decision allowlisted — only carries app version.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        capture("app_opened", properties: ["app_version": version])
    }

    // MARK: - Onboarding

    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    /// Pre-decision allowlisted — fires at the moment the consent
    /// prompt is about to appear, so the funnel "video → consent answer"
    /// is measurable without leaking user content.
    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    /// User answered the analytics consent prompt. Fires only after
    /// `consent.grant()`, so this is always allowed by the gate.
    static func trackAnalyticsConsentDecided(granted: Bool) {
        capture("analytics_consent_decided", properties: ["granted": granted])
    }

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: ["permission": permission])
    }

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: ["character_count": transcript.count])
    }

    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: ["character_count": response.count])
    }

    /// Claude's response included a [POINT:...] tag. Raw label is
    /// bucketed via UILabelCategorizer before leaving the device.
    static func trackElementPointed(elementLabel: String?) {
        let category = UILabelCategorizer.bucket(elementLabel)
        capture("element_pointed", properties: ["element_category": category.rawValue])
    }

    static func trackGuidedActionProposed() {
        capture("guided_action_proposed", properties: ["action_type": "click_target"])
    }

    static func trackGuidedActionDone() {
        capture("guided_action_done", properties: ["action_type": "click_target"])
    }

    static func trackGuidedActionClicked() {
        capture("guided_action_clicked", properties: ["action_type": "click_target"])
    }

    static func trackGuidedActionCancelled() {
        capture("guided_action_cancelled", properties: ["action_type": "click_target"])
    }

    static func trackNoteSaved() {
        capture("note_saved")
    }

    static func trackNoteDeleted() {
        capture("note_deleted")
    }

    static func trackConversationCleared() {
        capture("conversation_cleared")
    }

    // MARK: - Errors

    /// Tracks a typed MiloError. `analyticsCode` is stable per case and
    /// never contains free-text user content.
    static func trackError(_ error: MiloError, surface: String) {
        capture("milo_error", properties: [
            "error_code": error.analyticsCode,
            "surface": surface
        ])
    }
}
