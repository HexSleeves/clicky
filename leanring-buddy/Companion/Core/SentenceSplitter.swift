//
//  SentenceSplitter.swift
//  leanring-buddy
//
//  Incremental sentence detection over a streaming text source. Used to
//  chunk Claude's streaming response into TTS-able sentences so the first
//  sentence can begin playback while later sentences are still being
//  generated.
//
//  Strategy: aggressive split on `[.!?]` followed by whitespace.
//  Acceptable because the companion system prompt explicitly forbids
//  abbreviations (no "Dr.", "Mr.", "e.g."), so the classic
//  "split-on-period false positive" problem is by-design avoided.
//
//  Trailing `[POINT:...]` tags are recognized and held back from the
//  emitted text — the orchestrator strips and acts on them separately.
//

import Foundation

@MainActor
final class SentenceSplitter {

    /// Accumulated unflushed text that hasn't yet ended in a sentence
    /// terminator. Appended to on each `consume`; reset when a complete
    /// sentence is flushed; what remains at end-of-stream is the trailing
    /// fragment.
    private var buffer: String = ""

    /// Sentences already emitted, in order. Caller can replay these for
    /// debugging or as a transcript of what was queued for TTS.
    private(set) var emittedSentences: [String] = []

    /// Feeds a new chunk of streaming text. Returns the list of *new*
    /// sentences completed within this chunk (most calls return 0 or 1
    /// sentence; rarely more if a chunk crosses two boundaries).
    func consume(_ chunk: String) -> [String] {
        buffer.append(chunk)
        return drainCompleteSentences()
    }

    /// Drops any complete sentences from `buffer` and returns them in
    /// emission order. Stops at the first incomplete trailing fragment.
    private func drainCompleteSentences() -> [String] {
        var newlyEmitted: [String] = []

        while let endIndex = nextSentenceEnd(in: buffer) {
            let sentence = String(buffer[..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                emittedSentences.append(sentence)
                newlyEmitted.append(sentence)
            }
            buffer = String(buffer[endIndex...])
        }

        return newlyEmitted
    }

    /// Finds the index of the first character *after* a complete
    /// sentence's terminator + whitespace. Returns nil if no complete
    /// sentence exists yet in the buffer.
    ///
    /// Pattern: terminator `[.!?]` followed by one or more whitespace
    /// characters. The whitespace is consumed as part of the boundary
    /// so the next sentence starts with text.
    ///
    /// Suppresses splits inside a `[ACTION:{...}]` trailing tag — the JSON
    /// payload routinely contains sentence-terminator characters (e.g.
    /// `"text":"on my way!"`) that we don't want to flush to TTS as
    /// independent "sentences". Once `[ACTION:` appears we wait for the
    /// matching `]` before considering any further terminators.
    private func nextSentenceEnd(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var index = text.startIndex
        // Tag-suppression state: once we cross `[ACTION:` we treat the
        // entire JSON payload through the matching `]` as opaque so
        // sentence terminators inside the payload don't fire a flush.
        // String + brace + bracket tracking mirrors MiloActionParser so
        // a `]` inside a JSON string doesn't exit suppression early.
        var inActionTag = false
        var bracketDepth = 0
        var braceDepth = 0
        var inString = false
        var escapeNext = false

        while index < text.endIndex {
            // Detect "[ACTION:" prefix to enter tag-suppression mode.
            if !inActionTag && text[index] == "[" {
                let actionPrefix = "[ACTION:"
                if text.distance(from: index, to: text.endIndex) >= actionPrefix.count {
                    let prefixEnd = text.index(index, offsetBy: actionPrefix.count)
                    if text[index..<prefixEnd] == actionPrefix {
                        inActionTag = true
                        bracketDepth = 1
                        braceDepth = 0
                        inString = false
                        escapeNext = false
                        index = prefixEnd
                        continue
                    }
                }
            }

            if inActionTag {
                let char = text[index]
                if escapeNext {
                    escapeNext = false
                } else if inString {
                    if char == "\\" {
                        escapeNext = true
                    } else if char == "\"" {
                        inString = false
                    }
                } else {
                    switch char {
                    case "\"": inString = true
                    case "{": braceDepth += 1
                    case "}": braceDepth -= 1
                    case "[": bracketDepth += 1
                    case "]":
                        bracketDepth -= 1
                        if bracketDepth == 0 && braceDepth == 0 {
                            inActionTag = false
                        }
                    default:
                        break
                    }
                }
                index = text.index(after: index)
                continue
            }

            let char = text[index]
            if terminators.contains(char) {
                // Look ahead for whitespace — required so we don't split
                // mid-decimal or inside abbreviations a model might still
                // produce despite the prompt.
                let afterTerminator = text.index(after: index)
                if afterTerminator < text.endIndex,
                   text[afterTerminator].isWhitespace {
                    // Consume the whitespace too so the next sentence
                    // doesn't start with a leading space.
                    var consumeIndex = afterTerminator
                    while consumeIndex < text.endIndex,
                          text[consumeIndex].isWhitespace {
                        consumeIndex = text.index(after: consumeIndex)
                    }
                    return consumeIndex
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Returns whatever's left in the buffer at end-of-stream and
    /// clears it. The orchestrator should call this once the streaming
    /// source finishes so the last (possibly unterminated) sentence
    /// gets spoken.
    func flushRemainder() -> String? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !trimmed.isEmpty {
            emittedSentences.append(trimmed)
            return trimmed
        }
        return nil
    }

    /// Resets all state. Used when starting a new response.
    func reset() {
        buffer = ""
        emittedSentences = []
    }
}
