//
//  MiloError.swift
//  leanring-buddy
//
//  The single user-facing error model. Every failure path in the app —
//  permission denials, Worker budget exhaustion, provider outages,
//  network blips, TTS failures — maps to exactly one case here. Views
//  render `userMessage` + `recoverySuggestion`; the spoken cursor uses
//  `spokenFallback`; analytics records `analyticsCode`.
//
//  Why three text properties instead of one `LocalizedError.errorDescription`?
//  - `userMessage` is read by a human in a UI toast — short, plain, warm.
//  - `spokenFallback` is read by TTS — sentence-shaped, no "tap" verbs.
//  - `analyticsCode` is read by PostHog — stable across versions for funnels.
//  Conflating them produces messages that read fine in one channel and
//  weirdly in the others.
//

import Foundation

enum MiloError: Error, Equatable {

    enum Permission: String, Equatable {
        case microphone
        case screenRecording
        case accessibility

        var displayName: String {
            switch self {
            case .microphone: return "Microphone"
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            }
        }
    }

    enum ProviderKind: String, Equatable {
        case chat        // Claude via Worker /chat
        case tts         // ElevenLabs via Worker /tts
        case transcribe  // AssemblyAI via Worker /transcribe-token
    }

    case missingPermission(Permission)
    case budgetExhausted(retryAfterSeconds: TimeInterval)
    case rateLimited(retryAfterSeconds: TimeInterval)
    case providerDown(ProviderKind)
    case providerDenied(ProviderKind)
    case appUpgradeRequired(minimumVersion: String)
    case transcriptionFailed
    case ttsFailed
    case screenshotFailed
    case payloadTooLarge
    case network
    case unknown
}

extension MiloError {

    /// Text rendered in the panel toast. Keep short, plain, warm. Avoid
    /// jargon ("provider", "endpoint"). Avoid blame ("you ran out").
    var userMessage: String {
        switch self {
        case .missingPermission(let permission):
            return "Milo needs \(permission.displayName) access to help with that."
        case .budgetExhausted:
            return "You've used your messages for today. They reset at midnight UTC."
        case .rateLimited:
            return "Milo is catching its breath — try again in a moment."
        case .providerDown(.chat):
            return "Milo's brain is offline. Try again shortly."
        case .providerDown(.tts):
            return "Voice playback is unavailable. Using the system voice for now."
        case .providerDown(.transcribe):
            return "Speech-to-text is unavailable. Try the type-to-talk shortcut instead."
        case .providerDenied:
            return "Milo can't reach that service right now."
        case .appUpgradeRequired(let minimumVersion):
            return "An update is required to keep using Milo. Minimum version: \(minimumVersion)."
        case .transcriptionFailed:
            return "Milo couldn't hear that clearly. Try again."
        case .ttsFailed:
            return "Voice playback failed."
        case .screenshotFailed:
            return "Milo couldn't see your screen. Check Screen Recording permission."
        case .payloadTooLarge:
            return "That was a lot to send at once. Try a shorter message."
        case .network:
            return "Milo can't reach the server. Check your connection."
        case .unknown:
            return "Something went wrong. Try again in a moment."
        }
    }

    /// Optional follow-up CTA. When present, the toast renders a button
    /// next to the message. Returning nil means "no recovery action".
    var recoverySuggestion: RecoverySuggestion? {
        switch self {
        case .missingPermission:
            return RecoverySuggestion(label: "Open Settings", kind: .openSystemSettings)
        case .appUpgradeRequired:
            return RecoverySuggestion(label: "Get Update", kind: .openUpdatePage)
        case .budgetExhausted, .rateLimited:
            return nil // Time-based — nothing the user can do but wait.
        default:
            return nil
        }
    }

    /// TTS-friendly version. Read aloud to the user when an error
    /// happens during a voice interaction. Single sentence, no symbols.
    var spokenFallback: String {
        switch self {
        case .missingPermission:
            return "I need permission to help with that. Check the settings."
        case .budgetExhausted:
            return "You've hit today's message limit."
        case .rateLimited:
            return "Give me a sec to catch up."
        case .providerDown, .providerDenied:
            return "I can't reach the server right now."
        case .appUpgradeRequired:
            return "There's a Milo update waiting."
        case .transcriptionFailed:
            return "I couldn't catch that — try again?"
        case .ttsFailed:
            return ""
        case .screenshotFailed:
            return "I can't see your screen right now."
        case .payloadTooLarge:
            return "That was a lot — try something shorter."
        case .network:
            return "I'm having trouble reaching the server."
        case .unknown:
            return "I hit an error while trying to answer that."
        }
    }

    /// Stable code for analytics. NEVER include free-text user content here.
    /// Adding a case: pick a snake_case name and never change it — funnels
    /// and dashboards downstream depend on stability.
    var analyticsCode: String {
        switch self {
        case .missingPermission(let p): return "permission_\(p.rawValue)"
        case .budgetExhausted: return "budget_exhausted"
        case .rateLimited: return "rate_limited"
        case .providerDown(let p): return "provider_down_\(p.rawValue)"
        case .providerDenied(let p): return "provider_denied_\(p.rawValue)"
        case .appUpgradeRequired: return "upgrade_required"
        case .transcriptionFailed: return "transcription_failed"
        case .ttsFailed: return "tts_failed"
        case .screenshotFailed: return "screenshot_failed"
        case .payloadTooLarge: return "payload_too_large"
        case .network: return "network"
        case .unknown: return "unknown"
        }
    }
}

extension MiloError {

    /// Classifies an arbitrary Swift error into a MiloError case so the
    /// catch site doesn't need to inspect error shapes itself. Used by
    /// every response-pipeline catch site so error UI is consistent
    /// regardless of which subsystem threw.
    ///
    /// Today: pattern-matches URLError and NSError code/domain. Once
    /// T0.3's Worker error envelope ships, this is where the Worker's
    /// `E_BUDGET`, `E_RATE_LIMIT`, etc. codes get mapped to their
    /// matching MiloError cases.
    static func from(_ error: any Error) -> MiloError {
        if error is CancellationError { return .unknown } // caller should ignore

        let nsError = error as NSError

        // URLSession network failures.
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorTimedOut:
                return .network
            case NSURLErrorDataLengthExceedsMaximum:
                return .payloadTooLarge
            default:
                return .network
            }
        }

        return .unknown
    }
}

struct RecoverySuggestion: Equatable {
    enum Kind: Equatable {
        case openSystemSettings
        case openUpdatePage
        case retry
        case dismiss
    }

    let label: String
    let kind: Kind
}
