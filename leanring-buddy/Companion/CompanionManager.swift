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
        /// Legacy single-click target parsed from a `[POINT:x,y:label]` tag.
        /// Auto-bypassable when the user has the setting on.
        case clickTarget
        /// Multi-step sequence parsed from a `[ACTION:{...}]` tag. May
        /// include type/keypress/scroll steps. Always requires confirmation
        /// unless `MiloAction.isSafeForAutoBypass` is also true (single-step
        /// click/point only).
        case multiStep(MiloAction)
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
    /// Anchor for the cursor preview flight. For `.clickTarget` this is the
    /// click target. For `.multiStep` this is the first visual step's
    /// resolved location (click/scroll/point) — or `nil` if the sequence
    /// has no on-screen anchor (e.g. a pure ⌘S keypress).
    let targetScreenLocation: CGPoint?
    let targetDisplayFrame: CGRect?
    let targetLabel: String
    let instruction: String
    let screenNumber: Int?
    var state: State = .proposed

    /// Convenience: true when this proposal is a multi-step action that
    /// requires the executor rather than a single-click postLeftMouseClick.
    var isMultiStep: Bool {
        if case .multiStep = actionType { return true }
        return false
    }

    /// Convenience: the embedded `MiloAction` if this is a multi-step
    /// proposal, nil otherwise.
    var multiStepAction: MiloAction? {
        if case let .multiStep(action) = actionType { return action }
        return nil
    }
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

    /// Persistent analytics consent state. Drives `MiloAnalytics.capture`'s
    /// gate. Pre-decision allowlist still fires (app_opened, video done).
    /// Assigned to `MiloAnalytics.consent` on `start()` so the static enum
    /// consults the same instance the UI binds to.
    let analyticsConsent = AnalyticsConsent()

    /// Per-install Ed25519 keypair backed by Keychain. Drives signed
    /// Worker requests once the Worker side enforces (Stage C). Today
    /// (Stage A) we just register on first launch so the Worker can
    /// dashboard the unsigned-request rate.
    let installIdentity = InstallIdentity()

    private lazy var installRegistrar: InstallRegistrar = {
        return InstallRegistrar(identity: installIdentity, workerBaseURL: WorkerEndpoints.baseURL)
    }()

    /// Set after the onboarding video ends until the user makes a
    /// consent decision. Overlay observes this to render the prompt card.
    @Published private(set) var shouldShowAnalyticsConsentPrompt: Bool = false

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

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(
            proxyURL: WorkerEndpoints.chatURL,
            model: selectedModel,
            identity: installIdentity
        )
    }()

    private lazy var speechPipeline: SpeechPipeline = {
        return SpeechPipeline(
            workerBaseURL: WorkerEndpoints.baseURL,
            identity: installIdentity
        )
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

    /// Screen captures from the most recent Claude response. Stashed so the
    /// guided-action executor can resolve per-step `screen` indices to
    /// AppKit-global coordinates when the user confirms a multi-step
    /// `[ACTION:...]` sequence. Cleared when the proposal is dismissed.
    private var lastGuidedActionScreenCaptures: [CompanionScreenCapture] = []

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
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: PersistenceKeys.selectedClaudeModel) ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: PersistenceKeys.selectedClaudeModel)
        claudeAPI.model = model
    }

    /// User-selected cursor color. Drives every overlay accent (triangle, glow,
    /// waveform, spinner, navigation bubbles) plus the panel logo and the
    /// floating text-input chip. Persisted so the choice survives relaunches.
    @Published var selectedCursorColor: CursorColorOption = {
        guard let storedRawValue = UserDefaults.standard.string(forKey: PersistenceKeys.selectedCursorColor),
              let storedOption = CursorColorOption(rawValue: storedRawValue) else {
            return .blue
        }
        return storedOption
    }()

    func setSelectedCursorColor(_ cursorColor: CursorColorOption) {
        selectedCursorColor = cursorColor
        UserDefaults.standard.set(cursorColor.rawValue, forKey: PersistenceKeys.selectedCursorColor)
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
    @Published var isMiloCursorEnabled: Bool = UserDefaults.standard.object(forKey: PersistenceKeys.isMiloCursorEnabled) == nil
        ? true
        : UserDefaults.standard.bool(forKey: PersistenceKeys.isMiloCursorEnabled)

    @Published var isGuidedActionBypassEnabled: Bool = UserDefaults.standard.bool(forKey: PersistenceKeys.isGuidedActionBypassEnabled)

    func setGuidedActionBypassEnabled(_ enabled: Bool) {
        isGuidedActionBypassEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PersistenceKeys.isGuidedActionBypassEnabled)
    }

    func setMiloCursorEnabled(_ enabled: Bool) {
        isMiloCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PersistenceKeys.isMiloCursorEnabled)
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
        get { UserDefaults.standard.bool(forKey: PersistenceKeys.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: PersistenceKeys.hasCompletedOnboarding) }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: PersistenceKeys.hasSubmittedEmail)

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: PersistenceKeys.hasSubmittedEmail)

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
        // Make the static analytics gate consult this manager's consent
        // store so granting in one place is visible everywhere.
        MiloAnalytics.consent = analyticsConsent

        // Fire-and-forget install registration. Idempotent: short-circuits
        // when we already have an install ID. Stage A is observe-only,
        // so failure here just means the Worker logs an unsigned request.
        Task { [weak self] in
            await self?.installRegistrar.registerIfNeeded()
        }

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
            // Multi-step actions without an on-screen anchor (e.g. pure ⌘S)
            // leave the cursor where it is rather than flying it to a
            // sentinel location.
            if let anchor = guidedActionProposal.targetScreenLocation,
               let displayFrame = guidedActionProposal.targetDisplayFrame {
                self.detectedElementScreenLocation = anchor
                self.detectedElementDisplayFrame = displayFrame
            }
        }
    }

    func markGuidedActionDone() {
        guard guidedActionProposal != nil else { return }
        guidedActionProposal?.state = .completedByUser
        MiloAnalytics.trackGuidedActionDone()
        self.guidedActionProposal = nil
        self.lastGuidedActionScreenCaptures = []
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
            switch guidedActionProposal.actionType {
            case .clickTarget:
                if let location = guidedActionProposal.targetScreenLocation,
                   let displayFrame = guidedActionProposal.targetDisplayFrame {
                    Self.postLeftMouseClick(at: location, on: displayFrame)
                }
            case .multiStep(let action):
                let captures = self.lastGuidedActionScreenCaptures
                await MiloActionExecutor.execute(action) { screenshotPoint, screenNumber in
                    Self.resolveScreenshotCoordinate(
                        screenshotPoint: screenshotPoint,
                        screenNumber: screenNumber,
                        screenCaptures: captures
                    )
                }
            }
            guidedActionProposal.state = .completedByMilo
            MiloAnalytics.trackGuidedActionClicked()
            self.guidedActionProposal = nil
            self.lastGuidedActionScreenCaptures = []
            self.clearDetectedElementLocation()
        }
    }

    func cancelGuidedActionProposal() {
        guard guidedActionProposal != nil else { return }
        guidedActionProposal?.state = .cancelled
        MiloAnalytics.trackGuidedActionCancelled()
        self.guidedActionProposal = nil
        self.lastGuidedActionScreenCaptures = []
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
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: PersistenceKeys.hasScreenContentPermission)
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
                    UserDefaults.standard.set(true, forKey: PersistenceKeys.hasScreenContentPermission)
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

        onboardingController.onVideoEnded = { [weak self] in
            MiloAnalytics.trackOnboardingVideoCompleted()
            self?.surfaceAnalyticsConsentPromptIfNeeded()
        }
    }

    /// Shows the consent card when the user hasn't decided yet. Called
    /// from the onboarding video's end callback so timing is "after video
    /// ends, before the post-video interactive moment", per the locked
    /// T0.5 design decision.
    private func surfaceAnalyticsConsentPromptIfNeeded() {
        guard analyticsConsent.state == .undecided else { return }
        shouldShowAnalyticsConsentPrompt = true
    }

    /// Called from the consent prompt's Grant/Deny buttons.
    func handleAnalyticsConsentDecision(granted: Bool) {
        if granted {
            analyticsConsent.grant()
        } else {
            analyticsConsent.deny()
        }
        shouldShowAnalyticsConsentPrompt = false
        MiloAnalytics.trackAnalyticsConsentDecided(granted: granted)
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

                // Sentence-chunked TTS: stream Claude's response and fire
                // a TTS request as soon as each sentence terminator + space
                // arrives. The first sentence's audio plays while later
                // sentences are still being generated, cutting perceived
                // latency roughly in half on multi-sentence responses.
                let sentenceSplitter = SentenceSplitter()
                speechPipeline.setOnFirstPlaybackStarted { [weak self] in
                    self?.voiceState = .responding
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: combinedSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] chunk in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            for sentence in sentenceSplitter.consume(chunk) {
                                self.enqueueSentenceForTTSIfSpeakable(sentence)
                            }
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                // End-of-stream: flush the remainder (which likely contains
                // any trailing `[POINT:...]` or `[ACTION:{...}]` tag glued to
                // the last sentence). Strip whichever tag is present, enqueue
                // the residual spoken text if non-empty.
                if let remainder = sentenceSplitter.flushRemainder() {
                    let trailing = stripTrailingActionOrPointTag(remainder)
                    enqueueSentenceForTTSIfSpeakable(trailing)
                }

                // Try the new [ACTION:{...}] grammar first; fall back to the
                // legacy [POINT:...] tag if no action was parsed. Both
                // formats coexist so older prompt iterations or Claude
                // responses that reverted to the simpler form still work.
                let actionParseResult = MiloActionParser.parse(fullResponseText)
                let spokenText: String

                if let action = actionParseResult.action {
                    spokenText = actionParseResult.spokenText
                    handleParsedAction(
                        action,
                        screenCaptures: screenCaptures
                    )
                } else {
                    // Parse the [POINT:...] tag from Claude's response
                    let parseResult = PointTagParser.parse(fullResponseText)
                    spokenText = parseResult.spokenText

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
                } // end of `else` (legacy [POINT:...] branch)

                // Save this exchange to conversation history (with the trailing
                // tag stripped so it doesn't confuse future context)
                appendConversationHistory(
                    transcript: transcript,
                    assistantResponse: spokenText
                )

                MiloAnalytics.trackAIResponseReceived(response: spokenText)
                incrementMonthlyAgentMessageCount()
                // Streaming TTS already kicked off audio as sentences arrived.
                // voiceState flipped to .responding via the
                // setOnFirstPlaybackStarted callback. Nothing else to do
                // here — scheduleTransientHideIfNeeded later polls
                // speechPipeline.isPlaying to wait for the queue to drain
                // before fading the cursor out.

                // Session-level fallback: if ElevenLabs rejected every
                // chunk (paid-plan-required, etc.), `isInElevenLabsFallbackMode`
                // is true and nothing played. Speak the full response via
                // macOS system voice so the user hears the answer instead
                // of silence.
                if speechPipeline.isInElevenLabsFallbackMode && !speechPipeline.isPlaying {
                    MiloAnalytics.trackError(.ttsFailed, surface: "response_pipeline")
                    errorPresenter.present(.ttsFailed)
                    speechPipeline.speakViaSystemFallback(spokenText)
                    voiceState = .responding
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                let miloError = MiloError.from(error)
                MiloAnalytics.trackError(miloError, surface: "response_pipeline")
                errorPresenter.present(miloError)
                print("⚠️ Companion response error [\(miloError.analyticsCode)]: \(error)")
                _ = await speechPipeline.speak(miloError.spokenFallback)
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

    /// Enqueues a single sentence into the streaming TTS queue, after a
    /// defensive strip of any trailing tags ([POINT:...] or [ACTION:{...}])
    /// in case Claude sneaks a tag mid-response (the system prompt forbids
    /// this but the parsers are permissive). Empty inputs are dropped —
    /// speaking "" returns an unhelpful audio blip and wastes a quota unit.
    private func enqueueSentenceForTTSIfSpeakable(_ sentence: String) {
        let cleaned = stripTrailingActionOrPointTag(sentence)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        speechPipeline.enqueueSpeak(cleaned)
    }

    /// Strips a trailing [ACTION:{...}] or [POINT:...] tag from a text
    /// fragment, whichever is present. Returns the spoken-text remainder.
    /// Used during streaming TTS (mid-stream tag scrub) and end-of-stream
    /// flush (so the residual sentence with the tag glued on still plays
    /// audibly clean).
    private func stripTrailingActionOrPointTag(_ text: String) -> String {
        // MiloActionParser runs first because [ACTION:{...}] contains
        // brace-balanced JSON that the simpler PointTagParser regex can't
        // reason about. If no ACTION tag is present, fall through to the
        // POINT tag stripper.
        let actionResult = MiloActionParser.parse(text)
        if actionResult.action != nil
            || actionResult.spokenText != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return actionResult.spokenText
        }
        return PointTagParser.parse(text).spokenText
    }

    /// Appends a transcript→response pair to the conversation history and
    /// trims the oldest entries past the 10-exchange cap. Extracted so the
    /// action-grammar path and the legacy point-tag path don't drift.
    private func appendConversationHistory(transcript: String, assistantResponse: String) {
        conversationHistory.append(ConversationExchange(
            userTranscript: transcript,
            assistantResponse: assistantResponse,
            createdAt: Date()
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        print("🧠 Conversation history: \(conversationHistory.count) exchanges")
    }

    /// Builds a multi-step `GuidedActionProposal` from a parsed `MiloAction`,
    /// stashes the screen captures for later coordinate resolution, and
    /// auto-fires if the bypass setting allows it (only single-step safe
    /// actions auto-fire — typing, hotkeys, or multi-step sequences always
    /// require explicit confirmation).
    private func handleParsedAction(
        _ action: MiloAction,
        screenCaptures: [CompanionScreenCapture]
    ) {
        // Stash captures so MiloActionExecutor's per-step coordinate
        // resolver can translate screenshot → AppKit-global at confirm
        // time. Cleared in performGuidedActionClick / cancel / done.
        self.lastGuidedActionScreenCaptures = screenCaptures

        // Find the first step that has on-screen coordinates so the
        // preview can fly the cursor to it. Pure ⌘S keypress sequences,
        // etc., simply skip the cursor flight.
        let visualAnchor = firstVisualAnchor(
            in: action,
            screenCaptures: screenCaptures
        )

        if let anchor = visualAnchor {
            // Switch to idle BEFORE setting the location so the triangle
            // becomes visible and can fly to the anchor.
            voiceState = .idle
            detectedElementScreenLocation = anchor.globalLocation
            detectedElementDisplayFrame = anchor.displayFrame
        }

        let instruction = action.confirm.isEmpty ? "Perform action" : action.confirm
        let proposal = GuidedActionProposal(
            actionType: .multiStep(action),
            targetScreenLocation: visualAnchor?.globalLocation,
            targetDisplayFrame: visualAnchor?.displayFrame,
            targetLabel: action.confirm,
            instruction: instruction,
            screenNumber: visualAnchor?.screenNumber
        )
        guidedActionProposal = proposal
        detectedElementBubbleText = proposal.instruction
        MiloAnalytics.trackGuidedActionProposed()

        print("🎯 Multi-step action proposed: \(action.steps.count) step(s) — \"\(action.confirm)\"")

        if isGuidedActionBypassEnabled && action.isSafeForAutoBypass {
            performGuidedActionClick()
        } else {
            NotificationCenter.default.post(name: .miloShowPanel, object: nil)
        }
    }

    /// Finds the first step in an action with an on-screen coordinate
    /// (point/click/scroll) and resolves it against the screen captures.
    /// Returns nil for keypress/type-only sequences.
    private func firstVisualAnchor(
        in action: MiloAction,
        screenCaptures: [CompanionScreenCapture]
    ) -> (globalLocation: CGPoint, displayFrame: CGRect, screenNumber: Int?)? {
        for step in action.steps {
            let coordinate: (x: Int, y: Int, screen: Int?)?
            switch step {
            case let .point(x, y, screen, _),
                 let .click(x, y, screen, _),
                 let .scroll(x, y, screen, _, _):
                coordinate = (x, y, screen)
            case .type, .keypress:
                coordinate = nil
            }
            guard let coord = coordinate else { continue }
            if let resolved = Self.resolveScreenshotCoordinate(
                screenshotPoint: CGPoint(x: coord.x, y: coord.y),
                screenNumber: coord.screen,
                screenCaptures: screenCaptures
            ) {
                return (resolved.globalLocation, resolved.displayFrame, coord.screen)
            }
        }
        return nil
    }


    // MARK: - Point Tag Parsing

    /// Resolves an in-screenshot coordinate (the space Claude emits in action
    /// steps) to AppKit-global coordinates plus the matching display frame.
    /// Returns nil if no matching screen capture is available. Used by the
    /// MiloActionExecutor to translate per-step coordinates at confirm time.
    private static func resolveScreenshotCoordinate(
        screenshotPoint: CGPoint,
        screenNumber: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) -> (globalLocation: CGPoint, displayFrame: CGRect)? {
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber, screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()

        guard let capture = targetCapture else { return nil }

        let globalLocation = CoordinateTranslator.screenshotPointToAppKitGlobal(
            screenshotPoint: screenshotPoint,
            screenshotSize: CGSize(
                width: CGFloat(capture.screenshotWidthInPixels),
                height: CGFloat(capture.screenshotHeightInPixels)
            ),
            displaySize: CGSize(
                width: CGFloat(capture.displayWidthInPoints),
                height: CGFloat(capture.displayHeightInPoints)
            ),
            displayFrame: capture.displayFrame
        )
        return (globalLocation, capture.displayFrame)
    }

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
