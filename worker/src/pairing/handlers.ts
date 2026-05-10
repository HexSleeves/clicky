/**
 * /pair/generate and /pair/verify HTTP handlers.
 *
 * Both routes thin-wrap a PairingSessionDO:
 *   - generate: mints a new DO id, calls /init, returns code+pairId.
 *   - verify:   parses pairId from body, forwards code, returns the
 *               DO's outcome (success/codeExpired/codeMismatch/lockedOut).
 *
 * Brute-force defense lives inside the DO (5-attempt hard cap per
 * pairId). No additional Worker-tier rate limit is needed for Phase 1
 * because the cap is identity-bound, not IP-bound — an attacker who
 * rotates IPs still only gets 5 attempts per stolen pairId.
 */

import type {
  InitResponseBody,
  VerifyResponseBody,
} from "./PairingSessionDO";

export interface PairingEnv {
  PAIRING_SESSIONS: DurableObjectNamespace;
}

export interface GenerateResponseBody {
  pairId: string;
  code: string;
  expiresAt: number;
  /// Pre-minted at /pair/generate so the kid can authenticate against
  /// the relay endpoints (/signal/:pairId/{send,poll}) immediately,
  /// without waiting on the senior's /pair/verify round-trip. The
  /// senior receives the SAME token from /pair/verify on success.
  sessionToken: string;
}

export async function handlePairGenerate(
  _request: Request,
  env: PairingEnv,
): Promise<Response> {
  const newPairId = env.PAIRING_SESSIONS.newUniqueId();
  const pairingDO = env.PAIRING_SESSIONS.get(newPairId);
  const initResponse = await pairingDO.fetch("https://do/init", {
    method: "POST",
  });

  if (!initResponse.ok) {
    const errorBody = await initResponse.text();
    console.error(`[/pair/generate] DO init failed: ${errorBody}`);
    return new Response(errorBody, {
      status: initResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  const initBody = (await initResponse.json()) as InitResponseBody;
  const responseBody: GenerateResponseBody = {
    pairId: newPairId.toString(),
    code: initBody.code,
    expiresAt: initBody.expiresAt,
    sessionToken: initBody.sessionToken,
  };
  return new Response(JSON.stringify(responseBody), {
    status: 201,
    headers: { "content-type": "application/json" },
  });
}

export async function handlePairVerify(
  request: Request,
  env: PairingEnv,
): Promise<Response> {
  const requestBody = (await request.json().catch(() => null)) as
    | { pairId?: unknown; code?: unknown }
    | null;

  if (
    !requestBody ||
    typeof requestBody.pairId !== "string" ||
    typeof requestBody.code !== "string"
  ) {
    return new Response(
      JSON.stringify({
        error:
          "expected { pairId: string, code: string } in /pair/verify body",
      }),
      { status: 400, headers: { "content-type": "application/json" } },
    );
  }

  let pairDOId: DurableObjectId;
  try {
    pairDOId = env.PAIRING_SESSIONS.idFromString(requestBody.pairId);
  } catch (_error) {
    // Malformed id — treat as expired so we don't leak whether a given
    // id ever existed.
    const expiredResponseBody: VerifyResponseBody = { outcome: "codeExpired" };
    return new Response(JSON.stringify(expiredResponseBody), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const pairingDO = env.PAIRING_SESSIONS.get(pairDOId);
  return await pairingDO.fetch("https://do/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: requestBody.code }),
  });
}
