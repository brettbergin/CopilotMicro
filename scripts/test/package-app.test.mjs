import assert from "node:assert/strict";
import * as fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  IDENTITY, LIMITS, PackagingError, main, packageApplication, parseArguments,
  runCommand, validateConfiguration, validateMetadata, validateOutputDirectory, validateSmokeReport,
} from "../package-app.mjs";

const repository = fileURLToPath(new URL("../..", import.meta.url));
const metadata = {
  CFBundleIdentifier: IDENTITY.bundleIdentifier,
  CFBundleExecutable: IDENTITY.executable,
  CFBundlePackageType: "APPL",
  CFBundleShortVersionString: IDENTITY.version,
  LSMinimumSystemVersion: "26.0",
  LSUIElement: true,
};
const configuration = { schemaVersion: 1, mode: "emulator", liveIntegrationsEnabled: false };
const report = (app) => ({
  schemaVersion: 1, outcome: "passed", bundleIdentifier: IDENTITY.bundleIdentifier,
  bundlePath: app, resourcePath: path.join(app, "Contents/Resources/foundation.json"),
  configuration, processID: 1234, mainThread: true, activationPolicy: "prohibited",
  windowCreated: true, hostingViewCreated: true, windowVisible: false, windowKey: false,
  windowMain: false, statusItemInstalled: false, menuActionsValidated: true,
  keepsRunningAfterManagerClose: true, fittingWidth: 600, fittingHeight: 380,
});

function fixture(t) {
  const build = path.join(repository, "build");
  fs.mkdirSync(build, { recursive: true });
  const root = fs.mkdtempSync(path.join(build, "package-test-"));
  t.after(() => {
    assert.equal(path.dirname(root), build);
    fs.rmSync(root, { recursive: true });
  });
  fs.mkdirSync(path.join(root, "App/Resources"), { recursive: true });
  fs.copyFileSync(path.join(repository, "App/Info.plist"), path.join(root, "App/Info.plist"));
  fs.writeFileSync(path.join(root, "App/Resources/foundation.json"), JSON.stringify(configuration));
  const developer = path.join(root, "developer tools ; not a shell");
  fs.mkdirSync(developer);
  const binaryDirectory = path.join(root, ".build/arm64-apple-macosx/release");
  const calls = [];
  const deps = {
    root, platform: "darwin",
    environment: {
      DEVELOPER_DIR: developer, GH_TOKEN: "must-not-pass", COPILOT_SDK_TOKEN: "must-not-pass",
      DYLD_LIBRARY_PATH: "/not-used", PATH: "/not-used", SDKROOT: "/not-used",
    },
    run(command, args, env, options) {
      calls.push({ command, args, env, options });
      if (command === "/usr/bin/plutil") {
        return args.includes("-convert") ? JSON.stringify(metadata) : "OK";
      }
      if (command === "/usr/bin/xcrun") {
        if (args[0] === "swift") {
          if (args.includes("--show-bin-path")) return `${binaryDirectory}\n`;
          fs.mkdirSync(binaryDirectory, { recursive: true });
          fs.writeFileSync(path.join(binaryDirectory, IDENTITY.executable), "fake arm64 binary", { mode: 0o755 });
          return "Build complete";
        }
        if (args[0] === "lipo") return "arm64\n";
        if (args[0] === "strip") return "";
      }
      if (command === "/usr/bin/codesign") {
        const app = args.at(-1);
        assert.deepEqual(JSON.parse(fs.readFileSync(path.join(app, "Contents/Resources/foundation.json"))), configuration);
        return "";
      }
      if (path.basename(command) === IDENTITY.executable) {
        assert.deepEqual(args, ["--smoke-test"]);
        return JSON.stringify(report(path.dirname(path.dirname(path.dirname(command)))));
      }
      assert.fail(`Unexpected command: ${command}`);
    },
  };
  return { root, deps, calls, developer };
}

test("defaults and parsing are explicit; help and invalid usage perform no I/O", () => {
  assert.deepEqual(parseArguments([]), {
    configuration: "release", outputDir: "build/package", developerDir: null, smokeTest: false, help: false,
  });
  for (const args of [
    ["--unknown"], ["--smoke-test", "--smoke-test"], ["--configuration", "fast"],
    ["--output-dir"], ["--developer-dir", "relative"], ["--output-dir", "build/\nunsafe"],
  ]) {
    let stderr = "";
    assert.equal(main(args, {}, { stdout: { write: assert.fail }, stderr: { write: (value) => { stderr += value; } } }), 2);
    assert.equal(JSON.parse(stderr).errorCode, "usage");
  }
  let help = "";
  assert.equal(main(["--help"], { root: "/does-not-exist", run: assert.fail }, {
    stdout: { write: (value) => { help += value; } }, stderr: { write: assert.fail },
  }), 0);
  assert.match(help, /never overwritten or deleted/u);
});

