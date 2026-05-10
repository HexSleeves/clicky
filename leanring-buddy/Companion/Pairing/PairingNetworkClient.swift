//
//  PairingNetworkClient.swift
//  leanring-buddy
//
//  HTTP client that talks to the Cloudflare Worker pairing endpoints
//  (Lane B). Phase 1 surface:
//
//      POST /pair/generate         (kid mints a code)
//      POST /pair/verify           (senior submits code)
//
//  Returns typed outcomes that mirror the Worker's JSON. Errors are
//  surfaced via a single `PairingNetworkError` enum so call sites can
//  distinguish "network down" from "code wrong" without parsing
//  HTTP status codes themselves.
//

import Foundation

struct PairCodeMintResponse: Equatable {
    let pairId: String
    let code: String
    let expiresAt: Date
    /// Pre-minted by the Worker at /pair/generate time so the kid has
    /// relay auth from t=0. The senior receives the same token from
    /// /pair/verify on success — both sides share one secret.
    let sessionToken: String
}

enum PairCodeVerificationOutcome: Equatable {
    case success(sessionToken: String)
    case codeExpired
    case codeMismatch(triesRemaining: Int)
    case lockedOut
}

enum PairingNetworkError: Error, Equatable {
    /// Request didn't reach the Worker (DNS, offline, TLS error).
    case networkUnreachable

    /// Worker returned a non-2xx status code we didn't expect.
    case unexpectedStatus(Int)

    /// JSON didn't match the agreed schema.
    case malformedResponse
}

@MainActor
final class PairingNetworkClient {

    private let workerBaseURL: URL
    private let session: URLSession

    init(workerBaseURLString: String, session: URLSession = .shared) {
        // If the URL is malformed, fall back to a placeholder that
        // will produce networkUnreachable errors instead of crashing
        // on app launch. The configuration tests catch malformed URLs
        // earlier.
        self.workerBaseURL = URL(string: workerBaseURLString)
            ?? URL(string: "https://invalid.localhost")!
        self.session = session
    }

    // MARK: - /pair/generate

    func generatePairCode() async throws -> PairCodeMintResponse {
        let request = makePOSTRequest(path: "/pair/generate", jsonBody: nil)
        let (responseData, urlResponse) = try await performRequest(request)
        let httpStatus = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 201 else {
            throw PairingNetworkError.unexpectedStatus(httpStatus)
        }
        return try Self.decodeMintResponse(from: responseData)
    }

    // MARK: - /pair/verify

    func verifyPairCode(pairId: String, code: String) async throws -> PairCodeVerificationOutcome {
        let bodyDictionary: [String: String] = ["pairId": pairId, "code": code]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDictionary)
        let request = makePOSTRequest(path: "/pair/verify", jsonBody: bodyData)
        let (responseData, urlResponse) = try await performRequest(request)
        let httpStatus = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            throw PairingNetworkError.unexpectedStatus(httpStatus)
        }
        return try Self.decodeVerifyOutcome(from: responseData)
    }

    // MARK: - Private

    private func makePOSTRequest(path: String, jsonBody: Data?) -> URLRequest {
        var request = URLRequest(url: workerBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonBody
        request.timeoutInterval = 10
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw PairingNetworkError.networkUnreachable
        }
    }

    static func decodeMintResponse(from responseData: Data) throws -> PairCodeMintResponse {
        let parsed = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        guard let pairId = parsed?["pairId"] as? String,
              let code = parsed?["code"] as? String,
              let expiresAtMillis = (parsed?["expiresAt"] as? NSNumber)?.doubleValue,
              let sessionToken = parsed?["sessionToken"] as? String else {
            throw PairingNetworkError.malformedResponse
        }
        return PairCodeMintResponse(
            pairId: pairId,
            code: code,
            expiresAt: Date(timeIntervalSince1970: expiresAtMillis / 1000),
            sessionToken: sessionToken
        )
    }

    static func decodeVerifyOutcome(from responseData: Data) throws -> PairCodeVerificationOutcome {
        let parsed = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        guard let outcomeString = parsed?["outcome"] as? String else {
            throw PairingNetworkError.malformedResponse
        }
        switch outcomeString {
        case "success":
            guard let sessionToken = parsed?["sessionToken"] as? String else {
                throw PairingNetworkError.malformedResponse
            }
            return .success(sessionToken: sessionToken)
        case "codeExpired":
            return .codeExpired
        case "codeMismatch":
            let triesRemaining = (parsed?["triesRemaining"] as? Int) ?? 0
            return .codeMismatch(triesRemaining: triesRemaining)
        case "lockedOut":
            return .lockedOut
        default:
            throw PairingNetworkError.malformedResponse
        }
    }
}
