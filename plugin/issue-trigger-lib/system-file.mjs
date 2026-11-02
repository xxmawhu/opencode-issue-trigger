// issue file classification: skip process artifacts and already-closed issues.
// Prefix list follows the platform rule for system-generated issue files.
import { closeSync, openSync, readSync } from "node:fs";
import { join } from "node:path";

export const SYSTEM_ISSUE_PREFIXES = [
  "ULWPM-process-",
  "reply-",
  "reminder-",
  "cleanup-reminder-",
  "backlog-",
  "backlog-alert-",
  "stuck-",
  "cleanup-",
  "unprocessed-",
  "alert-",
  "alert-scan-issue-",
  "consync-backlog",
];

const IGNORED_NAMES = new Set([".gitkeep", ".DS_Store"]);
const IGNORED_SUFFIXES = [".tmp", ".temp", ".part", ".crdownload", ".swp", ".swo", "~"];
const FRONTMATTER_BLOCK_RE = /^---\r?\n([\s\S]*?)\r?\n---/;
const TERMINAL_STATUSES = new Set([
  "escalated",
  "confirmed",
  "rejected",
  "fixed",
  "closed",
  "archived",
]);

export function isIssueCandidateName(name) {
  if (typeof name !== "string" || name.length === 0) return false;
  if (name.startsWith(".")) return false;
  if (IGNORED_NAMES.has(name)) return false;
  if (name.includes("/") || name.includes("\\")) return false;
  if (!name.endsWith(".md")) return false;
  if (IGNORED_SUFFIXES.some((suffix) => name.endsWith(suffix))) return false;
  return true;
}

export function isAiRunCmdFrontmatter(yaml) {
  if (!yaml) return false;
  const lines = yaml.split(/\r?\n/).map((line) => line.trim());
  const sourceLine = lines.find((line) => /^source:\s*/.test(line));
  if (sourceLine) {
    const value = sourceLine
      .replace(/^source:\s*/, "")
      .replace(/\s+#.*$/, "")
      .replace(/^['"]|['"]$/g, "")
      .trim();
    if (value === "ai-run-cmd") return true;
  }
  const tagsLine = lines.find((line) => /^tags:\s*/.test(line));
  if (tagsLine) {
    const value = tagsLine
      .replace(/^tags:\s*/, "")
      .replace(/\s+#.*$/, "")
      .trim();
    const tags = value
      .replace(/^\[|\]$/g, "")
      .split(",")
      .map((tag) => tag.trim().replace(/^['"]|['"]$/g, "").trim());
    if (tags.includes("ai-run-cmd")) return true;
  }
  return false;
}

export function isSystemIssueContent(content) {
  if (!content) return false;
  const match = content.match(FRONTMATTER_BLOCK_RE);
  if (!match) return false;
  return isAiRunCmdFrontmatter(match[1] ?? "");
}

export function extractIssueStatus(content) {
  if (!content) return undefined;
  const match = content.match(FRONTMATTER_BLOCK_RE);
  if (!match) return undefined;
  const statusLine = match[1]
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => /^status:\s*/.test(line));
  if (!statusLine) return undefined;
  return statusLine
    .replace(/^status:\s*/, "")
    .replace(/\s+#.*$/, "")
    .replace(/^['"]|['"]$/g, "")
    .trim()
    .toLowerCase();
}

export function readFileHeadSync(filePath, bytes = 4096) {
  let fd;
  try {
    fd = openSync(filePath, "r");
    const buffer = Buffer.alloc(bytes);
    const bytesRead = readSync(fd, buffer, 0, bytes, 0);
    return buffer.toString("utf-8", 0, bytesRead);
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

export function isActionableIssueFile(dir, name) {
  if (!isIssueCandidateName(name)) return false;
  if (SYSTEM_ISSUE_PREFIXES.some((prefix) => name.startsWith(prefix))) return false;

  const content = readFileHeadSync(join(dir, name));
  if (content === null) return true;
  if (isSystemIssueContent(content)) return false;
  const status = extractIssueStatus(content);
  if (status && TERMINAL_STATUSES.has(status)) return false;
  return true;
}