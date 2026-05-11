//
//  SpeechPipeline.swift
//  leanring-buddy
//
//  Owns spoken output: ElevenLabs TTS as the primary path, macOS system
//  voice (AVSpeechSynthesizer) as the fallback when the proxy or
//  ElevenLabs is unavailable. The orchestrator calls `speak(text:)` and
//  switches on `SpeakOutcome` to drive voice-state transitions and fire
//  the right analytics — this pipeline stays analytics-agnostic.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class SpeechPipeline {

    enum SpeakOutcome {
        /// ElevenLabs TTS started playback successfully.
        case elevenLabs
        /// ElevenLabs failed; system voice fallback was started instead.
        case systemFallback(error: Error)
        /// Input text was empty after trimming; nothing was spoken.
        case skippedEmpty
    }

    private let elevenLabsClient: ElevenLabsTTSClient
    private var systemSynthesizer: AVSpeechSynthesizer?

    /// True while ElevenLabs audio is playing. The orchestrator's transient
    /// hide scheduler polls this to decide when the cursor can fade out.
    /// Does not reflect system-fallback playback (AVSpeechSynthesizer
    /// exposes no equivalent `isPlaying` flag we can poll cheaply).
    var isPlaying: Bool { elevenLabsClient.isPlaying }

    init(
        workerBaseURL: String = WorkerEndpoints.baseURL,
        identity: InstallIdentity? = nil
    ) {
        self.elevenLabsClient = ElevenLabsTTSClient(
            proxyURL: workerBaseURL + WorkerEndpoints.ttsPath,
            identity: identity
        )
    }

    /// Speaks `text` aloud. Tries ElevenLabs first; on failure falls back
    /// to macOS system voice. Returns which path was taken so the caller
    /// can update state + analytics accordingly. Never throws — failure
    /// modes are surfaced through `SpeakOutcome` instead.
    func speak(_ text: String) async -> SpeakOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skippedEmpty }

        do {
            try await elevenLabsClient.speakText(trimmed)
            return .elevenLabs
        } catch {
            startSystemFallback(trimmed)
            return .systemFallback(error: error)
        }
    }

    /// Immediately halts any ElevenLabs playback and any active system
    /// fallback utterance. Idempotent and safe to call from any code path.
    func stop() {
        elevenLabsClient.stopPlayback()
        systemSynthesizer?.stopSpeaking(at: .immediate)
    }

    private func startSystemFallback(_ text: String) {
        systemSynthesizer?.stopSpeaking(at: .immediate)
        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
    }
}
