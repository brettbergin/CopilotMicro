import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import {
  HELP,
  LIMITS,
  SCOPE,
  collectReport,
  discoverDeveloperDirectories,
  findExecutable,
  formatReport,
  inspectDirectory,
  listXcodeApps,
  main,
  parseArguments,
  probeDeveloperDirectory,
  probeEnvironment,
  runCommand,
} from "../doctor.mjs";

const HOME = "/Users/developer";
const XCODE = "/Applications/Xcode.app/Contents/Developer";
const ALTERNATE = `${HOME}/Applications/Xcode-beta.app/Contents/Developer`;
const CLT = "/Library/Developer/CommandLineTools";
const sdkPath = (directory) => `${directory}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk`;
const ok = (stdout) => ({ ok: true, stdout });
const failed = (reason = "nonzero_exit") => ({ ok: false, reason });
const check = (report, id) => report.checks.find((item) => item.id === id);

function fixture({
  installations = [XCODE],
  tools = { xcodegen: "Version: 2.44.1\n", copilot: "1.0.84-5\n", gh: "gh version 2.79.0 (2025-09-01)\n" },
  overrides = {},
  platform = "darwin",
  arch = "arm64",
  os = "26.6.2",
  appleSilicon = "1",
  sdk = "26.0",
  nodeVersion = "v25.8.2",
  env = {},
} = {}) {
  const calls = [];
  const discoveries = [];
  const directories = new Map(installations.flatMap((directory) => [
    [directory, directory], [sdkPath(directory), sdkPath(directory)],
  ]));
  const deps = {
    platform, arch, nodeVersion, nodeExecutable: "/tools/node", home: HOME,
    env: { PATH: "/tools:/usr/bin:/bin", GH_TOKEN: "secret-token-marker", ...env },
    fs: {
      directory(directory) {
        return directories.has(directory) ? { ok: true, path: directories.get(directory) } : failed("not_found");
      },
      applications(directory) {
        discoveries.push(directory);
        return { ok: true, limited: false, apps: installations
          .map((item) => path.dirname(path.dirname(item)))
          .filter((item) => path.dirname(item) === directory) };
      },
      executable(name) {
        return Object.hasOwn(tools, name) ? { ok: true, path: `/tools/${name}` } : failed("not_found");
      },
    },
    run(command, args, environment) {
      calls.push({ command, args, env: { ...environment } });
      const key = `${command} ${args.join(" ")}`;
      const scopedKey = `${environment.DEVELOPER_DIR ?? "global"}:${key}`;
      if (Object.hasOwn(overrides, scopedKey)) return overrides[scopedKey];
      if (Object.hasOwn(overrides, key)) return overrides[key];
      switch (key) {
        case "/usr/bin/sw_vers -productVersion": return ok(`${os}\n`);
        case "/usr/bin/sw_vers -buildVersion": return ok("25G83\n");
        case "/usr/sbin/sysctl -n hw.optional.arm64": return ok(`${appleSilicon}\n`);
        case "/usr/bin/xcode-select -p": return ok(`${CLT}\n`);
        case "/usr/bin/xcodebuild -version": return ok("Xcode 26.0\nBuild version 17A123\n");
        case "/usr/bin/xcrun --sdk macosx --show-sdk-path": return ok(`${sdkPath(environment.DEVELOPER_DIR)}\n`);
        case "/usr/bin/xcrun --sdk macosx --show-sdk-version": return ok(`${sdk}\n`);
        case "/usr/bin/xcrun --sdk macosx swift --version":
          return ok("Apple Swift version 6.3.3 (swiftlang-6.3.3)\nTarget: arm64-apple-macosx26.0\n");
        default: {
          const name = path.basename(command);
          assert.deepEqual(args, ["--version"], "only fixed version probes may invoke PATH tools");
          assert.ok(Object.hasOwn(tools, name), `unexpected command: ${key}`);
          return ok(tools[name]);
        }
      }
    },
  };
  return { deps, calls, discoveries, directories };
}

