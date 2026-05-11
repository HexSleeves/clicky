//
//  InstallIdentityTests.swift
//  leanring-buddyTests
//
//  Behavior tests for the install identity layer. Keychain access uses
//  the system Keychain even in tests, so we use the production
//  InstallIdentity directly — a re-init reads what the prior init wrote.
//
//  Why no separate KeychainProtocol mock? Keychain APIs are notoriously
//  sensitive to entitlements + access groups; a mock would test the
//  mock more than the real code path. The trade is that these tests
//  leave a single Keychain item behind under the service name; not
//  ideal but harmless on dev machines.
//

import Testing
import CryptoKit
import Foundation
@testable import Milo

@MainActor
struct InstallIdentityTests {

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "InstallIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Install ID lifecycle

    @Test func freshInstallHasNoIdUntilSet() {
        let identity = InstallIdentity(defaults: makeScratchDefaults())
        #expect(identity.installId == nil)
    }

    @Test func setInstallIdPersists() {
        let defaults = makeScratchDefaults()
        let id = "test-\(UUID().uuidString)"

        let identity1 = InstallIdentity(defaults: defaults)
        identity1.setInstallId(id)
        #expect(identity1.installId == id)

        // Reload from the same defaults — should still see the id.
        let identity2 = InstallIdentity(defaults: defaults)
        #expect(identity2.installId == id)
    }

    @Test func installIdIsScopedToWorkerBaseURL() {
        let defaults = makeScratchDefaults()

        let localIdentity = InstallIdentity(defaults: defaults, workerBaseURL: "http://localhost:8787")
        localIdentity.setInstallId("local-install")

        let productionIdentity = InstallIdentity(defaults: defaults, workerBaseURL: "https://milo-proxy.example.workers.dev")
        #expect(productionIdentity.installId == nil)

        let reloadedLocalIdentity = InstallIdentity(defaults: defaults, workerBaseURL: "http://localhost:8787")
        #expect(reloadedLocalIdentity.installId == "local-install")
    }

    @Test func productionIdentityMigratesLegacyInstallId() {
        let defaults = makeScratchDefaults()
        defaults.set("legacy-production-install", forKey: PersistenceKeys.miloInstallId)

        let identity = InstallIdentity(defaults: defaults, workerBaseURL: WorkerEndpoints.productionBaseURL)

        #expect(identity.installId == "legacy-production-install")
    }

    // MARK: - Signing

    @Test func signProducesVerifiableSignature() throws {
        let identity = InstallIdentity(defaults: makeScratchDefaults())
        let payload = Data("the quick brown fox".utf8)

        let signature = try identity.sign(payload)
        #expect(signature.count == 64) // Ed25519 signatures are 64 bytes

        // Round-trip: signature verifies against the same public key.
        let publicKeyB64 = try identity.publicKeyBase64()
        let publicKeyData = Data(base64Encoded: publicKeyB64)!
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(publicKey.isValidSignature(signature, for: payload))
    }

    @Test func signaturesDifferAcrossPayloads() throws {
        let identity = InstallIdentity(defaults: makeScratchDefaults())

        let sigA = try identity.sign(Data("payload A".utf8))
        let sigB = try identity.sign(Data("payload B".utf8))
        #expect(sigA != sigB)
    }

    @Test func reloadedKeySignsConsistently() throws {
        // Two InstallIdentity instances should load the same Keychain
        // key and produce identical signatures for identical payloads.
        // This is the "relaunch should keep the same install identity"
        // guarantee in test form.
        let defaults1 = makeScratchDefaults()
        let identity1 = InstallIdentity(defaults: defaults1)
        let payload = Data("relaunch payload".utf8)
        let pubKey1 = try identity1.publicKeyBase64()

        let identity2 = InstallIdentity(defaults: defaults1)
        let pubKey2 = try identity2.publicKeyBase64()
        let sig2 = try identity2.sign(payload)

        // Same public key across reloads (proves Keychain persistence).
        #expect(pubKey1 == pubKey2)

        // Signature from the second instance verifies under the first
        // instance's public key (Ed25519 signatures are deterministic).
        let publicKeyData = Data(base64Encoded: pubKey1)!
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        #expect(publicKey.isValidSignature(sig2, for: payload))
    }
}
