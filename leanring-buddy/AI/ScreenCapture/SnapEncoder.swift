//
//  SnapEncoder.swift
//  leanring-buddy
//
//  Phase 1 Lane A snap encoder. ScreenCaptureKit produces a CGImage at
//  the senior screen's native resolution; we downscale to 1440px on
//  the long edge and encode HEIC (eng review decision #8 —
//  hardware-accelerated, 50-80% smaller than PNG, no quality loss for
//  click-target work).
//
//  Falls back to JPEG when HEIC is unavailable (older macOS) so the
//  pipeline never blocks on encoder availability.
//
//  Pure functions only — no global state, no dependencies on
//  CompanionManager. Lets unit tests drive a constructed CGImage
//  through the math and the byte path without touching ScreenCaptureKit.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

enum SnapEncoder {

    /// Phase 1 design constant. Senior cursor work targets click
    /// accuracy, not motion fidelity, so 1440p long-edge is enough.
    static let defaultLongEdgePixels: Int = 1440

    /// Encoded snap envelope returned to the data-channel send path.
    struct EncodedSnap {
        enum Format: String, Equatable {
            case heic
            case jpeg
        }
        let bytes: Data
        let format: Format
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum EncodeError: Error, Equatable {
        case downscaleFailed
        case encoderUnavailable
        case finalizeFailed
    }

    /// Compute the resized dimensions that fit within `longEdgePixels`
    /// while preserving aspect ratio. Always returns integer pixels;
    /// rounds half-pixel dimensions down so the output is always
    /// strictly within the budget.
    static func targetSize(
        forSourcePixelWidth sourceWidth: Int,
        sourcePixelHeight sourceHeight: Int,
        longEdgePixels: Int = defaultLongEdgePixels
    ) -> (pixelWidth: Int, pixelHeight: Int) {
        let safeLongEdge = max(1, longEdgePixels)
        let safeSourceWidth = max(1, sourceWidth)
        let safeSourceHeight = max(1, sourceHeight)

        let longEdgeIsAlreadyShortEnough =
            max(safeSourceWidth, safeSourceHeight) <= safeLongEdge
        if longEdgeIsAlreadyShortEnough {
            return (safeSourceWidth, safeSourceHeight)
        }

        if safeSourceWidth >= safeSourceHeight {
            let scale = Double(safeLongEdge) / Double(safeSourceWidth)
            let scaledHeight = max(1, Int((Double(safeSourceHeight) * scale).rounded(.down)))
            return (safeLongEdge, scaledHeight)
        } else {
            let scale = Double(safeLongEdge) / Double(safeSourceHeight)
            let scaledWidth = max(1, Int((Double(safeSourceWidth) * scale).rounded(.down)))
            return (scaledWidth, safeLongEdge)
        }
    }

    /// Encode a CGImage as an `EncodedSnap`. Tries HEIC first; if the
    /// platform lacks an HEIC encoder, falls back to JPEG with the
    /// same dimensions.
    static func encodeSnap(
        from sourceImage: CGImage,
        longEdgePixels: Int = defaultLongEdgePixels,
        compressionQuality: CGFloat = 0.85
    ) throws -> EncodedSnap {
        let target = targetSize(
            forSourcePixelWidth: sourceImage.width,
            sourcePixelHeight: sourceImage.height,
            longEdgePixels: longEdgePixels
        )

        guard let downscaledImage = downscale(
            sourceImage,
            toPixelWidth: target.pixelWidth,
            pixelHeight: target.pixelHeight
        ) else {
            throw EncodeError.downscaleFailed
        }

        if let heicData = encode(
            downscaledImage,
            asTypeIdentifier: UTType.heic.identifier,
            compressionQuality: compressionQuality
        ) {
            return EncodedSnap(
                bytes: heicData,
                format: .heic,
                pixelWidth: target.pixelWidth,
                pixelHeight: target.pixelHeight
            )
        }

        if let jpegData = encode(
            downscaledImage,
            asTypeIdentifier: UTType.jpeg.identifier,
            compressionQuality: compressionQuality
        ) {
            return EncodedSnap(
                bytes: jpegData,
                format: .jpeg,
                pixelWidth: target.pixelWidth,
                pixelHeight: target.pixelHeight
            )
        }

        throw EncodeError.encoderUnavailable
    }

    /// Heuristic check on encoded bytes: HEIC files have an `ftyp`
    /// box at byte offset 4-7. Useful for tests that need to
    /// distinguish the format without dragging UTType into the
    /// assertion site.
    static func looksLikeHEIC(_ encodedBytes: Data) -> Bool {
        guard encodedBytes.count >= 12 else { return false }
        let ftypBytes = encodedBytes.subdata(in: 4..<8)
        return String(data: ftypBytes, encoding: .ascii) == "ftyp"
    }

    // MARK: - Private

    private static func downscale(
        _ sourceImage: CGImage,
        toPixelWidth targetWidth: Int,
        pixelHeight targetHeight: Int
    ) -> CGImage? {
        let colorSpace = sourceImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        bitmapContext.interpolationQuality = .high
        bitmapContext.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        return bitmapContext.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        asTypeIdentifier typeIdentifier: String,
        compressionQuality: CGFloat
    ) -> Data? {
        let outputData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            outputData,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(
            imageDestination,
            image,
            destinationProperties as CFDictionary
        )
        guard CGImageDestinationFinalize(imageDestination) else {
            return nil
        }
        return outputData as Data
    }
}
