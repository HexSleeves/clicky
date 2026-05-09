//
//  RoleManagerTests.swift
//  leanring-buddyTests
//
//  Covers the Phase 1 Test Plan's RoleManager rows:
//  - Pick role + persist, reload across launches, idempotent
//  - No role selected (cancelled dialog) → re-prompt next launch
//  - Persistence corruption → fall back to fresh role pick
//

import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct RoleManagerTests {

    @Test func freshLaunchPromptsForRoleSelection() {
        let emptyStorage = InMemoryRoleStorage()
        let roleManager = RoleManager(storage: emptyStorage)

        #expect(roleManager.currentRole == nil)
        #expect(roleManager.needsRoleSelection == true)
    }

    @Test func selectingRolePersistsItAndClearsPrompt() throws {
        let storage = InMemoryRoleStorage()
        let roleManager = RoleManager(storage: storage)

        try roleManager.selectRole(.senior)

        #expect(roleManager.currentRole == .senior)
        #expect(roleManager.needsRoleSelection == false)
        #expect(storage.savedRole == .senior)
    }

    /// Reload across launches: a manager built from storage that already
    /// has a role MUST come up in that role with no prompt.
    @Test func relaunchWithPersistedRoleSkipsPrompt() {
        let storageWithKidRole = InMemoryRoleStorage(initialRole: .kid)
        let roleManager = RoleManager(storage: storageWithKidRole)

        #expect(roleManager.currentRole == .kid)
        #expect(roleManager.needsRoleSelection == false)
    }

    /// Idempotency: selecting the same role twice should not toggle the
    /// prompt back on or otherwise observably differ from selecting once.
    @Test func selectingSameRoleTwiceIsIdempotent() throws {
        let storage = InMemoryRoleStorage()
        let roleManager = RoleManager(storage: storage)

        try roleManager.selectRole(.kid)
        try roleManager.selectRole(.kid)

        #expect(roleManager.currentRole == .kid)
        #expect(roleManager.needsRoleSelection == false)
    }

    /// Phase 1 Test Plan row: "No role selected (cancelled dialog) →
    /// re-prompt next launch." We model "cancelled dialog" as: the user
    /// closed the picker without persisting, then relaunched. The next
    /// session sees an empty storage and re-prompts.
    @Test func cancelledDialogRePromptsNextLaunch() {
        let storage = InMemoryRoleStorage() // user closed the picker → nothing persisted
        let firstSession = RoleManager(storage: storage)
        #expect(firstSession.needsRoleSelection == true)

        // Simulate relaunch by constructing a new manager off the same
        // storage instance. (The real app constructs a fresh manager per
        // process; the storage is what survives.)
        let secondSession = RoleManager(storage: storage)
        #expect(secondSession.currentRole == nil)
        #expect(secondSession.needsRoleSelection == true)
    }

    /// Phase 1 Test Plan row: "Persistence corruption → fall back to
    /// fresh role pick." When storage returns nil because the bytes
    /// failed to decode, the manager MUST come up in the unset state so
    /// the user gets a fresh picker.
    @Test func persistenceCorruptionFallsBackToFreshPick() {
        let corruptedStorage = InMemoryRoleStorage(initialRole: .senior)
        corruptedStorage.loadShouldReturnNilToSimulateCorruption = true

        let roleManager = RoleManager(storage: corruptedStorage)

        #expect(roleManager.currentRole == nil)
        #expect(roleManager.needsRoleSelection == true)
    }

    @Test func resetRoleClearsPersistedStateAndRePrompts() throws {
        let storage = InMemoryRoleStorage(initialRole: .senior)
        let roleManager = RoleManager(storage: storage)

        roleManager.resetRole()

        #expect(roleManager.currentRole == nil)
        #expect(roleManager.needsRoleSelection == true)
        #expect(storage.savedRole == nil)
    }

    /// FileRoleStorage smoke test using a tempdir URL — verifies the
    /// real on-disk path round-trips. Doesn't poke at Application
    /// Support so this test never leaves debris on the dev machine.
    @Test func fileRoleStorageRoundTripsThroughTempDirectory() throws {
        let temporaryStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoleManagerTests-\(UUID().uuidString)")
            .appendingPathComponent("role.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryStoreURL.deletingLastPathComponent())
        }

        let fileStorage = FileRoleStorage(storeFileURL: temporaryStoreURL)
        try fileStorage.saveRole(.kid)

        let reopenedStorage = FileRoleStorage(storeFileURL: temporaryStoreURL)
        #expect(reopenedStorage.loadRole() == .kid)
    }

    /// Corruption posture on disk: garbage bytes at the role-file path
    /// MUST surface as nil, not throw, so the app can re-prompt rather
    /// than crash.
    @Test func fileRoleStorageReturnsNilOnGarbageBytes() throws {
        let temporaryStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoleManagerTests-\(UUID().uuidString)")
            .appendingPathComponent("role.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryStoreURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: temporaryStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a json role".utf8).write(to: temporaryStoreURL)

        let fileStorage = FileRoleStorage(storeFileURL: temporaryStoreURL)
        #expect(fileStorage.loadRole() == nil)
    }
}
