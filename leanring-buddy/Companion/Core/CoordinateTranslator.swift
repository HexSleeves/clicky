//
//  CoordinateTranslator.swift
//  leanring-buddy
//
//  Pure conversion from a screenshot-pixel coordinate (Claude's coordinate
//  space, top-left origin) to a global AppKit coordinate (bottom-left
//  origin) on the right display. Extracted from CompanionManager because
//  the math is the kind of thing that's easy to get wrong silently and
//  hard to verify by running the app — exactly what unit tests are for.
//

import CoreGraphics
import Foundation

enum CoordinateTranslator {

    /// Maps a screenshot-pixel coordinate to a global AppKit screen coordinate.
    ///
    /// - Parameters:
    ///   - screenshotPoint: Coordinate in the screenshot's pixel space.
    ///     Top-left origin, x increases rightward, y increases downward.
    ///   - screenshotSize: Pixel dimensions of the screenshot Claude saw.
    ///   - displaySize: Point dimensions of the target display.
    ///   - displayFrame: AppKit frame of the target display (bottom-left
    ///     origin, global coordinate space).
    /// - Returns: Global AppKit coordinate suitable for warping the cursor
    ///   to or driving an overlay flight animation.
    static func screenshotPointToAppKitGlobal(
        screenshotPoint: CGPoint,
        screenshotSize: CGSize,
        displaySize: CGSize,
        displayFrame: CGRect
    ) -> CGPoint {
        // Defensive clamp into the screenshot's pixel space — Claude
        // occasionally produces coordinates slightly past the image edge.
        let clampedX = max(0, min(screenshotPoint.x, screenshotSize.width))
        let clampedY = max(0, min(screenshotPoint.y, screenshotSize.height))

        // Screenshot pixels → display points (handles HiDPI scaling).
        let displayLocalX: CGFloat
        let displayLocalY: CGFloat
        if screenshotSize.width > 0 {
            displayLocalX = clampedX * (displaySize.width / screenshotSize.width)
        } else {
            displayLocalX = 0
        }
        if screenshotSize.height > 0 {
            displayLocalY = clampedY * (displaySize.height / screenshotSize.height)
        } else {
            displayLocalY = 0
        }

        // Top-left origin (screenshot) → bottom-left origin (AppKit).
        let appKitY = displaySize.height - displayLocalY

        // Display-local → global by offsetting with the display's frame origin.
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }
}
