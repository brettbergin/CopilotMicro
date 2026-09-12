import crypto from "node:crypto";
import fs from "node:fs";

export const EVIDENCE_SCHEMA_VERSION = 1;
export const MAXIMUM_EVIDENCE_RECORDS = 256;
export const MAXIMUM_EVIDENCE_BYTES = 131_072;
export const MAXIMUM_EVIDENCE_LINE_BYTES = 8_192;

const SESSION_MODES = new Set(["interactive", "plan", "autopilot"]);
const PERMISSION_MODES = new Set(["manual", "assisted", "allow-all"]);
const TASK_STATUSES = new Set(["running", "idle", "completed", "failed", "cancelled"]);
const QUEUE_KINDS = new Set(["message", "command"]);
const RELEVANT_COMMANDS = new Set([
  "archive",
  "autopilot",
  "clear",
  "effort",
  "model",
  "new",
  "plan",
  "rename",
  "resume",
  "sessions",
  "voice",
]);
const SAFE_EVENT_TYPES = new Set([
  "assistant.idle",
  "assistant.turn_end",
  "assistant.turn_start",
  "command.completed",
  "command.execute",
  "command.queued",
  "pending_messages.modified",
  "permission.completed",
  "permission.requested",
  "session.background_tasks_changed",
  "session.error",
  "session.idle",
  "session.mode_changed",
  "session.model_change",
  "session.resume",
  "session.shutdown",
  "session.start",
  "tool.execution_complete",
  "tool.execution_start",
]);
const METHOD_PATHS = [
  "commands.list",
  "completions.getTriggerCharacters",
  "extensions.list",
  "mode.get",
  "mode.set",
  "model.getCurrent",
  "model.list",
  "model.setReasoningEffort",
  "permissions.getMode",
  "permissions.handlePendingPermissionRequest",
  "permissions.notifyPromptShown",
  "permissions.pendingRequests",
  "permissions.setRequired",
  "queue.pendingItems",
  "sessions.list",
  "sessions.open",
  "tasks.list",
  "voice.getState",
  "voice.start",
  "voice.stop",
  "composer.focus",
  "composer.submit",
];
const RECORD_KINDS = new Set([
  "event.observed",
  "hook.observed",
  "join.failed",
  "join.succeeded",
  "probe.failed",
  "process.signal",
  "process.started",
  "rpc.result",
  "surface.snapshot",
]);
const RECORD_STATUSES = new Set(["demonstrated", "failed", "observed", "unavailable"]);
const LOCK_WAIT = new Int32Array(new SharedArrayBuffer(4));

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedString(value, maximum = 128) {
  if (typeof value !== "string" || value.length === 0) return undefined;
  return [...value].slice(0, maximum).join("");
}

function boundedStringArray(value, { maximumItems = 64, allowed } = {}) {
  if (!Array.isArray(value)) return [];
  const result = [];
  for (const item of value) {
    const safe = boundedString(item);
    if (!safe || (allowed && !allowed.has(safe)) || result.includes(safe)) continue;
    result.push(safe);
    if (result.length >= maximumItems) break;
  }
  return result.sort();
}

function countValues(values, allowed) {
  const counts = Object.fromEntries([...allowed].map((value) => [value, 0]));
  for (const value of values) {
    if (allowed.has(value)) counts[value] += 1;
  }
  return counts;
}

function withEvidenceLock(outputPath, callback) {
  const lockPath = `${outputPath}.lock`;
  let acquired = false;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      fs.mkdirSync(lockPath, { mode: 0o700 });
      acquired = true;
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      Atomics.wait(LOCK_WAIT, 0, 0, 2);
    }
  }
  if (!acquired) throw new Error("evidenceLockUnavailable");
  try {
    return callback();
  } finally {
    fs.rmdirSync(lockPath);
  }
}

export function aliasIdentifier(kind, value) {
  const prefix = boundedString(kind, 24) ?? "id";
  const digest = crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
  return `${prefix}-${digest}`;
}

export function classifyProbeError(error) {
  const message = String(error?.message ?? error ?? "");
  const code = String(error?.code ?? "");
  if (message === "methodUnavailable") return "methodUnavailable";
  if (/method.*not.*found|not implemented|unsupported/iu.test(message) || code === "-32601") {
    return "methodUnavailable";
  }
  if (/closed|disconnect|broken pipe|EPIPE/iu.test(message) || code === "EPIPE") {
    return "connectionClosed";
  }
  if (/timeout|timed out/iu.test(message)) return "timedOut";
  if (/permission|denied|not authorized/iu.test(message)) return "permissionDenied";
  return "requestFailed";
}

