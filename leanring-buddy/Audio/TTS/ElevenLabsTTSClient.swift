//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
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
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession
    private var shouldUseSystemVoiceFallback = false

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
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

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
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
