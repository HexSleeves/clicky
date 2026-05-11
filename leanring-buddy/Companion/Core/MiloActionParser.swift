//
//  MiloActionParser.swift
//  leanring-buddy
//
//  Extracts the trailing `[ACTION:{...}]` JSON tag from a Claude
//  response. Sits alongside PointTagParser — the orchestrator tries
//  ACTION first, falls back to POINT for older prompt iterations or
//  responses where Claude reverted to the simpler form.
//
//  Why hand-written bracket scanning instead of a regex: the action
//  payload is JSON with `{` and `}` characters whose count is
//  arbitrary. A regex pinned to the last `]` would over-match. Scanning
//  the brace stack from `[ACTION:` to the matching `]` is unambiguous
//  and handles nested objects/arrays correctly.
//

import Foundation

/// Result of parsing a [ACTION:...] tag.
struct ActionParseResult: Equatable {
    /// Text with the [ACTION:...] tag stripped — what TTS speaks.
    let spokenText: String
    /// Parsed action, or nil if no [ACTION:...] tag was present or it
    /// failed to decode.
    let action: MiloAction?
}

enum MiloActionParser {

    /// Parses the trailing [ACTION:...] tag from `responseText`.
    /// Returns the spoken-text-only portion and the decoded action.
    /// Tolerant of trailing whitespace after the tag.
    static func parse(_ responseText: String) -> ActionParseResult {
        guard let tagRange = findActionTagRange(in: responseText) else {
            return ActionParseResult(spokenText: responseText, action: nil)
        }

        let jsonPayload = extractJSONPayload(from: responseText, in: tagRange)
        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonPayload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MiloAction.self, from: data) else {
            // Tag was present but JSON was malformed — strip the tag from
            // the spoken text anyway (the user shouldn't hear `[ACTION:{...}]`
            // read aloud) but no action fires.
            return ActionParseResult(spokenText: spokenText, action: nil)
        }

        return ActionParseResult(spokenText: spokenText, action: decoded)
    }

    /// Finds the range of `[ACTION:...]` at the end of the response.
    /// Returns the range covering `[ACTION:` through the matching `]`,
    /// or nil if no such tag exists at end of string (tolerant of
    /// trailing whitespace).
    private static func findActionTagRange(in text: String) -> Range<String.Index>? {
        // Trim trailing whitespace to find the real end of content.
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        // We work on the original `text` so the returned range is valid
        // for the original string. Locate `[ACTION:` from the end.
        guard let openRange = text.range(of: "[ACTION:", options: .backwards) else {
            return nil
        }

        // Walk forward from `[ACTION:` matching brackets until the
        // outer `]` that closes the tag. JSON braces are tracked
        // separately so the loop knows when a `]` is inside the JSON
        // versus closing the tag itself.
        var braceDepth = 0
        var bracketDepth = 1 // we're inside `[ACTION:`
        var inString = false
        var escapeNext = false
        var cursor = openRange.upperBound

        while cursor < text.endIndex {
            let char = text[cursor]

            if escapeNext {
                escapeNext = false
                cursor = text.index(after: cursor)
                continue
            }

            if inString {
                if char == "\\" {
                    escapeNext = true
                } else if char == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }

            switch char {
            case "\"": inString = true
            case "{": braceDepth += 1
            case "}": braceDepth -= 1
            case "[": bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth == 0 && braceDepth == 0 {
                    // Verify only whitespace follows — this is the tag
                    // close. If there's more non-whitespace, the tag
                    // isn't trailing; bail.
                    let afterTag = text.index(after: cursor)
                    let tail = text[afterTag...]
                    if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return openRange.lowerBound..<afterTag
                    }
                    return nil
                }
            default:
                break
            }
            cursor = text.index(after: cursor)
        }

        // Unclosed tag.
        return nil
    }

    /// Returns the JSON object substring between `[ACTION:` and the
    /// closing `]`. Caller supplies the full tag range; this trims the
    /// `[ACTION:` prefix and the trailing `]`.
    private static func extractJSONPayload(from text: String, in tagRange: Range<String.Index>) -> String {
        let jsonStart = text.index(tagRange.lowerBound, offsetBy: "[ACTION:".count)
        let jsonEnd = text.index(before: tagRange.upperBound) // drop closing `]`
        return String(text[jsonStart..<jsonEnd])
    }
}
