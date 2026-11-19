#!/usr/bin/env bash
# Daily audit of issue-reminder delivery across every AI user's opencode
# workspaces, plus the dispatch side (scan_issue probe failures).
#
# Zero-argument and cron-safe: every path and threshold below is the default, so
# the crontab entry stays "absolute command + log redirect" with no parameters.
#
# What it answers, once per day, in log/injection-audit.YYYYMMDD.log:
#   1. reminder queue health: queued / injected / no-session / dropped per project
#   2. findings: projects that dropped a reminder, or waited for a session and
#      never injected it inside the window
#   3. dispatch health: probe timeouts and fail-closed skips in the newest
#      scan_issue hourly log
#   4. runtime drift: scan_issue process start time vs published binary mtime,
#      plus [SELF-CHECK] log evidence, so a published-but-not-running build is
#      visible every day instead of only when someone notices stale behavior
#
# A finding writes ./issues/<ts>_injection-audit.md so the reminder plugin picks
# it up like any other issue; one open audit issue at a time (deduplicated).
# Runtime drift is additionally rate-limited to one report per 7 days: it stays
# blocked until the owning user restarts the process, and a daily reminder adds
# no information.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HOME_ROOTS=(/mnt/beegfs_data/usr/maxx/dev /mnt/beegfs_data/usr/maxx/quant)
SCAN_LOG_DIR="/mnt/beegfs_data/usr/maxx/regular_task/scan_issue/log"
SCAN_PUBLISHED="/data/alpha/share/scan_issue/scan_issue"
SCAN_DRIFT_MARKER="${ROOT}/.var/scan-drift-last-report"
# Baseline captured the first time drift is seen: the hourly probe-timeout count
# and new-classification hits. After activation the same metrics are emitted once
# as SCANACTIVE, so "did the new build actually help" needs no manual comparison.
SCAN_DRIFT_BASELINE="${ROOT}/.var/scan-drift-baseline"
# Records the newest published fingerprint that the running process already
# covers, so "the fix is finally live" is a log line instead of a manual diff.
SCAN_ACTIVATED="${ROOT}/.var/scan-activated"
# A published build older than the process start is normal; the reverse means the
# running image predates what is on disk. Ignore a 30-minute window so a build
# that was just published, and is about to be picked up, is not reported.
SCAN_DRIFT_GRACE=1800
SCAN_DRIFT_REPORT_DAYS=7
LOG_DIR="${ROOT}/log"
LOG_FILE="${LOG_DIR}/injection-audit.$(date +%Y%m%d).log"
ISSUES_DIR="${ROOT}/issues"
# Workspace discovery walks two whole user trees (~4min on beegfs), so it is
# cached and refreshed weekly; the reminder events themselves are re-read daily.
WS_CACHE="${ROOT}/data/workspaces.txt"
CACHE_MAX_AGE_DAYS=7
TMP_DIR=""

# Window in days for "recent" log files and events.
WINDOW_DAYS=2
# A project that waited this many poll cycles (one log line per ~60s) without a
# single injection in the window is reported: the reminder is not being delivered.
NO_SESSION_ALERT=12
RETAIN_DAYS=30
# 30-day observation window for the reminder-queue fix. A WEEKLY aggregate is
# written every 7th day, and one VERDICT is written on the closing day, so the
# observation completes through the same cron entry with no manual step.
OBSERVE_START="2026-11-19"
OBSERVE_END="2026-12-19"
OBSERVE_FINAL_MARKER="${ROOT}/.var/observation-verdict"

log() {
  local level="$1"
  local message="$2"
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}" >>"${LOG_FILE}"
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

# Modern CLI is required; the platform ships fdfind and rg. A missing tool is a
# hard error: silently falling back to find/grep changes semantics (hidden dirs,
# mtime handling) and would report misleading zeros.
require_tools() {
  local tool
  for tool in fdfind rg; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      log ERROR "required tool missing: ${tool}"
      exit 1
    fi
  done
}

