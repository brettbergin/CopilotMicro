import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  QUALIFICATION_CONSENT,
  TOKEN_ENVIRONMENT_NAMES,
  buildInteractiveCommand,
  cleanupProbeWorkspace,
  prepareProbeWorkspace,
  readProbeWorkspaceSummary,
  safeEnvironment,
  summarizeProbeEvidence,
} from "../qualify-cli.mjs";

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));

test("qualification workspace is private, disposable, and project-scoped", () => {
  const prepared = prepareProbeWorkspace(root);
  try {
    assert.equal(path.dirname(prepared.workspace), fs.realpathSync(os.tmpdir()));
    assert.match(path.basename(prepared.workspace), /^copilot-micro-cli-probe-/u);
    assert.equal(fs.statSync(prepared.workspace).mode & 0o777, 0o700);
    assert.equal(fs.statSync(prepared.extensionDirectory).mode & 0o777, 0o700);
    assert.equal(
      fs.existsSync(path.join(root, ".github", "extensions", "copilot-micro-capability-probe-v1")),
      false,
    );
    assert.equal(
      fs.existsSync(path.join(prepared.extensionDirectory, "extension.mjs")),
      true,
    );
    const head = fs.readFileSync(path.join(prepared.workspace, ".git", "HEAD"), "utf8");
    assert.equal(head.trim(), "ref: refs/heads/main");
  } finally {
    cleanupProbeWorkspace(prepared.workspace, prepared.marker.nonce);
  }
  assert.equal(fs.existsSync(prepared.workspace), false);
});

test("cleanup refuses an unowned directory and a marker mismatch", () => {
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "not-a-cli-probe-"));
  const prepared = prepareProbeWorkspace(root);
  try {
    assert.throws(
      () => cleanupProbeWorkspace(outside, "missing"),
      /unsafeQualificationWorkspace/u,
    );
    assert.throws(
      () => cleanupProbeWorkspace(prepared.workspace, "0".repeat(32)),
      /qualificationMarkerMismatch/u,
    );
    assert.throws(
      () => readProbeWorkspaceSummary(
        { copilot: "copilot" },
        prepared.workspace,
        "0".repeat(32),
      ),
      /qualificationMarkerMismatch/u,
    );
  } finally {
    fs.rmSync(outside, { recursive: true, force: true });
    cleanupProbeWorkspace(prepared.workspace, prepared.marker.nonce);
  }
});

test("live child environment removes GitHub and Copilot token variables", () => {
  const source = Object.fromEntries(TOKEN_ENVIRONMENT_NAMES.map((name) => [name, "secret"]));
  source.SAFE_VALUE = "retained";
  const environment = safeEnvironment(false, false, source);
  for (const name of TOKEN_ENVIRONMENT_NAMES) assert.equal(environment[name], undefined);
  assert.equal(environment.SAFE_VALUE, "retained");
  assert.equal(environment.COPILOT_MICRO_PROBE_ACTIVE, "0");
  assert.equal(environment.COPILOT_MICRO_PROBE_PERMISSION_EVENTS, undefined);
});

test("non-interactive launch failure removes the marker-verified workspace", () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "copilot-micro-launch-test-"));
  try {
    const result = spawnSync(
      process.execPath,
      [
        path.join(root, "scripts", "qualify-cli.mjs"),
        "--consent",
        QUALIFICATION_CONSENT,
      ],
      {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, TMPDIR: temporaryRoot },
      },
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /interactiveTerminalRequired/u);
    assert.deepEqual(fs.readdirSync(temporaryRoot), []);
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test("Makefile requires exact opt-in values for mutating probes", () => {
  for (const assignment of ["ACTIVE=0", "PERMISSION_EVENTS=0"]) {
    const result = spawnSync(
      "make",
      ["qualify-cli", `CONSENT=${QUALIFICATION_CONSENT}`, assignment],
      { cwd: root, encoding: "utf8" },
    );
    assert.notEqual(result.status, 0);
    assert.match(`${result.stdout}\n${result.stderr}`, /must be exactly 1/u);
  }
});

test("default interactive command lets the CLI create its own session", () => {
  const command = buildInteractiveCommand("copilot", "/private/disposable");
  assert.equal(command.includes("--session-id"), false);
  assert.deepEqual(command.slice(-2), ["-C", "/private/disposable"]);
});

