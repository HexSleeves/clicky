/**
 * /signal/:pairId routes — relay WebRTC offer/answer/ICE between kid
 * and senior. The actual mailbox state lives on the PairingSessionDO
 * (one DO per pair), so this file is a thin URL parser + DO forwarder.
 *
 * Routes (all POST):
 *   /signal/:pairId/send  → body: { sessionToken, from, kind, data }
 *   /signal/:pairId/poll  → body: { sessionToken, role }
 *   /signal/:pairId/end   → body: { sessionToken }
 *
 * Auth is the sessionToken returned from /pair/verify. The DO returns
 * 401 unauthorized for any token mismatch; we never reveal whether a
 * given pairId exists.
 */

import type { PairingEnv } from "../pairing/handlers";

const SIGNAL_ROUTE_PATTERN = /^\/signal\/([^/]+)\/(send|poll|end)$/;

export async function handleSignalRoute(
  request: Request,
  env: PairingEnv,
): Promise<Response | undefined> {
  const url = new URL(request.url);
  const matchResult = url.pathname.match(SIGNAL_ROUTE_PATTERN);
  if (!matchResult) return undefined;

  const [, pairIdString, signalSubroute] = matchResult;

  let pairDOId: DurableObjectId;
  try {
    pairDOId = env.PAIRING_SESSIONS.idFromString(pairIdString);
  } catch (_error) {
    return new Response(
      JSON.stringify({ outcome: "unauthorized" }),
      { status: 401, headers: { "content-type": "application/json" } },
    );
  }

  const pairingDO = env.PAIRING_SESSIONS.get(pairDOId);
  const requestBodyText = await request.text();
  return await pairingDO.fetch(`https://do/signal/${signalSubroute}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: requestBodyText,
  });
}