export function methodAvailability(rpc) {
  return Object.fromEntries(
    METHOD_PATHS.map((methodPath) => {
      const parts = methodPath.split(".");
      let current = rpc;
      for (const part of parts) current = current?.[part];
      return [methodPath, typeof current === "function"];
    }),
  );
}

function sanitizeModelList(value) {
  const items = Array.isArray(value?.list)
    ? value.list
    : Array.isArray(value?.models)
      ? value.models
      : [];
  return {
    models: items.slice(0, 64).flatMap((item) => {
      if (!isPlainObject(item)) return [];
      const id = boundedString(item.id ?? item.modelId);
      if (!id) return [];
      const efforts = boundedStringArray(item.supportedReasoningEfforts, {
        maximumItems: 16,
      });
      const reasoningEffort = item.capabilities?.supports?.reasoningEffort;
      return [{
        id,
        reasoningEffort: typeof reasoningEffort === "boolean" ? reasoningEffort : efforts.length > 0,
        supportedReasoningEfforts: efforts,
      }];
    }),
  };
}

export function sanitizeRpcResult(operation, value) {
  switch (operation) {
    case "sdk.protocol":
      return {
        protocolVersion: Number.isSafeInteger(value) && value > 0 ? value : null,
      };
    case "mode.current":
    case "mode.afterSet":
    case "mode.restored":
      return { mode: SESSION_MODES.has(value) ? value : "unknown" };
    case "mode.set":
      return {
        requestedMode: SESSION_MODES.has(value?.requestedMode) ? value.requestedMode : "unknown",
        resultMode: SESSION_MODES.has(value?.result?.mode) ? value.result.mode : null,
      };
    case "model.current":
    case "model.afterEffortSet":
      return {
        modelId: boundedString(value?.modelId) ?? null,
        reasoningEffort: boundedString(value?.reasoningEffort, 32) ?? null,
        contextTier: boundedString(value?.contextTier, 32) ?? null,
      };
    case "model.list":
      return sanitizeModelList(value);
    case "model.setReasoningEffort":
      return {
        reasoningEffort: boundedString(value?.reasoningEffort, 32) ?? null,
      };
    case "tasks.list": {
      const tasks = Array.isArray(value?.tasks) ? value.tasks : [];
      return {
        count: tasks.length,
        statuses: countValues(tasks.map((task) => task?.status), TASK_STATUSES),
        types: {
          agent: tasks.filter((task) => task?.type === "agent").length,
          shell: tasks.filter((task) => task?.type === "shell").length,
        },
      };
    }
    case "queue.pendingItems": {
      const items = Array.isArray(value?.items) ? value.items : [];
      const kinds = items.map((item) => item?.kind);
      return {
        count: items.length,
        kinds: countValues(kinds, QUEUE_KINDS),
        steeringCount: Array.isArray(value?.steeringMessages) ? value.steeringMessages.length : 0,
        inFlightSteeringCount: Number.isSafeInteger(value?.inFlightSteeringCount)
          ? value.inFlightSteeringCount
          : null,
      };
    }
    case "permissions.mode":
      return {
        mode: PERMISSION_MODES.has(value?.mode) ? value.mode : "unknown",
      };
    case "permissions.pendingRequests":
      return {
        count: Array.isArray(value?.items) ? value.items.length : 0,
      };
    case "permissions.setRequired":
      return {
        success: value?.success === true,
      };
    case "commands.list": {
      const commands = Array.isArray(value?.commands) ? value.commands : [];
      return {
        relevantCommands: boundedStringArray(
          commands.map((command) => command?.name).filter((name) => RELEVANT_COMMANDS.has(name)),
          { maximumItems: RELEVANT_COMMANDS.size },
        ),
      };
    }
    case "completions.triggerCharacters":
      return {
        triggerCharacters: boundedStringArray(value?.triggerCharacters, {
          maximumItems: 16,
          allowed: new Set(["@", "#", "/"]),
        }),
      };
    case "extensions.list": {
      const extensions = Array.isArray(value?.extensions) ? value.extensions : [];
      return {
        count: extensions.length,
        sources: countValues(
          extensions.map((extension) => extension?.source),
          new Set(["project", "user", "plugin", "session"]),
        ),
        statuses: countValues(
          extensions.map((extension) => extension?.status),
          new Set(["running", "disabled", "failed", "starting"]),
        ),
      };
    }
    case "sessions.list":
      return {
        count: Array.isArray(value?.sessions) ? value.sessions.length : 0,
      };
    default:
      return {};
  }
}

