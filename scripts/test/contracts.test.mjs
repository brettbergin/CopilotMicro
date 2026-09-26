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
  validateJsonSchema,
  validateActionGuard,
  validateActionRequest,
} from "../check-contracts.mjs";

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));

test("shared contract catalogs and fixtures pass", () => {
  assert.deepEqual(runContractChecks(root), {
    actionCount: 16,
    controlCount: 12,
    fixtureCount: 13,
    resultFixtureCount: 5,
    configurationSchemaCount: 2,
    cliCapabilityEvidenceSchemaCount: 1,
    cliCompatibilityReportCount: 1,
    hardwareCapabilityEvidenceSchemaCount: 1,
    hardwareCompatibilityReportCount: 1,
    ipcFixtureCount: 23,
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
  assert.equal(validateActionGuard(request, { ...base, paused: true }), "paused");
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

test("committed CLI evidence keeps unsafe capabilities disabled", () => {
  const reportPath = path.join(root, "Compatibility", "copilot-cli-1.0.84-5.json");
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  assert.equal(report.schemaVersion, 1);
  assert.equal(report.environment.cliVersion, "1.0.84-5");
  assert.equal(report.environment.cliBuildCommit, "0de509ce");
  assert.equal(report.environment.sdkVersion, "1.0.13-preview.4");
  assert.equal(report.environment.sdkProtocolVersion, null);
  assert.equal(report.lifecycle.sameHostAcrossReplacement, true);
  assert.equal(report.capabilities["U-01"].status, "partial");
  assert.equal(report.capabilities["U-07"].status, "unavailable");
  assert.equal(report.capabilities["U-08"].status, "partial");
  assert.ok(fs.statSync(reportPath).size < 131_072);
});

test("CLI evidence schema rejects missing, extra, and oversized fields", () => {
  const { cliCapabilityEvidenceSchema } = loadContractCatalogs(root);
  const report = JSON.parse(
    fs.readFileSync(
      path.join(root, "Compatibility", "copilot-cli-1.0.84-5.json"),
      "utf8",
    ),
  );
  const missing = structuredClone(report);
  delete missing.capabilities["U-02"];
  assert.throws(
    () => validateJsonSchema(cliCapabilityEvidenceSchema, missing),
    /U-02 is required/u,
  );
  const extra = structuredClone(report);
  extra.environment.token = "secret";
  assert.throws(
    () => validateJsonSchema(cliCapabilityEvidenceSchema, extra),
    /token is not allowed/u,
  );
  const oversized = structuredClone(report);
  oversized.capabilities["U-01"].evidence[0] = "x".repeat(241);
  assert.throws(
    () => validateJsonSchema(cliCapabilityEvidenceSchema, oversized),
    /longer than maxLength/u,
  );
});

test("committed hardware evidence is read-only and schema-valid", () => {
  const { hardwareCapabilityEvidenceSchema } = loadContractCatalogs(root);
  const report = JSON.parse(
    fs.readFileSync(
      path.join(
        root,
        "Compatibility",
        "creator-micro-2-0x8298-firmware-0.6.2-usb.json",
      ),
      "utf8",
    ),
  );
  assert.equal(validateJsonSchema(hardwareCapabilityEvidenceSchema, report), true);
  assert.equal(report.outcome, "read-only-qualified");
  assert.equal(report.mutatingOperationsPerformed, false);
  assert.deepEqual(report.keymap.activeLayerKeyRowLengths, [2, 4, 4, 3]);
  assert.equal(report.status.activeLayerIndex, 1);
  assert.equal(Object.hasOwn(report, "serialNumber"), false);
});

test("production extension source remains passive and uninstalled", () => {
  const sourceFiles = [
    "Bridge/src/extension.mjs",
    "Bridge/src/extension-runtime.mjs",
    "Bridge/src/session-observer.mjs",
  ];
  const source = sourceFiles
    .map((file) => fs.readFileSync(path.join(root, file), "utf8"))
    .join("\n");
  for (const forbidden of [
    /child_process/u,
    /permissionHandler/u,
    /permissions\.setRequired/u,
    /session\.abort/u,
    /session\.send/u,
    /\.mode\.set/u,
    /\.model\.set/u,
    /GITHUB_TOKEN/u,
    /COPILOT_SDK_TOKEN/u,
  ]) {
    assert.doesNotMatch(source, forbidden);
  }
  assert.match(source, /joinSession\(\{ tools: \[\] \}\)/u);
  assert.equal(
    fs.existsSync(path.join(root, ".github", "extensions", "copilot-micro")),
    false,
  );
});
