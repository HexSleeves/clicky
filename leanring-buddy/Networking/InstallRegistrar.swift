//
//  InstallRegistrar.swift
//  leanring-buddy
//
//  Calls the Worker's `/install/register` endpoint on first launch to
//  exchange the install's public key for a server-issued install ID.
//  Stage A is fire-and-forget: failures don't block the app; the next
//  Worker request just goes out unsigned and the Worker logs the gap.
//

import Foundation

@MainActor
final class InstallRegistrar {

    private let identity: InstallIdentity
    private let workerBaseURL: String
    private let session: URLSession

    init(
        identity: InstallIdentity,
        workerBaseURL: String,
        session: URLSession = .shared
    ) {
        self.identity = identity
        self.workerBaseURL = workerBaseURL
        self.session = session
    }

    /// Registers the install if not already registered. Idempotent and
    /// safe to call from `start()` on every launch — short-circuits when
    /// `identity.installId` is already set.
    func registerIfNeeded() async {
        guard identity.installId == nil else { return }

        do {
            let publicKeyBase64 = try identity.publicKeyBase64()
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

            guard let url = URL(string: "\(workerBaseURL)/install/register") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(appVersion, forHTTPHeaderField: "X-Milo-App-Version")

            let body: [String: String] = [
                "public_key": publicKeyBase64,
                "app_version": appVersion
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ InstallRegistrar: non-200 response, skipping")
                return
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let installId = json["install_id"] as? String
            else {
                print("⚠️ InstallRegistrar: malformed response")
                return
            }

            identity.setInstallId(installId)
            print("🔐 InstallRegistrar: registered install \(installId.prefix(8))…")
        } catch {
            // Stage A is observe-only; registration failure doesn't block
            // the app — the next Worker request just goes out unsigned
            // and the Worker records that as a tracked metric.
            print("⚠️ InstallRegistrar: registration failed: \(error.localizedDescription)")
        }
    }
}
