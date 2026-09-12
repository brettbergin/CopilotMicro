#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

export const QUALIFICATION_CONSENT = "I-own-this-disposable-session";
export const TOKEN_ENVIRONMENT_NAMES = [
  "COPILOT_GITHUB_TOKEN",
  "COPILOT_SDK_TOKEN",
  "GH_ENTERPRISE_TOKEN",
  "GH_PAT",
  "GH_TOKEN",
  "GITHUB_ENTERPRISE_TOKEN",
  "GITHUB_PAT",
  "GITHUB_PERSONAL_ACCESS_TOKEN",
  "GITHUB_TOKEN",
];
const WORKSPACE_PREFIX = "copilot-micro-cli-probe-";
const MARKER_NAME = ".copilot-micro-probe-owner.json";

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writePrivateJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  fs.chmodSync(filePath, 0o600);
}

export function safeEnvironment(
  active,
  permissionEvents,
  sourceEnvironment = process.env,
) {
  const environment = { ...sourceEnvironment };
  for (const name of TOKEN_ENVIRONMENT_NAMES) delete environment[name];
  environment.COPILOT_MICRO_PROBE_ACTIVE = active ? "1" : "0";
  if (permissionEvents) environment.COPILOT_MICRO_PROBE_PERMISSION_EVENTS = "1";
  else delete environment.COPILOT_MICRO_PROBE_PERMISSION_EVENTS;
  return environment;
}

function parseArguments(arguments_) {
  const options = {
    active: false,
    cleanup: true,
    collect: null,
    consent: null,
    copilot: "copilot",
    nonce: null,
    output: null,
    permissionEvents: false,
    prepareOnly: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--active") options.active = true;
    else if (argument === "--permission-events") options.permissionEvents = true;
    else if (argument === "--keep") options.cleanup = false;
    else if (argument === "--prepare-only") options.prepareOnly = true;
    else if (["--collect", "--consent", "--copilot", "--nonce", "--output"].includes(argument)) {
      options[{
        "--collect": "collect",
        "--consent": "consent",
        "--copilot": "copilot",
        "--nonce": "nonce",
        "--output": "output",
      }[argument]] = arguments_[index + 1];
      index += 1;
    } else {
      throw new Error(`unknownArgument:${argument}`);
    }
  }
  if (options.consent !== QUALIFICATION_CONSENT) throw new Error("explicitConsentRequired");
  if (options.collect && !/^[a-f0-9]{32}$/u.test(options.nonce ?? "")) {
    throw new Error("collectNonceRequired");
  }
  if (!options.collect && options.nonce) throw new Error("nonceRequiresCollect");
  return options;
}

function requireOwnedWorkspace(workspacePath, expectedNonce) {
  const resolved = fs.realpathSync(workspacePath);
  if (
    path.dirname(resolved) !== fs.realpathSync(os.tmpdir())
    || !path.basename(resolved).startsWith(WORKSPACE_PREFIX)
  ) {
    throw new Error("unsafeQualificationWorkspace");
  }
  const markerPath = path.join(resolved, MARKER_NAME);
  const markerStatus = fs.lstatSync(markerPath);
  if (!markerStatus.isFile() || markerStatus.isSymbolicLink()) {
    throw new Error("invalidQualificationMarker");
  }
  const marker = readJson(markerPath);
  let markerWorkspace;
  try {
    markerWorkspace = typeof marker.workspace === "string"
      ? fs.realpathSync(marker.workspace)
      : null;
  } catch {
    markerWorkspace = null;
  }
  if (
    marker.schemaVersion !== 1
    || markerWorkspace !== resolved
    || typeof marker.nonce !== "string"
    || !/^[a-f0-9]{32}$/u.test(marker.nonce)
  ) {
    throw new Error("invalidQualificationMarker");
  }
  if (expectedNonce !== undefined && marker.nonce !== expectedNonce) {
    throw new Error("qualificationMarkerMismatch");
  }
  return { marker, resolved };
}

