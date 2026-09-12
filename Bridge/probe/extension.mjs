import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

import {
  EvidenceWriter,
  aliasIdentifier,
  classifyProbeError,
  recordRpcProbe,
  runActiveProbes,
  runReadOnlyProbes,
  sanitizeSessionEvent,
} from "./probe-core.mjs";

const writer = new EvidenceWriter({
  outputPath: fileURLToPath(new URL("./probe-evidence.jsonl", import.meta.url)),
  probeInstance: crypto.randomUUID(),
  hostAlias: aliasIdentifier("host", process.ppid),
});

writer.record("process.started", "observed", {
  nodeVersion: process.version,
  platform: process.platform,
  architecture: process.arch,
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    writer.record("process.signal", "observed", { signal });
    process.exit(0);
  });
}

let session;
try {
  const { joinSession } = await import("@github/copilot-sdk/extension");
  session = await joinSession({
    tools: [],
  });
} catch (error) {
  writer.record("join.failed", "failed", {
    errorCategory: classifyProbeError(error),
  });
  process.exitCode = 1;
}

if (session) {
  try {
    const sessionAlias = aliasIdentifier("session", session.sessionId);
    writer.record("join.succeeded", "demonstrated", {
      sessionAlias,
      sdkSource: "host-provided",
      workspaceAvailable: typeof session.workspacePath === "string",
      hostCapabilities: {
        elicitation: session.capabilities.ui?.elicitation === true,
        canvases: session.capabilities.ui?.canvases === true,
        mcpApps: session.capabilities.ui?.mcpApps === true,
      },
    });
    session.on((event) => {
      const safeEvent = sanitizeSessionEvent(event, sessionAlias);
      if (safeEvent) writer.record("event.observed", "observed", safeEvent);
    });
    if (process.env.COPILOT_MICRO_PROBE_PERMISSION_EVENTS === "1") {
      await recordRpcProbe(
        writer,
        "permissions.setRequired",
        () => session.rpc.permissions.setRequired({ required: true }),
      );
    }
    await runReadOnlyProbes(session, writer, async () => {
      try {
        const sdk = await import("@github/copilot-sdk/sdkProtocolVersion");
        return sdk.getSdkProtocolVersion();
      } catch {
        throw new Error("methodUnavailable");
      }
    });
    if (process.env.COPILOT_MICRO_PROBE_ACTIVE === "1") {
      await runActiveProbes(session, writer);
    }
  } catch (error) {
    writer.record("probe.failed", "failed", {
      errorCategory: classifyProbeError(error),
    });
    process.exitCode = 1;
  }
}
