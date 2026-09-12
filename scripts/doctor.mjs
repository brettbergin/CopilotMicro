import { spawnSync } from "node:child_process";
import * as nodeFS from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const LIMITS = Object.freeze({
  timeoutMs: 5000,
  outputBytes: 16384,
  applicationEntries: 256,
  developerCandidates: 8,
  pathEntries: 64,
});

export const SCOPE =
  "Developer prerequisites only. No app, CLI, terminal, emulator or hardware " +
  "qualification. No login/authentication or extension checks are performed.";

export const HELP = `Usage: scripts/doctor [--phase xcode|development] [--developer-dir PATH] [--json]
       scripts/doctor --help
       node scripts/doctor.mjs [the same options]

Read-only, local developer prerequisite checks for Copilot Micro.

  --phase xcode        I-00 setup: Apple Silicon, macOS Tahoe 26.x, full Xcode,
                       a macOS SDK >= 26, Swift >= 6, and Node.js >= 18.
                       XcodeGen is reported but is not a blocker in this phase.
  --phase development  Default: the setup checks plus required XcodeGen.
  --developer-dir PATH An absolute Xcode .app or its Contents/Developer directory.
                       Overrides DEVELOPER_DIR. An invalid override is BLOCKED,
                       never silently replaced by another installation.
  --json               Stable JSON report (no timestamps or raw command output).
  --help, -h           Show this help without running probes.

Without an override, inspect Xcode*.app directly in /Applications and
~/Applications, in that order. The current global xcode-select setting is
reported, never changed. Each candidate must pass scoped xcodebuild and macOS
SDK probes; a .app name or Command Line Tools installation is not sufficient.
Discovery examines at most ${LIMITS.applicationEntries} entries per location and
${LIMITS.developerCandidates} candidates. PATH lookup examines at most ${LIMITS.pathEntries} entries.
Each subprocess has a ${LIMITS.timeoutMs} ms timeout and ${LIMITS.outputBytes}-byte output limit.

Copilot and gh are optional version-only probes for later live CLI and private
update work. Missing tools or authentication do not block native GUI/emulator
development. This command never requests tokens, installs software, downloads
data, loads extensions, starts/attaches an agent, or accesses HID devices.

macOS 26.6.2 is the initial qualification baseline, not a required patch version.
Detected versions are observations, not selected shipping pins.
${SCOPE}

Exit codes: 0 = prerequisites detected (or help), 1 = BLOCKED, 2 = invalid usage.
`;

class ArgumentError extends Error {}

export function parseArguments(argv) {
  const options = { phase: "development", developerDir: null, json: false, help: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index] === "-h" ? "--help" : argv[index];
    if (!["--phase", "--developer-dir", "--json", "--help"].includes(flag)) {
      throw new ArgumentError("Unknown argument. Use --help for supported options.");
    }
    if (seen.has(flag)) throw new ArgumentError("Duplicate option. Specify each option once.");
    seen.add(flag);
    if (flag === "--json" || flag === "--help") {
      options[flag.slice(2)] = true;
      continue;
    }
    const value = argv[++index];
    if (!value || value.startsWith("-")) {
      throw new ArgumentError("Missing option value. Use --help for supported options.");
    }
    if (flag === "--phase") {
      if (!["xcode", "development"].includes(value)) {
        throw new ArgumentError("Invalid phase. Expected xcode or development.");
      }
      options.phase = value;
    } else {
      if (!path.isAbsolute(value) || /[\u0000-\u001f\u007f]/u.test(value)) {
        throw new ArgumentError("--developer-dir requires an absolute path without control characters.");
      }
      options.developerDir = value;
    }
  }
  return options;
}

function failureReason(error) {
  return {
    ENOENT: "not_found",
    ENOTDIR: "not_directory",
    EACCES: "permission_denied",
    EPERM: "permission_denied",
    ETIMEDOUT: "timed_out",
    ENOBUFS: "output_limit",
  }[error.code] ?? "probe_failed";
}

export function runCommand(command, args, env, spawn = spawnSync) {
  const result = spawn(command, args, {
    env,
    shell: false,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: LIMITS.timeoutMs,
    maxBuffer: LIMITS.outputBytes,
    killSignal: "SIGKILL",
  });
  if (result.error) return { ok: false, reason: failureReason(result.error) };
  if (result.signal) return { ok: false, reason: "terminated" };
  if (result.status !== 0) return { ok: false, reason: "nonzero_exit" };
  return { ok: true, stdout: result.stdout ?? "" };
}

