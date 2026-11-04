// OpenCode v2 plugin entry. Installed as ~/.config/opencode/plugins/issue-trigger/index.ts
// The host calls this function with { client, directory, ... } and uses the
// returned object as the hook table. `chat.message` is the prompt admission
// hook; `event` keeps the session tracker fed for injection.
import { join } from "node:path";
import { createIssueInputHandler, createIssueTrigger, createLogger } from "./issue-trigger-lib/index.mjs";

export const IssueTrigger = async (ctx) => {
  const client = ctx?.client;
  const directory = ctx?.directory || ctx?.location?.directory || process.cwd();
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

  await trigger.start();
  logger.info("issue-trigger loaded", { issuesDir: trigger.issuesDir });

  return {
    // User input hook. Parts that the host synthesized are ignored so only
    // what the user typed is parsed. The agent name is intentionally not used:
    // hosts may run every session under the same agent (for example `ulw-pm`),
    // so it cannot distinguish user input from plugin injections.
    "chat.message": async (input, output) => {
      try {
        const parts = Array.isArray(output?.parts) ? output.parts : [];
        for (const part of parts) {
          if (part?.type !== "text" || typeof part.text !== "string") continue;
          const result = inputHandler.handle({
            text: part.text,
            messageID: input?.messageID,
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
};

// Default export is required by the v2 loader contract; named export keeps the
// same function available to hosts that resolve by name.
export default IssueTrigger;