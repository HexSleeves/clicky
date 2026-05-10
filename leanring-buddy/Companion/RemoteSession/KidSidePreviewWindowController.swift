//
//  KidSidePreviewWindowController.swift
//  leanring-buddy
//
//  Floating NSWindow on the kid's Mac that hosts the
//  KidSidePreviewView. Lives in its own file (not bolted into
//  OverlayWindow.swift — see eng review's minor finding that the
//  881-line overlay should not absorb the kid-side preview).
//
//  Position is remembered across launches via UserDefaults; the
//  default placement is centered on the kid's main screen. The
//  controller takes a callback so RemoteSessionManager (the owner)
//  receives translated click coordinates and turns them into
//  CursorCommand wire messages.
//

import AppKit
import SwiftUI

@MainActor
final class KidSidePreviewWindowController: NSObject {

    private static let preferredOriginXKey = "kidPreviewWindowOriginX"
    private static let preferredOriginYKey = "kidPreviewWindowOriginY"
    private static let preferredSizeWidthKey = "kidPreviewWindowSizeWidth"
    private static let preferredSizeHeightKey = "kidPreviewWindowSizeHeight"

    private var hostedWindow: NSWindow?
    private var hostingView: NSHostingView<KidSidePreviewView>?

    /// Active senior screen pixel size + index. Refreshed when a new
    /// snap arrives in case the senior switched monitors.
    private var seniorScreenPixelSize: CGSize = CGSize(width: 1, height: 1)
    private var seniorScreenIndex: Int = 0

    private var currentSnapImage: NSImage?

    /// Invoked when the kid clicks inside the preview. Translated
    /// coordinates are already in senior-screen pixel space.
    var onClickInSeniorPixelSpace: ((PreviewClickTranslationOutput) -> Void)?

    func showWindow() {
        if hostedWindow == nil {
            buildWindow()
        }
        hostedWindow?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        hostedWindow?.orderOut(nil)
    }

    /// Convenience hook for the wire path: takes a SnapDelivery wire
    /// payload, base64-decodes the bytes, and renders. Drops malformed
    /// payloads silently rather than throwing — the data channel is
    /// expected to flush junk every now and then.
    func renderSnapDelivery(_ snapDelivery: SnapDelivery) {
        guard let encodedBytes = Data(base64Encoded: snapDelivery.bytesBase64) else {
            return
        }
        renderSnap(
            encodedBytes: encodedBytes,
            seniorScreenPixelSize: CGSize(
                width: CGFloat(snapDelivery.pixelWidth),
                height: CGFloat(snapDelivery.pixelHeight)
            ),
            seniorScreenIndex: snapDelivery.screenIndex
        )
    }

    /// Renders a freshly-arrived HEIC snap. Decoding happens on the
    /// main actor because NSImage(data:) is cheap and avoids a
    /// hand-off race with the SwiftUI rebuild.
    func renderSnap(
        encodedBytes: Data,
        seniorScreenPixelSize: CGSize,
        seniorScreenIndex: Int
    ) {
        let decodedImage = NSImage(data: encodedBytes)
        self.currentSnapImage = decodedImage
        self.seniorScreenPixelSize = seniorScreenPixelSize
        self.seniorScreenIndex = seniorScreenIndex
        rebuildHostedView()
    }

    // MARK: - Window setup

    private func buildWindow() {
        let initialFrame = restoredFrameOrDefault()
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mom's Mac"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let initialView = KidSidePreviewView(
            currentSnapImage: currentSnapImage,
            seniorScreenPixelSize: seniorScreenPixelSize,
            seniorScreenIndex: seniorScreenIndex,
            onClickInSeniorPixelSpace: { [weak self] translation in
                self?.onClickInSeniorPixelSpace?(translation)
            }
        )
        let hostingView = NSHostingView(rootView: initialView)
        window.contentView = hostingView

        self.hostingView = hostingView
        self.hostedWindow = window
    }

    private func rebuildHostedView() {
        guard let hostingView else { return }
        hostingView.rootView = KidSidePreviewView(
            currentSnapImage: currentSnapImage,
            seniorScreenPixelSize: seniorScreenPixelSize,
            seniorScreenIndex: seniorScreenIndex,
            onClickInSeniorPixelSpace: { [weak self] translation in
                self?.onClickInSeniorPixelSpace?(translation)
            }
        )
    }

    private func restoredFrameOrDefault() -> NSRect {
        let userDefaults = UserDefaults.standard
        let storedOriginX = userDefaults.object(forKey: Self.preferredOriginXKey) as? Double
        let storedOriginY = userDefaults.object(forKey: Self.preferredOriginYKey) as? Double
        let storedWidth = userDefaults.object(forKey: Self.preferredSizeWidthKey) as? Double
        let storedHeight = userDefaults.object(forKey: Self.preferredSizeHeightKey) as? Double

        let hasStoredFrame = storedOriginX != nil
            && storedOriginY != nil
            && storedWidth != nil
            && storedHeight != nil

        if hasStoredFrame {
            return NSRect(
                x: storedOriginX!,
                y: storedOriginY!,
                width: storedWidth!,
                height: storedHeight!
            )
        }

        // Default: centered on main screen at 1024x768 (per design
        // "floating 1024x768 panel").
        let mainScreenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultSize = CGSize(width: 1024, height: 768)
        return NSRect(
            x: mainScreenFrame.midX - defaultSize.width / 2,
            y: mainScreenFrame.midY - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )
    }
}

extension KidSidePreviewWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        persistWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistWindowFrame()
    }

    private func persistWindowFrame() {
        guard let frame = hostedWindow?.frame else { return }
        let userDefaults = UserDefaults.standard
        userDefaults.set(Double(frame.origin.x), forKey: Self.preferredOriginXKey)
        userDefaults.set(Double(frame.origin.y), forKey: Self.preferredOriginYKey)
        userDefaults.set(Double(frame.size.width), forKey: Self.preferredSizeWidthKey)
        userDefaults.set(Double(frame.size.height), forKey: Self.preferredSizeHeightKey)
    }
}
