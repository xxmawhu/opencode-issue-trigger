// OpenCode plugin entry, installed as ~/.config/opencode/plugin/issue-trigger.ts.
//
// Single-entry dual export:
//   - opencode 1.x reads the default object and calls `server(input)`.
//   - opencode 2.x reads `id` + `setup(ctx)` from the same object.
// `tui` is intentionally absent: the v1 loader rejects a `tui` field that
// coexists with `server`. Hooks are not translated across generations; both
// paths share the host-neutral core below and adapt only their own registration
// surface.
import { join } from "node:path";
import { createIssueInputHandler, createIssueTrigger, createLogger } from "../issue-trigger-lib/index.mjs";

// One host per project directory. A newer v1 host may run both the v1 and v2
// passes, so `server()` and `setup()` can run in the same process; the refcount
// keeps a single watcher/injector instead of injecting the same issue twice.
const hosts = new Map();

function createCore({ directory, logger, listSessions, sendPrompt }) {
  const issuesDir = join(directory, "issues");
  const inputHandler = createIssueInputHandler({ issuesDir, logger });
  const trigger = createIssueTrigger({ issuesDir, directory, logger, listSessions, sendPrompt });
  return { trigger, inputHandler };
}

function acquireHost(config) {
  const existing = hosts.get(config.directory);
  if (existing) {
    existing.refs += 1;
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

// Feeds the text parts of one user message to the issue command parser. The
// active agent name is intentionally not used: hosts may run every session
// under the same agent (for example `ulw-pm`), so it cannot distinguish user
// input from plugin injections. Only synthetic parts and our own reminder
// prefixes are filtered.
function handleParts({ inputHandler, logger, parts, messageID }) {
  try {
    for (const part of Array.isArray(parts) ? parts : []) {
      if (part?.type !== "text" || typeof part.text !== "string") continue;
      const result = inputHandler.handle({
        text: part.text,
        messageID,
        synthetic: part.synthetic === true,
      });
      if (result.created) break;
    }
  } catch (error) {
    // A parsing failure must never break the user's message.
    logger.error("failed to handle user input", { error: String(error) });
  }
}

function messageParts(message, info) {
  if (Array.isArray(message?.parts)) return message.parts;
  if (Array.isArray(message?.content)) return message.content;
  if (Array.isArray(info?.parts)) return info.parts;
  return [];
}

// opencode 2.x has no chat.message hook. The `context` session hook receives
// the message list before each model call, which is the only place a user
// prompt becomes visible to a plugin, so the issue command is admitted there.
function userTexts(message) {
  const info = message?.info ?? message;
  if (info?.role !== "user") return undefined;
  const messageID = info?.id ?? message?.id ?? info?.messageID;
  const texts = [];
  for (const part of messageParts(message, info)) {
    if (part?.synthetic === true) continue;
    if (part?.type !== "text" || typeof part.text !== "string") continue;
    texts.push(part.text);
  }
  if (typeof info?.text === "string") texts.push(info.text);
  return { messageID, texts };
}

function createContextHook(inputHandler, logger) {
  return (event) => {
    try {
      const messages = Array.isArray(event?.messages) ? event.messages : [];
      for (const message of messages) {
        const entry = userTexts(message);
        if (!entry) continue;
        for (const text of entry.texts) {
          const result = inputHandler.handle({
            text,
            messageID: entry.messageID,
            synthetic: false,
          });
          if (result.created) break;
        }
      }
    } catch (error) {
      logger.error("failed to inspect session messages", { error: String(error) });
    }
    return event;
  };
}

// V1 path: keep the classic initialization flow. The input facade is the v1
// client shape, and the returned hook table is consumed by the v1 host.
async function server(input) {
  const directory = input?.directory || input?.worktree || process.cwd();
  const client = input?.client;
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

  if (!client?.session) {
    logger.error("opencode session client is unavailable; issue-trigger disabled");
    return {};
  }

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
    // v1 hook for user input. Read only the parts the user typed; host
    // synthesized parts are ignored.
    "chat.message": async (input, output) => {
      handleParts({
        inputHandler: host.inputHandler,
        logger,
        parts: output?.parts,
        messageID: input?.messageID,
      });
    },
    event: async ({ event }) => {
      host.trigger.noteEvent(event);
    },
    dispose: async () => {
      await releaseHost(directory);
    },
  };
}

// V2 path: adapt the v2 context to the same core, then bridge registrations.
// `setup` returns the cleanup callback the v2 host expects.
async function setup(ctx) {
  const directory = ctx?.location?.directory || ctx?.directory || process.cwd();
  // opencode 2.x exposes no app.log endpoint; stderr is captured by the host
  // log (verified: --print-logs records console.error).
  const logger = createLogger({
    sink: (level, message, extra) => {
      const suffix = extra === undefined ? "" : ` ${JSON.stringify(extra)}`;
      console.error(`[issue-trigger] ${level} ${message}${suffix}`);
    },
  });

  if (typeof ctx?.session?.prompt !== "function") {
    logger.error("opencode session client is unavailable; issue-trigger disabled");
    return undefined;
  }

  const host = acquireHost({
    directory,
    logger,
    listSessions: async () => {
      if (typeof ctx?.session?.list !== "function") return [];
      const page = await ctx.session.list({ directory, limit: 50 });
      if (Array.isArray(page)) return page;
      if (Array.isArray(page?.data)) return page.data;
      if (Array.isArray(page?.items)) return page.items;
      return [];
    },
    sendPrompt: async (sessionID, text) => {
      await ctx.session.prompt({ sessionID, text });
    },
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

  let contextHook;
  if (typeof ctx?.session?.hook === "function") {
    try {
      contextHook = await ctx.session.hook("context", createContextHook(host.inputHandler, logger));
    } catch (error) {
      logger.error("failed to register session context hook", { error: String(error) });
    }
  } else {
    // [log-review] 预期内：宿主未暴露 session.hook；降级原因：监听注入仍可用；影响范围：用户输入创建 issue 不可用
    logger.warn("host exposes no session.hook; user input issue creation disabled");
  }

  return async () => {
    controller.abort();
    try {
      contextHook?.dispose?.();
    } catch {
      // Ignore dispose failures during shutdown.
    }
    await releaseHost(directory);
  };
}

// Default export: `server` for opencode 1.x, `id` + `setup` for opencode 2.x.
// A plain object works because the v2 `define()` helper is an identity function,
// so the entry has no runtime dependency on the host package.
export default {
  id: "issue-trigger",
  server,
  setup,
};