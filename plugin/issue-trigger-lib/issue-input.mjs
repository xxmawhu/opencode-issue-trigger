// Parses a user message that starts with `issue` and materializes it as an
// issue file under <project>/issues.
//
// Message filters are intentionally narrow:
//   - synthetic parts are host-generated, never user input
//   - the ulw-pm host agent injects prompts of its own
//   - our own reminder text starts with INJECTED_PROMPT_PREFIX
// Without these filters the injection itself or an orchestrator prompt could
// create a new issue and retrigger injection indefinitely.
import { existsSync, linkSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const ISSUE_COMMAND_PATTERN = /^issue\b[:：]?\s*([\s\S]+)$/i;
export const INJECTED_PROMPT_PREFIX = "请分析./issues/";
export const HOST_INJECTION_AGENTS = ["ulw-pm"];

// Returns the issue body when the message starts with the command word
// `issue`, otherwise undefined. Leading blank lines are ignored so the command
// may start at the first non-empty line.
export function parseIssueCommand(text) {
  if (typeof text !== "string") return undefined;
  const normalized = text.replace(/^\s+/, "");
  const match = ISSUE_COMMAND_PATTERN.exec(normalized);
  if (!match) return undefined;
  const body = match[1].trim();
  return body.length > 0 ? body : undefined;
}

// True when the message is an issue command even if its body is empty.
export function matchesIssueCommand(text) {
  if (typeof text !== "string") return false;
  return /^issue\b[:：]?/i.test(text.replace(/^\s+/, ""));
}

function slugify(body) {
  const firstLine = body
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0);
  if (!firstLine) return "issue";
  const slug = firstLine
    .slice(0, 24)
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug.length > 0 ? slug : "issue";
}

function two(value) {
  return String(value).padStart(2, "0");
}

// Local wall-clock timestamp: the issue name reads naturally in the same
// timezone the user typed the message in.
export function formatTimestamp(date) {
  return (
    `${date.getFullYear()}${two(date.getMonth() + 1)}${two(date.getDate())}` +
    `_${two(date.getHours())}${two(date.getMinutes())}${two(date.getSeconds())}`
  );
}

// Publishes the temp file under the first free name. hard link is atomic and
// fails with EEXIST instead of overwriting (rename would replace a concurrent
// writer's issue). The loop terminates: every iteration increments the suffix,
// candidate names are distinct, and a directory holds finitely many files.
function publish(issuesDir, base, temp) {
  for (let index = 1; ; index += 1) {
    const name = index === 1 ? `${base}.md` : `${base}_${index}.md`;
    try {
      linkSync(temp, join(issuesDir, name));
      return name;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }
}

export function createIssueInputHandler({
  issuesDir,
  logger,
  now = () => new Date(),
  pid = process.pid,
  maxTrackedMessages = 1000,
} = {}) {
  if (typeof issuesDir !== "string" || issuesDir.length === 0) {
    throw new TypeError("createIssueInputHandler requires issuesDir");
  }

  const seen = new Set();

  function remember(messageID) {
    if (typeof messageID !== "string" || messageID.length === 0) return true;
    if (seen.has(messageID)) return false;
    seen.add(messageID);
    if (seen.size > maxTrackedMessages) {
      const oldest = seen.values().next().value;
      seen.delete(oldest);
    }
    return true;
  }

  function handle({ text, messageID, agent, synthetic } = {}) {
    if (synthetic === true) return { created: false, reason: "synthetic" };
    if (HOST_INJECTION_AGENTS.includes(agent)) return { created: false, reason: "host-agent" };
    if (typeof text !== "string") return { created: false, reason: "no-text" };

    const trimmed = text.trimStart();
    if (trimmed.startsWith(INJECTED_PROMPT_PREFIX)) {
      return { created: false, reason: "injected-prompt" };
    }

    if (!matchesIssueCommand(trimmed)) return { created: false, reason: "not-an-issue-command" };

    const body = parseIssueCommand(trimmed);
    if (!body) {
      // WARN: recoverable malformed input; the user is told nothing else.
      logger?.warn("issue command has an empty body; ignored", { messageID });
      return { created: false, reason: "empty-body" };
    }
    if (!remember(messageID)) return { created: false, reason: "duplicate" };

    let isDirectory = false;
    try {
      isDirectory = existsSync(issuesDir) && statSync(issuesDir).isDirectory();
    } catch {
      isDirectory = false;
    }
    if (!isDirectory) {
      // WARN: recoverable, the project may not manage issues; never create the
      // directory on the user's behalf.
      logger?.warn("issues directory is missing; issue command ignored", { issuesDir });
      return { created: false, reason: "no-issues-dir" };
    }

    const base = `${formatTimestamp(now())}_${slugify(body)}`;
    // The temp name must not end with .md: the watcher would dispatch a
    // half-written file.
    const temp = join(issuesDir, `.${base}.md.tmp-${pid}`);
    let name;
    try {
      writeFileSync(temp, `${body}\n`, "utf8");
      name = publish(issuesDir, base, temp);
    } catch (error) {
      try {
        unlinkSync(temp);
      } catch {
        // Ignore cleanup failures; the temp file is invisible to the watcher.
      }
      logger?.error("failed to write issue file from user input", { issuesDir, error: String(error) });
      return { created: false, reason: "write-failed" };
    }
    try {
      unlinkSync(temp);
    } catch {
      // The published link is complete; a leftover temp file is harmless.
    }

    const target = join(issuesDir, name);
    logger?.info("issue created from user input", { path: target });
    return { created: true, path: target };
  }

  return { handle, parseIssueCommand };
}