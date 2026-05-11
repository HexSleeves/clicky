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
        case completedByMilo
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

    // MARK: - Onboarding Video + Prompt
    //
    // State + observers + fade timers live in OnboardingController.
    // CompanionManager exposes forwarding computed properties so OverlayWindow
    // keeps reading `companionManager.onboardingVideoPlayer` etc. unchanged.
    // The 40s demo trigger is wired below as a closure that calls
    // `performOnboardingDemoInteraction()` here — keeping AI/vision/cursor
    // cross-cutting work in the orchestrator where it belongs.

    let onboardingController = OnboardingController()
    private var onboardingControllerCancellable: AnyCancellable?

    /// User-facing error toaster. Service code presents MiloError values
    /// here; the panel renders the toast and offers the recovery CTA.
    let errorPresenter = MiloErrorPresenter()
    private var errorPresenterCancellable: AnyCancellable?

    var onboardingVideoPlayer: AVPlayer? { onboardingController.videoPlayer }
    var showOnboardingVideo: Bool { onboardingController.isVideoVisible }
    var onboardingVideoOpacity: Double { onboardingController.videoOpacity }
    var onboardingPromptText: String { onboardingController.promptText }
    var onboardingPromptOpacity: Double { onboardingController.promptOpacity }
    var showOnboardingPrompt: Bool { onboardingController.isPromptVisible }

    // MARK: - Onboarding Music

    private let onboardingMusicPlayer = OnboardingMusicPlayer()

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let textInputPanelManager = CompanionTextInputPanelManager()

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

    private lazy var speechPipeline: SpeechPipeline = {
        return SpeechPipeline(workerBaseURL: Self.workerBaseURL)
    }()

    /// One round-trip exchange retained for in-session memory. Surfaced
    /// publicly so the Settings popover can render "what Milo remembers"
    /// and offer a Clear button.
    struct ConversationExchange: Identifiable, Equatable {
        let id = UUID()
        let userTranscript: String
        let assistantResponse: String
        let createdAt: Date
    }

    /// Conversation history so Claude remembers prior exchanges within a
    /// session. Capped at the last 10 exchanges. Cleared by quit/relaunch
    /// or by the user via the Settings popover's Clear button.
    @Published private(set) var conversationHistory: [ConversationExchange] = []

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
    //
    // Counters + rollover live in UsageBudget; we forward the existing
    // public surface here so view files keep reading
    // `companionManager.monthly…` unchanged. When the budget changes, its
    // objectWillChange is re-emitted via Combine in init so SwiftUI
    // re-renders the Settings popover automatically.

    let usageBudget = UsageBudget()
    private var usageBudgetCancellable: AnyCancellable?

    static var monthlyVoiceMessageCap: Int { UsageBudget.voiceMessageCap }
    static var monthlyAgentMessageCap: Int { UsageBudget.agentMessageCap }

    var monthlyVoiceMessageCount: Int { usageBudget.voiceMessageCount }
    var monthlyAgentMessageCount: Int { usageBudget.agentMessageCount }
    var monthlyUsagePeriodStart: Date { usageBudget.periodStart }
    var monthlyUsagePeriodEnd: Date { usageBudget.periodEnd }

    func incrementMonthlyVoiceMessageCount() {
        usageBudget.incrementVoiceMessageCount()
    }

    func incrementMonthlyAgentMessageCount() {
        usageBudget.incrementAgentMessageCount()
    }

    /// Wipes the in-session conversation history Claude sees on each turn.
    /// Persistent saved notes are untouched. Called from the Settings
    /// popover's Clear button.
    func clearConversation() {
        conversationHistory.removeAll()
        MiloAnalytics.trackConversationCleared()
    }

    /// User preference for whether the Milo cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isMiloCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isMiloCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isMiloCursorEnabled")

    @Published var isGuidedActionBypassEnabled: Bool = UserDefaults.standard.bool(forKey: "isGuidedActionBypassEnabled")

    func setGuidedActionBypassEnabled(_ enabled: Bool) {
        isGuidedActionBypassEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isGuidedActionBypassEnabled")
    }

    func setMiloCursorEnabled(_ enabled: Bool) {
        isMiloCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isMiloCursorEnabled")
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
        print("🔑 Milo start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindUsageBudget()
        bindOnboardingController()
        bindErrorPresenter()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isMiloCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .miloDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        MiloAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        onboardingMusicPlayer.start()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .miloDismissPanel, object: nil)
        MiloAnalytics.trackOnboardingReplayed()
        onboardingMusicPlayer.start()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
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
        MiloAnalytics.trackGuidedActionDone()
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
        NotificationCenter.default.post(name: .miloDismissPanel, object: nil)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self else { return }
            Self.postLeftMouseClick(
                at: guidedActionProposal.targetScreenLocation,
                on: guidedActionProposal.targetDisplayFrame
            )
            guidedActionProposal.state = .completedByMilo
            MiloAnalytics.trackGuidedActionClicked()
            self.guidedActionProposal = nil
            self.clearDetectedElementLocation()
        }
    }

    func cancelGuidedActionProposal() {
        guard guidedActionProposal != nil else { return }
        guidedActionProposal?.state = .cancelled
        MiloAnalytics.trackGuidedActionCancelled()
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
            MiloAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            MiloAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            MiloAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            MiloAnalytics.trackAllPermissionsGranted()
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
                    MiloAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isMiloCursorEnabled {
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

    /// Re-emits `usageBudget.objectWillChange` so the Settings popover
    /// (which binds to `CompanionManager`) re-renders when counters or the
    /// period start change. SwiftUI doesn't bubble nested ObservableObjects.
    private func bindUsageBudget() {
        usageBudgetCancellable = usageBudget.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// Re-emits `onboardingController.objectWillChange` so OverlayWindow
    /// re-renders when the video player, opacity, or prompt text change.
    /// Also installs the demo trigger callback that kicks off the 40s
    /// cursor-pointing demo (which crosses AI + vision + cursor state).
    private func bindOnboardingController() {
        onboardingControllerCancellable = onboardingController.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        onboardingController.onDemoTrigger = { [weak self] in
            MiloAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        onboardingController.onVideoEnded = {
            MiloAnalytics.trackOnboardingVideoCompleted()
        }
    }

    /// Re-emits `errorPresenter.objectWillChange` so panel observers see
    /// toast presentation through the parent companion manager binding.
    private func bindErrorPresenter() {
        errorPresenterCancellable = errorPresenter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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
            if !isMiloCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .miloDismissPanel, object: nil)
            textInputPanelManager.hide()

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            speechPipeline.stop()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            onboardingController.dismissPromptIfVisible()

            MiloAnalytics.trackPushToTalkStarted()

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
                        MiloAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self.incrementMonthlyVoiceMessageCount()

                        // "remember that …" / "save note: …" never goes to Claude — it
                        // becomes a saved note and Milo just confirms it.
                        if let capturedNoteText = NoteCaptureRouter.parseNoteCaptureText(from: finalTranscript) {
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
            MiloAnalytics.trackPushToTalkReleased()
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

            NotificationCenter.default.post(name: .miloDismissPanel, object: nil)
            currentResponseTask?.cancel()
            speechPipeline.stop()
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
        onboardingController.dismissPromptIfVisible()
    }

    private func submitTypedMessage(_ typedMessage: String, attachments: [Data] = []) {
        let trimmedTypedMessage = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypedMessage.isEmpty else { return }

        lastTranscript = trimmedTypedMessage
        MiloAnalytics.trackUserMessageSent(transcript: trimmedTypedMessage)
        incrementMonthlyVoiceMessageCount()

        // Note capture works for typed input the same way it works for voice —
        // attachments are ignored when the user is just saving a memory.
        if attachments.isEmpty,
           let capturedNoteText = NoteCaptureRouter.parseNoteCaptureText(from: trimmedTypedMessage) {
            captureNote(text: capturedNoteText)
            return
        }

        sendTranscriptToClaudeWithScreenshot(
            transcript: trimmedTypedMessage,
            userAttachments: attachments
        )
    }

    // MARK: - Note Capture

    /// Saves the captured text as a note and gives the user a brief audible
    /// confirmation. We deliberately skip the Claude round-trip so saving a
    /// note feels instant.
    private func captureNote(text: String) {
        guard let savedNote = notesStore.add(text: text) else { return }

        MiloAnalytics.trackNoteSaved()
        print("📝 Saved note: \(savedNote.text)")

        currentResponseTask?.cancel()
        speechPipeline.stop()
        guidedActionProposal = nil
        detectedElementBubbleText = nil

        let confirmationText = "saved."
        Task { @MainActor in
            let outcome = await speechPipeline.speak(confirmationText)
            if case .skippedEmpty = outcome {} else {
                voiceState = .responding
            }
            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

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
        speechPipeline.stop()
        guidedActionProposal = nil
        detectedElementBubbleText = nil

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let isGuidedActionRequest = PointTagParser.isGuidedActionRequest(transcript)

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

                let combinedSystemPrompt = CompanionSystemPrompt.build(
                    notesBlock: notesStore.systemPromptBlock()
                )

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
                let parseResult = PointTagParser.parse(fullResponseText)
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
                    let displayFrame = targetScreenCapture.displayFrame
                    let globalLocation = CoordinateTranslator.screenshotPointToAppKitGlobal(
                        screenshotPoint: pointCoordinate,
                        screenshotSize: CGSize(
                            width: CGFloat(targetScreenCapture.screenshotWidthInPixels),
                            height: CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        ),
                        displaySize: CGSize(
                            width: CGFloat(targetScreenCapture.displayWidthInPoints),
                            height: CGFloat(targetScreenCapture.displayHeightInPoints)
                        ),
                        displayFrame: displayFrame
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    MiloAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)

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
                        MiloAnalytics.trackGuidedActionProposed()

                        if isGuidedActionBypassEnabled {
                            performGuidedActionClick()
                        } else {
                            NotificationCenter.default.post(name: .miloShowPanel, object: nil)
                        }
                    }

                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append(ConversationExchange(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    createdAt: Date()
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                MiloAnalytics.trackAIResponseReceived(response: spokenText)
                incrementMonthlyAgentMessageCount()

                // Play the response via speech pipeline (ElevenLabs primary,
                // system fallback on failure). Switch to responding once
                // playback has actually started.
                let speakOutcome = await speechPipeline.speak(spokenText)
                switch speakOutcome {
                case .elevenLabs, .systemFallback:
                    voiceState = .responding
                case .skippedEmpty:
                    break
                }
                if case let .systemFallback(error) = speakOutcome {
                    MiloAnalytics.trackTTSError(error: error.localizedDescription)
                    print("⚠️ ElevenLabs unavailable, using system voice: \(error.localizedDescription)")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                MiloAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                _ = await speechPipeline.speak("I hit an error while trying to answer that.")
                voiceState = .responding
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Milo" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isMiloCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while speechPipeline.isPlaying {
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

    // Point tag parsing + guided-action heuristic live in PointTagParser.

    // MARK: - Onboarding Video

    func setupOnboardingVideo() {
        onboardingController.startVideo()
    }

    func tearDownOnboardingVideo() {
        onboardingController.stopVideo()
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're milo, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

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

                let parseResult = PointTagParser.parse(fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let displayFrame = cursorScreenCapture.displayFrame
                let globalLocation = CoordinateTranslator.screenshotPointToAppKitGlobal(
                    screenshotPoint: pointCoordinate,
                    screenshotSize: CGSize(
                        width: CGFloat(cursorScreenCapture.screenshotWidthInPixels),
                        height: CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                    ),
                    displaySize: CGSize(
                        width: CGFloat(cursorScreenCapture.displayWidthInPoints),
                        height: CGFloat(cursorScreenCapture.displayHeightInPoints)
                    ),
                    displayFrame: displayFrame
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
