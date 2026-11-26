#!/usr/bin/env bash
# Reproducible regression chain for the dual-generation plugin install:
#   install -> assert input writer present -> materialize a user `issue` message
#   -> start -> assert no LoadError -> drop an issue -> assert injection
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
LOG_FILE="${LOG_DIR}/verify-regression.$(date +%Y%m%dT%H).log"
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
  printf '❌ %s: %s（详见 %s）\n' "$1" "$2" "${LOG_FILE}"
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

# A run started from an opencode session inherits OPENCODE=1, the parent session
# id and XDG_DATA_HOME/XDG_CONFIG_HOME pointing at that live workspace, so the CLI
# resolves data/config/log there instead of HOME. Clearing them is what makes the
# sandbox a sandbox: without it the rounds exercise the real installation and
# write to the real database.
iso() {
  env -u OPENCODE -u OPENCODE_SESSION_ID -u OPENCODE_SESSION_PID -u OPENCODE_TERMINAL \
    -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME "$@"
}

setup_sandbox() {
  rm -rf "${SANDBOX}"
  mkdir -p "${SANDBOX}/home/.local/state" "${SANDBOX}/project/issues"
  # The project root is the git root of the working directory. Without a repo
  # here, the sandbox project resolves to this repository and the plugin watches
  # the real ./issues directory.
  git init -q "${SANDBOX}/project"
  log INFO setup "sandbox=${SANDBOX}"
}

run_install() {
  local label="$1"
  shift
  local output="${SANDBOX}/install-${label}.log"
  ( cd "${ROOT}" && iso HOME="${SANDBOX}/home" timeout 180 bash install.sh "$@" ) >"${output}" 2>&1 ||
    fail install "install.sh 退出非 0（mode=${label}）"
  cmp -s "${ROOT}/plugin/issue-trigger.ts" "${SANDBOX}/home/.config/opencode/plugin/issue-trigger.ts" ||
    fail install "入口与仓库不一致（mode=${label}）"
  pass install "安装完成且入口与仓库一致（mode=${label}）"
}

# The plugin materializes a user message that starts with `issue` as an issue
# file (2026-11-26 user ruling: this is a feature; the duplicate-file report was
# about `o.run` prefixing every prompt, not about this capability). Assert the
# installed build carries the writer chain instead of trusting one behavioural
# run, so a future removal cannot pass silently.
assert_input_writer() {
  local stage="input-writer"
  local lib="${SANDBOX}/home/.config/opencode/issue-trigger-lib"
  local entry="${SANDBOX}/home/.config/opencode/plugin/issue-trigger.ts"
  [ -f "${lib}/issue-input.mjs" ] || fail "${stage}" "安装目录缺少 issue-input.mjs"
  rg -q 'createIssueInputHandler' "${entry}" || fail "${stage}" "入口未接入用户输入处理器"
  rg -q '"chat\.message"' "${entry}" || fail "${stage}" "入口缺少 v1 chat.message hook"
  rg -q 'session\.hook\(' "${entry}" || fail "${stage}" "入口缺少 v2 session.hook 注册"
  # writeFileSync + linkSync 是物化链路的唯一实现：临时件落盘 + 硬链接原子发布。
  rg -q 'writeFileSync' "${lib}/issue-input.mjs" || fail "${stage}" "issue-input.mjs 不再写临时件"
  rg -q 'linkSync' "${lib}/issue-input.mjs" || fail "${stage}" "issue-input.mjs 不再硬链接发布"
  pass "${stage}" "安装目录带物化模块、三条注册链路齐全"
}

# Behavioural half of the same contract: the v1 host must turn `issue <body>`
# into a file under issues/. Body stays short so the slug is predictable
# (slug = first line slice(0, 24), only [A-Za-z0-9_-] kept).
v1_materialize_round() {
  local stage="materialize"
  local output="${SANDBOX}/v1-materialize.log"
  local body="materialize-probe"
  rm -f "${SANDBOX}/project/issues/"*.md
  ( cd "${SANDBOX}/project" && iso HOME="${SANDBOX}/home" timeout 120 "${V1}" run "issue ${body}" \
    --model nonexistent/nonexistent --print-logs --log-level DEBUG ) >"${output}" 2>&1
  local created
  created="$(rg --files --no-ignore -g "*_${body}.md" "${SANDBOX}/project/issues" | head -1)"
  [[ -n "${created}" ]] || fail "${stage}" "宿主启动后未生成 issue 文件（详见 ${output}）"
  [[ "$(<"${created}")" == "${body}" ]] ||
    fail "${stage}" "issue 文件内容不符：$(head -3 "${created}" | tr '\n' ' ')"
  # 空正文不建文件：命令被识别但不物化。
  rm -f "${SANDBOX}/project/issues/"*.md
  ( cd "${SANDBOX}/project" && iso HOME="${SANDBOX}/home" timeout 120 "${V1}" run "issue" \
    --model nonexistent/nonexistent --print-logs --log-level DEBUG ) >"${SANDBOX}/v1-materialize-empty.log" 2>&1
  [[ -z "$(rg --files --no-ignore -g '*.md' "${SANDBOX}/project/issues" | head -1)" ]] ||
    fail "${stage}" "空正文仍生成了 issue 文件"
  pass "${stage}" "issue <正文> 生成 ${body}.md 且内容一致；空正文不建文件"
}