test("output is a strict build descendant, never a checkout, tooling, external or existing bundle", (t) => {
  const { root } = fixture(t);
  for (const requested of ["", ".", "..", "build", "build/tooling", "build/tooling/nested", "/tmp", "build/../../outside"]) {
    assert.throws(() => validateOutputDirectory(root, requested), PackagingError);
  }
  assert.equal(validateOutputDirectory(root, "build/artifacts with spaces"), path.join(root, "build/artifacts with spaces"));
  fs.mkdirSync(path.join(root, "build/package/CopilotMicro.app"), { recursive: true });
  fs.writeFileSync(path.join(root, "build/package/CopilotMicro.app/user-file"), "preserve");
  assert.throws(() => validateOutputDirectory(root, "build/package"), { code: "output_exists" });
  assert.equal(fs.readFileSync(path.join(root, "build/package/CopilotMicro.app/user-file"), "utf8"), "preserve");
});

test("symlinked ancestors and dangling existing app links are rejected", (t) => {
  const { root } = fixture(t);
  fs.mkdirSync(path.join(root, "elsewhere"));
  fs.symlinkSync(path.join(root, "elsewhere"), path.join(root, "build"));
  assert.throws(() => validateOutputDirectory(root, "build/package"), { code: "unsafe_path" });
  fs.unlinkSync(path.join(root, "build"));
  fs.mkdirSync(path.join(root, "build/package"), { recursive: true });
  fs.symlinkSync(path.join(root, "missing"), path.join(root, "build/package/CopilotMicro.app"));
  assert.throws(() => validateOutputDirectory(root, "build/package"), { code: "output_exists" });
});

test("only expected metadata and emulator-only configuration are accepted", () => {
  validateMetadata(metadata);
  validateConfiguration(configuration);
  for (const key of Object.keys(metadata)) {
    assert.throws(() => validateMetadata({ ...metadata, [key]: null }), { code: "invalid_metadata" });
  }
  for (const value of [null, {}, { ...configuration, mode: "live" },
    { ...configuration, liveIntegrationsEnabled: true }, { ...configuration, schemaVersion: 2 }]) {
    assert.throws(() => validateConfiguration(value), { code: "invalid_configuration" });
  }
});

test("commands are argument arrays with deadlines, output limits, no shell and ignored stdin", () => {
  const env = { DEVELOPER_DIR: "/developer tools ; literal" };
  assert.equal(runCommand("/usr/bin/xcrun", ["swift", "build"], env, { cwd: "/root", timeoutMs: LIMITS.buildMs },
    (command, args, options) => {
      assert.equal(command, "/usr/bin/xcrun");
      assert.deepEqual(args, ["swift", "build"]);
      assert.equal(options.shell, false);
      assert.equal(options.timeout, 180000);
      assert.equal(options.maxBuffer, 1024 * 1024);
      assert.equal(options.killSignal, "SIGKILL");
      assert.deepEqual(options.stdio, ["ignore", "pipe", "pipe"]);
      assert.equal(options.env, env);
      return { status: 0, stdout: "success" };
    }), "success");
  for (const [result, code] of [
    [{ error: { code: "ETIMEDOUT" } }, "timed_out"],
    [{ error: { code: "ENOBUFS" } }, "output_limit"],
    [{ signal: "SIGKILL" }, "command_failed"],
    [{ status: 1, stderr: "failed\n" }, "command_failed"],
  ]) {
    assert.throws(() => runCommand("tool", [], {}, {}, () => result), { code });
  }
});

test("packaging builds arm64, seals resources and signs only the newly generated app", (t) => {
  const { root, deps, calls, developer } = fixture(t);
  const options = parseArguments(["--output-dir", "build/foundation app", "--smoke-test"]);
  const result = packageApplication(options, deps);
  const app = path.join(root, "build/foundation app/CopilotMicro.app");
  assert.equal(result.appPath, app);
  assert.equal(result.smoke.outcome, "passed");
  assert.equal(fs.readFileSync(path.join(app, "Contents/MacOS/CopilotMicro"), "utf8"), "fake arm64 binary");
  for (const call of calls) {
    assert.equal(call.env.DEVELOPER_DIR, developer);
    for (const name of ["GH_TOKEN", "COPILOT_SDK_TOKEN", "DYLD_LIBRARY_PATH", "SDKROOT"]) {
      assert.equal(call.env[name], undefined);
    }
    assert.equal(call.env.PATH, "/usr/bin:/bin:/usr/sbin:/sbin");
    assert.equal(call.options.cwd, root);
    assert.notEqual(path.basename(call.command), "copilot");
    assert.notEqual(path.basename(call.command), "xcode-select");
  }
  const build = calls.find((call) => call.args[0] === "swift" && !call.args.includes("--show-bin-path"));
  assert.equal(build.options.timeoutMs, LIMITS.buildMs);
  assert.equal(build.args[build.args.indexOf("--arch") + 1], "arm64");
  assert.equal(build.args[build.args.indexOf("--configuration") + 1], "release");
  assert.ok(build.args.includes("--disable-dependency-cache"));
  assert.deepEqual(calls.filter((call) => call.command === "/usr/bin/codesign").map((call) => call.args), [
    ["--force", "--sign", "-", "--timestamp=none", app],
    ["--verify", "--strict", "--verbose=2", app],
  ]);
  assert.equal(calls.at(-1).options.timeoutMs, LIMITS.smokeMs);
  const count = calls.length;
  assert.throws(() => packageApplication(options, deps), { code: "output_exists" });
  assert.equal(calls.length, count, "a repeat cannot build or sign another existing app");
});

