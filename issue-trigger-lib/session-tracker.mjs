// Resolves the session that should receive an issue reminder.
//
// Selection policy, in order:
//   1. the same-directory root session the user most recently wrote to
//      (assistant streaming events are ignored so the target does not drift)
//   2. a same-directory root session that is currently idle
//   3. the most recently updated same-directory root session (startup fallback)
//
// A session reported busy by `session.status` is never injected into; the
// reminder waits for `session.idle` instead of interrupting the active turn.
//
// The busy mark is only trusted for `busyStaleMs`. Host event streams can end
// (TUI closed, turn aborted, stream rebuild) without a matching idle event, and
// the plugin instance lives in a long-running server process: an unbounded mark
// then blocks every reminder for the rest of the process. Observed on
// alg-trader-n2: 30+ minutes of "no injectable session yet" per issue until the
// reminder expired, repeated across 33 issues (2026-11-13..16).
function toMillis(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value < 1e12 ? value * 1000 : value;
  }
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

function updatedAt(session) {
  return Math.max(
    toMillis(session?.time?.updated),
    toMillis(session?.time?.busy),
    toMillis(session?.time?.idle),
    toMillis(session?.time?.created),
    toMillis(session?.updatedAt),
  );
}

function isRoot(session) {
  return session && !session.parentID && !session.parentId;
}

function isUserMessage(event) {
  if (event?.type !== "message.updated") return false;
  return event.properties?.info?.role === "user";
}

export function extractSessionID(event) {
  if (!event || typeof event !== "object") return undefined;
  const candidates = [
    event.properties?.sessionID,
    event.properties?.info?.sessionID,
    event.properties?.part?.sessionID,
    event.sessionID,
    event.info?.sessionID,
    event.data?.sessionID,
    event.data?.info?.sessionID,
    event.data?.part?.sessionID,
  ];
  return candidates.find((value) => typeof value === "string" && value.length > 0);
}

export function createSessionTracker({
  listSessions,
  directory,
  logger,
  busyStaleMs = 15 * 60 * 1000,
  now = () => Date.now(),
} = {}) {
  let lastSessionID;
  // sessionID -> time of the last non-idle status event.
  const busy = new Map();

  function noteEvent(event) {
    const sessionID = extractSessionID(event);
    if (!sessionID) return;
    if (event?.type === "session.status") {
      // retry counts as busy: the session is still working on a turn.
      if (event.properties?.status?.type === "idle") busy.delete(sessionID);
      else busy.set(sessionID, now());
      return;
    }
    if (event?.type === "session.idle") {
      busy.delete(sessionID);
      return;
    }
    if (isUserMessage(event)) lastSessionID = sessionID;
  }

  // A busy mark survives only while it keeps being refreshed by status events.
  function isBusy(sessionID) {
    const markedAt = busy.get(sessionID);
    if (markedAt === undefined) return false;
    const stalledMs = now() - markedAt;
    if (stalledMs <= busyStaleMs) return true;
    busy.delete(sessionID);
    // [log-review] 预期内：宿主事件流中断后缺失 idle 事件；降级原因：过期标记按空闲处理，
    // 否则提醒在本进程内永久阻塞；影响范围：可能向已结束的轮次补发一次提示。
    logger?.warn("stale busy mark expired; session treated as idle", {
      sessionID,
      stalledMs,
      busyStaleMs,
    });
    return false;
  }

  async function resolve() {
    let sessions;
    try {
      sessions = await listSessions();
    } catch (error) {
      // [log-review] 预期内：服务端尚未就绪；降级原因：下次触发会重新查询；影响范围：本次注入延迟
      logger?.warn("session list delayed; retry on next trigger", { error: String(error) });
      return undefined;
    }
    if (!Array.isArray(sessions)) return undefined;
    const roots = sessions
      .filter(isRoot)
      .filter((session) => !directory || !session.directory || session.directory === directory)
      .slice()
      .sort((a, b) => updatedAt(b) - updatedAt(a));
    if (roots.length === 0) return undefined;

    const tracked = lastSessionID ? roots.find((session) => session.id === lastSessionID) : undefined;
    const target = tracked || roots.find((session) => !isBusy(session.id)) || roots[0];
    if (isBusy(target.id)) {
      logger?.debug("all candidate sessions busy; waiting for idle", {
        roots: roots.length,
        directory,
      });
      return undefined;
    }
    return target.id;
  }

  return {
    noteEvent,
    resolve,
    get lastSessionID() {
      return lastSessionID;
    },
  };
}