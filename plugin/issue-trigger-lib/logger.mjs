// Structured, best-effort logging. Never throws into the plugin call path.
import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const MAX_LOG_BYTES = 2 * 1024 * 1024;

export function createLogger({ stateDir, sink } = {}) {
  const root = stateDir || join(homedir(), ".local", "state", "opencode-issue-trigger");
  const file = join(root, "issue-trigger.log");

  function rotate() {
    try {
      if (existsSync(file) && statSync(file).size > MAX_LOG_BYTES) {
        renameSync(file, `${file}.1`);
      }
    } catch {
      // Best effort only.
    }
  }

  function write(level, message, extra) {
    const line = JSON.stringify({
      time: new Date().toISOString(),
      level,
      service: "issue-trigger",
      message,
      ...(extra === undefined ? {} : { extra }),
    });
    try {
      if (!existsSync(root)) mkdirSync(root, { recursive: true });
      rotate();
      appendFileSync(file, `${line}\n`);
    } catch {
      // Logging must never break injection.
    }
    if (typeof sink === "function") {
      try {
        const result = sink(level, message, extra);
        if (result && typeof result.catch === "function") result.catch(() => {});
      } catch {
        // Host logger is optional.
      }
    }
  }

  // WARN: recoverable failures only (retryable session lookup, watcher restart);
  // each caller passes the failure reason, injection itself continues.
  return {
    info: (message, extra) => write("info", message, extra),
    warn: (message, extra) => write("warn", message, extra),
    error: (message, extra) => write("error", message, extra),
  };
}