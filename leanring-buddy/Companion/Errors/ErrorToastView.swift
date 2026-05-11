//
//  ErrorToastView.swift
//  leanring-buddy
//
//  The SwiftUI surface for a presented MiloError. Renders the userMessage
//  + optional recovery button + a manual dismiss. Designed for inline use
//  inside the panel and as a transient bubble inside the cursor overlay —
//  the visual treatment is the same; only the host is different.
//

import AppKit
import SwiftUI

struct ErrorToastView: View {
    let error: MiloError
    let onRecover: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.destructiveText)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(error.userMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if let suggestion = error.recoverySuggestion {
                    Button(action: onRecover) {
                        Text(suggestion.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.destructive.opacity(0.30))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.destructive.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.destructive.opacity(0.40), lineWidth: 0.5)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var iconName: String {
        switch error {
        case .missingPermission: return "lock.shield"
        case .budgetExhausted: return "hourglass"
        case .rateLimited: return "tortoise"
        case .appUpgradeRequired: return "arrow.up.circle"
        case .network: return "wifi.slash"
        case .screenshotFailed: return "eye.slash"
        case .transcriptionFailed, .ttsFailed: return "waveform.slash"
        case .providerDown, .providerDenied, .payloadTooLarge, .unknown:
            return "exclamationmark.triangle"
        }
    }
}
