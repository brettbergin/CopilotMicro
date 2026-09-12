import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const MAXIMUM_ACTION_BYTES = 65_536;
export const MAXIMUM_CONTEXT_REVISION = 9_007_199_254_740_991;
export const MAXIMUM_RESULT_MESSAGE_CHARACTERS = 512;
const ENVELOPE_KEYS = new Set([
  "protocolVersion",
  "messageType",
  "requestId",
  "instanceId",
  "sessionId",
  "generation",
  "contextRevision",
  "action",
]);
const ACTION_KEYS = new Set(["type", "permissionRequestId"]);
const RESULT_REQUIRED_KEYS = new Set(["protocolVersion", "messageType", "requestId", "outcome", "message"]);
const RESULT_ALLOWED_KEYS = new Set([...RESULT_REQUIRED_KEYS, "code"]);
const IDENTIFIER = /^[!-~]{1,128}$/u;

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected) {
  const keys = Object.keys(value);
  return keys.length === expected.size && keys.every((key) => expected.has(key));
}

function validIdentifier(value) {
  return typeof value === "string" && IDENTIFIER.test(value);
}

export function validateActionRequest(data, actionCatalog) {
  if (Buffer.byteLength(data) > MAXIMUM_ACTION_BYTES) return { error: "messageTooLarge" };
  let value;
  try {
    value = JSON.parse(data);
  } catch {
    return { error: "malformed" };
  }
  if (!isPlainObject(value) || !isPlainObject(value.action)) return { error: "malformed" };
  const envelopeKeys = Object.keys(value);
  if (envelopeKeys.some((key) => !ENVELOPE_KEYS.has(key))) return { error: "unexpectedField" };
  if (!exactKeys(value, ENVELOPE_KEYS)) return { error: "malformed" };
  const actionKeys = Object.keys(value.action);
  if (actionKeys.some((key) => !ACTION_KEYS.has(key))) return { error: "unexpectedField" };
  if (value.protocolVersion !== 1) return { error: "unsupportedProtocol" };
  if (value.messageType !== "action") return { error: "invalidMessageType" };
  if (
    !validIdentifier(value.requestId)
    || !validIdentifier(value.instanceId)
    || !validIdentifier(value.sessionId)
    || !validIdentifier(value.generation)
    || !Number.isSafeInteger(value.contextRevision)
    || value.contextRevision < 0
    || value.contextRevision > MAXIMUM_CONTEXT_REVISION
  ) {
    return { error: "malformed" };
  }
  const actionDefinition = actionCatalog.get(value.action.type);
  if (!actionDefinition) return { error: "unsupportedAction" };
  const hasPermissionRequest = Object.hasOwn(value.action, "permissionRequestId");
  if (
    (actionDefinition.permissionRequestArgument === "required") !== hasPermissionRequest
    || (hasPermissionRequest && !validIdentifier(value.action.permissionRequestId))
  ) {
    return { error: "invalidArguments" };
  }
  return { value };
}

export function validateActionResult(data, resultCodes) {
  if (Buffer.byteLength(data) > MAXIMUM_ACTION_BYTES) return { error: "messageTooLarge" };
  let value;
  try {
    value = JSON.parse(data);
  } catch {
    return { error: "malformed" };
  }
  if (!isPlainObject(value)) return { error: "malformed" };
  const keys = Object.keys(value);
  if (keys.some((key) => !RESULT_ALLOWED_KEYS.has(key))) return { error: "unexpectedField" };
  if ([...RESULT_REQUIRED_KEYS].some((key) => !Object.hasOwn(value, key))) {
    return { error: "malformed" };
  }
  if (value.protocolVersion !== 1) return { error: "unsupportedProtocol" };
  if (value.messageType !== "actionResult") return { error: "invalidMessageType" };
  if (!validIdentifier(value.requestId)) return { error: "malformed" };
  if (!["accepted", "completed", "rejected", "failed"].includes(value.outcome)) return { error: "malformed" };
  if (typeof value.message !== "string" || value.message.length === 0) return { error: "emptyMessage" };
  if ([...value.message].length > MAXIMUM_RESULT_MESSAGE_CHARACTERS) return { error: "messageTooLong" };
  if (value.code !== undefined && !resultCodes.has(value.code)) return { error: "malformed" };
  return { value };
}