export function inspectDirectory(directory, fs = nodeFS) {
  try {
    if (!fs.statSync(directory).isDirectory()) return { ok: false, reason: "not_directory" };
    return { ok: true, path: fs.realpathSync(directory) };
  } catch (error) {
    return { ok: false, reason: failureReason(error) };
  }
}

export function listXcodeApps(directory, fs = nodeFS) {
  let handle;
  try {
    handle = fs.opendirSync(directory);
    const apps = [];
    for (let count = 0; count < LIMITS.applicationEntries; count += 1) {
      const entry = handle.readSync();
      if (!entry) return { ok: true, apps: apps.sort(), limited: false };
      if (/^Xcode[^/]*\.app$/iu.test(entry.name)) apps.push(path.join(directory, entry.name));
    }
    return { ok: true, apps: apps.sort(), limited: handle.readSync() !== null };
  } catch (error) {
    return { ok: false, reason: failureReason(error) };
  } finally {
    handle?.closeSync();
  }
}

export function findExecutable(name, searchPath, fs = nodeFS) {
  const entries = searchPath.split(path.delimiter);
  let inaccessible = false;
  for (const entry of entries.slice(0, LIMITS.pathEntries)) {
    const executable = path.resolve(entry || ".", name);
    try {
      fs.accessSync(executable, fs.constants.X_OK);
      if (fs.statSync(executable).isFile()) return { ok: true, path: executable };
    } catch (error) {
      if (!["ENOENT", "ENOTDIR"].includes(error.code)) inaccessible = true;
    }
  }
  return {
    ok: false,
    reason: inaccessible ? "permission_denied" : "not_found",
    limited: entries.length > LIMITS.pathEntries,
  };
}

const realFilesystem = {
  directory: inspectDirectory,
  applications: listXcodeApps,
  executable: findExecutable,
};

export function probeEnvironment(env, home) {
  const result = {
    PATH: env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: home,
    LANG: "C",
    LC_ALL: "C",
    NO_COLOR: "1",
  };
  if (env.TMPDIR) result.TMPDIR = env.TMPDIR;
  return result;
}

export function discoverDeveloperDirectories(fs, home) {
  const locations = [...new Set(["/Applications", path.join(home, "Applications")])];
  const candidates = [];
  const discovery = [];
  for (const location of locations) {
    const result = fs.applications(location);
    discovery.push({
      directory: location,
      status: result.ok ? "INSPECTED" : result.reason === "not_found" ? "MISSING" : "ERROR",
      reason: result.ok ? null : result.reason,
      limited: result.limited ?? false,
    });
    if (result.ok) {
      const apps = [...result.apps].sort((a, b) => {
        const priority = (app) => path.basename(app) === "Xcode.app" ? 0 : 1;
        return priority(a) - priority(b) || (a < b ? -1 : a > b ? 1 : 0);
      });
      candidates.push(...apps.map((app) => path.join(app, "Contents", "Developer")));
    }
  }
  return {
    candidates: candidates.slice(0, LIMITS.developerCandidates),
    discovery,
    limited: candidates.length > LIMITS.developerCandidates || discovery.some((item) => item.limited),
  };
}

function within(parent, child) {
  const relative = path.relative(parent, child);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative);
}

function versionProbe(run, command, args, env, pattern) {
  const result = run(command, args, env);
  if (!result.ok) return result;
  const match = result.stdout.trim().match(pattern);
  return match ? { ok: true, version: match[1] } : { ok: false, reason: "unrecognized_version" };
}

