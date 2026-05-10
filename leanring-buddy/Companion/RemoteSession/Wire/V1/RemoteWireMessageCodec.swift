//
//  RemoteWireMessageCodec.swift
//  leanring-buddy
//
//  Encode/decode for `RemoteWireMessage` over the WebRTC data channel.
//
//  Design notes:
//  - Forward-compat: unknown top-level fields are silently ignored
//    (Codable's default behaviour). Unknown `kind` values decode to
//    `.unsupported(...)` instead of throwing, so a v1.1-or-later sender
//    cannot crash a v1 receiver.
//  - All numeric timestamps are unix milliseconds (Int64) so we don't
//    have to negotiate locale/precision with the Worker / future TS
//    clients.
//  - `messageId` is a UUID string to keep the JSON shape identical
//    between Swift and TypeScript.
//

import Foundation

enum RemoteWireMessageCodec {
    /// Surface every decode failure mode the receiver should expect. The
    /// caller logs + drops; never crashes.
    enum DecodeError: Error, Equatable {
        case malformedJSON
        case missingRequiredField(String)
        case unsupportedProtocolVersion(Int)
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let jsonDecoder = JSONDecoder()

    static func encode(_ message: RemoteWireMessage) throws -> Data {
        let envelope = message.envelope
        let kind = wireKind(for: message)
        let payloadJSON = try encodePayload(message)

        let document: [String: Any] = [
            "v": envelope.protocolVersion,
            "kind": kind,
            "id": envelope.messageId.uuidString,
            "ts": envelope.sentAtUnixMilliseconds,
            "data": try JSONSerialization.jsonObject(with: payloadJSON, options: [.fragmentsAllowed])
        ]

        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> RemoteWireMessage {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodeError.malformedJSON
        }

        guard let topLevelObject = parsed as? [String: Any] else {
            throw DecodeError.malformedJSON
        }

        let protocolVersion = topLevelObject["v"] as? Int ?? RemoteWireProtocolVersion.current
        if protocolVersion < 1 {
            throw DecodeError.unsupportedProtocolVersion(protocolVersion)
        }

        guard let rawKind = topLevelObject["kind"] as? String else {
            throw DecodeError.missingRequiredField("kind")
        }
        guard let messageIdString = topLevelObject["id"] as? String,
              let messageId = UUID(uuidString: messageIdString) else {
            throw DecodeError.missingRequiredField("id")
        }
        guard let sentAtMilliseconds = topLevelObject["ts"] as? Int64
                ?? (topLevelObject["ts"] as? Int).map(Int64.init)
                ?? (topLevelObject["ts"] as? Double).map(Int64.init) else {
            throw DecodeError.missingRequiredField("ts")
        }

        let envelope = RemoteWireEnvelope(
            protocolVersion: protocolVersion,
            messageId: messageId,
            sentAtUnixMilliseconds: sentAtMilliseconds
        )

        let payloadValue = topLevelObject["data"] ?? [String: Any]()
        let payloadData = try JSONSerialization.data(withJSONObject: payloadValue, options: [.fragmentsAllowed])

        switch rawKind {
        case "cursor.command":
            let payload = try jsonDecoder.decode(CursorCommand.self, from: payloadData)
            return .cursorCommand(envelope: envelope, payload: payload)
        case "snap.request":
            let payload = try jsonDecoder.decode(SnapRequest.self, from: payloadData)
            return .snapRequest(envelope: envelope, payload: payload)
        case "snap.delivery":
            let payload = try jsonDecoder.decode(SnapDelivery.self, from: payloadData)
            return .snapDelivery(envelope: envelope, payload: payload)
        case "click.confirmation":
            let payload = try jsonDecoder.decode(ClickConfirmation.self, from: payloadData)
            return .clickConfirmation(envelope: envelope, payload: payload)
        case "help.session.request":
            let payload = try jsonDecoder.decode(HelpSessionRequest.self, from: payloadData)
            return .helpSessionRequest(envelope: envelope, payload: payload)
        default:
            return .unsupported(envelope: envelope, rawKind: rawKind)
        }
    }

    private static func wireKind(for message: RemoteWireMessage) -> String {
        switch message {
        case .cursorCommand: return "cursor.command"
        case .snapRequest: return "snap.request"
        case .snapDelivery: return "snap.delivery"
        case .clickConfirmation: return "click.confirmation"
        case .helpSessionRequest: return "help.session.request"
        case .unsupported(_, let rawKind): return rawKind
        }
    }

    private static func encodePayload(_ message: RemoteWireMessage) throws -> Data {
        switch message {
        case .cursorCommand(_, let payload):
            return try jsonEncoder.encode(payload)
        case .snapRequest(_, let payload):
            return try jsonEncoder.encode(payload)
        case .snapDelivery(_, let payload):
            return try jsonEncoder.encode(payload)
        case .clickConfirmation(_, let payload):
            return try jsonEncoder.encode(payload)
        case .helpSessionRequest(_, let payload):
            return try jsonEncoder.encode(payload)
        case .unsupported:
            return Data("{}".utf8)
        }
    }
}
