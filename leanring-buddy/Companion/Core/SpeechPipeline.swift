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

    let elevenLabsClient: ElevenLabsTTSClient
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

    /// Enqueue a sentence into the streaming TTS queue. Fires the TTS
    /// request immediately; playback happens sequentially in submission
    /// order via AVAudioPlayer's delegate chain. Used by the response
    /// pipeline to start the first sentence playing while later
    /// sentences are still arriving from Claude.
    func enqueueSpeak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        elevenLabsClient.enqueueSpeak(trimmed)
    }

    /// Set BEFORE enqueueing the first sentence of a response. Fires
    /// when audio for the first chunk actually starts playing — the
    /// orchestrator uses this to flip voiceState from .processing to
    /// .responding so the spinner becomes the speaking-cursor state.
    func setOnFirstPlaybackStarted(_ handler: @escaping @MainActor () -> Void) {
        elevenLabsClient.onPlaybackStarted = handler
    }

    /// Set BEFORE the response stream finishes. Fires when the queue is
    /// fully drained + no requests remain in flight — orchestrator uses
    /// this to drop voiceState back to .idle.
    func setOnQueueDrained(_ handler: @escaping @MainActor () -> Void) {
        elevenLabsClient.onQueueDrained = handler
    }

    /// True once ElevenLabs has rejected the session. Orchestrator checks
    /// this after streaming completes to decide whether the entire
    /// response should be re-spoken via system voice.
    var isInElevenLabsFallbackMode: Bool {
        elevenLabsClient.isInFallbackMode
    }

    /// Speaks `text` via the macOS system voice synthesizer — bypasses
    /// ElevenLabs entirely. Used as the session-level fallback when the
    /// streaming pipeline detects ElevenLabs is unusable.
    func speakViaSystemFallback(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSystemFallback(trimmed)
    }

    private func startSystemFallback(_ text: String) {
        systemSynthesizer?.stopSpeaking(at: .immediate)
        let synthesizer = AVSpeechSynthesizer()
        systemSynthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
    }
}
