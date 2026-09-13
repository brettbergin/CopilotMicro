import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const IDENTITY = Object.freeze({
  bundleIdentifier: "com.github.copilot-micro",
  executable: "CopilotMicro",
  appName: "CopilotMicro.app",
  version: "0.1.0",
});
export const LIMITS = Object.freeze({
  buildMs: 180000,
  commandMs: 10000,
  smokeMs: 30000,
  outputBytes: 1024 * 1024,
  diagnosticBytes: 4096,
});
export const HELP = `Usage: node scripts/package-app.mjs [options]

Build and ad-hoc sign the Creator Micro 2 Copilot Micro app using SwiftPM.
No XcodeGen, asset compiler, external packages or CLI integration.

  --configuration debug|release  Default: release; arm64, macOS 26, Swift 6.
  --output-dir PATH              Default: build/package. Must be a strict
                                 descendant of this checkout's build directory,
                                 outside build/tooling. No symlink ancestors.
  --developer-dir PATH           Absolute developer tools directory. Defaults
                                 to DEVELOPER_DIR, then installed stock CLT.
                                 Applied only to child commands.
  --smoke-test                   Run hidden AppKit/SwiftUI/resource smoke and
                                 bounded production accessory lifecycle smoke.
  --help, -h                     Print this help without building.

Existing app bundles are never overwritten or deleted. Choose a new output
directory or explicitly move your old generated app before packaging again.
Builds have a 180-second deadline; smoke has a 30-second deadline. Other
commands have 10 seconds. Each command has a 1 MiB output limit, no shell,
and a credential-free environment. No app window is shown; accessory smoke
uses the production run loop briefly and exits.
Output is JSON. Exit codes: 0 = packaged/help, 1 = failure, 2 = invalid usage.
Ad-hoc signing does not establish notarization, Gatekeeper or live support.
`;

export class PackagingError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

function validPath(value) {
  return typeof value === "string" && value.length > 0 && !/[\u0000-\u001f\u007f]/u.test(value);
}

export function parseArguments(argv) {
  const options = { configuration: "release", outputDir: "build/package", developerDir: null, smokeTest: false, help: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index] === "-h" ? "--help" : argv[index];
    if (!["--configuration", "--output-dir", "--developer-dir", "--smoke-test", "--help"].includes(flag) || seen.has(flag)) {
      throw new PackagingError("usage", "Unknown or duplicate argument. Use --help.");
    }
    seen.add(flag);
    if (flag === "--help" || flag === "--smoke-test") {
      options[flag === "--help" ? "help" : "smokeTest"] = true;
      continue;
    }
    const value = argv[++index];
    if (!validPath(value) || value.startsWith("-")) {
      throw new PackagingError("usage", "Missing or invalid option value. Use --help.");
    }
    if (flag === "--configuration") {
      if (!["debug", "release"].includes(value)) throw new PackagingError("usage", "Expected debug or release.");
      options.configuration = value;
    } else if (flag === "--developer-dir") {
      if (!path.isAbsolute(value)) throw new PackagingError("usage", "Developer directory must be absolute.");
      options.developerDir = value;
    } else {
      options.outputDir = value;
    }
  }
  return options;
}

