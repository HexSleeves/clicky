//
//  AudioSessionCoordinator.swift
//  leanring-buddy
//
//  Single-owner gatekeeper for the mic + speaker pipelines.
//
//  Use sites (Phase 1):
//    - BuddyDictationManager: acquire(.pushToTalk) before starting a
//      recording; release on transcript finalization.
//    - ElevenLabsTTSClient: acquire(.claudeTTSPlayback) before play;
//      release in `audioPlayerDidFinishPlaying`.
//    - RemoteSessionManager: acquire(.remoteHelpDuplex) on session
//      start; release on session teardown. This call may preempt an
//      in-flight push-to-talk — the coordinator notifies the previous
//      owner via `onPreemption` so PTT can wind down cleanly.
//

import Combine
import Foundation

@MainActor
final class AudioSessionCoordinator: ObservableObject {
    enum AcquireOutcome: Equatable {
        /// Acquisition succeeded; coordinator was previously idle or the
        /// same owner re-acquired idempotently.
        case acquired
        /// Acquisition succeeded by preempting a higher-priority owner.
        /// The caller MUST be ready for the previous owner's pipeline to
        /// have just been told to stop.
        case acquiredBySuspending(previousOwner: AudioSessionOwner)
        /// Acquisition rejected because the current owner outranks (or
        /// equals) the requester. The caller backs off.
        case rejected(currentOwner: AudioSessionOwner)
    }

    @Published private(set) var currentOwner: AudioSessionOwner = .idle

    /// Hook invoked synchronously when the coordinator preempts the
    /// current owner. The owner being preempted is passed in. Used by
    /// the PTT subsystem to drop a recording in flight when remote-help
    /// starts.
    var onPreemption: ((AudioSessionOwner) -> Void)?

    @discardableResult
    func acquire(_ requestingOwner: AudioSessionOwner) -> AcquireOutcome {
        guard requestingOwner != .idle else {
            return .rejected(currentOwner: currentOwner)
        }

        if currentOwner == .idle {
            currentOwner = requestingOwner
            return .acquired
        }

        if currentOwner == requestingOwner {
            // Same owner re-acquiring — idempotent for callers like PTT
            // that may re-enter on rapid key events.
            return .acquired
        }

        if requestingOwner.preemptionPriority > currentOwner.preemptionPriority {
            let previousOwner = currentOwner
            onPreemption?(previousOwner)
            currentOwner = requestingOwner
            return .acquiredBySuspending(previousOwner: previousOwner)
        }

        return .rejected(currentOwner: currentOwner)
    }

    /// Releases ownership only if the caller currently holds it. Wrong-
    /// owner releases are no-ops so a late "stop" from a preempted
    /// pipeline cannot accidentally drop a higher-priority owner.
    func release(_ releasingOwner: AudioSessionOwner) {
        guard currentOwner == releasingOwner else { return }
        currentOwner = .idle
    }

    /// Force back to idle. Reserved for app-shutdown / reset paths.
    func resetToIdle() {
        currentOwner = .idle
    }
}
