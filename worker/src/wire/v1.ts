/**
 * Clicky remote-help wire protocol — v1.
 *
 * JSON envelope flowing over the WebRTC data channel between the kid app
 * and the senior app. The Cloudflare Worker only relays signaling traffic
 * (offer/answer/ICE) — it does not see data-channel payloads — but these
 * types live here so any Worker-side tooling, telemetry shim, or future
 * server-side relay can validate without re-deriving the schema.
 *
 * Mirror of leanring-buddy/Companion/RemoteSession/Wire/V1/*.swift. Both
 * sides MUST change in lockstep on a breaking edit; additive fields stay
 * on v1 because both decoders ignore unknown keys.
 */

export const REMOTE_WIRE_PROTOCOL_VERSION = 1 as const;

/** Discriminator strings used in the envelope `kind` field. */
export const WireMessageKind = {
  cursorCommand: "cursor.command",
  snapRequest: "snap.request",
  clickConfirmation: "click.confirmation",
} as const;

export type WireMessageKindName =
  (typeof WireMessageKind)[keyof typeof WireMessageKind];

/** Common envelope fields shared by every message. */
export interface WireEnvelope {
  /** Protocol version. v1 currently. */
  v: number;
  kind: WireMessageKindName | string; // string lets unknown future kinds round-trip
  /** UUID v4 string. */
  id: string;
  /** Unix epoch, milliseconds. Sender-clock; do not assume monotonic across senders. */
  ts: number;
}

/** Kid -> senior: fly the cursor overlay to a point on a specific screen. */
export interface CursorCommandPayload {
  x: number;
  y: number;
  screenIndex: number;
  label?: string | null;
}

/** Kid -> senior: ask for a fresh screenshot snap. */
export interface SnapRequestPayload {
  screenIndex?: number | null;
  reason?: string | null;
}

/** Bidirectional: confirm or decline a previously-proposed click action. */
export interface ClickConfirmationPayload {
  proposalId: string;
  decision: "confirmed" | "declined" | "timedOut";
  decidedAtUnixMilliseconds: number;
}

export interface CursorCommandMessage extends WireEnvelope {
  kind: typeof WireMessageKind.cursorCommand;
  data: CursorCommandPayload;
}

export interface SnapRequestMessage extends WireEnvelope {
  kind: typeof WireMessageKind.snapRequest;
  data: SnapRequestPayload;
}

export interface ClickConfirmationMessage extends WireEnvelope {
  kind: typeof WireMessageKind.clickConfirmation;
  data: ClickConfirmationPayload;
}

export type WireMessage =
  | CursorCommandMessage
  | SnapRequestMessage
  | ClickConfirmationMessage
  | (WireEnvelope & { data?: unknown }); // unknown future kinds

/**
 * Type guard — does this look like a v1 envelope at all?
 * Used at the relay tier to drop garbage before forwarding.
 */
export function isWireEnvelope(value: unknown): value is WireEnvelope {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.v === "number" &&
    typeof candidate.kind === "string" &&
    typeof candidate.id === "string" &&
    typeof candidate.ts === "number"
  );
}
