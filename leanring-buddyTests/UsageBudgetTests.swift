//
//  UsageBudgetTests.swift
//  leanring-buddyTests
//
//  Exercises UsageBudget's persistence + rollover math with an injected
//  clock and a scratch UserDefaults suite. The real ~30-day rollover takes
//  too long to wait for in CI — the injected clock makes it deterministic.
//

import Testing
import Foundation
@testable import Milo

@MainActor
struct UsageBudgetTests {

    // MARK: - Helpers

    /// Fresh in-memory UserDefaults so each test starts clean. Suite name
    /// is per-test (UUID) so tests can't pollute each other.
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "UsageBudgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Mutable clock for tests — tweak `now` between calls to advance time.
    private final class TestClock {
        var now: Date
        init(_ start: Date) { self.now = start }
        func read() -> Date { now }
    }

    // MARK: - Initialization

    @Test func freshInstallAnchorsPeriodToNow() {
        let defaults = makeScratchDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))

        let budget = UsageBudget(defaults: defaults, clock: clock.read)

        #expect(budget.voiceMessageCount == 0)
        #expect(budget.agentMessageCount == 0)
        #expect(budget.periodStart == clock.now)
        // Period start was persisted so a re-init reads the same anchor.
        #expect(defaults.double(forKey: PersistenceKeys.monthlyUsagePeriodStart) == clock.now.timeIntervalSince1970)
    }

    @Test func relaunchReadsPersistedState() {
        let defaults = makeScratchDefaults()
        let originalStart = Date(timeIntervalSince1970: 1_000_000)
        defaults.set(originalStart.timeIntervalSince1970, forKey: PersistenceKeys.monthlyUsagePeriodStart)
        defaults.set(7, forKey: PersistenceKeys.monthlyVoiceMessageCount)
        defaults.set(3, forKey: PersistenceKeys.monthlyAgentMessageCount)

        let clock = TestClock(Date(timeIntervalSince1970: 1_500_000))
        let budget = UsageBudget(defaults: defaults, clock: clock.read)

        #expect(budget.voiceMessageCount == 7)
        #expect(budget.agentMessageCount == 3)
        #expect(budget.periodStart == originalStart)
    }

    // MARK: - Increments

    @Test func incrementBumpsVoiceCounterAndPersists() {
        let defaults = makeScratchDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let budget = UsageBudget(defaults: defaults, clock: clock.read)

        budget.incrementVoiceMessageCount()
        budget.incrementVoiceMessageCount()

        #expect(budget.voiceMessageCount == 2)
        #expect(defaults.integer(forKey: PersistenceKeys.monthlyVoiceMessageCount) == 2)
    }

    @Test func incrementBumpsAgentCounterIndependently() {
        let defaults = makeScratchDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let budget = UsageBudget(defaults: defaults, clock: clock.read)

        budget.incrementVoiceMessageCount()
        budget.incrementAgentMessageCount()
        budget.incrementAgentMessageCount()

        #expect(budget.voiceMessageCount == 1)
        #expect(budget.agentMessageCount == 2)
    }

    // MARK: - Rollover

    @Test func incrementBeforePeriodEndDoesNotRollover() {
        let defaults = makeScratchDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let budget = UsageBudget(defaults: defaults, clock: clock.read)
        budget.incrementVoiceMessageCount()
        budget.incrementVoiceMessageCount()

        // Advance 29 days — still inside the window.
        clock.now = clock.now.addingTimeInterval(60 * 60 * 24 * 29)
        budget.incrementVoiceMessageCount()

        #expect(budget.voiceMessageCount == 3)
        #expect(budget.periodStart == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func incrementAfterPeriodEndRollsCountersToZeroAndAdvancesAnchor() {
        let defaults = makeScratchDefaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        let budget = UsageBudget(defaults: defaults, clock: clock.read)
        budget.incrementVoiceMessageCount()
        budget.incrementAgentMessageCount()
        #expect(budget.voiceMessageCount == 1)

        // Advance 31 days past the original anchor.
        clock.now = start.addingTimeInterval(60 * 60 * 24 * 31)
        budget.incrementVoiceMessageCount()

        // Rollover happened first, then the increment fired against the
        // reset counters → voice = 1, agent = 0.
        #expect(budget.voiceMessageCount == 1)
        #expect(budget.agentMessageCount == 0)
        #expect(budget.periodStart == clock.now)
        #expect(defaults.double(forKey: PersistenceKeys.monthlyUsagePeriodStart) == clock.now.timeIntervalSince1970)
    }

    @Test func periodEndIsThirtyDaysAfterStart() {
        let defaults = makeScratchDefaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        let budget = UsageBudget(defaults: defaults, clock: clock.read)

        let expectedEnd = start.addingTimeInterval(60 * 60 * 24 * 30)
        #expect(budget.periodEnd == expectedEnd)
    }

    // MARK: - Caps surface

    @Test func capsAreNonZero() {
        // The Settings popover divides usage by the cap to render the bar.
        // A zero cap would NaN/Inf the math.
        #expect(UsageBudget.voiceMessageCap > 0)
        #expect(UsageBudget.agentMessageCap > 0)
    }
}