function report(fake, args = []) {
  return collectReport(parseArguments(args), fake.deps);
}

function invoke(args, deps) {
  let stdout = "";
  let stderr = "";
  const exitCode = main(args, deps, {
    stdout: { write: (value) => { stdout += value; } },
    stderr: { write: (value) => { stderr += value; } },
  });
  return { exitCode, stdout, stderr };
}

test("default development report records actual versions and limits its claims", () => {
  const result = report(fixture());
  assert.equal(result.status, "READY");
  assert.equal(result.exitCode, 0);
  assert.equal(result.phase, "development");
  assert.equal(result.developerDirectory, XCODE);
  assert.equal(result.globalDeveloperDirectory, CLT);
  assert.deepEqual(check(result, "macos").data, {
    platform: "darwin", version: "26.6.2", build: "25G83", qualificationBaseline: "26.6.2",
  });
  assert.equal(check(result, "swift").data.version, "6.3.3");
  assert.equal(check(result, "copilot").data.version, "1.0.84-5");
  assert.equal(check(result, "xcodegen").required, true);
  assert.equal(result.scope, SCOPE);
  assert.match(result.scope, /No app, CLI, terminal, emulator or hardware qualification/u);
});

test("missing Xcode blocks, even with working Node and optional CLI tools", () => {
  const result = report(fixture({ installations: [] }), ["--phase", "xcode"]);
  assert.equal(result.status, "BLOCKED");
  assert.equal(result.exitCode, 1);
  assert.equal(result.developerDirectory, null);
  for (const id of ["xcode", "macos-sdk", "swift"]) assert.equal(check(result, id).status, "BLOCKED");
  assert.equal(check(result, "node").status, "PASS");
  assert.match(check(result, "xcode").message, /Command Line Tools are insufficient/u);
});

test("CLT override is not full Xcode and does not trigger fallback discovery", () => {
  for (const explicit of [true, false]) {
    const fake = fixture({ env: explicit ? {} : { DEVELOPER_DIR: CLT } });
    const result = report(fake, explicit ? ["--developer-dir", CLT] : []);
    assert.equal(result.status, "BLOCKED");
    assert.equal(result.developerDirectoryAttempts[0].reason, "not_full_xcode_app");
    assert.deepEqual(fake.discoveries, []);
    assert.ok(!fake.calls.some((call) => call.command === "/usr/bin/xcodebuild"));
  }
});

test("a directory merely named Xcode.app is not evidence of a usable installation", () => {
  const fake = fixture({ overrides: { "/usr/bin/xcodebuild -version": failed() } });
  const result = report(fake, ["--developer-dir", "/Applications/Xcode.app"]);
  assert.equal(result.status, "BLOCKED");
  assert.equal(result.developerDirectoryAttempts[0].reason, "xcodebuild_nonzero_exit");
  assert.ok(!fake.calls.some((call) => call.command === "/usr/bin/xcrun"));
});

test("explicit full Xcode wins over environment and global CLT without global mutation", () => {
  for (const explicit of ["/Applications/Xcode.app", `${XCODE}/`]) {
    const fake = fixture({ env: { DEVELOPER_DIR: CLT } });
    const result = report(fake, ["--developer-dir", explicit]);
    assert.equal(result.status, "READY");
    assert.equal(result.developerDirectorySource, "argument");
    assert.equal(result.developerDirectory, XCODE);
    assert.equal(result.globalDeveloperDirectory, CLT);
    assert.deepEqual(fake.discoveries, []);
    for (const call of fake.calls) {
      if (["/usr/bin/xcrun", "/usr/bin/xcodebuild"].includes(call.command)) {
        assert.equal(call.env.DEVELOPER_DIR, XCODE);
      } else {
        assert.equal(Object.hasOwn(call.env, "DEVELOPER_DIR"), false);
      }
      assert.equal(Object.hasOwn(call.env, "GH_TOKEN"), false);
    }
    assert.deepEqual(fake.calls.filter((call) => call.command === "/usr/bin/xcode-select")
      .map((call) => call.args), [["-p"]]);
    assert.equal(fake.deps.env.DEVELOPER_DIR, CLT);
  }
});

