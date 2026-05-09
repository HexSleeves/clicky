//
//  RemoteWireMessageTests.swift
//  leanring-buddyTests
//
//  Covers the Phase 1 Test Plan's "Codable wire types" rows:
//  - encode/decode roundtrip per kind
//  - forward-compat: unknown JSON field is ignored
//  - unknown kind decodes to .unsupported instead of throwing
//  - malformed JSON surfaces as DecodeError.malformedJSON, never a crash
//

import Foundation
import Testing
@testable import leanring_buddy

struct RemoteWireMessageTests {

    @Test func cursorCommandRoundtrip() throws {
        let envelope = RemoteWireEnvelope(
            messageId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sentAtUnixMilliseconds: 1_736_400_000_000
        )
        let original = RemoteWireMessage.cursorCommand(
            envelope: envelope,
            payload: CursorCommand(x: 1024.5, y: 768.25, screenIndex: 1, label: "Click here")
        )

        let encodedData = try RemoteWireMessageCodec.encode(original)
        let decodedMessage = try RemoteWireMessageCodec.decode(encodedData)

        #expect(decodedMessage == original)
    }

    @Test func snapRequestRoundtrip() throws {
        let original = RemoteWireMessage.snapRequest(
            envelope: RemoteWireEnvelope(),
            payload: SnapRequest(screenIndex: nil, reason: "kid-clicked")
        )

        let encodedData = try RemoteWireMessageCodec.encode(original)
        let decodedMessage = try RemoteWireMessageCodec.decode(encodedData)

        #expect(decodedMessage == original)
    }

    @Test func clickConfirmationRoundtrip() throws {
        let original = RemoteWireMessage.clickConfirmation(
            envelope: RemoteWireEnvelope(),
            payload: ClickConfirmation(
                proposalId: "11111111-2222-3333-4444-555555555555",
                decision: .confirmed,
                decidedAtUnixMilliseconds: 1_736_400_010_000
            )
        )

        let encodedData = try RemoteWireMessageCodec.encode(original)
        let decodedMessage = try RemoteWireMessageCodec.decode(encodedData)

        #expect(decodedMessage == original)
    }

    /// Phase 1 Test Plan row: "Forward-compat: unknown JSON field is ignored."
    /// Simulates a future v1.x sender adding a new top-level field. A v1
    /// receiver MUST decode the message anyway.
    @Test func unknownTopLevelFieldIsIgnored() throws {
        let futureLookingJSON = """
        {
          "v": 1,
          "kind": "cursor.command",
          "id": "11111111-2222-3333-4444-555555555555",
          "ts": 1736400000000,
          "futureField": { "experimental": true },
          "data": { "x": 100, "y": 200, "screenIndex": 0, "label": null }
        }
        """

        let decodedMessage = try RemoteWireMessageCodec.decode(Data(futureLookingJSON.utf8))

        guard case .cursorCommand(_, let payload) = decodedMessage else {
            Issue.record("Expected cursorCommand, got \(decodedMessage)")
            return
        }
        #expect(payload.x == 100)
        #expect(payload.screenIndex == 0)
    }

    /// Unknown `kind` string MUST decode to `.unsupported(...)` rather than
    /// throwing — the receiver logs and drops, never crashes.
    @Test func unknownKindDecodesToUnsupported() throws {
        let futureKindJSON = """
        {
          "v": 1,
          "kind": "click.macro",
          "id": "11111111-2222-3333-4444-555555555555",
          "ts": 1736400000000,
          "data": {}
        }
        """

        let decodedMessage = try RemoteWireMessageCodec.decode(Data(futureKindJSON.utf8))

        guard case .unsupported(_, let rawKind) = decodedMessage else {
            Issue.record("Expected unsupported, got \(decodedMessage)")
            return
        }
        #expect(rawKind == "click.macro")
    }

    /// Phase 1 Test Plan row: "Malformed JSON → log + drop, don't crash."
    @Test func malformedJSONSurfacesError() {
        let garbageData = Data("{ this is not valid json".utf8)

        #expect(throws: RemoteWireMessageCodec.DecodeError.malformedJSON) {
            _ = try RemoteWireMessageCodec.decode(garbageData)
        }
    }

    @Test func missingKindFieldSurfacesError() {
        let jsonWithoutKind = """
        { "v": 1, "id": "11111111-2222-3333-4444-555555555555", "ts": 1, "data": {} }
        """

        #expect(throws: RemoteWireMessageCodec.DecodeError.self) {
            _ = try RemoteWireMessageCodec.decode(Data(jsonWithoutKind.utf8))
        }
    }
}
