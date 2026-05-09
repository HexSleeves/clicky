// Phase 1 Test Plan rows for the pairing endpoints (Worker side):
//   - generateCode + verifyCode happy path
//   - Code expiry → "expired"
//   - Wrong code typo + retry counter (lockout after 5)
//   - Worker rate-limit / brute-force defense (DO-level 5-attempt cap)
//   - Re-pairing after kid replaces machine (each /generate is fresh)
//   - Pair token replay rejected (consume-session-token gate)
//
// Tests fetch through SELF so they exercise the real Worker entry,
// the DO bindings, and the JSON contracts the Swift app will hit.

import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type {
  GenerateResponseBody,
} from "../src/pairing/handlers";
import type { VerifyResponseBody } from "../src/pairing/PairingSessionDO";

async function callPairGenerate(): Promise<GenerateResponseBody> {
  const generateResponse = await SELF.fetch("https://worker/pair/generate", {
    method: "POST",
  });
  expect(generateResponse.status).toBe(201);
  return (await generateResponse.json()) as GenerateResponseBody;
}

async function callPairVerify(
  pairId: string,
  code: string,
): Promise<VerifyResponseBody> {
  const verifyResponse = await SELF.fetch("https://worker/pair/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ pairId, code }),
  });
  expect(verifyResponse.status).toBe(200);
  return (await verifyResponse.json()) as VerifyResponseBody;
}

describe("/pair/generate", () => {
  it("mints a 6-digit code and returns a pairId + expiresAt", async () => {
    const generated = await callPairGenerate();
    expect(generated.code).toMatch(/^\d{6}$/);
    expect(generated.pairId.length).toBeGreaterThan(0);
    expect(generated.expiresAt).toBeGreaterThan(Date.now());
  });

  it("returns a different pairId on each call (re-pair after kid replaces machine)", async () => {
    const firstGenerated = await callPairGenerate();
    const secondGenerated = await callPairGenerate();
    expect(firstGenerated.pairId).not.toBe(secondGenerated.pairId);
  });
});

describe("/pair/verify happy path", () => {
  it("returns success + sessionToken for the matching code", async () => {
    const generated = await callPairGenerate();
    const verifyOutcome = await callPairVerify(generated.pairId, generated.code);
    expect(verifyOutcome.outcome).toBe("success");
    if (verifyOutcome.outcome === "success") {
      expect(verifyOutcome.sessionToken.length).toBeGreaterThanOrEqual(32);
    }
  });

  it("returning to the same pairId with the same code is idempotent (same token)", async () => {
    // Senior's network can drop the success response; on retry the DO
    // should return the SAME session token rather than minting a new
    // one. This protects against token churn during flaky pairing.
    const generated = await callPairGenerate();
    const firstVerifyOutcome = await callPairVerify(generated.pairId, generated.code);
    const secondVerifyOutcome = await callPairVerify(generated.pairId, generated.code);

    if (
      firstVerifyOutcome.outcome === "success" &&
      secondVerifyOutcome.outcome === "success"
    ) {
      expect(firstVerifyOutcome.sessionToken).toBe(secondVerifyOutcome.sessionToken);
    } else {
      expect.fail("expected both verifies to succeed");
    }
  });
});

describe("/pair/verify wrong code path (Phase 1 brute-force defense)", () => {
  it("counts down triesRemaining on each wrong attempt then locks out on the 5th", async () => {
    const generated = await callPairGenerate();
    const wrongCode = generated.code === "000000" ? "000001" : "000000";

    const firstWrong = await callPairVerify(generated.pairId, wrongCode);
    const secondWrong = await callPairVerify(generated.pairId, wrongCode);
    const thirdWrong = await callPairVerify(generated.pairId, wrongCode);
    const fourthWrong = await callPairVerify(generated.pairId, wrongCode);
    const fifthWrong = await callPairVerify(generated.pairId, wrongCode);

    expect(firstWrong).toEqual({ outcome: "codeMismatch", triesRemaining: 4 });
    expect(secondWrong).toEqual({ outcome: "codeMismatch", triesRemaining: 3 });
    expect(thirdWrong).toEqual({ outcome: "codeMismatch", triesRemaining: 2 });
    expect(fourthWrong).toEqual({ outcome: "codeMismatch", triesRemaining: 1 });
    expect(fifthWrong).toEqual({ outcome: "lockedOut" });
  });

  it("locks out subsequent attempts even with the correct code", async () => {
    const generated = await callPairGenerate();
    const wrongCode = generated.code === "999999" ? "999998" : "999999";

    for (let attemptIndex = 0; attemptIndex < 5; attemptIndex++) {
      await callPairVerify(generated.pairId, wrongCode);
    }
    const correctCodeAfterLockout = await callPairVerify(
      generated.pairId,
      generated.code,
    );

    expect(correctCodeAfterLockout).toEqual({ outcome: "lockedOut" });
  });
});

describe("/pair/verify error paths", () => {
  it("rejects malformed body with 400", async () => {
    const malformedResponse = await SELF.fetch("https://worker/pair/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(malformedResponse.status).toBe(400);
  });

  it("returns codeExpired for an unknown pairId (no oracle for valid ids)", async () => {
    const unknownPairOutcome = await callPairVerify(
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "123456",
    );
    expect(unknownPairOutcome.outcome).toBe("codeExpired");
  });

  it("returns codeExpired for a malformed pairId (don't leak existence)", async () => {
    const malformedPairOutcome = await callPairVerify("not-a-real-id", "123456");
    expect(malformedPairOutcome.outcome).toBe("codeExpired");
  });
});
