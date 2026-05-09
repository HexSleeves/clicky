//
//  PairingManagerTests.swift
//  leanring-buddyTests
//
//  Covers the client-side Phase 1 Test Plan rows for PairingManager:
//  - generateCode + verifyCode happy path
//  - Code expiry (default 5min) → "expired, ask kid for new one"
//  - Wrong code typo + retry counter (lockout after 5 wrong)
//  - Re-pairing after kid replaces machine
//
//  Worker-side rows (rate-limit, token replay) belong to Lane B and
//  live in worker/test/.
//

import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct PairingManagerTests {

    private let referenceTime = Date(timeIntervalSince1970: 1_736_400_000)

    @Test func generatedCodeIsSixDigitsAndExpiresInFiveMinutes() {
        let pairingManager = PairingManager(randomDigitsSource: { 123_456 })

        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        #expect(mintedCode.digits == "123456")
        #expect(mintedCode.digits.count == PairingManager.codeDigitCount)
        #expect(mintedCode.expiresAt == referenceTime.addingTimeInterval(5 * 60))
        #expect(pairingManager.activePairCode == mintedCode)
    }

    /// Leading-zero padding matters: digit boxes on Mom's screen render
    /// six monospace cells, and PairCode.digits is read directly by the
    /// equality compare. A 7-character or 5-character string would
    /// silently mismatch.
    @Test func generatedCodeIsZeroPaddedForSmallRandomValues() {
        let pairingManager = PairingManager(randomDigitsSource: { 42 })

        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        #expect(mintedCode.digits == "000042")
    }

    @Test func verifyHappyPathReturnsSuccessAndStoresToken() {
        let pairingManager = PairingManager(randomDigitsSource: { 555_555 })
        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        let outcome = pairingManager.verifyEnteredCode(
            "555555",
            against: mintedCode,
            now: referenceTime,
            sessionTokenOnSuccess: "session-abc"
        )

        #expect(outcome == .success)
        #expect(pairingManager.consecutiveWrongAttempts == 0)
        #expect(pairingManager.pairedPeerToken == "session-abc")
    }

    /// Phase 1 Test Plan row: "Code expiry (default 5min) → senior gets
    /// 'expired, ask kid for new one'."
    @Test func expiredCodeReturnsCodeExpired() {
        let pairingManager = PairingManager(randomDigitsSource: { 111_111 })
        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        let oneSecondPastExpiry = mintedCode.expiresAt.addingTimeInterval(1)
        let outcome = pairingManager.verifyEnteredCode(
            "111111",
            against: mintedCode,
            now: oneSecondPastExpiry
        )

        #expect(outcome == .codeExpired)
        #expect(pairingManager.pairedPeerToken == nil)
    }

    /// Phase 1 Test Plan row: "Wrong code typo + retry counter."
    /// The first four wrong attempts surface decreasing tries-remaining;
    /// the fifth pushes us into lockout.
    @Test func wrongAttemptsCountDownThenLockOutOnFifth() {
        let pairingManager = PairingManager(randomDigitsSource: { 999_999 })
        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        let firstWrong = pairingManager.verifyEnteredCode("000000", against: mintedCode, now: referenceTime)
        let secondWrong = pairingManager.verifyEnteredCode("000001", against: mintedCode, now: referenceTime)
        let thirdWrong = pairingManager.verifyEnteredCode("000002", against: mintedCode, now: referenceTime)
        let fourthWrong = pairingManager.verifyEnteredCode("000003", against: mintedCode, now: referenceTime)
        let fifthWrong = pairingManager.verifyEnteredCode("000004", against: mintedCode, now: referenceTime)

        #expect(firstWrong == .codeMismatch(triesRemaining: 4))
        #expect(secondWrong == .codeMismatch(triesRemaining: 3))
        #expect(thirdWrong == .codeMismatch(triesRemaining: 2))
        #expect(fourthWrong == .codeMismatch(triesRemaining: 1))
        let expectedUnlockAt = referenceTime.addingTimeInterval(60)
        #expect(fifthWrong == .lockedOut(unlockAt: expectedUnlockAt))
        #expect(pairingManager.lockoutUntil == expectedUnlockAt)
    }

    /// During lockout every attempt — even the right code — comes back
    /// `.lockedOut` so a brute-forcer can't sneak past the wall.
    @Test func attemptsDuringLockoutAreRejected() {
        let pairingManager = PairingManager(randomDigitsSource: { 999_999 })
        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        for _ in 0..<5 {
            _ = pairingManager.verifyEnteredCode("000000", against: mintedCode, now: referenceTime)
        }
        let unlockAt = pairingManager.lockoutUntil ?? Date.distantFuture

        let stillLockedOutOutcome = pairingManager.verifyEnteredCode(
            "999999", // correct code
            against: mintedCode,
            now: unlockAt.addingTimeInterval(-1)
        )

        #expect(stillLockedOutOutcome == .lockedOut(unlockAt: unlockAt))
        #expect(pairingManager.pairedPeerToken == nil)
    }

    /// After the lockout window elapses, the wrong-attempt counter MUST
    /// reset so a fat-finger event doesn't leave Mom permanently locked.
    @Test func attemptsAfterLockoutWindowResetsCounter() {
        let pairingManager = PairingManager(randomDigitsSource: { 999_999 })
        let mintedCode = pairingManager.generatePairCode(now: referenceTime)

        for _ in 0..<5 {
            _ = pairingManager.verifyEnteredCode("000000", against: mintedCode, now: referenceTime)
        }

        let oneSecondAfterLockout = referenceTime.addingTimeInterval(60 + 1)
        let firstAttemptAfterUnlock = pairingManager.verifyEnteredCode(
            "000000",
            against: mintedCode,
            now: oneSecondAfterLockout
        )

        // Counter should have reset to 0 before this attempt registered as +1.
        #expect(firstAttemptAfterUnlock == .codeMismatch(triesRemaining: 4))
        #expect(pairingManager.lockoutUntil == nil)
        #expect(pairingManager.consecutiveWrongAttempts == 1)
    }

    /// Phase 1 Test Plan row: "Re-pairing after kid replaces machine."
    /// Senior calls reset(), kid mints fresh code, senior verifies again.
    @Test func rePairingAfterResetSucceeds() {
        let pairingManager = PairingManager(randomDigitsSource: { 222_222 })
        let firstMintedCode = pairingManager.generatePairCode(now: referenceTime)
        _ = pairingManager.verifyEnteredCode(
            "222222",
            against: firstMintedCode,
            now: referenceTime
        )
        #expect(pairingManager.pairedPeerToken != nil)

        pairingManager.reset()

        // Imagine kid's new Mac mints a different code.
        let secondMintedCode = PairCode(
            digits: "333333",
            issuedAt: referenceTime,
            expiresAt: referenceTime.addingTimeInterval(5 * 60)
        )
        let secondPairOutcome = pairingManager.verifyEnteredCode(
            "333333",
            against: secondMintedCode,
            now: referenceTime,
            sessionTokenOnSuccess: "second-session"
        )

        #expect(secondPairOutcome == .success)
        #expect(pairingManager.pairedPeerToken == "second-session")
    }
}
