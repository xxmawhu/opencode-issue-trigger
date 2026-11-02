#!/usr/bin/env bash
# post-merge hook: reinstall the plugin after git pull.
# Screen output stays minimal; the full trace goes to log/post-merge-hook.YYYYMMDD.log.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/log"
LOG_FILE="${LOG_DIR}/post-merge-hook.$(date +%Y%m%d).log"
mkdir -p "${LOG_DIR}"

log() {
  local level="$1"
  local stage="$2"
  local message="$3"
  printf '[%s] [%s] [stage:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${stage}" "${message}" >>"${LOG_FILE}"
}

log INFO "post-merge" "git pull detected; reinstalling issue-trigger"

if bash "${PROJECT_ROOT}/install.sh" >>"${LOG_FILE}" 2>&1; then
  log PASS "post-merge" "reinstall completed"
  printf '✅ issue-trigger reinstall\n'
  exit 0
fi

log FAIL "post-merge" "reinstall failed; see log/install.$(date +%Y%m%d).log"
printf '❌ issue-trigger reinstall（详见 log/post-merge-hook.%s.log）\n' "$(date +%Y%m%d)"
exit 0