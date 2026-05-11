//
//  SignedRequest.swift
//  leanring-buddy
//
//  URLRequest extension that attaches the X-Milo-* signature headers
//  using a shared InstallIdentity. Pragmatic Stage A behavior: if the
//  install hasn't registered yet (first-launch race) or signing fails,
//  the request is sent unsigned and the Worker records it as such in
//  the daily metrics.
//

import Foundation

extension URLRequest {

    /// Attaches X-Milo-Install, X-Milo-App-Version, X-Milo-Timestamp,
    /// X-Milo-Nonce, and X-Milo-Signature headers. Idempotent — if the
    /// identity lacks an install ID, returns without modifying.
    ///
    /// `path` MUST be the URL path the Worker sees (not the full URL).
    /// `body` MUST be byte-identical to the data actually sent on the wire —
    /// signature covers the SHA-256 of this exact byte sequence.
    @MainActor
    mutating func attachMiloSignatureHeaders(
        identity: InstallIdentity,
        path: String,
        body: Data
    ) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let method = httpMethod ?? "POST"

        do {
            guard let headers = try SignedRequestHeaderBuilder.build(
                method: method,
                path: path,
                body: body,
                identity: identity,
                appVersion: appVersion
            ) else {
                return // No install ID yet — send unsigned, Worker logs the gap.
            }
            for (key, value) in headers.asDictionary {
                setValue(value, forHTTPHeaderField: key)
            }
        } catch {
            // Signing should never fail for a registered install since the
            // Keychain key is loaded once + cached. If it does, log and
            // send unsigned — Stage A doesn't reject anyway.
            print("⚠️ SignedRequest: failed to sign \(path): \(error)")
        }
    }
}
