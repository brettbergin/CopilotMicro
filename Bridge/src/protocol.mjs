import crypto from "node:crypto";

export const IPC_PROTOCOL_VERSION = 1;
export const MAXIMUM_WIRE_BYTES = 65_536;
export const MAXIMUM_SAFE_SEQUENCE = 9_007_199_254_740_991;
export const MAXIMUM_IN_FLIGHT_REQUESTS = 64;
export const MAXIMUM_SOCKET_PATH_BYTES = 103;
export const ACTION_TYPES = [
  "session.openList",
  "session.create",
  "session.previous",
  "session.next",
  "session.archive",
  "session.cycleMode",
  "session.selectModel",
  "session.selectEffort",
  "session.voice",
  "session.cancelForeground",
  "composer.submit",
  "composer.focus",
  "picker.confirm",
  "picker.back",
  "permission.approveOnce",
  "permission.reject",
];
export const RESULT_CODES = [
  "focusConsumed",
  "paused",
  "disconnected",
  "unsynchronized",
  "staleInstance",
  "staleSession",
  "staleGeneration",
  "staleContext",
  "capabilityUnavailable",
  "capabilityBlocked",
  "capabilityUnknown",
  "invalidRequest",
  "permissionRequestNotPending",
  "permissionRequestNotVisible",
  "timedOut",
  "hostRejected",
  "transportFailure",
  "alreadyResolved",
  "duplicateRequest",
  "replayLedgerFull",
];

const IDENTIFIER = /^[!-~]{1,128}$/u;
const BOOTSTRAP_TOKEN = /^[a-f0-9]{64}$/u;
const ACTION_TYPE_SET = new Set(ACTION_TYPES);
const RESULT_CODE_SET = new Set(RESULT_CODES);
const REGISTRATION_KEYS = new Set([
  "protocolVersion",
  "messageType",
  "role",
  "bootstrapToken",
  "instanceId",
  "sessionId",
  "generation",
  "bridgeVersion",
  "cliVersion",
  "sdkVersion",
]);
const FRAME_KEYS = new Set([
  "protocolVersion",
  "messageType",
  "role",
  "generation",
  "sequence",
  "payload",
]);
const REGISTRATION_RESULT_KEYS = new Set([
  "protocolVersion",
  "messageType",
  "outcome",
  "connectionId",
  "code",
  "message",
]);
const PAYLOAD_SENDERS = new Map([
  ["action", "nativeApp"],
  ["actionResult", "cliBridge"],
  ["sessionSnapshot", "cliBridge"],
]);

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

function validOptionalString(value, maximumCharacters) {
  return value === undefined
    || (typeof value === "string" && [...value].length <= maximumCharacters);
}

function validateActionPayload(value, generation) {
  const envelopeKeys = new Set([
    "protocolVersion",
    "messageType",
    "requestId",
    "instanceId",
    "sessionId",
    "generation",
    "contextRevision",
    "action",
  ]);
  const actionKeys = new Set(["type", "permissionRequestId"]);
  if (!exactKeys(value, envelopeKeys) || !isPlainObject(value.action)) return false;
  if (Object.keys(value.action).some((key) => !actionKeys.has(key))) return false;
  if (
    !validIdentifier(value.requestId)
    || !validIdentifier(value.instanceId)
    || !validIdentifier(value.sessionId)
    || !validIdentifier(value.generation)
    || value.generation !== generation
    || !Number.isSafeInteger(value.contextRevision)
    || value.contextRevision < 0
    || value.contextRevision > MAXIMUM_SAFE_SEQUENCE
    || !ACTION_TYPE_SET.has(value.action.type)
  ) {
    return false;
  }
  const permissionAction = value.action.type.startsWith("permission.");
  const hasPermissionRequest = Object.hasOwn(value.action, "permissionRequestId");
  return permissionAction === hasPermissionRequest
    && (!hasPermissionRequest || validIdentifier(value.action.permissionRequestId));
}

