// Resumes a paused goal after a reminder is injected.
//
// Why: a paused goal makes the session stop as soon as the reminder is handled
// (opencode's goal plugin returns early from its idle hook while the goal is not
// active), so the injected reminder looks ineffective: the objective never
// advances again. Restarting the goal puts the reminder and the goal
// continuation in the same execution.
//
// A goal is paused without any user action whenever the server process restarts
// while the goal was active: the goal plugin stores a process boot id and
// settles the goal as "The server restarted while the goal was active" on the
// next turn. Installing this plugin (install.sh rewriting the plugin files) makes
// the host restart that process, so the reminder that follows an install is
// exactly the case this hook must cover.
//
// The goal command is the only surface a plugin has, so the resume is attempted
// without knowing the goal state first. The attempt is safe: measured on
// opencode 2.x (2026-11-20) `goal resume` on a session with no goal or with an
// active goal returns "No paused goal to resume." and changes nothing (status,
// rounds and updatedAt stay identical), while a paused goal becomes active with
// rounds+1 and its boot id rewritten to the current process — so it does not
// immediately look like "restarted while active" again.
//
// An earlier version gated the attempt on a `metadata.source === "goal"` message
// found in `session.context()`. That gate never fires in a long session: the
// context is trimmed to the recent window, so the original goal message (message
// 4 of 11k in the observed session) is long gone and the hook reported
// "no-goal" while the goal was in fact paused. The reminder was then delivered
// with the goal left paused, which is the defect this file now avoids.
function failureMessage(error) {
  const candidates = [error?.message, error?.data?.message, error?.cause?.message];
  const found = candidates.find((value) => typeof value === "string" && value.length > 0);
  if (found) return found;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

// Returns a function that resumes the session's paused goal, or a no-op when the
// host cannot run commands (opencode 1.x has no goal plugin).
export function createGoalResume({ resumeCommand, logger } = {}) {
  if (typeof resumeCommand !== "function") {
    return async () => ({ resumed: false, reason: "unsupported" });
  }

  return async function resumeGoal(sessionID) {
    try {
      await resumeCommand(sessionID);
      return { resumed: true };
    } catch (error) {
      const message = failureMessage(error);
      // [log-review] 预期内：会话没有暂停中的 goal（本就没有 goal，或 goal 仍在运行）；
      // 降级原因：该结果由宿主命令语义决定且不改变任何状态；影响范围：仅该次不推进 objective
      const noPausedGoal = message.includes("No paused goal to resume");
      logger?.debug(noPausedGoal ? "no paused goal to resume" : "goal resume failed", {
        sessionID,
        error: message,
      });
      return { resumed: false, reason: noPausedGoal ? "no-paused-goal" : "resume-failed" };
    }
  };
}
