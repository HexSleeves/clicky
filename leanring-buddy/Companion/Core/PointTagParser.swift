//
//  PointTagParser.swift
//  leanring-buddy
//
//  Pure parsing of the [POINT:x,y:label:screenN] tag Claude embeds at the
//  end of responses, plus the keyword heuristic that decides whether a
//  transcript is a guided-action request. Extracted from CompanionManager
//  so the parser has a clear test seam.
//

import CoreGraphics
import Foundation

/// Result of parsing a [POINT:...] tag from a Claude response.
struct PointingParseResult: Equatable {
    /// The response text with the [POINT:...] tag removed — this is what gets spoken.
    let spokenText: String
    /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
    let coordinate: CGPoint?
    /// Short label describing the element (e.g. "run button"), or "none".
    let elementLabel: String?
    /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
    let screenNumber: Int?
}

enum PointTagParser {

    /// Matches [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
    /// at the end of a response. Optional whitespace after the tag is allowed.
    private static let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

    /// Parses a trailing [POINT:...] tag from Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parse(_ responseText: String) -> PointingParseResult {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return PointingParseResult(
                spokenText: responseText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // [POINT:none] — no coordinate groups captured.
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil
            )
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4,
           let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5,
           let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// Returns true if the transcript reads like the user wants Milo to
    /// take a guided click action (vs. a passive explanation).
    static func isGuidedActionRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        let guidedActionPhrases = [
            "click",
            "open",
            "select",
            "press",
            "choose",
            "tap",
            "where do i click",
            "show me where",
            "show where",
            "what do i click",
            "which button",
            "which menu"
        ]
        return guidedActionPhrases.contains { normalizedTranscript.contains($0) }
    }
}
