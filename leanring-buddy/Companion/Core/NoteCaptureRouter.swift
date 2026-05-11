//
//  NoteCaptureRouter.swift
//  leanring-buddy
//
//  Pure intent detection for "remember that …" / "save note: …" phrases.
//  Returns the trailing memory text so CompanionManager can route it to
//  NotesStore instead of Claude. Orchestration (cancellation, TTS
//  confirmation, voice-state transitions) stays in CompanionManager —
//  this router only answers "is this a note-capture intent, and if so
//  what is the note text?".
//

import Foundation

enum NoteCaptureRouter {

    /// Trigger patterns matched at the start of the (case-insensitive)
    /// transcript. Each pattern ends by consuming any combination of
    /// whitespace, commas, colons, semicolons, periods, or dashes so the
    /// parser is robust against punctuation that AssemblyAI inserts
    /// between the trigger phrase and the body (e.g. "Remember that, my
    /// router password is on the fridge.").
    ///
    /// Ordered longer-prefix-first so "save note that X" matches before
    /// "save note X" — the regex engine returns the first match found in
    /// the list, not the longest.
    ///
    /// `separators` includes em-dash + en-dash as literal characters; we
    /// can't use Swift's `\u{2014}` escape in raw strings (which would be
    /// passed through verbatim and reject as invalid regex), so the
    /// characters appear directly in the source.
    private static let separators = "[\\s,:;.\\-—–]"

    private static let triggerPatterns: [String] = [
        "^\\s*please\\s+remember\\s+that\\b\(separators)*",
        "^\\s*please\\s+remember\\s+to\\b\(separators)*",
        "^\\s*remember\\s+that\\b\(separators)*",
        "^\\s*remember\\s+to\\b\(separators)*",
        "^\\s*remember\\s+this\\b\(separators)+",
        "^\\s*remember\\b\(separators)*[:,]\\s*",
        "^\\s*save\\s+a\\s+note\\s+that\\b\(separators)*",
        "^\\s*save\\s+a\\s+note\\b\(separators)*[:,]\\s*",
        "^\\s*save\\s+note\\s+that\\b\(separators)*",
        "^\\s*save\\s+note\\b\(separators)+",
        "^\\s*make\\s+a\\s+note\\s+that\\b\(separators)*",
        "^\\s*make\\s+a\\s+note\\b\(separators)*[:,]\\s*",
        "^\\s*note\\s+that\\b\(separators)*",
        "^\\s*note\\b\(separators)*[:,]\\s*"
    ]

    /// Compiled once at type init. `precondition` guards against silent
    /// failure: if any pattern fails to compile, the build crashes here
    /// at first use rather than producing an empty array that makes every
    /// call quietly return nil.
    private static let compiledPatterns: [NSRegularExpression] = {
        let compiled = triggerPatterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        precondition(
            compiled.count == triggerPatterns.count,
            "NoteCaptureRouter regex patterns failed to compile: \(triggerPatterns.count - compiled.count) of \(triggerPatterns.count) invalid"
        )
        return compiled
    }()

    /// Detects a leading note-capture phrase and returns the trailing memory
    /// text. Returns nil when the transcript is a normal question. Match is
    /// case-insensitive; trailing punctuation in the captured text is trimmed.
    static func parseNoteCaptureText(from transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        let fullRange = NSRange(trimmedTranscript.startIndex..., in: trimmedTranscript)
        for regex in compiledPatterns {
            guard let match = regex.firstMatch(in: trimmedTranscript, range: fullRange),
                  let matchRange = Range(match.range, in: trimmedTranscript) else {
                continue
            }
            let body = trimmedTranscript[matchRange.upperBound...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            return body.isEmpty ? nil : body
        }
        return nil
    }
}