export function prepareProbeWorkspace(repositoryRoot) {
  const workspace = fs.realpathSync(
    fs.mkdtempSync(path.join(os.tmpdir(), WORKSPACE_PREFIX)),
  );
  fs.chmodSync(workspace, 0o700);
  const marker = {
    schemaVersion: 1,
    workspace,
    nonce: crypto.randomBytes(16).toString("hex"),
  };
  writePrivateJson(path.join(workspace, MARKER_NAME), marker);
  try {
    const extensionDirectory = path.join(
      workspace,
      ".github",
      "extensions",
      "copilot-micro-capability-probe-v1",
    );
    fs.mkdirSync(extensionDirectory, { recursive: true, mode: 0o700 });
    fs.cpSync(path.join(repositoryRoot, "Bridge", "probe"), extensionDirectory, {
      recursive: true,
      errorOnExist: true,
    });
    for (const entry of fs.readdirSync(extensionDirectory)) {
      fs.chmodSync(path.join(extensionDirectory, entry), 0o600);
    }
    fs.writeFileSync(
      path.join(workspace, "README.md"),
      "# Disposable Copilot Micro CLI capability probe\n\n"
        + "This repository contains no product source and may be deleted after qualification.\n",
      { mode: 0o600 },
    );
    fs.writeFileSync(
      path.join(workspace, ".gitignore"),
      `${MARKER_NAME}\nexpect-transcript.txt\nlogs/\nprobe-evidence.jsonl\n`,
      { mode: 0o600 },
    );
    fs.mkdirSync(path.join(workspace, "logs"), { mode: 0o700 });
    const git = spawnSync("git", ["init", "-q", "-b", "main"], {
      cwd: workspace,
      encoding: "utf8",
    });
    if (git.status !== 0) throw new Error("gitInitializationFailed");
    const commit = spawnSync(
      "git",
      [
        "-c",
        "user.name=Copilot",
        "-c",
        "user.email=223556219+Copilot@users.noreply.github.com",
        "add",
        ".",
      ],
      { cwd: workspace, encoding: "utf8" },
    );
    if (commit.status !== 0) throw new Error("gitStagingFailed");
    const committed = spawnSync(
      "git",
      [
        "-c",
        "user.name=Copilot",
        "-c",
        "user.email=223556219+Copilot@users.noreply.github.com",
        "commit",
        "-q",
        "-m",
        "Add disposable CLI capability probe\n\nwritten by Copilot, on behalf of @brettbergin\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>\nCopilot-Session: a5e45bc9-ff13-4c85-b33b-477021df31c8",
      ],
      { cwd: workspace, encoding: "utf8" },
    );
    if (committed.status !== 0) throw new Error("gitCommitFailed");
    return {
      evidencePath: path.join(extensionDirectory, "probe-evidence.jsonl"),
      extensionDirectory,
      marker,
      workspace,
    };
  } catch (error) {
    cleanupProbeWorkspace(workspace, marker.nonce);
    throw error;
  }
}

export function buildInteractiveCommand(copilot, workspace) {
  return [
    copilot,
    "--screen-reader",
    "--disable-builtin-mcps",
    "--log-dir",
    path.join(workspace, "logs"),
    "-C",
    workspace,
  ];
}

export function cleanupProbeWorkspace(workspacePath, expectedNonce) {
  const { resolved } = requireOwnedWorkspace(workspacePath, expectedNonce);
  fs.rmSync(resolved, { recursive: true, force: false });
}

