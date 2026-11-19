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
#
# A finding writes ./issues/<ts>_injection-audit.md so the reminder plugin picks
# it up like any other issue; one open audit issue at a time (deduplicated).
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HOME_ROOTS=(/mnt/beegfs_data/usr/maxx/dev /mnt/beegfs_data/usr/maxx/quant)
SCAN_LOG_DIR="/mnt/beegfs_data/usr/maxx/regular_task/scan_issue/log"
LOG_DIR="${ROOT}/log"
LOG_FILE="${LOG_DIR}/injection-audit.$(date +%Y%m%d).log"
ISSUES_DIR="${ROOT}/issues"
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

collect_reminder_counts() {
  local ws_file="$1"
  local ws_file_count project log_file
  ws_file_count="$(wc -l <"${ws_file}")"
  log INFO "workspaces discovered: ${ws_file_count}"
  while IFS= read -r ws; do
    project="${ws%/.local/share/opencode-workspaces}"
    while IFS= read -r log_file; do
      rg --no-filename --no-line-number \
        -e 'message="queued issue injection"' \
        -e 'message="injected issue prompt"' \
        -e 'message="no injectable session yet; issue stays queued"' \
        -e 'message="dropping issue injection"' \
        "${log_file}" 2>/dev/null
    done < <(fdfind --hidden --type f --changed-within "${WINDOW_DAYS}d" \
      --glob '*.log' "${ws}" 2>/dev/null) | awk -v cutoff="${CUTOFF}" -v project="${project}" '
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
    /fail-closed/ { closed++ }
    /\[PRE-CHECK\] opencode already running/ { running++ }
    END {
      printf "DISPATCH\tfile=%s exit124=%d exit255=%d failclosed=%d running=%d\n", FILENAME, t124, t255, closed, running
    }' "${latest}" >>"${TMP_DIR}/findings.txt"
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
    printf -- '- 判据：dropped > 0 视为提醒丢失；injected = 0 且 nosession >= %s 视为未送达\n\n' "${NO_SESSION_ALERT}"
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
  mkdir -p "${LOG_DIR}" "${ISSUES_DIR}" "${ROOT}/.var"
  : >"${LOG_FILE}"
  TMP_DIR="$(mktemp -d "${ROOT}/.var/injection-audit.XXXXXX")"
  CUTOFF="$(date -u -d "${WINDOW_DAYS} days ago" +%Y-%m-%dT%H:%M)"
  export CUTOFF

  require_tools
  log INFO "audit start | window=${WINDOW_DAYS}d cutoff=${CUTOFF}"

  fdfind --hidden --type d --glob 'opencode-workspaces' "${HOME_ROOTS[@]}" \
    2>/dev/null >"${TMP_DIR}/workspaces.txt"
  collect_reminder_counts "${TMP_DIR}/workspaces.txt"
  summarize_reminders
  summarize_dispatch
  cat "${TMP_DIR}/findings.txt" >>"${LOG_FILE}"

  if [[ -s "${TMP_DIR}/findings.txt" ]] &&
    rg -q '^(DROPPED|STALLED)' "${TMP_DIR}/findings.txt"; then
    write_issue
  else
    log INFO "no reminder-delivery finding"
  fi

  rotate_logs
  log INFO "audit done"
}

main "$@"
