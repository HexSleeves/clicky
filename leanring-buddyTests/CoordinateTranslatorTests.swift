//
//  CoordinateTranslatorTests.swift
//  leanring-buddyTests
//
//  Coordinate-space conversion is the kind of bug that ships and you
//  don't notice until pointing lands a few pixels off. These tests pin
//  down the four moving parts: scaling, axis flip, screen offset, and
//  clamping at the edges.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

struct CoordinateTranslatorTests {

    // MARK: - 1:1 (no scaling, no offset)

    @Test func originMapsToTopLeftFlippedToBottomLeft() {
        // (0,0) top-left in a 100x100 screenshot on a 100x100 display
        // at frame origin (0,0) → AppKit (0, 100). Y flipped.
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 0, y: 0),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(result == CGPoint(x: 0, y: 100))
    }

    @Test func centerMapsToCenter() {
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 50, y: 50),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(result == CGPoint(x: 50, y: 50))
    }

    @Test func bottomRightMapsToBottomLeftOrigin() {
        // Bottom-right of screenshot is bottom-right of AppKit display,
        // which in AppKit (bottom-left origin) is (width, 0).
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 100, y: 100),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(result == CGPoint(x: 100, y: 0))
    }

    // MARK: - HiDPI scaling (screenshot pixels ≠ display points)

    @Test func retinaScreenshotScalesToPointSpace() {
        // 2880x1800 screenshot, 1440x900 display points (2× retina).
        // Click at screenshot (1440, 900) is the screen center → display (720, 450)
        // → AppKit Y flipped: 900 - 450 = 450.
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 1440, y: 900),
            screenshotSize: CGSize(width: 2880, height: 1800),
            displaySize: CGSize(width: 1440, height: 900),
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(result == CGPoint(x: 720, y: 450))
    }

    // MARK: - Multi-display offset

    @Test func secondaryDisplayAddsFrameOffset() {
        // Display 2 sits to the right of display 1 (at x = 1440).
        // Screenshot center for display 2 → AppKit (1440 + 720, 450).
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 720, y: 450),
            screenshotSize: CGSize(width: 1440, height: 900),
            displaySize: CGSize(width: 1440, height: 900),
            displayFrame: CGRect(x: 1440, y: 0, width: 1440, height: 900)
        )
        #expect(result == CGPoint(x: 1440 + 720, y: 450))
    }

    @Test func displayWithNegativeFrameOriginIsHandled() {
        // macOS lets a secondary display sit above the primary, which
        // produces a negative frame origin in some configurations.
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 0, y: 0),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 900, width: 100, height: 100)
        )
        #expect(result == CGPoint(x: 0, y: 1000))
    }

    // MARK: - Clamping

    @Test func pointPastRightEdgeIsClamped() {
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 500, y: 50),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        // x clamped to 100 (screenshot width), so display-local x = 100.
        #expect(result == CGPoint(x: 100, y: 50))
    }

    @Test func negativePointIsClamped() {
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: -10, y: -10),
            screenshotSize: CGSize(width: 100, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        // Both negative → clamped to 0; y-flip gives 100.
        #expect(result == CGPoint(x: 0, y: 100))
    }

    // MARK: - Degenerate inputs

    @Test func zeroScreenshotWidthDoesNotCrash() {
        // Defensive: never divide by zero. Should produce a consistent
        // output (point at display origin) rather than NaN/Inf.
        let result = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: CGPoint(x: 10, y: 10),
            screenshotSize: CGSize(width: 0, height: 100),
            displaySize: CGSize(width: 100, height: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(!result.x.isNaN && !result.x.isInfinite)
        #expect(!result.y.isNaN && !result.y.isInfinite)
    }
}
