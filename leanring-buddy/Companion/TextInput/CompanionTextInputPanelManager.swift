//
//  CompanionTextInputPanelManager.swift
//  leanring-buddy
//
//  Floating text input panel for typed Clicky prompts.
//

import AppKit
import SwiftUI

private final class KeyableTextInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CompanionTextInputPanelManager: NSObject {
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    /// Watches mouse-moved events while the panel is visible so the chip
    /// can track the cursor (or Clicky's blue cursor) as it moves around.
    /// Two monitors needed: global for when our app isn't key (rare while
    /// typing), local for when it is.
    private var globalMouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?

    private let panelWidth: CGFloat = 300
    private let panelHeight: CGFloat = 50

    func show(
        onSubmit: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        if panel == nil {
            createPanel(onSubmit: onSubmit, onCancel: onCancel)
        }

        positionPanelNearCursor()

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor(onCancel: onCancel)
        installMouseFollowMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        removeClickOutsideMonitor()
        removeMouseFollowMonitor()
    }

    private func createPanel(
        onSubmit: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        let textInputView = CompanionTextInputPanelView(
            onSubmit: { [weak self] messageText in
                self?.hide()
                onSubmit(messageText)
            },
            onCancel: { [weak self] in
                self?.hide()
                onCancel()
            }
        )
        .frame(width: panelWidth, height: panelHeight)

        let hostingView = NSHostingView(rootView: textInputView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let textInputPanel = KeyableTextInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        textInputPanel.isFloatingPanel = true
        textInputPanel.level = .screenSaver
        textInputPanel.isOpaque = false
        textInputPanel.backgroundColor = .clear
        textInputPanel.hasShadow = false
        textInputPanel.hidesOnDeactivate = false
        textInputPanel.isExcludedFromWindowsMenu = true
        textInputPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        textInputPanel.isMovableByWindowBackground = false
        textInputPanel.titleVisibility = .hidden
        textInputPanel.titlebarAppearsTransparent = true
        // Required so the panel delivers mouseMoved events to our local
        // monitor while it's key (it's key whenever the user is typing).
        textInputPanel.acceptsMouseMovedEvents = true
        textInputPanel.contentView = hostingView

        panel = textInputPanel
    }

    private func positionPanelNearCursor() {
        guard let panel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        let preferredX = mouseLocation.x + 22
        let preferredY = mouseLocation.y - panelHeight - 16
        let clampedX = max(visibleFrame.minX + 12, min(preferredX, visibleFrame.maxX - panelWidth - 12))
        let clampedY = max(visibleFrame.minY + 12, min(preferredY, visibleFrame.maxY - panelHeight - 12))

        panel.setFrame(
            NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    private func installClickOutsideMonitor(onCancel: @escaping @MainActor () -> Void) {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if panel.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.hide()
                onCancel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    /// Repositions the panel near the cursor on every mouse move so the
    /// chip "follows" the user's pointer (and Clicky's blue cursor overlay
    /// since they share a position). Both global + local monitors needed
    /// because the panel takes key focus while typing.
    private func installMouseFollowMonitor() {
        removeMouseFollowMonitor()

        let handler: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.positionPanelNearCursor()
            }
        }

        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { _ in handler() }

        // Local monitor must return the event so the field still receives it.
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved]
        ) { event in
            handler()
            return event
        }
    }

    private func removeMouseFollowMonitor() {
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
            self.globalMouseMoveMonitor = nil
        }
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
            self.localMouseMoveMonitor = nil
        }
    }
}

private struct CompanionTextInputPanelView: View {
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool

    let onSubmit: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    /// Tight capsule chip: 270×34 sat inside a 300×50 panel so the shadow
    /// has breathing room. Designed to feel like a tooltip/companion bubble
    /// next to the cursor, not a dialog.
    private let chipWidth: CGFloat = 270
    private let chipHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            // Tiny cursor mark on the leading edge to tie this to Clicky's
            // identity. Same color as the overlay cursor.
            Image(systemName: "cursorarrow")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.overlayCursorBlue)

            TextField("ask clicky…", text: $messageText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isTextFieldFocused)
                .onSubmit(submitMessage)
                .overlay(IBeamCursorView())

            submitButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(width: chipWidth, height: chipHeight)
        .background(chipBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .onExitCommand { onCancel() }
    }

    private var submitButton: some View {
        Button(action: submitMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(
                    trimmedMessageText.isEmpty
                        ? DS.Colors.textTertiary
                        : DS.Colors.textOnAccent
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(
                            trimmedMessageText.isEmpty
                                ? DS.Colors.surface4
                                : DS.Colors.overlayCursorBlue
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            trimmedMessageText.isEmpty
                                ? DS.Colors.borderSubtle
                                : Color.white.opacity(0.18),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(trimmedMessageText.isEmpty)
        .pointerCursor(isEnabled: !trimmedMessageText.isEmpty)
        .animation(.easeOut(duration: 0.12), value: trimmedMessageText.isEmpty)
    }

    private var chipBackground: some View {
        Capsule(style: .continuous)
            .fill(DS.Colors.surface2)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.32), lineWidth: 0.8)
            )
            // Subtle inner top highlight — gives the chip a glassy lift.
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.20), radius: 10, x: 0, y: 0)
    }

    private var trimmedMessageText: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitMessage() {
        let submittedMessageText = trimmedMessageText
        guard !submittedMessageText.isEmpty else { return }
        onSubmit(submittedMessageText)
    }
}
