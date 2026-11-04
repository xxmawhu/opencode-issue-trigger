// OpenCode v1 plugin entry. Installed as ~/.config/opencode/plugin/issue-trigger.ts
// Only plugin functions are exported: the v1 loader requires every export of a
// legacy plugin module to be a plugin function.
import { join } from "node:path";
import { createIssueInputHandler, createIssueTrigger, createLogger } from "./issue-trigger-lib/index.mjs";

function createPlugin(input) {
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

  const issuesDir = join(directory, "issues");
  const inputHandler = createIssueInputHandler({ issuesDir, logger });

  const trigger = createIssueTrigger({
    issuesDir,
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

  trigger.start().catch((error) => {
    logger.error("failed to start issue-trigger", { error: String(error) });
  });

  logger.info("issue-trigger loaded", { issuesDir: trigger.issuesDir });

  return {
    // v1 hook for user input. The host calls it for user messages; parts that
    // the host synthesized are ignored so only what the user typed is parsed.
    "chat.message": async (input, output) => {
      try {
        const parts = Array.isArray(output?.parts) ? output.parts : [];
        for (const part of parts) {
          if (part?.type !== "text" || typeof part.text !== "string") continue;
          const result = inputHandler.handle({
            text: part.text,
            messageID: input?.messageID,
            agent: input?.agent,
            synthetic: part.synthetic === true,
          });
          if (result.created) break;
        }
      } catch (error) {
        // A parsing failure must never break the user's message.
        logger.error("failed to handle user input", { error: String(error) });
      }
    },
    event: async ({ event }) => {
      trigger.noteEvent(event);
    },
    dispose: async () => {
      await trigger.stop();
    },
  };
}

// Default export is required by the v1 loader contract; named export keeps the
// same function available to hosts that resolve by name.
export const Plugin = createPlugin;
export default createPlugin;