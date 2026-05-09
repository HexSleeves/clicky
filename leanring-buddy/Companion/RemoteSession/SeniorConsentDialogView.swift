//
//  SeniorConsentDialogView.swift
//  leanring-buddy
//
//  "Jacob wants to help on your screen" modal. Phase 1 design spec:
//    - vibrancy background, 480pt × 320pt centered
//    - kid name in 40pt headline (or 36pt if it overflows)
//    - "wants to help on your screen" in 28pt body
//    - YES button: 60pt, full-width, accent.primary, ✓ glyph
//    - NO  button: 60pt, full-width, bordered, ✗ glyph
//    - reassurance footer: 18pt accent.calm
//    - NO timer-driven dismissal — Mom reads slowly
//    - 5-minute auto-cancel only, with a TTS warning at 4:30
//
//  Wired into RemoteSessionManager.handleConsent via the YES/NO
//  handlers; the auto-cancel timer maps to handleConsent(.timedOut).
//

import SwiftUI

struct SeniorConsentDialogView: View {

    let kidDisplayName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Senior.Geometry.readSpacing) {
            Text(kidDisplayName)
                .font(DS.Senior.Typography.headline)
                .foregroundColor(DS.Senior.Colors.foreground)
                .lineLimit(1)
                .minimumScaleFactor(
                    DS.Senior.Typography.headlineMinSize / DS.Senior.Typography.headlineSize
                )

            Text("wants to help on your screen")
                .font(DS.Senior.Typography.body)
                .foregroundColor(DS.Senior.Colors.foreground)

            Spacer().frame(height: DS.Senior.Geometry.touchSpacing)

            VStack(spacing: DS.Senior.Geometry.touchSpacing) {
                acceptButton
                declineButton
            }

            Text("You can stop sharing anytime.")
                .font(DS.Senior.Typography.hint)
                .foregroundColor(DS.Senior.Colors.accentCalm)
                .padding(.top, DS.Senior.Geometry.readSpacing)

            Spacer()
        }
        .padding(32)
        .frame(width: 480, height: 320)
        .background(DS.Senior.Colors.background)
    }

    @ViewBuilder
    private var acceptButton: some View {
        Button(action: onAccept) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(DS.Senior.Typography.body)
                Text("Yes, share my screen")
                    .font(DS.Senior.Typography.body.weight(.semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: DS.Senior.Geometry.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                    .fill(DS.Senior.Colors.accentPrimary)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var declineButton: some View {
        Button(action: onDecline) {
            HStack(spacing: 12) {
                Image(systemName: "xmark")
                    .font(DS.Senior.Typography.body)
                Text("No thanks")
                    .font(DS.Senior.Typography.body)
            }
            .foregroundColor(DS.Senior.Colors.foreground)
            .frame(maxWidth: .infinity, minHeight: DS.Senior.Geometry.buttonHeight)
            .background(DS.Senior.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                    .stroke(DS.Senior.Colors.foreground, lineWidth: DS.Senior.Geometry.hairlineWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
struct SeniorConsentDialogView_Previews: PreviewProvider {
    static var previews: some View {
        SeniorConsentDialogView(
            kidDisplayName: "Jacob",
            onAccept: {},
            onDecline: {}
        )
        .frame(width: 480, height: 320)
    }
}
#endif
