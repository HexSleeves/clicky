/**
 * Install identity + Stage A signature verification.
 *
 * Stage A is observe-only: every request is logged with whether it
 * carried a valid signature, but the result is NEVER used to gate the
 * response. Once the dashboard shows acceptable signed-request coverage
 * (Stage B), the gate flips on for app versions ≥ the threshold.
 *
 * Storage (KV namespace `INSTALLS`):
 *   installs:<install_id> → JSON `{ public_key, app_version, first_seen,
 *                                    last_seen, revoked? }`
 *   metrics:unsigned:<yyyy-mm-dd> → integer (cheap roll-up dashboarded later)
 */
import { sha256Hex } from "./crypto";

export interface InstallStoreEnv {
  INSTALLS: KVNamespace;
}

export interface InstallRecord {
  public_key: string; // base64 raw 32 bytes
  app_version: string;
  first_seen: number; // unix seconds
  last_seen: number;
  revoked?: boolean;
}

/**
 * POST /install/register
 * Body: { public_key: string, app_version?: string }
 * Returns: { install_id: string }
 */
export async function handleInstallRegister(
  request: Request,
  env: InstallStoreEnv
): Promise<Response> {
  try {
    const body = (await request.json()) as { public_key?: string; app_version?: string };

    if (!body.public_key || typeof body.public_key !== "string") {
      return new Response(JSON.stringify({ error: "missing public_key" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }

    // Sanity-check public key shape: Ed25519 raw is 32 bytes → 44 chars base64.
    if (body.public_key.length < 40 || body.public_key.length > 48) {
      return new Response(JSON.stringify({ error: "invalid public_key" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }

    const installId = crypto.randomUUID();
    const now = Math.floor(Date.now() / 1000);
    const record: InstallRecord = {
      public_key: body.public_key,
      app_version: body.app_version ?? "unknown",
      first_seen: now,
      last_seen: now,
    };

    await env.INSTALLS.put(`installs:${installId}`, JSON.stringify(record));

    return new Response(JSON.stringify({ install_id: installId }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  } catch (error) {
    console.error("[/install/register] error:", error);
    return new Response(JSON.stringify({ error: "internal" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

/**
 * Verifies signature headers on an incoming request. Stage A:
 *  - If headers missing → returns `{ result: "unsigned" }`, caller passes through.
 *  - If headers present + verify → returns `{ result: "valid" }`.
 *  - If headers present + verify fails → returns `{ result: "invalid", reason }`.
 *
 * Caller logs the result + bumps a per-day counter; the response is
 * NEVER rejected based on this outcome in Stage A.
 */
export async function verifySignedRequest(
  request: Request,
  body: ArrayBuffer,
  env: InstallStoreEnv
): Promise<
  | { result: "unsigned" }
  | { result: "valid"; installId: string; appVersion: string }
  | { result: "invalid"; reason: string }
> {
  const installId = request.headers.get("X-Milo-Install");
  const appVersion = request.headers.get("X-Milo-App-Version") ?? "unknown";
  const timestamp = request.headers.get("X-Milo-Timestamp");
  const nonce = request.headers.get("X-Milo-Nonce");
  const signatureB64 = request.headers.get("X-Milo-Signature");

  if (!installId || !timestamp || !nonce || !signatureB64) {
    return { result: "unsigned" };
  }

  // 5-minute timestamp tolerance. Anti-replay window — anything past
  // the bound is rejected even though signature would verify.
  const now = Math.floor(Date.now() / 1000);
  const ts = parseInt(timestamp, 10);
  if (Number.isNaN(ts) || Math.abs(now - ts) > 300) {
    return { result: "invalid", reason: "timestamp_out_of_window" };
  }

  // Replay protection: nonce reuse within 10 minutes is rejected.
  // KV with 600s TTL is cheap and sufficient for Stage A volume.
  const nonceKey = `nonce:${installId}:${nonce}`;
  const seen = await env.INSTALLS.get(nonceKey);
  if (seen) {
    return { result: "invalid", reason: "nonce_replayed" };
  }
  await env.INSTALLS.put(nonceKey, "1", { expirationTtl: 600 });

  // Look up the install's public key.
  const recordJson = await env.INSTALLS.get(`installs:${installId}`);
  if (!recordJson) {
    return { result: "invalid", reason: "install_not_found" };
  }
  let record: InstallRecord;
  try {
    record = JSON.parse(recordJson);
  } catch {
    return { result: "invalid", reason: "record_corrupt" };
  }
  if (record.revoked) {
    return { result: "invalid", reason: "revoked" };
  }

  // Reconstruct canonical bytes: METHOD\nPATH\nBODYHASH\nTIMESTAMP\nNONCE.
  const path = new URL(request.url).pathname;
  const bodyHash = await sha256Hex(body);
  const canonical = `${request.method.toUpperCase()}\n${path}\n${bodyHash}\n${timestamp}\n${nonce}`;

  // Decode public key + signature.
  let publicKeyBytes: Uint8Array;
  let signatureBytes: Uint8Array;
  try {
    publicKeyBytes = base64ToBytes(record.public_key);
    signatureBytes = base64ToBytes(signatureB64);
  } catch {
    return { result: "invalid", reason: "decode_failed" };
  }

  if (publicKeyBytes.length !== 32) {
    return { result: "invalid", reason: "public_key_wrong_length" };
  }
  if (signatureBytes.length !== 64) {
    return { result: "invalid", reason: "signature_wrong_length" };
  }

  let publicKey: CryptoKey;
  try {
    publicKey = await crypto.subtle.importKey(
      "raw",
      publicKeyBytes,
      { name: "Ed25519" },
      false,
      ["verify"]
    );
  } catch (error) {
    return { result: "invalid", reason: `import_key_failed: ${error}` };
  }

  let ok: boolean;
  try {
    ok = await crypto.subtle.verify(
      "Ed25519",
      publicKey,
      signatureBytes,
      new TextEncoder().encode(canonical)
    );
  } catch (error) {
    return { result: "invalid", reason: `verify_threw: ${error}` };
  }

  if (!ok) {
    return { result: "invalid", reason: "signature_mismatch" };
  }

  // Refresh last_seen so old installs can be aged out if needed.
  record.last_seen = now;
  await env.INSTALLS.put(`installs:${installId}`, JSON.stringify(record));

  return { result: "valid", installId, appVersion };
}

/**
 * Bumps the daily unsigned-request counter so Stage A → Stage B
 * progression is data-driven. KV "increment" is read-modify-write; OK
 * for low cardinality (one key per day).
 */
export async function recordSignatureOutcome(
  outcome: "unsigned" | "valid" | "invalid",
  env: InstallStoreEnv
): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const key = `metrics:${outcome}:${day}`;
  const current = parseInt((await env.INSTALLS.get(key)) ?? "0", 10);
  await env.INSTALLS.put(key, String(current + 1), { expirationTtl: 60 * 60 * 24 * 35 });
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
