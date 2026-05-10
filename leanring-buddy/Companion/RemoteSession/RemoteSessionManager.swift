//
//  RemoteSessionManager.swift
//  leanring-buddy
//
//  Phase 1, eng-review decision #5. Owns the lifecycle of a single
//  kid <-> senior help session: consent gate, audio pipeline ownership,
//  snap-on-demand throttling, wire-message dispatch, idempotent
//  teardown.
//
//  This manager is intentionally transport-agnostic; Lane A injects the
//  real WebRTC transport, tests inject `InMemoryRemoteSessionTransport`.
//

import Combine
import Foundation

@MainActor
final class RemoteSessionManager: ObservableObject {

    enum State: Equatable {
        case idle
        case awaitingConsent(requestedAt: Date)
        case active(startedAt: Date)
        case ending
    }

    /// Outcome of the per-session consent gate (eng review decision #4
    /// — per-session consent + thin blocklist).
    enum ConsentDecision: String, Equatable, Sendable {
        case accepted
        case declined
        case timedOut
    }

    @Published private(set) var state: State = .idle

    /// Latest consent decision, kept for telemetry / UI replay.
    @Published private(set) var lastConsentDecision: ConsentDecision?

    /// Default snap throttle from the design doc: 1 snap / 500 ms.
    static let defaultSnapThrottleInterval: TimeInterval = 0.5

    private let audioSessionCoordinator: AudioSessionCoordinator
    private let blocklistMonitor: BlocklistMonitor?
    private let snapThrottleInterval: TimeInterval
    private var lastSnapDeliveredAt: Date?

    /// The active transport, if any. Nil between sessions and during
    /// teardown.
    private(set) var transport: RemoteSessionTransport?

    init(
        audioSessionCoordinator: AudioSessionCoordinator,
        blocklistMonitor: BlocklistMonitor? = nil,
        snapThrottleInterval: TimeInterval = RemoteSessionManager.defaultSnapThrottleInterval
    ) {
        self.audioSessionCoordinator = audioSessionCoordinator
        self.blocklistMonitor = blocklistMonitor
        self.snapThrottleInterval = snapThrottleInterval
    }

    // MARK: - Lifecycle

    /// Begin a new session. Senior-side: triggered by Mom pressing the
    /// help button. Kid-side: triggered by accepting an inbound
    /// notification. Either way the next step is the consent gate.
    ///
    /// No-op if a session is already in flight (avoids double-trigger
    /// when Mom hits the menu bar icon twice).
    func requestSession(now: Date = Date()) {
        guard state == .idle else { return }
        state = .awaitingConsent(requestedAt: now)
    }

    /// Senior-side consent path. Phase 1 always goes through here before
    /// any frames leave Mom's Mac.
    ///
    /// On accept: acquires the audio coordinator (preempting PTT if it
    /// was active) and transitions to `.active`.
    /// On decline / timeout: returns to idle without ever touching the
    /// audio pipeline or the transport.
    func handleConsent(_ decision: ConsentDecision, now: Date = Date()) {
        guard case .awaitingConsent = state else { return }
        lastConsentDecision = decision
        switch decision {
        case .accepted:
            _ = audioSessionCoordinator.acquire(.remoteHelpDuplex)
            blocklistMonitor?.startMonitoring()
            state = .active(startedAt: now)
        case .declined, .timedOut:
            state = .idle
        }
    }

    /// Idempotent teardown. Safe to call from any state including
    /// `.idle` and `.ending`.
    func endSession() {
        switch state {
        case .idle, .ending:
            return
        case .awaitingConsent:
            state = .idle
            transport?.teardown()
            transport = nil
            return
        case .active:
            state = .ending
            audioSessionCoordinator.release(.remoteHelpDuplex)
            blocklistMonitor?.stopMonitoring()
            transport?.teardown()
            transport = nil
            lastSnapDeliveredAt = nil
            state = .idle
        }
    }

    // MARK: - Transport wiring

    /// Attach the wire transport. Wires up the manager's message and
    /// disconnect handlers in one place so callers cannot accidentally
    /// leave one unsubscribed.
    func attachTransport(_ transport: RemoteSessionTransport) {
        self.transport = transport
        transport.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleIncoming(message)
            }
        }
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.handleTransportDisconnect()
            }
        }
        transport.onTransportError = { error in
            NSLog("[RemoteSessionManager] transport error: \(error)")
        }
    }

    // MARK: - Snap-on-demand throttle

    /// Returns true iff a fresh snap should be encoded + sent right now.
    /// Used by the senior-side capture loop on input events. Throttled
    /// to 1 / `snapThrottleInterval`; calls outside `.active` are
    /// always denied so we never leak frames before consent.
    @discardableResult
    func shouldDeliverSnap(now: Date = Date()) -> Bool {
        guard case .active = state else { return false }
        if let lastDeliveredAt = lastSnapDeliveredAt,
           now.timeIntervalSince(lastDeliveredAt) < snapThrottleInterval {
            return false
        }
        lastSnapDeliveredAt = now
        return true
    }

    // MARK: - Outbound wire helpers

    /// Convenience for the senior side: build + send a SnapRequest
    /// envelope. Caller handles the actual snap bytes via the binary
    /// channel (Lane A).
    func sendSnapRequest(_ payload: SnapRequest) {
        guard case .active = state else { return }
        let message = RemoteWireMessage.snapRequest(
            envelope: RemoteWireEnvelope(),
            payload: payload
        )
        transport?.send(message)
    }

    /// Convenience for the kid side: build + send a CursorCommand.
    func sendCursorCommand(_ payload: CursorCommand) {
        guard case .active = state else { return }
        let message = RemoteWireMessage.cursorCommand(
            envelope: RemoteWireEnvelope(),
            payload: payload
        )
        transport?.send(message)
    }

    // MARK: - Inbound dispatch

    /// Hook surfaced for tests + future routing layers. Real callers
    /// observe `state` / `@Published` fields rather than calling this.
    private(set) var lastReceivedMessage: RemoteWireMessage?

    private func handleIncoming(_ message: RemoteWireMessage) {
        guard case .active = state else { return }
        lastReceivedMessage = message
    }

    private func handleTransportDisconnect() {
        // Phase 1 policy: any disconnect inside an active session ends
        // the session. The 10-second reconnect window is Lane A work.
        if case .active = state {
            endSession()
        }
    }
}