# Refresh the workspace list when the cache is missing or older than the
# retention window. The write is atomic (same directory, mv) so a crashed refresh
# cannot leave a half list behind.
discover_workspaces() {
  mkdir -p "$(dirname "${WS_CACHE}")"
  if [[ -f "${WS_CACHE}" && "${WS_CACHE}" -nt "${TMP_DIR}/cache-cutoff" ]]; then
    log INFO "workspace cache fresh: ${WS_CACHE}"
    return 0
  fi
  fdfind --hidden --type d --glob 'opencode-workspaces' --max-depth 8 "${HOME_ROOTS[@]}" \
    2>/dev/null >"${WS_CACHE}.tmp.$$"
  mv "${WS_CACHE}.tmp.$$" "${WS_CACHE}"
  log INFO "workspace cache refreshed: $(wc -l <"${WS_CACHE}") entries"
}

# Log files sit at two known depths under a workspace; enumerating those globs is
# O(directories) instead of a full tree walk.
collect_reminder_counts() {
  local ws_file="$1"
  local project log_file
  log INFO "workspaces scanned: $(wc -l <"${ws_file}")"
  while IFS= read -r ws; do
    project="${ws%/.local/share/opencode-workspaces}"
    for log_file in "${ws}"/*/opencode/log/*.log \
      "${ws}"/*/sessions/*/opencode/log/*.log; do
      [[ -f "${log_file}" ]] || continue
      [[ "${log_file}" -nt "${TMP_DIR}/cutoff" ]] || continue
      rg --no-filename --no-line-number \
        -e 'message="queued issue injection"' \
        -e 'message="injected issue prompt"' \
        -e 'message="no injectable session yet; issue stays queued"' \
        -e 'message="dropping issue injection"' \
        "${log_file}" 2>/dev/null
    done | awk -v cutoff="${CUTOFF}" -v project="${project}" '
      {
        match($0, /timestamp=[^ ]+/)
        if (RSTART == 0) next
        ts = substr($0, RSTART + 10, 16)
        if (ts < cutoff) next
        if ($0 ~ /queued issue injection/) queued++
        else if ($0 ~ /injected issue prompt/) injected++
        else if ($0 ~ /no injectable session yet/) nosession++
        else if ($0 ~ /dropping issue injection/) dropped++
      }
      END {
        if (queued + injected + nosession + dropped == 0) exit
        printf "%s\t%d\t%d\t%d\t%d\n", project, queued, injected, nosession, dropped
      }'
  done <"${ws_file}" >>"${TMP_DIR}/counts.tsv"
}

summarize_reminders() {
  local counts="${TMP_DIR}/counts.tsv"
  touch "${counts}"
  awk -F'\t' '
    {
      q += $2; i += $3; n += $4; d += $5
      if ($5 > 0) printf "DROPPED\t%s\tqueued=%d injected=%d nosession=%d dropped=%d\n", $1, $2, $3, $4, $5
      else if ($3 == 0 && $4 >= alert) printf "STALLED\t%s\tqueued=%d injected=%d nosession=%d dropped=%d\n", $1, $2, $3, $4, $5
    }
    END {
      printf "TOTAL\tqueued=%d injected=%d nosession=%d dropped=%d\n", q, i, n, d
      if (d > 0) exit 1
    }' alert="${NO_SESSION_ALERT}" "${counts}" >"${TMP_DIR}/findings.txt"
}

summarize_dispatch() {
  local latest
  latest="$(newest_scan_log)"
  if [[ -z "${latest}" ]]; then
    log ERROR "no scan_issue log found in ${SCAN_LOG_DIR}"
    return 0
  fi
  awk '
    /probe failed \(exit=124\)/ { t124++ }
    /probe failed \(exit=255\)/ { t255++ }
    /opencode already running for project/ { running++ }
    /skipping batch dispatch/ { skipped++ }
    END {
      printf "DISPATCH\tfile=%s exit124=%d exit255=%d running=%d skipped=%d\n", FILENAME, t124, t255, running, skipped
    }' "${latest}" >>"${TMP_DIR}/findings.txt"
}

# Published build vs running image. The process may belong to another user, so
# only read-only facts are used: /proc start time (etimes) and the published
# mtime. [SELF-CHECK] log lines prove the new self-check code is running.
# Log files are named either scan_issueYYYYMMDDHH.log (old) or
# scan_issue.YYYYMMDDTHH.log (new self-check build), so ordering is by mtime.
scan_logs_by_mtime() {
  fdfind --type f --glob 'scan_issue*.log' "${SCAN_LOG_DIR}" 2>/dev/null |
    xargs -r stat -c '%Y %n' | sort -n | cut -d' ' -f2-
}

newest_scan_log() {
  scan_logs_by_mtime | tail -1
}

# Newest *complete* hourly log: comparing an in-progress hour against a full hour
# would understate the post-activation rate, so the current hour is excluded.
newest_complete_scan_log() {
  local current_hour f digits last=""
  current_hour="$(date +%Y%m%d%H)"
  while IFS= read -r f; do
    digits="$(basename "${f}")"
    digits="${digits//[^0-9]/}"
    [[ "${digits}" == "${current_hour}" ]] && continue
    last="${f}"
  done < <(scan_logs_by_mtime)
  printf '%s' "${last}"
}

# Probe timeouts are the failure the published fix classifies; new-classification
# strings prove the new build is the one writing them.
scan_log_metric() {
  local file="$1" field="$2"
  if [[ ! -f "${file}" ]]; then
    printf '0'
    return 0
  fi
  case "${field}" in
  exit124) awk '/probe failed \(exit=124\)/ { n++ } END { print n+0 }' "${file}" ;;
  newclass) awk '/probe-expired|ssh-unreachable/ { n++ } END { print n+0 }' "${file}" ;;
  *) printf '0' ;;
  esac
}

# Read the first "key=value" line from the drift baseline.
baseline_field() {
  local file="$1" key="$2" line value
  while IFS= read -r line; do
    case "${line}" in
    "${key}="*)
      value="${line#*=}"
      printf '%s' "${value%% *}"
      return 0
      ;;
    esac
  done <"${file}"
  return 1
}

check_scan_runtime() {
  local pub_mtime now pid etimes start_epoch drift=0 selfcheck=0 start_iso pub_iso
  local recorded
  local latest exit124 newclass baseline_new act_epoch latest_hour act_hour
  local -a logs=()

  if [[ ! -f "${SCAN_PUBLISHED}" ]]; then
    printf 'SCANSTOPPED\tstate=published-missing\tpath=%s\n' "${SCAN_PUBLISHED}" >>"${TMP_DIR}/findings.txt"
    return 0
  fi

  pub_mtime="$(stat -c %Y "${SCAN_PUBLISHED}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  pid="$(pgrep -f "^${SCAN_PUBLISHED} " 2>/dev/null | head -1)"
  if [[ -z "${pid}" ]]; then
    printf 'SCANSTOPPED\tstate=no-process\tpublished_mtime=%s\n' \
      "$(date -d "@${pub_mtime}" '+%Y-%m-%dT%H:%M:%S')" >>"${TMP_DIR}/findings.txt"
    return 0
  fi

  etimes="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ')"
  [[ "${etimes}" =~ ^[0-9]+$ ]] || etimes=0
  start_epoch=$((now - etimes))
  ((pub_mtime - start_epoch > SCAN_DRIFT_GRACE)) && drift=1

  while IFS= read -r f; do logs+=("${f}"); done < <(scan_logs_by_mtime | tail -3)
  if ((${#logs[@]} > 0)) && rg -q -e '\[SELF-CHECK\]' "${logs[@]}" 2>/dev/null; then
    selfcheck=1
  fi

  start_iso="$(date -d "@${start_epoch}" '+%Y-%m-%dT%H:%M:%S')"
  pub_iso="$(date -d "@${pub_mtime}" '+%Y-%m-%dT%H:%M:%S')"
  latest="$(newest_complete_scan_log)"
  exit124="$(scan_log_metric "${latest}" exit124)"
  newclass="$(scan_log_metric "${latest}" newclass)"
  printf 'SCANRUNTIME\tpid=%s start=%s published=%s drift=%d selfcheck=%d\n' \
    "${pid}" "${start_iso}" "${pub_iso}" "${drift}" "${selfcheck}" >>"${TMP_DIR}/findings.txt"

  # A process that already covers the published build (drift=0) with the
  # self-check code alive means the publish is live. One line per published
  # fingerprint, so an activation is recorded without anyone comparing hashes.
  if ((drift == 0 && selfcheck == 1)); then
    recorded="$(baseline_field "${SCAN_ACTIVATED}" published_epoch 2>/dev/null || true)"
    if [[ -z "${recorded}" ]] || ((pub_mtime > recorded)); then
      printf 'published_epoch=%s published=%s pid=%s started=%s at=%s\n' \
        "${pub_mtime}" "${pub_iso}" "${pid}" "${start_iso}" "$(date -d "@${now}" '+%Y-%m-%dT%H:%M:%S')" \
        >"${SCAN_ACTIVATED}.tmp.$$" &&
        mv -f "${SCAN_ACTIVATED}.tmp.$$" "${SCAN_ACTIVATED}"
      printf 'SCANACTIVATED\tpid=%s started=%s published=%s\n' \
        "${pid}" "${start_iso}" "${pub_iso}" >>"${TMP_DIR}/findings.txt"
    fi
  fi

  if ((drift == 1 && selfcheck == 0)); then
    printf 'SCANDRIFT\tpid=%s running_since=%s published_mtime=%s selfcheck=0\n' \
      "${pid}" "${start_iso}" "${pub_iso}" >>"${TMP_DIR}/findings.txt"
    if [[ ! -f "${SCAN_DRIFT_BASELINE}" ]]; then
      baseline_new="${SCAN_DRIFT_BASELINE}.tmp.$$"
      printf 'published_mtime=%s exit124=%s newclass=%s file=%s at=%s\n' \
        "${pub_iso}" "${exit124}" "${newclass}" "${latest}" "${start_iso}" >"${baseline_new}"
      mv "${baseline_new}" "${SCAN_DRIFT_BASELINE}"
    fi
  elif ((drift == 0 && selfcheck == 1)) && [[ -f "${SCAN_DRIFT_BASELINE}" ]]; then
    act_epoch="$(baseline_field "${SCAN_DRIFT_BASELINE}" activated_at || true)"
    if [[ -z "${act_epoch}" ]]; then
      act_epoch="${start_epoch}"
      printf 'activated_at=%s pid=%s\n' "${act_epoch}" "${pid}" >>"${SCAN_DRIFT_BASELINE}"
      printf 'SCANACTIVE_PENDING\tpid=%s started=%s note=waiting for a complete post-activation hour\n' \
        "${pid}" "${start_iso}" >>"${TMP_DIR}/findings.txt"
    fi
    if ! baseline_field "${SCAN_DRIFT_BASELINE}" verified_at >/dev/null 2>&1; then
      latest_hour="$(basename "${latest}")"
      latest_hour="${latest_hour//[^0-9]/}"
      act_hour="$(date -d "@${act_epoch}" +%Y%m%d%H)"
      if [[ -n "${latest_hour}" && -n "${act_hour}" ]] && ((latest_hour >= act_hour)); then
        # A complete hour that begins with the activated build: same basis as the
        # baseline hour, so the two numbers are comparable.
        exit124="$(scan_log_metric "${latest}" exit124)"
        newclass="$(scan_log_metric "${latest}" newclass)"
        printf 'verified_at=%s exit124=%s newclass=%s file=%s\n' \
          "$(date -d "@${now}" '+%Y-%m-%dT%H:%M:%S')" "${exit124}" "${newclass}" "${latest}" \
          >>"${SCAN_DRIFT_BASELINE}"
        printf 'SCANACTIVE\tpid=%s started=%s exit124_now=%s newclass_now=%s baseline=%s\n' \
          "${pid}" "${start_iso}" "${exit124}" "${newclass}" "${SCAN_DRIFT_BASELINE}" >>"${TMP_DIR}/findings.txt"
      else
        log INFO "post-activation metrics pending: newest complete hour ${latest_hour:-none} < activation hour ${act_hour}"
      fi
    fi
  fi
}

write_issue() {
  local stamp body
  if compgen -G "${ISSUES_DIR}/*_injection-audit.md" >/dev/null; then
    log INFO "open injection-audit issue already present; skipping new issue"
    return 0
  fi
  stamp="$(date +%Y%m%d_%H%M%S)_$$"
  body="${ISSUES_DIR}/${stamp}_injection-audit.md"
  {
    printf '# 注入链路日审计发现问题（%s）\n\n' "$(date '+%Y-%m-%d')"
    printf '## 现象\n\n```\n'
    cat "${TMP_DIR}/findings.txt"
    printf '```\n\n## 证据\n\n'
    printf -- '- 明细日志：%s\n' "${LOG_FILE}"
    printf -- '- 窗口：最近 %s 天事件（%s 起）\n' "${WINDOW_DAYS}" "${CUTOFF}"
    printf -- '- 判据：dropped > 0 视为提醒丢失；injected = 0 且 nosession >= %s 视为未送达；SCANDRIFT = 发布件新于运行镜像且无自检日志\n\n' "${NO_SESSION_ALERT}"
    printf '## 处置\n\n按本轮审计结论修复根因，修复后删除/归档本 issue；同日不重复创建。\n'
  } >"${body}"
  log ERROR "findings written to ${body}"
}

# 30-day observation bookkeeping. Emits a WEEKLY aggregate every 7 days and one
# VERDICT on the closing day, so the observation runs to completion through the
# daily cron entry. Counters come from the per-day audit logs themselves; a day
# with a DROPPED/STALLED line is a delivery failure by definition.
periodic_report() {
  local today days f d n dropped stalled drift stopped verdict start_num
  local now_epoch start_epoch elapsed
  today="$(date +%Y-%m-%d)"
  start_num="$(date -d "${OBSERVE_START}" +%Y%m%d)"
  now_epoch="$(date -d "${today}" +%s)"
  start_epoch="$(date -d "${OBSERVE_START}" +%s)"
  elapsed=$((now_epoch - start_epoch))
  # Integer days; negative before the window opens, which is the no-op branch.
  days=$((elapsed / 86400))
  ((days > 0)) || return 0

  n=0 dropped=0 stalled=0 drift=0 stopped=0
  # 终止性：输入是 fdfind 的有限文件列表，每轮消费一行，循环必然结束。
  while IFS= read -r f; do
    d="$(basename "${f}")"
    d="${d//[^0-9]/}"
    [[ -n "${d}" ]] || continue
    ((10#${d} >= 10#${start_num})) || continue
    n=$((n + 1))
    # Day-level flags, not line counts: several audit runs per day must not
    # inflate the number of failing days.
    if rg -q '^DROPPED' "${f}" 2>/dev/null; then dropped=$((dropped + 1)); fi
    if rg -q '^STALLED' "${f}" 2>/dev/null; then stalled=$((stalled + 1)); fi
    if rg -q '^SCANDRIFT' "${f}" 2>/dev/null; then drift=$((drift + 1)); fi
    if rg -q '^SCANSTOPPED' "${f}" 2>/dev/null; then stopped=$((stopped + 1)); fi
  done < <(fdfind --type f --glob 'injection-audit.*.log' "${LOG_DIR}" 2>/dev/null | sort)

  if ((days % 7 == 0)); then
    printf 'WEEKLY\tday=%s audited_days=%s bad_days_dropped=%s bad_days_stalled=%s bad_days_drift=%s bad_days_stopped=%s\n' \
      "${days}" "${n}" "${dropped}" "${stalled}" "${drift}" "${stopped}" >>"${LOG_FILE}"
  fi

  # ISO dates compare correctly as strings (YYYY-MM-DD), so ">=" is date order.
  if [[ "${today}" == "${OBSERVE_END}" || "${today}" > "${OBSERVE_END}" ]] &&
    [[ ! -f "${OBSERVE_FINAL_MARKER}" ]]; then
    if ((dropped == 0 && stalled == 0 && stopped == 0)); then
      verdict=PASS
    else
      verdict=FAIL
    fi
    printf 'VERDICT\tverdict=%s end=%s audited_days=%s bad_days_dropped=%s bad_days_stalled=%s bad_days_drift=%s bad_days_stopped=%s\n' \
      "${verdict}" "${OBSERVE_END}" "${n}" "${dropped}" "${stalled}" "${drift}" "${stopped}" \
      >>"${LOG_FILE}"
    # Atomic marker: a half-written state file would look like "not yet done"
    # and re-emit the verdict; tmp lives in the same directory as the target.
    printf 'verdict=%s at=%s audited_days=%s bad_days_dropped=%s bad_days_stalled=%s bad_days_drift=%s bad_days_stopped=%s\n' \
      "${verdict}" "${today}" "${n}" "${dropped}" "${stalled}" "${drift}" "${stopped}" \
      >"${OBSERVE_FINAL_MARKER}.tmp.$$" &&
      mv -f "${OBSERVE_FINAL_MARKER}.tmp.$$" "${OBSERVE_FINAL_MARKER}"
    # The observation's closing note belongs with the other conclusions, and the
    # cron run is the only actor at that point, so append directly.
    if [[ -d "${ROOT}/memory" ]]; then
      {
        printf '\n## 2026-11-19 issue 注入链路 30 天观察结论（%s，自动生成）\n\n' "${today}"
        printf -- '- 判定：%s（窗口 %s → %s）\n' "${verdict}" "${OBSERVE_START}" "${OBSERVE_END}"
        printf -- '- 样本：%s 个审计日；丢弃日 %s、停滞日 %s、运行态停止日 %s、漂移日 %s\n' \
          "${n}" "${dropped}" "${stalled}" "${stopped}" "${drift}"
        printf -- '- 证据：`%s`、`%s`\n' "${LOG_FILE}" "${OBSERVE_FINAL_MARKER}"
      } >>"${ROOT}/memory/overall.md"
    fi
  fi
}

rotate_logs() {
  fdfind --type f --glob 'injection-audit.*.log' --changed-before "${RETAIN_DAYS}d" \
    "${LOG_DIR}" 2>/dev/null | while IFS= read -r old; do
    rm -f "${old}"
  done
}

main() {
  local now_ts marker_ts
  mkdir -p "${LOG_DIR}" "${ISSUES_DIR}" "${ROOT}/.var"
  # Append, not truncate: several manual runs per day are normal and the earlier
  # blocks are the evidence for what changed. Retention is bounded by rotate_logs.
  if [[ ! -f "${LOG_FILE}" ]]; then : >"${LOG_FILE}"; fi
  printf '\n=== audit run %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"${LOG_FILE}"
  TMP_DIR="$(mktemp -d "${ROOT}/.var/injection-audit.XXXXXX")"
  CUTOFF="$(date -u -d "${WINDOW_DAYS} days ago" +%Y-%m-%dT%H:%M)"
  export CUTOFF

  require_tools
  log INFO "audit start | window=${WINDOW_DAYS}d cutoff=${CUTOFF}"
  touch -d "${WINDOW_DAYS} days ago" "${TMP_DIR}/cutoff"
  touch -d "${CACHE_MAX_AGE_DAYS} days ago" "${TMP_DIR}/cache-cutoff"

  discover_workspaces
  collect_reminder_counts "${WS_CACHE}"
  summarize_reminders
  summarize_dispatch
  check_scan_runtime
  cat "${TMP_DIR}/findings.txt" >>"${LOG_FILE}"

  if [[ -s "${TMP_DIR}/findings.txt" ]] &&
    rg -q '^(DROPPED|STALLED|SCANSTOPPED)' "${TMP_DIR}/findings.txt"; then
    write_issue
  elif [[ -s "${TMP_DIR}/findings.txt" ]] &&
    rg -q '^SCANDRIFT' "${TMP_DIR}/findings.txt"; then
    now_ts="$(date +%s)"
    marker_ts="$(stat -c %Y "${SCAN_DRIFT_MARKER}" 2>/dev/null || echo 0)"
    if ((now_ts - marker_ts >= SCAN_DRIFT_REPORT_DAYS * 86400)); then
      write_issue
      touch "${SCAN_DRIFT_MARKER}"
    else
      log INFO "scan runtime drift already reported within ${SCAN_DRIFT_REPORT_DAYS}d; log only"
    fi
  else
    log INFO "no reminder-delivery finding"
  fi

  periodic_report
  rotate_logs
  log INFO "audit done"
}

main "$@"
