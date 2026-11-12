// issue-trigger shared library (no runtime dependencies, Node/Bun built-ins only).
export { createIssueTrigger, buildIssuePrompt, PROMPT_TEMPLATE } from "./trigger.mjs";
export { createIssueWatcher } from "./watcher.mjs";
export { createInjector } from "./injector.mjs";
export { createSessionTracker } from "./session-tracker.mjs";
export { createLogger } from "./logger.mjs";
export { isIssueFileName } from "./issue-file.mjs";
export {
  createIssueInputHandler,
  parseIssueCommand,
  matchesIssueCommand,
  formatTimestamp,
  ISSUE_COMMAND_PATTERN,
  INJECTED_PROMPT_PREFIX,
  INJECTED_PROMPT_PREFIXES,
} from "./issue-input.mjs";