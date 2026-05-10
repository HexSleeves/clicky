//
//  PairingManager.swift
//  leanring-buddy
//
//  Phase 1 client-side pairing state machine. Worker-side rate limit and
//  replay defense live in Lane B; this manager owns local code minting
//  (kid side), code verification (senior side), retry counting, and
//  lockout.
//
//  Policy (from design doc):
//    - 6 digits, 5-minute expiry
//    - 5 consecutive wrong attempts → 60-second lockout
//    - lockout expiring resets the counter (Mom can retry naturally)
//    - re-pairing after kid replaces machine: senior calls reset() then
//      runs the verify flow again with a fresh code
//

import Combine
import Foundation

@MainActor
final class PairingManager: ObservableObject {
    static let codeDigitCount: Int = 6
    static let codeExpiryDuration: TimeInterval = 5 * 60
    static let maxConsecutiveWrongAttempts: Int = 5
    static let lockoutDuration: TimeInterval = 60

    /// Outcome of a single verification attempt. Senior-side UI maps these
    /// directly to user-visible copy (e.g. `.codeMismatch(triesRemaining:)`
    /// drives the "5 tries left" banner).
    enum VerifyOutcome: Equatable {
        case success
        case codeExpired
        case codeMismatch(triesRemaining: Int)
        case lockedOut(unlockAt: Date)
    }

    /// Active code minted by `generatePairCode()` on the kid side. Surfaced
    /// to the kid-side UI so the kid can read it aloud / hand it to Mom.
    @Published private(set) var activePairCode: PairCode?

    /// Wrong-attempt counter on the senior side. Reset on success or
    /// after a lockout window expires.
    @Published private(set) var consecutiveWrongAttempts: Int = 0

    /// When set + in the future, all verify calls fail with `.lockedOut`.
    /// Cleared automatically the first time `verifyEnteredCode` runs past
    /// the deadline.
    @Published private(set) var lockoutUntil: Date?

    /// Set on a successful verification. The opaque value comes from the
    /// Worker in production (DO-issued session token); L0 tests pass any
    /// non-empty string.
    @Published private(set) var pairedPeerToken: String?

    /// Random number source — overridable in tests so we can drive
    /// deterministic codes. Default is `SystemRandomNumberGenerator`.
    private let randomDigitsSource: () -> UInt32

    init(randomDigitsSource: @escaping () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) {
        self.randomDigitsSource = randomDigitsSource
    }

    /// Kid side: mint a fresh 6-digit code with 5-minute expiry.
    @discardableResult
    func generatePairCode(now: Date = Date()) -> PairCode {
        let zeroPaddedDigits = String(
            format: "%0\(Self.codeDigitCount)d",
            randomDigitsSource() % 1_000_000
        )
        let mintedCode = PairCode(
            digits: zeroPaddedDigits,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(Self.codeExpiryDuration)
        )
        activePairCode = mintedCode
        return mintedCode
    }

    /// Senior side: validate the digits Mom typed against the expected
    /// code. In production the `expectedCode` comes back from the Worker
    /// (`/pair/verify` returning the kid's stored code metadata); in L0
    /// tests it's passed directly.
    ///
    /// Side effects:
    ///   - increments `consecutiveWrongAttempts` on mismatch
    ///   - sets `lockoutUntil` after 5 consecutive misses
    ///   - clears wrong-attempts + lockout on success or once a stale
    ///     lockout window has elapsed
    ///   - sets `pairedPeerToken` on success
    func verifyEnteredCode(
        _ enteredDigits: String,
        against expectedCode: PairCode,
        now: Date = Date(),
        sessionTokenOnSuccess: String = "ok"
    ) -> VerifyOutcome {
        if let lockoutDeadline = lockoutUntil, lockoutDeadline > now {
            return .lockedOut(unlockAt: lockoutDeadline)
        }

        // Past-lockout cleanup so Mom can retry without app restart.
        if lockoutUntil != nil {
            lockoutUntil = nil
            consecutiveWrongAttempts = 0
        }

        if expectedCode.isExpired(at: now) {
            return .codeExpired
        }

        if enteredDigits == expectedCode.digits {
            consecutiveWrongAttempts = 0
            lockoutUntil = nil
            pairedPeerToken = sessionTokenOnSuccess
            return .success
        }

        consecutiveWrongAttempts += 1
        let triesRemaining = max(0, Self.maxConsecutiveWrongAttempts - consecutiveWrongAttempts)
        if triesRemaining == 0 {
            let unlockAt = now.addingTimeInterval(Self.lockoutDuration)
            lockoutUntil = unlockAt
            return .lockedOut(unlockAt: unlockAt)
        }
        return .codeMismatch(triesRemaining: triesRemaining)
    }

