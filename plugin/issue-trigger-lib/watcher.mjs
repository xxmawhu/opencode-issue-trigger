// Watches <project>/issues with fs.watch plus a periodic polling fallback.
// Every regular .md file is an issue. Existing files are dispatched on startup;
// files created later wait for the quiet window so writes can finish.
import { readdirSync, statSync, watch } from "node:fs";
import { join } from "node:path";
import { isIssueFileName } from "./issue-file.mjs";

function signatureOf(file) {
  try {
    const stat = statSync(file);
    if (!stat.isFile()) return undefined;
    return { signature: `${stat.dev}:${stat.ino}:${stat.size}:${Math.trunc(stat.mtimeMs)}` };
  } catch {
    return undefined;
  }
}

function unref(timer) {
  if (timer && typeof timer.unref === "function") timer.unref();
  return timer;
}

export function createIssueWatcher({
  issuesDir,
  logger,
  onReady,
  quietMs = 800,
  pollMs = 30_000,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
} = {}) {
  let watcher;
  let pollTimer;
  let missingLoggedAt = 0;
  const candidates = new Map();
  const dispatched = new Set();

  function listFiles() {
    let entries;
    try {
      entries = readdirSync(issuesDir, { withFileTypes: true });
    } catch {
      return [];
    }
    const files = [];
    for (const entry of entries) {
      if (!entry.isFile() || !isIssueFileName(entry.name)) continue;
      const path = join(issuesDir, entry.name);
      const info = signatureOf(path);
      if (!info) continue;
      files.push({ path, ...info });
    }
    return files;
  }

  function cancel(path) {
    const candidate = candidates.get(path);
    if (!candidate) return;
    clearTimeoutFn(candidate.timer);
    candidates.delete(path);
  }

  function release(path) {
    cancel(path);
    dispatched.delete(path);
  }

  function dispatch(path) {
    candidates.delete(path);
    if (dispatched.has(path)) return;
    dispatched.add(path);
    try {
      const result = onReady(path);
      if (result && typeof result.catch === "function") {
        result.catch((error) => {
          logger?.error("issue ready handler failed", { path, error: String(error) });
          release(path);
        });
      }
    } catch (error) {
      logger?.error("issue ready handler threw", { path, error: String(error) });
      release(path);
    }
  }

  function schedule(path, info) {
    if (dispatched.has(path)) return;
    cancel(path);
    const candidate = { signature: info.signature, timer: undefined };
    candidates.set(path, candidate);
    candidate.timer = unref(
      setTimeoutFn(() => {
        const current = candidates.get(path);
        if (current !== candidate) return;
        const latest = signatureOf(path);
        if (!latest) {
          cancel(path);
          return;
        }
        if (latest.signature !== candidate.signature) {
          schedule(path, latest);
          return;
        }
        dispatch(path);
      }, quietMs),
    );
  }

  function consider(name) {
    if (!isIssueFileName(name)) return;
    const path = join(issuesDir, name);
    if (dispatched.has(path)) return;
    const info = signatureOf(path);
    if (!info) {
      cancel(path);
      return;
    }
    schedule(path, info);
  }

  function scanNow({ immediate = false } = {}) {
    ensureWatch();
    const files = listFiles();
    for (const file of files) {
      if (dispatched.has(file.path)) continue;
      if (candidates.has(file.path)) continue;
      if (immediate) {
        dispatch(file.path);
      } else {
        schedule(file.path, file);
      }
    }
  }

  function ensureWatch() {
    if (watcher) return;
    try {
      watcher = watch(issuesDir, { persistent: false }, (_eventType, filename) => {
        if (typeof filename === "string" && filename.length > 0) {
          consider(filename);
        } else {
          scanNow();
        }
      });
      watcher.on("error", (error) => {
        // [log-review] 预期内：目录被替换或句柄失效；降级原因：轮询兜底仍可发现文件；影响范围：最长延迟一个轮询周期
        logger?.warn("issues watcher stopped; polling fallback continues", { error: String(error) });
        try {
          watcher?.close();
        } catch {
          // Ignore close failures.
        }
        watcher = undefined;
      });
    } catch (error) {
      watcher = undefined;
      const now = Date.now();
      if (now - missingLoggedAt > 300_000) {
        missingLoggedAt = now;
        // [log-review] 预期内：issues 目录尚未创建；降级原因：每 5 分钟重试且轮询兜底；影响范围：创建后最长延迟一个轮询周期
        logger?.warn("issues directory is not watchable yet; polling fallback continues", {
          issuesDir,
          error: String(error),
        });
      }
    }
  }

  return {
    get issuesDir() {
      return issuesDir;
    },

    async start() {
      // State is intentionally in-memory only: every startup re-reminds the
      // user about issues already sitting on disk.
      const files = listFiles();
      ensureWatch();
      for (const file of files) dispatch(file.path);
      logger?.info("startup scan dispatched existing issues", { issuesDir, count: files.length });
      pollTimer = unref(setIntervalFn(() => scanNow(), pollMs));
    },

    scanNow,
    consider,
    release,

    async stop() {
      if (pollTimer) {
        clearIntervalFn(pollTimer);
        pollTimer = undefined;
      }
      for (const path of [...candidates.keys()]) cancel(path);
      try {
        watcher?.close();
      } catch {
        // Ignore close failures.
      }
      watcher = undefined;
    },
  };
}