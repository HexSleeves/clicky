//
//  SeniorTokens.swift
//  leanring-buddy
//
//  Phase 1 senior-side design system. Lives under `DS.Senior.*` so it
//  reads as one namespace separate from the kid-side `DS.*` palette
//  (which is dark-bias, smaller type, more interactive density).
//
//  Spec source: docs/phase-1/design.md "Design Specs" section. Every
//  numeric value below has a matching test row in
//  leanring-buddyTests/SeniorTokensTests.swift to catch silent drift
//  between the design spec and the implementation.
//
//  Hard rules from the design review:
//    - Type minimum = 18pt (the `hint` token). Anything below 18pt is
//      a regression and must NOT ship on senior surfaces.
//    - Buttons are >=60pt height (arthritis-friendly target).
//    - Cursor motion is ease-out, NOT spring. Spring reads as
//      "playful"; senior aesthetic is "calm".
//    - Reduce-Motion teleports — animations collapse to zero duration
//      so VoiceOver and motion-sensitive users get instant transitions.
//

import SwiftUI

extension DS {

    /// Senior-side design tokens. Use these (and only these) for any
    /// surface visible to Mom/Dad. Kid-side surfaces continue to use
    /// the existing `DS.Colors`, `DS.Spacing`, etc.
    enum Senior {

        // MARK: - Typography

        enum Typography {
            /// Smallest body size. Use only when `body` will not fit
            /// (e.g. dense secondary copy). Never go smaller than this.
            static let bodyMinSize: CGFloat = 24

            /// Default body size. Use for prose, button labels, and
            /// most surfaces.
            static let bodySize: CGFloat = 28

            /// Smallest headline size. Use when `headline` overflows
            /// (e.g. on the consent dialog when the kid's name is
            /// long).
            static let headlineMinSize: CGFloat = 36

            /// Default headline size. Use for primary lines on modal
            /// dialogs and one-screen flows.
            static let headlineSize: CGFloat = 40

            /// Hint / disclosure copy. The MINIMUM size on any senior
            /// surface — anything smaller than this is a regression.
            static let hintSize: CGFloat = 18

            /// Monospace size for the 6-digit pair-code entry boxes.
            static let monospaceSize: CGFloat = 44

            static let bodyMin = Font.system(size: bodyMinSize, weight: .regular, design: .default)
            static let body = Font.system(size: bodySize, weight: .regular, design: .default)
            static let headlineMin = Font.system(size: headlineMinSize, weight: .semibold, design: .default)
            static let headline = Font.system(size: headlineSize, weight: .semibold, design: .default)
            static let hint = Font.system(size: hintSize, weight: .regular, design: .default)
            static let monospace = Font.system(size: monospaceSize, weight: .regular, design: .monospaced)
        }

        // MARK: - Colors

        enum Colors {
            // Light-bias palette. The system pref is respected at the
            // SwiftUI environment layer; these are the *light* values.
            // Dark-mode counterparts live in `dark` below.
            static let background = Color(hex: "#FFFFFF")
            static let foreground = Color(hex: "#1A1A1A")

            static let dividerHairline = Color(hex: "#C8C8C8")

            /// Affirmative actions ("Yes, share my screen", success
            /// banners). High-contrast green chosen for AAA contrast
            /// against the white background.
            static let accentPrimary = Color(hex: "#1A6F3F")

            /// Destructive / urgent ("STOP SHARING"). ALWAYS pair with
            /// a shape (icon, border, capsule) — never communicate
            /// danger by color alone.
            static let accentDanger = Color(hex: "#B33A1F")

            /// Calm status accent ("Jacob is here", "Reaching Jacob…").
            /// Deep navy reads as "okay, this is fine" without
            /// shouting.
            static let accentCalm = Color(hex: "#2C4F6E")

            /// Dark-mode override. Only used when the user has
            /// explicitly enabled dark mode in System Settings.
            enum Dark {
                static let background = Color(hex: "#1C1C1E")
                static let foreground = Color(hex: "#F5F5F5")
            }
        }

        // MARK: - Geometry

        enum Geometry {
            /// Minimum tap target. Arthritis-friendly; the design
            /// review chose 60pt rather than the standard 44pt because
            /// senior tremor + low-precision pointers fail at 44pt.
            static let buttonHeight: CGFloat = 60

            /// Button corner radius. Quiet, not playful — 8pt reads
            /// as "professional". Avoid pill / 24pt corners on
            /// senior surfaces.
            static let buttonCornerRadius: CGFloat = 8

            /// Modal / card containers.
            static let containerCornerRadius: CGFloat = 16

            /// Single hairline weight used for grouping. NO shadows
            /// (visual noise reads as clutter for low-vision users).
            static let hairlineWidth: CGFloat = 1.5

            /// Gap between any two tappable elements. Larger than
            /// kid-side spacing so missed taps don't trigger a
            /// neighboring control.
            static let touchSpacing: CGFloat = 24

            /// Gap between text blocks for clean scan lines.
            static let readSpacing: CGFloat = 16
        }

        // MARK: - Motion

        enum Motion {
            /// Cursor flight to a target. Calm ease-out, NOT spring.
            static let cursorFlightDurationSeconds: TimeInterval = 0.20

            /// Modal / banner appearance.
            static let fadeInDurationSeconds: TimeInterval = 0.18

            /// Modal / banner disappearance — slightly faster than
            /// fade-in so the surface clears the moment Mom dismisses
            /// it.
            static let fadeOutDurationSeconds: TimeInterval = 0.12

            /// Returns a SwiftUI animation that respects the system
            /// `reduceMotion` accessibility flag. If reduce-motion is
            /// on, returns `nil` so the caller's value updates apply
            /// instantly (teleport) rather than tweening.
            static func cursorFlightAnimation(reduceMotion: Bool) -> Animation? {
                reduceMotion ? nil : .easeOut(duration: cursorFlightDurationSeconds)
            }

            static func fadeInAnimation(reduceMotion: Bool) -> Animation? {
                reduceMotion ? nil : .easeOut(duration: fadeInDurationSeconds)
            }

            static func fadeOutAnimation(reduceMotion: Bool) -> Animation? {
                reduceMotion ? nil : .easeIn(duration: fadeOutDurationSeconds)
            }
        }
    }
}
