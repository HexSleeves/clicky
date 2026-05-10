//
//  SeniorConsentDialogWindowController.swift
//  leanring-buddy
//
//  Hosts SeniorConsentDialogView in a floating, centered NSWindow.
//  Owns the 5-minute auto-cancel timer (per design spec) so the view
//  stays a pure SwiftUI surface and doesn't have to know about
//  Date / Timer.
//
//  Lifecycle: presentForIncomingRequest(kidName:onAccept:onDecline:)
//  shows the window, starts the 4:30 TTS warning timer, and the 5:00
//  hard auto-cancel. Either button click resolves and tears the
//  window down.
//

import AppKit
import SwiftUI

@MainActor
final class SeniorConsentDialogWindowController: NSObject, NSWindowDelegate {

    /// Per design spec: 5-minute hard auto-cancel.
    static let autoCancelDelaySeconds: TimeInterval = 5 * 60
    /// Per design spec: 4:30 audible warning before the auto-cancel.
    static let autoCancelWarningOffsetSeconds: TimeInterval = 30

    private var hostedWindow: NSWindow?
    private var autoCancelWarningTask: Task<Void, Never>?
    private var autoCancelHardTask: Task<Void, Never>?
    private var pendingResolution: ((SeniorConsentResolution) -> Void)?

    enum SeniorConsentResolution: Equatable {
        case accepted
        case declined
        case timedOut
    }

    func presentForIncomingRequest(
        kidName: String,
        onAutoCancelWarning: (() -> Void)? = nil,
        onResolved: @escaping (SeniorConsentResolution) -> Void
    ) {
        // If a previous prompt is somehow still up, resolve it as a
        // decline so we don't end up with two consent windows on
        // top of each other.
        cleanupExistingPrompt(resolution: .declined)

        pendingResolution = onResolved
        buildAndShowWindow(kidName: kidName)
        scheduleAutoCancel(onAutoCancelWarning: onAutoCancelWarning)
    }

    func dismissCurrentPrompt() {
        cleanupExistingPrompt(resolution: .declined)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // If the user closed the window via the title bar instead of
        // clicking yes/no, treat it as a decline.
        cleanupExistingPrompt(resolution: .declined)
    }

    // MARK: - Private

    private func buildAndShowWindow(kidName: String) {
        let dialogView = SeniorConsentDialogView(
            kidDisplayName: kidName,
            onAccept: { [weak self] in
                self?.cleanupExistingPrompt(resolution: .accepted)
            },
            onDecline: { [weak self] in
                self?.cleanupExistingPrompt(resolution: .declined)
            }
        )
        let hostingView = NSHostingView(rootView: dialogView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Help request"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.hostedWindow = window
    }

    private func scheduleAutoCancel(onAutoCancelWarning: (() -> Void)?) {
        // Warning task doesn't need a self capture — it just fires the
        // caller-provided closure; the hard-cancel task below is the
        // one that needs to drive cleanupExistingPrompt.
        autoCancelWarningTask = Task {
            let warningDelaySeconds = Self.autoCancelDelaySeconds - Self.autoCancelWarningOffsetSeconds
            try? await Task.sleep(nanoseconds: UInt64(warningDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { onAutoCancelWarning?() }
        }
        autoCancelHardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoCancelDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.cleanupExistingPrompt(resolution: .timedOut)
            }
        }
    }

    private func cleanupExistingPrompt(resolution: SeniorConsentResolution) {
        autoCancelWarningTask?.cancel()
        autoCancelWarningTask = nil
        autoCancelHardTask?.cancel()
        autoCancelHardTask = nil

        let resolver = pendingResolution
        pendingResolution = nil

        hostedWindow?.delegate = nil
        hostedWindow?.close()
        hostedWindow = nil

        resolver?(resolution)
    }
}
