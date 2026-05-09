//
//  RoleManager+UIGating.swift
//  leanring-buddy
//
//  Single source of truth for "should this surface render given the
//  current role." Views import these instead of inlining `currentRole
//  == .kid` checks so a future role addition doesn't fork hide/show
//  logic across a dozen call sites.
//

import Foundation

extension RoleManager {

    /// Should the kid-side surfaces (Settings popover model picker,
    /// pair-code generator dashboard, conversation history, etc.) be
    /// visible? Includes the "no role chosen yet" state because the
    /// kid is the one who hits first-launch on their own Mac before
    /// Mom's Mac is configured.
    var shouldShowKidSurfaces: Bool {
        switch currentRole {
        case .kid, .none:
            return true
        case .senior:
            return false
        }
    }

    /// Should the senior-side surfaces (one-button help trigger,
    /// consent dialog, post-session success card) be visible? Strictly
    /// senior-only — the kid never sees these even during the
    /// no-role-yet first launch (they're presented inside the senior's
    /// Mac, not the kid's).
    var shouldShowSeniorSurfaces: Bool {
        switch currentRole {
        case .senior:
            return true
        case .kid, .none:
            return false
        }
    }

    /// Phase 1 scope rule (eng review decision #1 + design spec):
    /// "Auto-click actions" toggle is hidden entirely in senior mode.
    /// Keeping it visible to Mom violates the voice-first / no-settings
    /// constraint. Routed through the same predicate so any future
    /// surface adoption is consistent.
    var shouldShowAdvancedSettings: Bool {
        shouldShowKidSurfaces
    }
}
