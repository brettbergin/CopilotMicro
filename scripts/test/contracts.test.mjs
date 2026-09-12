import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  MAXIMUM_ACTION_BYTES,
  loadContractCatalogs,
  runContractChecks,
  validateActionGuard,
  validateActionRequest,
} from "../check-contracts.mjs";

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));

test("shared contract catalogs and fixtures pass", () => {
  assert.deepEqual(runContractChecks(root), {
    actionCount: 16,
    controlCount: 12,
    fixtureCount: 10,
  });
});

test("oversized messages fail before parsing or field validation", () => {
  const { actionCatalog } = loadContractCatalogs(root);
  const invalid = `{"unexpected":"${"x".repeat(MAXIMUM_ACTION_BYTES)}"}`;
  assert.deepEqual(validateActionRequest(invalid, actionCatalog), { error: "messageTooLarge" });
});

test("connection and capability failures remain distinct", () => {
  const { actionCatalog } = loadContractCatalogs(root);
  const request = JSON.parse(
    fs.readFileSync(path.join(root, "Contracts", "fixtures", "bridge-v1", "valid-cancel.json"), "utf8"),
  );
  const base = {
    binding: {
      instanceId: request.instanceId,
      sessionId: request.sessionId,
      generation: request.generation,
    },
    connection: "ready",
    contextRevision: request.contextRevision,
    capabilities: { [request.action.type]: "supported" },
    pendingRequestIds: new Set(),
    visiblePermissionRequestId: null,
  };
  assert.equal(validateActionGuard(request, { ...base, connection: "disconnected" }), "disconnected");
  assert.equal(validateActionGuard(request, { ...base, connection: "synchronizing" }), "unsynchronized");
  assert.equal(
    validateActionGuard(request, { ...base, capabilities: { [request.action.type]: "blocked" } }),
    "capabilityBlocked",
  );
  assert.equal(validateActionGuard(request, { ...base, capabilities: {} }), "capabilityUnknown");
});

test("catalog validation rejects duplicate actions without changing repository files", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-contracts-"));
  try {
    fs.cpSync(path.join(root, "Contracts"), path.join(directory, "Contracts"), { recursive: true });
    const actionsPath = path.join(directory, "Contracts", "actions.json");
    const actions = JSON.parse(fs.readFileSync(actionsPath, "utf8"));
    actions.actions.push(actions.actions[0]);
    fs.writeFileSync(actionsPath, JSON.stringify(actions));
    assert.throws(() => loadContractCatalogs(directory), /duplicate action ID/u);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