export function sanitizeSessionEvent(event, sessionAlias) {
  if (!isPlainObject(event) || !SAFE_EVENT_TYPES.has(event.type)) return null;
  const data = isPlainObject(event.data) ? event.data : {};
  const safe = {
    eventType: event.type,
    rootSession: typeof event.agentId !== "string",
    sessionAlias,
  };
  switch (event.type) {
    case "session.start":
      return {
        ...safe,
        cliVersion: boundedString(data.copilotVersion, 64) ?? null,
        modelId: boundedString(data.selectedModel) ?? null,
        reasoningEffort: boundedString(data.reasoningEffort, 32) ?? null,
        contextTier: boundedString(data.contextTier, 32) ?? null,
        alreadyInUse: data.alreadyInUse === true,
      };
    case "session.resume":
      return {
        ...safe,
        modelId: boundedString(data.selectedModel) ?? null,
        reasoningEffort: boundedString(data.reasoningEffort, 32) ?? null,
        contextTier: boundedString(data.contextTier, 32) ?? null,
        alreadyInUse: data.alreadyInUse === true,
        sessionWasActive: data.sessionWasActive === true,
        continuePendingWork: data.continuePendingWork === true,
      };
    case "session.idle":
      return {
        ...safe,
        aborted: data.aborted === true,
        mode: SESSION_MODES.has(data.mode) ? data.mode : null,
      };
    case "session.mode_changed":
      return {
        ...safe,
        previousMode: SESSION_MODES.has(data.previousMode) ? data.previousMode : null,
        newMode: SESSION_MODES.has(data.newMode) ? data.newMode : null,
      };
    case "session.model_change":
      return {
        ...safe,
        previousModel: boundedString(data.previousModel) ?? null,
        newModel: boundedString(data.newModel) ?? null,
        previousReasoningEffort: boundedString(data.previousReasoningEffort, 32) ?? null,
        reasoningEffort: boundedString(data.reasoningEffort, 32) ?? null,
        contextTier: boundedString(data.contextTier, 32) ?? null,
      };
    case "permission.requested":
      return {
        ...safe,
        requestAlias: aliasIdentifier("request", data.requestId ?? "missing"),
        requestKind: boundedString(data.permissionRequest?.kind, 48) ?? "unknown",
        resolvedByHook: data.resolvedByHook === true,
        promptIdentityPresent: isPlainObject(data.promptRequest),
      };
    case "permission.completed":
      return {
        ...safe,
        requestAlias: aliasIdentifier("request", data.requestId ?? "missing"),
        outcome: boundedString(data.outcome ?? data.result, 48) ?? "unknown",
      };
    case "session.shutdown":
      return {
        ...safe,
        shutdownType: boundedString(data.shutdownType, 48) ?? "unknown",
      };
    case "session.error":
      return {
        ...safe,
        errorCategory: boundedString(data.errorType, 48) ?? "unknown",
      };
    default:
      return safe;
  }
}

export class EvidenceWriter {
  #sequence = 0;

  constructor({ outputPath, probeInstance, hostAlias, now = () => new Date() }) {
    this.outputPath = outputPath;
    this.probeInstance = probeInstance;
    this.hostAlias = hostAlias;
    this.now = now;
    if (fs.existsSync(outputPath)) {
      const status = fs.lstatSync(outputPath);
      if (!status.isFile() || status.isSymbolicLink() || status.size > MAXIMUM_EVIDENCE_BYTES) {
        throw new Error("unsafeEvidencePath");
      }
      const records = fs.readFileSync(outputPath, "utf8")
        .split("\n")
        .filter(Boolean)
        .length;
      if (records > MAXIMUM_EVIDENCE_RECORDS) throw new Error("unsafeEvidencePath");
    }
  }

