//
//  MiloErrorPresenterTests.swift
//  leanring-buddyTests
//
//  Behavior tests for the presentation lifecycle: present → auto-dismiss,
//  replacement of stale errors, and explicit dismiss. The auto-dismiss
//  hold defaults are long enough to make real-time tests slow, so each
//  test passes a short `hold` override.
//

import Testing
import Foundation
@testable import leanring_buddy

@MainActor
struct MiloErrorPresenterTests {

    @Test func presentSetsCurrentImmediately() {
        let presenter = MiloErrorPresenter()
        presenter.present(.network, hold: 60)
        #expect(presenter.current == .network)
    }

    @Test func dismissClearsCurrent() {
        let presenter = MiloErrorPresenter()
        presenter.present(.network, hold: 60)
        presenter.dismiss()
        #expect(presenter.current == nil)
    }

    @Test func presentReplacesPreviousError() {
        let presenter = MiloErrorPresenter()
        presenter.present(.network, hold: 60)
        presenter.present(.unknown, hold: 60)
        #expect(presenter.current == .unknown)
    }

    @Test func autoDismissClearsCurrentAfterHold() async throws {
        let presenter = MiloErrorPresenter()
        presenter.present(.transcriptionFailed, hold: 0.05)
        #expect(presenter.current == .transcriptionFailed)

        // Wait past the hold window (50ms + buffer).
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(presenter.current == nil)
    }

    @Test func newPresentationCancelsOldAutoDismiss() async throws {
        // First error has a very short hold; second error has a longer one.
        // After the first hold elapses, the second error should STILL be
        // current — the first error's timer must not have cleared it.
        let presenter = MiloErrorPresenter()
        presenter.present(.transcriptionFailed, hold: 0.05)
        presenter.present(.network, hold: 5.0)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(presenter.current == .network,
                "Stale auto-dismiss from first error cleared the newer second error")
    }
}
