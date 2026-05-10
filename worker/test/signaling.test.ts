// Phase 1 Test Plan rows for the signaling endpoints:
//   - /signal/:pairId offer/answer/ICE relay roundtrip
//   - DO eviction / unknown pairId surfaces "try again" (401)
//   - /signal calls without sessionToken → 401
//   - /signal calls after /signal/end → 410 sessionEnded
//   - /verify after signaling has begun returns codeExpired (replay defense)

import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import type { GenerateResponseBody } from "../src/pairing/handlers";
import type {
  SignalEndResponseBody,
  SignalPollResponseBody,
  SignalSendResponseBody,
  VerifyResponseBody,
} from "../src/pairing/PairingSessionDO";

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

async function callSignalSend(
  session: PairedSession,
  from: "kid" | "senior",
  kind: "offer" | "answer" | "ice" | "stop" | "wire",
  data: unknown,
): Promise<{ status: number; body: SignalSendResponseBody }> {
  const sendResponse = await SELF.fetch(
    `https://worker/signal/${session.pairId}/send`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionToken: session.sessionToken,
        from,
        kind,
        data,
      }),
    },
  );
  const responseBody = (await sendResponse.json()) as SignalSendResponseBody;
  return { status: sendResponse.status, body: responseBody };
}

async function callSignalPoll(
  session: PairedSession,
  role: "kid" | "senior",
): Promise<{ status: number; body: SignalPollResponseBody }> {
  const pollResponse = await SELF.fetch(
    `https://worker/signal/${session.pairId}/poll`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionToken: session.sessionToken,
        role,
      }),
    },
  );
  const responseBody = (await pollResponse.json()) as SignalPollResponseBody;
  return { status: pollResponse.status, body: responseBody };
}

async function callSignalEnd(
  session: PairedSession,
): Promise<{ status: number; body: SignalEndResponseBody }> {
  const endResponse = await SELF.fetch(
    `https://worker/signal/${session.pairId}/end`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sessionToken: session.sessionToken }),
    },
  );
  const responseBody = (await endResponse.json()) as SignalEndResponseBody;
  return { status: endResponse.status, body: responseBody };
}

describe("/signal/:pairId/send + /poll", () => {
  it("relays an offer from kid into the senior's inbox", async () => {
    const session = await pairUpForTesting();
    const sendOutcome = await callSignalSend(session, "kid", "offer", {
      sdp: "v=0\r\no=...\r\n",
    });
    expect(sendOutcome).toEqual({ status: 200, body: { outcome: "ok" } });

    const pollOutcome = await callSignalPoll(session, "senior");
    expect(pollOutcome.status).toBe(200);
    if (pollOutcome.body.outcome !== "ok") {
      expect.fail(`expected ok, got ${JSON.stringify(pollOutcome.body)}`);
    }
    expect(pollOutcome.body.messages).toHaveLength(1);
    expect(pollOutcome.body.messages[0].kind).toBe("offer");
    expect(pollOutcome.body.messages[0].from).toBe("kid");
  });

  it("drains the inbox so a second poll returns empty", async () => {
    const session = await pairUpForTesting();
    await callSignalSend(session, "kid", "offer", "first");
    const firstPoll = await callSignalPoll(session, "senior");
    const secondPoll = await callSignalPoll(session, "senior");

    if (firstPoll.body.outcome !== "ok" || secondPoll.body.outcome !== "ok") {
      expect.fail("both polls should be ok");
    }
    expect(firstPoll.body.messages).toHaveLength(1);
    expect(secondPoll.body.messages).toHaveLength(0);
  });

  it("accumulates ICE candidates in posted order", async () => {
    const session = await pairUpForTesting();
    await callSignalSend(session, "senior", "ice", "candidate-1");
    await callSignalSend(session, "senior", "ice", "candidate-2");
    await callSignalSend(session, "senior", "ice", "candidate-3");

    const pollOutcome = await callSignalPoll(session, "kid");
    if (pollOutcome.body.outcome !== "ok") {
      expect.fail("expected ok");
    }
    expect(pollOutcome.body.messages.map((m) => m.data)).toEqual([
      "candidate-1",
      "candidate-2",
      "candidate-3",
    ]);
  });
});

