//
//  MiloErrorTests.swift
//  leanring-buddyTests
//
//  Pins down the data-model side of the error system: every case has a
//  non-empty user message + stable analytics code, recovery suggestions
//  map to the right kinds, and Equatable is shaped the way callers
//  expect. Presenter behavior lives in MiloErrorPresenterTests so this
//  file stays pure-value testing.
//

import Testing
@testable import leanring_buddy

struct MiloErrorTests {

    // MARK: - userMessage non-emptiness

    @Test func everyCaseHasNonEmptyUserMessage() {
        let allCases: [MiloError] = [
            .missingPermission(.microphone),
            .missingPermission(.screenRecording),
            .missingPermission(.accessibility),
            .budgetExhausted(retryAfterSeconds: 3600),
            .rateLimited(retryAfterSeconds: 60),
            .providerDown(.chat),
            .providerDown(.tts),
            .providerDown(.transcribe),
            .providerDenied(.chat),
            .appUpgradeRequired(minimumVersion: "1.2.0"),
            .transcriptionFailed,
            .ttsFailed,
            .screenshotFailed,
            .payloadTooLarge,
            .network,
            .unknown
        ]
        for error in allCases {
            #expect(!error.userMessage.isEmpty,
                    "userMessage was empty for \(error.analyticsCode)")
        }
    }

    // MARK: - analytics codes are stable + unique

    @Test func analyticsCodesAreUniqueAcrossCaseFamilies() {
        // ttsFailed is intentionally distinct from providerDown(.tts):
        // the former is a one-off playback failure, the latter signals
        // an outage. Mixing them in funnels would conflate two stories.
        #expect(MiloError.ttsFailed.analyticsCode != MiloError.providerDown(.tts).analyticsCode)
    }

    @Test func providerKindIsEncodedInAnalyticsCode() {
        #expect(MiloError.providerDown(.chat).analyticsCode == "provider_down_chat")
        #expect(MiloError.providerDown(.tts).analyticsCode == "provider_down_tts")
        #expect(MiloError.providerDown(.transcribe).analyticsCode == "provider_down_transcribe")
    }

    @Test func permissionIsEncodedInAnalyticsCode() {
        #expect(MiloError.missingPermission(.microphone).analyticsCode == "permission_microphone")
        #expect(MiloError.missingPermission(.screenRecording).analyticsCode == "permission_screenRecording")
        #expect(MiloError.missingPermission(.accessibility).analyticsCode == "permission_accessibility")
    }

    // MARK: - recoverySuggestion mapping

    @Test func permissionErrorOffersSystemSettingsRecovery() {
        let suggestion = MiloError.missingPermission(.microphone).recoverySuggestion
        #expect(suggestion?.kind == .openSystemSettings)
    }

    @Test func upgradeRequiredOffersUpdatePageRecovery() {
        let suggestion = MiloError.appUpgradeRequired(minimumVersion: "1.2").recoverySuggestion
        #expect(suggestion?.kind == .openUpdatePage)
    }

    @Test func timeBasedErrorsOfferNoRecovery() {
        // Budget + rate limit have no user action; rendering a button
        // would imply otherwise.
        #expect(MiloError.budgetExhausted(retryAfterSeconds: 3600).recoverySuggestion == nil)
        #expect(MiloError.rateLimited(retryAfterSeconds: 60).recoverySuggestion == nil)
    }

    // MARK: - Equatable shape

    @Test func budgetExhaustedRetryAfterDistinguishesCases() {
        // Two budget errors with different retry windows should be
        // distinct so a fresh one supersedes a stale one in the presenter.
        let a = MiloError.budgetExhausted(retryAfterSeconds: 1000)
        let b = MiloError.budgetExhausted(retryAfterSeconds: 2000)
        #expect(a != b)
    }

    @Test func providerDownAcrossKindsAreNotEqual() {
        #expect(MiloError.providerDown(.chat) != MiloError.providerDown(.tts))
    }

    // MARK: - spokenFallback safety

    @Test func ttsFailedSpokenFallbackIsEmpty() {
        // TTS just failed — speaking the error aloud via the same failed
        // path would either loop forever or itself fail. Empty is correct.
        #expect(MiloError.ttsFailed.spokenFallback == "")
    }

    @Test func nonTTSErrorsHaveNonEmptySpokenFallback() {
        let speakable: [MiloError] = [
            .missingPermission(.microphone),
            .budgetExhausted(retryAfterSeconds: 0),
            .rateLimited(retryAfterSeconds: 0),
            .providerDown(.chat),
            .network,
            .unknown
        ]
        for error in speakable {
            #expect(!error.spokenFallback.isEmpty,
                    "spokenFallback was empty for \(error.analyticsCode)")
        }
    }
}
