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
  latest="$(fdfind --type f --glob 'scan_issue*.log' "${SCAN_LOG_DIR}" 2>/dev/null |
    sort | tail -1)"
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
check_scan_runtime() {
  local pub_mtime now pid etimes start_epoch drift=0 selfcheck=0 start_iso pub_iso
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

  while IFS= read -r f; do logs+=("${f}"); done < <(
    fdfind --type f --glob 'scan_issue*.log' "${SCAN_LOG_DIR}" 2>/dev/null | sort | tail -3
  )
  if ((${#logs[@]} > 0)) && rg -q -e '\[SELF-CHECK\]' "${logs[@]}" 2>/dev/null; then
    selfcheck=1
  fi

  start_iso="$(date -d "@${start_epoch}" '+%Y-%m-%dT%H:%M:%S')"
  pub_iso="$(date -d "@${pub_mtime}" '+%Y-%m-%dT%H:%M:%S')"
  printf 'SCANRUNTIME\tpid=%s start=%s published=%s drift=%d selfcheck=%d\n' \
    "${pid}" "${start_iso}" "${pub_iso}" "${drift}" "${selfcheck}" >>"${TMP_DIR}/findings.txt"
  if ((drift == 1 && selfcheck == 0)); then
    printf 'SCANDRIFT\tpid=%s running_since=%s published_mtime=%s selfcheck=0\n' \
      "${pid}" "${start_iso}" "${pub_iso}" >>"${TMP_DIR}/findings.txt"
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

rotate_logs() {
  fdfind --type f --glob 'injection-audit.*.log' --changed-before "${RETAIN_DAYS}d" \
    "${LOG_DIR}" 2>/dev/null | while IFS= read -r old; do
    rm -f "${old}"
  done
}

main() {
  local now_ts marker_ts
  mkdir -p "${LOG_DIR}" "${ISSUES_DIR}" "${ROOT}/.var"
  : >"${LOG_FILE}"
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

  rotate_logs
  log INFO "audit done"
}

main "$@"
