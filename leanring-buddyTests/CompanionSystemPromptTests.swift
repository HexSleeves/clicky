//
//  CompanionSystemPromptTests.swift
//  leanring-buddyTests
//
//  Verifies the prompt composer's notes-block splicing. The base prompt
//  itself is treated as a deliberately-tuned blob; we just check that
//  it's non-empty and the splicing rules behave.
//

import Testing
@testable import leanring_buddy

struct CompanionSystemPromptTests {

    @Test func basePromptIsNotEmpty() {
        #expect(!CompanionSystemPrompt.basePrompt.isEmpty)
    }

    @Test func buildWithNilNotesReturnsBasePromptUnchanged() {
        let composed = CompanionSystemPrompt.build(notesBlock: nil)
        #expect(composed == CompanionSystemPrompt.basePrompt)
    }

    @Test func buildWithEmptyNotesReturnsBasePromptUnchanged() {
        let composed = CompanionSystemPrompt.build(notesBlock: "")
        #expect(composed == CompanionSystemPrompt.basePrompt)
    }

    @Test func buildWithWhitespaceOnlyNotesReturnsBasePromptUnchanged() {
        // A notes block that's only whitespace shouldn't trick the composer
        // into appending a useless trailing blank section.
        let composed = CompanionSystemPrompt.build(notesBlock: "   \n  \n")
        #expect(composed == CompanionSystemPrompt.basePrompt)
    }

    @Test func buildWithNotesAppendsBlockSeparatedByBlankLine() {
        let notesBlock = "User notes:\n- prefers dark mode"
        let composed = CompanionSystemPrompt.build(notesBlock: notesBlock)

        #expect(composed.hasPrefix(CompanionSystemPrompt.basePrompt))
        #expect(composed.hasSuffix(notesBlock))
        #expect(composed.contains("\n\n" + notesBlock))
    }
}