    /// Wipes pairing state. Use cases:
    ///   - kid replaces machine → senior calls reset(), enters new code
    ///   - explicit "unpair" debug flow
    func reset() {
        activePairCode = nil
        consecutiveWrongAttempts = 0
        lockoutUntil = nil
        pairedPeerToken = nil
        activePairId = nil
        lastNetworkError = nil
    }

    // MARK: - Network-backed flow (Phase 1 wiring to Lane B)

    /// Worker pair-id of the kid-side mint, returned alongside
    /// `activePairCode` after a successful `requestNewPairCodeFromWorker`.
    /// Senior side fills this in after a successful verify.
    @Published private(set) var activePairId: String?

    /// Most recent network-side error, if any. Surfaced by the UI so
    /// "couldn't reach the server" is distinguishable from "code wrong."
    @Published private(set) var lastNetworkError: PairingNetworkError?

    /// Kid side: ask the Worker to mint a fresh 6-digit code. On
    /// success, both `activePairCode` and `activePairId` are set so
    /// the kid-side UI can render the code AND remember which DO
    /// holds it.
    func requestNewPairCodeFromWorker(client: PairingNetworkClient) async {
        lastNetworkError = nil
        do {
            let mintResponse = try await client.generatePairCode()
            self.activePairCode = PairCode(
                digits: mintResponse.code,
                issuedAt: Date(),
                expiresAt: mintResponse.expiresAt
            )
            self.activePairId = mintResponse.pairId
            // Worker pre-mints the session token at /pair/generate so
            // the kid has relay auth from t=0. Storing it as
            // pairedPeerToken kicks the panel into "Paired ✓" and
            // triggers CompanionManager's transport-attach hook the
            // moment the code is minted — without this the kid sat
            // unauthorised even after the senior verified.
            self.pairedPeerToken = mintResponse.sessionToken
        } catch let error as PairingNetworkError {
            lastNetworkError = error
        } catch {
            lastNetworkError = .networkUnreachable
        }
    }

    /// Senior side: submit `enteredDigits` to the Worker. On success,
    /// `pairedPeerToken` is set with the session token. On mismatch,
    /// the local retry/lockout policy in `consecutiveWrongAttempts`
    /// is updated to mirror the Worker's view (the Worker
    /// authoritatively caps at 5; we keep a local mirror so the UI
    /// can show "4 left" without an extra request).
    func submitEnteredPairCode(
        _ enteredDigits: String,
        forKidPairId kidPairId: String,
        client: PairingNetworkClient,
        now: Date = Date()
    ) async {
        lastNetworkError = nil
        if let lockoutDeadline = lockoutUntil, lockoutDeadline > now {
            return
        }
        if lockoutUntil != nil {
            lockoutUntil = nil
            consecutiveWrongAttempts = 0
        }

        do {
            let outcome = try await client.verifyPairCode(
                pairId: kidPairId,
                code: enteredDigits
            )
            switch outcome {
            case .success(let sessionToken):
                consecutiveWrongAttempts = 0
                lockoutUntil = nil
                pairedPeerToken = sessionToken
                activePairId = kidPairId
            case .codeExpired:
                activePairCode = nil
            case .codeMismatch(let triesRemaining):
                consecutiveWrongAttempts = max(
                    0,
                    Self.maxConsecutiveWrongAttempts - triesRemaining
                )
                if triesRemaining == 0 {
                    lockoutUntil = now.addingTimeInterval(Self.lockoutDuration)
                }
            case .lockedOut:
                consecutiveWrongAttempts = Self.maxConsecutiveWrongAttempts
                lockoutUntil = now.addingTimeInterval(Self.lockoutDuration)
            }
        } catch let error as PairingNetworkError {
            lastNetworkError = error
        } catch {
            lastNetworkError = .networkUnreachable
        }
    }
}
