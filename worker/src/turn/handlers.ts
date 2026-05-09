/**
 * /turn-credentials — issues short-lived TURN auth scoped to a paired
 * session.
 *
 * Pattern: standard TURN REST API time-limited credentials.
 *   username   = `${expiryUnixSeconds}:${pairId}`
 *   credential = base64( HMAC-SHA1( TURN_SHARED_SECRET, username ) )
 *
 * The TURN server is configured with the same shared secret and accepts
 * any (username, credential) pair where the HMAC matches AND the
 * expiry hasn't passed. This avoids cross-DO state lookups inside TURN
 * itself.
 *
 * Auth on the Worker side: caller must present the sessionToken from
 * /pair/verify; the Worker forwards to the PairingSessionDO's
 * lightweight /verify-session-token endpoint.
 */

import type { PairingEnv } from "../pairing/handlers";

export interface TurnCredentialsEnv extends PairingEnv {
  TURN_SHARED_SECRET: string;
  TURN_URLS?: string;
}

export const TURN_CREDENTIAL_TTL_SECONDS = 10 * 60;

const DEFAULT_TURN_URLS = [
  "turn:turn.cloudflare.com:3478?transport=udp",
  "turn:turn.cloudflare.com:3478?transport=tcp",
  "turns:turn.cloudflare.com:5349?transport=tcp",
] as const;

export interface TurnCredentialsResponseBody {
  username: string;
  credential: string;
  ttlSeconds: number;
  urls: string[];
}

export async function handleTurnCredentials(
  request: Request,
  env: TurnCredentialsEnv,
): Promise<Response> {
  const requestBody = (await request.json().catch(() => null)) as
    | { pairId?: unknown; sessionToken?: unknown }
    | null;

  if (
    !requestBody ||
    typeof requestBody.pairId !== "string" ||
    typeof requestBody.sessionToken !== "string"
  ) {
    return new Response(
      JSON.stringify({
        error:
          "expected { pairId: string, sessionToken: string } in /turn-credentials body",
      }),
      { status: 400, headers: { "content-type": "application/json" } },
    );
  }

  let pairDOId: DurableObjectId;
  try {
    pairDOId = env.PAIRING_SESSIONS.idFromString(requestBody.pairId);
  } catch (_error) {
    return new Response(
      JSON.stringify({ outcome: "unauthorized" }),
      { status: 401, headers: { "content-type": "application/json" } },
    );
  }

  const pairingDO = env.PAIRING_SESSIONS.get(pairDOId);
  const sessionTokenCheckResponse = await pairingDO.fetch(
    "https://do/verify-session-token",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sessionToken: requestBody.sessionToken }),
    },
  );
  if (!sessionTokenCheckResponse.ok) {
    return sessionTokenCheckResponse;
  }

  if (!env.TURN_SHARED_SECRET || env.TURN_SHARED_SECRET.length === 0) {
    console.error("[/turn-credentials] TURN_SHARED_SECRET is not configured");
    return new Response(
      JSON.stringify({ error: "TURN not configured" }),
      { status: 503, headers: { "content-type": "application/json" } },
    );
  }

  const expiryUnixSeconds =
    Math.floor(Date.now() / 1000) + TURN_CREDENTIAL_TTL_SECONDS;
  const username = `${expiryUnixSeconds}:${requestBody.pairId}`;
  const credential = await hmacSha1Base64(env.TURN_SHARED_SECRET, username);

  const responseBody: TurnCredentialsResponseBody = {
    username,
    credential,
    ttlSeconds: TURN_CREDENTIAL_TTL_SECONDS,
    urls: env.TURN_URLS
      ? env.TURN_URLS.split(",").map((s) => s.trim()).filter(Boolean)
      : Array.from(DEFAULT_TURN_URLS),
  };
  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function hmacSha1Base64(
  sharedSecret: string,
  message: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(sharedSecret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const signatureBuffer = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    encoder.encode(message),
  );
  const signatureBytes = new Uint8Array(signatureBuffer);
  let binaryString = "";
  for (let byteIndex = 0; byteIndex < signatureBytes.length; byteIndex++) {
    binaryString += String.fromCharCode(signatureBytes[byteIndex]);
  }
  return btoa(binaryString);
}