export function probeDeveloperDirectory(candidate, { run, fs, env }) {
  if (!path.isAbsolute(candidate) || /[\u0000-\u001f\u007f]/u.test(candidate)) {
    return { ok: false, directory: candidate, reason: "invalid_path" };
  }
  const directory = candidate.endsWith(".app") || candidate.endsWith(".app/")
    ? path.join(candidate, "Contents", "Developer")
    : path.normalize(candidate).replace(/\/$/u, "");
  if (!/\.app\/Contents\/Developer$/u.test(directory)) {
    return { ok: false, directory, reason: "not_full_xcode_app" };
  }
  const resolved = fs.directory(directory);
  if (!resolved.ok) return { ok: false, directory, reason: resolved.reason };
  const scopedEnv = { ...env, DEVELOPER_DIR: resolved.path };
  const xcode = versionProbe(run, "/usr/bin/xcodebuild", ["-version"], scopedEnv,
    /^Xcode (\d+(?:\.\d+){1,2})(?:\n|$)/u);
  if (!xcode.ok) return { ok: false, directory: resolved.path, reason: `xcodebuild_${xcode.reason}` };
  const sdk = run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], scopedEnv);
  if (!sdk.ok) return { ok: false, directory: resolved.path, reason: `sdk_${sdk.reason}` };
  const sdkPath = sdk.stdout.trim();
  if (!path.isAbsolute(sdkPath) || /[\u0000-\u001f\u007f]/u.test(sdkPath)) {
    return { ok: false, directory: resolved.path, reason: "sdk_invalid_path" };
  }
  const resolvedSDK = fs.directory(sdkPath);
  if (!resolvedSDK.ok) return { ok: false, directory: resolved.path, reason: `sdk_${resolvedSDK.reason}` };
  if (!within(resolved.path, resolvedSDK.path)) {
    return { ok: false, directory: resolved.path, reason: "sdk_outside_selected_xcode" };
  }
  const sdkVersion = versionProbe(run, "/usr/bin/xcrun",
    ["--sdk", "macosx", "--show-sdk-version"], scopedEnv, /^(\d+(?:\.\d+){1,2})$/u);
  const swift = versionProbe(run, "/usr/bin/xcrun",
    ["--sdk", "macosx", "swift", "--version"], scopedEnv,
    /^(?:Apple )?Swift version (\d+(?:\.\d+){1,2})(?:\s|$)/u);
  const reason = !sdkVersion.ok ? `sdk_${sdkVersion.reason}` :
    Number(sdkVersion.version.split(".")[0]) < 26 ? "sdk_requires_tahoe" :
      !swift.ok ? `swift_${swift.reason}` :
        Number(swift.version.split(".")[0]) < 6 ? "swift_requires_6" : null;
  return {
    ok: reason === null,
    reason,
    directory: resolved.path,
    xcodeVersion: xcode.version,
    sdkPath: resolvedSDK.path,
    sdkVersion,
    swift,
  };
}

function check(id, group, required, status, message, data = {}) {
  return { id, group, required, status, message, data };
}

function unavailableVersion(id, group, required, result, extra = "") {
  return check(id, group, required, required ? "BLOCKED" : "OPTIONAL_UNAVAILABLE",
    `Version probe unavailable: ${result.reason}.${extra}`, { reason: result.reason });
}

