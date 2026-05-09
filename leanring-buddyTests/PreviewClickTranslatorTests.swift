//
//  PreviewClickTranslatorTests.swift
//  leanring-buddyTests
//
//  Phase 1 Test Plan rows:
//    - translateClick (DPI/scaling): Retina 2x kid Mac → non-Retina 1x
//      senior Mac, exact coordinate.
//    - Multi-monitor on senior side: snap per monitor, click maps to
//      correct screenN.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

struct PreviewClickTranslatorTests {

    @Test func clickAtImageCenterMapsToScreenCenter() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 512, y: 384),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 2560, height: 1600),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.seniorScreenPixelX == 1280)
        #expect(translation.seniorScreenPixelY == 800)
        #expect(translation.seniorScreenIndex == 0)
        #expect(translation.didLandInsideImage == true)
    }

    @Test func clickAtImageCornerMapsToScreenCorner() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 0, y: 0),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 2560, height: 1600),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.seniorScreenPixelX == 0)
        #expect(translation.seniorScreenPixelY == 0)
    }

    /// Phase 1 Test Plan row: "Retina 2x kid Mac → non-Retina 1x
    /// senior Mac, exact coordinate." The kid window is in points;
    /// the translator never sees a backing scale factor — it
    /// normalizes by the displayed-image rect. So Retina-vs-non
    /// disappears once we hit the math.
    @Test func retinaKidToNonRetinaSeniorMapsExactly() {
        // Kid window is 1024x768 points (Retina backing 2x = 2048x1536
        // physical pixels but the click event arrives in points).
        // Senior is 1920x1080 native pixels (non-Retina).
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 256, y: 192),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 1920, height: 1080),
                seniorScreenIndex: 0
            )
        )
        // 256/1024 = 0.25 → 0.25 * 1920 = 480.
        // 192/768 = 0.25  → 0.25 * 1080 = 270.
        #expect(translation.seniorScreenPixelX == 480)
        #expect(translation.seniorScreenPixelY == 270)
    }

    /// Letterboxed image: the displayed rect is OFFSET inside the
    /// window. Click coordinates must subtract the offset before
    /// normalizing — otherwise a click at "the top-left of the image"
    /// gets a negative normalized fraction and (after clamp) maps to
    /// the wrong corner.
    @Test func letterboxedImageOffsetIsRespected() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                // Click at the visual top-left of the displayed image,
                // not the window's (0,0).
                clickInWindowPoints: CGPoint(x: 100, y: 50),
                imageDisplayedRectInWindowPoints: CGRect(x: 100, y: 50, width: 800, height: 600),
                seniorScreenPixelSize: CGSize(width: 1600, height: 1200),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.seniorScreenPixelX == 0)
        #expect(translation.seniorScreenPixelY == 0)
    }

    @Test func clickInLetterboxMarginClampsToNearestEdge() {
        // Click in the empty letterbox above the image.
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 200, y: 10),
                imageDisplayedRectInWindowPoints: CGRect(x: 100, y: 50, width: 800, height: 600),
                seniorScreenPixelSize: CGSize(width: 1600, height: 1200),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.didLandInsideImage == false)
        // X normalizes to (200-100)/800 = 0.125 → 200 senior pixels.
        // Y is above image; clamps to 0.
        #expect(translation.seniorScreenPixelX == 200)
        #expect(translation.seniorScreenPixelY == 0)
    }

    /// Multi-monitor: senior has 2 displays; the snap envelope tells
    /// the kid which screenIndex it came from, the translator just
    /// echoes that back so CursorCommand.screenIndex stays in sync.
    @Test func screenIndexRoundTrips() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 100, y: 100),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 800, height: 600),
                seniorScreenPixelSize: CGSize(width: 1920, height: 1080),
                seniorScreenIndex: 1
            )
        )
        #expect(translation.seniorScreenIndex == 1)
    }

    @Test func zeroSizedImageRectDoesNotCrash() {
        // Defensive — pre-first-frame state where the displayed rect
        // is degenerate. Should clamp to (0, 0) without dividing by
        // zero.
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 0, y: 0),
                imageDisplayedRectInWindowPoints: CGRect.zero,
                seniorScreenPixelSize: CGSize(width: 1920, height: 1080),
                seniorScreenIndex: 0
            )
        )
        // The translator returns finite coordinates regardless.
        #expect(translation.seniorScreenPixelX.isFinite)
        #expect(translation.seniorScreenPixelY.isFinite)
    }

    // MARK: - aspectFitRect helper used by KidSidePreviewView

    @Test func aspectFitMatchesContainerWhenAspectsMatch() {
        let rect = aspectFitRect(
            imageNativeSize: CGSize(width: 1600, height: 900),
            containerSize: CGSize(width: 800, height: 450)
        )
        #expect(rect.origin == .zero)
        #expect(rect.size == CGSize(width: 800, height: 450))
    }

    @Test func aspectFitLetterboxesWideImageInSquareContainer() {
        // 16:9 image inside a 1:1 container letterboxes top + bottom.
        let rect = aspectFitRect(
            imageNativeSize: CGSize(width: 1600, height: 900),
            containerSize: CGSize(width: 1000, height: 1000)
        )
        // Width fills (1000), height shrinks to maintain 16:9 →
        // 1000 * 9/16 = 562.5
        #expect(rect.size.width == 1000)
        #expect(abs(rect.size.height - 562.5) < 0.001)
        #expect(rect.origin.x == 0)
        #expect(abs(rect.origin.y - (1000 - 562.5) / 2) < 0.001)
    }
}
