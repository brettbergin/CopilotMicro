import * as fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const temporaryOutputPattern =
  /^build\/smoke-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

export class CleanupError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function inspect(entry, filesystem) {
  try {
    return filesystem.lstatSync(entry);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

export function removeTemporarySmokeOutput(root, requested, filesystem = fs) {
  if (typeof requested !== "string" || !temporaryOutputPattern.test(requested)) {
    throw new CleanupError("unsafe_path", "Only a generated build/smoke-UUID directory can be removed.");
  }
  const canonicalRoot = filesystem.realpathSync(root);
  const build = path.join(canonicalRoot, "build");
  const output = path.resolve(canonicalRoot, requested);
  if (path.dirname(output) !== build) {
    throw new CleanupError("unsafe_path", "Temporary smoke output must be a direct child of build.");
  }
  const outputStat = inspect(output, filesystem);
  if (outputStat === null) return false;
  const buildStat = inspect(build, filesystem);
  if (!buildStat?.isDirectory() || buildStat.isSymbolicLink()
      || !outputStat.isDirectory() || outputStat.isSymbolicLink()
      || filesystem.realpathSync(build) !== build
      || filesystem.realpathSync(output) !== output) {
    throw new CleanupError("unsafe_path", "Temporary smoke output must be a real local directory.");
  }
  filesystem.rmSync(output, { recursive: true });
  return true;
}

export function main(argv, {
  root = fileURLToPath(new URL("..", import.meta.url)),
  filesystem = fs,
} = {}, io = process) {
  try {
    if (argv.length !== 1) {
      throw new CleanupError("usage", "Expected one generated build/smoke-UUID directory.");
    }
    const removed = removeTemporarySmokeOutput(root, argv[0], filesystem);
    io.stdout.write(`${JSON.stringify({ outcome: "cleaned", removed })}\n`);
    return 0;
  } catch (error) {
    io.stderr.write(`${JSON.stringify({
      outcome: "failed",
      errorCode: error.code ?? "cleanup_failed",
      message: error.message,
    })}\n`);
    return error.code === "usage" ? 2 : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
