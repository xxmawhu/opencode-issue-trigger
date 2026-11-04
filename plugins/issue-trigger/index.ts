// OpenCode v2 plugin entry. Installed as ~/.config/opencode/plugins/issue-trigger/index.ts
// define() from @opencode/plugin is an identity function, so the plain object below
// avoids any runtime dependency on the host package.
import { join } from "node:path";
import { createIssueInputHandler, createIssueTrigger, createLogger } from "./issue-trigger-lib/index.mjs";

const issueTriggerPlugin = {
  id: "issue-trigger",
  async setup(ctx) {
    // Logging goes to opencode's own log sink; the plugin never owns a log file.
    const appLog = ctx?.app?.log ?? ctx?.client?.app?.log;
    const appLogHost = ctx?.app?.log ? ctx.app : ctx?.client?.app;
    const logger = createLogger({
      sink: (level, message, extra) => {
        if (typeof appLog === "function") {
          return appLog.call(appLogHost, {
            body: {
              service: "issue-trigger",
              level,
              message,
              ...(extra === undefined ? {} : { extra }),
            },
          });
        }
        // Fallback keeps records in opencode's own captured output when the
        // host exposes no log API.
        console.error(`[issue-trigger] ${level}: ${message}`, extra ?? "");
        return undefined;
      },
    });
    const directory = ctx?.location?.directory || process.cwd();
    const controller = new AbortController();
    const issuesDir = join(directory, "issues");
    const inputHandler = createIssueInputHandler({ issuesDir, logger });

    const trigger = createIssueTrigger({
      issuesDir,
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
        if (typeof ctx?.session?.prompt !== "function") {
          throw new Error("session.prompt is unavailable");
        }
        await ctx.session.prompt({ sessionID, text });
      },
    });

    await trigger.start();
    logger.info("issue-trigger loaded", { issuesDir: trigger.issuesDir });

    // v2 equivalent of the v1 chat.message hook: prompt admission fires for
    // user input before it is persisted. Synthetic messages never reach it.
    let promptHookRegistered = false;
    if (typeof ctx?.session?.hook === "function") {
      try {
        await ctx.session.hook("prompt", (event) => {
          try {
            inputHandler.handle({
              text: event?.prompt?.text,
              messageID: event?.messageID,
            });
          } catch (error) {
            logger.error("failed to handle user input", { error: String(error) });
          }
        });
        promptHookRegistered = true;
      } catch (error) {
        // [log-review] 预期内：旧 v2 宿主未提供 prompt hook；降级原因：事件流可还原最终消息；影响范围：仅识别延迟到会话空闲
        logger.warn("prompt hook unavailable; using event stream fallback", { error: String(error) });
      }
    }

    // Fallback for hosts without the prompt hook: remember user message parts
    // and parse them once the turn goes idle, so the text is complete.
    const userMessages = new Set();
    const pendingParts = new Map();

    function noteInputEvent(event) {
      const type = event?.type;
      const properties = event?.properties ?? {};
      if (type === "message.updated") {
        const info = properties.info;
        const id = info?.id ?? properties.messageID;
        if (id && info?.role === "user") userMessages.add(id);
        return;
      }
      if (type === "message.part.updated") {
        const part = properties.part;
        if (!part || part.type !== "text" || typeof part.text !== "string") return;
        if (part.synthetic === true) return;
        if (part.messageID && !userMessages.has(part.messageID)) return;
        const key = part.messageID ?? part.id;
        if (!key) return;
        const bucket = pendingParts.get(key) ?? [];
        const index = bucket.findIndex((item) => item.id === part.id);
        if (index >= 0) bucket[index] = part;
        else bucket.push(part);
        pendingParts.set(key, bucket);
        return;
      }
      if (type !== "session.idle") return;
      const sessionID = properties.sessionID;
      for (const [messageID, parts] of pendingParts) {
        pendingParts.delete(messageID);
        userMessages.delete(messageID);
        for (const part of parts) {
          if (sessionID && part.sessionID && part.sessionID !== sessionID) continue;
          const result = inputHandler.handle({
            text: part.text,
            messageID,
            synthetic: part.synthetic === true,
          });
          if (result.created) break;
        }
      }
    }

    const events =
      typeof ctx?.event?.subscribe === "function" ? ctx.event.subscribe({ signal: controller.signal }) : undefined;
    if (events) {
      void (async () => {
        try {
          for await (const event of events) {
            trigger.noteEvent(event);
            if (!promptHookRegistered) noteInputEvent(event);
          }
        } catch (error) {
          // [log-review] 预期内：插件卸载或连接重建；降级原因：注入不依赖该事件流；影响范围：会话跟踪退化为最近会话
          if (!controller.signal.aborted) logger.warn("event stream ended", { error: String(error) });
        }
      })();
    }

    return async () => {
      controller.abort();
      await trigger.stop();
    };
  },
};

// Default export is required by the v2 loader contract.
export default issueTriggerPlugin;