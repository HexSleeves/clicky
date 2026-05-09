//
//  RoleManagerUIGatingTests.swift
//  leanring-buddyTests
//
//  Tests for the role-aware UI predicates that views consult instead
//  of inlining `currentRole == .kid` checks.
//

import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct RoleManagerUIGatingTests {

    @Test func kidRoleShowsKidSurfaces() throws {
        let storage = InMemoryRoleStorage(initialRole: .kid)
        let roleManager = RoleManager(storage: storage)
        #expect(roleManager.shouldShowKidSurfaces == true)
        #expect(roleManager.shouldShowSeniorSurfaces == false)
        #expect(roleManager.shouldShowAdvancedSettings == true)
    }

    @Test func seniorRoleShowsOnlySeniorSurfaces() throws {
        let storage = InMemoryRoleStorage(initialRole: .senior)
        let roleManager = RoleManager(storage: storage)
        #expect(roleManager.shouldShowKidSurfaces == false)
        #expect(roleManager.shouldShowSeniorSurfaces == true)
        #expect(roleManager.shouldShowAdvancedSettings == false)
    }

    /// Pre-selection state: kid surfaces show (the kid is the
    /// installer hitting first launch), senior surfaces stay hidden
    /// (Mom never sees the no-role-yet state — by the time she's
    /// looking, the kid has already picked .senior on her behalf).
    @Test func unsetRoleShowsKidNotSenior() throws {
        let storage = InMemoryRoleStorage(initialRole: nil)
        let roleManager = RoleManager(storage: storage)
        #expect(roleManager.shouldShowKidSurfaces == true)
        #expect(roleManager.shouldShowSeniorSurfaces == false)
        #expect(roleManager.shouldShowAdvancedSettings == true)
    }

    @Test func switchingRolesUpdatesPredicates() throws {
        let storage = InMemoryRoleStorage(initialRole: .kid)
        let roleManager = RoleManager(storage: storage)
        #expect(roleManager.shouldShowKidSurfaces == true)

        try roleManager.selectRole(.senior)

        #expect(roleManager.shouldShowKidSurfaces == false)
        #expect(roleManager.shouldShowSeniorSurfaces == true)
    }
}
