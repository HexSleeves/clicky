# Milo Production Readiness

This slice only removes immediate credential/update exposure and reorganizes the Xcode app target. The remaining blockers below must be closed before public distribution.

## Security

- Rotate the ElevenLabs key that was previously placed in `Info.plist`.
- Keep all Anthropic, AssemblyAI, and ElevenLabs credentials in Cloudflare Worker secrets only.
- Re-enable Sparkle only after a Milo-owned feed URL and a newly generated Sparkle EdDSA keypair exist.
- Add CI secret scanning with a hard-fail rule.
- Replace hardcoded Worker URLs with typed build/runtime configuration.

## Privacy

- Audit every `MiloAnalytics.track*` call and keep a table of event names, fields, and rationale.
- Keep transcripts, screenshots, and assistant response text out of analytics.
- Add an analytics opt-in/out control.
- Decide Worker log retention. Default should be structured metadata only, no request bodies.
- Prepare a privacy policy covering microphone audio, screen content, transcripts, and subprocessors.

## Cost And Abuse Protection

- Add per-install request budgets in the Worker.
- Add a remote `/config` endpoint for provider kill switches.
- Add spend alerts for Anthropic, AssemblyAI, ElevenLabs, and Cloudflare.
- Decide whether ElevenLabs, OpenAI TTS, or a hybrid provider strategy is the v1 production path.

## Reliability

- Decompose `CompanionManager` after this folder cleanup into interaction, AI response, speech, permission, and configuration services.
- Add cancellation tests for rapid push-to-talk, type-to-talk cancellation, and interrupted TTS.
- Add coordinate parsing tests for every supported `[POINT]` shape and malformed tags.
- Add a single user-facing error model for permissions, Worker failures, STT failures, Claude failures, TTS failures, screenshots, and budget denial.

## Worker

- Validate method, path, content type, and payload size.
- Return stable JSON error codes instead of raw upstream bodies.
- Reject obvious unauthenticated probes and require install/app-version headers.
- Upgrade Wrangler to 4.x after verifying `wrangler dev` and deploy behavior.
- Add Worker tests for route success/failure, missing secrets, upstream failures, payload-size rejection, audio headers, and AssemblyAI token handling.

## Release

- Rename release automation, appcast, DMG names, and release notes from `makesomething` to `Milo`.
- Replace the placeholder bundle identifier before first public release.
- Archive, sign, notarize, staple, and Sparkle-sign only on CI/release machines.
- Smoke-test the signed artifact on a clean macOS user account.
