import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { connectAuthenticated } from "../src/client.mjs";
import {
  LengthPrefixedFrameDecoder,
  authenticateRegistration,
  encodeLengthPrefixedFrame,
  validateRegistration,
} from "../src/protocol.mjs";

const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

function registration(bootstrapToken = token) {
  return {
    protocolVersion: 1,
    messageType: "registration",
    role: "cliBridge",
    bootstrapToken,
    instanceId: "cli-instance-1",
    sessionId: "session-1",
    generation: "generation-1",
    bridgeVersion: "0.1.0",
    cliVersion: "1.0.84-5",
    sdkVersion: "host-provided",
  };
}

async function withServer(body, { sendAction = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-ipc-"));
  fs.chmodSync(directory, 0o700);
  const socketPath = path.join(directory, "bridge.sock");
  const server = net.createServer((socket) => {
    const decoder = new LengthPrefixedFrameDecoder();
    let authenticated = false;
    socket.on("data", (chunk) => {
      for (const frame of decoder.append(chunk)) {
        if (authenticated) continue;
        const decoded = validateRegistration(frame);
        const authentication = decoded.error
          ? "protocolViolation"
          : authenticateRegistration(decoded.value, {
              expectedToken: token,
              peerUid: process.getuid(),
              expectedUid: process.getuid(),
            });
        const accepted = authentication === "accepted";
        const response = encodeLengthPrefixedFrame(
          Buffer.from(
            JSON.stringify({
              protocolVersion: 1,
              messageType: "registrationResult",
              outcome: accepted ? "accepted" : "rejected",
              connectionId: accepted ? "connection-1" : null,
              code: accepted ? null : authentication,
              message: accepted ? "Authenticated." : "Registration rejected.",
            }),
          ),
        );
        authenticated = accepted;
        if (accepted && sendAction) {
          const action = (sequence, requestId) => encodeLengthPrefixedFrame(
            Buffer.from(
              JSON.stringify({
                protocolVersion: 1,
                messageType: "frame",
                role: "nativeApp",
                generation: "generation-1",
                sequence,
                payload: {
                  protocolVersion: 1,
                  messageType: "action",
                  requestId,
                  instanceId: "cli-instance-1",
                  sessionId: "session-1",
                  generation: "generation-1",
                  contextRevision: 42,
                  action: { type: "session.cancelForeground" },
                },
              }),
            ),
          );
          socket.write(Buffer.concat([
            response,
            action(1, "request-1"),
            action(2, "request-2"),
          ]));
        } else {
          socket.write(response);
        }
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.listen(socketPath, () => {
      fs.chmodSync(socketPath, 0o600);
      resolve();
    });
    server.once("error", reject);
  });
  try {
    await body(socketPath);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("client authenticates over an owner-only Unix socket", async () => {
  await withServer(async (socketPath) => {
    const client = await connectAuthenticated({ socketPath, registration: registration() });
    assert.equal(client.connectionId, "connection-1");
    client.close();
    assert.equal(fs.statSync(path.dirname(socketPath)).mode & 0o777, 0o700);
    assert.equal(fs.statSync(socketPath).mode & 0o777, 0o600);
  });
});

test("client fails closed when the bootstrap token is rejected", async () => {
  await withServer(async (socketPath) => {
    await assert.rejects(
      connectAuthenticated({
        socketPath,
        registration: registration("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
      }),
      /invalidToken/u,
    );
  });
});

test("client enforces frame roles and preserves coalesced server frames", async () => {
  await withServer(async (socketPath) => {
    const client = await connectAuthenticated({ socketPath, registration: registration() });
    const firstFrame = await client.receive();
    const secondFrame = await client.receive();
    assert.equal(firstFrame.payload.requestId, "request-1");
    assert.equal(secondFrame.payload.requestId, "request-2");
    assert.throws(
      () => client.sendPayload(firstFrame.payload),
      /wrongRole/u,
    );
    client.sendPayload({
      protocolVersion: 1,
      messageType: "actionResult",
      requestId: "request-1",
      outcome: "completed",
      message: "Completed.",
    });
    client.close();
  }, { sendAction: true });
});

test("authentication timeout destroys the pending socket", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-ipc-timeout-"));
  fs.chmodSync(directory, 0o700);
  const socketPath = path.join(directory, "bridge.sock");
  const sockets = new Set();
  let resolveClosed;
  const closed = new Promise((resolve) => {
    resolveClosed = resolve;
  });
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.resume();
    socket.on("close", () => {
      sockets.delete(socket);
      resolveClosed();
    });
    socket.on("error", () => {});
  });
  await new Promise((resolve, reject) => {
    server.listen(socketPath, resolve);
    server.once("error", reject);
  });
  try {
    await assert.rejects(
      connectAuthenticated({
        socketPath,
        registration: registration(),
        timeoutMilliseconds: 50,
      }),
      /timedOut/u,
    );
    await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error("closeTimedOut")), 500)),
    ]);
    assert.equal(sockets.size, 0);
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
