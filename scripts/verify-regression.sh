#!/usr/bin/env bash
# Reproducible regression chain for the dual-generation plugin install:
#   install -> start -> assert no LoadError -> drop an issue -> assert injection
#   -> restart -> assert the same issue is injected once per process
# Runs in an isolated HOME, so it never touches the real opencode config.
#
# Environment overrides:
#   OPENCODE_V1  v1 binary (default /usr/local/bin/opencode)
#   OPENCODE_V2  v2 binary; when unset the v2 pass is skipped
#   ROUNDS       rounds per host (default 3)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SANDBOX="${ROOT}/.var/verify-regression"
LOG_DIR="${ROOT}/log"
LOG_FILE="${LOG_DIR}/verify-regression.$(date +%Y%m%d).log"
V1="${OPENCODE_V1:-/usr/local/bin/opencode}"
V2="${OPENCODE_V2:-}"
ROUNDS="${ROUNDS:-3}"

mkdir -p "${LOG_DIR}" "${SANDBOX}"
: >"${LOG_FILE}"

log() {
  local level="$1" stage="$2" message="$3"
  printf '[%s] [%s] [stage:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${stage}" "${message}" >>"${LOG_FILE}"
}

fail() {
  log FAIL "$1" "$2"
  printf '❌ %s: %s（详见 log/verify-regression.%s.log）\n' "$1" "$2" "$(date +%Y%m%d)"
  exit 1
}

pass() {
  log PASS "$1" "$2"
  printf '✅ %s: %s\n' "$1" "$2"
}

# rg prints nothing (and exits 1) when a pattern is absent; callers need 0.
count_matches() {
  local count
  count="$(rg -c -- "$1" "$2" 2>/dev/null)" || count=0
  printf '%s' "${count:-0}"
}

setup_sandbox() {
  rm -rf "${SANDBOX}"
  mkdir -p "${SANDBOX}/home/.local/state" "${SANDBOX}/project/issues"
  log INFO setup "sandbox=${SANDBOX}"
}

run_install() {
  local label="$1"
  shift
  local output="${SANDBOX}/install-${label}.log"
  ( cd "${ROOT}" && HOME="${SANDBOX}/home" timeout 180 bash install.sh "$@" ) >"${output}" 2>&1 ||
    fail install "install.sh 退出非 0（mode=${label}）"
  cmp -s "${ROOT}/plugin/issue-trigger.ts" "${SANDBOX}/home/.config/opencode/plugin/issue-trigger.ts" ||
    fail install "入口与仓库不一致（mode=${label}）"
  pass install "安装完成且入口与仓库一致（mode=${label}）"
}

# One v1 round: fresh issue file, one headless run, assert single injection.
v1_round() {
  local round="$1"
  local output="${SANDBOX}/v1-${round}.log"
  rm -f "${SANDBOX}/project/issues/"*.md
  printf '# regression issue %s\n\nprobe\n' "${round}" >"${SANDBOX}/project/issues/2026-11-16_round${round}.md"
  ( cd "${SANDBOX}/project" && HOME="${SANDBOX}/home" timeout 120 "${V1}" run hi \
    --model nonexistent/nonexistent --print-logs --log-level DEBUG ) >"${output}" 2>&1
  local load_fail loaded injected
  load_fail="$(count_matches 'failed to load plugin' "${output}")"
  loaded="$(count_matches 'issue-trigger loaded' "${output}")"
  injected="$(count_matches 'injected issue prompt' "${output}")"
  [[ "${load_fail}" -eq 0 ]] || fail v1 "round ${round} LoadError=${load_fail}"
  [[ "${loaded}" -eq 1 ]] || fail v1 "round ${round} 激活次数=${loaded}（应为 1）"
  [[ "${injected}" -eq 1 ]] || fail v1 "round ${round} 注入次数=${injected}（应为 1）"
  pass v1 "round ${round} 无 LoadError、单激活、单次注入"
}

v2_round() {
  local round="$1"
  local output="${SANDBOX}/v2-${round}.log"
  ( cd "${SANDBOX}/project" && HOME="${SANDBOX}/home" timeout 120 "${V2}" \
    --standalone --print-logs --log-level debug debug agents ) >"${output}" 2>&1
  local load_fail loaded
  load_fail="$(count_matches 'failed to load plugin' "${output}")"
  loaded="$(count_matches 'issue-trigger loaded' "${output}")"
  [[ "${load_fail}" -eq 0 ]] || fail v2 "round ${round} LoadError=${load_fail}"
  [[ "${loaded}" -eq 1 ]] || fail v2 "round ${round} 激活次数=${loaded}（应为 1）"
  pass v2 "round ${round} 无 LoadError、单激活"
}

main() {
  [[ -x "${V1}" ]] || fail start "v1 可执行文件不存在: ${V1}"
  setup_sandbox
  run_install copy
  run_install link --link

  local i
  # Loop bound is the caller-supplied round count; no early exit, so the
  # invariant "0 <= i <= ROUNDS" and the strictly increasing i guarantee exit.
  for i in $(seq 1 "${ROUNDS}"); do
    v1_round "${i}"
  done

  if [[ -z "${V2}" ]]; then
    log INFO v2 "未设置 OPENCODE_V2，跳过 v2 轮次"
    printf '⏭️  v2 轮次跳过（未设置 OPENCODE_V2）\n'
  elif [[ ! -x "${V2}" ]]; then
    fail v2 "v2 可执行文件不存在: ${V2}"
  else
    for i in $(seq 1 "${ROUNDS}"); do
      v2_round "${i}"
    done
  fi

  log PASS done "回归链通过（${ROUNDS} 轮 v1${V2:+ + ${ROUNDS} 轮 v2}）"
  printf '✅ 回归链通过（日志 log/verify-regression.%s.log）\n' "$(date +%Y%m%d)"
}

main "$@"