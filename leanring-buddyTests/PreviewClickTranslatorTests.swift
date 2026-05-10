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
//  Output is now a 0..1 fraction — see CursorCommand wire schema.
//  Pixel/scale concerns moved to the senior side's flyOverlayCursor.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

struct PreviewClickTranslatorTests {

    @Test func clickAtImageCenterMapsToHalfFraction() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 512, y: 384),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 2560, height: 1600),
                seniorScreenIndex: 0
            )
        )
        #expect(abs(translation.xFraction - 0.5) < 0.000_001)
        #expect(abs(translation.yFraction - 0.5) < 0.000_001)
        #expect(translation.seniorScreenIndex == 0)
        #expect(translation.didLandInsideImage == true)
    }

    @Test func clickAtImageCornerMapsToZeroFraction() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 0, y: 0),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 2560, height: 1600),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.xFraction == 0)
        #expect(translation.yFraction == 0)
    }

    /// Phase 1 Test Plan row: "Retina 2x kid Mac → non-Retina 1x
    /// senior Mac, exact coordinate." Working in fractions removes the
    /// whole class of scale conversions — kid windows in points
    /// produce a fraction that's correct on any senior screen.
    @Test func fractionMappingIsScaleAgnostic() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 256, y: 192),
                imageDisplayedRectInWindowPoints: CGRect(x: 0, y: 0, width: 1024, height: 768),
                seniorScreenPixelSize: CGSize(width: 1920, height: 1080),
                seniorScreenIndex: 0
            )
        )
        // 256/1024 = 0.25, 192/768 = 0.25. Senior multiplies these by
        // ITS screen.frame width/height (in points), which is exactly
        // what we want regardless of senior backing scale.
        #expect(abs(translation.xFraction - 0.25) < 0.000_001)
        #expect(abs(translation.yFraction - 0.25) < 0.000_001)
    }

    /// Letterboxed image: the displayed rect is OFFSET inside the
    /// window. Click coordinates must subtract the offset before
    /// normalizing — otherwise a click at "the top-left of the image"
    /// gets a negative fraction and (after clamp) maps to the wrong
    /// corner.
    @Test func letterboxedImageOffsetIsRespected() {
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 100, y: 50),
                imageDisplayedRectInWindowPoints: CGRect(x: 100, y: 50, width: 800, height: 600),
                seniorScreenPixelSize: CGSize(width: 1600, height: 1200),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.xFraction == 0)
        #expect(translation.yFraction == 0)
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
        // (200-100)/800 = 0.125. Y is above image, clamps to 0.
        #expect(abs(translation.xFraction - 0.125) < 0.000_001)
        #expect(translation.yFraction == 0)
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
        let translation = PreviewClickTranslator.translate(
            PreviewClickTranslationInput(
                clickInWindowPoints: CGPoint(x: 0, y: 0),
                imageDisplayedRectInWindowPoints: CGRect.zero,
                seniorScreenPixelSize: CGSize(width: 1920, height: 1080),
                seniorScreenIndex: 0
            )
        )
        #expect(translation.xFraction.isFinite)
        #expect(translation.yFraction.isFinite)
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
        let rect = aspectFitRect(
            imageNativeSize: CGSize(width: 1600, height: 900),
            containerSize: CGSize(width: 1000, height: 1000)
        )
        #expect(rect.size.width == 1000)
        #expect(abs(rect.size.height - 562.5) < 0.001)
        #expect(rect.origin.x == 0)
        #expect(abs(rect.origin.y - (1000 - 562.5) / 2) < 0.001)
    }
}
