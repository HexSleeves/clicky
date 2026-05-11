# Milo - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Users can also press ctrl+command to open a floating text input panel and type to Milo. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `MiloAnalytics.swift`
- **Source Layout**: The app target uses folder-backed Xcode groups under `leanring-buddy/`: `App`, `Companion`, `AI`, `Audio`, `Analytics`, `DesignSystem`, `Resources`, and `Support`. Keep the Xcode project and scheme names unchanged.

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Guided Action Mode**: Milo can turn action-intent prompts (for example, "where do I click?", "reply 'on my way'", "save this file") into a confirmed action proposal. Two grammars coexist:

- **Legacy `[POINT:x,y:label:screenN]`** — single click target. Milo flies the cursor and shows a panel preview; after the user presses Click, Milo posts one left-click at the target. The "Auto-click actions" bypass setting skips confirmation for this single-click case.
- **`[ACTION:{...}]` (Action Grammar v2)** — multi-step JSON sequence with `point`/`click`/`type`/`keypress`/`scroll` verbs and a Claude-authored `confirm` string. Milo previews the step list in the panel; after the user presses Run, `MiloActionExecutor` synthesizes the CGEvents in order with an 80ms inter-step delay. Auto-bypass is restricted to single-step click/point sequences — typing, hotkeys, or any multi-step chain always requires explicit confirmation regardless of the setting.

