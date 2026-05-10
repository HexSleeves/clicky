//
//  PreviewClickTranslator.swift
//  leanring-buddy
//
//  Pure click → senior-screen-fraction translator. Lives apart from
//  KidSidePreviewWindow / KidSidePreviewView so the math can be
//  unit-tested without spinning up an NSWindow.
//
//  Output is a 0..1 fraction of the target screen (top-left origin,
//  x rightward, y downward). Fractions sidestep every snap-vs-native-
//  vs-Retina conversion mismatch — neither side has to know the
//  other's pixel densities. CompanionManager.flyOverlayCursor
//  multiplies by senior `screen.frame` width/height (in points) and
//  applies the AppKit Y flip to land on the right pixel.
//
//  Three coordinate systems are still involved on the kid side:
//    1. Kid window points (SwiftUI / AppKit points)
//    2. Snap image displayed rect inside the window (a sub-rect of #1)
//    3. Senior screen 0..1 fraction (sent on the wire)
//
//  Earlier revisions wired the wire in pixel space and consistently
//  put the cursor at half the intended distance whenever the snap's
//  downscaled pixel dim differed from the senior's native pixel dim.
//  The fraction wire eliminates that whole class of bugs.
//

import CoreGraphics
import Foundation

/// Inputs the translator needs from the caller. All values are taken
/// at click time so retroactive resizes don't desync the math.
struct PreviewClickTranslationInput: Equatable {
    /// Where the kid clicked, in kid-window points (top-left origin
    /// inside the window's content view).
    let clickInWindowPoints: CGPoint

    /// The frame of the snap image inside the window, in kid-window
    /// points. This shrinks/grows as the kid resizes the preview
    /// window — the click translator uses ONLY this rect, not the
    /// window size, so letterbox margins are automatically excluded.
    let imageDisplayedRectInWindowPoints: CGRect

    /// Kept on the input shape for backwards compatibility with the
    /// pixel-era callers; ignored by the current fraction-based math.
    /// (See `aspectFitRect` callers in KidSidePreviewView for how the
    /// displayed rect is computed.)
    let seniorScreenPixelSize: CGSize

    /// Zero-indexed screen number on the senior's machine. Echoed into
    /// the output so CursorCommand.screenIndex stays in sync.
    let seniorScreenIndex: Int
}

struct PreviewClickTranslationOutput: Equatable {
    /// 0..1 fraction of the senior screen width, top-left origin.
    let xFraction: Double
    /// 0..1 fraction of the senior screen height.
    let yFraction: Double
    let seniorScreenIndex: Int

    /// True iff the click landed inside the displayed image. Clicks in
    /// the letterbox margin are clamped to the nearest image edge so
    /// the kid never sends a "click past the screen edge" command,
    /// but we surface the fact so the kid-side UI can render a
    /// "missed" affordance.
    let didLandInsideImage: Bool
}

enum PreviewClickTranslator {

    static func translate(_ input: PreviewClickTranslationInput) -> PreviewClickTranslationOutput {
        let imageRect = input.imageDisplayedRectInWindowPoints
        let clickPoint = input.clickInWindowPoints

        let didLandInsideImage = imageRect.contains(clickPoint)

        // Normalize relative to the displayed-image rect. Guard
        // against a zero-size image rect so we never divide by 0.
        let safeImageWidth = max(0.000_001, imageRect.width)
        let safeImageHeight = max(0.000_001, imageRect.height)

        let normalizedX = (clickPoint.x - imageRect.origin.x) / safeImageWidth
        let normalizedY = (clickPoint.y - imageRect.origin.y) / safeImageHeight

        // Clamp so an off-image click maps to the nearest edge.
        let clampedXFraction = min(max(Double(normalizedX), 0), 1)
        let clampedYFraction = min(max(Double(normalizedY), 0), 1)

        return PreviewClickTranslationOutput(
            xFraction: clampedXFraction,
            yFraction: clampedYFraction,
            seniorScreenIndex: input.seniorScreenIndex,
            didLandInsideImage: didLandInsideImage
        )
    }
}
