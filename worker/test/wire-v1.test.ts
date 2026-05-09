// Wire-protocol guards covering the Worker-side mirror of the v1
// schema. Lane B owns relay tier validation; Lane A's Swift tests
// cover encode/decode roundtrip on the app side.

import { describe, expect, it } from "vitest";
import {
  REMOTE_WIRE_PROTOCOL_VERSION,
  WireMessageKind,
  isWireEnvelope,
  type WireEnvelope,
} from "../src/wire/v1";

describe("wire-v1 envelope guard", () => {
  it("accepts a well-formed envelope", () => {
    const envelope: WireEnvelope = {
      v: REMOTE_WIRE_PROTOCOL_VERSION,
      kind: WireMessageKind.cursorCommand,
      id: "11111111-2222-3333-4444-555555555555",
      ts: 1_736_400_000_000,
    };
    expect(isWireEnvelope(envelope)).toBe(true);
  });

  it("rejects null", () => {
    expect(isWireEnvelope(null)).toBe(false);
  });

  it("rejects a missing field", () => {
    const partialEnvelope = {
      v: 1,
      kind: WireMessageKind.snapRequest,
      id: "x",
      // ts missing
    };
    expect(isWireEnvelope(partialEnvelope)).toBe(false);
  });

  it("rejects wrong primitive types", () => {
    const wronglyTypedEnvelope = {
      v: "1",                                    // string, not number
      kind: WireMessageKind.cursorCommand,
      id: "11111111-2222-3333-4444-555555555555",
      ts: 1_736_400_000_000,
    };
    expect(isWireEnvelope(wronglyTypedEnvelope)).toBe(false);
  });

  it("accepts unknown kind values for forward-compat", () => {
    // A v1.x sender that adds a new kind MUST pass the envelope guard.
    // Higher-level routers fall through to the unsupported branch.
    const futureKindEnvelope: WireEnvelope = {
      v: 1,
      kind: "click.macro",
      id: "11111111-2222-3333-4444-555555555555",
      ts: 1_736_400_000_000,
    };
    expect(isWireEnvelope(futureKindEnvelope)).toBe(true);
  });
});
