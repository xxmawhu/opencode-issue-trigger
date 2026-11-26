// OpenCode plugin entry, installed as ~/.config/opencode/plugin/issue-trigger.ts.
//
// Dual-generation export, one plain object literal:
//   - opencode 1.x reads the default object and calls `server(input)`.
//   - opencode 2.x validates `id` + `setup(ctx)` on the same object.
// The literal is exported as-is: no helper wrapping, no spreading. `define()` is
// an identity function today and spreading would drop any non-enumerable brand a
// future host attaches.
// `tui` is intentionally absent: the v1 loader rejects a `tui` field that
// coexists with `server`.
import { join } from "node:path";
import {
  createFileSink,
  createGoalResume,
  createIssueTrigger,
  createLogger,
} from "../issue-trigger-lib/index.mjs";

// One host per project directory. A newer v1 host may run both the v1 and v2
// passes, so `server()` and `setup()` can run in the same process; the refcount
// keeps a single watcher/injector instead of injecting the same issue twice.
const hosts = new Map();

function createCore({ directory, logger, listSessions, sendPrompt, onInjected }) {
  const issuesDir = join(directory, "issues");
  // Held in an object so a later generation loading the same directory can attach
  // its own hook (the v2 pass owns goal resume; the v1 pass does not).
  const hook = { onInjected };
  const trigger = createIssueTrigger({
    issuesDir,
    directory,
    logger,
    listSessions,
    sendPrompt,
    onInjected: (sessionID, path) => hook.onInjected?.(sessionID, path),
  });
  return { trigger, hook };
}

function acquireHost(config) {
  const existing = hosts.get(config.directory);
  if (existing) {
    existing.refs += 1;
    if (!existing.hook.onInjected && config.onInjected) existing.hook.onInjected = config.onInjected;
    return existing;
  }
  const host = { ...createCore(config), refs: 1 };
  hosts.set(config.directory, host);
  return host;
}

function releaseHost(directory) {
  const host = hosts.get(directory);
  if (!host) return undefined;
  host.refs -= 1;
  if (host.refs > 0) return undefined;
  hosts.delete(directory);
  return host.trigger.stop();
}

// Generation is decided by the registration surface actually present in the
// input, never by a version string:
//   - v1 input carries `directory` (or `worktree`) plus `client.session`.
//   - v2 context carries `location.directory` plus a top-level `session` object.
// Missing surface means "not my generation": the adapter stays inert.
function v1Surface(input) {
  const directory = input?.directory ?? input?.worktree;
  if (typeof directory !== "string" || directory.length === 0) return undefined;
  const session = input?.client?.session;
  if (typeof session?.list !== "function") return undefined;
  if (typeof session?.prompt !== "function" && typeof session?.promptAsync !== "function") return undefined;
  return directory;
}

function v2Surface(ctx) {
  if (typeof ctx?.location?.directory !== "string" || ctx.location.directory.length === 0) return undefined;
  if (typeof ctx?.session?.list !== "function") return undefined;
  if (typeof ctx?.session?.prompt !== "function") return undefined;
  return ctx.location.directory;
}

// V1 adapter: translate the core into the classic initialization flow. The
// returned hook table is what the v1 host consumes.
async function server(input) {
  const directory = v1Surface(input);
  if (!directory) return {};
  const client = input.client;
  // Logging goes to opencode's own log sink; the plugin never owns a log file.
  const logger = createLogger({
    sink: (level, message, extra) =>
      client?.app?.log?.({
        body: {
          service: "issue-trigger",
          level,
          message,
          ...(extra === undefined ? {} : { extra }),
        },
      }),
  });

  const host = acquireHost({
    directory,
    logger,
    listSessions: async () => {
      const result = await client.session.list({ query: { directory } });
      if (Array.isArray(result)) return result;
      if (Array.isArray(result?.data)) return result.data;
      return [];
    },
    sendPrompt: async (sessionID, text) => {
      const payload = {
        path: { id: sessionID },
        body: { parts: [{ type: "text", text }] },
        query: { directory },
      };
      if (typeof client.session.promptAsync === "function") {
        await client.session.promptAsync(payload);
        return;
      }
      await client.session.prompt(payload);
    },
  });

  host.trigger.start().catch((error) => {
    logger.error("failed to start issue-trigger", { error: String(error) });
  });

  logger.info("issue-trigger loaded", { issuesDir: host.trigger.issuesDir });

  return {
    event: async ({ event }) => {
      host.trigger.noteEvent(event);
    },
    dispose: async () => {
      await releaseHost(directory);
    },
  };
}

// V2 adapter: translate the same core onto context methods, then return the
// cleanup callback the v2 host expects.
async function setup(ctx) {
  const directory = v2Surface(ctx);
  if (!directory) {
    // v1 config callbacks and any other context without the v2 surface are not
    // this entry's job; staying inert avoids a watcher that cannot reach the
    // session API.
    return undefined;
  }
  // opencode 2.x exposes no app.log endpoint, and a standalone server runs with
  // stderr on /dev/null: console-only lines are lost (issue 891a50f5). Entries go
  // to <project>/log/issue-trigger.YYYYMMDDTHH.log so a silently unloaded
  // location still leaves a trail; an unwritable log dir falls back to stderr.
  const logger = createLogger({
    sink: createFileSink({ logDir: join(directory, "log") }),
  });

  const host = acquireHost({
    directory,
    logger,
    listSessions: async () => {
      const page = await ctx.session.list({ directory, limit: 50 });
      if (Array.isArray(page)) return page;
      if (Array.isArray(page?.data)) return page.data;
      if (Array.isArray(page?.items)) return page.items;
      return [];
    },
    sendPrompt: async (sessionID, text) => {
      await ctx.session.prompt({ sessionID, text });
    },
    // A paused goal stops the session right after the reminder is handled, so the
    // reminder never advances the objective. opencode 2.x exposes the goal command;
    // opencode 1.x has no goal plugin, and the factory then returns a no-op.
    // The goal state is deliberately not read first: `session.context()` is
    // trimmed, so a long session shows no goal message and the resume would be
    // skipped exactly when it is needed (see goal-resume.mjs).
    onInjected: createGoalResume({
      logger,
      resumeCommand:
        typeof ctx.session.command === "function"
          ? (sessionID) => ctx.session.command({ sessionID, name: "goal", text: "resume" })
          : undefined,
    }),
  });

  await host.trigger.start();
  logger.info("issue-trigger loaded", { issuesDir: host.trigger.issuesDir });

  const controller = new AbortController();
  const events =
    typeof ctx?.event?.subscribe === "function"
      ? ctx.event.subscribe({ signal: controller.signal })
      : undefined;
  if (events) {
    void (async () => {
      try {
        for await (const event of events) host.trigger.noteEvent(event);
      } catch (error) {
        // [log-review] 预期内：插件卸载或连接重建；降级原因：注入不依赖该事件流；影响范围：会话跟踪退化为最近会话
        if (!controller.signal.aborted) logger.warn("event stream ended", { error: String(error) });
      }
    })();
  }

  return async () => {
    controller.abort();
    await releaseHost(directory);
  };
}

// `server` for opencode 1.x, `id` + `setup` for opencode 2.x. Both generations
// read this exact literal; it is never rewritten, wrapped or spread.
export default { id: "issue-trigger", server, setup };