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
            ZStack {
                Color.black

                if let currentSnapImage {
                    // Compute the displayed-image rect inside our
                    // bounds for the click translator. SwiftUI's
                    // .scaledToFit centers the image; we mirror the
                    // same math so the translator sees exactly the
                    // rect we render.
                    let containerSize = proxy.size
                    let imageNativeSize = currentSnapImage.size
                    let imageDisplayedRect = aspectFitRect(
                        imageNativeSize: imageNativeSize,
                        containerSize: containerSize
                    )

                    Image(nsImage: currentSnapImage)
                        .resizable()
                        .scaledToFit()
                        .gesture(
                            DragGesture(minimumDistance: 0)
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
                } else {
                    Text("Waiting for the first frame…")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }
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
