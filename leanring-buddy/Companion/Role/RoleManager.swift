//
//  RoleManager.swift
//  leanring-buddy
//
//  Phase 1, eng-review decision #5 (decompose CompanionManager).
//
//  Owns the runtime role flag for the single-app, two-role architecture.
//  CompanionManager consumes this via composition — it does NOT subclass
//  or extend RoleManager.
//

import Combine
import Foundation

@MainActor
final class RoleManager: ObservableObject {
    /// Currently-active role. `nil` means the user has not picked one yet
    /// (first launch, or storage corruption fell back to fresh prompt).
    @Published private(set) var currentRole: AppRole?

    /// True when the role-picker UI should be presented. Bound to the
    /// onboarding flow on first launch.
    @Published private(set) var needsRoleSelection: Bool

    private let storage: RoleStorage

    init(storage: RoleStorage = FileRoleStorage()) {
        self.storage = storage
        let loadedRole = storage.loadRole()
        self.currentRole = loadedRole
        self.needsRoleSelection = (loadedRole == nil)
    }

    /// Persists the chosen role and clears the role-selection prompt.
    /// Idempotent: selecting the same role twice is a no-op for callers.
    func selectRole(_ role: AppRole) throws {
        try storage.saveRole(role)
        currentRole = role
        needsRoleSelection = false
    }

    /// Wipes the persisted role and re-arms the role-selection prompt.
    /// Reserved for explicit user action ("change role" debug menu) —
    /// not invoked anywhere in the auto-recovery path.
    func resetRole() {
        storage.clear()
        currentRole = nil
        needsRoleSelection = true
    }
}