function validateResultPayload(value) {
  const required = new Set(["protocolVersion", "messageType", "requestId", "outcome", "message"]);
  const allowed = new Set([...required, "code"]);
  const keys = Object.keys(value);
  if (
    keys.some((key) => !allowed.has(key))
    || [...required].some((key) => !Object.hasOwn(value, key))
    || !validIdentifier(value.requestId)
    || !["accepted", "completed", "rejected", "failed"].includes(value.outcome)
    || typeof value.message !== "string"
    || value.message.length === 0
    || [...value.message].length > 512
  ) {
    return false;
  }
  return value.code === undefined || RESULT_CODE_SET.has(value.code);
}

function validateSnapshotPayload(value, generation) {
  const required = new Set([
    "protocolVersion",
    "messageType",
    "instanceId",
    "sessionId",
    "generation",
    "contextRevision",
    "connection",
    "paused",
    "mode",
    "work",
    "pendingAttention",
    "capabilities",
  ]);
  const allowed = new Set([
    ...required,
    "visiblePermissionRequestId",
    "failure",
    "completionId",
  ]);
  const keys = Object.keys(value);
  if (
    keys.some((key) => !allowed.has(key))
    || [...required].some((key) => !Object.hasOwn(value, key))
    || !validIdentifier(value.instanceId)
    || !validIdentifier(value.sessionId)
    || !validIdentifier(value.generation)
    || value.generation !== generation
    || !Number.isSafeInteger(value.contextRevision)
    || value.contextRevision < 0
    || value.contextRevision > MAXIMUM_SAFE_SEQUENCE
    || !["connecting", "synchronizing", "ready", "reconnecting", "shuttingDown"].includes(
      value.connection,
    )
    || typeof value.paused !== "boolean"
    || !(value.mode === null || ["default", "plan", "autopilot"].includes(value.mode))
    || !isPlainObject(value.work)
    || !Array.isArray(value.pendingAttention)
    || value.pendingAttention.length > 128
    || !isPlainObject(value.capabilities)
    || Object.keys(value.capabilities).length > 64
  ) {
    return false;
  }

  if (
    !exactKeys(value.work, new Set(["known", "foregroundActive", "backgroundCount", "queuedCount"]))
    || typeof value.work.known !== "boolean"
    || typeof value.work.foregroundActive !== "boolean"
    || !Number.isSafeInteger(value.work.backgroundCount)
    || value.work.backgroundCount < 0
    || !Number.isSafeInteger(value.work.queuedCount)
    || value.work.queuedCount < 0
  ) {
    return false;
  }

  const pendingRequestIds = new Set();
  for (const attention of value.pendingAttention) {
    if (
      !isPlainObject(attention)
      || !exactKeys(attention, new Set(["requestId", "kind"]))
      || !validIdentifier(attention.requestId)
      || pendingRequestIds.has(attention.requestId)
      || !["permission", "question", "elicitation", "planDecision"].includes(attention.kind)
    ) {
      return false;
    }
    pendingRequestIds.add(attention.requestId);
  }

  for (const [action, capability] of Object.entries(value.capabilities)) {
    if (
      !ACTION_TYPE_SET.has(action)
      || !isPlainObject(capability)
      || Object.keys(capability).some(
        (key) => !["status", "reason", "gapReference", "recoveryAction"].includes(key),
      )
      || !Object.hasOwn(capability, "status")
      || !["supported", "unavailable", "blocked", "unknown"].includes(capability.status)
      || !validOptionalString(capability.reason, 512)
      || !validOptionalString(capability.gapReference, 128)
      || !validOptionalString(capability.recoveryAction, 128)
    ) {
      return false;
    }
  }

  if (
    !(value.visiblePermissionRequestId === undefined
      || value.visiblePermissionRequestId === null
      || validIdentifier(value.visiblePermissionRequestId))
    || !(value.completionId === undefined
      || value.completionId === null
      || validIdentifier(value.completionId))
  ) {
    return false;
  }
  if (value.failure !== undefined && value.failure !== null) {
    if (
      !isPlainObject(value.failure)
      || !exactKeys(value.failure, new Set(["id", "category"]))
      || !validIdentifier(value.failure.id)
      || !["host", "integration", "protocolViolation", "device"].includes(
        value.failure.category,
      )
    ) {
      return false;
    }
  }
  return true;
}

