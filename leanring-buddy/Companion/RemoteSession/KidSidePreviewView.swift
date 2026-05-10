//
//  KidSidePreviewView.swift
//  leanring-buddy
//
//  SwiftUI content for the kid-side preview window. Renders the most
//  recently received HEIC snap (already decoded into an NSImage by
//  the controller) and emits click coordinates via the click
//  translator.
//
//  Visual chrome is intentionally minimal — kid-side surfaces use the
//  default `DS.*` palette, NOT `DS.Senior.*`. The kid is a
//  high-attention user who can tolerate dense UI.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

struct KidSidePreviewView: View {

    /// Most recently received snap, already decoded. nil while we
    /// haven't received the first frame yet.
    let currentSnapImage: NSImage?

    /// Senior screen pixel size for the screen this snap came from.
    /// Drives the click translator.
    let seniorScreenPixelSize: CGSize
    let seniorScreenIndex: Int

    /// Called when the kid clicks inside the preview. Coordinates are
    /// already in senior-screen pixel space.
    let onClickInSeniorPixelSpace: (PreviewClickTranslationOutput) -> Void

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let imageDisplayedRect: CGRect = currentSnapImage.map { image in
                aspectFitRect(
                    imageNativeSize: image.size,
                    containerSize: containerSize
                )
            } ?? .zero

            ZStack {
                Color.black

                if let currentSnapImage {
                    Image(nsImage: currentSnapImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Waiting for the first frame…")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            // Make the WHOLE container clickable (not just the image)
            // so a click in the letterbox margin still produces a
            // useful "missed" event upstream — without this the
            // gesture only fires on the Image's own bounds.
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.gestureCoordinateSpaceName)
            .gesture(
                // SwiftUI's default gesture coordinate space is the
                // gestured view's LOCAL bounds. Image's local bounds
                // are the aspect-fit rect — which means location
                // origin is the image's top-left, NOT the container's.
                // imageDisplayedRect is in container coords, so the
                // translator's offset subtraction was double-counting
                // the letterbox and snapping clicks to the top edge.
                // Pinning the gesture to a NAMED space matching the
                // ZStack's frame puts gesture.location into container
                // coords, and the translator's math is correct.
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(Self.gestureCoordinateSpaceName)
                )
                .onEnded { gestureValue in
                    let translation = PreviewClickTranslator.translate(
                        PreviewClickTranslationInput(
                            clickInWindowPoints: gestureValue.location,
                            imageDisplayedRectInWindowPoints: imageDisplayedRect,
                            seniorScreenPixelSize: seniorScreenPixelSize,
                            seniorScreenIndex: seniorScreenIndex
                        )
                    )
                    onClickInSeniorPixelSpace(translation)
                }
            )
        }
    }

    private static let gestureCoordinateSpaceName = "kid-preview-container"
}

/// Pure helper used by both the view and its tests. Computes the
/// `.scaledToFit` rect (letterboxed if needed) for an image of
/// `imageNativeSize` rendered into a container of `containerSize`.
func aspectFitRect(imageNativeSize: CGSize, containerSize: CGSize) -> CGRect {
    let safeImageSize = CGSize(
        width: max(1, imageNativeSize.width),
        height: max(1, imageNativeSize.height)
    )
    let safeContainerSize = CGSize(
        width: max(1, containerSize.width),
        height: max(1, containerSize.height)
    )

    let imageAspect = safeImageSize.width / safeImageSize.height
    let containerAspect = safeContainerSize.width / safeContainerSize.height

    let displayedSize: CGSize
    if imageAspect >= containerAspect {
        // Image is wider than container — width-bound.
        let displayedWidth = safeContainerSize.width
        let displayedHeight = displayedWidth / imageAspect
        displayedSize = CGSize(width: displayedWidth, height: displayedHeight)
    } else {
        // Container is wider than image — height-bound.
        let displayedHeight = safeContainerSize.height
        let displayedWidth = displayedHeight * imageAspect
        displayedSize = CGSize(width: displayedWidth, height: displayedHeight)
    }

    let displayedOrigin = CGPoint(
        x: (safeContainerSize.width - displayedSize.width) / 2,
        y: (safeContainerSize.height - displayedSize.height) / 2
    )
    return CGRect(origin: displayedOrigin, size: displayedSize)
}
