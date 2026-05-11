//
//  OnboardingMusicPlayer.swift
//  leanring-buddy
//
//  Owns the "ff.mp3" theme that plays during onboarding plus the fade
//  schedule (1m 30s play, 3s fade-out, stop). Extracted from
//  CompanionManager so the audio lifecycle is isolated from the
//  surrounding state machine and the timer/closure capture story stays
//  simple: this class is single-purpose and @MainActor-isolated, so the
//  fade timer can safely capture [weak self] without the "re-fetch from
//  self each tick" workaround the inline version needed.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class OnboardingMusicPlayer {

    private static let resourceName = "ff"
    private static let resourceExtension = "mp3"
    private static let startVolume: Float = 0.3
    private static let secondsBeforeFade: TimeInterval = 90.0
    private static let fadeDurationSeconds: Double = 3.0
    private static let fadeStepCount = 30

    private var player: AVAudioPlayer?
    private var scheduledTimer: Timer?

    /// Starts (or restarts) the onboarding theme. Plays at low volume,
    /// then auto-fades + stops after the configured window. Safe to call
    /// when already playing — it tears down the previous instance first.
    func start(bundle: Bundle = .main) {
        stop()

        guard let musicURL = bundle.url(forResource: Self.resourceName, withExtension: Self.resourceExtension)
            ?? bundle.url(forResource: Self.resourceName, withExtension: Self.resourceExtension, subdirectory: "Audio")
        else {
            print("⚠️ Milo: \(Self.resourceName).\(Self.resourceExtension) not found in bundle")
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: musicURL)
            newPlayer.volume = Self.startVolume
            newPlayer.play()
            self.player = newPlayer

            scheduledTimer = Timer.scheduledTimer(
                withTimeInterval: Self.secondsBeforeFade,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadeOut()
                }
            }
        } catch {
            print("⚠️ Milo: Failed to play onboarding music: \(error)")
        }
    }

    /// Immediately stops playback and cancels any scheduled fade. Idempotent.
    func stop() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        player?.stop()
        player = nil
    }

    /// Smooth volume rampdown then stop. Called automatically at the end of
    /// the play window; callers should use `stop()` for immediate halts.
    private func fadeOut() {
        guard let player else { return }

        let stepInterval = Self.fadeDurationSeconds / Double(Self.fadeStepCount)
        let volumeDecrement = player.volume / Float(Self.fadeStepCount)
        var stepsRemaining = Self.fadeStepCount

        // Use `self.scheduledTimer?.invalidate()` instead of capturing
        // the Timer parameter inside the @MainActor Task body — `Timer`
        // is non-Sendable and capturing it across the Task boundary is
        // an error under Swift 6 strict concurrency.
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let activePlayer = self.player else {
                    self.scheduledTimer?.invalidate()
                    self.scheduledTimer = nil
                    return
                }
                stepsRemaining -= 1
                activePlayer.volume -= volumeDecrement

                if stepsRemaining <= 0 {
                    self.scheduledTimer?.invalidate()
                    activePlayer.stop()
                    self.player = nil
                    self.scheduledTimer = nil
                }
            }
        }
    }
}
