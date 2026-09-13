import crypto from "node:crypto";

import { ACTION_TYPES } from "./protocol.mjs";

export const QUALIFIED_CLI_VERSION = "1.0.84-5";
export const QUALIFIED_SDK_VERSION = "1.0.13-preview.4";
export const PRODUCTION_ACTION_MILESTONE = "I-15";

const MAXIMUM_COLLECTION_COUNT = 128;
const RECONCILE_EVENT_REASONS = new Map([
  ["assistant.idle", "activity"],
  ["assistant.turn_end", "activity"],
  ["assistant.turn_start", "activity"],
  ["pending_messages.modified", "queue"],
  ["permission.completed", "attention"],
  ["permission.requested", "attention"],
  ["session.background_tasks_changed", "backgroundTasks"],
  ["session.error", "hostError"],
  ["session.idle", "activity"],
  ["session.mode_changed", "mode"],
  ["session.model_change", "model"],
  ["session.resume", "lifecycle"],
  ["session.shutdown", "lifecycle"],
  ["session.start", "lifecycle"],
  ["tool.execution_complete", "activity"],
  ["tool.execution_start", "activity"],
]);
const SESSION_MODES = new Map([
  ["interactive", "default"],
  ["plan", "plan"],
  ["autopilot", "autopilot"],
]);
const UNAVAILABLE_ACTION_REASONS = new Map([
  ["session.openList", "The qualified extension surface cannot open the native session list."],
  ["session.create", "The qualified extension surface cannot create a native foreground session."],
  ["session.previous", "The qualified extension surface cannot select the previous native session."],
  ["session.next", "The qualified extension surface cannot select the next native session."],
  ["session.archive", "The qualified extension surface cannot archive the selected session."],
  ["session.voice", "The qualified extension surface exposes no native voice lifecycle."],
  ["session.cancelForeground", "Foreground cancellation has not completed production qualification."],
  ["composer.submit", "The qualified extension surface cannot submit the existing TUI draft."],
  ["composer.focus", "The qualified extension surface cannot focus the existing TUI composer."],
  ["picker.confirm", "No qualified host picker confirmation surface is available."],
  ["picker.back", "No qualified host picker dismissal surface is available."],
  [
    "permission.approveOnce",
    "Visible request binding and one-shot permission authority are not qualified.",
  ],
  [
    "permission.reject",
    "Visible request binding and one-shot permission authority are not qualified.",
  ],
]);
const DEFERRED_ACTIONS = new Set([
  "session.cycleMode",
  "session.selectModel",
  "session.selectEffort",
]);

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedString(value, maximum = 128) {
  if (typeof value !== "string" || value.length === 0) return null;
  return [...value].slice(0, maximum).join("");
}

function boundedCount(value) {
  return Number.isSafeInteger(value) && value >= 0 && value <= MAXIMUM_COLLECTION_COUNT
    ? value
    : null;
}

function runningCount(value) {
  if (!Array.isArray(value) || value.length > MAXIMUM_COLLECTION_COUNT) return null;
  return value.filter((item) => item?.status === "running").length;
}

function collectionCount(value) {
  if (!Array.isArray(value) || value.length > MAXIMUM_COLLECTION_COUNT) return null;
  return value.length;
}

function queuedWorkCount(value) {
  const items = collectionCount(value?.items);
  const steering = collectionCount(value?.steeringMessages ?? []);
  const inFlight = boundedCount(value?.inFlightSteeringCount ?? 0);
  if (items === null || steering === null || inFlight === null) return null;
  const total = items + steering + inFlight;
  return total <= MAXIMUM_COLLECTION_COUNT ? total : null;
}

function compatibilityFor(cliVersion, sdkVersion = "host-provided") {
  if (cliVersion === QUALIFIED_CLI_VERSION && sdkVersion === "host-provided") {
    return {
      status: "qualifiedReadOnly",
      cliVersion,
      sdkVersion,
      reason:
        `Read-only observation is qualified for Copilot CLI ${QUALIFIED_CLI_VERSION} `
        + `with its host-provided SDK (${QUALIFIED_SDK_VERSION} observed).`,
    };
  }
  return {
    status: "unqualified",
    cliVersion,
    sdkVersion,
    reason:
      `This CLI/SDK tuple is not qualified for production observation; `
      + `the qualified CLI version is ${QUALIFIED_CLI_VERSION}.`,
  };
}

