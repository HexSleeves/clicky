//
//  PollingRelayTransport.swift
//  leanring-buddy
//
//  RemoteSessionTransport implementation that rides on the existing
//  Worker /signal/:pairId/{send,poll} endpoints. Bridge until a real
//  RTCPeerConnection-backed transport ships.
//
//  Send path:  POST /signal/:pairId/send with kind="wire" and the
//              full RemoteWireMessage JSON envelope as `data`.
//  Recv path:  poll /signal/:pairId/poll on a 1s timer; for each
//              "wire" message, decode the data field as a wire message
//              and dispatch via onMessage.
//
//  Latency: poll-interval bound (~1s). Bad for cursor flight but enough
//  to prove the end-to-end loop without WebRTC. Swap for an
//  RTCPeerConnection transport in a later commit; the
//  RemoteSessionTransport boundary stays unchanged.
//

import Foundation

@MainActor
final class PollingRelayTransport: RemoteSessionTransport {

    enum Role: String {
        case kid
        case senior
    }

    var onMessage: ((RemoteWireMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onTransportError: ((Error) -> Void)?

    private let workerBaseURL: URL
    private let pairId: String
    private let sessionToken: String
    private let role: Role
    private let session: URLSession
    private let pollIntervalSeconds: TimeInterval

    private var pollTask: Task<Void, Never>?
    private var isTornDown: Bool = false

    init(
        workerBaseURLString: String,
        pairId: String,
        sessionToken: String,
        role: Role,
        pollIntervalSeconds: TimeInterval = 1.0,
        session: URLSession = .shared
    ) {
        self.workerBaseURL = URL(string: workerBaseURLString)
            ?? URL(string: "https://invalid.localhost")!
        self.pairId = pairId
        self.sessionToken = sessionToken
        self.role = role
        self.pollIntervalSeconds = pollIntervalSeconds
        self.session = session
    }

    /// Begin polling. Idempotent — calling twice doesn't double up.
    func startPolling() {
        guard pollTask == nil, !isTornDown else { return }
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func send(_ message: RemoteWireMessage) {
        Task { [weak self] in
            await self?.performSend(message)
        }
    }

    func teardown() {
        isTornDown = true
        pollTask?.cancel()
        pollTask = nil
        // POST end best-effort so the DO marks the session ended.
        Task { [pairId, sessionToken, workerBaseURL, session] in
            var endRequest = URLRequest(url: workerBaseURL.appendingPathComponent("/signal/\(pairId)/end"))
            endRequest.httpMethod = "POST"
            endRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            endRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionToken": sessionToken])
            _ = try? await session.data(for: endRequest)
        }
    }

    // MARK: - Send

    private func performSend(_ message: RemoteWireMessage) async {
        do {
            let envelopeData = try RemoteWireMessageCodec.encode(message)
            let envelopeObject = try JSONSerialization.jsonObject(with: envelopeData)

            let body: [String: Any] = [
                "sessionToken": sessionToken,
                "from": role.rawValue,
                "kind": "wire",
                "data": envelopeObject
            ]
            var request = URLRequest(url: workerBaseURL.appendingPathComponent("/signal/\(pairId)/send"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, urlResponse) = try await session.data(for: request)
            if let httpResponse = urlResponse as? HTTPURLResponse,
               httpResponse.statusCode == 410 {
                // Session ended on the other side.
                onDisconnect?()
            }
        } catch {
            onTransportError?(error)
        }
    }

    // MARK: - Poll loop

    private func runPollLoop() async {
        let pollRoleString = role.rawValue
        while !Task.isCancelled, !isTornDown {
            do {
                var request = URLRequest(url: workerBaseURL.appendingPathComponent("/signal/\(pairId)/poll"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "sessionToken": sessionToken,
                    "role": pollRoleString
                ])

                let (responseData, urlResponse) = try await session.data(for: request)
                let httpStatus = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0

                if httpStatus == 410 {
                    // Session ended; close and notify.
                    onDisconnect?()
                    return
                }
                if httpStatus == 200 {
                    handlePollResponse(responseData)
                }
                // Other statuses: silently retry next tick.
            } catch {
                onTransportError?(error)
            }

            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }

    private func handlePollResponse(_ responseData: Data) {
        struct PollResponse: Decodable {
            struct Message: Decodable {
                let from: String
                let kind: String
                let data: AnyDecodable?
            }
            let outcome: String
            let messages: [Message]?
        }

        do {
            let decoded = try JSONDecoder().decode(PollResponse.self, from: responseData)
            guard let messages = decoded.messages else { return }
            for message in messages where message.kind == "wire" {
                guard let data = message.data?.value else { continue }
                let envelopeJSON = try JSONSerialization.data(withJSONObject: data)
                let wireMessage = try RemoteWireMessageCodec.decode(envelopeJSON)
                onMessage?(wireMessage)
            }
        } catch {
            // Malformed poll response — log and keep polling.
            onTransportError?(error)
        }
    }
}

/// Tiny `Any`-backed Decodable so we can re-serialize the inbox `data`
/// blob without forcing the relay to know every wire kind's schema.
private struct AnyDecodable: Decodable {
    let value: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyDecodable].self) {
            self.value = array.map { $0.value as Any }
        } else if let dict = try? container.decode([String: AnyDecodable].self) {
            self.value = dict.mapValues { $0.value as Any }
        } else {
            self.value = nil
        }
    }
}
