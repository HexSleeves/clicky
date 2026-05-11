//
//  SignedRequestHeaders.swift
//  leanring-buddy
//
//  Builds the X-Milo-* headers that authenticate a request to the
//  Worker. Signature covers method + path + body hash + timestamp +
//  nonce, so replays are bounded to a small window and tampering is
//  detected.
//
//  Header contract (Stage A — Worker logs but doesn't enforce):
//    X-Milo-Install     install ID from /install/register
//    X-Milo-App-Version  CFBundleShortVersionString
//    X-Milo-Timestamp    seconds since epoch
//    X-Milo-Nonce        16 random bytes hex
//    X-Milo-Signature    base64(Ed25519 sign of canonical bytes)
//

import CryptoKit
import Foundation

struct SignedRequestHeaders {
    let install: String
    let appVersion: String
    let timestamp: String
    let nonce: String
    let signature: String

    /// Dictionary representation suitable for setting on URLRequest.
    var asDictionary: [String: String] {
        return [
            "X-Milo-Install": install,
            "X-Milo-App-Version": appVersion,
            "X-Milo-Timestamp": timestamp,
            "X-Milo-Nonce": nonce,
            "X-Milo-Signature": signature
        ]
    }
}

@MainActor
enum SignedRequestHeaderBuilder {

    /// Canonicalizes the request into the byte sequence the signature
    /// covers. Format: "METHOD\nPATH\nBODYHASH\nTIMESTAMP\nNONCE". The
    /// Worker reconstructs this exact same string from the incoming
    /// headers + body to verify.
    static func canonicalBytes(
        method: String,
        path: String,
        body: Data,
        timestamp: String,
        nonce: String
    ) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method.uppercased())\n\(path)\n\(bodyHash)\n\(timestamp)\n\(nonce)"
        return Data(canonical.utf8)
    }

    /// Builds the signed header set for the given request. Returns nil
    /// if the install hasn't registered yet (the network client will
    /// skip the auth headers entirely — the Worker accepts unsigned
    /// during Stage A and logs the gap).
    static func build(
        method: String,
        path: String,
        body: Data,
        identity: InstallIdentity,
        appVersion: String,
        clock: () -> Date = Date.init,
        nonceProvider: () -> String = randomHexNonce
    ) throws -> SignedRequestHeaders? {
        guard let install = identity.installId else { return nil }

        let timestamp = String(Int(clock().timeIntervalSince1970))
        let nonce = nonceProvider()
        let canonical = canonicalBytes(
            method: method,
            path: path,
            body: body,
            timestamp: timestamp,
            nonce: nonce
        )
        let signatureData = try identity.sign(canonical)

        return SignedRequestHeaders(
            install: install,
            appVersion: appVersion,
            timestamp: timestamp,
            nonce: nonce,
            signature: signatureData.base64EncodedString()
        )
    }

    /// 16 bytes of cryptographic random, hex-encoded. Worker rejects
    /// replays within a 10-minute TTL window. `nonisolated` so the
    /// default parameter form doesn't lose `@MainActor`.
    nonisolated static func randomHexNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes should never fail in practice; degrade
            // to a UUID rather than fatalError so a one-off OS hiccup
            // doesn't crash the app mid-session.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
