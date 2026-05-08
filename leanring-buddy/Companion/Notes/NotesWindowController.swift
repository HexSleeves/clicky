//
//  NotesWindowController.swift
//  leanring-buddy
//
//  Hosts the Notes view in a real, draggable NSWindow with traffic lights
//  so the user can move it around, keep it open while doing other things,
//  and resize it like any other macOS window. Independent from the menu
//  bar panel — closing the panel does NOT close Notes.
//

import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSObject {
    private weak var companionManager: CompanionManager?
    private var window: NSWindow?

    private let initialWidth: CGFloat = 360
    private let initialHeight: CGFloat = 440

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Brings the Notes window forward, creating it on first call.
    func show() {
        guard let companionManager else { return }

        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            // Activate so the window comes to the foreground even if the
            // user is in another app — they explicitly asked for Notes.
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let notesView = NotesPanelView(
            notesStore: companionManager.notesStore,
            companionManager: companionManager
        )

        let hostingView = NSHostingView(rootView: notesView)
        hostingView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)

        let notesWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        notesWindow.title = "Clicky Notes"
        // Hide the system title text — our SwiftUI header renders the title
        // and the count chip in a single row alongside the traffic lights.
        notesWindow.titleVisibility = .hidden
        notesWindow.titlebarAppearsTransparent = true
        notesWindow.isMovableByWindowBackground = true
        notesWindow.backgroundColor = NSColor(
            red: 0x10 / 255.0,
            green: 0x12 / 255.0,
            blue: 0x11 / 255.0,
            alpha: 1.0
        )
        notesWindow.minSize = NSSize(width: 320, height: 340)
        notesWindow.contentView = hostingView
        notesWindow.isReleasedWhenClosed = false
        // Restore position across launches under a unique autosave name.
        notesWindow.setFrameAutosaveName("ClickyNotesWindow")

        // Fall back to a sensible center position if no autosave exists yet.
        if notesWindow.frameAutosaveName.isEmpty || notesWindow.frame.origin == .zero {
            notesWindow.center()
        }

        // We listen for close so we can re-create cleanly next time the
        // user re-opens (covers edge cases where AppKit retires the window).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: notesWindow
        )

        window = notesWindow
        notesWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: closingWindow
        )
        window = nil
    }
}
