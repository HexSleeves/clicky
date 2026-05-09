//
//  AppRole.swift
//  leanring-buddy
//
//  Single-app, two-role architecture (eng review decision #1).
//  The app ships as one bundle; on first launch the user picks
//  whether this Mac is the kid (helper) or the senior (parent
//  receiving help). All UI surfaces gate on this flag.
//

import Foundation

/// Runtime role of the Mac the app is running on. Persisted across
/// launches; can be reset only by an explicit user action (not by code).
enum AppRole: String, Codable, CaseIterable, Sendable {
    /// Adult child — the buyer and the active driver. Sees the dashboard,
    /// pair-code generator, and kid-side preview window.
    case kid

    /// Aging parent — the help-receiver. Voice-first, one-button surface;
    /// dashboards and settings panels are hidden in this mode.
    case senior
}
