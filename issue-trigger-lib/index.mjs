// issue-trigger shared library (no runtime dependencies, Node/Bun built-ins only).
export { createIssueTrigger, buildIssuePrompt, PROMPT_TEMPLATE } from "./trigger.mjs";
export { createGoalResume } from "./goal-resume.mjs";
export { createIssueWatcher } from "./watcher.mjs";
export { createInjector } from "./injector.mjs";
export { createSessionTracker } from "./session-tracker.mjs";
export { createLogger } from "./logger.mjs";
export { createFileSink, formatLine, hourlyLogPath } from "./log-file.mjs";
export { isIssueFileName } from "./issue-file.mjs";