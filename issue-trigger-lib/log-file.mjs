// Hourly log file sink for the v2 adapter.
//
// The v2 host gives plugins no `app.log` endpoint, and a standalone server runs
// with stderr on /dev/null (verified 2026-11-24: /proc/<pid>/fd/2 -> /dev/null,
// `[issue-trigger]` count 0 in opencode.log). Console-only logging therefore
// vanished exactly when the plugin failed silently (location idle eviction, issue
// 891a50f5), so entries go to the project's own log directory instead:
//   <project>/log/issue-trigger.YYYYMMDDTHH.log
// Rotation is hourly to match the platform Python log convention; the file is
// appended per line so a crash cannot lose earlier entries. Any filesystem error
// falls back to stderr and never throws into the plugin call path.
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const PREFIX = "issue-trigger";

function pad(value) {
  return String(value).padStart(2, "0");
}

// Local-time stamp; the platform keeps log file names in local time.
export function hourlyLogPath(logDir, date, prefix = PREFIX) {
  const stamp = `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}T${pad(date.getHours())}`;
  return join(logDir, `${prefix}.${stamp}.log`);
}

function formatTime(date) {
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  const clock = `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  return `${day} ${clock}`;
}

function formatExtra(extra) {
  if (extra === undefined) return "";
  try {
    return ` ${JSON.stringify(extra)}`;
  } catch {
    // Circular or non-serializable payloads must not drop the log line.
    return " <extra not serializable>";
  }
}

export function formatLine(date, level, message, extra) {
  return `[${formatTime(date)}] [${level}] [${PREFIX}] ${message}${formatExtra(extra)}`;
}

export function createFileSink({
  logDir,
  prefix = PREFIX,
  now = () => new Date(),
  appendFile = appendFileSync,
  makeDir = mkdirSync,
  stderr = (line) => console.error(line),
} = {}) {
  if (typeof logDir !== "string" || logDir.length === 0) {
    throw new TypeError("createFileSink requires logDir");
  }
  return (level, message, extra) => {
    const at = now();
    const line = formatLine(at, level, message, extra);
    try {
      makeDir(logDir, { recursive: true });
      appendFile(hourlyLogPath(logDir, at, prefix), `${line}\n`);
    } catch {
      try {
        stderr(line);
      } catch {
        // Logging must never break injection, even when stderr is closed.
      }
    }
  };
}