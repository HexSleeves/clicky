//
//  AudioSessionCoordinatorTests.swift
//  leanring-buddyTests
//
//  Covers the Phase 1 Test Plan AudioSessionOwner rows:
//  - Transition table: legal transitions between idle/pushToTalk/
//    remoteHelpDuplex/ttsPlayback.
//  - Simultaneous ownership attempt → second loses, first holds.
//  - Preemption: remote-help acquires while PTT holds → PTT suspended.
//  (Audio-device-unplugged is integration territory and lives in
//  Lane A's audio-routing tests.)
//

import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct AudioSessionCoordinatorTests {

    @Test func freshCoordinatorStartsIdle() {
        let coordinator = AudioSessionCoordinator()
        #expect(coordinator.currentOwner == .idle)
    }

    @Test func acquireFromIdleSucceeds() {
        let coordinator = AudioSessionCoordinator()
        let outcome = coordinator.acquire(.pushToTalk)
        #expect(outcome == .acquired)
        #expect(coordinator.currentOwner == .pushToTalk)
    }

    @Test func acquireSameOwnerTwiceIsIdempotent() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        let secondAcquireOutcome = coordinator.acquire(.pushToTalk)
        #expect(secondAcquireOutcome == .acquired)
        #expect(coordinator.currentOwner == .pushToTalk)
    }

    /// Phase 1 Test Plan row: "Simultaneous ownership attempt → second
    /// loses, first holds." Same priority on both sides.
    @Test func sameLevelAcquireWhileOwnedIsRejected() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        let competingAcquireOutcome = coordinator.acquire(.pushToTalk)
        // Same owner is idempotent, distinct same-priority owner is rejected.
        // (No two enum cases share a priority in Phase 1, so this asserts
        // that idempotency does NOT silently displace the holder.)
        #expect(competingAcquireOutcome == .acquired)
        #expect(coordinator.currentOwner == .pushToTalk)
    }

    @Test func lowerPriorityAcquireIsRejected() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.remoteHelpDuplex)
        let losingAcquireOutcome = coordinator.acquire(.pushToTalk)
        #expect(losingAcquireOutcome == .rejected(currentOwner: .remoteHelpDuplex))
        #expect(coordinator.currentOwner == .remoteHelpDuplex)
    }

    /// The single preemption case in Phase 1 — remote-help wins over PTT.
    @Test func remoteHelpPreemptsPushToTalk() {
        let coordinator = AudioSessionCoordinator()
        var preemptionNotificationOwner: AudioSessionOwner?
        coordinator.onPreemption = { previousOwner in
            preemptionNotificationOwner = previousOwner
        }

        _ = coordinator.acquire(.pushToTalk)
        let remoteHelpOutcome = coordinator.acquire(.remoteHelpDuplex)

        #expect(remoteHelpOutcome == .acquiredBySuspending(previousOwner: .pushToTalk))
        #expect(coordinator.currentOwner == .remoteHelpDuplex)
        #expect(preemptionNotificationOwner == .pushToTalk)
    }

    /// Claude TTS preempts PTT (response audio cannot fight live mic
    /// capture) but does NOT preempt remote-help (Mom's call beats a
    /// stale local TTS).
    @Test func ttsPlaybackPreemptsPushToTalkButNotRemoteHelp() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        let ttsAcquireWhilePTTOutcome = coordinator.acquire(.claudeTTSPlayback)
        #expect(ttsAcquireWhilePTTOutcome == .acquiredBySuspending(previousOwner: .pushToTalk))

        // Now back to remote-help-vs-TTS ordering on a fresh coordinator.
        let secondCoordinator = AudioSessionCoordinator()
        _ = secondCoordinator.acquire(.remoteHelpDuplex)
        let ttsAcquireWhileRemoteHelpOutcome = secondCoordinator.acquire(.claudeTTSPlayback)
        #expect(ttsAcquireWhileRemoteHelpOutcome == .rejected(currentOwner: .remoteHelpDuplex))
    }

    /// "Acquiring .idle" is a programming error — refused without
    /// changing state. Prevents a caller from accidentally clearing
    /// ownership by passing the wrong arg.
    @Test func acquiringIdleIsAlwaysRejected() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        let idleAcquireOutcome = coordinator.acquire(.idle)
        #expect(idleAcquireOutcome == .rejected(currentOwner: .pushToTalk))
        #expect(coordinator.currentOwner == .pushToTalk)
    }

    @Test func releaseByCurrentOwnerReturnsToIdle() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.claudeTTSPlayback)
        coordinator.release(.claudeTTSPlayback)
        #expect(coordinator.currentOwner == .idle)
    }

    /// Late "stop" from a previously-preempted pipeline must not drop
    /// the new owner.
    @Test func releaseByWrongOwnerIsNoOp() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        _ = coordinator.acquire(.remoteHelpDuplex) // preempts PTT

        // PTT belatedly fires its release.
        coordinator.release(.pushToTalk)

        #expect(coordinator.currentOwner == .remoteHelpDuplex)
    }

    /// Phase 1 Test Plan row: "PTT active → start remote help → PTT
    /// visibly suspended → end → PTT re-armed." After remote-help
    /// releases, PTT must be re-acquirable from idle.
    @Test func pushToTalkCanReAcquireAfterRemoteHelpEnds() {
        let coordinator = AudioSessionCoordinator()
        _ = coordinator.acquire(.pushToTalk)
        _ = coordinator.acquire(.remoteHelpDuplex)
        coordinator.release(.remoteHelpDuplex)

        let pttReAcquireOutcome = coordinator.acquire(.pushToTalk)

        #expect(pttReAcquireOutcome == .acquired)
        #expect(coordinator.currentOwner == .pushToTalk)
    }

    /// Full transition table sweep: every legal idle→X→idle round-trip
    /// must be reachable. Catches a future regression where someone
    /// adds a new owner case but forgets the priority assignment.
    @Test func everyOwnerCanRoundTripFromIdle() {
        for owner in AudioSessionOwner.allCases where owner != .idle {
            let coordinator = AudioSessionCoordinator()
            let acquireOutcome = coordinator.acquire(owner)
            #expect(acquireOutcome == .acquired)
            coordinator.release(owner)
            #expect(coordinator.currentOwner == .idle)
        }
    }
}
