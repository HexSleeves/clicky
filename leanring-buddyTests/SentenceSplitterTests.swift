//
//  SentenceSplitterTests.swift
//  leanring-buddyTests
//
//  Pins the incremental sentence-detection behavior. The streaming TTS
//  pipeline calls `consume` on every Claude SSE chunk, so correct
//  emission order + completeness matters across chunk boundaries that
//  can land mid-sentence, mid-terminator, or mid-whitespace.
//

import Testing
@testable import Milo

@MainActor
struct SentenceSplitterTests {

    // MARK: - Single-call cases

    @Test func emptyChunkEmitsNothing() {
        let splitter = SentenceSplitter()
        #expect(splitter.consume("") == [])
    }

    @Test func incompleteSentenceIsHeld() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("Hello there")
        #expect(emitted == [])
    }

    @Test func singleCompleteSentenceEmits() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("Hello there. ")
        #expect(emitted == ["Hello there."])
    }

    @Test func twoSentencesInOneChunkEmitBoth() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("First sentence. Second sentence. ")
        #expect(emitted == ["First sentence.", "Second sentence."])
    }

    @Test func questionAndExclamationAreTerminators() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("Got it! What now? ")
        #expect(emitted == ["Got it!", "What now?"])
    }

    // MARK: - Incremental streaming (the real use case)

    @Test func sentenceCompletesAcrossMultipleChunks() {
        let splitter = SentenceSplitter()
        #expect(splitter.consume("Hello ") == [])
        #expect(splitter.consume("there") == [])
        #expect(splitter.consume(". ") == ["Hello there."])
    }

    @Test func chunkBoundaryAtTerminatorEmitsOnNextWhitespace() {
        // Terminator alone isn't enough — Claude could be in the middle
        // of a decimal "3.14" or just emit "." with more text coming.
        // We wait for whitespace as confirmation.
        let splitter = SentenceSplitter()
        #expect(splitter.consume("Sure.") == [])           // no whitespace yet
        #expect(splitter.consume(" Here") == ["Sure."])    // whitespace confirms
        #expect(splitter.consume(" we go. ") == ["Here we go."])
    }

    @Test func chunkBoundaryMidWordHoldsUntilTerminator() {
        let splitter = SentenceSplitter()
        #expect(splitter.consume("This is a sen") == [])
        #expect(splitter.consume("tence") == [])
        #expect(splitter.consume(". ") == ["This is a sentence."])
    }

    // MARK: - flushRemainder

    @Test func flushReturnsUnterminatedTrailingText() {
        let splitter = SentenceSplitter()
        _ = splitter.consume("First. ")
        _ = splitter.consume("Second sentence without terminator")
        #expect(splitter.flushRemainder() == "Second sentence without terminator")
    }

    @Test func flushReturnsNilWhenBufferIsEmpty() {
        let splitter = SentenceSplitter()
        _ = splitter.consume("Complete. ")
        #expect(splitter.flushRemainder() == nil)
    }

    @Test func flushReturnsNilForWhitespaceOnlyRemainder() {
        let splitter = SentenceSplitter()
        _ = splitter.consume("Done.  \n  ")
        // The trailing whitespace after "Done." was already consumed as
        // part of the boundary — buffer should be empty.
        #expect(splitter.flushRemainder() == nil)
    }

    // MARK: - emittedSentences ordering

    @Test func emittedSentencesPreservesAllInOrder() {
        let splitter = SentenceSplitter()
        _ = splitter.consume("One. ")
        _ = splitter.consume("Two? ")
        _ = splitter.consume("Three!")
        _ = splitter.flushRemainder()
        #expect(splitter.emittedSentences == ["One.", "Two?", "Three!"])
    }

    // MARK: - reset

    @Test func resetClearsBufferAndHistory() {
        let splitter = SentenceSplitter()
        _ = splitter.consume("Some text. ")
        splitter.reset()
        #expect(splitter.emittedSentences == [])
        #expect(splitter.flushRemainder() == nil)
    }

    // MARK: - Edge cases

    @Test func multipleTrailingTerminatorsCollapse() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("Really?! What. ")
        // Three terminators in two sentences. First two ?! are eaten as
        // part of "Really?!" because the splitter only looks for
        // terminator-then-whitespace; ?! has no whitespace between them
        // so it stays glued.
        #expect(emitted == ["Really?!", "What."])
    }

    @Test func newlineActsAsBoundaryWhitespace() {
        let splitter = SentenceSplitter()
        let emitted = splitter.consume("First sentence.\nSecond sentence.\n")
        #expect(emitted == ["First sentence.", "Second sentence."])
    }
}
