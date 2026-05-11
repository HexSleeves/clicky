//
//  RecoverySuggestionHandler.swift
//  leanring-buddy
//
//  Maps a recovery suggestion's Kind to the actual side effect. Kept
//  separate from MiloError + the presenter so the data model stays pure
//  and testable, and so the side effects (opening URLs, posting
//  notifications) live in one auditable place.
//

import AppKit
import Foundation

@MainActor
enum RecoverySuggestionHandler {

    /// Performs the side effect for a recovery action. Called from the
    /// toast's CTA button. The presenter is passed in so success paths
    /// can dismiss the toast (e.g. after opening System Settings).
    static func perform(
        _ suggestion: RecoverySuggestion,
        presenter: MiloErrorPresenter
    ) {
        switch suggestion.kind {
        case .openSystemSettings:
            openSystemPrivacySettings()
            presenter.dismiss()
        case .openUpdatePage:
            // Until Sparkle is re-enabled per docs/production-readiness.md,
            // route users to the public download page.
            if let url = URL(string: "https://www.heyclicky.com/") {
                NSWorkspace.shared.open(url)
            }
            presenter.dismiss()
        case .retry:
            // Caller wires its own retry pathway via a notification or
            // direct call. The handler just dismisses.
            presenter.dismiss()
        case .dismiss:
            presenter.dismiss()
        }
    }

    private static func openSystemPrivacySettings() {
        // Privacy & Security pane root. Specific pane (Microphone /
        // Screen Recording / Accessibility) varies per macOS version;
        // landing on the root is the most reliable cross-version target.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