test("valid environment override is used without discovery", () => {
  const fake = fixture({ installations: [ALTERNATE], env: { DEVELOPER_DIR: ALTERNATE } });
  const result = report(fake);
  assert.equal(result.status, "READY");
  assert.equal(result.developerDirectorySource, "environment");
  assert.equal(result.developerDirectory, ALTERNATE);
  assert.deepEqual(fake.discoveries, []);
});

test("invalid explicit and environment paths never silently fall back", () => {
  for (const [args, env] of [
    [["--developer-dir", "/Missing/Xcode.app"], {}],
    [[], { DEVELOPER_DIR: "/Missing/Xcode.app" }],
    [[], { DEVELOPER_DIR: "" }],
    [[], { DEVELOPER_DIR: "Xcode.app" }],
  ]) {
    const fake = fixture({ env });
    const result = report(fake, args);
    assert.equal(result.status, "BLOCKED");
    assert.equal(result.developerDirectory, null);
    assert.equal(result.developerDirectoryAttempts.length, 1);
    assert.deepEqual(fake.discoveries, []);
  }
});

test("discovery tries an alternate full Xcode in the user's Applications directory", () => {
  const fake = fixture({
    installations: [XCODE, ALTERNATE],
    overrides: { [`${XCODE}:/usr/bin/xcodebuild -version`]: failed("timed_out") },
  });
  const result = report(fake);
  assert.equal(result.status, "READY");
  assert.equal(result.developerDirectory, ALTERNATE);
  assert.equal(result.developerDirectorySource, "discovery");
  assert.deepEqual(result.developerDirectoryAttempts.map((item) => item.ok), [false, true]);
  assert.deepEqual(fake.discoveries, ["/Applications", `${HOME}/Applications`]);
});

test("discovery continues past a full Xcode with an old SDK or a failed toolchain probe", () => {
  for (const [command, result] of [
    ["/usr/bin/xcrun --sdk macosx --show-sdk-version", ok("25.0\n")],
    ["/usr/bin/xcrun --sdk macosx --show-sdk-version", failed("timed_out")],
    ["/usr/bin/xcrun --sdk macosx swift --version", failed("nonzero_exit")],
  ]) {
    const fake = fixture({
      installations: [XCODE, ALTERNATE],
      overrides: { [`${XCODE}:${command}`]: result },
    });
    const discovered = report(fake);
    assert.equal(discovered.status, "READY");
    assert.equal(discovered.developerDirectory, ALTERNATE);
    const explicit = report(fake, ["--developer-dir", XCODE]);
    assert.equal(explicit.status, "BLOCKED");
    assert.equal(explicit.developerDirectory, XCODE);
    assert.equal(explicit.developerDirectoryAttempts.length, 1);
  }
});

test("Xcode and SDK real paths are checked and the actual directory is reported", () => {
  const actual = "/Applications/Xcode-26.app/Contents/Developer";
  const fake = fixture({ installations: [XCODE, actual] });
  fake.directories.set(XCODE, actual);
  const result = report(fake, ["--developer-dir", XCODE]);
  assert.equal(result.status, "READY");
  assert.equal(result.developerDirectory, actual);
  assert.equal(check(result, "macos-sdk").data.path, sdkPath(actual));
});

test("SDK path must exist and remain inside the selected Xcode, not point into CLT", () => {
  for (const [value, expected] of [
    ["/Missing/MacOSX.sdk", "sdk_not_found"],
    [`${CLT}/SDKs/MacOSX.sdk`, "sdk_outside_selected_xcode"],
    ["relative/MacOSX.sdk", "sdk_invalid_path"],
    [`${sdkPath(XCODE)}\nsecret-token-marker`, "sdk_invalid_path"],
  ]) {
    const fake = fixture({ overrides: { "/usr/bin/xcrun --sdk macosx --show-sdk-path": ok(value) } });
    fake.directories.set(`${CLT}/SDKs/MacOSX.sdk`, `${CLT}/SDKs/MacOSX.sdk`);
    const result = report(fake);
    assert.equal(result.status, "BLOCKED");
    assert.equal(result.developerDirectoryAttempts[0].reason, expected);
    assert.ok(!formatReport(result, true).includes("secret-token-marker"));
  }
});

