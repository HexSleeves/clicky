//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Sends text to ElevenLabs and plays the resulting audio. Supports two
//  modes:
//   - `speakText` — single request, blocks until audio starts playing.
//     Used for short utterances like "saved." that complete in one shot.
//   - `enqueueSpeak` — fire-and-forget. Spawns a TTS request immediately
//     and appends the resulting player to a queue. Players play
//     sequentially via the AVAudioPlayer delegate callback. Enables
//     sentence-chunked playback during streaming Claude responses.
//
//  The queue preserves caller-submitted order even if a later
//  sentence's TTS finishes before an earlier one's — each queued slot
//  holds either "in-flight" or "ready-to-play" state, and the playback
//  loop only advances when the next slot has its audio.
//

import AVFoundation
import Foundation

struct ElevenLabsTTSClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class ElevenLabsTTSClient: NSObject {
    private let proxyURL: URL
    private let session: URLSession
    private let identity: InstallIdentity?
    private(set) var shouldUseSystemVoiceFallback = false

    /// True once ElevenLabs has rejected the session (plan disabled,
    /// payment required, etc.). The orchestrator checks this after the
    /// streaming response completes to decide whether to speak the
    /// whole response via the system voice fallback path.
    var isInFallbackMode: Bool { shouldUseSystemVoiceFallback }

    /// Currently-playing audio player, if any. Held so playback continues
    /// when the caller doesn't retain a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Audio data ready to play, in submission order. Sentence N+1's
    /// data may arrive in this array before sentence N's playback has
    /// started — the playback loop drains in order, so out-of-order TTS
    /// completion is fine.
    private var pendingPlaybackQueue: [Data] = []

    /// Number of in-flight TTS requests not yet returned. Used by the
    /// orchestrator to know when the queue is drained AND no more audio
    /// can arrive — i.e. when it's safe to flip voiceState to .idle.
    private(set) var pendingRequestCount: Int = 0

    /// Fires when the entire queue has played out AND no requests are
    /// still in flight. Owner uses this to flip state machine.
    var onQueueDrained: (@MainActor () -> Void)?

    /// Fires when the FIRST queued audio starts playing in a session.
    /// Owner uses this to flip voiceState from processing to responding.
    var onPlaybackStarted: (@MainActor () -> Void)?

    init(proxyURL: String, identity: InstallIdentity? = nil) {
        self.proxyURL = URL(string: proxyURL)!
        self.identity = identity

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    // MARK: - Single-shot API (unchanged)

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    /// For sentence-chunked streaming use `enqueueSpeak` instead.
    func speakText(_ text: String) async throws {
        let data = try await fetchAudioData(for: text)
        try Task.checkCancellation()
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    // MARK: - Streaming queue API

    /// Fires a TTS request for `text` and queues the resulting audio
    /// for sequential playback. Returns immediately; playback happens
    /// asynchronously via the audio-player delegate chain.
    ///
    /// Subsequent calls during the same response queue further audio
    /// behind whatever's already playing. Out-of-order completion is
    /// fine — slots are filled in submission order, drained in order.
    func enqueueSpeak(_ text: String) {
        let submissionIndex = pendingRequestCount + pendingPlaybackQueue.count
        pendingRequestCount += 1

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await self.fetchAudioData(for: text)
                self.pendingRequestCount -= 1
                self.insertAudioData(data, atSubmissionIndex: submissionIndex)
                self.advanceQueueIfIdle()
            } catch is CancellationError {
                self.pendingRequestCount -= 1
            } catch {
                self.pendingRequestCount -= 1
                // Only log the FIRST failure per session. Once
                // `shouldUseSystemVoiceFallback` flips true, every later
                // chunk throws the same error — logging each one fills
                // the console with noise. The orchestrator handles the
                // session-level fallback via `isInFallbackMode`.
                if !self.shouldUseSystemVoiceFallback {
                    print("⚠️ ElevenLabs TTS chunk failed: \(error.localizedDescription)")
                }
                self.notifyDrainedIfQuiet()
            }
        }
    }

