//
//  SettingsPopoverView.swift
//  leanring-buddy
//
//  Companion settings — the popover that opens off the gear icon in the
//  main panel footer. Matches the row-based mockup: header, plan card with
//  usage stats, "Upgrade to Milo Pro" CTA, eight settings rows, version
//  footer. Notes lives in its own draggable window so it does NOT appear
//  here.
//

import AppKit
import Combine
import SwiftUI

struct SettingsPopoverView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Closure called when the user picks an action that should also close
    /// the popover (e.g. opening a URL, quitting). MenuBarPanelManager
    /// wires this so it can dismiss its hosting NSPanel.
    var onRequestDismiss: () -> Void

    /// Drives the "resets in Xd Yh" line — refreshed every 60s while the
    /// popover is visible so the countdown stays accurate without a full
    /// view refresh on every render.
    @State private var nowForCountdown: Date = Date()

    private static let countdownRefresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    planCard
                    upgradeCTA
                    settingsRowsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }

            footer
        }
        .frame(width: 320, height: 560)
        .background(panelBackground)
        .onReceive(Self.countdownRefresh) { tick in
            nowForCountdown = tick
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Back chevron is decorative for now (no sub-nav). Keeping the
            // glyph so the header reads "settings page" rather than "popover"
            // and so the layout matches the mockup.
            Button(action: onRequestDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
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
            .accessibilityLabel("Back")

            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: onRequestDismiss) {
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
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    // MARK: - Plan Card

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, you're on our Free plan.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                // Use string interpolation for the cap so the copy stays in
                // sync with `CompanionManager.monthlyVoiceMessageCap`.
                Text("On the free plan you can talk to Milo \(CompanionManager.monthlyVoiceMessageCap) times a month and send \(CompanionManager.monthlyAgentMessageCap) agent messages. Your current usage resets in \(periodResetCountdownText).")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                planUsageColumn(
                    title: "Talk to Milo",
                    used: companionManager.monthlyVoiceMessageCount,
                    cap: CompanionManager.monthlyVoiceMessageCap
                )
                planUsageColumn(
                    title: "Agent Messages",
                    used: companionManager.monthlyAgentMessageCount,
                    cap: CompanionManager.monthlyAgentMessageCap
                )
            }
        }
    }

    private func planUsageColumn(title: String, used: Int, cap: Int) -> some View {
        // Clamp so progress can never visually overflow. The cap is a soft
        // display target, not a hard limit.
        let progress = cap > 0 ? min(1.0, Double(used) / Double(cap)) : 0

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("\(used) / \(cap) used")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .monospacedDigit()

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(DS.Colors.surface3)
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(companionManager.selectedCursorColor.displayColor)
                        .frame(width: max(2, geometry.size.width * progress), height: 3)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Upgrade CTA

    private var upgradeCTA: some View {
        // Milo doesn't have real billing yet — this row is intentionally
        // a no-op placeholder so the popover matches the mockup. Wire it
        // up to a real upgrade flow when paid plans ship.
        Button(action: { /* placeholder until billing ships */ }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.18))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Upgrade to Milo Pro")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Text("You'll be able to talk to Milo as much as you want and send up to 150 agent messages per month.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.overlayCursorRed)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .shadow(color: DS.Colors.overlayCursorRedGlow.opacity(0.35), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Upgrade to Milo Pro")
    }

    // MARK: - Settings Rows

    /// All eight rows from the mockup, stacked into individual rounded
    /// cards (matches the screenshot's "each row is its own pill" style).
    private var settingsRowsCard: some View {
        VStack(spacing: 8) {
            settingsRowCard(
                icon: "rectangle.on.rectangle",
                iconTint: DS.Colors.textSecondary,
                title: "Shortcuts",
                trailing: .chevron,
                action: { showShortcutsAlert() }
            )

            // Agent Folder gets a custom trailing pair (path label + chevron + refresh).
            agentFolderRow

            settingsRowCard(
                icon: "globe",
                iconTint: DS.Colors.textSecondary,
                title: "Connect Google Workspace",
                subtitle: "This lets Milo Agent interact with Google Docs, Calendar, Drive, and more.",
                trailing: .externalLink,
                action: { /* placeholder until Google Workspace integration ships */ }
            )

            settingsRowCard(
                icon: "lock.shield",
                iconTint: DS.Colors.textSecondary,
                title: "Agent Permissions",
                trailing: .chevron,
                action: { openSystemPrivacySettings() }
            )

            settingsRowCard(
                icon: "arrow.clockwise.circle",
                iconTint: DS.Colors.textSecondary,
                title: "Check for Updates...",
                trailing: .none,
                action: { /* Sparkle integration is currently stubbed in leanring_buddyApp */ }
            )

            settingsRowCard(
                icon: "bubble.left.and.bubble.right.fill",
                iconTint: DS.Colors.textSecondary,
                title: "DM Farza for bugs",
                trailing: .none,
                action: {
                    if let twitterURL = URL(string: "https://x.com/farzatv") {
                        NSWorkspace.shared.open(twitterURL)
                    }
                    onRequestDismiss()
                }
            )

            settingsRowCard(
                icon: "rectangle.portrait.and.arrow.right",
                iconTint: DS.Colors.textSecondary,
                title: "Log Out",
                trailing: .none,
                action: { /* placeholder — Milo has no auth yet */ }
            )

            settingsRowCard(
                icon: "power",
                iconTint: DS.Colors.destructiveText,
                title: "Quit Milo",
                titleTint: DS.Colors.destructiveText,
                trailing: .none,
                action: {
                    onRequestDismiss()
                    NSApp.terminate(nil)
                }
            )
        }
    }

    /// Agent Folder row mirrors the mockup: title, ~/Documents-style path
    /// chip, chevron, plus a separate refresh button outside the card.
    private var agentFolderRow: some View {
        HStack(spacing: 8) {
            Button(action: revealNotesFolderInFinder) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 18)

                    Text("Agent Folder")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)

                    Spacer(minLength: 0)

                    Text(notesFolderDisplayPath)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: revealNotesFolderInFinder) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Reveal in Finder")
        }
    }

    // MARK: - Settings Row Card

    private enum SettingsRowTrailing {
        case chevron
        case externalLink
        case none
    }

    /// Single-row card matching the mockup style: icon, title (+ optional
    /// subtitle), trailing accessory.
    private func settingsRowCard(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String? = nil,
        titleTint: Color = DS.Colors.textPrimary,
        trailing: SettingsRowTrailing,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconTint)
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(titleTint)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                switch trailing {
                case .chevron:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 2)
                case .externalLink:
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 2)
                case .none:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(versionLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    // MARK: - Background

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.background)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
    }

    // MARK: - Helpers

    private var versionLabel: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return shortVersion.isEmpty ? "" : "v\(shortVersion)"
    }

    /// Friendly "29d 5h" countdown until the rolling 30-day usage period
    /// resets. Uses `nowForCountdown` so the @State refresh propagates.
    private var periodResetCountdownText: String {
        let remainingSeconds = max(0, companionManager.monthlyUsagePeriodEnd.timeIntervalSince(nowForCountdown))
        let totalSeconds = Int(remainingSeconds)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        // Less than an hour — show minutes so the display never reads "0h".
        let minutes = max(1, (totalSeconds % 3_600) / 60)
        return "\(minutes)m"
    }

    /// Where Milo's notes JSON lives. Shown on the Agent Folder row so
    /// the user can tell at a glance which directory will open in Finder.
    private var notesFolderDisplayPath: String {
        let fileManager = FileManager.default
        guard let appSupportDir = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return "~/Library/Application Support/Milo" }

        let miloDir = appSupportDir.appendingPathComponent("Milo", isDirectory: true)
        // Replace the user's home prefix with `~` so the path stays short
        // and is readable across machines / screenshots.
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let miloPath = miloDir.path
        if miloPath.hasPrefix(homeURL.path) {
            return "~" + String(miloPath.dropFirst(homeURL.path.count))
        }
        return miloPath
    }

    private func revealNotesFolderInFinder() {
        let fileManager = FileManager.default
        guard let appSupportDir = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let miloDir = appSupportDir.appendingPathComponent("Milo", isDirectory: true)
        try? fileManager.createDirectory(at: miloDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([miloDir])
    }

    private func showShortcutsAlert() {
        // Lightweight info alert until a real Shortcuts sub-screen exists.
        let alert = NSAlert()
        alert.messageText = "Milo Shortcuts"
        alert.informativeText = "Push to talk: control + option\nText input: press control twice"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openSystemPrivacySettings() {
        // Drops the user straight into the Privacy & Security pane so they
        // can review or revoke Milo's accessibility / mic / screen access.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
        onRequestDismiss()
    }
}
