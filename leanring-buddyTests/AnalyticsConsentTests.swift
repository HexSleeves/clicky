//
//  AnalyticsConsentTests.swift
//  leanring-buddyTests
//
//  Persistence + state transitions for the consent store. The allowlist
//  is verified separately so its membership is deliberate, not
//  accidental — adding events to it is a privacy decision that should
//  show up in a failing test until you update this file.
//

import Testing
import Foundation
@testable import Milo

@MainActor
struct AnalyticsConsentTests {

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "AnalyticsConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Initial state

    @Test func freshInstallStartsUndecided() {
        let defaults = makeScratchDefaults()
        let consent = AnalyticsConsent(defaults: defaults)
        #expect(consent.state == .undecided)
        #expect(consent.isGranted == false)
    }

    @Test func relaunchPreservesGrantedDecision() {
        let defaults = makeScratchDefaults()
        let consent1 = AnalyticsConsent(defaults: defaults)
        consent1.grant()

        let consent2 = AnalyticsConsent(defaults: defaults)
        #expect(consent2.state == .granted)
        #expect(consent2.isGranted == true)
    }

    @Test func relaunchPreservesDeniedDecision() {
        let defaults = makeScratchDefaults()
        let consent1 = AnalyticsConsent(defaults: defaults)
        consent1.deny()

        let consent2 = AnalyticsConsent(defaults: defaults)
        #expect(consent2.state == .denied)
        #expect(consent2.isGranted == false)
    }

    // MARK: - Reset

    @Test func resetReturnsToUndecided() {
        let defaults = makeScratchDefaults()
        let consent = AnalyticsConsent(defaults: defaults)
        consent.grant()
        consent.resetToUndecided()
        #expect(consent.state == .undecided)
    }

    // MARK: - Pre-decision allowlist

    @Test func allowlistContainsAppOpenedAndVideoCompleted() {
        #expect(AnalyticsConsent.preDecisionAllowlist.contains("app_opened"))
        #expect(AnalyticsConsent.preDecisionAllowlist.contains("onboarding_video_completed"))
    }

    @Test func allowlistDoesNotContainUserActivityEvents() {
        // Sanity: nothing carrying user content can be allowlisted. If
        // someone adds these to the allowlist without thinking, the
        // failure here makes the privacy regression visible.
        let mustNotBeAllowlisted = [
            "user_message_sent",
            "ai_response_received",
            "element_pointed",
            "guided_action_proposed",
            "note_saved",
            "conversation_cleared",
            "milo_error"
        ]
        for event in mustNotBeAllowlisted {
            #expect(!AnalyticsConsent.preDecisionAllowlist.contains(event),
                    "\(event) MUST NOT be in the pre-decision allowlist")
        }
    }

    @Test func allowlistIsSmall() {
        // Soft cap on growth — if the allowlist gets above ~5 entries,
        // someone should be reconsidering the model rather than adding
        // more pre-consent events.
        #expect(AnalyticsConsent.preDecisionAllowlist.count <= 5)
    }
}
