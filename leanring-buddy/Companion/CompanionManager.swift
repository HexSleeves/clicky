//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

struct GuidedActionProposal: Identifiable, Equatable {
    enum ActionType: Equatable {
        case clickTarget
    }

    enum State: Equatable {
        case proposed
        case executing
        case cancelled
        case completedByUser
        case completedByClicky
    }

    let id = UUID()
    let actionType: ActionType
    let targetScreenLocation: CGPoint
    let targetDisplayFrame: CGRect
    let targetLabel: String
    let instruction: String
    let screenNumber: Int?
    var state: State = .proposed
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    @Published private(set) var guidedActionProposal: GuidedActionProposal?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?
    private var fallbackSpeechSynthesizer: AVSpeechSynthesizer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let textInputPanelManager = CompanionTextInputPanelManager()

    // MARK: - Phase 1 senior-side composition (eng review decisions #1, #5, #6)
    //
    // CompanionManager owns the existing Claude voice loop. The managers
    // below own the Phase 1 senior-side concerns; composition keeps them
    // independently testable (see leanring-buddyTests/RoleManagerTests etc.)
    // while CompanionManager remains the single point of wiring.
    let audioSessionCoordinator = AudioSessionCoordinator()
    let roleManager = RoleManager()
    let pairingManager = PairingManager()
    let blocklistMonitor = BlocklistMonitor()
    lazy var remoteSessionManager: RemoteSessionManager = RemoteSessionManager(
        audioSessionCoordinator: audioSessionCoordinator,
        blocklistMonitor: blocklistMonitor
    )

    /// Senior-side: window controller that hosts SeniorConsentDialogView
    /// when the kid requests a help session. Lazy because most launches
    /// won't see one and we don't want to allocate the AppKit shell up
    /// front.
    lazy var seniorConsentDialogWindowController = SeniorConsentDialogWindowController()

    /// Kid-side: floating NSWindow that displays incoming snaps from
    /// the senior's Mac. Lazy for the same reason. Click handler is
    /// wired in `wireRemoteHelpSurfaces()`.
    lazy var kidSidePreviewWindowController = KidSidePreviewWindowController()