export function productionActionCapabilities(cliVersion, sdkVersion = "host-provided") {
  const compatible = compatibilityFor(cliVersion, sdkVersion).status === "qualifiedReadOnly";
  return Object.fromEntries(
    ACTION_TYPES.map((action) => {
      if (!compatible) {
        return [
          action,
          {
            status: "unknown",
            reason:
              `Compatibility is unqualified for this host; all production actions remain `
              + `disabled until ${PRODUCTION_ACTION_MILESTONE}.`,
            gapReference: PRODUCTION_ACTION_MILESTONE,
            recoveryAction: `Use qualified Copilot CLI ${QUALIFIED_CLI_VERSION}.`,
          },
        ];
      }
      if (DEFERRED_ACTIONS.has(action)) {
        return [
          action,
          {
            status: "blocked",
            reason:
              `The read-only host surface is qualified, but production state changes remain `
              + `disabled until ${PRODUCTION_ACTION_MILESTONE}.`,
            gapReference: PRODUCTION_ACTION_MILESTONE,
          },
        ];
      }
      return [
        action,
        {
          status: "unavailable",
          reason:
            `${UNAVAILABLE_ACTION_REASONS.get(action) ?? "This action is not qualified."} `
            + `Production actions remain disabled until ${PRODUCTION_ACTION_MILESTONE}.`,
          gapReference: PRODUCTION_ACTION_MILESTONE,
        },
      ];
    }),
  );
}

function unknownWork() {
  return {
    known: false,
    foregroundActive: false,
    backgroundCount: 0,
    queuedCount: 0,
  };
}

function unknownAttention() {
  return {
    known: false,
    permissionCount: 0,
    otherCount: 0,
  };
}

function unknownModel() {
  return {
    known: false,
    modelId: null,
    reasoningEffort: null,
    contextTier: null,
    availableModels: [],
  };
}

function hostCapabilities(session) {
  return {
    elicitation: session.capabilities?.ui?.elicitation === true,
    canvases: session.capabilities?.ui?.canvases === true,
    mcpApps: session.capabilities?.ui?.mcpApps === true,
  };
}

function sanitizeModels(value) {
  const values = Array.isArray(value?.list)
    ? value.list
    : Array.isArray(value?.models)
      ? value.models
      : [];
  if (values.length > 64) return [];
  return values.flatMap((model) => {
    if (!isPlainObject(model)) return [];
    const id = boundedString(model.id ?? model.modelId);
    if (!id) return [];
    const rawEfforts = Array.isArray(model.supportedReasoningEfforts)
      ? model.supportedReasoningEfforts
      : [];
    const supportedReasoningEfforts = [...new Set(
      rawEfforts.flatMap((effort) => {
        const safe = boundedString(effort, 32);
        return safe ? [safe] : [];
      }),
    )].slice(0, 16).sort();
    return [{
      id,
      reasoningEffort:
        model.capabilities?.supports?.reasoningEffort === true
        || supportedReasoningEfforts.length > 0,
      supportedReasoningEfforts,
    }];
  });
}

async function readOnlyCall(callback) {
  try {
    if (typeof callback !== "function") return { ok: false };
    return { ok: true, value: await callback() };
  } catch {
    return { ok: false };
  }
}

export class SessionObserver {
  #session;
  #binding;
  #sendPayload = null;
  #unsubscribe = null;
  #currentRevision = 0;
  #pendingRevision = 0;
  #reconcilePromise = null;
  #dirty = false;
  #stopped = false;
  #foregroundKnown = false;
  #foregroundActive = false;
  #cliVersion = "unknown";
  #failure = null;
  #connection = "synchronizing";
  #hostShutdown = false;
  #onFailure;

  constructor({ session, binding, onFailure = () => {} }) {
    this.#session = session;
    this.#binding = binding;
    this.#onFailure = onFailure;
  }

