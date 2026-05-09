//
//  PreviewClickTranslator.swift
//  leanring-buddy
//
//  Pure click→senior-pixel coordinate translator. Lives apart from
//  KidSidePreviewWindow / KidSidePreviewView so the multi-monitor +
//  DPI math can be unit-tested without spinning up an NSWindow or
//  hosting an SwiftUI runtime.
//
//  The kid clicks inside an NSWindow that displays a downscaled snap
//  of the senior's screen. We need to translate that click into the
//  senior's actual screen pixel coordinates so the existing
//  [POINT:x,y:label:screenN] cursor flight pipeline can fly to the
//  right spot. Three coordinate systems involved:
//
//    1. Kid window points (SwiftUI / AppKit points, Retina-agnostic)
//    2. Snap image displayed rect inside the window (a sub-rect of #1)
//    3. Senior screen pixels (the real thing the cursor flies on)
//
//  We DON'T care about the snap's pixel dimensions (they're a lossy
//  representation between #1 and #3). Normalizing to a 0..1 fraction
//  inside the displayed image rect, then multiplying by senior screen
//  pixel size, sidesteps the kid-Retina vs senior-Retina mismatch
//  entirely.
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

    /// Pixel dimensions of the senior screen the snap came from.
    /// Multi-monitor setups pass the dimensions of the screen named
    /// in `seniorScreenIndex`.
    let seniorScreenPixelSize: CGSize

    /// Zero-indexed screen number on the senior's machine. Echoed into
    /// the output so CursorCommand.screenIndex stays in sync.
    let seniorScreenIndex: Int
}

struct PreviewClickTranslationOutput: Equatable {
    let seniorScreenPixelX: Double
    let seniorScreenPixelY: Double
    let seniorScreenIndex: Int

    /// True iff the click landed inside the displayed image. Clicks in
    /// the letterbox margin are clamped to the nearest image pixel
    /// (so the kid never sends a "click past the screen edge"
    /// command), but we surface the fact so the kid-side UI can
    /// render a "missed" affordance.
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

        // Clamp so an off-image click maps to the nearest edge pixel.
        let clampedNormalizedX = min(max(Double(normalizedX), 0), 1)
        let clampedNormalizedY = min(max(Double(normalizedY), 0), 1)

        let seniorPixelX = clampedNormalizedX * Double(input.seniorScreenPixelSize.width)
        let seniorPixelY = clampedNormalizedY * Double(input.seniorScreenPixelSize.height)

        return PreviewClickTranslationOutput(
            seniorScreenPixelX: seniorPixelX,
            seniorScreenPixelY: seniorPixelY,
            seniorScreenIndex: input.seniorScreenIndex,
            didLandInsideImage: didLandInsideImage
        )
    }
}
