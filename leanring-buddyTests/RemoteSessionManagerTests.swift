//
//  RemoteSessionManagerTests.swift
//  leanring-buddyTests
//
//  Phase 1 Test Plan rows for RemoteSessionManager that don't require
//  real WebRTC:
//  - startSession + endSession, idempotent teardown
//  - handleConsent (accepted, denied, timeout)
//  - deliverSnap on input event, throttled to 1 snap / 500ms
//  - handleClick → CursorCommand encode → wire roundtrip → POINT path
//    (encode side; receive side covered by RemoteWireMessageTests)
//  - handleStopSharing tears down both sides cleanly
//  - Either-side disconnect → graceful recovery
//
//  Rows that require real network adversity (ICE failure, TURN expiry,
//  Mac sleep) live in Lane A integration suites.
//

import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct RemoteSessionManagerTests {

    private let referenceTime = Date(timeIntervalSince1970: 1_736_400_000)

    // MARK: - Lifecycle

    @Test func freshManagerStartsIdle() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        #expect(sessionManager.state == .idle)
        #expect(sessionManager.lastConsentDecision == nil)
    }

    @Test func requestSessionFromIdleMovesToAwaitingConsent() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)

        sessionManager.requestSession(now: referenceTime)

        #expect(sessionManager.state == .awaitingConsent(requestedAt: referenceTime))
    }

    @Test func requestSessionWhileNotIdleIsNoOp() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)

        let muchLater = referenceTime.addingTimeInterval(60)
        sessionManager.requestSession(now: muchLater)

        // Original requestedAt preserved.
        #expect(sessionManager.state == .awaitingConsent(requestedAt: referenceTime))
    }

    // MARK: - Consent

    @Test func consentAcceptedAcquiresAudioAndGoesActive() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)

        sessionManager.handleConsent(.accepted, now: referenceTime.addingTimeInterval(1))

        #expect(sessionManager.state == .active(startedAt: referenceTime.addingTimeInterval(1)))
        #expect(sessionManager.lastConsentDecision == .accepted)
        #expect(coordinator.currentOwner == .remoteHelpDuplex)
    }

    @Test func consentDeclinedReturnsToIdleAndDoesNotTouchAudio() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)

        sessionManager.handleConsent(.declined)

        #expect(sessionManager.state == .idle)
        #expect(sessionManager.lastConsentDecision == .declined)
        #expect(coordinator.currentOwner == .idle)
    }

    @Test func consentTimedOutReturnsToIdle() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)

        sessionManager.handleConsent(.timedOut)

        #expect(sessionManager.state == .idle)
        #expect(sessionManager.lastConsentDecision == .timedOut)
        #expect(coordinator.currentOwner == .idle)
    }

    @Test func handleConsentOutsideAwaitingConsentIsNoOp() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)

        // No requestSession() first.
        sessionManager.handleConsent(.accepted)

        #expect(sessionManager.state == .idle)
        #expect(sessionManager.lastConsentDecision == nil)
    }

    // MARK: - Snap throttle

    @Test func snapThrottleDeniesWhenNotActive() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)

        #expect(sessionManager.shouldDeliverSnap(now: referenceTime) == false)
    }

    @Test func snapThrottleAllowsFirstAndDeniesWithin500Ms() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)
        sessionManager.handleConsent(.accepted, now: referenceTime)

        let firstSnapAllowed = sessionManager.shouldDeliverSnap(now: referenceTime)
        let secondSnapAt400Ms = sessionManager.shouldDeliverSnap(now: referenceTime.addingTimeInterval(0.4))
        let thirdSnapAt600Ms = sessionManager.shouldDeliverSnap(now: referenceTime.addingTimeInterval(0.6))

        #expect(firstSnapAllowed == true)
        #expect(secondSnapAt400Ms == false)
        #expect(thirdSnapAt600Ms == true)
    }

    // MARK: - Outbound wire

    @Test func sendCursorCommandEmitsCorrectWireMessage() throws {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        let inMemoryTransport = InMemoryRemoteSessionTransport()
        sessionManager.attachTransport(inMemoryTransport)

        sessionManager.requestSession(now: referenceTime)
        sessionManager.handleConsent(.accepted, now: referenceTime)

        sessionManager.sendCursorCommand(
            CursorCommand(xFraction: 0.4, yFraction: 0.6, screenIndex: 0, label: "click here")
        )

        #expect(inMemoryTransport.sentMessages.count == 1)
        guard case .cursorCommand(_, let payload) = inMemoryTransport.sentMessages[0] else {
            Issue.record("Expected cursorCommand on the wire, got \(inMemoryTransport.sentMessages)")
            return
        }
        #expect(payload.xFraction == 0.4)
        #expect(payload.label == "click here")
    }

    @Test func outboundSendsAreDroppedWhenNotActive() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        let inMemoryTransport = InMemoryRemoteSessionTransport()
        sessionManager.attachTransport(inMemoryTransport)

        // Never reached .active.
        sessionManager.sendCursorCommand(
            CursorCommand(xFraction: 0.01, yFraction: 0.02, screenIndex: 0, label: nil)
        )

        #expect(inMemoryTransport.sentMessages.isEmpty)
    }

    // MARK: - Teardown / disconnect

    @Test func endSessionFromActiveTearsDownAndReleasesAudio() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        let inMemoryTransport = InMemoryRemoteSessionTransport()
        sessionManager.attachTransport(inMemoryTransport)
        sessionManager.requestSession(now: referenceTime)
        sessionManager.handleConsent(.accepted, now: referenceTime)

        sessionManager.endSession()

        #expect(sessionManager.state == .idle)
        #expect(coordinator.currentOwner == .idle)
        #expect(inMemoryTransport.teardownCallCount == 1)
    }

    @Test func endSessionIsIdempotentFromIdle() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)

        sessionManager.endSession()
        sessionManager.endSession()

        #expect(sessionManager.state == .idle)
    }

    @Test func endSessionFromAwaitingConsentReturnsToIdle() {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        sessionManager.requestSession(now: referenceTime)

        sessionManager.endSession()

        #expect(sessionManager.state == .idle)
        #expect(coordinator.currentOwner == .idle) // never acquired
    }

    /// Phase 1 Test Plan row: "Either-side disconnect → graceful
    /// recovery". L0 policy: an active-session disconnect ends the
    /// session and releases audio; the 10-second reconnect window is
    /// Lane A work.
    @Test func transportDisconnectDuringActiveEndsTheSession() async {
        let coordinator = AudioSessionCoordinator()
        let sessionManager = RemoteSessionManager(audioSessionCoordinator: coordinator)
        let inMemoryTransport = InMemoryRemoteSessionTransport()
        sessionManager.attachTransport(inMemoryTransport)
        sessionManager.requestSession(now: referenceTime)
        sessionManager.handleConsent(.accepted, now: referenceTime)

        inMemoryTransport.simulateDisconnect()

        // attachTransport hops disconnect callbacks through Task { @MainActor }
        // so we yield once to let the hop complete before asserting.
        await Task.yield()
        await Task.yield()

        #expect(sessionManager.state == .idle)
        #expect(coordinator.currentOwner == .idle)
    }
}