The orchestrator tries `[ACTION:...]` first and falls back to `[POINT:...]` if no action was parsed. Both formats remain supported.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Milo" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/App/leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `leanring-buddy/Companion/CompanionManager.swift` | ~1450 | Central state machine. Owns dictation, shortcut monitoring, typed input, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, cursor color, cursor visibility, and the Notes store. Detects "remember that…" / "save note: …" intents and routes them to NotesStore instead of Claude. Coordinates the full voice/text input → screenshot → Claude → TTS → pointing pipeline. Tries the new `[ACTION:{...}]` grammar (multi-step) first, falls back to legacy `[POINT:...]` (single click). |
| `leanring-buddy/Companion/Core/MiloAction.swift` | ~192 | Action Grammar v2 data model. `MiloAction` (steps + confirm), `MiloActionStep` enum cases — `point`/`click`/`type`/`keypress`/`scroll` — with Codable encode/decode dispatched by a `verb` discriminator. `isSafeForAutoBypass` gates the bypass setting to single-step click/point only (typing, hotkeys, multi-step sequences always require explicit confirmation). |
| `leanring-buddy/Companion/Core/MiloActionParser.swift` | ~133 | Extracts the trailing `[ACTION:{...}]` JSON tag from a Claude response. Bracket-balanced scanner (not regex) handles nested JSON objects, escaped quotes, and brackets inside string values. Returns `ActionParseResult` with the spoken-text portion and the decoded action. |
| `leanring-buddy/Companion/Core/MiloActionExecutor.swift` | ~233 | Synthesizes CGEvents to execute a `MiloAction` sequentially. Per-verb executors: click (warp + mouseDown/Up), type (`keyboardSetUnicodeString` — locale-independent), keypress (virtual key codes + modifier flag composition), scroll. 80ms inter-step delay so the OS can settle between events. Coordinate translation is owned by the caller via the injected `CoordinateResolver` closure. |
| `leanring-buddy/Companion/Core/SentenceSplitter.swift` | ~176 | Incremental sentence detection over a streaming text source. Drives sentence-chunked TTS so the first sentence plays while later sentences are still being generated. Recognizes `[ACTION:...]` payloads and suppresses splitting inside them (JSON routinely contains `.`/`!`/`?` that aren't real sentence boundaries). |
| `leanring-buddy/Companion/Core/CompanionSystemPrompt.swift` | ~92 | The Claude system prompt for spoken-companion mode. Defines voice/style rules, the `[POINT:...]` element-pointing protocol, the `[ACTION:{...}]` multi-step grammar with examples, and the safety guidance Claude follows when proposing actions. `build(notesBlock:)` splices in the user's saved-notes block. |
| `leanring-buddy/Companion/CursorColorOption.swift` | ~55 | Enum of available cursor colors (red/blue/yellow/green) with `displayColor` and `glowColor` accessors. Drives the cursor overlay, panel logo, response bubble, and text-input pill so the chosen color reads as a single identity. |
| `leanring-buddy/Companion/Notes/MiloNote.swift` | ~22 | `Identifiable, Codable` struct for a single saved note (id, text, createdAt). |
| `leanring-buddy/Companion/Notes/NotesStore.swift` | ~135 | `@MainActor` class that persists `[MiloNote]` to `~/Library/Application Support/Milo/notes.json`. Exposes `add` / `remove` / `systemPromptBlock()` for Claude system-prompt injection. |
| `leanring-buddy/Companion/Notes/NotesPanelView.swift` | ~210 | SwiftUI popover hosted by `MenuBarPanelManager` from the footer Notes button. Lists saved notes with delete-per-row, supports manual add, and shows empty-state copy explaining the voice phrasing. |
| `leanring-buddy/Companion/Panel/MenuBarPanelManager.swift` | ~430 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. Also hosts the Notes and Settings popovers spawned from the panel footer. |
| `leanring-buddy/Companion/Panel/CompanionPanelView.swift` | ~1240 | SwiftUI panel content for the menu bar dropdown. Header (logo + Active pill + X close), permissions/onboarding UI, push-to-talk hero, guided-action preview, the cursor color picker (red/blue/yellow/green tiles), and the new footer (version • Notes • gear). Dark aesthetic using `DS` design system. |
| `leanring-buddy/Companion/Panel/SettingsPopoverView.swift` | ~190 | Settings popover spawned from the gear icon in the panel footer. Hosts the Sonnet/Opus model picker, "DM Farza on X", "Replay onboarding", and "Quit Milo". |
| `leanring-buddy/Companion/TextInput/CompanionTextInputPanelManager.swift` | ~340 | Floating text input panel opened by ctrl+command. Coral/cursor-colored pill with a paperclip image-attach button (NSOpenPanel, multi-select), arrow-up submit, and X close. Positions near the cursor, focuses the text field, submits typed prompts (and any attached image data) to `CompanionManager`, and dismisses on outside click or Escape. |
| `leanring-buddy/Companion/Overlay/OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `leanring-buddy/Companion/Overlay/CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `leanring-buddy/AI/ScreenCapture/CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `leanring-buddy/Audio/Dictation/BuddyDictationManager.swift` | ~932 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, voice/text shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `leanring-buddy/Audio/Dictation/BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `leanring-buddy/Audio/Dictation/AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `leanring-buddy/Audio/Dictation/OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `leanring-buddy/Audio/Dictation/AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `leanring-buddy/Audio/Dictation/BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `leanring-buddy/Companion/Input/GlobalPushToTalkShortcutMonitor.swift` | ~152 | System-wide shortcut monitor. Owns the listen-only `CGEvent` tap and publishes push-to-talk plus type-to-talk press/release transitions. |
| `leanring-buddy/AI/ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `leanring-buddy/AI/OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `leanring-buddy/Audio/TTS/ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `leanring-buddy/DesignSystem/DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `leanring-buddy/Analytics/MiloAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `leanring-buddy/Companion/Permissions/WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `leanring-buddy/App/Configuration/AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for non-secret app bundle values in Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

## GBrain Configuration (configured by /setup-gbrain)

- Mode: local-stdio
- Engine: pglite
- Config file: ~/.gbrain/config.json (mode 0600)
- Setup date: 2026-05-09
- MCP registered: yes (user scope, stdio)
- Artifacts repo: git@github.com:HexSleeves/gstack-artifacts-lecoqjacob.git
- Artifacts sync: full
- Current repo policy: read-write

## GBrain Search Guidance (configured by /sync-gbrain)
<!-- gstack-gbrain-search-guidance:start -->

GBrain is set up and synced on this machine. The agent should prefer gbrain
over Grep when the question is semantic or when you don't know the exact
identifier yet. Two indexed corpora available via the `gbrain` CLI:
- This repo's code (registered as `gstack-code-milo` source).
- `~/.gstack/` curated memory (registered as `gstack-brain-lecoqjacob` source via the existing federation pipeline).

Prefer gbrain when:
- "Where is X handled?" / semantic intent, no exact string yet:
  `gbrain search "<terms>"` or `gbrain query "<question>"`
- "Where is symbol Y defined?" / symbol-based code questions:
  `gbrain code-def <symbol>` or `gbrain code-refs <symbol>`
- "What calls Y?" / "What does Y depend on?":
  `gbrain code-callers <symbol>` / `gbrain code-callees <symbol>`
- "What did we decide last time?" / past plans, retros, learnings:
  `gbrain search "<terms>" --source gstack-brain-lecoqjacob`

Grep is still right for known exact strings, regex, multiline patterns, and
file globs. The brain auto-syncs incrementally on every gstack skill start.
Run `/sync-gbrain` to force-refresh, `/sync-gbrain --full` for full reindex.

<!-- gstack-gbrain-search-guidance:end -->

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
