// Composes the watcher, session tracker and injector into a single lifecycle object.
// Host plugins only provide listSessions() and sendPrompt(); everything else is local.
import { basename } from "node:path";
import { createInjector } from "./injector.mjs";
import { createLogger } from "./logger.mjs";
import { createSessionTracker } from "./session-tracker.mjs";
import { createStateStore } from "./state.mjs";
import { createIssueWatcher } from "./watcher.mjs";

export const PROMPT_TEMPLATE = "请分析{issue-path}的内容，制定plan，写入到./plan并逐步实施";

export function buildIssuePrompt(issueName) {
  return PROMPT_TEMPLATE.replace("{issue-path}", `./issues/${issueName}`);
}

export function createIssueTrigger({
  issuesDir,
  stateDir,
  logger,
  listSessions,
  sendPrompt,
  quietMs,
  pollMs,
  maxAgeMs,
  now,
  setTimeoutFn,
  clearTimeoutFn,
  setIntervalFn,
  clearIntervalFn,
} = {}) {
  if (typeof issuesDir !== "string" || issuesDir.length === 0) {
    throw new TypeError("createIssueTrigger requires issuesDir");
  }
  if (typeof listSessions !== "function") {
    throw new TypeError("createIssueTrigger requires listSessions()");
  }
  if (typeof sendPrompt !== "function") {
    throw new TypeError("createIssueTrigger requires sendPrompt()");
  }

  const log = logger || createLogger({ stateDir });
  const state = createStateStore({ issuesDir, stateDir });
  const sessions = createSessionTracker({ listSessions, logger: log });

  const injector = createInjector({
    resolveSession: () => sessions.resolve(),
    sendPrompt,
    onSuccess: (item) => {
      if (!state.mark(item.path)) {
        // [log-review] 预期内：状态目录不可写；降级原因：注入已完成；影响范围：重启后可能重复注入
        log.warn("issue state write delayed; continuing", { path: item.path });
      }
    },
    onDrop: (path) => watcher.release(path),
    logger: log,
    maxAgeMs,
    now,
    setTimeoutFn,
    clearTimeoutFn,
  });

  const watcher = createIssueWatcher({
    issuesDir,
    state,
    logger: log,
    quietMs,
    pollMs,
    setTimeoutFn,
    clearTimeoutFn,
    setIntervalFn,
    clearIntervalFn,
    onReady: (path) => {
      injector.enqueue(path, buildIssuePrompt(basename(path)));
    },
  });

  let started = false;

  return {
    issuesDir,
    noteEvent: (event) => sessions.noteEvent(event),
    async start() {
      if (started) return;
      started = true;
      await watcher.start();
    },
    async stop() {
      if (!started) return;
      started = false;
      injector.stop();
      await watcher.stop();
    },
    get started() {
      return started;
    },
  };
}