  get binding() {
    return { ...this.#binding };
  }

  get contextRevision() {
    return this.#currentRevision;
  }

  get connection() {
    return this.#connection;
  }

  get capabilities() {
    return productionActionCapabilities(this.#cliVersion);
  }

  get hostShutdown() {
    return this.#hostShutdown;
  }

  subscribe() {
    if (this.#unsubscribe) return;
    const unsubscribe = this.#session.on((event) => {
      this.observeEvent(event);
    });
    if (typeof unsubscribe === "function") this.#unsubscribe = unsubscribe;
  }

  async attach(sendPayload) {
    if (typeof sendPayload !== "function") throw new Error("invalidSender");
    this.#sendPayload = sendPayload;
    this.#sendSnapshot(this.#unknownSnapshot("synchronizing"), this.#nextRevision());
    await this.#queueReconciliation();
  }

  observeEvent(event) {
    if (this.#stopped || !isPlainObject(event)) return false;
    const reason = RECONCILE_EVENT_REASONS.get(event.type);
    if (!reason) return false;
    const data = isPlainObject(event.data) ? event.data : {};
    const rootSession = typeof event.agentId !== "string";
    if (event.type === "session.start") {
      this.#cliVersion = boundedString(data.copilotVersion, 64) ?? "unknown";
      this.#foregroundKnown = false;
      this.#foregroundActive = false;
      this.#failure = null;
    } else if (rootSession && event.type === "assistant.turn_start") {
      this.#foregroundKnown = true;
      this.#foregroundActive = true;
      this.#failure = null;
    } else if (
      rootSession
      && (
        event.type === "assistant.turn_end"
        || event.type === "assistant.idle"
        || event.type === "session.idle"
      )
    ) {
      this.#foregroundKnown = true;
      this.#foregroundActive = false;
    } else if (rootSession && event.type === "session.error") {
      this.#foregroundKnown = false;
      this.#foregroundActive = false;
      this.#failure = {
        id: `host-error-${crypto.randomUUID()}`,
        category: "host",
      };
    }

    const revision = this.#nextRevision();
    if (this.#sendPayload) {
      this.#sendPayload({
        protocolVersion: 1,
        messageType: "sessionEvent",
        ...this.#binding,
        contextRevision: revision,
        reason,
      });
    }
    if (event.type === "session.shutdown") {
      this.#hostShutdown = true;
      this.#connection = "shuttingDown";
      if (this.#sendPayload) {
        this.#sendSnapshot(this.#unknownSnapshot("shuttingDown"), revision);
      }
      this.stop();
      return true;
    }
    this.#dirty = true;
    if (this.#sendPayload) {
      void this.#queueReconciliation().catch((error) => this.#onFailure(error));
    }
    return true;
  }

  heartbeatPayload() {
    return {
      protocolVersion: 1,
      messageType: "heartbeat",
      ...this.#binding,
      contextRevision: this.#currentRevision,
    };
  }

  async flush() {
    await this.#queueReconciliation();
  }

  stop() {
    if (this.#stopped) return;
    this.#stopped = true;
    this.#unsubscribe?.();
    this.#unsubscribe = null;
  }

  async #queueReconciliation() {
    this.#dirty = true;
    if (this.#pendingRevision <= this.#currentRevision) this.#nextRevision();
    if (this.#reconcilePromise) return this.#reconcilePromise;
    this.#reconcilePromise = this.#reconcile();
    try {
      await this.#reconcilePromise;
    } finally {
      this.#reconcilePromise = null;
    }
  }

  async #reconcile() {
    while (this.#dirty && !this.#stopped) {
      this.#dirty = false;
      const revision = this.#pendingRevision;
      const snapshot = await this.#collectSnapshot();
      if (this.#dirty || revision !== this.#pendingRevision || this.#stopped) continue;
      this.#connection = "ready";
      this.#sendSnapshot(snapshot, revision);
    }
  }

  async #collectSnapshot() {
    const [
      mode,
      currentModel,
      models,
      tasks,
      queue,
      permissions,
    ] = await Promise.all([
      readOnlyCall(this.#session.rpc?.mode?.get?.bind(this.#session.rpc.mode)),
      readOnlyCall(this.#session.rpc?.model?.getCurrent?.bind(this.#session.rpc.model)),
      readOnlyCall(this.#session.rpc?.model?.list?.bind(this.#session.rpc.model)),
      readOnlyCall(this.#session.rpc?.tasks?.list?.bind(this.#session.rpc.tasks)),
      readOnlyCall(this.#session.rpc?.queue?.pendingItems?.bind(this.#session.rpc.queue)),
      readOnlyCall(
        this.#session.rpc?.permissions?.pendingRequests?.bind(this.#session.rpc.permissions),
      ),
    ]);

    const backgroundCount = tasks.ok ? runningCount(tasks.value?.tasks) : null;
    const queuedCount = queue.ok ? queuedWorkCount(queue.value) : null;
    const permissionCount = permissions.ok
      ? collectionCount(permissions.value?.items)
      : null;
    const workKnown = this.#foregroundKnown
      && backgroundCount !== null
      && queuedCount !== null;
    const modeValue = mode.ok ? SESSION_MODES.get(mode.value) ?? null : null;
    const modelID = currentModel.ok ? boundedString(currentModel.value?.modelId) : null;

    return {
      protocolVersion: 1,
      messageType: "sessionSnapshot",
      ...this.#binding,
      contextRevision: this.#pendingRevision,
      connection: "ready",
      paused: false,
      mode: modeValue,
      work: workKnown
        ? {
            known: true,
            foregroundActive: this.#foregroundActive,
            backgroundCount,
            queuedCount,
          }
        : unknownWork(),
      pendingAttention: [],
      attention: permissionCount === null
        ? unknownAttention()
        : {
            known: true,
            permissionCount: boundedCount(permissionCount),
            otherCount: 0,
          },
      capabilities: productionActionCapabilities(this.#cliVersion),
      hostCapabilities: hostCapabilities(this.#session),
      model: currentModel.ok
        ? {
            known: true,
            modelId: modelID,
            reasoningEffort: boundedString(currentModel.value?.reasoningEffort, 32),
            contextTier: boundedString(currentModel.value?.contextTier, 32),
            availableModels: models.ok ? sanitizeModels(models.value) : [],
          }
        : unknownModel(),
      compatibility: compatibilityFor(this.#cliVersion),
      visiblePermissionRequestId: null,
      failure: this.#failure,
      completionId: null,
    };
  }

  #unknownSnapshot(connection) {
    return {
      protocolVersion: 1,
      messageType: "sessionSnapshot",
      ...this.#binding,
      contextRevision: this.#pendingRevision,
      connection,
      paused: false,
      mode: null,
      work: unknownWork(),
      pendingAttention: [],
      attention: unknownAttention(),
      capabilities: productionActionCapabilities(this.#cliVersion),
      hostCapabilities: hostCapabilities(this.#session),
      model: unknownModel(),
      compatibility: compatibilityFor(this.#cliVersion),
      visiblePermissionRequestId: null,
      failure: null,
      completionId: null,
    };
  }

  #sendSnapshot(snapshot, revision) {
    snapshot.contextRevision = revision;
    this.#sendPayload(snapshot);
    this.#currentRevision = revision;
    this.#pendingRevision = revision;
  }

  #nextRevision() {
    this.#pendingRevision = Math.max(this.#currentRevision, this.#pendingRevision) + 1;
    return this.#pendingRevision;
  }
}

export class ProductionActionRejector {
  static maximumTrackedRequests = 4_096;

  #observer;
  #requestIDs = new Set();

  constructor(observer) {
    this.#observer = observer;
  }

  reject(request) {
    const binding = this.#observer.binding;
    let code;
    let message;
    if (request.instanceId !== binding.instanceId) {
      code = "staleInstance";
      message = "The selected CLI host changed.";
    } else if (request.sessionId !== binding.sessionId) {
      code = "staleSession";
      message = "The selected session changed.";
    } else if (request.generation !== binding.generation) {
      code = "staleGeneration";
      message = "The bridge lifetime changed.";
    } else if (this.#observer.connection !== "ready") {
      code = "unsynchronized";
      message = "The read-only bridge is synchronizing.";
    } else if (request.contextRevision !== this.#observer.contextRevision) {
      code = "staleContext";
      message = "The observed session state changed.";
    } else if (this.#requestIDs.has(request.requestId)) {
      code = "duplicateRequest";
      message = "This request was already rejected.";
    } else if (this.#requestIDs.size >= ProductionActionRejector.maximumTrackedRequests) {
      code = "replayLedgerFull";
      message = "The bounded request ledger is full for this bridge lifetime.";
    } else {
      this.#requestIDs.add(request.requestId);
      const capability = this.#observer.capabilities[request.action.type];
      code = capability?.status === "blocked"
        ? "capabilityBlocked"
        : capability?.status === "unavailable"
          ? "capabilityUnavailable"
          : "capabilityUnknown";
      message = capability?.reason
        ?? `Production stateful actions remain disabled until ${PRODUCTION_ACTION_MILESTONE}.`;
    }
    return {
      protocolVersion: 1,
      messageType: "actionResult",
      requestId: request.requestId,
      outcome: "rejected",
      code,
      message,
    };
  }
}
