//
//  RemoteWireMessage.swift
//  leanring-buddy
//
//  v1 wire protocol for the kid <-> senior WebRTC data channel.
//  JSON-encoded, forward-compatible: decoders ignore unknown top-level
//  fields and surface unknown `kind` values as `.unsupported(...)` so
//  callers can log + drop rather than crash.
//
//  Mirror in worker/src/wire/v1.ts must change in lockstep.
//

import Foundation

/// Protocol-level version. Bump only on a breaking schema change; additive
/// fields stay on v1 because both sides ignore unknown keys.
enum RemoteWireProtocolVersion {
    static let current: Int = 1
}

/// Top-level envelope sent on the data channel.
///
/// Wire format (JSON):
///   {
///     "v": 1,
///     "kind": "cursor.command" | "snap.request" | "click.confirmation",
///     "id":   "<uuid>",
///     "ts":   <unix-ms>,
///     "data": { ... type-specific payload ... }
///   }
///
/// Unknown top-level fields are ignored. Unknown `kind` values decode to
/// `.unsupported(rawKind:rawData:)` so the receiver can log and drop the
/// message without throwing.
enum RemoteWireMessage: Equatable {
    case cursorCommand(envelope: RemoteWireEnvelope, payload: CursorCommand)
    case snapRequest(envelope: RemoteWireEnvelope, payload: SnapRequest)
    case snapDelivery(envelope: RemoteWireEnvelope, payload: SnapDelivery)
    case clickConfirmation(envelope: RemoteWireEnvelope, payload: ClickConfirmation)
    case helpSessionRequest(envelope: RemoteWireEnvelope, payload: HelpSessionRequest)
    case unsupported(envelope: RemoteWireEnvelope, rawKind: String)

    var envelope: RemoteWireEnvelope {
        switch self {
        case .cursorCommand(let envelope, _): return envelope
        case .snapRequest(let envelope, _): return envelope
        case .snapDelivery(let envelope, _): return envelope
        case .clickConfirmation(let envelope, _): return envelope
        case .helpSessionRequest(let envelope, _): return envelope
        case .unsupported(let envelope, _): return envelope
        }
    }
}

/// Envelope fields shared by every message kind.
struct RemoteWireEnvelope: Equatable {
    let protocolVersion: Int
    let messageId: UUID
    let sentAtUnixMilliseconds: Int64

    init(
        protocolVersion: Int = RemoteWireProtocolVersion.current,
        messageId: UUID = UUID(),
        sentAtUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.protocolVersion = protocolVersion
        self.messageId = messageId
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
    }
}

/// Kid -> senior. Asks the senior-side cursor overlay to fly to a point.
///
/// Coordinates are in the senior's *device-pixel* space for the named
/// screen (zero-indexed across `NSScreen.screens`). The kid app is
/// responsible for translating from its preview-window coordinate space.
struct CursorCommand: Codable, Equatable {
    /// Target x in senior-side pixel coordinates (top-left origin within the
    /// chosen screen).
    let x: Double
    /// Target y in senior-side pixel coordinates.
    let y: Double
    /// Zero-indexed screen number on the senior's machine. Maps to
    /// `NSScreen.screens[screenIndex]`.
    let screenIndex: Int
    /// Optional speech-bubble text rendered next to the cursor. Capped at
    /// 200 chars by the encoder so a malformed sender can't blow up the
    /// overlay.
    let label: String?
}

/// Kid -> senior. Asks the senior to send a fresh screenshot snap.
///
/// Throttling lives on the senior side (default: 1 snap / 500 ms per
/// design doc). The `reason` field is informational only.
struct SnapRequest: Codable, Equatable {
    /// Optional screen index when the kid wants a specific monitor; `nil`
    /// means "all monitors, your choice."
    let screenIndex: Int?
    /// Free-form hint surfaced for telemetry / debugging. e.g.
    /// "kid-clicked", "kid-scrolled", "session-start".
    let reason: String?
}

/// Senior -> kid. Delivers an encoded screenshot snap.
///
/// Phase 1 ships bytes inline as base64 inside the JSON envelope so we
/// have a single message kind to reason about. Phase 2 may switch to
/// a binary data-channel frame for efficiency; the envelope shape
/// stays the same so older clients keep working.
struct SnapDelivery: Codable, Equatable {
    enum Format: String, Codable, Equatable {
        case heic
        case jpeg
    }

    /// Base64-encoded image bytes. Decoder uses
    /// `Data(base64Encoded:)` which silently rejects malformed input;
    /// a malformed snap ends up as a transient render failure rather
    /// than a crash.
    let bytesBase64: String
    let format: Format
    let pixelWidth: Int
    let pixelHeight: Int

    /// Zero-indexed senior screen this snap came from. Mirrors the
    /// CursorCommand.screenIndex space so click translation lines up.
    let screenIndex: Int
}

/// Kid -> senior. Triggers the consent dialog on the senior's Mac.
///
/// Carries the kid's display name so the senior dialog reads
/// "<name> wants to help on your screen." Sent the moment the kid
/// presses "Help Mom" in the panel.
struct HelpSessionRequest: Codable, Equatable {
    let kidDisplayName: String
}

/// Bidirectional. Records that a click action was confirmed (or rejected).
///
/// Phase 1 produces these on senior-side when Mom presses the panel
/// "Click" button on a guided-action proposal. Phase 3+ uses the same
/// type for AI-proposed actions Mom must confirm.
struct ClickConfirmation: Codable, Equatable {
    enum Decision: String, Codable {
        case confirmed
        case declined
        case timedOut
    }

    /// The id of the proposed action this confirmation answers. Matches a
    /// prior `CursorCommand.envelope.messageId.uuidString` so the kid can
    /// correlate.
    let proposalId: String
    let decision: Decision
    /// Senior-side timestamp at the moment of decision (unix ms).
    let decidedAtUnixMilliseconds: Int64
}
