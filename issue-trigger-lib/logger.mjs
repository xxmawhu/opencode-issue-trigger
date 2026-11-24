// Logging adapter. The sink is injected: the v1 host passes opencode's logger,
// the v2 host passes a project log file sink (no app.log endpoint, and standalone
// stderr is /dev/null — issue 891a50f5). No file paths are created here, and
// logging never throws into the plugin call path.
const LEVELS = new Set(["debug", "info", "warn", "error"]);

export function createLogger({ sink } = {}) {
  function write(level, message, extra) {
    if (typeof sink !== "function") return;
    try {
      const result = sink(LEVELS.has(level) ? level : "info", message, extra);
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch {
      // Logging must never break injection.
    }
  }

  // WARN: recoverable failures only (retryable session lookup, watcher restart);
  // each caller passes the failure reason, injection itself continues.
  return {
    debug: (message, extra) => write("debug", message, extra),
    info: (message, extra) => write("info", message, extra),
    warn: (message, extra) => write("warn", message, extra),
    error: (message, extra) => write("error", message, extra),
  };
}