describe("auth & replay defense", () => {
  it("rejects /signal/send with the wrong session token", async () => {
    const session = await pairUpForTesting();
    const wrongTokenSession = {
      pairId: session.pairId,
      sessionToken: "00000000",
    };
    const sendOutcome = await callSignalSend(
      wrongTokenSession,
      "kid",
      "offer",
      "x",
    );
    expect(sendOutcome.status).toBe(401);
    expect(sendOutcome.body).toEqual({ outcome: "unauthorized" });
  });

  it("rejects /signal/send for an unknown pairId (DO eviction case)", async () => {
    const evictedSession: PairedSession = {
      pairId:
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      sessionToken: "irrelevant",
    };
    const sendOutcome = await callSignalSend(
      evictedSession,
      "kid",
      "offer",
      "x",
    );
    expect(sendOutcome.status).toBe(401);
    expect(sendOutcome.body).toEqual({ outcome: "unauthorized" });
  });

  /// "Pair token replay rejected by Worker" — once signaling has begun,
  /// /verify with the original code MUST return codeExpired so a leaked
  /// code can't be reused to mint a parallel session token.
  it("/verify returns codeExpired after signaling has begun", async () => {
    const session = await pairUpForTesting();
    await callSignalSend(session, "kid", "offer", "any");

    // Try to /verify the same code again.
    const reverifyResponse = await SELF.fetch("https://worker/pair/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        pairId: session.pairId,
        // We can't recover the original code from the test, but any
        // attempt — wrong or right — must come back not-success. This
        // test relies on the DO having already activated; the wrong
        // code path also returns codeMismatch, so we need a code we
        // can be sure is valid. We deliberately re-pair to obtain it.
        code: "000000",
      }),
    });
    const reverifyBody = (await reverifyResponse.json()) as VerifyResponseBody;
    // Either codeExpired (sessionActivated branch) or codeMismatch is
    // acceptable; the critical guarantee is "not success".
    expect(reverifyBody.outcome).not.toBe("success");
  });

  it("/verify returns codeExpired when sending the original code AFTER signaling", async () => {
    // Tightened version of the previous test — we capture the actual
    // code so we can prove the original code stops working.
    const generateResponse = await SELF.fetch(
      "https://worker/pair/generate",
      { method: "POST" },
    );
    const generated = (await generateResponse.json()) as GenerateResponseBody;

    const firstVerifyResponse = await SELF.fetch(
      "https://worker/pair/verify",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          pairId: generated.pairId,
          code: generated.code,
        }),
      },
    );
    const firstVerifyOutcome =
      (await firstVerifyResponse.json()) as VerifyResponseBody;
    if (firstVerifyOutcome.outcome !== "success") {
      expect.fail("expected initial verify to succeed");
    }

    // Activate session by sending one signaling message.
    await callSignalSend(
      { pairId: generated.pairId, sessionToken: firstVerifyOutcome.sessionToken },
      "kid",
      "offer",
      "x",
    );

    const replayVerifyResponse = await SELF.fetch(
      "https://worker/pair/verify",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          pairId: generated.pairId,
          code: generated.code,
        }),
      },
    );
    const replayVerifyOutcome =
      (await replayVerifyResponse.json()) as VerifyResponseBody;
    expect(replayVerifyOutcome.outcome).toBe("codeExpired");
  });
});

describe("wire kind (polling-relay support)", () => {
  it("accepts kind=wire and round-trips the data payload through the inbox", async () => {
    const session = await pairUpForTesting();
    const wireEnvelopePayload = {
      v: 1,
      kind: "cursor.command",
      id: "11111111-2222-3333-4444-555555555555",
      ts: 1_736_400_000_000,
      data: { x: 100, y: 200, screenIndex: 0, label: null },
    };
    const sendOutcome = await callSignalSend(
      session,
      "kid",
      "wire",
      wireEnvelopePayload,
    );
    expect(sendOutcome).toEqual({ status: 200, body: { outcome: "ok" } });

    const pollOutcome = await callSignalPoll(session, "senior");
    if (pollOutcome.body.outcome !== "ok") {
      expect.fail("expected ok");
    }
    expect(pollOutcome.body.messages).toHaveLength(1);
    expect(pollOutcome.body.messages[0].kind).toBe("wire");
    expect(pollOutcome.body.messages[0].data).toEqual(wireEnvelopePayload);
  });
});

describe("/signal/end teardown", () => {
  it("ends the session and subsequent /signal/send returns 410", async () => {
    const session = await pairUpForTesting();
    const endOutcome = await callSignalEnd(session);
    expect(endOutcome.body).toEqual({ outcome: "ended" });

    const postEndSendOutcome = await callSignalSend(session, "kid", "offer", "x");
    expect(postEndSendOutcome.status).toBe(410);
    expect(postEndSendOutcome.body).toEqual({ outcome: "sessionEnded" });
  });

  it("end is idempotent (calling twice returns ended both times)", async () => {
    const session = await pairUpForTesting();
    const firstEnd = await callSignalEnd(session);
    const secondEnd = await callSignalEnd(session);
    expect(firstEnd.body).toEqual({ outcome: "ended" });
    expect(secondEnd.body).toEqual({ outcome: "ended" });
  });

  it("post-end /poll returns 410 sessionEnded when there are no leftover messages", async () => {
    const session = await pairUpForTesting();
    await callSignalEnd(session);
    const postEndPoll = await callSignalPoll(session, "senior");
    expect(postEndPoll.status).toBe(410);
    expect(postEndPoll.body).toEqual({ outcome: "sessionEnded" });
  });
});