for (const [command, id] of [
  ["/usr/bin/sw_vers -productVersion", "macos"],
  ["/usr/bin/sw_vers -buildVersion", "macos"],
  ["/usr/sbin/sysctl -n hw.optional.arm64", "apple-silicon"],
  ["/usr/bin/xcodebuild -version", "xcode"],
  ["/usr/bin/xcrun --sdk macosx --show-sdk-path", "xcode"],
  ["/usr/bin/xcrun --sdk macosx --show-sdk-version", "macos-sdk"],
  ["/usr/bin/xcrun --sdk macosx swift --version", "swift"],
  ["/tools/xcodegen --version", "xcodegen"],
]) {
  for (const reason of ["nonzero_exit", "timed_out", "output_limit"]) {
    test(`required probe ${command}: ${reason} is BLOCKED`, () => {
      const result = report(fixture({ overrides: { [command]: failed(reason) } }));
      assert.equal(result.status, "BLOCKED");
      assert.equal(result.exitCode, 1);
      assert.equal(check(result, id).status, "BLOCKED");
      assert.match(formatReport(result, true), new RegExp(reason, "u"));
    });
  }
}

test("missing optional tools never gate the native GUI/emulator prerequisites", () => {
  const fake = fixture({ tools: { xcodegen: "Version: 2.44.1\n" } });
  const result = report(fake);
  assert.equal(result.status, "READY");
  for (const id of ["copilot", "gh"]) {
    assert.equal(check(result, id).required, false);
    assert.equal(check(result, id).status, "OPTIONAL_UNAVAILABLE");
  }
  assert.ok(!fake.calls.some((call) => call.args.includes("auth") || call.args.includes("login")));
});

test("optional command failures and missing global selection remain informational", () => {
  const result = report(fixture({ overrides: {
    "/tools/copilot --version": failed("timed_out"),
    "/tools/gh --version": failed("nonzero_exit"),
    "/usr/bin/xcode-select -p": failed("not_found"),
  } }));
  assert.equal(result.status, "READY");
  assert.equal(result.globalDeveloperDirectory, null);
  assert.equal(result.globalSelectionProbe, "not_found");
  assert.equal(check(result, "copilot").status, "OPTIONAL_UNAVAILABLE");
});

test("XcodeGen is required only in full development, not the I-00 xcode phase", () => {
  const fake = fixture({ tools: {} });
  const setup = report(fake, ["--phase", "xcode"]);
  assert.equal(setup.status, "READY");
  assert.equal(check(setup, "xcodegen").required, false);
  assert.equal(check(setup, "xcodegen").status, "DEFERRED");
  const development = report(fake);
  assert.equal(development.status, "BLOCKED");
  assert.equal(check(development, "xcodegen").required, true);
  assert.equal(check(development, "xcodegen").status, "BLOCKED");
});

test("macOS eligibility is Tahoe 26.x, not an exact patch match or a qualification claim", () => {
  for (const version of ["26.0", "26.6.1", "26.6.2", "26.9"]) {
    assert.equal(report(fixture({ os: version })).status, "READY");
  }
  for (const version of ["25.6.2", "27.0", "not-a-version"]) {
    assert.equal(check(report(fixture({ os: version })), "macos").status, "BLOCKED");
  }
});

test("non-macOS and Intel hosts are blocked, while Rosetta does not misidentify Apple Silicon", () => {
  const linux = fixture({ platform: "linux", arch: "arm64" });
  const result = report(linux);
  assert.equal(result.status, "BLOCKED");
  assert.deepEqual(linux.discoveries, []);
  assert.ok(!linux.calls.some((call) => call.command.startsWith("/usr/")));
  assert.equal(check(report(fixture({ arch: "x64", appleSilicon: "0" })), "apple-silicon").status, "BLOCKED");
  assert.equal(check(report(fixture({ arch: "x64", appleSilicon: "1" })), "apple-silicon").status, "PASS");
  assert.equal(check(report(fixture({ appleSilicon: "unknown" })), "apple-silicon").status, "BLOCKED");
});