export function collectReport(options, {
  run = runCommand,
  fs = realFilesystem,
  env = process.env,
  platform = process.platform,
  arch = process.arch,
  nodeVersion = process.version,
  nodeExecutable = process.execPath,
  home = homedir(),
} = {}) {
  const checks = [];
  const probeEnv = probeEnvironment(env, home);
  const numericVersion = /^(\d+(?:\.\d+){1,2})$/u;
  let globalDeveloperDirectory = null;
  let selectionProbe = "not_macos";
  let developerDirectory = null;
  const source = options.developerDir !== null ? "argument" :
    Object.hasOwn(env, "DEVELOPER_DIR") ? "environment" : "discovery";
  const attempts = [];
  let discovery = [];
  let discoveryLimited = false;

  if (platform === "darwin") {
    const os = versionProbe(run, "/usr/bin/sw_vers", ["-productVersion"], probeEnv, numericVersion);
    const build = versionProbe(run, "/usr/bin/sw_vers", ["-buildVersion"], probeEnv,
      /^([0-9]{2,3}[A-Z][0-9]+[a-z]?)$/u);
    const eligible = os.ok && os.version.split(".")[0] === "26" && build.ok;
    checks.push(check("macos", "host", true, eligible ? "PASS" : "BLOCKED",
      !os.ok || !build.ok
        ? `Cannot verify macOS version/build: ${!os.ok ? os.reason : build.reason}.`
        : eligible ? `macOS ${os.version} (${build.version}) is Tahoe-eligible, not qualified.`
          : `macOS ${os.version} (${build.version}) is outside the macOS Tahoe 26.x target.`,
      { platform, version: os.ok ? os.version : null, build: build.ok ? build.version : null,
        qualificationBaseline: "26.6.2" }));
    const silicon = run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], probeEnv);
    const hostValue = silicon.ok ? silicon.stdout.trim() : null;
    checks.push(check("apple-silicon", "host", true, hostValue === "1" ? "PASS" : "BLOCKED",
      hostValue === "1" ? `Apple Silicon detected; Node process architecture: ${arch}.`
        : hostValue === "0" ? "Intel hardware is outside the Apple Silicon target."
          : `Cannot verify Apple Silicon: ${silicon.ok ? "unrecognized_architecture" : silicon.reason}.`,
      { appleSilicon: hostValue === "1" ? true : hostValue === "0" ? false : null,
        nodeArchitecture: arch }));
    const selected = run("/usr/bin/xcode-select", ["-p"], probeEnv);
    const selectedPath = selected.ok ? selected.stdout.trim() : "";
    if (path.isAbsolute(selectedPath) && !/[\u0000-\u001f\u007f]/u.test(selectedPath)) {
      globalDeveloperDirectory = selectedPath;
      selectionProbe = "observed";
    } else {
      selectionProbe = selected.ok ? "invalid_path" : selected.reason;
    }

    let candidates;
    if (source !== "discovery") {
      candidates = [options.developerDir ?? env.DEVELOPER_DIR];
    } else {
      const found = discoverDeveloperDirectories(fs, home);
      candidates = found.candidates;
      discovery = found.discovery;
      discoveryLimited = found.limited;
    }
    for (const candidate of candidates) {
      const attempt = probeDeveloperDirectory(candidate, { run, fs, env: probeEnv });
      attempts.push(attempt);
      if (attempt.ok) break;
    }
  } else {
    checks.push(check("macos", "host", true, "BLOCKED",
      `macOS Tahoe 26.x is required; detected platform: ${platform}.`, { platform }));
    checks.push(check("apple-silicon", "host", true, "BLOCKED",
      "Apple Silicon Mac eligibility cannot be established on this platform.", { nodeArchitecture: arch }));
  }

  const chosen = attempts.find((attempt) => attempt.ok) ?? attempts.find((attempt) => attempt.sdkPath);
  if (chosen) {
    developerDirectory = chosen.directory;
    checks.push(check("xcode", "native-build", true, "PASS",
      `Full Xcode ${chosen.xcodeVersion} passed the scoped Xcode and SDK path probes.`,
      { version: chosen.xcodeVersion, developerDirectory }));
    const { sdkVersion, swift } = chosen;
    checks.push(!sdkVersion.ok
      ? unavailableVersion("macos-sdk", "native-build", true, sdkVersion)
      : check("macos-sdk", "native-build", true,
        Number(sdkVersion.version.split(".")[0]) >= 26 ? "PASS" : "BLOCKED",
        `macOS SDK ${sdkVersion.version}; SDK >= 26 is required for the Tahoe target.`,
        { version: sdkVersion.version, path: chosen.sdkPath }));
    checks.push(!swift.ok
      ? unavailableVersion("swift", "native-build", true, swift)
      : check("swift", "native-build", true,
        Number(swift.version.split(".")[0]) >= 6 ? "PASS" : "BLOCKED",
        `Swift ${swift.version} from the chosen Xcode; Swift >= 6 is required, not a shipping pin.`,
        { version: swift.version }));
  } else {
    checks.push(check("xcode", "native-build", true, "BLOCKED",
      "No usable full Xcode app. Install full Xcode separately, finish its setup, then rerun " +
      "with --developer-dir /Applications/Xcode.app. Command Line Tools are insufficient.",
      { source, discoveryLimited }));
    for (const [id, label] of [["macos-sdk", "macOS SDK"], ["swift", "Xcode Swift"]]) {
      checks.push(check(id, "native-build", true, "BLOCKED",
        `${label} cannot be verified without a usable full Xcode selection.`, { reason: "xcode_unavailable" }));
    }
  }

  const node = nodeVersion.match(/^v(\d+\.\d+\.\d+)$/u);
  checks.push(check("node", "tooling", true, node && Number(node[1].split(".")[0]) >= 18 ? "PASS" : "BLOCKED",
    node ? `Node.js ${node[1]} runs this checker; Node >= 18 is required for the test tooling.`
      : "Cannot identify the running Node.js version.",
    { version: node?.[1] ?? null, executable: nodeExecutable }));

  const tools = [
    { id: "xcodegen", name: "xcodegen", group: "native-build", required: options.phase === "development",
      pattern: /^Version: (\d+\.\d+\.\d+)$/u,
      note: options.phase === "xcode" ? " Not required during --phase xcode." : " Required for full development." },
    { id: "copilot", name: "copilot", group: "optional-live-cli", required: false,
      pattern: /^(?:(?:GitHub )?Copilot(?: CLI)?(?: version)?\s+)?(\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)\.?(?:\r?\n|$)/iu,
      note: " Optional for live CLI integration; login and extensions are not checked." },
    { id: "gh", name: "gh", group: "optional-updates", required: false,
      pattern: /^gh version (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\s|$)/u,
      note: " Optional for private update retrieval; authentication is not checked." },
  ];
  for (const tool of tools) {
    const executable = fs.executable(tool.name, probeEnv.PATH);
    const version = executable.ok
      ? versionProbe(run, executable.path, ["--version"], probeEnv, tool.pattern) : executable;
    const item = version.ok
      ? check(tool.id, tool.group, tool.required, "PASS", `${tool.name} ${version.version}.${tool.note}`,
        { version: version.version, executable: executable.path })
      : unavailableVersion(tool.id, tool.group, tool.required, version, tool.note);
    if (executable.ok && !version.ok) item.data.executable = executable.path;
    if (executable.limited) item.data.pathLookupLimited = true;
    if (tool.id === "xcodegen" && !tool.required && !version.ok) item.status = "DEFERRED";
    checks.push(item);
  }

  const blocked = checks.some((item) => item.required && item.status !== "PASS");
  return {
    schemaVersion: 1,
    phase: options.phase,
    status: blocked ? "BLOCKED" : "READY",
    exitCode: blocked ? 1 : 0,
    developerDirectory,
    developerDirectorySource: source,
    globalDeveloperDirectory,
    globalSelectionProbe: selectionProbe,
    developerDirectoryAttempts: attempts,
    discovery,
    discoveryLimited,
    checks,
    scope: SCOPE,
  };
}

