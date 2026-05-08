//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    /// Settings popover anchored under the gear footer button.
    private var settingsPopoverPanel: NSPanel?
    private var settingsPopoverClickOutsideMonitor: Any?

    /// Notes lives in its own draggable, persistent NSWindow rather than a
    /// popover — closing the menu-bar panel does not close Notes.
    private let notesWindowController: NotesWindowController

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    /// Tall enough for the new cursor-color picker row plus the existing
    /// permissions/onboarding states. The panel wraps to fittingSize when
    /// shown, so this is just the initial frame.
    private let panelHeight: CGFloat = 460

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.notesWindowController = NotesWindowController(companionManager: companionManager)
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPanel()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        // Settings is a transient popover — close it whenever the main panel
        // goes away. The Notes window stays open by design (it's a real
        // standalone window the user might be referencing).
        hideSettingsPopover()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(
            companionManager: companionManager,
            onShowNotesPanel: { [weak self] in
                self?.notesWindowController.show()
            },
            onShowSettingsPanel: { [weak self] in
                self?.showSettingsPopover()
            }
        )
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Settings Popover

    /// Spawns the settings popover anchored next to the main companion panel.
    /// Notes lives in its own draggable NSWindow (see `notesWindowController`)
    /// so it survives panel dismissal.
    fileprivate func showSettingsPopover() {
        if settingsPopoverPanel != nil {
            hideSettingsPopover()
            return
        }

        let settingsView = SettingsPopoverView(
            companionManager: companionManager,
            onRequestDismiss: { [weak self] in
                self?.hideSettingsPopover()
            }
        )

        let popoverWidth: CGFloat = 320
        let popoverHeight: CGFloat = 560
        let popoverPanel = makePopoverPanel(
            rootView: AnyView(settingsView),
            size: CGSize(width: popoverWidth, height: popoverHeight)
        )

        positionPopover(popoverPanel)
        popoverPanel.makeKeyAndOrderFront(nil)
        popoverPanel.orderFrontRegardless()

        settingsPopoverPanel = popoverPanel
        installSettingsClickOutsideMonitor()
    }

    fileprivate func hideSettingsPopover() {
        settingsPopoverPanel?.orderOut(nil)
        settingsPopoverPanel = nil
        if let monitor = settingsPopoverClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            settingsPopoverClickOutsideMonitor = nil
        }
    }

    private func makePopoverPanel(rootView: AnyView, size: CGSize) -> NSPanel {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let popoverPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        popoverPanel.isFloatingPanel = true
        // Sit one level above the main panel so we never get hidden behind it.
        popoverPanel.level = .popUpMenu
        popoverPanel.isOpaque = false
        popoverPanel.backgroundColor = .clear
        popoverPanel.hasShadow = false
        popoverPanel.hidesOnDeactivate = false
        popoverPanel.isExcludedFromWindowsMenu = true
        popoverPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        popoverPanel.contentView = hostingView
        return popoverPanel
    }

    /// Anchors the popover to the trailing edge of the main companion panel
    /// with a small horizontal gap so it visually pairs with the gear button.
    private func positionPopover(_ popoverPanel: NSPanel) {
        guard let mainPanel = panel else { return }

        let popoverSize = popoverPanel.frame.size
        let mainFrame = mainPanel.frame
        let horizontalGap: CGFloat = 8

        let originX = mainFrame.maxX + horizontalGap
        let originY = mainFrame.maxY - popoverSize.height

        let activeScreen: NSScreen? = NSScreen.screens.first { screen in
            screen.frame.contains(NSPoint(x: mainFrame.midX, y: mainFrame.midY))
        } ?? NSScreen.main
        let visibleFrame: NSRect
        if let screen = activeScreen {
            visibleFrame = screen.visibleFrame
        } else {
            visibleFrame = NSRect(x: 0, y: 0, width: NSScreen.main?.frame.width ?? 0, height: NSScreen.main?.frame.height ?? 0)
        }

        let clampedX = max(visibleFrame.minX + 8, min(originX, visibleFrame.maxX - popoverSize.width - 8))
        let clampedY = max(visibleFrame.minY + 8, min(originY, visibleFrame.maxY - popoverSize.height - 8))

        popoverPanel.setFrame(
            NSRect(x: clampedX, y: clampedY, width: popoverSize.width, height: popoverSize.height),
            display: true
        )
    }

    private func installSettingsClickOutsideMonitor() {
        if let monitor = settingsPopoverClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }

        settingsPopoverClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let popoverPanel = self.settingsPopoverPanel,
                      popoverPanel.isVisible else { return }
                if popoverPanel.frame.contains(NSEvent.mouseLocation) { return }
                self.hideSettingsPopover()
            }
        }
    }
}
