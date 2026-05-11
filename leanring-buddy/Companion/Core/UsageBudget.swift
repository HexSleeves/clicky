//
//  UsageBudget.swift
//  leanring-buddy
//
//  Owns the rolling 30-day "free plan" usage counters surfaced on the
//  Settings popover. Two counters today: voice/text messages sent, and
//  Claude responses received. Both auto-roll over every 30 days, anchored
//  to the period-start timestamp persisted on first launch.
//
//  Extracted from CompanionManager so the rollover math is testable in
//  isolation and so the eventual Worker-side budget (T0.3) has a single
//  client-side seam to integrate against — without searching through
//  orchestration code to find it.
//

import Combine
import Foundation

@MainActor
final class UsageBudget: ObservableObject {

    /// Soft caps shown on the Settings popover. Not enforced — they exist
    /// purely so the progress bars render with meaningful denominators.
    /// Will become server-driven once T0.3 ships per-install budgets.
    static let voiceMessageCap: Int = 100
    static let agentMessageCap: Int = 35

    private static let periodLength: TimeInterval = 60 * 60 * 24 * 30

    // Forwarders to keep the rest of the file readable; PersistenceKeys
    // is the source of truth and what's used by tests / external readers.
    private static let voiceCountKey = PersistenceKeys.monthlyVoiceMessageCount
    private static let agentCountKey = PersistenceKeys.monthlyAgentMessageCount
    private static let periodStartKey = PersistenceKeys.monthlyUsagePeriodStart

    @Published private(set) var voiceMessageCount: Int
    @Published private(set) var agentMessageCount: Int
    @Published private(set) var periodStart: Date

    /// When the current rolling window ends. Settings popover renders a
    /// "resets in Xd Yh" countdown against this.
    var periodEnd: Date {
        periodStart.addingTimeInterval(Self.periodLength)
    }

    private let defaults: UserDefaults
    private let clock: () -> Date

    /// - Parameters:
    ///   - defaults: Persistence backing store. Production uses `.standard`;
    ///     tests inject a scratch suite via `UserDefaults(suiteName:)`.
    ///   - clock: Closure returning "now". Production uses `Date.init`;
    ///     tests inject a stub so rollover behavior is deterministic.
    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock

        self.voiceMessageCount = defaults.integer(forKey: Self.voiceCountKey)
        self.agentMessageCount = defaults.integer(forKey: Self.agentCountKey)

        let storedTimestamp = defaults.double(forKey: Self.periodStartKey)
        if storedTimestamp > 0 {
            self.periodStart = Date(timeIntervalSince1970: storedTimestamp)
        } else {
            // First launch — anchor the period to "now" so the countdown
            // stays consistent across launches.
            let now = clock()
            self.periodStart = now
            defaults.set(now.timeIntervalSince1970, forKey: Self.periodStartKey)
        }
    }

    func incrementVoiceMessageCount() {
        rolloverIfNeeded()
        voiceMessageCount += 1
        defaults.set(voiceMessageCount, forKey: Self.voiceCountKey)
    }

    func incrementAgentMessageCount() {
        rolloverIfNeeded()
        agentMessageCount += 1
        defaults.set(agentMessageCount, forKey: Self.agentCountKey)
    }

    /// Resets counters and bumps the period start when the rolling 30-day
    /// window has elapsed. Called before every increment so the rollover
    /// happens lazily without a background timer.
    private func rolloverIfNeeded() {
        guard clock() >= periodEnd else { return }

        voiceMessageCount = 0
        agentMessageCount = 0
        let newPeriodStart = clock()
        periodStart = newPeriodStart

        defaults.set(0, forKey: Self.voiceCountKey)
        defaults.set(0, forKey: Self.agentCountKey)
        defaults.set(newPeriodStart.timeIntervalSince1970, forKey: Self.periodStartKey)
    }
}