    /// Persistent user-supplied memory. Surfaced into Claude's system prompt so
    /// every conversation starts with the user's saved context.
    let notesStore = NotesStore()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WORKER_BASE_URL")
        ?? "https://clicky-proxy.lecoqjosephjacob.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Lazy pairing client. Same Worker base URL as the rest of the
    /// proxy traffic. Surfaced as a method (not a stored property) so
    /// pairing UI views construct an instance scoped to their own
    /// async task and we don't keep a long-lived URLSession bound to
    /// the manager.
    func makePairingNetworkClient() -> PairingNetworkClient {
        PairingNetworkClient(workerBaseURLString: Self.workerBaseURL)
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var typeToTalkShortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User-selected cursor color. Drives every overlay accent (triangle, glow,
    /// waveform, spinner, navigation bubbles) plus the panel logo and the
    /// floating text-input chip. Persisted so the choice survives relaunches.
    @Published var selectedCursorColor: CursorColorOption = {
        guard let storedRawValue = UserDefaults.standard.string(forKey: "selectedCursorColor"),
              let storedOption = CursorColorOption(rawValue: storedRawValue) else {
            return .blue
        }
        return storedOption
    }()

    func setSelectedCursorColor(_ cursorColor: CursorColorOption) {
        selectedCursorColor = cursorColor
        UserDefaults.standard.set(cursorColor.rawValue, forKey: "selectedCursorColor")
    }

    // MARK: - Monthly Usage Tracking

    /// Soft "free plan" caps shown on the Settings popover. Not enforced —
    /// they exist purely so the progress bars render with meaningful
    /// denominators. Tweak these if you ever introduce real billing.
    static let monthlyVoiceMessageCap: Int = 100
    static let monthlyAgentMessageCap: Int = 35

    /// Number of voice/text prompts the user has sent this period.
    /// Resets to 0 when `monthlyUsagePeriodStart` rolls over (every 30 days).
    @Published private(set) var monthlyVoiceMessageCount: Int = UserDefaults.standard.integer(forKey: "monthlyVoiceMessageCount")

    /// Number of Claude responses received this period.
    @Published private(set) var monthlyAgentMessageCount: Int = UserDefaults.standard.integer(forKey: "monthlyAgentMessageCount")

    /// Anchor for the rolling 30-day usage period. The Settings card shows
    /// "resets in Xd Yh" relative to `monthlyUsagePeriodStart + 30 days`.
    @Published private(set) var monthlyUsagePeriodStart: Date = {
        let storedTimestamp = UserDefaults.standard.double(forKey: "monthlyUsagePeriodStart")
        if storedTimestamp > 0 {
            return Date(timeIntervalSince1970: storedTimestamp)
        }
        // First launch — anchor the period to "now" and stash it so the
        // countdown stays consistent across launches.
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "monthlyUsagePeriodStart")
        return now
    }()

    private static let monthlyUsagePeriodLength: TimeInterval = 60 * 60 * 24 * 30

    /// Date the current usage period rolls over and the counts reset.
    var monthlyUsagePeriodEnd: Date {
        monthlyUsagePeriodStart.addingTimeInterval(Self.monthlyUsagePeriodLength)
    }

    func incrementMonthlyVoiceMessageCount() {
        rolloverMonthlyUsagePeriodIfNeeded()
        monthlyVoiceMessageCount += 1
        UserDefaults.standard.set(monthlyVoiceMessageCount, forKey: "monthlyVoiceMessageCount")
    }

    func incrementMonthlyAgentMessageCount() {
        rolloverMonthlyUsagePeriodIfNeeded()
        monthlyAgentMessageCount += 1
        UserDefaults.standard.set(monthlyAgentMessageCount, forKey: "monthlyAgentMessageCount")
    }

    /// Resets the counters and bumps the period start when the rolling
    /// 30-day window has elapsed. Called before every increment so the
    /// rollover happens lazily without a background timer.
    private func rolloverMonthlyUsagePeriodIfNeeded() {
        guard Date() >= monthlyUsagePeriodEnd else { return }

        monthlyVoiceMessageCount = 0
        monthlyAgentMessageCount = 0
        let newPeriodStart = Date()
        monthlyUsagePeriodStart = newPeriodStart

        let defaults = UserDefaults.standard
        defaults.set(0, forKey: "monthlyVoiceMessageCount")
        defaults.set(0, forKey: "monthlyAgentMessageCount")
        defaults.set(newPeriodStart.timeIntervalSince1970, forKey: "monthlyUsagePeriodStart")
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    @Published var isGuidedActionBypassEnabled: Bool = UserDefaults.standard.bool(forKey: "isGuidedActionBypassEnabled")

    func setGuidedActionBypassEnabled(_ enabled: Bool) {
        isGuidedActionBypassEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isGuidedActionBypassEnabled")
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        wireAudioSessionCoordination()
        wireRemoteHelpSurfaces()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Wires the AudioSessionCoordinator into the dictation manager and
    /// installs the preemption hook so a remote-help session can suspend
    /// an in-flight push-to-talk recording cleanly. Phase 1 only handles
    /// `.pushToTalk` preemption; TTS preemption follows in Lane A when
    /// ElevenLabsTTSClient gets its lifecycle delegate.
    private func wireAudioSessionCoordination() {
        buddyDictationManager.audioSessionCoordinator = audioSessionCoordinator

        audioSessionCoordinator.onPreemption = { [weak self] previousOwner in
            guard let self else { return }
            if previousOwner == .pushToTalk {
                self.buddyDictationManager.cancelCurrentDictation(preserveDraftText: true)
            }
        }
    }

    /// Wires the kid-side preview window's click handler so taps inside
    /// the preview translate (via PreviewClickTranslator) into wire-level
    /// CursorCommand messages routed through RemoteSessionManager.
    /// Also wires the inbound SnapDelivery hook so received snaps land
    /// in the kid's preview window.
    /// Called once during `start()`; the window itself only appears
    /// when `presentKidSidePreviewIfNeeded()` runs.
    private func wireRemoteHelpSurfaces() {
        kidSidePreviewWindowController.onClickInSeniorPixelSpace = { [weak self] translation in
            guard let self else { return }
            let cursorCommand = CursorCommand(
                x: translation.seniorScreenPixelX,
                y: translation.seniorScreenPixelY,
                screenIndex: translation.seniorScreenIndex,
                label: nil
            )
            self.remoteSessionManager.sendCursorCommand(cursorCommand)
        }

        remoteSessionManager.onIncomingSnapDelivery = { [weak self] snapDelivery in
            guard let self else { return }
            // Snap arrival auto-presents the preview window so the kid
            // sees it without having to remember to open it.
            self.kidSidePreviewWindowController.showWindow()
            self.kidSidePreviewWindowController.renderSnapDelivery(snapDelivery)
        }
    }

    /// Senior side: capture the cursor screen, encode HEIC, ship the
    /// bytes to the kid via SnapDelivery. Respects
    /// `RemoteSessionManager.shouldDeliverSnap` so we don't busy-loop
    /// the data channel on rapid input events. Safe to call from any
    /// state — the throttle returns false outside `.active`.
    func captureAndDeliverSnapToKid() async {
        guard remoteSessionManager.shouldDeliverSnap() else { return }
        do {
            let (encodedSnap, screenIndex) =
                try await CompanionScreenCaptureUtility.captureCursorScreenAsEncodedSnap()
            let snapDelivery = SnapDelivery(
                bytesBase64: encodedSnap.bytes.base64EncodedString(),
                format: encodedSnap.format == .heic ? .heic : .jpeg,
                pixelWidth: encodedSnap.pixelWidth,
                pixelHeight: encodedSnap.pixelHeight,
                screenIndex: screenIndex
            )
            remoteSessionManager.sendSnapDelivery(snapDelivery)
        } catch {
            NSLog("[CompanionManager] snap capture/encode failed: \(error)")
        }
    }

    // MARK: - Public API for incoming remote-help requests

    /// Senior-side entrypoint. Called when an incoming help request
    /// arrives from the kid (signaling layer once WebRTC ships). Drives
    /// the consent dialog, then forwards the resolution to
    /// RemoteSessionManager.
    ///
    /// Exposed publicly so any future trigger (signaling notification,
    /// hotword listener, debug button) can invoke the same flow.
    func respondToIncomingRemoteHelpRequest(kidDisplayName: String) {
        remoteSessionManager.requestSession()
        seniorConsentDialogWindowController.presentForIncomingRequest(
            kidName: kidDisplayName,
            onAutoCancelWarning: { [weak self] in
                // Phase 1 design: TTS plays at 4:30 warning Mom the
                // request will close. Keep it short and warm.
                self?.speakConsentTimeoutWarning()
            },
            onResolved: { [weak self] resolution in
                guard let self else { return }
                switch resolution {
                case .accepted:
                    self.remoteSessionManager.handleConsent(.accepted)
                case .declined:
                    self.remoteSessionManager.handleConsent(.declined)
                case .timedOut:
                    self.remoteSessionManager.handleConsent(.timedOut)
                }
            }
        )
    }

    /// Kid-side entrypoint. Surfaces the preview window so the kid can
    /// see Mom's screen as snaps stream in. Idempotent — calling twice
    /// is safe and just brings the window forward.
    func presentKidSidePreviewIfNeeded() {
        kidSidePreviewWindowController.showWindow()
    }

    private func speakConsentTimeoutWarning() {
        let warningCopy = "i'll close this in just a moment if you don't see it. take your time."
        Task {
            try? await elevenLabsTTSClient.speakText(warningCopy)
        }
    }

    /// Senior-mode helper: when the blocklist gate fires, speak a
    /// friendly "I can't see this app right now" line via TTS and
    /// reset state so Mom isn't stuck in the processing spinner.
    /// Uses the same TTS path Claude responses use so the voice and
    /// volume match.
    private func speakBlockedAppNotice(displayReason: String) async {
        // Spoken copy is intentionally short, plain, and reassuring —
        // never blames the user. The displayReason ("banking app
        // detected" etc.) flows in for parity with the kid-side
        // banner, but the spoken version is gentler.
        let blockedAppNotice = "i can't look at this one for safety. switch to a different window and ask me again."
        voiceState = .responding
        defer {
            Task { @MainActor in
                self.voiceState = .idle
            }
        }
        do {
            try await elevenLabsTTSClient.speakText(blockedAppNotice)
        } catch {
            // TTS failure isn't fatal — fall back to the system
            // synthesizer so Mom still hears something.
            let fallbackSynthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: blockedAppNotice)
            fallbackSynthesizer.speak(utterance)
            self.fallbackSpeechSynthesizer = fallbackSynthesizer
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3")
            ?? Bundle.main.url(forResource: "ff", withExtension: "mp3", subdirectory: "Audio")
        else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadeOutOnboardingMusic()
                }
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        // Player is mutated only on MainActor inside the Task hop below.
        // We don't capture `player` directly — we re-fetch from self each tick
        // so the @Sendable closure has no non-Sendable captures.
        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, let activePlayer = self.onboardingMusicPlayer else {
                    timer.invalidate()
                    return
                }
                stepsRemaining -= 1
                activePlayer.volume -= volumeDecrement

                if stepsRemaining <= 0 {
                    timer.invalidate()
                    activePlayer.stop()
                    self.onboardingMusicPlayer = nil
                    self.onboardingMusicFadeTimer = nil
                }
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func replayGuidedActionTarget() {
        guard let guidedActionProposal else { return }

        showOverlayForCurrentInteractionIfNeeded()
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = guidedActionProposal.instruction

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.detectedElementScreenLocation = guidedActionProposal.targetScreenLocation
            self.detectedElementDisplayFrame = guidedActionProposal.targetDisplayFrame
        }
    }

    func markGuidedActionDone() {
        guard guidedActionProposal != nil else { return }
        guidedActionProposal?.state = .completedByUser
        ClickyAnalytics.trackGuidedActionDone()
        self.guidedActionProposal = nil
        clearDetectedElementLocation()
    }

    func performGuidedActionClick() {
        guard var guidedActionProposal else { return }
        guard hasAccessibilityPermission else {
            _ = WindowPositionManager.requestAccessibilityPermission()
            return
        }

        guidedActionProposal.state = .executing
        self.guidedActionProposal = guidedActionProposal
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self else { return }
            Self.postLeftMouseClick(
                at: guidedActionProposal.targetScreenLocation,
                on: guidedActionProposal.targetDisplayFrame
            )
            guidedActionProposal.state = .completedByClicky
            ClickyAnalytics.trackGuidedActionClicked()
            self.guidedActionProposal = nil
            self.clearDetectedElementLocation()
        }
    }

    func cancelGuidedActionProposal() {
        guard guidedActionProposal != nil else { return }
        guidedActionProposal?.state = .cancelled
        ClickyAnalytics.trackGuidedActionCancelled()
        self.guidedActionProposal = nil
        clearDetectedElementLocation()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        textInputPanelManager.hide()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        guidedActionProposal = nil
        shortcutTransitionCancellable?.cancel()
        typeToTalkShortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        typeToTalkShortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .typeToTalkShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleTypeToTalkShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            textInputPanelManager.hide()

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self.incrementMonthlyVoiceMessageCount()

                        // "remember that …" / "save note: …" never goes to Claude — it
                        // becomes a saved note and Clicky just confirms it.
                        if let capturedNoteText = Self.parseNoteCaptureText(from: finalTranscript) {
                            self.captureNote(text: capturedNoteText)
                            return
                        }

                        self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    private func handleTypeToTalkShortcutTransition(_ transition: BuddyTypeToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            transientHideTask?.cancel()
            transientHideTask = nil

            showOverlayForCurrentInteractionIfNeeded()

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
            voiceState = .idle
            clearDetectedElementLocation()
            dismissOnboardingPromptIfNeeded()

            textInputPanelManager.show(
                companionManager: self,
                onSubmit: { [weak self] typedMessage, typedAttachments in
                    self?.submitTypedMessage(typedMessage, attachments: typedAttachments)
                },
                onCancel: { [weak self] in
                    self?.scheduleTransientHideIfNeeded()
                }
            )
        case .released, .none:
            break
        }
    }

    private func showOverlayForCurrentInteractionIfNeeded() {
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    private func dismissOnboardingPromptIfNeeded() {
        guard showOnboardingPrompt else { return }

        withAnimation(.easeOut(duration: 0.3)) {
            onboardingPromptOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    private func submitTypedMessage(_ typedMessage: String, attachments: [Data] = []) {
        let trimmedTypedMessage = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypedMessage.isEmpty else { return }

        lastTranscript = trimmedTypedMessage
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedTypedMessage)
        incrementMonthlyVoiceMessageCount()

        // Note capture works for typed input the same way it works for voice —
        // attachments are ignored when the user is just saving a memory.
        if attachments.isEmpty,
           let capturedNoteText = Self.parseNoteCaptureText(from: trimmedTypedMessage) {
            captureNote(text: capturedNoteText)
            return
        }

        sendTranscriptToClaudeWithScreenshot(
            transcript: trimmedTypedMessage,
            userAttachments: attachments
        )
    }

    // MARK: - Note Capture

    /// Detects a leading "remember that …" / "save note: …" intent and returns
    /// the trailing memory text. Returns nil when the transcript is a normal
    /// question. Case-insensitive; tolerates trailing punctuation in the
    /// trigger phrase ("note:" / "note,") and a few spoken variants.
    static func parseNoteCaptureText(from transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        // The triggers are intentionally specific — a stray "remember when …"
        // story shouldn't accidentally save a note. Order matters: longer
        // prefixes first so "save note that" matches before "save note".
        let noteCapturePrefixes: [String] = [
            "remember that ",
            "remember to ",
            "remember this:",
            "remember:",
            "please remember that ",
            "please remember to ",
            "save a note that ",
            "save a note:",
            "save note that ",
            "save note:",
            "save note ",
            "make a note that ",
            "make a note:",
            "note that ",
            "note:"
        ]

        let lowercasedTranscript = trimmedTranscript.lowercased()
        for prefix in noteCapturePrefixes {
            if lowercasedTranscript.hasPrefix(prefix) {
                let prefixEndIndex = trimmedTranscript.index(trimmedTranscript.startIndex, offsetBy: prefix.count)
                let capturedNoteText = trimmedTranscript[prefixEndIndex...]
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                return capturedNoteText.isEmpty ? nil : capturedNoteText
            }
        }
        return nil
    }

    /// Saves the captured text as a note and gives the user a brief audible
    /// confirmation. We deliberately skip the Claude round-trip so saving a
    /// note feels instant.
    private func captureNote(text: String) {
        guard let savedNote = notesStore.add(text: text) else { return }

        ClickyAnalytics.trackNoteSaved()
        print("📝 Saved note: \(savedNote.text)")

        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
        guidedActionProposal = nil
        detectedElementBubbleText = nil

        let confirmationText = "saved."
        Task { @MainActor in
            do {
                try await elevenLabsTTSClient.speakText(confirmationText)
                voiceState = .responding
            } catch {
                speakSystemVoiceFallback(confirmationText)
            }
            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Companion Prompt

    /// System prompt tuned for senior-mode users (Mom / Dad).
    ///
    /// Derived from the Sunday 2026-05-09 observation session:
    ///   - bad eyesight → bias hard toward pointing, generous phrase
    ///   - moves slowly → one short sentence at a time, no nesting
    ///   - explicit ask: "freely talk with Clicky and have Clicky just
    ///     point things out and guide her"
    ///
    /// Senior-side rules differ from the kid/founder prompt in three
    /// ways: (1) ALWAYS point if there's anything visual to point at,
    /// never `[POINT:none]` when the user is asking a how-do-i;
    /// (2) one short sentence; (3) plain words, no programming jargon
    /// or hedge phrases. Tone matters: she's not a colleague, she's a
    /// patient parent at a computer she only half-understands.
    private static let seniorVoiceResponseSystemPrompt = """
    you're clicky, a patient helper for an older user who can't always see well and moves slowly. she just spoke to you, and you can see her screen. your reply gets spoken out loud, so write the way you'd talk to a parent on the phone — calm, friendly, never rushed. this is an ongoing conversation; you remember what she said before.

    rules:
    - one short sentence is the default. two only if the first one wouldn't be enough. never three.
    - all lowercase, warm, gentle. no emojis.
    - plain everyday words. avoid jargon, abbreviations, and computer terms unless she used them first. if she calls something "the picture thing" or "that blue button," call it the same thing back.
    - never say "simply," "just," "easy," "obvious," "click here" alone, or "you can do that yourself."
    - if she sounds confused, slow down even more. acknowledge first ("yep, that one's tricky") before guiding.
    - if she got something done, say so warmly ("perfect, that's exactly it") so she knows she's on track.
    - don't end with questions like "want me to keep going?" — she'll naturally pause and ask if she needs more. just stop when the step is complete.
    - if she asks something general (weather, recipes, news) just answer briefly and warmly, no pointing needed.

    pointing — this is the most important behavior:
    you have a small cursor that flies to and points at things on screen. she has bad eyesight and finds it very hard to locate things by description, so POINT WHENEVER POSSIBLE. if she's asking how to do anything, where something is, what to click, or how to navigate, you MUST point at the exact element. err strongly on the side of pointing — pointing at the "wrong" thing is recoverable, but a description without a point usually fails her.

    when you point, append the coordinate tag AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space; origin (0,0) is the top-left.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates and label is 1-3 plain words ("the send button", "the file menu"). if the element is on a different monitor than her cursor, append :screenN. only emit [POINT:none] when she's asking a general-knowledge question with no on-screen target.

    one click at a time:
    she does the actual clicking. you only point. never say "i'll click it for you" or claim a click happened. say things like "see the blue button at the top? click that one." short sentence, then the point tag.

    examples:
    - she asks how to send an email: "see the blue send button at the bottom? click that one. [POINT:840,720:the send button]"
    - she asks where her photos are: "your photos live in the left sidebar — that little flower icon. [POINT:36,180:photos]"
    - she asks what time it is: "it's 3:42 in the afternoon. [POINT:none]"
    - she got it right: "perfect, that's exactly it. [POINT:none]"
    - she's stuck on the wrong window: "no worries — click the safari window behind it first. [POINT:1100,40:safari window]"
    """

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk or typed to you from the floating text box, and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    guided actions:
    when the user asks you to click, open, select, press, choose, or show where to click, clicky can perform one click after your response if the app setting allows it or the user confirms it. identify exactly one target and append the point tag for that target. keep the spoken response short, natural, and action-oriented. do not say "you can click it yourself", "click it yourself", or "i can't click". good responses sound like "got it, i'll click the send button." or "i found it — clicking the deploy button." never claim the click already happened before the point tag is processed.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    /// `userAttachments` are extra images the user attached from the text
    /// input pill (paperclip → file picker). They are appended after the
    /// screen captures so Claude reads the screen context first.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        userAttachments: [Data] = []
    ) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
        guidedActionProposal = nil
        detectedElementBubbleText = nil

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Senior-mode privacy gate: if Mom's frontmost app or
                // active URL is on the thin blocklist (banking,
                // password managers, health portals), DO NOT send a
                // screenshot to Claude. Speak a friendly "I can't see
                // this app" instead and bail.
                if roleManager.shouldShowSeniorSurfaces {
                    blocklistMonitor.evaluateNow()
                    if case .blocked(let displayReason) = blocklistMonitor.currentOutcome {
                        await speakBlockedAppNotice(displayReason: displayReason)
                        return
                    }
                }

                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let isGuidedActionRequest = Self.isGuidedActionRequest(transcript)

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                var labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // User-provided attachments are appended AFTER the screen
                // captures so Claude treats them as supplemental references
                // rather than primary screen context.
                for (attachmentIndex, attachmentData) in userAttachments.enumerated() {
                    labeledImages.append((
                        data: attachmentData,
                        label: "User attachment \(attachmentIndex + 1)"
                    ))
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Pick the role-appropriate base prompt. Senior surfaces
                // get the patient-helper prompt with mandatory pointing
                // and one-short-sentence cap. Everyone else gets the
                // existing Clicky prompt. Notes append unchanged.
                let combinedSystemPrompt: String = {
                    let basePrompt = roleManager.shouldShowSeniorSurfaces
                        ? Self.seniorVoiceResponseSystemPrompt
                        : Self.companionVoiceResponseSystemPrompt
                    guard let notesBlock = notesStore.systemPromptBlock() else {
                        return basePrompt
                    }
                    return basePrompt + "\n\n" + notesBlock
                }()

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: combinedSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)

                    if isGuidedActionRequest {
                        let targetLabel = parseResult.elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayLabel = targetLabel?.isEmpty == false ? targetLabel! : "target"
                        let proposal = GuidedActionProposal(
                            actionType: .clickTarget,
                            targetScreenLocation: globalLocation,
                            targetDisplayFrame: displayFrame,
                            targetLabel: displayLabel,
                            instruction: "Click \(displayLabel)",
                            screenNumber: parseResult.screenNumber
                        )
                        guidedActionProposal = proposal
                        detectedElementBubbleText = proposal.instruction
                        ClickyAnalytics.trackGuidedActionProposed()

                        if isGuidedActionBypassEnabled {
                            performGuidedActionClick()
                        } else {
                            NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
                        }
                    }

                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                incrementMonthlyAgentMessageCount()

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs unavailable, using system voice: \(error.localizedDescription)")
                        speakSystemVoiceFallback(spokenText)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakSystemVoiceFallback("I hit an error while trying to answer that.")
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Uses macOS system TTS when ElevenLabs is unavailable.
    /// Uses AVSpeechSynthesizer (replacement for the deprecated NSSpeechSynthesizer).
    private func speakSystemVoiceFallback(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        fallbackSpeechSynthesizer?.stopSpeaking(at: .immediate)
        let synthesizer = AVSpeechSynthesizer()
        fallbackSpeechSynthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: trimmedText)
        synthesizer.speak(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    private static func postLeftMouseClick(at appKitScreenLocation: CGPoint, on displayFrame: CGRect) {
        let quartzEventLocation = CGPoint(
            x: appKitScreenLocation.x,
            y: displayFrame.maxY - appKitScreenLocation.y
        )
        let eventSource = CGEventSource(stateID: .hidSystemState)

        CGWarpMouseCursorPosition(quartzEventLocation)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzEventLocation,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)

        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: quartzEventLocation,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)

        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: quartzEventLocation,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    static func isGuidedActionRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        let guidedActionPhrases = [
            "click",
            "open",
            "select",
            "press",
            "choose",
            "tap",
            "where do i click",
            "show me where",
            "show where",
            "what do i click",
            "which button",
            "which menu"
        ]

        return guidedActionPhrases.contains { normalizedTranscript.contains($0) }
    }

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                ClickyAnalytics.trackOnboardingDemoTriggered()
                self?.performOnboardingDemoInteraction()
            }
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ClickyAnalytics.trackOnboardingVideoCompleted()
                self.onboardingVideoOpacity = 0.0
                // Wait for the 2s fade-out animation to complete before tearing down
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.tearDownOnboardingVideo()
                    // After the video disappears, stream in the prompt to try talking
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.startOnboardingPromptStream()
                    }
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option to talk, or control + command to type"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard currentIndex < message.count else {
                    timer.invalidate()
                    // Auto-dismiss after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        guard self.showOnboardingPrompt else { return }
                        withAnimation(.easeOut(duration: 0.3)) {
                            self.onboardingPromptOpacity = 0.0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            self.showOnboardingPrompt = false
                            self.onboardingPromptText = ""
                        }
                    }
                    return
                }
                let index = message.index(message.startIndex, offsetBy: currentIndex)
                self.onboardingPromptText.append(message[index])
                currentIndex += 1
            }
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
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

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
