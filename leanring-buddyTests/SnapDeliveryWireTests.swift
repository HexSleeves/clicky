//
//  SnapDeliveryWireTests.swift
//  leanring-buddyTests
//
//  Roundtrip + tolerance for the SnapDelivery wire kind added in the
//  end-to-end remote-help wiring commit.
//

import Foundation
import Testing
@testable import leanring_buddy

struct SnapDeliveryWireTests {

    @Test func snapDeliveryRoundtrip() throws {
        let original = RemoteWireMessage.snapDelivery(
            envelope: RemoteWireEnvelope(),
            payload: SnapDelivery(
                bytesBase64: Data("hello world".utf8).base64EncodedString(),
                format: .heic,
                pixelWidth: 1440,
                pixelHeight: 900,
                screenIndex: 0
            )
        )
        let encodedData = try RemoteWireMessageCodec.encode(original)
        let decodedMessage = try RemoteWireMessageCodec.decode(encodedData)
        #expect(decodedMessage == original)
    }

    /// Forward-compat: an unknown format string in a snap.delivery
    /// payload should fail to decode (Codable enum mismatch); upstream
    /// callers treat the error as a transient render failure rather
    /// than crashing.
    @Test func snapDeliveryRejectsUnknownFormat() {
        let futureFormatJSON = """
        {
          "v": 1,
          "kind": "snap.delivery",
          "id": "11111111-2222-3333-4444-555555555555",
          "ts": 1736400000000,
          "data": {
            "bytesBase64": "AA==",
            "format": "avif",
            "pixelWidth": 100,
            "pixelHeight": 100,
            "screenIndex": 0
          }
        }
        """
        #expect(throws: (any Error).self) {
            _ = try RemoteWireMessageCodec.decode(Data(futureFormatJSON.utf8))
        }
    }
}