test("an older SDK or Node runtime does not pass the declared tooling floor", () => {
  assert.equal(check(report(fixture({ sdk: "25.0" })), "macos-sdk").status, "BLOCKED");
  assert.equal(check(report(fixture({ nodeVersion: "v16.20.2" })), "node").status, "BLOCKED");
  assert.equal(check(report(fixture({ nodeVersion: "not-a-version" })), "node").status, "BLOCKED");
});

test("Swift below 6 blocks an explicit selection and discovery can choose a qualified alternate", () => {
  const fake = fixture({
    installations: [XCODE, ALTERNATE],
    overrides: {
      [`${XCODE}:/usr/bin/xcrun --sdk macosx swift --version`]:
        ok("Apple Swift version 5.10 (swiftlang-5.10)\n"),
    },
  });
  const explicit = report(fake, ["--developer-dir", XCODE]);
  assert.equal(explicit.status, "BLOCKED");
  assert.equal(explicit.exitCode, 1);
  assert.equal(explicit.developerDirectory, XCODE);
  assert.equal(check(explicit, "swift").status, "BLOCKED");
  assert.equal(explicit.developerDirectoryAttempts[0].reason, "swift_requires_6");
  assert.equal(explicit.developerDirectoryAttempts.length, 1);
  const discovered = report(fake);
  assert.equal(discovered.status, "READY");
  assert.equal(discovered.developerDirectory, ALTERNATE);
});

test("unexpected version output is not accepted or copied into reports", () => {
  const fake = fixture({ overrides: {
    "/usr/bin/xcodebuild -version": ok("secret-token-marker"),
    "/tools/copilot --version": ok("secret-token-marker"),
  } });
  const result = report(fake);
  assert.equal(result.status, "BLOCKED");
  assert.equal(check(result, "copilot").status, "OPTIONAL_UNAVAILABLE");
  assert.ok(!formatReport(result, true).includes("secret-token-marker"));
});

test("Copilot's optional display punctuation is not part of its observed version", () => {
  for (const output of [
    "1.0.84-5.\n",
    "GitHub Copilot CLI 1.0.84-5.\n",
    "1.0.84-5\nCommit: example\n",
  ]) {
    const result = report(fixture({ overrides: { "/tools/copilot --version": ok(output) } }));
    assert.equal(check(result, "copilot").data.version, "1.0.84-5");
    assert.ok(!check(result, "copilot").message.includes(".."));
  }
});

test("text and JSON output agree with status/exit codes and JSON is deterministic", () => {
  for (const installations of [[XCODE], []]) {
    const fake = fixture({ installations });
    const text = invoke(["--phase", "xcode"], fake.deps);
    const json = invoke(["--phase", "xcode", "--json"], fake.deps);
    const parsed = JSON.parse(json.stdout);
    assert.equal(text.exitCode, installations.length ? 0 : 1);
    assert.equal(json.exitCode, text.exitCode);
    assert.equal(parsed.exitCode, json.exitCode);
    assert.ok(text.stdout.startsWith(`${parsed.status}: developer prerequisites`));
    assert.equal(text.stderr, "");
    assert.equal(json.stderr, "");
    assert.equal(json.stdout, invoke(["--phase", "xcode", "--json"], fake.deps).stdout);
    assert.equal(Object.hasOwn(parsed, "timestamp"), false);
    assert.ok(!json.stdout.includes("secret-token-marker"));
  }
});

