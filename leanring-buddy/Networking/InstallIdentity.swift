//
//  InstallIdentity.swift
//  leanring-buddy
//
//  Per-install Ed25519 keypair backed by the Keychain. The private key
//  signs every outgoing Worker request; the public key is sent to
//  /install/register on first launch and stored server-side for
//  signature verification.
//
//  Why Ed25519 over HMAC: the Worker only stores public keys, so a
//  Worker breach doesn't compromise the installs themselves. HMAC would
//  require a shared secret that any leaked Worker dump could replay.
//
//  Keychain access policy: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//  — survives reboots, doesn't sync to iCloud, doesn't migrate to other
//  devices. Reinstalling the app creates a new identity, which is correct:
//  install = device + app, not user.
//

import CryptoKit
import Foundation
import Security

@MainActor
final class InstallIdentity {

    private static let keychainService = "so.clicky.milo.installIdentity"
    private static let keychainAccount = "installPrivateKey"
    private static let legacyInstallIdDefaultsKey = PersistenceKeys.miloInstallId
    private static let installIdDefaultsKeyPrefix = PersistenceKeys.miloInstallIdByWorkerBaseURLPrefix

    /// The persistent install identifier returned by the Worker's
    /// /install/register response. Nil until the first successful
    /// registration. Stored in UserDefaults per Worker base URL —
    /// re-registration on a fresh install or a different Worker is by
    /// design (new server-side store = new install record).
    private(set) var installId: String?

    /// In-memory copy of the private key. Loaded from Keychain on first
    /// use, generated + stored if absent.
    private var privateKey: Curve25519.Signing.PrivateKey?

    private let defaults: UserDefaults
    private let installIdDefaultsKey: String

    init(defaults: UserDefaults = .standard, workerBaseURL: String = WorkerEndpoints.baseURL) {
        self.defaults = defaults
        self.installIdDefaultsKey = Self.installIdDefaultsKey(forWorkerBaseURL: workerBaseURL)

        if let installId = defaults.string(forKey: installIdDefaultsKey) {
            self.installId = installId
        } else if workerBaseURL == WorkerEndpoints.productionBaseURL,
                  let legacyInstallId = defaults.string(forKey: Self.legacyInstallIdDefaultsKey) {
            self.installId = legacyInstallId
            defaults.set(legacyInstallId, forKey: installIdDefaultsKey)
        } else {
            self.installId = nil
        }
    }

    /// Returns the install's private signing key. On first call, attempts
    /// to load from Keychain. If absent, generates a new keypair and
    /// stores it. Throws on Keychain failure — callers should treat this
    /// as fatal at startup (no signing = no Worker requests).
    func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let cached = privateKey {
            return cached
        }
        if let loaded = try Self.loadPrivateKeyFromKeychain() {
            privateKey = loaded
            return loaded
        }
        let generated = Curve25519.Signing.PrivateKey()
        try Self.storePrivateKeyInKeychain(generated)
        privateKey = generated
        return generated
    }

    /// Base64-encoded public key for sending to the Worker on register.
    func publicKeyBase64() throws -> String {
        let key = try loadOrCreatePrivateKey()
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Stores the install ID returned by /install/register so future
    /// requests can include `X-Milo-Install: <id>`.
    func setInstallId(_ id: String) {
        installId = id
        defaults.set(id, forKey: installIdDefaultsKey)
    }

    private nonisolated static func installIdDefaultsKey(forWorkerBaseURL workerBaseURL: String) -> String {
        let workerBaseURLHash = SHA256.hash(data: Data(workerBaseURL.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return installIdDefaultsKeyPrefix + workerBaseURLHash
    }

    /// Signs the given data with the install's private key. Used by
    /// `SignedRequestBuilder` to produce the `X-Milo-Signature` header.
    func sign(_ data: Data) throws -> Data {
        let key = try loadOrCreatePrivateKey()
        return try key.signature(for: data)
    }

    // MARK: - Keychain helpers

    private static func loadPrivateKeyFromKeychain() throws -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let rawData = result as? Data else { return nil }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: rawData)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    private static func storePrivateKeyInKeychain(_ key: Curve25519.Signing.PrivateKey) throws {
        let rawData = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: rawData
        ]

        // Delete any prior entry first — paranoid but cheap; SecItemAdd
        // returns errSecDuplicateItem otherwise.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    enum KeychainError: Error, Equatable {
        case unhandled(status: OSStatus)
    }
}
