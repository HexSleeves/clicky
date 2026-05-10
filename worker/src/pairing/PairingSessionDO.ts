/**
 * PairingSessionDO — single-pair Durable Object.
 *
 * One DO per pair attempt. Two-phase lifecycle:
 *
 *   Phase 1 (pairing):
 *     1. Worker `/pair/generate` calls `POST /init` → DO mints a 6-digit
 *        code, stores it with a 5-minute TTL, returns the code + pairId.
 *     2. Worker `/pair/verify` calls `POST /verify` → DO validates the
 *        submitted code, counts wrong attempts, locks out after 5, and
 *        mints a `sessionToken` on success.
 *
 *   Phase 2 (signaling):
 *     3. Worker `/signal/:pairId/send` and `/poll` call `POST /signal/*`
 *        with the sessionToken. The DO holds two mailboxes (kid + senior)
 *        for offer/answer/ICE relay. First `/signal/send` flips
 *        `sessionActivated`, after which further `/verify` attempts fail
 *        with `codeExpired` so a leaked-but-not-yet-consumed code can't
 *        be replayed into a parallel session.
 *     4. `/signal/end` marks the session terminated; further send/poll
 *        return 410 Gone.
 *
 * State persisted in `state.storage`:
 *   code:                 string ("123456")
 *   issuedAt:             number (unix ms)
 *   expiresAt:            number (unix ms)
 *   wrongAttemptCount:    number
 *   sessionToken:         string | null
 *   sessionTokenConsumed: boolean        (legacy gate, kept for backward
 *                                        compat; signaling uses
 *                                        sessionActivated instead)
 *   sessionActivated:     boolean        (true once /signal/send fires)
 *   endedAt:              number | null  (set on /signal/end)
 *   kidInbox:             SignalMessage[]
 *   seniorInbox:          SignalMessage[]
 *
 * No raw secrets logged. The DO body never echoes the code back on
 * /verify success — the caller already has it; only the sessionToken
 * is returned.
 */

const PAIR_CODE_DIGIT_COUNT = 6;
const PAIR_CODE_EXPIRY_MS = 5 * 60 * 1000;
const MAX_WRONG_ATTEMPTS = 5;

export type SignalRole = "kid" | "senior";
/// Lane B signal kinds. "offer" / "answer" / "ice" / "stop" are the
/// WebRTC handshake messages from the original design. "wire" is the
/// catch-all relay for the v1 RemoteWireMessage envelope (CursorCommand,
/// SnapDelivery, HelpSessionRequest, etc.) so the polling-relay
/// transport can ride on the same DO mailboxes until WebRTC ships.
export type SignalKind = "offer" | "answer" | "ice" | "stop" | "wire";

export interface SignalMessage {
  from: SignalRole;
  kind: SignalKind;
  data: unknown;
  postedAt: number;
}

interface PairingDOState {
  code: string;
  issuedAt: number;
  expiresAt: number;
  wrongAttemptCount: number;
  sessionToken: string | null;
  sessionTokenConsumed: boolean;
  sessionActivated: boolean;
  endedAt: number | null;
  kidInbox: SignalMessage[];
  seniorInbox: SignalMessage[];
}

export interface InitResponseBody {
  code: string;
  expiresAt: number;
}

export type VerifyResponseBody =
  | { outcome: "success"; sessionToken: string }
  | { outcome: "codeExpired" }
  | { outcome: "codeMismatch"; triesRemaining: number }
  | { outcome: "lockedOut" };

export interface ConsumeSessionTokenResponseBody {
  outcome: "consumed" | "replay" | "unknownToken";
}

export interface SignalSendRequestBody {
  sessionToken: string;
  from: SignalRole;
  kind: SignalKind;
  data: unknown;
}

export type SignalSendResponseBody =
  | { outcome: "ok" }
  | { outcome: "unauthorized" }
  | { outcome: "sessionEnded" };

export interface SignalPollRequestBody {
  sessionToken: string;
  role: SignalRole;
}

export type SignalPollResponseBody =
  | { outcome: "ok"; messages: SignalMessage[] }
  | { outcome: "unauthorized" }
  | { outcome: "sessionEnded" };

