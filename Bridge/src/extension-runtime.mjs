import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { connectAuthenticated } from "./client.mjs";
import {
  ProductionActionRejector,
  SessionObserver,
} from "./session-observer.mjs";

export const BRIDGE_VERSION = "0.1.0";
export const BRIDGE_DIRECTORY_ENVIRONMENT_KEY = "COPILOT_MICRO_BRIDGE_DIRECTORY";
export const BRIDGE_SOCKET_FILENAME = "bridge.sock";
export const BOOTSTRAP_TOKEN_FILENAME = "bootstrap-token";
export const DEFAULT_HEARTBEAT_MILLISECONDS = 5_000;
export const DEFAULT_MAXIMUM_RECONNECT_ATTEMPTS = 4;
export const DEFAULT_RECONNECT_DELAY_MILLISECONDS = 250;

function requireOwnerOnly(status, expectedMode, expectedUserID) {
  if (status.uid !== expectedUserID || (status.mode & 0o777) !== expectedMode) {
    throw new Error("unsafeRuntimePermissions");
  }
}

function readBootstrapToken(tokenPath, fileSystem) {
  const flags = fileSystem.constants.O_RDONLY | (fileSystem.constants.O_NOFOLLOW ?? 0);
  const descriptor = fileSystem.openSync(tokenPath, flags);
  try {
    const status = fileSystem.fstatSync(descriptor);
    requireOwnerOnly(status, 0o600, process.geteuid());
    if (!status.isFile() || status.size !== 64) throw new Error("invalidBootstrapToken");
    const token = fileSystem.readFileSync(descriptor, "utf8");
    if (!/^[a-f0-9]{64}$/u.test(token)) throw new Error("invalidBootstrapToken");
    return token;
  } finally {
    fileSystem.closeSync(descriptor);
  }
}

export function loadBridgeRuntimeConfiguration({
  environment = process.env,
  homeDirectory = os.homedir(),
  fileSystem = fs,
} = {}) {
  const configuredDirectory = environment[BRIDGE_DIRECTORY_ENVIRONMENT_KEY];
  const directory = path.resolve(
    configuredDirectory
      ?? path.join(homeDirectory, "Library", "Application Support", "Copilot Micro", "bridge"),
  );
  const directoryStatus = fileSystem.lstatSync(directory);
  if (!directoryStatus.isDirectory() || directoryStatus.isSymbolicLink()) {
    throw new Error("unsafeRuntimeDirectory");
  }
  requireOwnerOnly(directoryStatus, 0o700, process.geteuid());

  const socketPath = path.join(directory, BRIDGE_SOCKET_FILENAME);
  const socketStatus = fileSystem.lstatSync(socketPath);
  if (!socketStatus.isSocket() || socketStatus.isSymbolicLink()) {
    throw new Error("unsafeSocketPath");
  }
  requireOwnerOnly(socketStatus, 0o600, process.geteuid());

  return {
    socketPath,
    bootstrapToken: readBootstrapToken(
      path.join(directory, BOOTSTRAP_TOKEN_FILENAME),
      fileSystem,
    ),
  };
}

export function createHostBinding({
  parentProcessID = process.ppid,
  sessionID,
  generation = crypto.randomUUID(),
}) {
  if (!Number.isSafeInteger(parentProcessID) || parentProcessID <= 0) {
    throw new Error("invalidHostIdentity");
  }
  if (typeof sessionID !== "string" || !/^[!-~]{1,128}$/u.test(sessionID)) {
    throw new Error("invalidSessionIdentity");
  }
  if (typeof generation !== "string" || !/^[!-~]{1,96}$/u.test(generation)) {
    throw new Error("invalidGeneration");
  }
  return {
    instanceId: `cli-host-${parentProcessID}`,
    sessionId: sessionID,
    generation: `generation-${generation}`,
  };
}

