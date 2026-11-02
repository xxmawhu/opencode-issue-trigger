// issue-trigger shared library (no runtime dependencies, Node/Bun built-ins only).
export { createIssueTrigger, buildIssuePrompt, PROMPT_TEMPLATE } from "./trigger.mjs";
export { createIssueWatcher } from "./watcher.mjs";
export { createInjector } from "./injector.mjs";
export { createSessionTracker } from "./session-tracker.mjs";
export { createStateStore } from "./state.mjs";
export { createLogger } from "./logger.mjs";
export { isIssueCandidateName, isActionableIssueFile } from "./system-file.mjs";