test("summary records gaps without promoting method presence to support", () => {
  const records = [
    {
      probeInstance: "probe-1",
      hostAlias: "host-1",
      kind: "process.started",
      status: "observed",
      data: { nodeVersion: "v25.8.2", platform: "darwin", architecture: "arm64" },
    },
    {
      probeInstance: "probe-1",
      hostAlias: "host-1",
      kind: "join.succeeded",
      status: "demonstrated",
      data: { sessionAlias: "session-1" },
    },
    {
      probeInstance: "probe-1",
      hostAlias: "host-1",
      kind: "surface.snapshot",
      status: "observed",
      data: { methods: { "sessions.list": false, "composer.focus": false, "composer.submit": false } },
    },
    ...[
      "mode.current",
      "model.current",
      "model.list",
      "tasks.list",
      "queue.pendingItems",
      "permissions.pendingRequests",
      "permissions.setRequired",
      "commands.list",
      "mode.set",
      "mode.afterSet",
      "mode.restored",
      "model.setReasoningEffort",
      "model.afterEffortSet",
    ].map((operation) => ({
      probeInstance: "probe-1",
      hostAlias: "host-1",
      kind: "rpc.result",
      status: "demonstrated",
      data: {
        operation,
        result: operation === "commands.list"
          ? { relevantCommands: ["voice"] }
          : operation === "permissions.setRequired"
            ? { success: true }
            : operation === "mode.current"
              ? { mode: "interactive" }
              : operation === "mode.set"
                ? { requestedMode: "plan", resultMode: null }
                : operation === "mode.afterSet"
                  ? { mode: "plan" }
                  : operation === "mode.restored"
                    ? { mode: "interactive" }
                    : operation === "model.current"
                      ? { modelId: "gpt-test", reasoningEffort: "medium" }
                      : operation === "model.list"
                        ? { models: [] }
                        : operation === "model.setReasoningEffort"
                          ? { reasoningEffort: "medium" }
                          : operation === "model.afterEffortSet"
                            ? { modelId: "gpt-test", reasoningEffort: "medium" }
                            : {},
      },
    })),
  ];
  const summary = summarizeProbeEvidence(records, {
    cliVersion: "1.0.84-5",
    cliBuildCommit: "0de509ce",
    sdkVersion: "1.0.13-preview.4",
  });
  assert.equal(summary.environment.cliBuildCommit, "0de509ce");
  assert.equal(summary.environment.sdkVersion, "1.0.13-preview.4");
  assert.equal(summary.capabilities["U-01"].status, "partial");
  assert.equal(summary.capabilities["U-03"].status, "unavailable");
  assert.equal(summary.capabilities["U-05"].status, "unavailable");
  assert.equal(summary.capabilities["U-06"].status, "partial");
  assert.equal(summary.capabilities["U-07"].status, "unavailable");
  assert.match(
    summary.capabilities["U-07"].limitations.join(" "),
    /No permission\.requested event was observed/u,
  );
  assert.equal(summary.capabilities["U-08"].status, "partial");
  assert.match(summary.capabilities["U-08"].evidence.join(" "), /round-tripped/u);
  assert.match(summary.capabilities["U-08"].evidence.join(" "), /written back/u);
  assert.doesNotMatch(JSON.stringify(summary), /session-1|host-1|probe-1/u);
});

test("summary does not claim failed mode or effort round trips", () => {
  const rpc = (operation, result) => ({
    probeInstance: "probe-1",
    hostAlias: "host-1",
    kind: "rpc.result",
    status: "demonstrated",
    data: { operation, result },
  });
  const summary = summarizeProbeEvidence([
    rpc("mode.current", { mode: "interactive" }),
    rpc("mode.set", { requestedMode: "plan" }),
    rpc("mode.afterSet", { mode: "interactive" }),
    rpc("mode.restored", { mode: "plan" }),
    rpc("model.current", { modelId: "gpt-test", reasoningEffort: "medium" }),
    rpc("model.list", { models: [] }),
    rpc("model.setReasoningEffort", { reasoningEffort: "high" }),
    rpc("model.afterEffortSet", { modelId: "gpt-test", reasoningEffort: "high" }),
  ], { cliVersion: "1.0.84-5" });
  const evidenceText = summary.capabilities["U-08"].evidence.join(" ");
  assert.doesNotMatch(evidenceText, /round-tripped|written back/u);
});
