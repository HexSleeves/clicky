//
//  BlocklistMatcherTests.swift
//  leanring-buddyTests
//
//  Phase 1 Test Plan rows for the thin blocklist:
//    - Match active app bundle ID (banking, health, password managers)
//    - Match active URL pattern
//    - New app not in list → snap allowed (default-allow within consent gate)
//

import Foundation
import Testing
@testable import leanring_buddy

struct BlocklistMatcherTests {

    @Test func bankingBundleIDIsBlocked() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.chase.sig.Chase",
            activeURLString: nil
        )
        if case .blocked(let displayReason) = outcome {
            #expect(displayReason == "banking app detected")
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }

    @Test func passwordManagerBundleIDIsBlocked() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.1password.1password7",
            activeURLString: nil
        )
        if case .blocked(let displayReason) = outcome {
            #expect(displayReason == "password manager detected")
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }

    @Test func healthPortalBundleIDIsBlocked() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.epic.MyChart",
            activeURLString: nil
        )
        if case .blocked(let displayReason) = outcome {
            #expect(displayReason == "health portal detected")
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }

    @Test func bankingURLPatternIsBlocked() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.apple.Safari",
            activeURLString: "https://www.bankofamerica.com/login"
        )
        if case .blocked(let displayReason) = outcome {
            #expect(displayReason == "banking app detected")
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }

    /// Case-insensitivity: a URL with mixed case still matches a
    /// lowercase substring rule.
    @Test func urlMatchingIsCaseInsensitive() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.apple.Safari",
            activeURLString: "https://CHASE.COM/account"
        )
        if case .blocked = outcome {
            // ok
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }

    /// Phase 1 Test Plan row: "New app not in list → snap allowed".
    @Test func unknownBundleAndURLAreAllowed() {
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.example.NotebookApp",
            activeURLString: "https://www.wikipedia.org/wiki/macOS"
        )
        #expect(outcome == .allowed)
    }

    @Test func nilBundleAndURLAreAllowed() {
        // Boot-time state where NSWorkspace hasn't reported a frontmost
        // app yet. Default-allow inside the consent gate per design.
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: nil,
            activeURLString: nil
        )
        #expect(outcome == .allowed)
    }

    /// Custom rule injection: tests can supply their own rules so the
    /// curated defaults can grow without breaking existing assertions.
    @Test func customRulesArePickedUp() {
        let customRule = BlocklistRule(
            displayReason: "test app detected",
            bundleIdentifiers: ["com.example.TestApp"]
        )
        let outcome = BlocklistMatcher.evaluate(
            activeBundleIdentifier: "com.example.TestApp",
            activeURLString: nil,
            rules: [customRule]
        )
        if case .blocked(let displayReason) = outcome {
            #expect(displayReason == "test app detected")
        } else {
            Issue.record("expected blocked, got \(outcome)")
        }
    }
}