test("help and invalid arguments never run command or filesystem probes", () => {
  const fake = fixture();
  for (const args of [["--help"], ["-h"], ["--help", "--json"]]) {
    const result = invoke(args, fake.deps);
    assert.equal(result.exitCode, 0);
    assert.equal(result.stderr, "");
    if (args.includes("--json")) assert.equal(JSON.parse(result.stdout).status, "HELP");
    else assert.equal(result.stdout, HELP);
  }
  for (const args of [
    ["--unknown"], ["--phase"], ["--phase", "native"], ["--phase=xcode"],
    ["--developer-dir"], ["--developer-dir", "relative/Xcode.app"], ["--json", "--json"],
    ["--developer-dir", "/Xcode.app\nbad"], ["--phase", "--json"], ["-h", "--help"],
  ]) {
    for (const json of [false, true]) {
      const result = invoke(json ? [...args, "--json"] : args, fake.deps);
      assert.equal(result.exitCode, 2);
      if (json || args.includes("--json")) {
        const parsed = JSON.parse(result.stdout);
        assert.equal(parsed.status, "ERROR");
        assert.equal(parsed.exitCode, 2);
        assert.equal(result.stderr, "");
      } else {
        assert.match(result.stderr, /^ERROR: /u);
        assert.equal(result.stdout, "");
      }
    }
  }
  assert.deepEqual(fake.calls, []);
  assert.deepEqual(fake.discoveries, []);
});

test("command execution uses fixed arrays, no shell, bounded output/timeout and ignored stdin", () => {
  let options;
  const runner = (command, args, receivedOptions) => {
    assert.equal(command, "/usr/bin/xcodebuild");
    assert.deepEqual(args, ["-version"]);
    options = receivedOptions;
    return { status: 0, stdout: "Xcode 26.0\n", stderr: "" };
  };
  const environment = { DEVELOPER_DIR: "/Applications/Xcode $(touch unsafe).app/Contents/Developer" };
  assert.deepEqual(runCommand("/usr/bin/xcodebuild", ["-version"], environment, runner),
    ok("Xcode 26.0\n"));
  assert.equal(options.shell, false);
  assert.equal(options.timeout, LIMITS.timeoutMs);
  assert.equal(options.maxBuffer, LIMITS.outputBytes);
  assert.equal(options.killSignal, "SIGKILL");
  assert.deepEqual(options.stdio, ["ignore", "pipe", "pipe"]);
  assert.equal(options.env, environment);
});

test("runner classifies failures without returning raw stderr or partial secret-bearing output", () => {
  for (const [result, reason] of [
    [{ error: { code: "ENOENT" } }, "not_found"],
    [{ error: { code: "EACCES" } }, "permission_denied"],
    [{ error: { code: "ETIMEDOUT" } }, "timed_out"],
    [{ error: { code: "ENOBUFS" } }, "output_limit"],
    [{ error: { code: "EIO" } }, "probe_failed"],
    [{ status: 1 }, "nonzero_exit"],
    [{ signal: "SIGKILL" }, "terminated"],
  ]) {
    const actual = runCommand("fake", ["--version"], {}, () => ({
      stdout: "secret-token-marker", stderr: "secret-token-marker", ...result,
    }));
    assert.deepEqual(actual, failed(reason));
  }
});

test("the subprocess environment is narrowly allowlisted, not a token-bearing dump", () => {
  const actual = probeEnvironment({
    PATH: "/tools", HOME: "/ignored", TMPDIR: "/tmp/doctor", DEVELOPER_DIR: CLT,
    GH_TOKEN: "secret-token-marker", NODE_OPTIONS: "--require=unsafe", COPILOT_GITHUB_TOKEN: "secret",
  }, HOME);
  assert.deepEqual(actual, {
    PATH: "/tools", HOME, TMPDIR: "/tmp/doctor", LANG: "C", LC_ALL: "C", NO_COLOR: "1",
  });
});

