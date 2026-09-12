import assert from "node:assert/strict";
import test from "node:test";

import { ACTION_TYPES } from "../src/protocol.mjs";
import {
  ProductionActionRejector,
  QUALIFIED_CLI_VERSION,
  SessionObserver,
  productionActionCapabilities,
} from "../src/session-observer.mjs";

function fakeSession() {
  let listener;
  const calls = [];
  return {
    sessionId: "session-1",
    capabilities: {
      ui: {
        elicitation: true,
        canvases: false,
        mcpApps: false,
      },
    },
    rpc: {
      mode: {
        get: async () => {
          calls.push("mode.get");
          return "plan";
        },
      },
      model: {
        getCurrent: async () => {
          calls.push("model.getCurrent");
          return {
            modelId: "gpt-qualified",
            reasoningEffort: "medium",
            contextTier: "default",
          };
        },
        list: async () => {
          calls.push("model.list");
          return {
            models: [{
              id: "gpt-qualified",
              supportedReasoningEfforts: ["high", "medium", "low"],
            }],
          };
        },
      },
      tasks: {
        list: async () => {
          calls.push("tasks.list");
          return {
            tasks: [
              { status: "running", type: "agent" },
              { status: "completed", type: "shell" },
            ],
          };
        },
      },
      queue: {
        pendingItems: async () => {
          calls.push("queue.pendingItems");
          return { items: [{ kind: "message" }] };
        },
      },
      permissions: {
        pendingRequests: async () => {
          calls.push("permissions.pendingRequests");
          return { items: [{ requestId: "private-request-id" }] };
        },
      },
    },
    on(callback) {
      listener = callback;
      return () => {
        listener = undefined;
      };
    },
    emit(event) {
      listener?.(event);
    },
    calls,
  };
}

function binding(generation = "generation-1") {
  return {
    instanceId: "cli-host-100",
    sessionId: "session-1",
    generation,
  };
}

test("production capabilities are compatibility-aware and never stateful", () => {
  const qualified = productionActionCapabilities(QUALIFIED_CLI_VERSION);
  assert.deepEqual(Object.keys(qualified), ACTION_TYPES);
  assert.equal(
    Object.values(qualified).some((capability) => capability.status === "supported"),
    false,
  );
  assert.equal(qualified["session.cycleMode"].status, "blocked");
  assert.equal(qualified["composer.submit"].status, "unavailable");
  assert.equal(qualified["permission.approveOnce"].gapReference, "I-15");

  const unknown = productionActionCapabilities("1.0.85");
  assert.equal(
    Object.values(unknown).every((capability) => capability.status === "unknown"),
    true,
  );
  assert.match(unknown["session.cycleMode"].reason, /Compatibility is unqualified/u);
});

test("a new extension lifetime is unknown until a reconciled snapshot", async () => {
  const session = fakeSession();
  const payloads = [];
  const observer = new SessionObserver({ session, binding: binding() });
  observer.subscribe();
  await observer.attach((payload) => payloads.push(structuredClone(payload)));

  assert.equal(payloads[0].messageType, "sessionSnapshot");
  assert.equal(payloads[0].connection, "synchronizing");
  assert.equal(payloads[0].mode, null);
  assert.equal(payloads[0].work.known, false);
  assert.equal(payloads[0].attention.known, false);
  assert.equal(payloads[1].connection, "ready");
  assert.equal(payloads[1].mode, "plan");
  assert.equal(payloads[1].work.known, false);
  assert.equal(payloads[1].attention.permissionCount, 1);
  assert.deepEqual(payloads.map((payload) => payload.contextRevision), [1, 2]);
  assert.deepEqual(session.calls.sort(), [
    "mode.get",
    "model.getCurrent",
    "model.list",
    "permissions.pendingRequests",
    "queue.pendingItems",
    "tasks.list",
  ]);
  assert.equal(JSON.stringify(payloads).includes("private-request-id"), false);
  observer.stop();
});

test("qualified events force ordered reconciliation and capability changes", async () => {
  const session = fakeSession();
  const payloads = [];
  const observer = new SessionObserver({ session, binding: binding() });
  observer.subscribe();
  await observer.attach((payload) => payloads.push(structuredClone(payload)));

  session.emit({
    type: "session.start",
    data: { copilotVersion: QUALIFIED_CLI_VERSION },
  });
  session.emit({ type: "assistant.turn_start", data: {} });
  await observer.flush();

  const events = payloads.filter((payload) => payload.messageType === "sessionEvent");
  const snapshots = payloads.filter((payload) => payload.messageType === "sessionSnapshot");
  const latest = snapshots.at(-1);
  assert.deepEqual(events.map((event) => event.contextRevision), [3, 4]);
  assert.equal(latest.contextRevision, 4);
  assert.equal(latest.work.known, true);
  assert.equal(latest.work.foregroundActive, true);
  assert.equal(latest.work.backgroundCount, 1);
  assert.equal(latest.work.queuedCount, 1);
  assert.equal(latest.compatibility.status, "qualifiedReadOnly");
  assert.equal(latest.capabilities["session.cycleMode"].status, "blocked");
  assert.equal(latest.capabilities["composer.submit"].status, "unavailable");
  assert.equal(latest.model.modelId, "gpt-qualified");
  assert.equal(latest.pendingAttention.length, 0);
  assert.equal(latest.attention.permissionCount, 1);
  assert.equal(observer.heartbeatPayload().contextRevision, 4);
  observer.stop();
});

test("every production action is rejected without invoking an SDK mutation", async () => {
  const session = fakeSession();
  const observer = new SessionObserver({ session, binding: binding() });
  observer.subscribe();
  await observer.attach(() => {});
  session.emit({
    type: "session.start",
    data: { copilotVersion: QUALIFIED_CLI_VERSION },
  });
  session.emit({ type: "assistant.turn_start", data: {} });
  await observer.flush();
  const rejector = new ProductionActionRejector(observer);

  for (const [index, action] of ACTION_TYPES.entries()) {
    const result = rejector.reject({
      protocolVersion: 1,
      messageType: "action",
      requestId: `request-${index}`,
      ...binding(),
      contextRevision: observer.contextRevision,
      action: action.startsWith("permission.")
        ? { type: action, permissionRequestId: "permission-1" }
        : { type: action },
    });
    assert.equal(result.outcome, "rejected", action);
    assert.match(result.code, /^capability(?:Blocked|Unavailable)$/u, action);
    assert.match(result.message, /I-15/u, action);
  }
  assert.deepEqual(session.calls.filter((call) => call.includes("set")), []);
  observer.stop();
});

test("stale lifetime and duplicate actions fail explicitly", async () => {
  const session = fakeSession();
  const observer = new SessionObserver({ session, binding: binding("generation-current") });
  observer.subscribe();
  await observer.attach(() => {});
  const rejector = new ProductionActionRejector(observer);
  const request = {
    protocolVersion: 1,
    messageType: "action",
    requestId: "request-1",
    ...binding("generation-current"),
    contextRevision: observer.contextRevision,
    action: { type: "composer.submit" },
  };

  assert.equal(rejector.reject({ ...request, generation: "generation-old" }).code, "staleGeneration");
  assert.equal(rejector.reject(request).code, "capabilityUnknown");
  assert.equal(rejector.reject(request).code, "duplicateRequest");
  observer.stop();
});
