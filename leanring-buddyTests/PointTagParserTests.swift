//
//  PointTagParserTests.swift
//  leanring-buddyTests
//
//  Behavior matrix for PointTagParser. Covers every shape the
//  CompanionManager pipeline depends on plus the malformed-tag fallthroughs.
//

import Testing
import CoreGraphics
@testable import Milo

struct PointTagParserTests {

    // MARK: - parse: no tag

    @Test func responseWithNoTagIsPassedThroughUnchanged() {
        let response = "Sure — that's the run button in the toolbar."
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == response)
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
    }

    // MARK: - parse: [POINT:none]

    @Test func pointNoneStripsTagAndYieldsNoCoordinate() {
        let response = "I can't see anything to point at. [POINT:none]"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == "I can't see anything to point at.")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
        #expect(result.screenNumber == nil)
    }

    // MARK: - parse: coordinate only

    @Test func bareCoordinateTagYieldsCoordinateAndNoLabel() {
        let response = "Click here. [POINT:120,340]"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == "Click here.")
        #expect(result.coordinate == CGPoint(x: 120, y: 340))
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
    }

    // MARK: - parse: coordinate + label

    @Test func coordinateWithLabelExposesBothFields() {
        let response = "Press the green button. [POINT:42,17:run button]"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == "Press the green button.")
        #expect(result.coordinate == CGPoint(x: 42, y: 17))
        #expect(result.elementLabel == "run button")
        #expect(result.screenNumber == nil)
    }

    // MARK: - parse: coordinate + label + screen

    @Test func coordinateWithLabelAndScreenExposesAllFields() {
        let response = "It's on your second display. [POINT:800,600:reply button:screen2]"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == "It's on your second display.")
        #expect(result.coordinate == CGPoint(x: 800, y: 600))
        #expect(result.elementLabel == "reply button")
        #expect(result.screenNumber == 2)
    }

    // MARK: - parse: trailing whitespace tolerated

    @Test func trailingWhitespaceAfterTagIsTolerated() {
        let response = "Right there. [POINT:1,2:thing]   \n"
        let result = PointTagParser.parse(response)

        #expect(result.coordinate == CGPoint(x: 1, y: 2))
        #expect(result.elementLabel == "thing")
        #expect(result.spokenText == "Right there.")
    }

    // MARK: - parse: whitespace between coordinate digits

    @Test func whitespaceAroundCommaInCoordinateIsTolerated() {
        let response = "Aim here. [POINT:100 , 200]"
        let result = PointTagParser.parse(response)

        #expect(result.coordinate == CGPoint(x: 100, y: 200))
    }

    // MARK: - parse: malformed — tag mid-response is NOT a trailing tag

    @Test func tagInMiddleOfResponseIsNotConsumed() {
        let response = "I saw [POINT:5,5] earlier but it moved. Now look here."
        let result = PointTagParser.parse(response)

        // The pattern is anchored to end-of-string, so a mid-response tag
        // is left in place and no coordinate is extracted.
        #expect(result.spokenText == response)
        #expect(result.coordinate == nil)
    }

    // MARK: - parse: malformed — unclosed bracket

    @Test func unclosedTagFallsThroughAsPlainText() {
        let response = "Look here. [POINT:10,20:button"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == response)
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
    }

    // MARK: - parse: malformed — non-numeric coordinates

    @Test func nonNumericCoordinatesAreNotMatched() {
        let response = "Look. [POINT:abc,def:label]"
        let result = PointTagParser.parse(response)

        #expect(result.spokenText == response)
        #expect(result.coordinate == nil)
    }

    // MARK: - parse: empty response

    @Test func emptyResponseProducesEmptyResult() {
        let result = PointTagParser.parse("")

        #expect(result.spokenText == "")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
    }

    // MARK: - isGuidedActionRequest

    @Test func clickKeywordTriggersGuidedAction() {
        #expect(PointTagParser.isGuidedActionRequest("Where do I click to send?"))
    }

    @Test func phraseShowMeWhereTriggersGuidedAction() {
        #expect(PointTagParser.isGuidedActionRequest("Show me where the reply button is"))
    }

    @Test func openKeywordTriggersGuidedAction() {
        #expect(PointTagParser.isGuidedActionRequest("Open settings"))
    }

    @Test func caseInsensitiveMatch() {
        #expect(PointTagParser.isGuidedActionRequest("PRESS the button"))
    }

    @Test func plainExplanationDoesNotTriggerGuidedAction() {
        #expect(!PointTagParser.isGuidedActionRequest("What does this error mean?"))
    }

    @Test func emptyTranscriptDoesNotTriggerGuidedAction() {
        #expect(!PointTagParser.isGuidedActionRequest(""))
    }
}
