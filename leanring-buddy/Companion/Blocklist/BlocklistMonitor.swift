//
//  BlocklistMonitor.swift
//  leanring-buddy
//
//  Live wrapper around `BlocklistMatcher`. Subscribes to
//  NSWorkspace's `didActivateApplicationNotification` so the
//  outcome updates whenever Mom switches apps. URL-pattern matching
//  hooks an injected `URLProvider` — Phase 1 ships a stub that
//  returns nil; Phase 2 wires up the Accessibility API on Safari /
//  Chrome.
//
//  No AppKit imports inside the matcher itself — this file is the
//  ONLY place that talks to NSWorkspace, so unit tests can drive
//  the matcher directly without spinning up a runloop.
//

import AppKit
import Combine
import Foundation

/// Pluggable source for the active-tab URL. Phase 1 default is a
/// no-op; Phase 2 plugs in a Safari / Chrome AX bridge.
protocol BlocklistActiveURLProvider: AnyObject {
    /// Best-effort URL of the frontmost browser tab. Returns nil for
    /// non-browser apps or when the AX bridge can't read it.
    func currentActiveURLString() -> String?
}

final class NoOpBlocklistActiveURLProvider: BlocklistActiveURLProvider {
    func currentActiveURLString() -> String? { nil }
}

@MainActor
final class BlocklistMonitor: ObservableObject {

    @Published private(set) var currentOutcome: BlocklistOutcome = .allowed

    private let rules: [BlocklistRule]
    private let urlProvider: BlocklistActiveURLProvider
    private var workspaceObserver: NSObjectProtocol?

    init(
        rules: [BlocklistRule] = DefaultBlocklistRules.allRules,
        urlProvider: BlocklistActiveURLProvider = NoOpBlocklistActiveURLProvider()
    ) {
        self.rules = rules
        self.urlProvider = urlProvider
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    /// Begin monitoring. Idempotent — safe to call from session start.
    func startMonitoring() {
        if workspaceObserver != nil { return }
        evaluateNow()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateNow()
            }
        }
    }

    /// Stop monitoring and reset to allowed. Called by
    /// RemoteSessionManager.endSession so a stale block banner doesn't
    /// linger after Mom's call ended.
    func stopMonitoring() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        currentOutcome = .allowed
    }

    /// Force a re-evaluation against the current active app/URL. Call
    /// after wake-from-sleep or on any other "I'm not sure who's in
    /// front" boundary event.
    func evaluateNow() {
        let activeBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let activeURLString = urlProvider.currentActiveURLString()
        currentOutcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: activeBundleIdentifier,
            activeURLString: activeURLString,
            rules: rules
        )
    }
}