export type SignalEndResponseBody =
  | { outcome: "ended" }
  | { outcome: "unauthorized" };

export class PairingSessionDO implements DurableObject {
  private state: DurableObjectState;

  constructor(state: DurableObjectState, _env: unknown) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("method not allowed", { status: 405 });
    }

    switch (url.pathname) {
      case "/init":
        return await this.handleInit();
      case "/verify":
        return await this.handleVerify(request);
      case "/consume-session-token":
        return await this.handleConsumeSessionToken(request);
      case "/verify-session-token":
        return await this.handleVerifySessionToken(request);
      case "/signal/send":
        return await this.handleSignalSend(request);
      case "/signal/poll":
        return await this.handleSignalPoll(request);
      case "/signal/end":
        return await this.handleSignalEnd(request);
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private async handleInit(): Promise<Response> {
    const existingState = await this.loadState();
    if (existingState) {
      // Re-init of an already-active DO is a no-op so transient retries
      // don't blow away an in-flight pairing.
      const responseBody: InitResponseBody = {
        code: existingState.code,
        expiresAt: existingState.expiresAt,
      };
      return jsonResponse(responseBody, 200);
    }

    const issuedAt = Date.now();
    const newPairingState: PairingDOState = {
      code: generateRandom6DigitCode(),
      issuedAt,
      expiresAt: issuedAt + PAIR_CODE_EXPIRY_MS,
      wrongAttemptCount: 0,
      sessionToken: null,
      sessionTokenConsumed: false,
      sessionActivated: false,
      endedAt: null,
      kidInbox: [],
      seniorInbox: [],
    };
    await this.saveState(newPairingState);

    const responseBody: InitResponseBody = {
      code: newPairingState.code,
      expiresAt: newPairingState.expiresAt,
    };
    return jsonResponse(responseBody, 201);
  }

  private async handleVerify(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | { code?: unknown }
      | null;
    const submittedCode =
      requestBody && typeof requestBody.code === "string"
        ? requestBody.code
        : "";

    const currentState = await this.loadState();
    if (!currentState) {
      // No DO state means the kid never minted a code (or it expired
      // and was reaped). Senior-friendly outcome:
      const expiredResponseBody: VerifyResponseBody = { outcome: "codeExpired" };
      return jsonResponse(expiredResponseBody, 200);
    }

    if (currentState.wrongAttemptCount >= MAX_WRONG_ATTEMPTS) {
      const lockedOutResponseBody: VerifyResponseBody = { outcome: "lockedOut" };
      return jsonResponse(lockedOutResponseBody, 200);
    }

    // Replay defense (Phase 1 Test Plan: "Pair token replay rejected
    // by Worker"): once signaling has begun under this code's session
    // token, refuse further /verify attempts. We surface as codeExpired
    // so the API doesn't reveal the code WAS once correct.
    if (currentState.sessionActivated) {
      const expiredResponseBody: VerifyResponseBody = { outcome: "codeExpired" };
      return jsonResponse(expiredResponseBody, 200);
    }

    const now = Date.now();
    if (now >= currentState.expiresAt) {
      const expiredResponseBody: VerifyResponseBody = { outcome: "codeExpired" };
      return jsonResponse(expiredResponseBody, 200);
    }

    if (submittedCode === currentState.code) {
      // Mint session token if not already minted (idempotent for
      // back-to-back calls during a flaky network); but DO NOT mint a
      // new token if a previous one was already consumed.
      if (currentState.sessionToken && currentState.sessionTokenConsumed) {
        const lockedOutResponseBody: VerifyResponseBody = { outcome: "lockedOut" };
        return jsonResponse(lockedOutResponseBody, 200);
      }
      const sessionToken =
        currentState.sessionToken ?? generateRandomSessionToken();
      const successState: PairingDOState = {
        ...currentState,
        sessionToken,
        wrongAttemptCount: 0,
      };
      await this.saveState(successState);
      const successResponseBody: VerifyResponseBody = {
        outcome: "success",
        sessionToken,
      };
      return jsonResponse(successResponseBody, 200);
    }

    const incrementedState: PairingDOState = {
      ...currentState,
      wrongAttemptCount: currentState.wrongAttemptCount + 1,
    };
    await this.saveState(incrementedState);

    if (incrementedState.wrongAttemptCount >= MAX_WRONG_ATTEMPTS) {
      const lockedOutResponseBody: VerifyResponseBody = { outcome: "lockedOut" };
      return jsonResponse(lockedOutResponseBody, 200);
    }
    const triesRemaining = MAX_WRONG_ATTEMPTS - incrementedState.wrongAttemptCount;
    const mismatchResponseBody: VerifyResponseBody = {
      outcome: "codeMismatch",
      triesRemaining,
    };
    return jsonResponse(mismatchResponseBody, 200);
  }

  /**
   * Replay-defense entrypoint. Called by /signal handlers the first time
   * they see a session token: marks the token consumed. Subsequent calls
   * with the same token are rejected.
   */
  private async handleConsumeSessionToken(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | { sessionToken?: unknown }
      | null;
    const submittedToken =
      requestBody && typeof requestBody.sessionToken === "string"
        ? requestBody.sessionToken
        : "";

    const currentState = await this.loadState();
    if (!currentState || currentState.sessionToken === null) {
      const unknownResponseBody: ConsumeSessionTokenResponseBody = {
        outcome: "unknownToken",
      };
      return jsonResponse(unknownResponseBody, 200);
    }

    if (submittedToken !== currentState.sessionToken) {
      const unknownResponseBody: ConsumeSessionTokenResponseBody = {
        outcome: "unknownToken",
      };
      return jsonResponse(unknownResponseBody, 200);
    }

    if (currentState.sessionTokenConsumed) {
      const replayResponseBody: ConsumeSessionTokenResponseBody = {
        outcome: "replay",
      };
      return jsonResponse(replayResponseBody, 200);
    }

    const consumedState: PairingDOState = {
      ...currentState,
      sessionTokenConsumed: true,
    };
    await this.saveState(consumedState);
    const consumedResponseBody: ConsumeSessionTokenResponseBody = {
      outcome: "consumed",
    };
    return jsonResponse(consumedResponseBody, 200);
  }

  // MARK: - Lightweight session-token check used by sibling endpoints
  // (e.g. /turn-credentials) that don't need to mutate state.

  private async handleVerifySessionToken(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | { sessionToken?: unknown }
      | null;
    const submittedToken =
      requestBody && typeof requestBody.sessionToken === "string"
        ? requestBody.sessionToken
        : "";

    const currentState = await this.loadState();
    if (
      !currentState ||
      currentState.sessionToken === null ||
      submittedToken !== currentState.sessionToken
    ) {
      return jsonResponse({ outcome: "unauthorized" }, 401);
    }
    if (currentState.endedAt !== null) {
      return jsonResponse({ outcome: "sessionEnded" }, 410);
    }
    return jsonResponse({ outcome: "ok" }, 200);
  }

  // MARK: - Signaling

  private async handleSignalSend(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | Partial<SignalSendRequestBody>
      | null;

    const currentState = await this.loadState();
    if (!currentState) {
      const unauthorizedBody: SignalSendResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }
    if (
      !requestBody ||
      typeof requestBody.sessionToken !== "string" ||
      requestBody.sessionToken !== currentState.sessionToken
    ) {
      const unauthorizedBody: SignalSendResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }
    if (currentState.endedAt !== null) {
      const endedBody: SignalSendResponseBody = { outcome: "sessionEnded" };
      return jsonResponse(endedBody, 410);
    }
    if (
      requestBody.from !== "kid" &&
      requestBody.from !== "senior"
    ) {
      return jsonResponse({ error: "invalid `from`" }, 400);
    }
    if (
      requestBody.kind !== "offer" &&
      requestBody.kind !== "answer" &&
      requestBody.kind !== "ice" &&
      requestBody.kind !== "stop" &&
      requestBody.kind !== "wire"
    ) {
      return jsonResponse({ error: "invalid `kind`" }, 400);
    }

    const peerInboxKey: "kidInbox" | "seniorInbox" =
      requestBody.from === "kid" ? "seniorInbox" : "kidInbox";
    const newSignalMessage: SignalMessage = {
      from: requestBody.from,
      kind: requestBody.kind,
      data: requestBody.data,
      postedAt: Date.now(),
    };
    const updatedState: PairingDOState = {
      ...currentState,
      sessionActivated: true,
      [peerInboxKey]: [...currentState[peerInboxKey], newSignalMessage],
    };
    await this.saveState(updatedState);

    const okBody: SignalSendResponseBody = { outcome: "ok" };
    return jsonResponse(okBody, 200);
  }

  private async handleSignalPoll(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | Partial<SignalPollRequestBody>
      | null;

    const currentState = await this.loadState();
    if (!currentState) {
      const unauthorizedBody: SignalPollResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }
    if (
      !requestBody ||
      typeof requestBody.sessionToken !== "string" ||
      requestBody.sessionToken !== currentState.sessionToken
    ) {
      const unauthorizedBody: SignalPollResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }
    if (requestBody.role !== "kid" && requestBody.role !== "senior") {
      return jsonResponse({ error: "invalid `role`" }, 400);
    }
    if (currentState.endedAt !== null) {
      // Drain remaining + report ended so caller can flush UI state.
      const inboxKey: "kidInbox" | "seniorInbox" =
        requestBody.role === "kid" ? "kidInbox" : "seniorInbox";
      const drainedMessages = currentState[inboxKey];
      const drainedState: PairingDOState = {
        ...currentState,
        [inboxKey]: [],
      };
      await this.saveState(drainedState);
      const endedBody: SignalPollResponseBody =
        drainedMessages.length > 0
          ? { outcome: "ok", messages: drainedMessages }
          : { outcome: "sessionEnded" };
      return jsonResponse(endedBody, drainedMessages.length > 0 ? 200 : 410);
    }

    const inboxKey: "kidInbox" | "seniorInbox" =
      requestBody.role === "kid" ? "kidInbox" : "seniorInbox";
    const drainedMessages = currentState[inboxKey];
    const drainedState: PairingDOState = {
      ...currentState,
      [inboxKey]: [],
    };
    await this.saveState(drainedState);
    const okBody: SignalPollResponseBody = {
      outcome: "ok",
      messages: drainedMessages,
    };
    return jsonResponse(okBody, 200);
  }

  private async handleSignalEnd(request: Request): Promise<Response> {
    const requestBody = (await request.json().catch(() => null)) as
      | { sessionToken?: unknown }
      | null;

    const currentState = await this.loadState();
    if (!currentState) {
      const unauthorizedBody: SignalEndResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }
    if (
      !requestBody ||
      typeof requestBody.sessionToken !== "string" ||
      requestBody.sessionToken !== currentState.sessionToken
    ) {
      const unauthorizedBody: SignalEndResponseBody = { outcome: "unauthorized" };
      return jsonResponse(unauthorizedBody, 401);
    }

    if (currentState.endedAt !== null) {
      const idempotentEndBody: SignalEndResponseBody = { outcome: "ended" };
      return jsonResponse(idempotentEndBody, 200);
    }

    const endedState: PairingDOState = {
      ...currentState,
      endedAt: Date.now(),
    };
    await this.saveState(endedState);

    const endedBody: SignalEndResponseBody = { outcome: "ended" };
    return jsonResponse(endedBody, 200);
  }

  private async loadState(): Promise<PairingDOState | null> {
    const persisted = await this.state.storage.get<PairingDOState>("pairing");
    return persisted ?? null;
  }

  private async saveState(nextState: PairingDOState): Promise<void> {
    await this.state.storage.put("pairing", nextState);
  }
}

function generateRandom6DigitCode(): string {
  const randomBytes = new Uint32Array(1);
  crypto.getRandomValues(randomBytes);
  const sixDigitInteger = randomBytes[0] % 1_000_000;
  return sixDigitInteger.toString().padStart(PAIR_CODE_DIGIT_COUNT, "0");
}

function generateRandomSessionToken(): string {
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  return Array.from(randomBytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
