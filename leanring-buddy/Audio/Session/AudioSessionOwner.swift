//
//  AudioSessionOwner.swift
//  leanring-buddy
//
//  Eng review decision #6: explicit single-owner state machine for the
//  audio pipeline. Prevents "mic in use" bugs and feedback loops between
//  push-to-talk, remote-help duplex, and Claude TTS playback.
//

import Foundation

/// Who currently holds the microphone + speaker pipelines.
///
/// At most one of these is active at any moment. The `priority`
/// dimension models the *only* preemption case in Phase 1: a remote
/// help session preempts an in-flight push-to-talk recording (see
/// design doc, "PTT visibly suspended" path).
enum AudioSessionOwner: String, Equatable, CaseIterable, Sendable {
    case idle
    case pushToTalk
    case claudeTTSPlayback
    case remoteHelpDuplex

    /// Higher value preempts lower value. `idle` is 0 and never preempts
    /// or gets preempted (every acquire from idle is permitted).
    var preemptionPriority: Int {
        switch self {
        case .idle: return 0
        case .pushToTalk: return 1
        case .claudeTTSPlayback: return 2
        case .remoteHelpDuplex: return 3
        }
    }
}