function readEvidence(evidencePath) {
  const status = fs.lstatSync(evidencePath);
  if (!status.isFile() || status.isSymbolicLink() || status.size > 131_072) {
    throw new Error("invalidProbeEvidence");
  }
  return fs.readFileSync(evidencePath, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function rpcResults(records, operation) {
  return records.filter(
    (record) => record.kind === "rpc.result" && record.data?.operation === operation,
  );
}

function demonstrated(records, operation) {
  return rpcResults(records, operation).some((record) => record.status === "demonstrated");
}

function recordsByProbeInstance(records) {
  const groups = new Map();
  for (const record of records) {
    const group = groups.get(record.probeInstance) ?? [];
    group.push(record);
    groups.set(record.probeInstance, group);
  }
  return groups.values();
}

function verifiedModeRoundTrip(records) {
  for (const group of recordsByProbeInstance(records)) {
    const setIndex = group.findIndex(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "mode.set",
    );
    if (setIndex < 0) continue;
    const initial = group.slice(0, setIndex).reverse().find(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "mode.current",
    )?.data?.result?.mode;
    const requested = group[setIndex].data?.result?.requestedMode;
    const after = group.slice(setIndex + 1).find(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "mode.afterSet",
    )?.data?.result?.mode;
    const restored = group.slice(setIndex + 1).find(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "mode.restored",
    )?.data?.result?.mode;
    if (
      ["interactive", "plan"].includes(initial)
      && ["interactive", "plan"].includes(requested)
      && requested !== initial
      && after === requested
      && restored === initial
    ) {
      return true;
    }
  }
  return false;
}

function verifiedEffortRoundTrip(records) {
  for (const group of recordsByProbeInstance(records)) {
    const setIndex = group.findIndex(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "model.setReasoningEffort",
    );
    if (setIndex < 0) continue;
    const initial = group.slice(0, setIndex).reverse().find(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "model.current",
    )?.data?.result?.reasoningEffort;
    const written = group[setIndex].data?.result?.reasoningEffort;
    const after = group.slice(setIndex + 1).find(
      (record) => record.kind === "rpc.result"
        && record.status === "demonstrated"
        && record.data?.operation === "model.afterEffortSet",
    )?.data?.result?.reasoningEffort;
    if (typeof initial === "string" && written === initial && after === initial) return true;
  }
  return false;
}

function evidence(status, evidenceLines, limitations = []) {
  return { status, evidence: evidenceLines.slice(0, 8), limitations: limitations.slice(0, 8) };
}

export function summarizeProbeEvidence(
  records,
  { cliVersion, cliBuildCommit = null, sdkVersion = null },
) {
  const processRecords = records.filter((record) => record.kind === "process.started");
  const joins = records.filter((record) => record.kind === "join.succeeded");
  const signals = records.filter((record) => record.kind === "process.signal");
  const hostAliases = new Set(joins.map((record) => record.hostAlias));
  const sessionAliases = new Set(joins.map((record) => record.data?.sessionAlias).filter(Boolean));
  const surface = records.find((record) => record.kind === "surface.snapshot")?.data?.methods ?? {};
  const commandNames = new Set(
    rpcResults(records, "commands.list")
      .flatMap((record) => record.data?.result?.relevantCommands ?? []),
  );
  const permissionObserved = records.some(
    (record) => record.kind === "event.observed"
      && record.data?.eventType === "permission.requested",
  );
  const permissionBridgeEnabled = rpcResults(records, "permissions.setRequired")
    .some((record) => record.data?.result?.success === true);
  const protocolVersion = rpcResults(records, "sdk.protocol")
    .map((record) => record.data?.result?.protocolVersion)
    .find((value) => Number.isSafeInteger(value)) ?? null;
  const childNodeVersions = [...new Set(
    processRecords.map((record) => record.data?.nodeVersion).filter(Boolean),
  )].slice(0, 8);
  const platform = processRecords[0]?.data?.platform ?? "unknown";
  const architecture = processRecords[0]?.data?.architecture ?? "unknown";
  const lifecycleDemonstrated = joins.length >= 2
    && sessionAliases.size >= 2
    && hostAliases.size === 1;
  const modeRoundTrip = verifiedModeRoundTrip(records);
  const modelRead = rpcResults(records, "model.current")
    .some((record) => typeof record.data?.result?.modelId === "string")
    && rpcResults(records, "model.list")
      .some((record) => Array.isArray(record.data?.result?.models));
  const effortWrite = verifiedEffortRoundTrip(records);
  const queueRead = demonstrated(records, "queue.pendingItems");
  const tasksRead = demonstrated(records, "tasks.list");
  const pendingPermissionRead = demonstrated(records, "permissions.pendingRequests");
  const sessionApi = surface["sessions.list"] === true;
  const voiceCommand = commandNames.has("voice");
  const composerApi = surface["composer.focus"] === true || surface["composer.submit"] === true;

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    environment: {
      cliVersion,
      cliBuildCommit,
      sdkSource: "host-provided",
      sdkVersion,
      sdkProtocolVersion: protocolVersion,
      childNodeVersions,
      platform,
      architecture,
    },
    lifecycle: {
      extensionLifetimes: new Set(
        processRecords.map((record) => record.probeInstance),
      ).size,
      joinedSessions: sessionAliases.size,
      sameHostAcrossReplacement: lifecycleDemonstrated,
      terminationObserved: signals.length > 0,
    },
    capabilities: {
      "U-01": evidence(
        joins.length > 0 ? "partial" : "unavailable",
        joins.length > 0
          ? [
              `joinSession succeeded in ${joins.length} extension lifetime(s).`,
              lifecycleDemonstrated
                ? "Two session aliases and extension lifetimes were observed under the same host."
                : null,
            ].filter(Boolean)
          : [],
        [
          lifecycleDemonstrated
            ? "Selecting an arbitrary existing foreground session was not demonstrated."
            : "Foreground replacement and same-host reload require at least two joined session aliases.",
        ],
      ),
      "U-02": evidence(
        queueRead && tasksRead && pendingPermissionRead ? "partial" : "unavailable",
        [
          queueRead ? "The live queue snapshot RPC returned bounded counts." : null,
          tasksRead ? "The live background-task snapshot RPC returned bounded counts." : null,
          pendingPermissionRead ? "The pending-permission snapshot RPC returned a bounded count." : null,
        ].filter(Boolean),
        [
          "No API exposed a verified user acknowledgement/read state.",
          "Whole-session idle is event-driven and requires production reconciliation.",
        ],
      ),
      "U-03": evidence(
        sessionApi ? "partial" : "unavailable",
        [
          sessionApi ? "A session-list RPC was callable from the extension." : null,
          commandNames.size > 0
            ? `Relevant host commands observed: ${[...commandNames].sort().join(", ")}.`
            : null,
        ].filter(Boolean),
        [
          "No demonstrated extension API switched, created, or archived a foreground TUI session.",
          "Command presence alone is not proof that a companion can drive the host UI.",
        ],
      ),
      "U-04": evidence(
        "not-in-scope",
        [],
        ["Exact terminal window, tab, and pane targeting belongs to terminal adapter qualification."],
      ),
      "U-05": evidence(
        composerApi ? "partial" : "unavailable",
        demonstrated(records, "completions.triggerCharacters")
          ? ["Host-driven composer completion triggers were readable."]
          : [],
        [
          "No demonstrated API focused or submitted the existing TUI composer draft.",
          "session.send() is intentionally not accepted as a composer substitute.",
        ],
      ),
      "U-06": evidence(
        voiceCommand ? "partial" : "unavailable",
        voiceCommand ? ["The live host advertised a voice command."] : [],
        ["No extension RPC demonstrated native voice start, stop, state, or dependency handling."],
      ),
      "U-07": evidence(
        permissionObserved ? "partial" : "unavailable",
        [
          pendingPermissionRead ? "Pending permission requests were readable without installing a handler." : null,
          permissionBridgeEnabled
            ? "The extension enabled per-client permission event bridging without installing a decision handler."
            : null,
          permissionObserved ? "A permission.requested event was observed passively." : null,
        ].filter(Boolean),
        [
          permissionBridgeEnabled && !permissionObserved
            ? "No permission.requested event was observed after event bridging reported success."
            : null,
          "The SDK request ID does not prove that the exact prompt is visible in the selected terminal.",
          "Approve/reject remains disabled until visible-request binding and concurrent response races are qualified.",
        ].filter(Boolean),
      ),
      "U-08": evidence(
        modelRead ? "partial" : "unavailable",
        [
          modelRead ? "Current model and bounded available-model metadata were read from the live session." : null,
          modeRoundTrip ? "Interactive and plan mode were round-tripped and restored." : null,
          effortWrite ? "The current reasoning effort was written back and read without changing its value." : null,
        ].filter(Boolean),
        [
          "A different model was not selected, and next-turn inference semantics were not exercised.",
          "Autopilot was not enabled by the probe.",
        ],
      ),
    },
  };
}

function installedCliMetadata(copilot) {
  const result = spawnSync(copilot, ["--version"], { encoding: "utf8" });
  if (result.status !== 0) throw new Error("copilotVersionFailed");
  const match = `${result.stdout}\n${result.stderr}`.match(/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/u);
  if (!match) throw new Error("copilotVersionUnknown");
  const version = match[0];
  const packageRoot = path.join(
    os.homedir(),
    ".copilot",
    "pkg",
    `${process.platform}-${process.arch}`,
    version,
  );
  let cliBuildCommit = null;
  let sdkVersion = null;
  try {
    const packageMetadata = readJson(path.join(packageRoot, "package.json"));
    cliBuildCommit = typeof packageMetadata.buildMetadata?.gitCommit === "string"
      ? packageMetadata.buildMetadata.gitCommit
      : null;
    const extensionBundle = fs.readFileSync(
      path.join(packageRoot, "copilot-sdk", "extension.js"),
      "utf8",
    );
    sdkVersion = extensionBundle.match(/@github\+copilot-sdk@([0-9A-Za-z.-]+)/u)?.[1] ?? null;
  } catch {
    // Version metadata is optional evidence; the live CLI version remains authoritative.
  }
  return { cliBuildCommit, sdkVersion, version };
}

export function readProbeWorkspaceSummary(options, workspacePath, expectedNonce) {
  const { resolved } = requireOwnedWorkspace(workspacePath, expectedNonce);
  const evidencePath = path.join(
    resolved,
    ".github",
    "extensions",
    "copilot-micro-capability-probe-v1",
    "probe-evidence.jsonl",
  );
  const metadata = installedCliMetadata(options.copilot);
  const summary = summarizeProbeEvidence(readEvidence(evidencePath), {
    cliVersion: metadata.version,
    cliBuildCommit: metadata.cliBuildCommit,
    sdkVersion: metadata.sdkVersion,
  });
  return { resolved, summary };
}

function writeSummary(options, summary) {
  if (options.output) writePrivateJson(path.resolve(options.output), summary);
  else process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
}

function isMainModule() {
  return process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
}

if (isMainModule()) {
  try {
    const options = parseArguments(process.argv.slice(2));
    if (options.collect) {
      const owned = requireOwnedWorkspace(options.collect, options.nonce);
      try {
        const collected = readProbeWorkspaceSummary(options, owned.resolved, options.nonce);
        writeSummary(options, collected.summary);
      } finally {
        if (options.cleanup && fs.existsSync(owned.resolved)) {
          cleanupProbeWorkspace(owned.resolved, options.nonce);
        }
      }
    } else {
      const repositoryRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
      let prepared;
      try {
        prepared = prepareProbeWorkspace(repositoryRoot);
        const command = buildInteractiveCommand(options.copilot, prepared.workspace);
        if (options.prepareOnly) {
          process.stdout.write(`${JSON.stringify({
            workspace: prepared.workspace,
            evidencePath: prepared.evidencePath,
            markerNonce: prepared.marker.nonce,
            command,
          })}\n`);
        } else {
          if (!process.stdin.isTTY || !process.stdout.isTTY) {
            throw new Error("interactiveTerminalRequired");
          }
          process.stderr.write(
            "Disposable probe ready. Use only non-destructive prompts, /clear for replacement, then /exit.\n",
          );
          const result = spawnSync(command[0], command.slice(1), {
            cwd: prepared.workspace,
            env: safeEnvironment(options.active, options.permissionEvents),
            stdio: "inherit",
          });
          if (result.error) throw result.error;
          const collected = readProbeWorkspaceSummary(
            options,
            prepared.workspace,
            prepared.marker.nonce,
          );
          writeSummary(options, collected.summary);
          if (result.status !== 0) process.exitCode = result.status ?? 1;
        }
      } finally {
        if (
          prepared
          && options.cleanup
          && !options.prepareOnly
          && fs.existsSync(prepared.workspace)
        ) {
          cleanupProbeWorkspace(prepared.workspace, prepared.marker.nonce);
        }
      }
    }
  } catch (error) {
    process.stderr.write(`${JSON.stringify({
      outcome: "failed",
      error: String(error.message ?? error),
    })}\n`);
    process.exitCode = 1;
  }
}