export function validateActionGuard(request, context) {
  if (context.paused) return "paused";
  if (context.connection === "disconnected") return "disconnected";
  if (context.connection !== "ready" || !context.binding) return "unsynchronized";
  if (request.instanceId !== context.binding.instanceId) return "staleInstance";
  if (request.sessionId !== context.binding.sessionId) return "staleSession";
  if (request.generation !== context.binding.generation) return "staleGeneration";
  if (request.contextRevision !== context.contextRevision) return "staleContext";
  const capability = context.capabilities[request.action.type] ?? "unknown";
  if (capability === "unavailable") return "capabilityUnavailable";
  if (capability === "blocked") return "capabilityBlocked";
  if (capability !== "supported") return "capabilityUnknown";
  if (request.action.type.startsWith("permission.")) {
    if (!context.pendingRequestIds.has(request.action.permissionRequestId)) {
      return "permissionRequestNotPending";
    }
    if (context.visiblePermissionRequestId !== request.action.permissionRequestId) {
      return "permissionRequestNotVisible";
    }
  }
  return "allowed";
}

export class ActionReplayLedger {
  static maximumTrackedRequests = 4_096;

  #generation = null;
  #requestIds = new Set();

  reserve(request, context) {
    const rejection = validateActionGuard(request, context);
    if (rejection !== "allowed") return rejection;
    if (this.#generation !== null && this.#generation !== request.generation) return "staleGeneration";
    this.#generation ??= request.generation;
    if (this.#requestIds.has(request.requestId)) return "duplicateRequest";
    if (this.#requestIds.size >= ActionReplayLedger.maximumTrackedRequests) return "replayLedgerFull";
    this.#requestIds.add(request.requestId);
    return "reserved";
  }

  invalidate(newGeneration) {
    if (newGeneration === this.#generation) return false;
    this.#generation = newGeneration;
    this.#requestIds.clear();
    return true;
  }
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function loadContractCatalogs(root) {
  const contracts = path.join(root, "Contracts");
  const actions = readJSON(path.join(contracts, "actions.json"));
  const controls = readJSON(path.join(contracts, "default-controls.json"));
  const schema = readJSON(path.join(contracts, "bridge-v1.schema.json"));
  assert.equal(actions.schemaVersion, 1);
  assert.equal(controls.schemaVersion, 1);
  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");

  const actionCatalog = new Map();
  for (const action of actions.actions) {
    assert.ok(validIdentifier(action.id), `invalid action ID ${action.id}`);
    assert.ok(!actionCatalog.has(action.id), `duplicate action ID ${action.id}`);
    assert.ok(["required", "forbidden"].includes(action.permissionRequestArgument));
    actionCatalog.set(action.id, action);
  }
  assert.deepEqual(schema.$defs.actionType.enum, actions.actions.map((action) => action.id));
  assert.equal(schema.$defs.actionRequest.properties.contextRevision.maximum, MAXIMUM_CONTEXT_REVISION);
  assert.equal(schema.$defs.actionResult.properties.message.maxLength, MAXIMUM_RESULT_MESSAGE_CHARACTERS);
  const resultCodes = new Set(schema.$defs.actionResult.properties.code.enum);

  const contacts = [];
  const controlIDs = new Set();
  for (const control of controls.controls) {
    assert.ok(!controlIDs.has(control.id), `duplicate control ID ${control.id}`);
    assert.ok(actionCatalog.has(control.defaultAction), `unknown default action ${control.defaultAction}`);
    assert.equal(control.oneShot, true);
    controlIDs.add(control.id);
    contacts.push(...control.matrixContacts);
  }
  assert.deepEqual([...contacts].sort((left, right) => left - right), [...Array(13).keys()]);
  assert.deepEqual(
    controls.controls.find((control) => control.id === "key.submit")?.matrixContacts,
    [10, 11],
  );
  assert.deepEqual(
    controls.controls.filter((control) => control.id !== "key.submit").map((control) => control.matrixContacts.length),
    Array(11).fill(1),
  );
  assert.equal(controls.controls.find((control) => control.id === "key.sessions")?.matrixContacts[0], 1);
  assert.equal(controls.controls.find((control) => control.id === "key.new")?.matrixContacts[0], 0);
  return { actionCatalog, actions, controls, resultCodes, schema };
}

export function runContractChecks(root) {
  const { actionCatalog, resultCodes } = loadContractCatalogs(root);
  const fixtureDirectory = path.join(root, "Contracts", "fixtures", "bridge-v1");
  const manifest = readJSON(path.join(fixtureDirectory, "manifest.json"));
  assert.equal(manifest.schemaVersion, 1);
  const capabilities = Object.fromEntries([...actionCatalog.keys()].map((action) => [action, "supported"]));
  const context = {
    binding: {
      instanceId: "cli-instance-1",
      sessionId: "session-1",
      generation: "generation-1",
    },
    connection: "ready",
    contextRevision: 42,
    capabilities,
    pendingRequestIds: new Set(["permission-1"]),
    visiblePermissionRequestId: "permission-1",
    paused: false,
  };

  for (const fixture of manifest.cases) {
    const data = fixture.generator === "oversized"
      ? `${fs.readFileSync(path.join(fixtureDirectory, "valid-cancel.json"), "utf8")}${" ".repeat(MAXIMUM_ACTION_BYTES)}`
      : fs.readFileSync(path.join(fixtureDirectory, fixture.file), "utf8");
    const decoded = validateActionRequest(data, actionCatalog);
    assert.equal(decoded.error ?? "valid", fixture.decode, fixture.name);
    if (fixture.decode === "valid") {
      if (fixture.replay === "duplicate") {
        const ledger = new ActionReplayLedger();
        assert.equal(ledger.reserve(decoded.value, context), "reserved", fixture.name);
        assert.equal(ledger.reserve(decoded.value, context), fixture.guard, fixture.name);
      } else {
        assert.equal(validateActionGuard(decoded.value, context), fixture.guard, fixture.name);
      }
    }
  }

  const resultManifest = readJSON(path.join(fixtureDirectory, "result-manifest.json"));
  assert.equal(resultManifest.schemaVersion, 1);
  for (const fixture of resultManifest.cases) {
    const data = fixture.generator?.startsWith("unicode")
      ? JSON.stringify({
          protocolVersion: 1,
          messageType: "actionResult",
          requestId: "action-result-unicode",
          outcome: "completed",
          message: "é".repeat(Number.parseInt(fixture.generator.slice("unicode".length), 10)),
        })
      : fs.readFileSync(path.join(fixtureDirectory, fixture.file), "utf8");
    const decoded = validateActionResult(data, resultCodes);
    assert.equal(decoded.error ?? "valid", fixture.decode, fixture.name);
  }
  return {
    actionCount: actionCatalog.size,
    controlCount: 12,
    fixtureCount: manifest.cases.length,
    resultFixtureCount: resultManifest.cases.length,
  };
}

function isMainModule() {
  return process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
}

if (isMainModule()) {
  try {
    const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
    const result = runContractChecks(root);
    process.stdout.write(`${JSON.stringify({ outcome: "passed", ...result })}\n`);
  } catch (error) {
    process.stderr.write(`${JSON.stringify({ outcome: "failed", message: String(error.message ?? error) })}\n`);
    process.exitCode = 1;
  }
}
