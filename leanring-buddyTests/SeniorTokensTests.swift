//
//  SeniorTokensTests.swift
//  leanring-buddyTests
//
//  Pin every numeric value in DS.Senior.* to the design spec so silent
//  drift between docs/phase-1/design.md and the implementation gets
//  caught here, not at usability-review time.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct SeniorTokensTests {

    // MARK: - Typography

    @Test func typographyMinimumSizeIs18Pt() {
        // The "hint" token IS the senior-side type minimum. Anything
        // smaller is a regression that fails WCAG 2.1 AA on senior
        // surfaces.
        #expect(DS.Senior.Typography.hintSize == 18)
    }

    @Test func typographyScaleMatchesDesignSpec() {
        #expect(DS.Senior.Typography.bodyMinSize == 24)
        #expect(DS.Senior.Typography.bodySize == 28)
        #expect(DS.Senior.Typography.headlineMinSize == 36)
        #expect(DS.Senior.Typography.headlineSize == 40)
        #expect(DS.Senior.Typography.monospaceSize == 44)
    }

    @Test func typographyScaleIsStrictlyAscending() {
        // Defends against a future "let's bump body to 32 and forget
        // about hint" edit that flattens the hierarchy.
        let orderedSizes = [
            DS.Senior.Typography.hintSize,
            DS.Senior.Typography.bodyMinSize,
            DS.Senior.Typography.bodySize,
            DS.Senior.Typography.headlineMinSize,
            DS.Senior.Typography.headlineSize,
            DS.Senior.Typography.monospaceSize,
        ]
        for nextIndex in 1..<orderedSizes.count {
            #expect(orderedSizes[nextIndex] > orderedSizes[nextIndex - 1])
        }
    }

    // MARK: - Geometry

    @Test func buttonHeightIsArthritisFriendly() {
        // Design review locked >=60pt against the standard 44pt floor.
        #expect(DS.Senior.Geometry.buttonHeight == 60)
        #expect(DS.Senior.Geometry.buttonHeight >= 44)
    }

    @Test func cornerRadiiMatchDesignSpec() {
        #expect(DS.Senior.Geometry.buttonCornerRadius == 8)
        #expect(DS.Senior.Geometry.containerCornerRadius == 16)
    }

    @Test func hairlineAndSpacingMatchDesignSpec() {
        #expect(DS.Senior.Geometry.hairlineWidth == 1.5)
        #expect(DS.Senior.Geometry.touchSpacing == 24)
        #expect(DS.Senior.Geometry.readSpacing == 16)
    }

    @Test func touchSpacingIsLargerThanReadSpacing() {
        // Missed-tap defense: tap targets need MORE breathing room
        // than text blocks. If these ever reverse, senior users are
        // about to start hitting wrong buttons.
        #expect(DS.Senior.Geometry.touchSpacing > DS.Senior.Geometry.readSpacing)
    }

    // MARK: - Motion

    @Test func motionDurationsMatchDesignSpec() {
        #expect(DS.Senior.Motion.cursorFlightDurationSeconds == 0.20)
        #expect(DS.Senior.Motion.fadeInDurationSeconds == 0.18)
        #expect(DS.Senior.Motion.fadeOutDurationSeconds == 0.12)
    }

    /// Reduce-motion teleports: returning nil from the animation
    /// helper means SwiftUI applies the value change instantly.
    @Test func reduceMotionAnimationsAreNil() {
        #expect(DS.Senior.Motion.cursorFlightAnimation(reduceMotion: true) == nil)
        #expect(DS.Senior.Motion.fadeInAnimation(reduceMotion: true) == nil)
        #expect(DS.Senior.Motion.fadeOutAnimation(reduceMotion: true) == nil)
    }

    @Test func reduceMotionOffYieldsNonNilAnimations() {
        #expect(DS.Senior.Motion.cursorFlightAnimation(reduceMotion: false) != nil)
        #expect(DS.Senior.Motion.fadeInAnimation(reduceMotion: false) != nil)
        #expect(DS.Senior.Motion.fadeOutAnimation(reduceMotion: false) != nil)
    }
}
