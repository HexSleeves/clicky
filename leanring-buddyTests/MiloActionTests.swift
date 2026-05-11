//
//  MiloActionTests.swift
//  leanring-buddyTests
//
//  Codable round-trip + invariants for Action Grammar v2. The wire
//  format is what Claude is taught to emit, so a regression here means
//  Claude responses fail to decode in production.
//

import Testing
import Foundation
@testable import Milo

struct MiloActionTests {

    // MARK: - Encode/decode round-trip per verb

    @Test func pointStepRoundTrips() throws {
        let original = MiloAction(
            steps: [.point(x: 100, y: 200, screen: 1, label: "Reply")],
            confirm: "Point at Reply"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func clickStepRoundTrips() throws {
        let original = MiloAction(
            steps: [.click(x: 420, y: 312, screen: 2, label: "Send")],
            confirm: "Click Send"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func typeStepRoundTrips() throws {
        let original = MiloAction(
            steps: [.type(text: "Hello, world!")],
            confirm: "Type greeting"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func keypressStepRoundTrips() throws {
        let original = MiloAction(
            steps: [.keypress(key: "s", modifiers: [.cmd])],
            confirm: "Save"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func keypressWithNoModifiersRoundTrips() throws {
        let original = MiloAction(
            steps: [.keypress(key: "return", modifiers: [])],
            confirm: "Press return"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func scrollStepRoundTrips() throws {
        let original = MiloAction(
            steps: [.scroll(x: 500, y: 500, screen: nil, deltaX: 0, deltaY: -10)],
            confirm: "Scroll up"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    // MARK: - Multi-step sequence

    @Test func multiStepSequenceRoundTrips() throws {
        let original = MiloAction(
            steps: [
                .click(x: 420, y: 312, screen: 1, label: "Reply field"),
                .type(text: "Hi!"),
                .keypress(key: "return", modifiers: [.cmd])
            ],
            confirm: "Send 'Hi!' as a reply"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.steps.count == 3)
    }

    // MARK: - Decoding from the documented wire format

    @Test func decodesCanonicalWireFormat() throws {
        let json = #"""
        {
          "steps": [
            {"verb":"click","x":420,"y":312,"screen":1,"label":"Reply"},
            {"verb":"type","text":"Hi!"},
            {"verb":"keypress","key":"return","modifiers":["cmd"]}
          ],
          "confirm":"Send 'Hi!' as a reply"
        }
        """#

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MiloAction.self, from: data)

        #expect(decoded.steps.count == 3)
        #expect(decoded.confirm == "Send 'Hi!' as a reply")
        if case let .click(x, y, screen, label) = decoded.steps[0] {
            #expect(x == 420)
            #expect(y == 312)
            #expect(screen == 1)
            #expect(label == "Reply")
        } else {
            Issue.record("Expected click step")
        }
    }

    @Test func decodesScreenAsOptional() throws {
        let json = #"""
        {
          "steps":[{"verb":"point","x":10,"y":20,"label":"thing"}],
          "confirm":"Look here"
        }
        """#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MiloAction.self, from: data)
        if case let .point(_, _, screen, _) = decoded.steps[0] {
            #expect(screen == nil)
        } else {
            Issue.record("Expected point step")
        }
    }

    @Test func decodingUnknownVerbThrows() {
        let json = #"""
        {"steps":[{"verb":"explode","x":1,"y":2}],"confirm":"oops"}
        """#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MiloAction.self, from: data)
        }
    }

    // MARK: - Safety classification

    @Test func singleClickIsSafeForBypass() {
        let action = MiloAction(
            steps: [.click(x: 10, y: 20, screen: 1, label: "OK")],
            confirm: "Click OK"
        )
        #expect(action.isSafeForAutoBypass)
    }

    @Test func singlePointIsSafeForBypass() {
        let action = MiloAction(
            steps: [.point(x: 10, y: 20, screen: 1, label: "Here")],
            confirm: "Point"
        )
        #expect(action.isSafeForAutoBypass)
    }

    @Test func typeStepBlocksBypass() {
        let action = MiloAction(
            steps: [.type(text: "anything")],
            confirm: "Type"
        )
        #expect(!action.isSafeForAutoBypass)
    }

    @Test func keypressStepBlocksBypass() {
        let action = MiloAction(
            steps: [.keypress(key: "return", modifiers: [.cmd])],
            confirm: "Send"
        )
        #expect(!action.isSafeForAutoBypass)
    }

    @Test func multiStepSequenceBlocksBypassEvenWhenAllSafe() {
        let action = MiloAction(
            steps: [
                .click(x: 1, y: 1, screen: nil, label: "A"),
                .click(x: 2, y: 2, screen: nil, label: "B")
            ],
            confirm: "Two clicks"
        )
        // Two-step sequences require explicit confirmation regardless of
        // step safety — auto-bypass is single-step-only.
        #expect(!action.isSafeForAutoBypass)
    }

    // MARK: - Helpers

    private func roundTrip(_ action: MiloAction) throws -> MiloAction {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(MiloAction.self, from: data)
    }
}
