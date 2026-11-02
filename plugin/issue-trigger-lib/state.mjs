// Durable per-issues-directory state: a file is injected at most once.
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = 1;

export function fileSignature(file) {
  try {
    const stat = statSync(file);
    if (!stat.isFile()) return undefined;
    return `${stat.dev}:${stat.ino}:${stat.size}:${Math.trunc(stat.mtimeMs)}`;
  } catch {
    return undefined;
  }
}

export function createStateStore({ issuesDir, stateDir } = {}) {
  const root = stateDir || join(homedir(), ".local", "state", "opencode-issue-trigger");
  const digest = createHash("sha1").update(issuesDir).digest("hex").slice(0, 16);
  const file = join(root, `state-${digest}.json`);
  let processed = new Map();

  function load() {
    try {
      if (!existsSync(file)) return false;
      const raw = JSON.parse(readFileSync(file, "utf8"));
      if (!raw || raw.version !== VERSION || raw.issuesDir !== issuesDir) return false;
      const entries = raw.processed && typeof raw.processed === "object" ? raw.processed : {};
      processed = new Map(
        Object.entries(entries).filter(([key, value]) => typeof key === "string" && typeof value === "string"),
      );
      return true;
    } catch {
      processed = new Map();
      return false;
    }
  }

  function save() {
    const payload = {
      version: VERSION,
      issuesDir,
      updatedAt: new Date().toISOString(),
      processed: Object.fromEntries(processed),
    };
    let tmp;
    try {
      if (!existsSync(root)) mkdirSync(root, { recursive: true });
      tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
      writeFileSync(tmp, JSON.stringify(payload, null, 2));
      renameSync(tmp, file);
      return true;
    } catch {
      try {
        if (existsSync(tmp)) unlinkSync(tmp);
      } catch {
        // Best effort only.
      }
      return false;
    }
  }

  function has(path) {
    return processed.has(path);
  }

  function mark(path) {
    processed.set(path, new Date().toISOString());
    return save();
  }

  return {
    load,
    save,
    has,
    mark,
    get size() {
      return processed.size;
    },
  };
}