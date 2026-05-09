// Phase 1 Test Plan: /turn-credentials issuance.
//   - Auth: requires a valid pairId + sessionToken from /pair/verify
//   - Returns standard TURN REST API credential triple (username,
//     credential, ttlSeconds, urls)
//   - Unauthorized session tokens / unknown pair ids → 401
//   - TTL field round-trip (10-minute default)

import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { GenerateResponseBody } from "../src/pairing/handlers";
import type { VerifyResponseBody } from "../src/pairing/PairingSessionDO";
import type { TurnCredentialsResponseBody } from "../src/turn/handlers";
import { TURN_CREDENTIAL_TTL_SECONDS } from "../src/turn/handlers";

interface PairedSession {
  pairId: string;
  sessionToken: string;
}

async function pairUpForTesting(): Promise<PairedSession> {
  const generateResponse = await SELF.fetch("https://worker/pair/generate", {
    method: "POST",
  });
  const generated = (await generateResponse.json()) as GenerateResponseBody;

  const verifyResponse = await SELF.fetch("https://worker/pair/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ pairId: generated.pairId, code: generated.code }),
  });
  const verifyOutcome = (await verifyResponse.json()) as VerifyResponseBody;
  if (verifyOutcome.outcome !== "success") {
    throw new Error(`pair-up failed: ${JSON.stringify(verifyOutcome)}`);
  }
  return { pairId: generated.pairId, sessionToken: verifyOutcome.sessionToken };
}

async function callTurnCredentials(
  body: { pairId: string; sessionToken: string },
): Promise<{ status: number; body: unknown }> {
  const turnResponse = await SELF.fetch("https://worker/turn-credentials", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: turnResponse.status, body: await turnResponse.json() };
}

describe("/turn-credentials happy path", () => {
  it("returns username + credential + TTL for a valid session", async () => {
    const session = await pairUpForTesting();
    const turnOutcome = await callTurnCredentials(session);

    expect(turnOutcome.status).toBe(200);
    const turnBody = turnOutcome.body as TurnCredentialsResponseBody;
    expect(turnBody.ttlSeconds).toBe(TURN_CREDENTIAL_TTL_SECONDS);
    expect(turnBody.urls.length).toBeGreaterThan(0);
    expect(turnBody.urls[0]).toMatch(/^turns?:/);
    // Username format: <expiryUnixSeconds>:<pairId>
    expect(turnBody.username).toMatch(/^\d+:[0-9a-f]+$/);
    // Credential is base64-encoded HMAC-SHA1 (20 bytes → 28 chars).
    expect(turnBody.credential.length).toBe(28);
  });

  it("encodes the expected expiry inside the username", async () => {
    const session = await pairUpForTesting();
    const turnOutcome = await callTurnCredentials(session);
    const turnBody = turnOutcome.body as TurnCredentialsResponseBody;

    const [expiryString] = turnBody.username.split(":");
    const expiryUnixSeconds = Number(expiryString);
    const nowUnixSeconds = Math.floor(Date.now() / 1000);
    expect(expiryUnixSeconds - nowUnixSeconds).toBeGreaterThan(
      TURN_CREDENTIAL_TTL_SECONDS - 5,
    );
    expect(expiryUnixSeconds - nowUnixSeconds).toBeLessThan(
      TURN_CREDENTIAL_TTL_SECONDS + 5,
    );
  });
});

describe("/turn-credentials auth", () => {
  it("rejects an unknown pairId with 401", async () => {
    const turnOutcome = await callTurnCredentials({
      pairId:
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      sessionToken: "any",
    });
    expect(turnOutcome.status).toBe(401);
  });

  it("rejects a malformed pairId with 401", async () => {
    const turnOutcome = await callTurnCredentials({
      pairId: "not-a-real-id",
      sessionToken: "any",
    });
    expect(turnOutcome.status).toBe(401);
  });

  it("rejects the wrong session token with 401", async () => {
    const session = await pairUpForTesting();
    const turnOutcome = await callTurnCredentials({
      pairId: session.pairId,
      sessionToken: "wrong-token",
    });
    expect(turnOutcome.status).toBe(401);
  });

  it("rejects malformed body with 400", async () => {
    const malformedResponse = await SELF.fetch(
      "https://worker/turn-credentials",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      },
    );
    expect(malformedResponse.status).toBe(400);
  });
});