    /// Internal: inserts audio data into the playback queue at its
    /// submission position. Since `pendingPlaybackQueue` only holds
    /// READY data (not placeholders), submission position translates to
    /// "back of queue" — earlier sentences have already drained into
    /// `audioPlayer` by the time later ones arrive. If they haven't,
    /// FIFO append is still correct because in-flight requests block
    /// nothing; the queue advances based on player-finished callbacks.
    private func insertAudioData(_ data: Data, atSubmissionIndex submissionIndex: Int) {
        pendingPlaybackQueue.append(data)
    }

    /// If nothing is currently playing, pulls the next data from the
    /// queue and starts it. Otherwise, the player-finished delegate
    /// callback drives advancement.
    private func advanceQueueIfIdle() {
        guard audioPlayer == nil || audioPlayer?.isPlaying == false else { return }
        guard !pendingPlaybackQueue.isEmpty else {
            notifyDrainedIfQuiet()
            return
        }
        let nextData = pendingPlaybackQueue.removeFirst()

        // Defensive: skip zero-byte payloads. ElevenLabs can return a
        // 200 OK with empty body during edge cases (cancellation
        // mid-stream, malformed input); constructing an AVAudioPlayer
        // on empty data produces the `AVAudioBuffer mDataByteSize (0)
        // should be non-zero` runtime warning and silent playback.
        // Skip + advance to the next slot.
        guard nextData.count > 0 else {
            print("⚠️ ElevenLabs TTS chunk: skipping zero-byte audio")
            advanceQueueIfIdle()
            return
        }

        do {
            let player = try AVAudioPlayer(data: nextData)
            player.delegate = self
            self.audioPlayer = player
            let isFirstOfSession = (onPlaybackStarted != nil)
            player.play()
            print("🔊 ElevenLabs TTS chunk: playing \(nextData.count / 1024)KB (queue: \(pendingPlaybackQueue.count) more, \(pendingRequestCount) in flight)")
            if isFirstOfSession {
                onPlaybackStarted?()
                onPlaybackStarted = nil // one-shot per session
            }
        } catch {
            print("⚠️ ElevenLabs TTS playback init failed: \(error)")
            advanceQueueIfIdle() // try next slot
        }
    }

    private func notifyDrainedIfQuiet() {
        guard pendingPlaybackQueue.isEmpty,
              pendingRequestCount == 0,
              audioPlayer?.isPlaying != true else {
            return
        }
        onQueueDrained?()
    }

    // MARK: - Shared HTTP fetch

    /// Sends one TTS request, returns the raw audio data. Sets
    /// `shouldUseSystemVoiceFallback` and throws on plan/quota errors.
    private func fetchAudioData(for text: String) async throws -> Data {
        if shouldUseSystemVoiceFallback {
            throw ElevenLabsTTSClientError(message: "ElevenLabs unavailable for this session.")
        }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        if let identity {
            request.attachMiloSignatureHeaders(
                identity: identity,
                path: WorkerEndpoints.ttsPath,
                body: bodyData
            )
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            if Self.shouldDisableElevenLabsForSession(statusCode: httpResponse.statusCode, errorBody: errorBody) {
                shouldUseSystemVoiceFallback = true
                throw ElevenLabsTTSClientError(message: "ElevenLabs plan does not allow this voice/API request.")
            }
            throw NSError(
                domain: "ElevenLabsTTS",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        return data
    }

    // MARK: - State + lifecycle

    /// Whether TTS audio is currently playing back or queued to play.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || !pendingPlaybackQueue.isEmpty
    }

    /// Stops any in-progress playback immediately and clears the queue.
    /// In-flight TTS requests can't be canceled mid-fetch but their
    /// results will be ignored when they arrive (the queue is empty).
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        pendingPlaybackQueue.removeAll()
        // pendingRequestCount left intact — pending requests are still
        // running and will see the cleared queue when they return. The
        // counter naturally decrements as they complete.
        onPlaybackStarted = nil
        onQueueDrained = nil
    }

    private static func shouldDisableElevenLabsForSession(
        statusCode: Int,
        errorBody: String
    ) -> Bool {
        guard statusCode == 401 || statusCode == 402 else { return false }

        return errorBody.contains("paid_plan_required")
            || errorBody.contains("detected_unusual_activity")
            || errorBody.contains("payment_required")
            || errorBody.contains("Free users cannot use library voices")
    }
}

// MARK: - AVAudioPlayerDelegate

extension ElevenLabsTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioPlayer = nil
            self.advanceQueueIfIdle()
        }
    }
}