function validateBridgePayload(value, generation) {
  if (value.protocolVersion !== IPC_PROTOCOL_VERSION) return false;
  if (value.messageType === "action") return validateActionPayload(value, generation);
  if (value.messageType === "actionResult") return validateResultPayload(value);
  if (value.messageType === "sessionSnapshot") {
    return validateSnapshotPayload(value, generation);
  }
  return false;
}

function parseBoundedJSON(data) {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (bytes.byteLength > MAXIMUM_WIRE_BYTES) return { error: "messageTooLarge" };
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    return { error: "malformed" };
  }
  return { value };
}

export function validateRegistration(data) {
  const parsed = parseBoundedJSON(data);
  if (parsed.error) return parsed;
  const value = parsed.value;
  if (!isPlainObject(value)) return { error: "malformed" };
  if (Object.keys(value).some((key) => !REGISTRATION_KEYS.has(key))) {
    return { error: "unexpectedField" };
  }
  if (!exactKeys(value, REGISTRATION_KEYS)) return { error: "malformed" };
  if (value.protocolVersion !== IPC_PROTOCOL_VERSION) return { error: "unsupportedProtocol" };
  if (value.messageType !== "registration") return { error: "invalidMessageType" };
  if (!["nativeApp", "cliBridge"].includes(value.role)) return { error: "invalidRole" };
  if (!BOOTSTRAP_TOKEN.test(value.bootstrapToken)) return { error: "malformed" };
  if (
    !validIdentifier(value.instanceId)
    || !validIdentifier(value.sessionId)
    || !validIdentifier(value.generation)
    || !validIdentifier(value.bridgeVersion)
    || !validIdentifier(value.cliVersion)
    || !validIdentifier(value.sdkVersion)
  ) {
    return { error: "malformed" };
  }
  return { value };
}

export function authenticateRegistration(
  registration,
  { expectedToken, peerUid, expectedUid },
) {
  if (peerUid !== expectedUid) return "wrongPeer";
  if (registration.role !== "cliBridge") return "wrongRole";
  const received = Buffer.from(registration.bootstrapToken, "utf8");
  const expected = Buffer.from(expectedToken, "utf8");
  if (received.byteLength !== expected.byteLength) return "invalidToken";
  return crypto.timingSafeEqual(received, expected) ? "accepted" : "invalidToken";
}

export function validateRegistrationResult(data) {
  const parsed = parseBoundedJSON(data);
  if (parsed.error) return parsed;
  const value = parsed.value;
  if (!isPlainObject(value)) return { error: "malformed" };
  if (Object.keys(value).some((key) => !REGISTRATION_RESULT_KEYS.has(key))) {
    return { error: "unexpectedField" };
  }
  if (!exactKeys(value, REGISTRATION_RESULT_KEYS)) return { error: "malformed" };
  if (value.protocolVersion !== IPC_PROTOCOL_VERSION) return { error: "unsupportedProtocol" };
  if (value.messageType !== "registrationResult") return { error: "invalidMessageType" };
  if (!["accepted", "rejected"].includes(value.outcome)) return { error: "malformed" };
  if (typeof value.message !== "string" || value.message.length === 0 || [...value.message].length > 512) {
    return { error: "malformed" };
  }
  if (value.outcome === "accepted") {
    if (!validIdentifier(value.connectionId) || value.code !== null) return { error: "malformed" };
  } else if (
    value.connectionId !== null
    || !["invalidToken", "wrongPeer", "wrongRole", "protocolViolation"].includes(value.code)
  ) {
    return { error: "malformed" };
  }
  return { value };
}

