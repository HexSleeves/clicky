//
//  NoteCaptureRouterTests.swift
//  leanring-buddyTests
//
//  Behavior matrix for NoteCaptureRouter. Covers every trigger phrase plus
//  the common rejection cases (questions, empty input, "remember when"
//  stories that should not become notes).
//

import Testing
@testable import leanring_buddy

struct NoteCaptureRouterTests {

    // MARK: - "remember that …" variants

    @Test func rememberThatExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that my router password is on the fridge.")
        #expect(result == "my router password is on the fridge")
    }

    @Test func rememberToExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "remember to water the plants on tuesday")
        #expect(result == "water the plants on tuesday")
    }

    @Test func pleaseRememberThatExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Please remember that the spare key is under the mat.")
        #expect(result == "the spare key is under the mat")
    }

    // MARK: - "note: …" / "save note: …" variants

    @Test func saveNoteColonExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "save note: buy milk")
        #expect(result == "buy milk")
    }

    @Test func makeANoteThatExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Make a note that I prefer the dark theme.")
        #expect(result == "I prefer the dark theme")
    }

    @Test func bareNoteColonExtractsTrailingText() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Note: dentist appointment friday at 3")
        #expect(result == "dentist appointment friday at 3")
    }

    // MARK: - Case + whitespace handling

    @Test func uppercasePrefixStillMatches() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "REMEMBER THAT today is wednesday")
        #expect(result == "today is wednesday")
    }

    @Test func leadingAndTrailingWhitespaceIsTrimmed() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "   remember that the wifi is mesh-2  \n")
        #expect(result == "the wifi is mesh-2")
    }

    @Test func trailingPunctuationIsTrimmed() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that the deadline is friday!!!")
        #expect(result == "the deadline is friday")
    }

    // MARK: - Negative cases

    @Test func plainQuestionDoesNotMatch() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "What's on my screen right now?")
        #expect(result == nil)
    }

    @Test func rememberWhenStoryDoesNotMatch() {
        // "remember when" is intentionally NOT a trigger — it's a story
        // opener, not a memory-capture intent.
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember when we tried that other approach?")
        #expect(result == nil)
    }

    @Test func emptyInputReturnsNil() {
        #expect(NoteCaptureRouter.parseNoteCaptureText(from: "") == nil)
    }

    @Test func whitespaceOnlyInputReturnsNil() {
        #expect(NoteCaptureRouter.parseNoteCaptureText(from: "   \n  ") == nil)
    }

    @Test func triggerWithNothingAfterReturnsNil() {
        // "remember that " with no trailing content has nothing to save.
        #expect(NoteCaptureRouter.parseNoteCaptureText(from: "remember that ") == nil)
    }

    @Test func triggerFollowedByOnlyPunctuationReturnsNil() {
        // After trimming punctuation there is no note text left.
        #expect(NoteCaptureRouter.parseNoteCaptureText(from: "remember that ...") == nil)
    }

    // MARK: - Prefix ordering

    @Test func saveNoteThatBeatsSaveNote() {
        // "save note that X" should yield "X", not "that X".
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "save note that the printer is in the closet")
        #expect(result == "the printer is in the closet")
    }

    // MARK: - AssemblyAI punctuation insertion

    @Test func commaAfterTriggerStillMatches() {
        // The real-world failure that prompted the regex rewrite — AssemblyAI's
        // streaming model often inserts a comma after the trigger phrase.
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that, my router password is on the fridge.")
        #expect(result == "my router password is on the fridge")
    }

    @Test func periodAfterTriggerStillMatches() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that. The garage code is one two three four.")
        #expect(result == "The garage code is one two three four")
    }

    @Test func colonAfterTriggerStillMatches() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that: I prefer tea over coffee")
        #expect(result == "I prefer tea over coffee")
    }

    @Test func emDashAfterTriggerStillMatches() {
        // AssemblyAI sometimes emits em-dashes for short pauses.
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember that — the spare key is under the mat")
        #expect(result == "the spare key is under the mat")
    }

    @Test func bareRememberWithCommaMatches() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember, the meeting is at four pm")
        #expect(result == "the meeting is at four pm")
    }

    @Test func rememberToWithPunctuationMatches() {
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remember to, pick up the dry cleaning tomorrow.")
        #expect(result == "pick up the dry cleaning tomorrow")
    }

    @Test func remembersWithSDoesNotMatch() {
        // Word-boundary guard — "remembers" should NOT trigger as "remember".
        let result = NoteCaptureRouter.parseNoteCaptureText(from: "Remembers when we tried to fix it")
        #expect(result == nil)
    }
}
