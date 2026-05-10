//
//  PairingView.swift
//  leanring-buddy
//
//  Phase 1 pairing UI. Branches on the current role:
//
//    - Kid:    "Get a code" button → renders the 6-digit code in
//              monospace once minted, with copy-to-clipboard +
//              regenerate. Includes the pairId so the senior can
//              confirm they're typing into the right session.
//    - Senior: 6 monospace digit boxes. Submit hits /pair/verify;
//              shows "X tries left" on mismatch, "All set!" on
//              success.
//
//  Both branches consume PairingManager + PairingNetworkClient via
//  composition. The window controller lives in
//  PairingWindowController.swift.
//

import AppKit
import SwiftUI

struct PairingView: View {

    @ObservedObject var roleManager: RoleManager
    @ObservedObject var pairingManager: PairingManager
    let networkClient: PairingNetworkClient
    let onPairingCompleted: () -> Void

    var body: some View {
        Group {
            switch roleManager.currentRole {
            case .kid:
                KidPairCodeView(
                    pairingManager: pairingManager,
                    networkClient: networkClient
                )
            case .senior, .none:
                SeniorPairCodeEntryView(
                    pairingManager: pairingManager,
                    networkClient: networkClient,
                    onPairingCompleted: onPairingCompleted
                )
            }
        }
        .frame(width: 720, height: 540)
        .background(DS.Senior.Colors.background)
    }
}

// MARK: - Kid side

private struct KidPairCodeView: View {

    @ObservedObject var pairingManager: PairingManager
    let networkClient: PairingNetworkClient

