// Serial prompt injection queue with bounded retries. An issue path is injected once.
const DEFAULT_MAX_AGE_MS = 30 * 60 * 1000;
const NO_SESSION_RETRY_MS = 5000;
const BUSY_RETRY_MS = [2000, 5000, 10000, 30000, 60000];

export function createInjector({
  resolveSession,
  sendPrompt,
  onDrop,
  logger,
  maxAgeMs = DEFAULT_MAX_AGE_MS,
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
  now = () => Date.now(),
} = {}) {
  const queue = [];
  const known = new Set();
  let flushing = false;
  let retryTimer;
  let stopped = false;

  function scheduleRetry(delay) {
    if (stopped || retryTimer) return;
    retryTimer = setTimeoutFn(() => {
      retryTimer = undefined;
      void flush();
    }, delay);
    if (retryTimer && typeof retryTimer.unref === "function") retryTimer.unref();
  }

  function drop(item, reason) {
    const index = queue.indexOf(item);
    if (index >= 0) queue.splice(index, 1);
    known.delete(item.path);
    logger?.error("dropping issue injection", {
      path: item.path,
      attempts: item.attempts,
      reason,
    });
    try {
      onDrop?.(item.path);
    } catch (error) {
      logger?.warn("drop handler skipped; continuing", { path: item.path, error: String(error) });
    }
  }

  async function flush() {
    if (stopped || flushing) return;
    flushing = true;
    try {
      // 终止性论证：不变量 = queue 元素数非负；每轮非 return 分支只执行 shift 或 drop，
      // queue.length 严格递减且下界为 0，故有限步内必然终止。
      while (queue.length > 0) {
        const item = queue[0];
        if (now() - item.createdAt > maxAgeMs) {
          drop(item, "expired");
          continue;
        }
        let sessionID;
        try {
          sessionID = await resolveSession();
        } catch (error) {
          item.attempts += 1;
          // [log-review] 预期内：会话尚未就绪；降级原因：可重试且不丢任务；影响范围：仅本次注入延迟
          logger?.warn("session lookup delayed; retrying in 5s", {
            path: item.path,
            attempts: item.attempts,
            error: String(error),
          });
          scheduleRetry(NO_SESSION_RETRY_MS);
          return;
        }
        if (!sessionID) {
          item.attempts += 1;
          if (item.attempts === 1 || item.attempts % 12 === 0) {
            logger?.info("no injectable session yet; issue stays queued", {
              path: item.path,
              attempts: item.attempts,
            });
          }
          scheduleRetry(NO_SESSION_RETRY_MS);
          return;
        }
        try {
          await sendPrompt(sessionID, item.text);
        } catch (error) {
          item.attempts += 1;
          const delay = BUSY_RETRY_MS[Math.min(item.attempts - 1, BUSY_RETRY_MS.length - 1)];
          // [log-review] 预期内：会话忙或瞬时拒绝；降级原因：退避重试可恢复；影响范围：仅本次注入延迟
          logger?.warn("prompt injection delayed; retrying with backoff", {
            path: item.path,
            sessionID,
            attempts: item.attempts,
            delayMs: delay,
            error: String(error),
          });
          scheduleRetry(delay);
          return;
        }
        queue.shift();
        known.delete(item.path);
        logger?.info("injected issue prompt", {
          path: item.path,
          sessionID,
          attempts: item.attempts + 1,
        });
      }
    } finally {
      flushing = false;
    }
  }

  function enqueue(path, text) {
    if (stopped || known.has(path)) return false;
    known.add(path);
    queue.push({ path, text, attempts: 0, createdAt: now() });
    logger?.info("queued issue injection", { path, queue: queue.length });
    void flush();
    return true;
  }

  return {
    enqueue,
    flush,
    stop() {
      stopped = true;
      if (retryTimer) {
        clearTimeoutFn(retryTimer);
        retryTimer = undefined;
      }
    },
  };
}