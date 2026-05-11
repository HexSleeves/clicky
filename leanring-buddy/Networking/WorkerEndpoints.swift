//
//  WorkerEndpoints.swift
//  leanring-buddy
//
//  Single source of truth for the Cloudflare Worker URL and the route
//  paths the app calls. Built after a deploy-URL-rename incident where
//  the fallback URL was hardcoded in 3 separate files and drifted out
//  of sync — pointing the app at one place lets future renames touch
//  only this file.
//
//  Plist key `WORKER_BASE_URL` lets each build target an environment:
//   - Local dev: http://localhost:8787 (via `npx wrangler dev`)
//   - Production: https://milo-proxy.<account>.workers.dev
//  When the key is missing, falls back to the production URL.
//

import Foundation

// Members are explicitly `nonisolated` so they can be referenced as
// default-argument values + read from non-MainActor contexts (URLSession
// callbacks, network clients). The project ships with default actor
// isolation set to MainActor, which would otherwise make every static
// here implicitly @MainActor and forbidden from default args.
enum WorkerEndpoints {

    /// Info.plist key the app reads to discover the Worker base URL.
    nonisolated static let baseURLPlistKey = "WORKER_BASE_URL"

    /// Hardcoded fallback used when `WORKER_BASE_URL` is absent. The
    /// production worker URL — rebuilding the app without the plist key
    /// will still reach a real backend.
    nonisolated static let productionBaseURL = "https://milo-proxy.lecoqjosephjacob.workers.dev"

    /// Resolved base URL for the current build. Reads the plist key,
    /// falls back to production.
    nonisolated static var baseURL: String {
        AppBundleConfiguration.stringValue(forKey: baseURLPlistKey)
            ?? productionBaseURL
    }

    // MARK: - Path components
    //
    // Kept as path-only constants (no leading host) so they compose with
    // `baseURL`. Worker code at worker/src/index.ts dispatches on these
    // exact strings — any rename here MUST be matched on the Worker side
    // in the same commit.

    nonisolated static let chatPath = "/chat"
    nonisolated static let ttsPath = "/tts"
    nonisolated static let transcribeTokenPath = "/transcribe-token"
    nonisolated static let installRegisterPath = "/install/register"

    // MARK: - Composed URLs
    //
    // Convenience accessors for the routes the app actually hits.

    nonisolated static var chatURL: String { baseURL + chatPath }
    nonisolated static var ttsURL: String { baseURL + ttsPath }
    nonisolated static var transcribeTokenURL: String { baseURL + transcribeTokenPath }
    nonisolated static var installRegisterURL: String { baseURL + installRegisterPath }
}
