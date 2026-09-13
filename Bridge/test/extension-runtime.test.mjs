import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  BOOTSTRAP_TOKEN_FILENAME,
  BRIDGE_DIRECTORY_ENVIRONMENT_KEY,
  BRIDGE_SOCKET_FILENAME,
  SURFACE_ASSOCIATION_ENVIRONMENT_KEY,
  createHostBinding,
  loadBridgeRuntimeConfiguration,
  loadSurfaceAssociationToken,
  runHostExtension,
} from "../src/extension-runtime.mjs";

const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const surfaceToken = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

async function withRuntimeDirectory(body) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-runtime-"));
  fs.chmodSync(directory, 0o700);
  const tokenPath = path.join(directory, BOOTSTRAP_TOKEN_FILENAME);
  fs.writeFileSync(tokenPath, token, { mode: 0o600 });
  const socketPath = path.join(directory, BRIDGE_SOCKET_FILENAME);
  const server = net.createServer((socket) => socket.resume());
  await new Promise((resolve, reject) => {
    server.listen(socketPath, resolve);
    server.once("error", reject);
  });
  fs.chmodSync(socketPath, 0o600);
  try {
    await body({ directory, tokenPath, socketPath });
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("runtime configuration reads only owner-restricted bridge material", async () => {
  await withRuntimeDirectory(async ({ directory, socketPath }) => {
    const configuration = loadBridgeRuntimeConfiguration({
      environment: { [BRIDGE_DIRECTORY_ENVIRONMENT_KEY]: directory },
    });
    assert.deepEqual(configuration, { socketPath, bootstrapToken: token });
  });
});

test("runtime configuration rejects permissive or symlinked bootstrap material", async () => {
  await withRuntimeDirectory(async ({ directory, tokenPath }) => {
    fs.chmodSync(tokenPath, 0o644);
    assert.throws(
      () => loadBridgeRuntimeConfiguration({
        environment: { [BRIDGE_DIRECTORY_ENVIRONMENT_KEY]: directory },
      }),
      /unsafeRuntimePermissions/u,
    );
  });
});

test("host identity remains separate from session and generation", () => {
  const first = createHostBinding({
    parentProcessID: 123,
    sessionID: "session-1",
    generation: "first",
  });
  const replacement = createHostBinding({
    parentProcessID: 123,
    sessionID: "session-2",
    generation: "second",
  });
  assert.equal(first.instanceId, replacement.instanceId);
  assert.notEqual(first.sessionId, replacement.sessionId);
  assert.notEqual(first.generation, replacement.generation);
});

test("surface association token is optional but strictly validated", () => {
  assert.equal(loadSurfaceAssociationToken({ environment: {} }), null);
  assert.equal(
    loadSurfaceAssociationToken({
      environment: { [SURFACE_ASSOCIATION_ENVIRONMENT_KEY]: surfaceToken },
    }),
    surfaceToken,
  );
  assert.throws(
    () => loadSurfaceAssociationToken({
      environment: { [SURFACE_ASSOCIATION_ENVIRONMENT_KEY]: "unsafe token" },
    }),
    /invalidSurfaceAssociationToken/u,
  );
});

test("host runtime registers no tools or hooks and rejects received actions", async () => {
  const sent = [];
  let registration;
  let joinOptions;
  let received = false;
  const session = {
    sessionId: "session-1",
    capabilities: { ui: {} },
    rpc: {
      mode: { get: async () => "interactive" },
      model: {
        getCurrent: async () => ({ modelId: "gpt-qualified" }),
        list: async () => ({ models: [] }),
      },
      tasks: { list: async () => ({ tasks: [] }) },
      queue: { pendingItems: async () => ({ items: [] }) },
      permissions: { pendingRequests: async () => ({ items: [] }) },
    },
    on() {
      return () => {};
    },
  };

  await assert.rejects(
    runHostExtension({
      joinSession: async (options) => {
        joinOptions = options;
        return session;
      },
      connect: async (input) => {
        registration = input.registration;
        return {
          sendPayload(payload) {
            sent.push(structuredClone(payload));
          },
          async receive() {
            if (received) throw new Error("disconnected");
            received = true;
            const snapshot = sent.findLast((payload) => payload.messageType === "sessionSnapshot");
            return {
              payload: {
                protocolVersion: 1,
                messageType: "action",
                requestId: "request-1",
                instanceId: input.registration.instanceId,
                sessionId: input.registration.sessionId,
                generation: input.registration.generation,
                contextRevision: snapshot.contextRevision,
                action: { type: "session.cycleMode" },
              },
            };
          },
          close() {},
        };
      },
      runtimeConfiguration: {
        socketPath: "/tmp/copilot-micro-runtime-test.sock",
        bootstrapToken: token,
      },
      parentProcessID: 321,
      maximumReconnectAttempts: 0,
      setIntervalFunction: () => "timer",
      clearIntervalFunction: () => {},
    }),
    /disconnected/u,
  );

  assert.deepEqual(joinOptions, { tools: [] });
  assert.equal(Object.hasOwn(joinOptions, "hooks"), false);
  assert.equal(Object.hasOwn(joinOptions, "permissionHandler"), false);
  assert.equal(registration.instanceId, "cli-host-321");
  assert.equal(registration.sessionId, "session-1");
  assert.equal(Object.hasOwn(registration, "surfaceAssociationToken"), false);
  assert.match(registration.generation, /^generation-/u);
  const result = sent.find((payload) => payload.messageType === "actionResult");
  assert.equal(result.outcome, "rejected");
  assert.equal(result.code, "capabilityUnknown");
});

test("bounded reconnects preserve the host and session but rotate generation", async () => {
  const controller = new AbortController();
  const registrations = [];
  const delays = [];
  let attempts = 0;
  const session = {
    sessionId: "session-1",
    capabilities: { ui: {} },
    rpc: {
      mode: { get: async () => "interactive" },
      model: {
        getCurrent: async () => ({ modelId: "gpt-qualified" }),
        list: async () => ({ models: [] }),
      },
      tasks: { list: async () => ({ tasks: [] }) },
      queue: { pendingItems: async () => ({ items: [] }) },
      permissions: { pendingRequests: async () => ({ items: [] }) },
    },
    on() {
      return () => {};
    },
  };

  await runHostExtension({
    joinSession: async () => session,
    connect: async ({ registration }) => {
      registrations.push(registration);
      attempts += 1;
      if (attempts === 1) throw new Error("disconnected");
      return {
        sendPayload() {},
        async receive() {
          controller.abort();
          throw new Error("disconnected");
        },
        close() {},
      };
    },
    runtimeConfiguration: {
      socketPath: "/tmp/copilot-micro-runtime-test.sock",
      bootstrapToken: token,
    },
    surfaceAssociationToken: surfaceToken,
    parentProcessID: 321,
    maximumReconnectAttempts: 1,
    signal: controller.signal,
    setIntervalFunction: () => "timer",
    clearIntervalFunction: () => {},
    delayFunction: async (milliseconds) => {
      delays.push(milliseconds);
    },
  });

  assert.equal(registrations.length, 2);
  assert.equal(registrations[0].instanceId, registrations[1].instanceId);
  assert.equal(registrations[0].sessionId, registrations[1].sessionId);
  assert.equal(
    registrations[0].surfaceAssociationToken,
    registrations[1].surfaceAssociationToken,
  );
  assert.notEqual(registrations[0].generation, registrations[1].generation);
  assert.deepEqual(delays, [250]);
});
