// Resolves the most recently active root session for prompt injection.
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

export function createSessionTracker({ listSessions, logger } = {}) {
  let lastSessionID;

  function noteEvent(event) {
    const sessionID = extractSessionID(event);
    if (sessionID) lastSessionID = sessionID;
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
    const roots = sessions.filter(isRoot).slice().sort((a, b) => updatedAt(b) - updatedAt(a));
    if (roots.length === 0) return undefined;
    if (lastSessionID) {
      const tracked = roots.find((session) => session.id === lastSessionID);
      if (tracked) return tracked.id;
    }
    return roots[0].id;
  }

  return {
    noteEvent,
    resolve,
    get lastSessionID() {
      return lastSessionID;
    },
  };
}