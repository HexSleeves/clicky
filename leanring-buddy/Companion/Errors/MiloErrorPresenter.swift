//
//  MiloErrorPresenter.swift
//  leanring-buddy
//
//  Single point of fan-in for user-facing errors. Service code throws or
//  returns a `MiloError`; the orchestrator calls `present(_:)` and the
//  panel observes `current` to render the toast. Errors auto-dismiss
//  after a default hold so the user isn't left staring at a stale
//  message; `dismiss()` cancels the timer and clears immediately.
//
//  Auto-dismiss exists because there's no global "X" affordance — the
//  panel hosts the toast and closes on outside click, so a stale toast
//  could otherwise hang around invisibly until the next panel open.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class MiloErrorPresenter: ObservableObject {

    /// Currently presented error, or nil when none. Views observe this.
    @Published private(set) var current: MiloError?

    /// Tracks which error is on screen so the auto-dismiss task can
    /// confirm "I'm still the active one" before clearing — prevents a
    /// stale timer from clearing a newer error.
    private var presentedToken: UUID?
    private var autoDismissTask: Task<Void, Never>?

    private static let defaultHoldSeconds: TimeInterval = 6.0
    private static let shortHoldSeconds: TimeInterval = 3.0

    /// Presents an error in the toast. If another error is already
    /// presented, it's replaced and its auto-dismiss timer cancelled.
    /// `hold` controls how long before auto-dismiss; pass `nil` to use
    /// a per-error default (longer holds for actionable errors, shorter
    /// for transient ones like a single TTS failure).
    func present(_ error: MiloError, hold: TimeInterval? = nil) {
        autoDismissTask?.cancel()

        let token = UUID()
        presentedToken = token
        current = error

        let holdSeconds = hold ?? Self.holdSeconds(for: error)
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only clear if this token is still the active presentation —
            // a newer error may have replaced us while we slept.
            if self.presentedToken == token {
                self.current = nil
                self.presentedToken = nil
            }
        }
    }

    /// Clears any presented error immediately and cancels its auto-dismiss.
    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        presentedToken = nil
        current = nil
    }

    private static func holdSeconds(for error: MiloError) -> TimeInterval {
        switch error {
        case .ttsFailed:
            // TTS failure is benign — system voice already kicked in,
            // user doesn't need to dwell on it.
            return shortHoldSeconds
        case .appUpgradeRequired:
            // Blocking — user MUST take action. Hold until they dismiss.
            // (Represented here as a very long timeout; the orchestrator
            // should additionally gate further interactions.)
            return 600
        default:
            return defaultHoldSeconds
        }
    }
}
