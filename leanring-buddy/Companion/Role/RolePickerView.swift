//
//  RolePickerView.swift
//  leanring-buddy
//
//  Phase 1 first-launch role picker. Presented when
//  `RoleManager.needsRoleSelection` is true. The kid is the one
//  operating both Macs during in-person install, so the copy is
//  written from the kid's perspective.
//
//  Surfaces use DS.Senior.* tokens because either path may be presented
//  on a low-vision senior Mac (the kid sometimes installs a senior-side
//  build on their own Mac to test); applying the senior tokens
//  uniformly costs nothing visual on a kid Mac and protects the senior
//  case if someone hits the picker without the role being pre-selected.
//

import SwiftUI

struct RolePickerView: View {

    /// Owns the persistence side-effect; injected so previews and
    /// tests can substitute an in-memory storage.
    @ObservedObject var roleManager: RoleManager

    @State private var lastSelectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Senior.Geometry.touchSpacing) {
            Text("Who is this Mac for?")
                .font(DS.Senior.Typography.headline)
                .foregroundColor(DS.Senior.Colors.foreground)

            Text("Pick once. You can change this later from Settings.")
                .font(DS.Senior.Typography.hint)
                .foregroundColor(DS.Senior.Colors.accentCalm)

            VStack(spacing: DS.Senior.Geometry.touchSpacing) {
                rolePickerButton(
                    label: "This is my Mac",
                    subcopy: "I'll help someone else from here.",
                    role: .kid
                )

                rolePickerButton(
                    label: "This is my parent's Mac",
                    subcopy: "I'm setting it up so they can ask for help.",
                    role: .senior
                )
            }

            if let lastSelectionError {
                Text(lastSelectionError)
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentDanger)
            }

            Spacer()
        }
        .padding(40)
        .frame(width: 720, height: 540)
        .background(DS.Senior.Colors.background)
    }

    @ViewBuilder
    private func rolePickerButton(
        label: String,
        subcopy: String,
        role: AppRole
    ) -> some View {
        Button {
            handleSelection(role)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(DS.Senior.Typography.body)
                    .foregroundColor(DS.Senior.Colors.foreground)
                Text(subcopy)
                    .font(DS.Senior.Typography.hint)
                    .foregroundColor(DS.Senior.Colors.accentCalm)
            }
            .frame(maxWidth: .infinity, minHeight: DS.Senior.Geometry.buttonHeight, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Senior.Geometry.buttonCornerRadius)
                    .stroke(DS.Senior.Colors.dividerHairline, lineWidth: DS.Senior.Geometry.hairlineWidth)
            )
        }
        .buttonStyle(.plain)
    }

    private func handleSelection(_ role: AppRole) {
        do {
            try roleManager.selectRole(role)
            lastSelectionError = nil
        } catch {
            // Persistence failed (disk full, sandbox revoked, etc.).
            // Surface friendly copy; keep the picker open.
            lastSelectionError = "We couldn't save that. Try again."
        }
    }
}

#if DEBUG
struct RolePickerView_Previews: PreviewProvider {
    static var previews: some View {
        RolePickerView(roleManager: RoleManager(storage: InMemoryRoleStorage()))
            .frame(width: 720, height: 540)
    }
}
#endif
