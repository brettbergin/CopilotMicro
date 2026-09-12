import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  EvidenceWriter,
  MAXIMUM_EVIDENCE_BYTES,
  MAXIMUM_EVIDENCE_RECORDS,
  aliasIdentifier,
  methodAvailability,
  runActiveProbes,
  runReadOnlyProbes,
  sanitizeRpcResult,
  sanitizeSessionEvent,
} from "../probe/probe-core.mjs";

function temporaryEvidence() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-probe-test-"));
  return {
    directory,
    path: path.join(directory, "evidence.jsonl"),
  };
}

function readRecords(evidencePath) {
  return fs.readFileSync(evidencePath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

test("evidence writer is bounded, private, and rejects symlinks", () => {
  const temporary = temporaryEvidence();
  try {
    const writer = new EvidenceWriter({
      outputPath: temporary.path,
      probeInstance: "probe-1",
      hostAlias: "host-1",
      now: () => new Date("2026-09-11T00:00:00Z"),
    });
    assert.equal(writer.record("process.started", "observed", { nodeVersion: "v25.8.2" }), true);
    const record = readRecords(temporary.path)[0];
    assert.deepEqual(Object.keys(record), [
      "schemaVersion",
      "probeInstance",
      "hostAlias",
      "sequence",
      "recordedAt",
      "kind",
      "status",
      "data",
    ]);
    assert.equal(fs.statSync(temporary.path).mode & 0o777, 0o600);
    assert.ok(fs.statSync(temporary.path).size < MAXIMUM_EVIDENCE_BYTES);

    const symlinkPath = path.join(temporary.directory, "linked.jsonl");
    fs.symlinkSync(temporary.path, symlinkPath);
    assert.throws(
      () => new EvidenceWriter({
        outputPath: symlinkPath,
        probeInstance: "probe-2",
        hostAlias: "host-1",
      }),
      /unsafeEvidencePath/u,
    );
  } finally {
    fs.rmSync(temporary.directory, { recursive: true, force: true });
  }
});

test("evidence record bound applies across replacement extension lifetimes", () => {
  const temporary = temporaryEvidence();
  try {
    const firstWriter = new EvidenceWriter({
      outputPath: temporary.path,
      probeInstance: "first-probe",
      hostAlias: "host-1",
    });
    const replacementWriter = new EvidenceWriter({
      outputPath: temporary.path,
      probeInstance: "replacement-probe",
      hostAlias: "host-1",
    });
    for (let index = 0; index < MAXIMUM_EVIDENCE_RECORDS; index += 1) {
      const writer = index % 2 === 0 ? firstWriter : replacementWriter;
      assert.equal(writer.record("process.started", "observed", {}), true);
    }
    assert.equal(firstWriter.record("process.started", "observed", {}), false);
    assert.equal(replacementWriter.record("process.started", "observed", {}), false);
    assert.equal(readRecords(temporary.path).length, MAXIMUM_EVIDENCE_RECORDS);
  } finally {
    fs.rmSync(temporary.directory, { recursive: true, force: true });
  }
});

test("session events omit prompts, paths, commands, and permission details", () => {
  const sessionAlias = aliasIdentifier("session", "secret-session-id");
  const permission = sanitizeSessionEvent({
    type: "permission.requested",
    agentId: undefined,
    data: {
      requestId: "request-secret",
      permissionRequest: {
        kind: "shell",
        command: "cat /Users/private/secret.txt",
      },
      promptRequest: {
        message: "Approve secret?",
      },
    },
  }, sessionAlias);
  const serialized = JSON.stringify(permission);
  assert.match(serialized, /request-[a-f0-9]{12}/u);
  assert.doesNotMatch(serialized, /request-secret|cat |Users|Approve secret/u);
  assert.equal(permission.requestKind, "shell");

  assert.equal(sanitizeSessionEvent({
    type: "assistant.message",
    data: { content: "private response" },
  }, sessionAlias), null);
});

test("RPC result sanitizers retain only bounded capability metadata", () => {
  const modelList = sanitizeRpcResult("model.list", {
    list: [{
      id: "gpt-test",
      name: "display name",
      supportedReasoningEfforts: ["low", "high"],
      capabilities: { supports: { reasoningEffort: true } },
      warningText: "private account warning",
    }],
    quotaSnapshots: { premium: { remaining: 1 } },
  });
  assert.deepEqual(modelList, {
    models: [{
      id: "gpt-test",
      reasoningEffort: true,
      supportedReasoningEfforts: ["high", "low"],
    }],
  });

  const queue = sanitizeRpcResult("queue.pendingItems", {
    items: [{ kind: "message", displayText: "private prompt" }],
    steeringMessages: ["private steering"],
    inFlightSteeringCount: 0,
  });
  assert.deepEqual(queue, {
    count: 1,
    kinds: { message: 1, command: 0 },
    steeringCount: 1,
    inFlightSteeringCount: 0,
  });
  assert.doesNotMatch(JSON.stringify(queue), /private/u);
  assert.deepEqual(
    sanitizeRpcResult("permissions.setRequired", {
      success: true,
      request: { command: "private command" },
    }),
    { success: true },
  );
});

test("source-only extension registers no hooks, tools, or permission handler", () => {
  const source = fs.readFileSync(
    path.join(path.dirname(import.meta.dirname), "probe", "extension.mjs"),
    "utf8",
  );
  assert.doesNotMatch(
    source,
    /registerTool|registerHook|onPermissionRequest|handlePendingPermissionRequest/u,
  );
  assert.match(source, /tools: \[\]/u);
});

test("read-only probes use only the allowlisted getters", async () => {
  const temporary = temporaryEvidence();
  const calls = [];
  const rpc = {
    mode: {
      get: async () => {
        calls.push("mode.get");
        return "interactive";
      },
      set: async () => {
        throw new Error("unexpected mutation");
      },
    },
    model: {
      getCurrent: async () => {
        calls.push("model.getCurrent");
        return { modelId: "gpt-test", reasoningEffort: "high" };
      },
      list: async () => {
        calls.push("model.list");
        return { list: [] };
      },
      setReasoningEffort: async () => {
        throw new Error("unexpected mutation");
      },
    },
    tasks: {
      list: async () => {
        calls.push("tasks.list");
        return { tasks: [] };
      },
    },
    queue: {
      pendingItems: async () => {
        calls.push("queue.pendingItems");
        return { items: [], steeringMessages: [] };
      },
    },
    permissions: {
      getMode: async () => {
        calls.push("permissions.getMode");
        return { mode: "manual" };
      },
      pendingRequests: async () => {
        calls.push("permissions.pendingRequests");
        return { items: [] };
      },
      setRequired: async () => {
        throw new Error("unexpected mutation");
      },
    },
    commands: {
      list: async () => {
        calls.push("commands.list");
        return { commands: [{ name: "model" }, { name: "private-plugin-command" }] };
      },
    },
    completions: {
      getTriggerCharacters: async () => {
        calls.push("completions.getTriggerCharacters");
        return { triggerCharacters: ["@", "#"] };
      },
    },
    extensions: {
      list: async () => {
        calls.push("extensions.list");
        return { extensions: [] };
      },
    },
  };
  try {
    const writer = new EvidenceWriter({
      outputPath: temporary.path,
      probeInstance: "probe-1",
      hostAlias: "host-1",
    });
    await runReadOnlyProbes({ rpc }, writer, async () => 7);
    assert.deepEqual(calls, [
      "mode.get",
      "model.getCurrent",
      "model.list",
      "tasks.list",
      "queue.pendingItems",
      "permissions.getMode",
      "permissions.pendingRequests",
      "commands.list",
      "completions.getTriggerCharacters",
      "extensions.list",
    ]);
    const serialized = fs.readFileSync(temporary.path, "utf8");
    assert.doesNotMatch(serialized, /private-plugin-command/u);
    assert.equal(methodAvailability(rpc)["sessions.open"], false);
  } finally {
    fs.rmSync(temporary.directory, { recursive: true, force: true });
  }
});

test("active probes round-trip only plan mode and the current effort", async () => {
  const temporary = temporaryEvidence();
  const calls = [];
  let mode = "interactive";
  const rpc = {
    mode: {
      get: async () => mode,
      set: async ({ mode: requestedMode }) => {
        calls.push(["mode.set", requestedMode]);
        mode = requestedMode;
        return { mode };
      },
    },
    model: {
      getCurrent: async () => ({ modelId: "gpt-test", reasoningEffort: "high" }),
      setReasoningEffort: async ({ reasoningEffort }) => {
        calls.push(["model.setReasoningEffort", reasoningEffort]);
        return { reasoningEffort };
      },
    },
  };
  try {
    const writer = new EvidenceWriter({
      outputPath: temporary.path,
      probeInstance: "probe-1",
      hostAlias: "host-1",
    });
    await runActiveProbes({ rpc }, writer);
    assert.deepEqual(calls, [
      ["mode.set", "plan"],
      ["mode.set", "interactive"],
      ["model.setReasoningEffort", "high"],
    ]);
    assert.equal(mode, "interactive");
  } finally {
    fs.rmSync(temporary.directory, { recursive: true, force: true });
  }
});