test("discovery has deterministic ordering, limits and explicit read errors", () => {
  const found = discoverDeveloperDirectories({
    applications(directory) {
      return directory === "/Applications"
        ? { ok: true, limited: true, apps: [
          "/Applications/Xcode-z.app", "/Applications/Xcode.app",
          ...Array.from({ length: 10 }, (_, index) => `/Applications/Xcode-${index}.app`),
        ] }
        : failed("permission_denied");
    },
  }, HOME);
  assert.equal(found.candidates.length, LIMITS.developerCandidates);
  assert.equal(found.candidates[0], XCODE);
  assert.equal(found.limited, true);
  assert.equal(found.discovery[1].status, "ERROR");
  const fake = fixture({ installations: [] });
  fake.deps.fs.applications = () => failed("permission_denied");
  const result = report(fake);
  assert.equal(result.status, "BLOCKED");
  assert.match(formatReport(result), /Discovery error: \/Applications \(permission_denied\)/u);
});

test("filesystem probes distinguish absent paths and non-directories using only injected FS", () => {
  assert.deepEqual(inspectDirectory("/Xcode", {
    statSync: () => ({ isDirectory: () => false }),
  }), failed("not_directory"));
  assert.deepEqual(inspectDirectory("/Xcode", {
    statSync: () => { throw Object.assign(new Error("private path"), { code: "EACCES" }); },
  }), failed("permission_denied"));
  assert.deepEqual(inspectDirectory("/Xcode", {
    statSync: () => ({ isDirectory: () => true }), realpathSync: () => "/resolved",
  }), { ok: true, path: "/resolved" });
});

test("application enumeration is shallow and bounded, closes handles and reports failures", () => {
  let reads = 0;
  let closed = false;
  const result = listXcodeApps("/Applications", {
    opendirSync: () => ({
      readSync() { reads += 1; return { name: reads === 1 ? "Xcode.app" : "Other.app" }; },
      closeSync() { closed = true; },
    }),
  });
  assert.deepEqual(result.apps, ["/Applications/Xcode.app"]);
  assert.equal(result.limited, true);
  assert.equal(reads, LIMITS.applicationEntries + 1);
  assert.equal(closed, true);
  assert.deepEqual(listXcodeApps("/Applications", {
    opendirSync: () => { throw Object.assign(new Error("private path"), { code: "ENOENT" }); },
  }), failed("not_found"));
});

test("PATH lookup is bounded and checks executability, never invoking a shell", () => {
  const accesses = [];
  const fs = {
    constants: { X_OK: 1 },
    accessSync(executable, mode) {
      assert.equal(mode, 1);
      accesses.push(executable);
      if (executable !== "/tools/gh") throw Object.assign(new Error("missing"), { code: "ENOENT" });
    },
    statSync: () => ({ isFile: () => true }),
  };
  assert.deepEqual(findExecutable("gh", "/missing:/tools", fs), { ok: true, path: "/tools/gh" });
  accesses.length = 0;
  const result = findExecutable("gh", Array(100).fill("/missing").join(":"), fs);
  assert.deepEqual(result, { ok: false, reason: "not_found", limited: true });
  assert.equal(accesses.length, LIMITS.pathEntries);
});

test("shell metacharacters in an explicit installation stay in DEVELOPER_DIR, never command arguments", () => {
  const directory = "/Applications/Xcode $(touch unsafe);beta.app/Contents/Developer";
  const fake = fixture({ installations: [directory] });
  const result = probeDeveloperDirectory(directory, { ...fake.deps, env: {} });
  assert.equal(result.ok, true);
  assert.deepEqual(fake.calls.map((call) => [call.command, call.args]), [
    ["/usr/bin/xcodebuild", ["-version"]],
    ["/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]],
    ["/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]],
    ["/usr/bin/xcrun", ["--sdk", "macosx", "swift", "--version"]],
  ]);
  assert.ok(fake.calls.every((call) => call.env.DEVELOPER_DIR === directory));
});

test("text rendering escapes control characters rather than emitting terminal controls", () => {
  const result = report(fixture());
  result.globalDeveloperDirectory = "/unsafe\u001b[31m\nnew line";
  const text = formatReport(result);
  assert.ok(!text.includes("\u001b"));
  assert.ok(text.includes("/unsafe\\u001b[31m\\u000anew line"));
  assert.equal(JSON.parse(formatReport(result, true)).globalDeveloperDirectory, result.globalDeveloperDirectory);
});
