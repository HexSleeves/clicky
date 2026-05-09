/**
 * PairingSessionDO — single-pair Durable Object.
 *
 * One DO per pair attempt. Lifecycle:
 *   1. Worker `/pair/generate` calls `POST /init` → DO mints a 6-digit
 *      code, stores it with a 5-minute TTL, returns the code + pairId.
 *   2. Worker `/pair/verify` calls `POST /verify` → DO validates the
 *      submitted code, counts wrong attempts, locks out after 5, and
 *      mints a one-shot `sessionToken` on success.
 *   3. Subsequent /signal and /turn-credentials calls use the
 *      sessionToken to authenticate; the DO marks the token as
 *      consumed when the signaling handshake begins (replay defense).
 *
 * State persisted in `state.storage`:
 *   code:                 string ("123456")
 *   issuedAt:             number (unix ms)
 *   expiresAt:            number (unix ms)
 *   wrongAttemptCount:    number
 *   sessionToken:         string | null
 *   sessionTokenConsumed: boolean
 *
 * No raw secrets logged. The DO body never echoes the code back on
 * /verify success — the caller already has it; only the sessionToken
 * is returned.
 */

const PAIR_CODE_DIGIT_COUNT = 6;
const PAIR_CODE_EXPIRY_MS = 5 * 60 * 1000;
const MAX_WRONG_ATTEMPTS = 5;

interface PairingDOState {
  code: string;
  issuedAt: number;
  expiresAt: number;
  wrongAttemptCount: number;
  sessionToken: string | null;
  sessionTokenConsumed: boolean;
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