test("default packaging does not launch any app, and explicit developer override wins", (t) => {
  const { deps, developer, calls } = fixture(t);
  const result = packageApplication(parseArguments(["--developer-dir", developer]), deps);
  assert.equal(result.smoke, null);
  assert.ok(calls.every((call) => path.basename(call.command) !== IDENTITY.executable));
  assert.ok(calls.every((call) => call.env.DEVELOPER_DIR === developer));
});

test("non-macOS hosts and invalid developer overrides fail without signing or fallback", (t) => {
  const { root, deps, calls } = fixture(t);
  assert.throws(() => packageApplication(parseArguments([]), { ...deps, platform: "linux" }), { code: "unsupported_host" });
  assert.throws(() => packageApplication(parseArguments(["--developer-dir", path.join(root, "missing")]), deps));
  assert.throws(() => packageApplication(parseArguments([]), {
    ...deps, environment: { DEVELOPER_DIR: "relative" },
  }), { code: "invalid_developer_directory" });
  assert.equal(calls.length, 0);
});

test("resource symlinks cannot smuggle a source-path fallback into the package", (t) => {
  const { root, deps, calls } = fixture(t);
  const resource = path.join(root, "App/Resources/foundation.json");
  fs.renameSync(resource, path.join(root, "other-resource.json"));
  fs.symlinkSync(path.join(root, "other-resource.json"), resource);
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "invalid_input" });
  assert.equal(calls.length, 0);
});

test("invalid inputs, symlinked caches and escaped SwiftPM output never reach signing", (t) => {
  const { root, deps, calls } = fixture(t);
  fs.symlinkSync(path.join(root, "App"), path.join(root, ".build"));
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "unsafe_path" });
  assert.equal(calls.length, 0);
  fs.unlinkSync(path.join(root, ".build"));
  fs.writeFileSync(path.join(root, "App/Resources/foundation.json"), JSON.stringify({ ...configuration, mode: "live" }));
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "invalid_configuration" });
  assert.equal(calls.length, 0);
  fs.writeFileSync(path.join(root, "App/Resources/foundation.json"), JSON.stringify(configuration));
  const original = deps.run;
  deps.run = (command, args, ...rest) => args.includes("--show-bin-path")
    ? root : original(command, args, ...rest);
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "unsafe_binary" });
  assert.ok(calls.every((call) => call.command !== "/usr/bin/codesign"));
});

test("wrong architecture fails before app assembly or signing", (t) => {
  const { root, deps, calls } = fixture(t);
  const original = deps.run;
  deps.run = (command, args, ...rest) => args[0] === "lipo"
    ? "x86_64" : original(command, args, ...rest);
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "invalid_architecture" });
  assert.ok(!fs.existsSync(path.join(root, "build/package/CopilotMicro.app")));
  assert.ok(calls.every((call) => call.command !== "/usr/bin/codesign"));
});

test("signing failures are failures, retain inspectable output and never delete or overwrite it", (t) => {
  const { root, deps } = fixture(t);
  const original = deps.run;
  deps.run = (command, ...rest) => {
    if (command === "/usr/bin/codesign") throw new PackagingError("command_failed", "signing failed");
    return original(command, ...rest);
  };
  let stderr = "";
  const code = main([], deps, { stdout: { write: assert.fail }, stderr: { write: (value) => { stderr += value; } } });
  assert.equal(code, 1);
  assert.equal(JSON.parse(stderr).outcome, "failed");
  assert.ok(fs.existsSync(path.join(root, "build/package/CopilotMicro.app/Contents/Resources/foundation.json")));
  assert.throws(() => packageApplication(parseArguments([]), deps), { code: "output_exists" });
});

test("smoke invariants require real hidden UI, emulator configuration and the relocated resource path", () => {
  const app = "/relocated/CopilotMicro.app";
  validateSmokeReport(report(app), app);
  for (const change of [
    { outcome: "failed" }, { bundlePath: "/old/CopilotMicro.app" },
    { resourcePath: "/build/foundation.json" }, { windowVisible: true }, { windowKey: true },
    { windowMain: true }, { statusItemInstalled: true }, { activationPolicy: "regular" },
    { windowCreated: false }, { hostingViewCreated: false }, { menuActionsValidated: false },
    { keepsRunningAfterManagerClose: false }, { mainThread: false },
    { fittingWidth: 599 }, { fittingHeight: 379 }, { fittingWidth: Number.NaN }, { processID: 0 },
    { configuration: { ...configuration, liveIntegrationsEnabled: true } },
  ]) {
    assert.throws(() => validateSmokeReport({ ...report(app), ...change }, app), PackagingError);
  }
});
