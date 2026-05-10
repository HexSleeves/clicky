//
//  CompanionTextInputPanelManager.swift
//  leanring-buddy
//
//  Floating text input panel for typed Milo prompts.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class KeyableTextInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CompanionTextInputPanelManager: NSObject {
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    /// Watches mouse-moved events while the panel is visible so the chip
    /// can track the cursor (or Milo's blue cursor) as it moves around.
    /// Two monitors needed: global for when our app isn't key (rare while
    /// typing), local for when it is.
    private var globalMouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?

    private let panelWidth: CGFloat = 360
    private let panelHeight: CGFloat = 54

    func show(
        companionManager: CompanionManager,
        onSubmit: @escaping @MainActor (String, [Data]) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        if panel == nil {
            createPanel(
                companionManager: companionManager,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
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
        companionManager: CompanionManager,
        onSubmit: @escaping @MainActor (String, [Data]) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        let textInputView = CompanionTextInputPanelView(
            companionManager: companionManager,
            onSubmit: { [weak self] messageText, attachmentData in
                self?.hide()
                onSubmit(messageText, attachmentData)
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
    /// chip "follows" the user's pointer (and Milo's blue cursor overlay
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
    @ObservedObject var companionManager: CompanionManager

    @State private var messageText: String = ""
    @State private var attachmentData: [Data] = []
    @FocusState private var isTextFieldFocused: Bool

    let onSubmit: @MainActor (String, [Data]) -> Void
    let onCancel: @MainActor () -> Void

    /// Pill chip is the dominant element. Width fills the 360pt panel; height
    /// matches the trio of trailing buttons (paperclip / submit / close).
    private let chipHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                "type a question…",
                text: $messageText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .focused($isTextFieldFocused)
                .onSubmit(submitMessage)
                .overlay(IBeamCursorView())

            paperclipButton
            submitButton
            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: chipHeight)
        .frame(maxWidth: .infinity)
        .background(chipBackground)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .onExitCommand { onCancel() }
    }

    // MARK: - Trailing Buttons

    private var paperclipButton: some View {
        Button(action: presentImageAttachmentPicker) {
            ZStack {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.9))
                    .frame(width: 26, height: 26)

                if !attachmentData.isEmpty {
                    Text("\(attachmentData.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(companionManager.selectedCursorColor.displayColor)
                        .padding(3)
                        .background(
                            Circle()
                                .fill(Color.white)
                        )
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Attach image")
    }

    private var submitButton: some View {
        Button(action: submitMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(
                    canSubmit
                        ? companionManager.selectedCursorColor.displayColor
                        : Color.white.opacity(0.4)
                )
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(canSubmit ? 0.95 : 0.5))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .pointerCursor(isEnabled: canSubmit)
        .animation(.easeOut(duration: 0.12), value: canSubmit)
        .accessibilityLabel("Send")
    }

    private var closeButton: some View {
        Button(action: { onCancel() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.white.opacity(0.85))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Close")
    }

    private var chipBackground: some View {
        Capsule(style: .continuous)
            .fill(companionManager.selectedCursorColor.displayColor)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
            )
            // Inner glassy top highlight so the pill reads with depth.
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 14, x: 0, y: 6)
            .shadow(color: companionManager.selectedCursorColor.glowColor.opacity(0.35), radius: 12, x: 0, y: 0)
    }

    // MARK: - Submission / Attachments

    private var canSubmit: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachmentData.isEmpty
    }

    private func submitMessage() {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        // We allow attachment-only submissions ("look at this") so the user
        // can lean entirely on the screenshot pipeline if they want.
        guard !trimmedMessageText.isEmpty || !attachmentData.isEmpty else { return }
        onSubmit(trimmedMessageText, attachmentData)
    }

    /// Opens the standard macOS file picker filtered to images. Each picked
    /// file is read as `Data` and stashed in `attachmentData` until the
    /// user submits.
    private func presentImageAttachmentPicker() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Attach images"

        // begin(completionHandler:) returns control immediately so the
        // input chip stays focused while the picker is up.
        openPanel.begin { [weak openPanel] modalResponse in
            guard modalResponse == .OK, let openPanel else { return }
            let pickedFileURLs = openPanel.urls

            Task { @MainActor in
                for fileURL in pickedFileURLs {
                    if let fileData = try? Data(contentsOf: fileURL) {
                        attachmentData.append(fileData)
                    }
                }
                isTextFieldFocused = true
            }
        }
    }
}