export async function runHostExtension({
  joinSession,
  connect = connectAuthenticated,
  runtimeConfiguration = loadBridgeRuntimeConfiguration(),
  parentProcessID = process.ppid,
  heartbeatMilliseconds = DEFAULT_HEARTBEAT_MILLISECONDS,
  maximumReconnectAttempts = DEFAULT_MAXIMUM_RECONNECT_ATTEMPTS,
  reconnectDelayMilliseconds = DEFAULT_RECONNECT_DELAY_MILLISECONDS,
  signal,
  setIntervalFunction = setInterval,
  clearIntervalFunction = clearInterval,
  delayFunction = delay,
} = {}) {
  if (typeof joinSession !== "function") throw new Error("hostSdkUnavailable");
  if (!Number.isSafeInteger(heartbeatMilliseconds) || heartbeatMilliseconds < 1_000) {
    throw new Error("invalidHeartbeatInterval");
  }
  if (!Number.isSafeInteger(maximumReconnectAttempts) || maximumReconnectAttempts < 0) {
    throw new Error("invalidReconnectLimit");
  }
  if (!Number.isSafeInteger(reconnectDelayMilliseconds) || reconnectDelayMilliseconds < 1) {
    throw new Error("invalidReconnectDelay");
  }
  const session = await joinSession({ tools: [] });
  let reconnectAttempts = 0;
  let lastError = new Error("nativeBridgeUnavailable");

  while (!signal?.aborted) {
    let client;
    const binding = createHostBinding({
      parentProcessID,
      sessionID: session.sessionId,
    });
    const observer = new SessionObserver({
      session,
      binding,
      onFailure: () => client?.close(),
    });
    observer.subscribe();
    let heartbeat;
    const abort = () => client?.close();
    signal?.addEventListener("abort", abort, { once: true });
    try {
      client = await connect({
        socketPath: runtimeConfiguration.socketPath,
        registration: {
          protocolVersion: 1,
          messageType: "registration",
          role: "cliBridge",
          bootstrapToken: runtimeConfiguration.bootstrapToken,
          ...binding,
          bridgeVersion: BRIDGE_VERSION,
          cliVersion: "unknown",
          sdkVersion: "host-provided",
        },
      });
      reconnectAttempts = 0;
      await observer.attach((payload) => client.sendPayload(payload));
      const rejector = new ProductionActionRejector(observer);
      heartbeat = setIntervalFunction(() => {
        try {
          client.sendPayload(observer.heartbeatPayload());
        } catch {
          client.close();
        }
      }, heartbeatMilliseconds);

      while (!signal?.aborted && !observer.hostShutdown) {
        const frame = await client.receive();
        client.sendPayload(rejector.reject(frame.payload));
      }
      if (signal?.aborted || observer.hostShutdown) return;
    } catch (error) {
      if (signal?.aborted || observer.hostShutdown) return;
      lastError = error;
    } finally {
      if (heartbeat !== undefined) clearIntervalFunction(heartbeat);
      signal?.removeEventListener("abort", abort);
      observer.stop();
      client?.close();
    }
    if (reconnectAttempts >= maximumReconnectAttempts) throw lastError;
    reconnectAttempts += 1;
    await delayFunction(reconnectDelayMilliseconds * reconnectAttempts, signal);
  }
}

function delay(milliseconds, signal) {
  if (signal?.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, milliseconds);
    signal?.addEventListener("abort", finish, { once: true });
  });
}

export function classifyExtensionFailure(error) {
  const message = String(error?.message ?? error ?? "");
  if (
    [
      "invalidBootstrapToken",
      "unsafeRuntimeDirectory",
      "unsafeRuntimePermissions",
      "unsafeSocketPath",
    ].includes(message)
  ) {
    return message;
  }
  if (/ENOENT|ECONNREFUSED|disconnected/iu.test(message)) return "nativeBridgeUnavailable";
  if (/invalidHostIdentity|invalidSessionIdentity|invalidGeneration/iu.test(message)) {
    return "invalidHostIdentity";
  }
  if (/invalidToken|wrongPeer|wrongRole/iu.test(message)) return "authenticationRejected";
  return "bridgeStartupFailed";
}
