//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""

    /// Whether the cursor color picker grid is expanded. Collapsed by
    /// default — the tap target is a single swatch chip, and the grid
    /// blooms below it with a spring transition.
    @State private var isCursorColorPickerExpanded: Bool = false

    /// Owners (MenuBarPanelManager) wire these closures so the footer's
    /// Notes and gear buttons can spawn the right popovers anchored under
    /// their respective triggers. Default no-op makes preview rendering safe.
    var onShowNotesPanel: (() -> Void)? = nil
    var onShowSettingsPanel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            errorToastBanner
                .padding(.horizontal, 16)
                .padding(.top, companionManager.errorPresenter.current == nil ? 0 : 12)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                cursorColorPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                guidedActionBypassToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding,
               companionManager.allPermissionsGranted,
               companionManager.guidedActionProposal != nil {
                Spacer()
                    .frame(height: 12)

                guidedActionPreviewSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Error Toast

    @ViewBuilder
    private var errorToastBanner: some View {
        if let presentedError = companionManager.errorPresenter.current {
            ErrorToastView(
                error: presentedError,
                onRecover: {
                    if let suggestion = presentedError.recoverySuggestion {
                        RecoverySuggestionHandler.perform(
                            suggestion,
                            presenter: companionManager.errorPresenter
                        )
                    }
                },
                onDismiss: { companionManager.errorPresenter.dismiss() }
            )
            .animation(.easeOut(duration: 0.2), value: presentedError)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            // Logo mark — small cursor glyph in the user's chosen cursor color
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(companionManager.selectedCursorColor.displayColor.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(companionManager.selectedCursorColor.displayColor)
                    .offset(x: -1, y: -1)
            }

            Text("Milo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .tracking(-0.2)

            Spacer()

            statusBadge

            Button(action: {
                NotificationCenter.default.post(name: .miloDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        Circle()
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Pill-shaped status indicator. Background tinted by state so glance-readable.
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusDotColor.opacity(0.7), radius: 4)

            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusDotColor)
                .tracking(0.2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusDotColor.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(statusDotColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            shortcutHero
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Milo.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Milo.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Milo.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Milo will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shortcut Hero

    /// Two-row hero showing the push-to-talk and type-to-talk shortcuts as
    /// real keyboard chips. Displaces the previous single-line prose hint.
    /// Glance-readable; users no longer have to parse "Hold Control+Option".
    private var shortcutHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                kbdChipRow(symbols: ["control", "option"])
                shortcutCaption(action: "Talk", subtitle: "hold to record")
            }
            HStack(spacing: 10) {
                kbdChipRow(symbols: ["control", "command"])
                shortcutCaption(action: "Type", subtitle: "open text input")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func kbdChipRow(symbols: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                kbdChip(symbol: symbol)
                if index < symbols.count - 1 {
                    Text("+")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func kbdChip(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(DS.Colors.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(DS.Colors.borderStrong, lineWidth: 0.5)
            )
            // Subtle keycap top-edge highlight
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
            )
    }

    private func shortcutCaption(action: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(action)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Guided Action Preview

    @ViewBuilder
    private var guidedActionPreviewSection: some View {
        if let proposal = companionManager.guidedActionProposal {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(companionManager.selectedCursorColor.displayColor.opacity(0.16))
                            .frame(width: 28, height: 28)
                        Image(systemName: proposal.isMultiStep ? "wand.and.stars" : "cursorarrow.click")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(companionManager.selectedCursorColor.displayColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(proposal.instruction)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(guidedActionSubtitle(for: proposal))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)

                        if let action = proposal.multiStepAction {
                            guidedActionStepList(action: action)
                                .padding(.top, 4)
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    guidedActionButton(
                        label: proposal.isMultiStep ? "Run" : "Click",
                        icon: proposal.isMultiStep ? "play.fill" : "cursorarrow.click",
                        isPrimary: true,
                        action: { companionManager.performGuidedActionClick() }
                    )

                    if proposal.targetScreenLocation != nil {
                        guidedActionButton(
                            label: "Show target",
                            icon: "scope",
                            isPrimary: false,
                            action: { companionManager.replayGuidedActionTarget() }
                        )
                    }

                    guidedActionButton(
                        label: "Cancel",
                        icon: "xmark",
                        isPrimary: false,
                        action: { companionManager.cancelGuidedActionProposal() }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(companionManager.selectedCursorColor.displayColor.opacity(0.28), lineWidth: 0.7)
            )
        }
    }

    /// Short copy under the headline. Single-step still uses the original
    /// "Confirm before Milo clicks." phrasing; multi-step shows the verb
    /// count so the user knows whether they're about to fire a one-liner
    /// or a multi-step chain.
    private func guidedActionSubtitle(for proposal: GuidedActionProposal) -> String {
        if let action = proposal.multiStepAction {
            let count = action.steps.count
            return count == 1
                ? "1 step — confirm before Milo runs."
                : "\(count) steps — confirm before Milo runs."
        }
        return "Confirm before Milo clicks."
    }

    /// One-line-per-step preview using the same verb→human-readable
    /// mapping Claude itself would write. Limited to 4 visible lines so a
    /// long sequence doesn't blow up the panel.
    @ViewBuilder
    private func guidedActionStepList(action: MiloAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(action.steps.prefix(4).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(guidedActionStepDescription(step))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            if action.steps.count > 4 {
                Text("…and \(action.steps.count - 4) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    /// Renders one action step as a human-readable line. Kept conservative:
    /// the user is about to confirm the action, so the description must
    /// reflect what will actually happen.
    private func guidedActionStepDescription(_ step: MiloActionStep) -> String {
        switch step {
        case let .point(_, _, _, label):
            return "Point at \(label)"
        case let .click(_, _, _, label):
            return "Click \(label)"
        case let .type(text):
            let truncated = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "Type \u{201C}\(truncated)\u{201D}"
        case let .keypress(key, modifiers):
            let mods = modifiers.map(modifierGlyph).joined()
            let keyDisplay = key.count == 1 ? key.uppercased() : key
            return "Press \(mods)\(keyDisplay)"
        case let .scroll(_, _, _, deltaX, deltaY):
            let directionY = deltaY > 0 ? "down" : (deltaY < 0 ? "up" : nil)
            let directionX = deltaX > 0 ? "right" : (deltaX < 0 ? "left" : nil)
            let parts = [directionY, directionX].compactMap { $0 }
            return parts.isEmpty ? "Scroll" : "Scroll " + parts.joined(separator: "/")
        }
    }

    private func modifierGlyph(_ modifier: MiloActionStep.Modifier) -> String {
        switch modifier {
        case .cmd: return "\u{2318}"      // ⌘
        case .shift: return "\u{21E7}"    // ⇧
        case .option: return "\u{2325}"   // ⌥
        case .control: return "\u{2303}"  // ⌃
        case .fn: return "fn "
        }
    }

    private func guidedActionButton(
        label: String,
        icon: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isPrimary ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isPrimary ? DS.Colors.accent : DS.Colors.surface2)
            )
            .overlay(
                Capsule()
                    .stroke(isPrimary ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var guidedActionBypassToggleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(companionManager.isGuidedActionBypassEnabled ? DS.Colors.warning : DS.Colors.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-click actions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Skips the Click confirmation.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isGuidedActionBypassEnabled },
                set: { companionManager.setGuidedActionBypassEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.warning)
            .scaleEffect(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(
                    companionManager.isGuidedActionBypassEnabled
                    ? DS.Colors.warning.opacity(0.35)
                    : DS.Colors.borderSubtle,
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Milo Cursor Toggle

    private var showMiloCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Milo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isMiloCursorEnabled },
                set: { companionManager.setMiloCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Cursor Color Picker
    //
    // Two pieces: a swatch chip that's always visible and shows the
    // current color, plus an animated grid that blooms below the chip
    // when tapped. The expanded state is local to this view (not
    // persisted) since "which picker is open" isn't a user preference.

    private var cursorColorPickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cursor color")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .tracking(0.1)

                Spacer()

                cursorColorPickerTrigger
            }

            if isCursorColorPickerExpanded {
                cursorColorPickerGrid
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .topTrailing)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.92, anchor: .topTrailing)
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.74), value: isCursorColorPickerExpanded)
    }

    /// The collapsed-state chip — shows the current color, opens the grid on tap.
    private var cursorColorPickerTrigger: some View {
        let selected = companionManager.selectedCursorColor
        return Button(action: {
            isCursorColorPickerExpanded.toggle()
        }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(selected.displayColor)
                        .frame(width: 14, height: 14)
                        .shadow(color: selected.glowColor.opacity(0.7), radius: 4, x: 0, y: 0)
                }

                Text(selected.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Image(systemName: isCursorColorPickerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Cursor color: \(selected.displayName). Tap to change.")
    }

    /// 4×2 grid of color tiles. Stagger of `delay` makes the tiles pop in
    /// sequentially rather than as a single block — quick, cute,
    /// readable.
    private var cursorColorPickerGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(CursorColorOption.allCases.enumerated()), id: \.element.id) { index, option in
                cursorColorTile(option: option, gridIndex: index)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func cursorColorTile(option: CursorColorOption, gridIndex: Int) -> some View {
        let isSelected = companionManager.selectedCursorColor == option
        // Stagger delay tied to the option's position so tiles bloom in
        // a wave. Capped tight so the whole grid still feels snappy.
        let staggerDelay = Double(gridIndex) * 0.018
        return Button(action: {
            companionManager.setSelectedCursorColor(option)
            // Deliberately don't auto-collapse — keeping the grid open
            // lets users try multiple colors without re-tapping the chip.
            // They close it explicitly by tapping the chip again.
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(option.displayColor.opacity(isSelected ? 0.20 : 0.10))

                Triangle()
                    .fill(option.displayColor)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(20))
                    .shadow(color: option.glowColor.opacity(0.7), radius: isSelected ? 6 : 3, x: 0, y: 0)
                    .scaleEffect(isSelected ? 1.15 : 1.0)
            }
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        isSelected ? option.displayColor : DS.Colors.borderSubtle,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(option.displayName) cursor")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(.spring(response: 0.3, dampingFraction: 0.7).delay(staggerDelay),
                   value: isCursorColorPickerExpanded)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Footer

    /// Footer mirrors the new mockup: version on the left, Notes pill +
    /// gear icon on the right. The two buttons defer their actions to the
    /// hosting MenuBarPanelManager so popovers can be anchored correctly.
    private var footerSection: some View {
        HStack(spacing: 8) {
            Text(footerVersionString)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                notesFooterButton
                settingsFooterButton
            }
        }
    }

    private var notesFooterButton: some View {
        Button(action: {
            onShowNotesPanel?()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var settingsFooterButton: some View {
        Button(action: {
            onShowSettingsPanel?()
        }) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    Circle()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Settings")
    }

    /// "v1.0.14" style label sourced from Info.plist so it never goes stale.
    private var footerVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return shortVersion.isEmpty ? "" : "v\(shortVersion)"
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.background)

            // Subtle radial glow at the top tinted by the active cursor color
            // so the panel chrome quietly tracks the user's chosen identity.
            // Sits inside the panel mask so it never bleeds outside the rounded shape.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            companionManager.selectedCursorColor.displayColor.opacity(0.12),
                            companionManager.selectedCursorColor.displayColor.opacity(0.0)
                        ]),
                        center: .init(x: 0.2, y: -0.05),
                        startRadius: 0,
                        endRadius: 220
                    )
                )

            // Hairline inner stroke for crisp edge against the desktop wallpaper
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.30), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
