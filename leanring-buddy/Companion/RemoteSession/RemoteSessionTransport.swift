//
//  RemoteSessionTransport.swift
//  leanring-buddy
//
//  Boundary between RemoteSessionManager (L0, no networking) and the
//  WebRTC integration (Lane A). The manager owns the state machine and
//  the audio-pipeline contract; the transport owns the bytes.
//

import Foundation

/// Phase 1 transport surface. Lane A injects the real WebRTC
/// implementation; tests inject in-memory stubs.
protocol RemoteSessionTransport: AnyObject {
    /// Encode + send a wire message on the data channel.
    /// Failure modes (channel closed, encode error) are surfaced via
    /// `onTransportError`; this method should not throw to the caller.
    func send(_ message: RemoteWireMessage)

    /// Tear down any underlying connection. Idempotent — safe to call
    /// multiple times during multi-stage shutdown.
    func teardown()

    /// Set by the manager to receive incoming messages.
    var onMessage: ((RemoteWireMessage) -> Void)? { get set }

    /// Set by the manager to handle peer disconnect / data-channel
    /// closure. The manager decides whether to attempt reconnect based
    /// on its current state.
    var onDisconnect: (() -> Void)? { get set }

    /// Set by the manager to surface transport-level errors that don't
    /// imply disconnect (e.g. encode failure). Logged + dropped at the
    /// manager tier; never crashes.
    var onTransportError: ((Error) -> Void)? { get set }
}

/// In-memory transport for unit tests. Records every outbound message
/// and lets the test harness inject inbound messages and disconnects.
final class InMemoryRemoteSessionTransport: RemoteSessionTransport {
    private(set) var sentMessages: [RemoteWireMessage] = []
    private(set) var teardownCallCount: Int = 0

    var onMessage: ((RemoteWireMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onTransportError: ((Error) -> Void)?

    func send(_ message: RemoteWireMessage) {
        sentMessages.append(message)
    }

    func teardown() {
        teardownCallCount += 1
    }

    /// Test helper — pretend a peer message arrived.
    func simulateIncomingMessage(_ message: RemoteWireMessage) {
        onMessage?(message)
    }

    /// Test helper — pretend the data channel closed.
    func simulateDisconnect() {
        onDisconnect?()
    }
}
