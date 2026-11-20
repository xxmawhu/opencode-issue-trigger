// Resumes a paused goal after a reminder is injected.
//
// Why: a paused goal makes the session stop as soon as the reminder is handled
// (opencode's goal plugin returns early from its idle hook while the goal is not
// active), so the injected reminder looks ineffective: the objective never
// advances again. Restarting the goal puts the reminder and the goal
// continuation in the same execution.
//
// Detection uses host APIs only (no database access, no goal-plugin storage):
//   - a context message carrying `metadata.source === "goal"` means the session
//     has a goal;
//   - the goal's status is not readable from a plugin: the state lives in the
//     goal plugin's own storage, and its "a goal is active" reminder is spliced
//     into the model call without ever being persisted, so it is absent from
//     `session.context()` even while the goal is active.
//
// So the resume is attempted and a failure is treated as "the goal is active or
// complete". The failed attempt is remembered by (goal id, newest goal message
// id): every continuation the goal loop sends is a new message and therefore
// retries, while a completed goal that sends nothing more costs exactly one
// failed command instead of one per reminder.
function goalHistory(messages) {
  let goalID;
  let newestMessageID;
  let sawGoal = false;
  for (const message of messages) {
    const metadata = message?.metadata;
    if (metadata?.source !== "goal" && typeof metadata?.goalID !== "string") continue;
    sawGoal = true;
    if (typeof metadata?.goalID === "string") goalID = metadata.goalID;
    if (typeof message?.id === "string") newestMessageID = message.id;
  }
  return sawGoal ? { goalID, newestMessageID } : undefined;
}

// Returns a function that resumes the session's paused goal, or a no-op when the
// host cannot report context or run commands (opencode 1.x has no goal plugin).
export function createGoalResume({ readContext, resumeCommand, logger } = {}) {
  if (typeof readContext !== "function" || typeof resumeCommand !== "function") {
    return async () => ({ resumed: false, reason: "unsupported" });
  }
  const resumeFailed = new Set();

  return async function resumeGoal(sessionID) {
    let messages;
    try {
      messages = await readContext(sessionID);
    } catch (error) {
      // [log-review] 预期内：会话正忙或上下文不可读；降级原因：提醒已投递，跳过本次 goal 恢复；
      // 影响范围：仅该次不自动推进 objective
      logger?.debug("goal state unavailable; skipping resume", { sessionID, error: String(error) });
      return { resumed: false, reason: "context-unavailable" };
    }
    if (!Array.isArray(messages)) return { resumed: false, reason: "context-unavailable" };

    const history = goalHistory(messages);
    if (!history) return { resumed: false, reason: "no-goal" };

    const key = `${history.goalID ?? "unknown"}:${history.newestMessageID ?? "unknown"}`;
    if (resumeFailed.has(key)) return { resumed: false, reason: "resume-unavailable" };
    try {
      await resumeCommand(sessionID);
      resumeFailed.delete(key);
      return { resumed: true };
    } catch (error) {
      // [log-review] 预期内：goal 已完成或本就活跃（无暂停的 goal 可恢复）；降级原因：提醒已投递且不重试；
      // 影响范围：该 goal 在本条 goal 消息周期内不再尝试恢复
      resumeFailed.add(key);
      logger?.debug("goal resume skipped", { sessionID, goalID: history.goalID, error: String(error) });
      return { resumed: false, reason: "resume-failed" };
    }
  };
}
