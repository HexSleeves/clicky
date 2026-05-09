//
//  SnapEncoderTests.swift
//  leanring-buddyTests
//
//  Phase 1 Test Plan: HEIC snap encode + 1440p long-edge downscale.
//  - dimension math is the bulk of the surface (cheap to test, easy
//    to regress). Real encoder bytes are exercised by a constructed
//    CGImage round-trip.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

struct SnapEncoderTests {

    // MARK: - Dimension math

    @Test func portraitImageScalesToLongEdge() {
        // 1080×1920 (portrait) → 810×1440. 1440 / 1920 = 0.75.
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 1080,
            sourcePixelHeight: 1920
        )
        #expect(target.pixelWidth == 810)
        #expect(target.pixelHeight == 1440)
    }

    @Test func landscapeImageScalesToLongEdge() {
        // 3000×2000 (landscape) → 1440×960. 1440 / 3000 = 0.48.
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 3000,
            sourcePixelHeight: 2000
        )
        #expect(target.pixelWidth == 1440)
        #expect(target.pixelHeight == 960)
    }

    @Test func smallImagePassesThroughUnchanged() {
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 800,
            sourcePixelHeight: 600
        )
        #expect(target.pixelWidth == 800)
        #expect(target.pixelHeight == 600)
    }

    @Test func squareImageMapsBothEdgesToLongEdge() {
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 4000,
            sourcePixelHeight: 4000
        )
        #expect(target.pixelWidth == 1440)
        #expect(target.pixelHeight == 1440)
    }

    @Test func zeroSizeInputClampsToOnePixel() {
        // Defensive — never produce a 0-width / 0-height target
        // because CGImageDestination chokes on it.
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 0,
            sourcePixelHeight: 0
        )
        #expect(target.pixelWidth >= 1)
        #expect(target.pixelHeight >= 1)
    }

    @Test func customLongEdgeBudgetIsRespected() {
        // 3840x2160 down to 720p long edge → 720x405.
        let target = SnapEncoder.targetSize(
            forSourcePixelWidth: 3840,
            sourcePixelHeight: 2160,
            longEdgePixels: 720
        )
        #expect(target.pixelWidth == 720)
        #expect(target.pixelHeight == 405)
    }

    // MARK: - Real encoder round-trip

    /// Encodes a small constructed CGImage through SnapEncoder and
    /// asserts the output is non-empty and either HEIC (preferred)
    /// or JPEG (fallback). Catches the obvious "nothing got
    /// encoded" regression without tying tests to a specific
    /// encoder version.
    @Test func encodingRoundTripProducesUsableBytes() throws {
        let constructedImage = makeSolidColorCGImage(
            pixelWidth: 320,
            pixelHeight: 240,
            red: 0.2,
            green: 0.4,
            blue: 0.7
        )

        let encodedSnap = try SnapEncoder.encodeSnap(from: constructedImage)

        #expect(encodedSnap.bytes.count > 0)
        #expect(encodedSnap.pixelWidth == 320)
        #expect(encodedSnap.pixelHeight == 240)

        // We don't pin to .heic — older macOS may legitimately fall
        // back. We DO assert byte-level correctness for whichever
        // format won.
        switch encodedSnap.format {
        case .heic:
            #expect(SnapEncoder.looksLikeHEIC(encodedSnap.bytes) == true)
        case .jpeg:
            // JPEGs start with FF D8 FF.
            let header = encodedSnap.bytes.prefix(3)
            #expect(header[0] == 0xFF)
            #expect(header[1] == 0xD8)
            #expect(header[2] == 0xFF)
        }
    }

    @Test func encodingDownscalesLargeImages() throws {
        let constructedImage = makeSolidColorCGImage(
            pixelWidth: 2880,
            pixelHeight: 1800,
            red: 1,
            green: 0,
            blue: 0
        )

        let encodedSnap = try SnapEncoder.encodeSnap(from: constructedImage)

        // 2880x1800 → 1440x900 (long edge 1440).
        #expect(encodedSnap.pixelWidth == 1440)
        #expect(encodedSnap.pixelHeight == 900)
    }

    // MARK: - Helpers

    private func makeSolidColorCGImage(
        pixelWidth: Int,
        pixelHeight: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        bitmapContext.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return bitmapContext.makeImage()!
    }
}