# One v1 round: fresh issue file, one headless run, assert single injection.
v1_round() {
  local round="$1"
  local output="${SANDBOX}/v1-${round}.log"
  rm -f "${SANDBOX}/project/issues/"*.md
  printf '# regression issue %s\n\nprobe\n' "${round}" >"${SANDBOX}/project/issues/2026-11-16_round${round}.md"
  ( cd "${SANDBOX}/project" && iso HOME="${SANDBOX}/home" timeout 120 "${V1}" run hi \
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
  local plugin_log="${SANDBOX}/project/log"
  rm -rf "${plugin_log}"
  ( cd "${SANDBOX}/project" && iso HOME="${SANDBOX}/home" timeout 120 "${V2}" \
    --standalone --print-logs --log-level debug debug agents ) >"${output}" 2>&1
  local load_fail loaded log_file hook_missing hook_error
  load_fail="$(count_matches 'failed to load plugin' "${output}")"
  # v2 has no app.log endpoint and standalone stderr goes to /dev/null, so the
  # plugin owns an hourly log inside the project (issue 891a50f5).
  loaded="$(rg -o -- 'issue-trigger loaded' "${plugin_log}" 2>/dev/null | wc -l)"
  log_file="$(ls "${plugin_log}"/issue-trigger.*.log 2>/dev/null | head -1)"
  [[ "${load_fail}" -eq 0 ]] || fail v2 "round ${round} LoadError=${load_fail}"
  [[ "${loaded}" -eq 1 ]] || fail v2 "round ${round} 激活次数=${loaded}（应为 1，日志目录 ${plugin_log}）"
  [[ -n "${log_file}" ]] || fail v2 "round ${round} 未生成项目内日志（${plugin_log}）"
  # User-input materialization is part of the v2 wiring too: the context hook
  # must register, and its absence is logged as a warning by the plugin.
  hook_missing="$(count_matches 'host exposes no session.hook' "${log_file}")"
  hook_error="$(count_matches 'failed to register session context hook' "${log_file}")"
  [[ "${hook_missing}" -eq 0 ]] || fail v2 "round ${round} 宿主未暴露 session.hook，物化链路缺失"
  [[ "${hook_error}" -eq 0 ]] || fail v2 "round ${round} session.hook 注册失败（详见 ${log_file}）"
  pass v2 "round ${round} 无 LoadError、单激活、项目日志已写入、session.hook 已注册"
}

main() {
  [[ -x "${V1}" ]] || fail start "v1 可执行文件不存在: ${V1}"
  setup_sandbox
  # `debug info` exists only on the 1.x host, so it doubles as a generation
  # probe. Run it in the sandbox HOME: the live database may be a 2.x schema and
  # make the 1.x binary exit non-zero for reasons unrelated to its generation.
  iso HOME="${SANDBOX}/home" "${V1}" debug info >/dev/null 2>&1 ||
    fail start "${V1} 不支持 debug info（疑似 2.x 宿主），请用 OPENCODE_V1 指定 1.x 二进制"
  # Assert the isolation instead of trusting it: a leaked OPENCODE env var makes
  # the CLI use the live workspace's config and database.
  if [[ -n "${V2}" ]]; then
    local paths
    paths="$(iso HOME="${SANDBOX}/home" "${V2}" debug paths 2>&1)"
    printf '%s\n' "${paths}" | rg -q "config +${SANDBOX}/home/" ||
      fail start "沙箱配置目录未生效：$(printf '%s' "${paths}" | head -4 | tr '\n' ' ')"
  fi
  run_install copy
  assert_input_writer
  run_install link --link
  assert_input_writer
  v1_materialize_round

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
  printf '✅ 回归链通过（日志 %s）\n' "${LOG_FILE}"
}

main "$@"
