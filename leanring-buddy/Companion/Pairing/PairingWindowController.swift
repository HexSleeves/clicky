//
//  PairingWindowController.swift
//  leanring-buddy
//
//  Modal window that presents `PairingView`. Both kid + senior modes
//  go through this; the view branches on `RoleManager.currentRole`.
//

import AppKit
import SwiftUI

@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {

    private let roleManager: RoleManager
    private let pairingManager: PairingManager
    private let networkClient: PairingNetworkClient
    private var hostedWindow: NSWindow?

    init(
        roleManager: RoleManager,
        pairingManager: PairingManager,
        networkClient: PairingNetworkClient
    ) {
        self.roleManager = roleManager
        self.pairingManager = pairingManager
        self.networkClient = networkClient
        super.init()
    }

    func presentWindow() {
        if hostedWindow == nil {
            buildWindow()
        }
        hostedWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        hostedWindow?.close()
        hostedWindow = nil
    }

    private func buildWindow() {
        let pairingView = PairingView(
            roleManager: roleManager,
            pairingManager: pairingManager,
            networkClient: networkClient,
            onPairingCompleted: { [weak self] in
                // Senior-side: auto-close after a beat so the user
                // gets to read the "All set!" copy before the window
                // disappears. Kid side calls this synchronously from
                // the Done button — the delay is fine there too,
                // 1.5s feels intentional rather than instant.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.closeWindow()
                }
            }
        )
        let hostingView = NSHostingView(rootView: pairingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair Clicky"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.level = .floating
        self.hostedWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        hostedWindow = nil
    }
}