export function validateFrame(data) {
  const parsed = parseBoundedJSON(data);
  if (parsed.error) return parsed;
  const value = parsed.value;
  if (!isPlainObject(value) || !isPlainObject(value.payload)) return { error: "malformed" };
  if (Object.keys(value).some((key) => !FRAME_KEYS.has(key))) return { error: "unexpectedField" };
  if (!exactKeys(value, FRAME_KEYS)) return { error: "malformed" };
  if (value.protocolVersion !== IPC_PROTOCOL_VERSION) return { error: "unsupportedProtocol" };
  if (value.messageType !== "frame") return { error: "invalidMessageType" };
  if (!["nativeApp", "cliBridge"].includes(value.role)) return { error: "invalidRole" };
  if (!validIdentifier(value.generation)) return { error: "malformed" };
  if (
    !Number.isSafeInteger(value.sequence)
    || value.sequence < 1
    || value.sequence > MAXIMUM_SAFE_SEQUENCE
  ) {
    return { error: "malformed" };
  }
  if (!validateBridgePayload(value.payload, value.generation)) {
    return { error: "invalidPayload" };
  }
  return { value };
}

export function validateFrameDirection(frame, receiverRole) {
  const expectedSender = PAYLOAD_SENDERS.get(frame.payload.messageType);
  const expectedReceiver = expectedSender === "nativeApp" ? "cliBridge" : "nativeApp";
  return frame.role === expectedSender && receiverRole === expectedReceiver ? "allowed" : "wrongRole";
}

export class SequenceTracker {
  #generation;
  #nextSequence = 1;

  constructor(generation) {
    this.#generation = generation;
  }

  accept(frame) {
    if (frame.generation !== this.#generation) return "staleGeneration";
    if (frame.sequence < this.#nextSequence) return "staleSequence";
    if (frame.sequence > this.#nextSequence) return "sequenceGap";
    this.#nextSequence += 1;
    return "accepted";
  }

  invalidate(generation) {
    this.#generation = generation;
    this.#nextSequence = 1;
  }
}

export class InFlightRequestTracker {
  #requestIds = new Set();

  begin(requestId) {
    if (!validIdentifier(requestId)) return "invalidRequest";
    if (this.#requestIds.has(requestId)) return "duplicateRequest";
    if (this.#requestIds.size >= MAXIMUM_IN_FLIGHT_REQUESTS) return "tooManyInFlight";
    this.#requestIds.add(requestId);
    return "accepted";
  }

  complete(requestId) {
    return this.#requestIds.delete(requestId);
  }

  invalidate() {
    this.#requestIds.clear();
  }

  get count() {
    return this.#requestIds.size;
  }
}

export function encodeLengthPrefixedFrame(payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  if (data.byteLength === 0) throw new Error("malformed");
  if (data.byteLength > MAXIMUM_WIRE_BYTES) throw new Error("messageTooLarge");
  const result = Buffer.allocUnsafe(4 + data.byteLength);
  result.writeUInt32BE(data.byteLength, 0);
  data.copy(result, 4);
  return result;
}

export class LengthPrefixedFrameDecoder {
  #buffer = Buffer.alloc(0);

  append(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, Buffer.from(chunk)]);
    const frames = [];
    while (this.#buffer.byteLength >= 4) {
      const length = this.#buffer.readUInt32BE(0);
      if (length === 0) throw new Error("malformed");
      if (length > MAXIMUM_WIRE_BYTES) throw new Error("messageTooLarge");
      if (this.#buffer.byteLength < length + 4) break;
      frames.push(this.#buffer.subarray(4, length + 4));
      this.#buffer = this.#buffer.subarray(length + 4);
    }
    if (this.#buffer.byteLength > MAXIMUM_WIRE_BYTES + 4) {
      throw new Error("messageTooLarge");
    }
    return frames;
  }
}

export function validateSocketPath(socketPath) {
  if (typeof socketPath !== "string" || socketPath.length === 0) return "invalidPath";
  return Buffer.byteLength(socketPath) <= MAXIMUM_SOCKET_PATH_BYTES ? "valid" : "pathTooLong";
}
