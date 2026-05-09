//
//  Blocklist.swift
//  leanring-buddy
//
//  Phase 1 thin blocklist (eng review decision #4: per-session consent
//  + thin blocklist safety net). The active-app gate runs continuously
//  while a remote-help session is live. URL-pattern matching is a
//  Phase 2 polish — see `BlocklistRule.urlPattern`'s callers.
//

import Foundation

/// Outcome of the per-frame blocklist check.
enum BlocklistOutcome: Equatable {
    /// Active app + URL are clean; the snap-on-input path is allowed.
    case allowed

    /// Active surface matched a blocklist rule. Senior-side overlay
    /// suspends the stream and renders the "paused — banking detected"
    /// banner using `displayReason`.
    case blocked(displayReason: String)
}

/// One entry in the blocklist. Matches against either an app's bundle
/// identifier (e.g. "com.apple.Wallet") or a URL pattern. Phase 1 ships
/// a curated default list; future versions can layer user-curated
/// additions on top.
struct BlocklistRule: Equatable, Hashable {
    /// Free-form display text shown in the senior-side pause banner
    /// (e.g. "banking app detected"). Kept generic so Mom doesn't have
    /// to know which exact category triggered the block.
    let displayReason: String

    /// Bundle IDs that match this rule. Empty set means "no bundle-ID
    /// gate"; the rule still fires on a URL match.
    let bundleIdentifiers: Set<String>

    /// URL substrings that match this rule. Empty means "no URL gate".
    /// Substring match (case-insensitive) is sufficient for the thin
    /// blocklist spec; full regex is Phase 2 polish.
    let urlSubstrings: Set<String>

    init(
        displayReason: String,
        bundleIdentifiers: Set<String> = [],
        urlSubstrings: Set<String> = []
    ) {
        self.displayReason = displayReason
        self.bundleIdentifiers = bundleIdentifiers
        self.urlSubstrings = urlSubstrings
    }
}

enum DefaultBlocklistRules {
    /// Curated Phase 1 defaults. Senior-friendly, errs on the side of
    /// blocking too much — Mom can just switch apps to resume sharing.
    static let allRules: [BlocklistRule] = [
        BlocklistRule(
            displayReason: "banking app detected",
            bundleIdentifiers: [
                "com.apple.Wallet",
                "com.apple.PaymentSheetUIService",
                "com.bankofamerica.MOBILE",
                "com.chase.sig.Chase",
                "com.wellsfargo.Wells",
                "com.intuit.MintBank",
                "com.coinbase.Coinbase",
            ],
            urlSubstrings: [
                ".bank",
                "bankofamerica.com",
                "chase.com",
                "wellsfargo.com",
                "citibank.com",
                "fidelity.com",
                "schwab.com",
                "vanguard.com",
                "paypal.com",
                "venmo.com",
            ]
        ),
        BlocklistRule(
            displayReason: "password manager detected",
            bundleIdentifiers: [
                "com.1password.1password7",
                "com.agilebits.onepassword4",
                "com.lastpass.LastPass",
                "com.bitwarden.desktop",
                "org.keepassxc.keepassxc",
                "com.apple.Passwords",
            ]
        ),
        BlocklistRule(
            displayReason: "health portal detected",
            bundleIdentifiers: [
                "com.epic.MyChart",
                "com.apple.Health",
            ],
            urlSubstrings: [
                "mychart.",
                ".health",
                "healthcare.gov",
                "kaiserpermanente.org",
            ]
        ),
    ]
}

/// Pure evaluator. Side-effect-free so tests don't need NSWorkspace
/// or any AppKit notification taps. The live monitor (BlocklistMonitor)
/// feeds it the current frontmost app + tab URL; the matcher returns
/// allowed/blocked.
enum BlocklistMatcher {
    static func evaluate(
        activeBundleIdentifier: String?,
        activeURLString: String?,
        rules: [BlocklistRule] = DefaultBlocklistRules.allRules
    ) -> BlocklistOutcome {
        let normalizedURLString = activeURLString?.lowercased()

        for rule in rules {
            if let bundleIdentifier = activeBundleIdentifier,
               rule.bundleIdentifiers.contains(bundleIdentifier) {
                return .blocked(displayReason: rule.displayReason)
            }
            if let normalizedURLString,
               rule.urlSubstrings.contains(where: { normalizedURLString.contains($0.lowercased()) }) {
                return .blocked(displayReason: rule.displayReason)
            }
        }
        return .allowed
    }
}