function safeLine(value) {
  return String(value).replace(/[\u0000-\u001f\u007f-\u009f]/gu,
    (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

export function formatReport(report, json = false) {
  if (json) return `${JSON.stringify(report, null, 2)}\n`;
  const lines = [
    `${report.status}: developer prerequisites (phase: ${report.phase})`,
    `Chosen developer directory: ${report.developerDirectory ?? "none"} (${report.developerDirectorySource})`,
    `Global xcode-select directory (unchanged): ${report.globalDeveloperDirectory ?? "unavailable"} (${report.globalSelectionProbe})`,
    ...report.checks.map((item) => `[${item.status}] ${item.id}: ${item.message}`),
    ...report.developerDirectoryAttempts.filter((item) => !item.ok)
      .map((item) => `Developer directory probe failed: ${item.directory} (${item.reason})`),
    ...report.discovery.filter((item) => item.status === "ERROR")
      .map((item) => `Discovery error: ${item.directory} (${item.reason})`),
    ...(report.discoveryLimited ? ["Discovery limit reached; use --developer-dir for an explicit installation."] : []),
    report.scope,
  ];
  return `${lines.map(safeLine).join("\n")}\n`;
}

export function main(argv = process.argv.slice(2), dependencies = {}, io = {
  stdout: process.stdout,
  stderr: process.stderr,
}) {
  let options;
  try {
    options = parseArguments(argv);
  } catch (error) {
    if (!(error instanceof ArgumentError)) throw error;
    if (argv.includes("--json")) {
      io.stdout.write(`${JSON.stringify({
        schemaVersion: 1, status: "ERROR", exitCode: 2, error: error.message, usage: "scripts/doctor --help",
      }, null, 2)}\n`);
    } else {
      io.stderr.write(`ERROR: ${error.message}\n`);
    }
    return 2;
  }
  if (options.help) {
    io.stdout.write(options.json
      ? `${JSON.stringify({ schemaVersion: 1, status: "HELP", exitCode: 0, usage: HELP }, null, 2)}\n`
      : HELP);
    return 0;
  }
  const report = collectReport(options, dependencies);
  io.stdout.write(formatReport(report, options.json));
  return report.exitCode;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = main();
}
