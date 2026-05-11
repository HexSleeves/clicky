//
//  PersistenceKeys.swift
//  leanring-buddy
//
//  Single source of truth for every UserDefaults key the app reads or
//  writes. Centralizing the strings catches typos at build time (you
//  can't misspell an enum case) and makes it possible to audit at a
//  glance what state the app persists.
//
//  CRITICAL: these key strings are part of the on-disk format. Renaming
//  any of them orphans persisted state on existing installs — the next
//  launch reads `false`/`0`/`nil` instead of the previous value. The
//  constants here are FROZEN — only the constant *name* may change. If
//  you need different semantics, add a new key and migrate.
//
//  WindowPositionManager's key uses an old "com.learningbuddy" prefix
//  from before the rebrand. It's documented + frozen here so the
//  oddity is visible without changing the string.
//

import Foundation

enum PersistenceKeys {

    // MARK: - Onboarding

    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let hasSubmittedEmail = "hasSubmittedEmail"

    // MARK: - Permissions

    /// Tracks whether the user has previously granted Screen Content
    /// (separate from Screen Recording — this is the newer macOS 15
    /// permission tier).
    static let hasScreenContentPermission = "hasScreenContentPermission"

    /// Sticky "user has already granted Screen Recording before so don't
    /// re-prompt" flag. Frozen with the legacy bundle prefix to preserve
    /// existing installs' state across the Milo rebrand. Do NOT rename.
    static let hasPreviouslyConfirmedScreenRecordingPermission =
        "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    // MARK: - UI preferences

    static let isMiloCursorEnabled = "isMiloCursorEnabled"
    static let isGuidedActionBypassEnabled = "isGuidedActionBypassEnabled"
    static let selectedCursorColor = "selectedCursorColor"
    static let selectedClaudeModel = "selectedClaudeModel"

    // MARK: - Usage budget

    static let monthlyVoiceMessageCount = "monthlyVoiceMessageCount"
    static let monthlyAgentMessageCount = "monthlyAgentMessageCount"
    static let monthlyUsagePeriodStart = "monthlyUsagePeriodStart"

    // MARK: - Identity + consent

    static let miloInstallId = "miloInstallId"
    static let analyticsConsentState = "analyticsConsentState"
}
