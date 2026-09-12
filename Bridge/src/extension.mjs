import {
  classifyExtensionFailure,
  runHostExtension,
} from "./extension-runtime.mjs";

const controller = new AbortController();
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => controller.abort());
}

try {
  const { joinSession } = await import("@github/copilot-sdk/extension");
  await runHostExtension({
    joinSession,
    signal: controller.signal,
  });
} catch (error) {
  if (!controller.signal.aborted) {
    process.stderr.write(
      `${JSON.stringify({
        component: "copilot-micro-session-bridge",
        outcome: "failed",
        errorCategory: classifyExtensionFailure(error),
      })}\n`,
    );
    process.exitCode = 1;
  }
}
