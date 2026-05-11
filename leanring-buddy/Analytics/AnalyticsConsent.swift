//
//  AnalyticsConsent.swift
//  leanring-buddy
//
//  Persistent consent state for product analytics. Three states:
//
//    .undecided  — first-launch users, before the prompt fires
//    .granted    — user opted in via the prompt or Settings toggle
//    .denied     — user opted out via the prompt or Settings toggle
//
//  Only a small allowlist of events fire pre-decision (`app_opened`,
//  `onboarding_video_completed`) — both carry only version/empty
//  payloads. Everything else stays buffered until consent is granted,
//  and then doesn't fire historical events (silence is the privacy-safe
//  default for an audit trail you can't show the user).
//
//  Consent prompt timing: between the onboarding video end and the demo
//  interaction. Hooked from OnboardingController.onVideoEnded in
//  CompanionManager.
//

import Combine
import Foundation

@MainActor
final class AnalyticsConsent: ObservableObject {

    enum State: String, Equatable {
        case undecided
        case granted
        case denied
    }

    @Published private(set) var state: State

    private let defaults: UserDefaults
    private static let storageKey = PersistenceKeys.analyticsConsentState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawStored = defaults.string(forKey: Self.storageKey) ?? State.undecided.rawValue
        self.state = State(rawValue: rawStored) ?? .undecided
    }

    /// True when full analytics may fire. Pre-decision callers should
    /// consult `Self.preDecisionAllowlist` instead.
    var isGranted: Bool { state == .granted }

    /// True for the small set of events that may fire before the user
    /// has answered the prompt. Limited to launch / onboarding funnel
    /// signals carrying no user-identifying data.
    static let preDecisionAllowlist: Set<String> = [
        "app_opened",
        "onboarding_video_completed"
    ]

    /// Records the user's decision and persists it.
    func grant() {
        state = .granted
        defaults.set(State.granted.rawValue, forKey: Self.storageKey)
    }

    func deny() {
        state = .denied
        defaults.set(State.denied.rawValue, forKey: Self.storageKey)
    }

    /// Resets to undecided. Used by the Settings toggle when the user
    /// re-opens the question (e.g. via a "Reset analytics consent" row).
    func resetToUndecided() {
        state = .undecided
        defaults.removeObject(forKey: Self.storageKey)
    }
}
