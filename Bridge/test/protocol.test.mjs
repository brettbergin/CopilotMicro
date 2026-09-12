import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  InFlightRequestTracker,
  LengthPrefixedFrameDecoder,
  MAXIMUM_IN_FLIGHT_REQUESTS,
  MAXIMUM_WIRE_BYTES,
  SequenceTracker,
  authenticateRegistration,
  encodeLengthPrefixedFrame,
  validateFrame,
  validateFrameDirection,
  validateRegistration,
} from "../src/protocol.mjs";

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const manifest = JSON.parse(
  fs.readFileSync(path.join(root, "Contracts", "fixtures", "ipc-v1", "manifest.json"), "utf8"),
);

test("shared IPC registration and frame fixtures pass", () => {
  assert.equal(manifest.schemaVersion, 1);
  for (const fixture of manifest.cases) {
    const data = fixture.generator === "oversized"
      ? Buffer.alloc(MAXIMUM_WIRE_BYTES + 1, 0x20)
      : Buffer.from(JSON.stringify(fixture.message));
    if (fixture.kind === "registration") {
      const decoded = validateRegistration(data);
      assert.equal(decoded.error ?? "valid", fixture.decode, fixture.name);
      if (!decoded.error) {
        const peerUid = fixture.peer === "different" ? 502 : 501;
        assert.equal(
          authenticateRegistration(decoded.value, {
            expectedToken: manifest.bootstrapToken,
            peerUid,
            expectedUid: 501,
          }),
          fixture.authentication,
          fixture.name,
        );
      }
      continue;
    }

    const decoded = validateFrame(data);
    assert.equal(decoded.error ?? "valid", fixture.decode, fixture.name);
    if (decoded.error) continue;
    assert.equal(
      validateFrameDirection(decoded.value, fixture.receiverRole),
      fixture.direction,
      fixture.name,
    );
    if (fixture.sequence) {
      const tracker = new SequenceTracker("generation-1");
      if (fixture.replay === "duplicate") {
        assert.equal(tracker.accept(decoded.value), "accepted", fixture.name);
      }
      assert.equal(tracker.accept(decoded.value), fixture.sequence, fixture.name);
    }
  }
});

test("length-prefix framing handles split and coalesced messages", () => {
  const first = encodeLengthPrefixedFrame(Buffer.from('{"first":true}'));
  const second = encodeLengthPrefixedFrame(Buffer.from('{"second":true}'));
  const decoder = new LengthPrefixedFrameDecoder();
  assert.deepEqual(decoder.append(first.subarray(0, 3)), []);
  assert.deepEqual(
    decoder.append(Buffer.concat([first.subarray(3), second])),
    [Buffer.from('{"first":true}'), Buffer.from('{"second":true}')],
  );
  assert.throws(
    () => new LengthPrefixedFrameDecoder().append(Buffer.from([0, 1, 0, 1])),
    /messageTooLarge/u,
  );
});

test("in-flight request tracking is bounded and invalidated on disconnect", () => {
  const tracker = new InFlightRequestTracker();
  assert.equal(tracker.begin("request-1"), "accepted");
  assert.equal(tracker.begin("request-1"), "duplicateRequest");
  for (let index = 2; index <= MAXIMUM_IN_FLIGHT_REQUESTS; index += 1) {
    assert.equal(tracker.begin(`request-${index}`), "accepted");
  }
  assert.equal(tracker.begin("request-overflow"), "tooManyInFlight");
  tracker.invalidate();
  assert.equal(tracker.count, 0);
  assert.equal(tracker.begin("request-1"), "accepted");
});
