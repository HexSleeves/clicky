//
//  AnalyticsConsentPromptView.swift
//  leanring-buddy
//
//  The card-style consent prompt shown after the onboarding video ends
//  and before the 40s demo interaction. Lives inside the cursor overlay
//  as a centered modal-feeling sheet — no system alert (system alerts
//  steal focus and close the panel, which we want to avoid).
//
//  Copy is intentionally short and concrete: lists *what* is captured
//  (events, version, model name) and *what isn't* (transcripts, screen
//  content, AI responses). Two buttons; no neutral default — answering
//  is what unblocks the demo.
//

import SwiftUI

struct AnalyticsConsentPromptView: View {

    let onGrant: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Help improve Milo")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Share anonymous usage data so I can see how Milo is being used and where it breaks.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    bullet(positive: true, text: "Counts of features used, app version, error codes")
                    bullet(positive: false, text: "Never: your voice, transcripts, screen contents, or AI responses")
                }
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                Button(action: onDeny) {
                    Text("No thanks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: onGrant) {
                    Text("Share data")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.surface2.opacity(0.95))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 14, x: 0, y: 4)
    }

    private func bullet(positive: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: positive ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(positive ? DS.Colors.textSecondary : DS.Colors.destructiveText)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