    @State private var isMinting: Bool = false
    @State private var didCopySessionId: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Senior.Geometry.touchSpacing) {
            Text("Pair this Mac with your parent's Mac")
                .font(DS.Senior.Typography.headline)
                .foregroundColor(DS.Senior.Colors.foreground)

            Text("Tap the button below to get a 6-digit code, then read it to your parent so they can type it on their Mac. The code expires in 5 minutes.")
                .font(DS.Senior.Typography.hint)
                .foregroundColor(DS.Senior.Colors.accentCalm)
                .fixedSize(horizontal: false, vertical: true)

            if let activePairCode = pairingManager.activePairCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(formatCodeForDisplay(activePairCode.digits))
                        .font(DS.Senior.Typography.monospace)
                        .foregroundColor(DS.Senior.Colors.foreground)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Senior.Geometry.containerCornerRadius)
                                .fill(.thinMaterial)
                        )

                    if let pairId = pairingManager.activePairId {
                        sessionIdRow(pairId: pairId)
                    }
                }
            }

            HStack(spacing: DS.Senior.Geometry.touchSpacing) {
                Button(action: requestNewCode) {
                    Text(pairingManager.activePairCode == nil ? "Get a code" : "Get a new code")
                        .font(DS.Senior.Typography.body.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: DS.Senior.Geometry.buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                                .fill(DS.Senior.Colors.accentPrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isMinting)
            }

            if let networkError = pairingManager.lastNetworkError {
                Text(displayMessage(for: networkError))
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentDanger)
            }

            Spacer()
        }
        .padding(40)
    }

    /// Full session id row with copy button. Senior side requires the
    /// FULL Durable-Object id (64 hex chars) — truncating it to 8
    /// stranded the user. We render it selectable so the kid can paste
    /// into a message to Mom, plus a one-tap Copy button.
    private func sessionIdRow(pairId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session id (your parent needs this too):")
                .font(DS.Senior.Typography.hint)
                .foregroundColor(DS.Senior.Colors.accentCalm)

            HStack(alignment: .top, spacing: 12) {
                Text(pairId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Senior.Colors.foreground)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS.Senior.Colors.dividerHairline, lineWidth: 1)
                    )

                Button(action: { copySessionIdToClipboard(pairId: pairId) }) {
                    HStack(spacing: 6) {
                        Image(systemName: didCopySessionId
                              ? "checkmark"
                              : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                        Text(didCopySessionId ? "Copied" : "Copy")
                            .font(DS.Senior.Typography.hint.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                            .fill(didCopySessionId
                                  ? DS.Senior.Colors.accentPrimary
                                  : DS.Senior.Colors.accentCalm)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copySessionIdToClipboard(pairId: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pairId, forType: .string)
        didCopySessionId = true
        // Reset the "Copied" state after 2s so the kid can copy again
        // if they need to paste more than once.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopySessionId = false
        }
    }

    private func requestNewCode() {
        guard !isMinting else { return }
        isMinting = true
        Task {
            await pairingManager.requestNewPairCodeFromWorker(client: networkClient)
            isMinting = false
        }
    }

    /// "1 2 3 4 5 6" — visible space between digits so it's easy to
    /// read aloud over a phone call.
    private func formatCodeForDisplay(_ digits: String) -> String {
        digits.map { String($0) }.joined(separator: " ")
    }
}

// MARK: - Senior side

private struct SeniorPairCodeEntryView: View {

    @ObservedObject var pairingManager: PairingManager
    let networkClient: PairingNetworkClient
    let onPairingCompleted: () -> Void

    @State private var enteredDigits: String = ""
    @State private var enteredKidPairId: String = ""
    @State private var isVerifying: Bool = false
    @State private var lastVerifyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Senior.Geometry.touchSpacing) {
            Text("Type the 6-digit code your kid sent you")
                .font(DS.Senior.Typography.headline)
                .foregroundColor(DS.Senior.Colors.foreground)

            VStack(alignment: .leading, spacing: 6) {
                TextField("123456", text: Binding(
                    get: { enteredDigits },
                    set: { enteredDigits = String($0.prefix(6)).filter(\.isNumber) }
                ))
                .textFieldStyle(.plain)
                .font(DS.Senior.Typography.monospace)
                .foregroundColor(DS.Senior.Colors.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: DS.Senior.Geometry.containerCornerRadius)
                        .stroke(DS.Senior.Colors.dividerHairline, lineWidth: DS.Senior.Geometry.hairlineWidth)
                )

                Text("Session id (paste from kid's screen):")
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentCalm)

                TextField("paste id", text: $enteredKidPairId)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(DS.Senior.Colors.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS.Senior.Colors.dividerHairline, lineWidth: 1)
                    )
            }

            Button(action: submit) {
                Text("Connect")
                    .font(DS.Senior.Typography.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DS.Senior.Geometry.buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                            .fill(connectButtonIsEnabled
                                  ? DS.Senior.Colors.accentPrimary
                                  : DS.Senior.Colors.accentCalm.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!connectButtonIsEnabled)

            if let lastVerifyMessage {
                Text(lastVerifyMessage)
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(messageColor(for: lastVerifyMessage))
            }

            if let lockoutDeadline = pairingManager.lockoutUntil {
                Text("Too many wrong tries. Try again in \(secondsRemaining(until: lockoutDeadline))s.")
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentDanger)
            }

            if let networkError = pairingManager.lastNetworkError {
                Text(displayMessage(for: networkError))
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentDanger)
            }

            Spacer()
        }
        .padding(40)
        .onChange(of: pairingManager.pairedPeerToken) { _, newValue in
            if newValue != nil {
                lastVerifyMessage = "All set! You're paired."
                onPairingCompleted()
            }
        }
    }

    private var connectButtonIsEnabled: Bool {
        enteredDigits.count == PairingManager.codeDigitCount
        && !enteredKidPairId.isEmpty
        && !isVerifying
    }

    private func submit() {
        guard connectButtonIsEnabled else { return }
        isVerifying = true
        lastVerifyMessage = nil
        Task {
            await pairingManager.submitEnteredPairCode(
                enteredDigits,
                forKidPairId: enteredKidPairId,
                client: networkClient
            )
            isVerifying = false
            if pairingManager.pairedPeerToken == nil {
                if let lockoutDeadline = pairingManager.lockoutUntil, lockoutDeadline > Date() {
                    lastVerifyMessage = nil
                } else if pairingManager.consecutiveWrongAttempts > 0 {
                    let remaining = max(
                        0,
                        PairingManager.maxConsecutiveWrongAttempts - pairingManager.consecutiveWrongAttempts
                    )
                    lastVerifyMessage = "That code didn't match. \(remaining) tries left."
                }
            }
        }
    }

    private func secondsRemaining(until deadline: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(Date())))
    }

    private func messageColor(for message: String) -> Color {
        message.contains("All set") ? DS.Senior.Colors.accentPrimary : DS.Senior.Colors.accentDanger
    }
}

// MARK: - Shared helpers

private func displayMessage(for error: PairingNetworkError) -> String {
    switch error {
    case .networkUnreachable:
        return "Couldn't reach Clicky's server. Check your internet and try again."
    case .unexpectedStatus(let status):
        return "Server returned an unexpected response (status \(status))."
    case .malformedResponse:
        return "Server returned data we couldn't read. Try again in a moment."
    }
}