function within(parent, child) {
  const relative = path.relative(parent, child);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function inspect(entry) {
  try {
    return fs.lstatSync(entry);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

export function assertDirectoryPath(root, directory) {
  if (!within(root, directory)) throw new PackagingError("unsafe_path", "Directory must stay inside this checkout.");
  let cursor = root;
  for (const part of path.relative(root, directory).split(path.sep)) {
    cursor = path.join(cursor, part);
    const stat = inspect(cursor);
    if (stat && (stat.isSymbolicLink() || !stat.isDirectory())) {
      throw new PackagingError("unsafe_path", "Output/cache paths must be directories without symlink ancestors.");
    }
  }
}

export function validateOutputDirectory(root, requested) {
  if (!validPath(requested)) throw new PackagingError("usage", "Invalid output directory.");
  const directory = path.resolve(root, requested);
  const build = path.join(root, "build");
  const tooling = path.join(build, "tooling");
  if (!within(build, directory) || directory === tooling || within(tooling, directory)) {
    throw new PackagingError("unsafe_path", "Output must be inside build, outside its reserved tooling directory.");
  }
  assertDirectoryPath(root, directory);
  if (inspect(path.join(directory, IDENTITY.appName))) {
    throw new PackagingError("output_exists", "App output already exists; it will not be overwritten or deleted.");
  }
  return directory;
}

export function runCommand(command, args, env, { cwd, timeoutMs = LIMITS.commandMs } = {}, spawn = spawnSync) {
  const result = spawn(command, args, {
    cwd, env, shell: false, encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: timeoutMs, maxBuffer: LIMITS.outputBytes, killSignal: "SIGKILL",
  });
  if (result.error || result.signal || result.status !== 0) {
    const code = result.error?.code === "ETIMEDOUT" ? "timed_out"
      : result.error?.code === "ENOBUFS" ? "output_limit" : "command_failed";
    const stdout = sanitizeDiagnostic(result.stdout);
    const stderr = sanitizeDiagnostic(result.stderr);
    const appFailure = parseStructuredFailure(result.stdout);
    const details = {};
    if (stdout) details.commandStdout = stdout;
    if (stderr) details.commandStderr = stderr;
    if (appFailure) {
      details.appErrorCode = appFailure.errorCode;
      if (appFailure.message) details.appMessage = appFailure.message;
    }
    const detail = appFailure
      ? `${appFailure.errorCode}${appFailure.message ? `: ${appFailure.message}` : ""}`
      : stderr || stdout;
    throw new PackagingError(
      code,
      `${path.basename(command)} failed${detail ? `: ${detail}` : "."}`,
      details,
    );
  }
  return result.stdout ?? "";
}

function sanitizeDiagnostic(value) {
  const bytes = Buffer.from(String(value ?? ""), "utf8").subarray(0, LIMITS.diagnosticBytes);
  return bytes.toString("utf8").replace(/[\u0000-\u001f\u007f]/gu, " ").trim();
}

function parseStructuredFailure(value) {
  try {
    const parsed = JSON.parse(String(value ?? "").trim());
    if (parsed?.outcome !== "failed" || typeof parsed.errorCode !== "string") return null;
    const errorCode = sanitizeDiagnostic(parsed.errorCode);
    const message = typeof parsed.message === "string" ? sanitizeDiagnostic(parsed.message) : "";
    return errorCode ? { errorCode, message } : null;
  } catch {
    return null;
  }
}

export function validateMetadata(metadata) {
  const expected = {
    CFBundleIdentifier: IDENTITY.bundleIdentifier,
    CFBundleExecutable: IDENTITY.executable,
    CFBundlePackageType: "APPL",
    CFBundleShortVersionString: IDENTITY.version,
    LSMinimumSystemVersion: "26.0",
    LSUIElement: true,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (metadata?.[key] !== value) throw new PackagingError("invalid_metadata", `Unexpected ${key} in app metadata.`);
  }
}

export function validateConfiguration(configuration) {
  if (configuration?.schemaVersion !== 1 || configuration.mode !== "device"
      || configuration.deviceIntegrationEnabled !== true) {
    throw new PackagingError(
      "invalid_configuration",
      "Only schema 1 Creator Micro device configuration with device integration enabled is allowed.",
    );
  }
}

export function validateSmokeReport(report, app, mode = "hidden", canonicalize = path.normalize) {
  if (!["hidden", "accessory"].includes(mode)) {
    throw new PackagingError("smoke_failed", "Unknown smoke mode.");
  }
  const accessory = mode === "accessory";
  const expected = {
    schemaVersion: 1, outcome: "passed",
    smokeMode: mode,
    bundleIdentifier: IDENTITY.bundleIdentifier,
    mainThread: true, activationPolicy: accessory ? "accessory" : "prohibited",
    windowCreated: true, hostingViewCreated: true,
    windowVisible: false, windowKey: false, windowMain: false,
    applicationDelegateInstalled: accessory,
    applicationDidFinishLaunching: accessory,
    mainMenuInstalled: accessory,
    mainMenuActionsValidated: true,
    statusItemInstalled: accessory,
    statusItemMenuInstalled: accessory,
    menuActionsValidated: true,
    keepsRunningAfterManagerClose: true,
    managerAreasValidated: true,
    directDeviceUIValidated: true,
    deviceServiceSuppressedForSmoke: true,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (report?.[key] !== value) throw new PackagingError("smoke_failed", `Smoke invariant failed: ${key}.`);
  }
  const expectedResource = path.join(app, "Contents", "Resources", "foundation.json");
  if (typeof report.bundlePath !== "string" || canonicalize(report.bundlePath) !== canonicalize(app)) {
    throw new PackagingError("smoke_failed", "Smoke invariant failed: bundlePath.");
  }
  if (typeof report.resourcePath !== "string"
      || canonicalize(report.resourcePath) !== canonicalize(expectedResource)) {
    throw new PackagingError("smoke_failed", "Smoke invariant failed: resourcePath.");
  }
  validateConfiguration(report.configuration);
  if (!Number.isFinite(report.fittingWidth) || !Number.isFinite(report.fittingHeight)
      || report.fittingWidth < 600 || report.fittingHeight < 380
      || !Number.isInteger(report.processID) || report.processID <= 0) {
    throw new PackagingError("smoke_failed", "Invalid layout or process identity.");
  }
}

function readInput(filename) {
  const stat = inspect(filename);
  if (!stat?.isFile() || stat.isSymbolicLink()) {
    throw new PackagingError("invalid_input", "Packaging inputs must be regular, non-symlink files.");
  }
  return fs.readFileSync(filename);
}

export function packageApplication(options, {
  root = fileURLToPath(new URL("..", import.meta.url)),
  environment = process.env, platform = process.platform, run = runCommand,
} = {}) {
  if (platform !== "darwin") throw new PackagingError("unsupported_host", "Native packaging requires macOS.");
  root = fs.realpathSync(root);
  const output = validateOutputDirectory(root, options.outputDir);
  const developerDir = options.developerDir ?? environment.DEVELOPER_DIR ?? "/Library/Developer/CommandLineTools";
  if (!validPath(developerDir) || !path.isAbsolute(developerDir) || !fs.statSync(developerDir).isDirectory()) {
    throw new PackagingError("invalid_developer_directory", "Developer directory must be an existing absolute directory.");
  }
  const tools = path.join(root, "build", "tooling");
  const scratch = path.join(root, ".build");
  const directories = [
    scratch,
    output,
    ...["home", "tmp", "clang", "modules", "cache", "config", "security"]
      .map((part) => path.join(tools, part)),
  ];
  for (const directory of directories) assertDirectoryPath(root, directory);
  const info = path.join(root, "App", "Info.plist");
  const resource = path.join(root, "App", "Resources", "foundation.json");
  const infoData = readInput(info);
  const resourceData = readInput(resource);
  validateConfiguration(JSON.parse(resourceData.toString("utf8")));
  for (const directory of directories) fs.mkdirSync(directory, { recursive: true });

  const env = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL: "C",
    HOME: path.join(tools, "home"), TMPDIR: `${path.join(tools, "tmp")}${path.sep}`,
    DEVELOPER_DIR: developerDir,
    CLANG_MODULE_CACHE_PATH: path.join(tools, "clang"),
    SWIFTPM_MODULECACHE_OVERRIDE: path.join(tools, "modules"),
    GIT_TERMINAL_PROMPT: "0",
    GIT_CONFIG_COUNT: "2",
    GIT_CONFIG_KEY_0: "credential.interactive",
    GIT_CONFIG_VALUE_0: "never",
    GIT_CONFIG_KEY_1: `includeIf.gitdir:${root}/.path`,
    GIT_CONFIG_VALUE_1: path.join(root, "scripts", "git-swiftpm.config"),
  };
  const invoke = (command, args, timeoutMs = LIMITS.commandMs) => run(command, args, env, { cwd: root, timeoutMs });
  validateMetadata(JSON.parse(invoke("/usr/bin/plutil", ["-convert", "json", "-o", "-", info])));
  const buildArgs = [
    "swift", "build", "--configuration", options.configuration, "--arch", "arm64", "--jobs", "2",
    "--scratch-path", scratch, "--cache-path", path.join(tools, "cache"),
    "--config-path", path.join(tools, "config"),
    "--security-path", path.join(tools, "security"),
    "--disable-dependency-cache", "--disable-netrc", "--disable-keychain",
  ];
  invoke("/usr/bin/xcrun", buildArgs, LIMITS.buildMs);
  const binDirectory = fs.realpathSync(invoke("/usr/bin/xcrun", [...buildArgs, "--show-bin-path"]).trim());
  if (!within(scratch, binDirectory)) throw new PackagingError("unsafe_binary", "SwiftPM binary must be inside its local scratch directory.");
  const binary = path.join(binDirectory, IDENTITY.executable);
  readInput(binary);
  if (invoke("/usr/bin/xcrun", ["lipo", "-archs", binary]).trim() !== "arm64") {
    throw new PackagingError("invalid_architecture", "Expected an arm64 executable.");
  }

  // The destination is reserved exclusively; no prior app can be signed or replaced.
  assertDirectoryPath(root, output);
  const app = path.join(output, IDENTITY.appName);
  fs.mkdirSync(app);
  const contents = path.join(app, "Contents");
  fs.mkdirSync(path.join(contents, "MacOS"), { recursive: true });
  fs.mkdirSync(path.join(contents, "Resources"));
  const executable = path.join(contents, "MacOS", IDENTITY.executable);
  fs.copyFileSync(binary, executable, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(executable, 0o755);
  fs.writeFileSync(path.join(contents, "Info.plist"), infoData, { flag: "wx", mode: 0o644 });
  fs.writeFileSync(path.join(contents, "Resources", "foundation.json"), resourceData, { flag: "wx", mode: 0o644 });
  invoke("/usr/bin/xcrun", ["strip", "-S", executable]);
  invoke("/usr/bin/plutil", ["-lint", path.join(contents, "Info.plist")]);
  invoke("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app]);
  invoke("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", app]);
  let smoke = null;
  if (options.smokeTest) {
    smoke = {};
    for (const [mode, argument] of [
      ["hidden", "--smoke-test"],
      ["accessory", "--smoke-test=accessory"],
    ]) {
      const report = JSON.parse(invoke(executable, [argument], LIMITS.smokeMs));
      validateSmokeReport(report, app, mode, fs.realpathSync);
      smoke[mode] = report;
    }
  }
  return {
    outcome: "packaged", appPath: app, bundleIdentifier: IDENTITY.bundleIdentifier,
    configuration: options.configuration, architecture: "arm64", minimumMacOS: "26.0",
    developerDirectory: developerDir, signing: "ad-hoc", smoke,
  };
}

export function main(argv, deps = {}, io = process) {
  try {
    const options = parseArguments(argv);
    if (options.help) {
      io.stdout.write(HELP);
      return 0;
    }
    io.stdout.write(`${JSON.stringify(packageApplication(options, deps), null, 2)}\n`);
    return 0;
  } catch (error) {
    io.stderr.write(`${JSON.stringify({
      outcome: "failed", errorCode: error.code ?? "packaging_failed", message: error.message,
      ...(error.details ?? {}),
    })}\n`);
    return error.code === "usage" ? 2 : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
