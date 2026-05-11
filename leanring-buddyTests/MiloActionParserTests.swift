//
//  MiloActionParserTests.swift
//  leanring-buddyTests
//
//  Behavior matrix for MiloActionParser. The parser extracts the
//  trailing [ACTION:{...}] tag from a Claude response by scanning
//  brackets/braces — these tests pin the edge cases (nested JSON,
//  strings with escaped quotes, malformed payloads, mid-response tags).
//

import Testing
@testable import Milo

struct MiloActionParserTests {

    // MARK: - No tag

    @Test func responseWithNoTagPassesThrough() {
        let response = "Sure, click the blue button."
        let result = MiloActionParser.parse(response)
        #expect(result.spokenText == response)
        #expect(result.action == nil)
    }

    @Test func emptyResponseProducesEmpty() {
        let result = MiloActionParser.parse("")
        #expect(result.spokenText == "")
        #expect(result.action == nil)
    }

    // MARK: - Well-formed tag

    @Test func parsesSingleClickAction() {
        let response = #"""
        I'll click the Reply button. [ACTION:{"steps":[{"verb":"click","x":420,"y":312,"screen":1,"label":"Reply"}],"confirm":"Click Reply"}]
        """#
        let result = MiloActionParser.parse(response)

        #expect(result.spokenText == "I'll click the Reply button.")
        #expect(result.action != nil)
        #expect(result.action?.steps.count == 1)
        #expect(result.action?.confirm == "Click Reply")
    }

    @Test func parsesMultiStepAction() {
        let response = #"""
        Sending now. [ACTION:{"steps":[{"verb":"click","x":420,"y":312,"label":"Reply"},{"verb":"type","text":"Hi!"},{"verb":"keypress","key":"return","modifiers":["cmd"]}],"confirm":"Send 'Hi!'"}]
        """#
        let result = MiloActionParser.parse(response)

        #expect(result.spokenText == "Sending now.")
        #expect(result.action?.steps.count == 3)
    }

    @Test func trailingWhitespaceAfterTagIsTolerated() {
        let response = #"""
        Done. [ACTION:{"steps":[{"verb":"point","x":1,"y":2,"label":"here"}],"confirm":"point"}]

        """#
        let result = MiloActionParser.parse(response)
        #expect(result.action != nil)
        #expect(result.spokenText == "Done.")
    }

    // MARK: - JSON payload edge cases

    @Test func textWithEscapedQuoteInsideJSONIsTolerated() {
        let response = #"""
        Replying. [ACTION:{"steps":[{"verb":"type","text":"She said \"hi\""}],"confirm":"type"}]
        """#
        let result = MiloActionParser.parse(response)
        #expect(result.action != nil)
        if case let .type(text) = result.action?.steps[0] {
            #expect(text == "She said \"hi\"")
        } else {
            Issue.record("Expected type step")
        }
    }

    @Test func textWithBracketsInsideJSONStringDoesNotBreakScanner() {
        let response = #"""
        Type. [ACTION:{"steps":[{"verb":"type","text":"array[0] and {x}"}],"confirm":"type"}]
        """#
        let result = MiloActionParser.parse(response)
        #expect(result.action != nil)
        if case let .type(text) = result.action?.steps[0] {
            #expect(text == "array[0] and {x}")
        } else {
            Issue.record("Expected type step")
        }
    }

    @Test func nestedObjectsAreToleratedByBraceCounting() {
        // The grammar doesn't currently use nested objects, but the
        // scanner should still handle them — this protects against
        // future schema evolution.
        let response = #"""
        Hmm. [ACTION:{"steps":[{"verb":"point","x":1,"y":2,"label":"a"}],"confirm":"x","meta":{"nested":{"deep":true}}}]
        """#
        let result = MiloActionParser.parse(response)
        // Unknown keys (`meta`) are ignored by Codable; the action
        // should still decode.
        #expect(result.action != nil)
    }

    // MARK: - Malformed

    @Test func malformedJSONStillStripsTagFromSpokenText() {
        let response = #"""
        Trying. [ACTION:{not valid json at all}]
        """#
        let result = MiloActionParser.parse(response)
        // The scanner still locates a brace-balanced close even when the
        // JSON inside is garbage; spoken text should drop the tag so the
        // user doesn't hear it read aloud.
        #expect(result.spokenText == "Trying.")
        #expect(result.action == nil)
    }

    @Test func unclosedTagFallsThroughAsPlainText() {
        let response = #"""
        Trying. [ACTION:{"steps":[
        """#
        let result = MiloActionParser.parse(response)
        #expect(result.spokenText == response)
        #expect(result.action == nil)
    }

    @Test func tagInMiddleOfResponseIsNotConsumed() {
        let response = #"""
        I tried [ACTION:{"steps":[{"verb":"click","x":1,"y":2,"label":"X"}],"confirm":"x"}] earlier but it didn't work.
        """#
        let result = MiloActionParser.parse(response)
        // Tag isn't trailing, so it's left in place. (Spoken text
        // includes the literal tag in this fallback — acceptable since
        // it's a malformed input.)
        #expect(result.action == nil)
        #expect(result.spokenText == response)
    }

    @Test func unknownVerbDecodesAsNilActionButStripsTag() {
        let response = #"""
        Hmm. [ACTION:{"steps":[{"verb":"explode","x":1,"y":2}],"confirm":"x"}]
        """#
        let result = MiloActionParser.parse(response)
        #expect(result.action == nil)
        #expect(result.spokenText == "Hmm.")
    }
}