  record(kind, status, data = {}) {
    if (!RECORD_KINDS.has(kind) || !RECORD_STATUSES.has(status) || !isPlainObject(data)) {
      throw new Error("invalidEvidenceRecord");
    }
    const record = {
      schemaVersion: EVIDENCE_SCHEMA_VERSION,
      probeInstance: this.probeInstance,
      hostAlias: this.hostAlias,
      sequence: this.#sequence + 1,
      recordedAt: this.now().toISOString(),
      kind,
      status,
      data,
    };
    const line = `${JSON.stringify(record)}\n`;
    const lineBytes = Buffer.byteLength(line);
    if (lineBytes > MAXIMUM_EVIDENCE_LINE_BYTES) return false;
    return withEvidenceLock(this.outputPath, () => {
      let existingBytes = 0;
      let existingRecords = 0;
      if (fs.existsSync(this.outputPath)) {
        const evidenceStatus = fs.lstatSync(this.outputPath);
        if (!evidenceStatus.isFile() || evidenceStatus.isSymbolicLink()) {
          throw new Error("unsafeEvidencePath");
        }
        existingBytes = evidenceStatus.size;
        if (existingBytes > MAXIMUM_EVIDENCE_BYTES) throw new Error("unsafeEvidencePath");
        existingRecords = fs.readFileSync(this.outputPath, "utf8")
          .split("\n")
          .filter(Boolean)
          .length;
      }
      if (
        existingRecords >= MAXIMUM_EVIDENCE_RECORDS
        || existingBytes + lineBytes > MAXIMUM_EVIDENCE_BYTES
      ) {
        return false;
      }
      const flags = fs.constants.O_WRONLY
        | fs.constants.O_CREAT
        | fs.constants.O_APPEND
        | (fs.constants.O_NOFOLLOW ?? 0);
      const descriptor = fs.openSync(this.outputPath, flags, 0o600);
      try {
        fs.fchmodSync(descriptor, 0o600);
        fs.writeFileSync(descriptor, line, "utf8");
      } finally {
        fs.closeSync(descriptor);
      }
      this.#sequence += 1;
      return true;
    });
  }
}

export async function recordRpcProbe(writer, operation, callback) {
  try {
    const value = await callback();
    writer.record("rpc.result", "demonstrated", {
      operation,
      result: sanitizeRpcResult(operation, value),
    });
    return value;
  } catch (error) {
    writer.record("rpc.result", "unavailable", {
      operation,
      errorCategory: classifyProbeError(error),
    });
    return undefined;
  }
}

export async function runReadOnlyProbes(session, writer, sdkProtocolLoader) {
  if (sdkProtocolLoader) {
    await recordRpcProbe(writer, "sdk.protocol", sdkProtocolLoader);
  }
  const availability = methodAvailability(session.rpc);
  writer.record("surface.snapshot", "observed", { methods: availability });
  await recordRpcProbe(writer, "mode.current", () => session.rpc.mode.get());
  await recordRpcProbe(writer, "model.current", () => session.rpc.model.getCurrent());
  await recordRpcProbe(writer, "model.list", () => session.rpc.model.list());
  await recordRpcProbe(writer, "tasks.list", () => session.rpc.tasks.list());
  await recordRpcProbe(writer, "queue.pendingItems", () => session.rpc.queue.pendingItems());
  await recordRpcProbe(writer, "permissions.mode", () => session.rpc.permissions.getMode());
  await recordRpcProbe(
    writer,
    "permissions.pendingRequests",
    () => session.rpc.permissions.pendingRequests(),
  );
  await recordRpcProbe(writer, "commands.list", () => session.rpc.commands.list());
  await recordRpcProbe(
    writer,
    "completions.triggerCharacters",
    () => session.rpc.completions.getTriggerCharacters(),
  );
  await recordRpcProbe(writer, "extensions.list", () => session.rpc.extensions.list());
  if (availability["sessions.list"]) {
    await recordRpcProbe(writer, "sessions.list", () => session.rpc.sessions.list({}));
  }
}

export async function runActiveProbes(session, writer) {
  const initialMode = await recordRpcProbe(writer, "mode.current", () => session.rpc.mode.get());
  if (initialMode === "interactive" || initialMode === "plan") {
    const requestedMode = initialMode === "interactive" ? "plan" : "interactive";
    await recordRpcProbe(writer, "mode.set", async () => ({
      requestedMode,
      result: await session.rpc.mode.set({ mode: requestedMode }),
    }));
    await recordRpcProbe(writer, "mode.afterSet", () => session.rpc.mode.get());
    await session.rpc.mode.set({ mode: initialMode });
    await recordRpcProbe(writer, "mode.restored", () => session.rpc.mode.get());
  } else {
    writer.record("rpc.result", "unavailable", {
      operation: "mode.set",
      errorCategory: "unsafeInitialMode",
    });
  }

  const currentModel = await recordRpcProbe(
    writer,
    "model.current",
    () => session.rpc.model.getCurrent(),
  );
  if (boundedString(currentModel?.reasoningEffort, 32)) {
    await recordRpcProbe(
      writer,
      "model.setReasoningEffort",
      () => session.rpc.model.setReasoningEffort({
        reasoningEffort: currentModel.reasoningEffort,
      }),
    );
    await recordRpcProbe(
      writer,
      "model.afterEffortSet",
      () => session.rpc.model.getCurrent(),
    );
  }
}
