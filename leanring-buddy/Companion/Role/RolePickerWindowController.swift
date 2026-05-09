//
//  RolePickerWindowController.swift
//  leanring-buddy
//
//  AppKit shell for `RolePickerView`. Presents a modal window on first
//  launch when `RoleManager.needsRoleSelection` is true, watches the
//  manager for a non-nil role, and self-closes once the user picks.
//
//  Lives separately from MenuBarPanelManager because the picker MUST
//  appear before the panel exists — Mom's Mac needs a role before any
//  role-aware UI gating runs.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class RolePickerWindowController: NSObject, NSWindowDelegate {

    private let roleManager: RoleManager
    private var hostedWindow: NSWindow?
    private var roleSubscription: AnyCancellable?

    /// Called once a role is persisted. App delegate uses this to
    /// continue the normal launch flow (show menu bar panel, etc.).
    private let onRoleSelected: () -> Void

    init(roleManager: RoleManager, onRoleSelected: @escaping () -> Void) {
        self.roleManager = roleManager
        self.onRoleSelected = onRoleSelected
        super.init()
    }

    /// Builds and presents the picker. Idempotent — safe to call from
    /// `applicationDidFinishLaunching` even if a role is already set
    /// (returns immediately as a no-op).
    func presentIfNeeded() {
        guard roleManager.needsRoleSelection else { return }
        if hostedWindow != nil { return }
        buildAndShowWindow()
        observeRoleSelection()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // If the user closed the window without picking, the app is
        // unusable. Re-present after a tick so they have to choose;
        // we don't accept "I'd rather not" as an answer here.
        Task { @MainActor in
            if roleManager.needsRoleSelection {
                hostedWindow = nil
                presentIfNeeded()
            }
        }
    }

    // MARK: - Private

    private func buildAndShowWindow() {
        let pickerView = RolePickerView(roleManager: roleManager)
        let hostingView = NSHostingView(rootView: pickerView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Clicky"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.hostedWindow = window
    }

    private func observeRoleSelection() {
        roleSubscription = roleManager.$currentRole
            .compactMap { $0 }
            .first()
            .sink { [weak self] _ in
                self?.handleRoleSelected()
            }
    }

    private func handleRoleSelected() {
        roleSubscription = nil
        hostedWindow?.delegate = nil // prevent willClose re-presentation
        hostedWindow?.close()
        hostedWindow = nil
        onRoleSelected()
    }
}
