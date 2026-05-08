//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func controlCommandStartsTypeToTalkShortcut() async throws {
        let transition = BuddyTypeToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags([.control, .command]).rawValue),
            wasShortcutPreviouslyPressed: false
        )

        #expect(transition == .pressed)
    }

    @Test func releasingControlCommandEndsTypeToTalkShortcut() async throws {
        let transition = BuddyTypeToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: 0,
            wasShortcutPreviouslyPressed: true
        )

        #expect(transition == .released)
    }

}
