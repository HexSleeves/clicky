//
//  SignedRequestHeadersTests.swift
//  leanring-buddyTests
//
//  Pins the canonical byte format the Worker reconstructs to verify
//  signatures. Any change here must land in the Worker (worker/src/
//  install.ts → verifySignedRequest) in the same commit; the format is
//  the contract between the two.
//

import Testing
import CryptoKit
import Foundation
@testable import Milo

@MainActor
struct SignedRequestHeadersTests {

    // MARK: - Canonical byte format

    @Test func canonicalIncludesAllFields() {
        let bytes = SignedRequestHeaderBuilder.canonicalBytes(
            method: "post",
            path: "/chat",
            body: Data("hi".utf8),
            timestamp: "1700000000",
            nonce: "abcdef"
        )
        let str = String(decoding: bytes, as: UTF8.self)
        let lines = str.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == 5)
        #expect(lines[0] == "POST")          // method is upper-cased
        #expect(lines[1] == "/chat")
        // line 2 is the sha256(body) hex — checked separately below.
        #expect(lines[3] == "1700000000")
        #expect(lines[4] == "abcdef")
    }

    @Test func bodyHashIsSha256Hex() {
        let body = Data("hello milo".utf8)
        let bytes = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST",
            path: "/chat",
            body: body,
            timestamp: "1",
            nonce: "n"
        )
        let str = String(decoding: bytes, as: UTF8.self)
        let lines = str.split(separator: "\n", omittingEmptySubsequences: false)

        let expected = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(lines[2] == expected)
    }

    @Test func canonicalChangesWhenAnyFieldChanges() {
        // Tampering with any field — method, path, body, timestamp,
        // nonce — must produce different canonical bytes (and therefore
        // an invalid signature). This is the core security invariant.
        let base = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST", path: "/chat",
            body: Data("a".utf8), timestamp: "1", nonce: "n"
        )
        let differentMethod = SignedRequestHeaderBuilder.canonicalBytes(
            method: "GET", path: "/chat",
            body: Data("a".utf8), timestamp: "1", nonce: "n"
        )
        let differentPath = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST", path: "/tts",
            body: Data("a".utf8), timestamp: "1", nonce: "n"
        )
        let differentBody = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST", path: "/chat",
            body: Data("b".utf8), timestamp: "1", nonce: "n"
        )
        let differentTimestamp = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST", path: "/chat",
            body: Data("a".utf8), timestamp: "2", nonce: "n"
        )
        let differentNonce = SignedRequestHeaderBuilder.canonicalBytes(
            method: "POST", path: "/chat",
            body: Data("a".utf8), timestamp: "1", nonce: "m"
        )

        #expect(base != differentMethod)
        #expect(base != differentPath)
        #expect(base != differentBody)
        #expect(base != differentTimestamp)
        #expect(base != differentNonce)
    }

    // MARK: - build()

    @Test func buildReturnsNilWhenNoInstallId() throws {
        let defaults = UserDefaults(suiteName: "SignedReqBuild.\(UUID().uuidString)")!
        let identity = InstallIdentity(defaults: defaults)
        // No setInstallId — should return nil.

        let result = try SignedRequestHeaderBuilder.build(
            method: "POST",
            path: "/chat",
            body: Data(),
            identity: identity,
            appVersion: "1.0"
        )
        #expect(result == nil)
    }

    @Test func buildProducesAllFiveHeadersWhenIdentityIsRegistered() throws {
        let defaults = UserDefaults(suiteName: "SignedReqBuild.\(UUID().uuidString)")!
        let identity = InstallIdentity(defaults: defaults)
        identity.setInstallId("install-123")

        let result = try SignedRequestHeaderBuilder.build(
            method: "POST",
            path: "/chat",
            body: Data("body".utf8),
            identity: identity,
            appVersion: "1.0",
            clock: { Date(timeIntervalSince1970: 1700000000) },
            nonceProvider: { "deadbeef" }
        )

        let headers = try #require(result?.asDictionary)
        #expect(headers["X-Milo-Install"] == "install-123")
        #expect(headers["X-Milo-App-Version"] == "1.0")
        #expect(headers["X-Milo-Timestamp"] == "1700000000")
        #expect(headers["X-Milo-Nonce"] == "deadbeef")
        // Signature is base64(64 bytes) → 88 chars including padding.
        #expect(headers["X-Milo-Signature"]?.count == 88)
    }

    // MARK: - randomHexNonce

    @Test func nonceIs32HexChars() {
        let nonce = SignedRequestHeaderBuilder.randomHexNonce()
        #expect(nonce.count == 32) // 16 bytes × 2 hex chars
        #expect(nonce.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func noncesAreUnique() {
        // 16 bytes of CSPRNG output — collision probability is negligible.
        // Test pinned to catch accidental "use a counter" regressions.
        let a = SignedRequestHeaderBuilder.randomHexNonce()
        let b = SignedRequestHeaderBuilder.randomHexNonce()
        #expect(a != b)
    }
}
