//
//  OnboardingController.swift
//  leanring-buddy
//
//  Owns the onboarding video player + the streaming "press control + option
//  to talk" prompt bubble that follows. KVO/notification observers, the 40s
//  demo trigger callback, and fade-in/out timers all live here. The demo
//  interaction itself stays in CompanionManager because it cross-cuts AI,
//  vision capture, and cursor-overlay state — this controller only fires
//  the trigger callback at the right moment.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class OnboardingController: ObservableObject {

    private static let videoStreamURL = "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8"
    private static let demoTriggerSeconds: Double = 40
    private static let videoFadeInDelay: TimeInterval = 0.2
    private static let videoAudioFadeDurationSeconds: Double = 2.0
    private static let videoFadeOutHoldSeconds: TimeInterval = 2.0
    private static let promptBubbleDelaySeconds: TimeInterval = 0.3
    private static let promptStreamCharacterInterval: TimeInterval = 0.03
    private static let promptAutoDismissSeconds: TimeInterval = 10.0
    private static let promptMessage = "press control + option to talk, or control + command to type"

    // MARK: - Video state

    @Published private(set) var videoPlayer: AVPlayer?
    @Published private(set) var isVideoVisible: Bool = false
    @Published private(set) var videoOpacity: Double = 0.0

    // MARK: - Prompt bubble state

    @Published private(set) var promptText: String = ""
    @Published private(set) var promptOpacity: Double = 0.0
    @Published private(set) var isPromptVisible: Bool = false

    // MARK: - Observers

    private var videoEndObserver: NSObjectProtocol?
    private var demoTimeObserver: Any?

    /// Closure invoked when the 40-second demo trigger fires. Owner sets
    /// this so CompanionManager can perform its vision+AI+cursor work
    /// without this controller needing to know about any of it.
    var onDemoTrigger: (@MainActor () -> Void)?

    /// Closure invoked the moment the video finishes playing (before fade-out
    /// hold). Owner uses this to fire completion analytics — the controller
    /// itself stays analytics-agnostic.
    var onVideoEnded: (@MainActor () -> Void)?

    // MARK: - Video lifecycle

    /// Starts the onboarding video at low opacity then fades in. Schedules
    /// the demo trigger at 40s and the cleanup at end-of-playback.
    func startVideo() {
        guard let videoURL = URL(string: Self.videoStreamURL) else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.videoPlayer = player
        self.isVideoVisible = true
        self.videoOpacity = 0.0

        player.play()

        // Mount delay so SwiftUI has the view in the tree before we set
        // the visible-opacity target.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.videoFadeInDelay) { [weak self] in
            guard let self else { return }
            self.videoOpacity = 1.0
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: Self.videoAudioFadeDurationSeconds)
        }

        let demoTriggerTime = CMTime(seconds: Self.demoTriggerSeconds, preferredTimescale: 600)
        demoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.onDemoTrigger?()
            }
        }

        videoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVideoEnded()
            }
        }
    }

    /// Tears down the video player + observers immediately. Idempotent.
    func stopVideo() {
        isVideoVisible = false

        if let demoTimeObserver, let player = videoPlayer {
            player.removeTimeObserver(demoTimeObserver)
        }
        demoTimeObserver = nil

        videoPlayer?.pause()
        videoPlayer = nil

        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
        }
        videoEndObserver = nil
    }

    private func handleVideoEnded() {
        onVideoEnded?()
        videoOpacity = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.videoFadeOutHoldSeconds) { [weak self] in
            guard let self else { return }
            self.stopVideo()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptBubbleDelaySeconds) { [weak self] in
                self?.startPromptStream()
            }
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration. Pure helper — `player` is the
    /// only captured reference (no `self`) so this is safe to fire from a
    /// dispatched closure.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Prompt bubble

    /// Streams the prompt message character-by-character onto the cursor,
    /// then auto-dismisses after the configured hold.
    func startPromptStream() {
        promptText = ""
        isPromptVisible = true
        promptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            promptOpacity = 1.0
        }

        var currentIndex = 0
        let message = Self.promptMessage
        Timer.scheduledTimer(withTimeInterval: Self.promptStreamCharacterInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard currentIndex < message.count else {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptAutoDismissSeconds) { [weak self] in
                        self?.dismissPromptIfVisible()
                    }
                    return
                }
                let index = message.index(message.startIndex, offsetBy: currentIndex)
                self.promptText.append(message[index])
                currentIndex += 1
            }
        }
    }

    /// Cancels an in-flight prompt bubble immediately (used when the user
    /// starts interacting before the auto-dismiss window).
    func dismissPromptIfVisible() {
        guard isPromptVisible else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            promptOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.isPromptVisible = false
            self.promptText = ""
        }
    }
}
