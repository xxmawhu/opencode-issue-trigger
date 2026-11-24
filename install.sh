#!/usr/bin/env bash
# One-click installer for opencode-issue-trigger.
# Installs the v1 and v2 plugin entries into the current user's opencode config
# and registers the repository git hooks through pre-commit.
#
# Host processes may run as accounts other than the installer, so installed
# artifacts must stay readable by other accounts. Modes are set explicitly and
# verified fail-closed instead of being inherited from the caller's umask.
set -euo pipefail
umask 022

PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
OPENCODE_DIR="${HOME}/.config/opencode"
LOG_DIR="${PROJECT_ROOT}/log"
LOG_FILE="${LOG_DIR}/install.$(date +%Y%m%dT%H).log"
CLEANUP_TARGET=""
LINK_MODE=0
VERIFY_RUNTIME=0
# Platform tools live under the platform Python prefix; agent accounts no longer
# carry /opt/miniconda3/bin on PATH, so resolve pre-commit by absolute path only.
PRE_COMMIT_BIN="/opt/miniconda3/bin/pre-commit"

log() {
  local level="$1"
  local stage="$2"
  local message="$3"
  printf '[%s] [%s] [stage:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${stage}" "${message}" >>"${LOG_FILE}"
}

die() {
  log ERROR "$1" "$2"
  printf '❌ %s（详见 log/install.%s.log）\n' "$2" "$(date +%Y%m%dT%H)"
  exit 1
}

cleanup() {
  if [ -n "${CLEANUP_TARGET}" ] && [ -e "${CLEANUP_TARGET}" ]; then
    rm -rf "${CLEANUP_TARGET}"
  fi
}
trap cleanup EXIT

# Normalize an installed tree to world-readable modes: dirs 0755, files 0644.
# `find` is used instead of fdfind because target hosts are not guaranteed to
# ship the latter; the fallback is exactly the portable implementation.
normalize_permissions() {
  local root="$1"
  chmod 0755 "${root}"
  find "${root}" -type d -exec chmod 0755 {} +
  find "${root}" -type f -exec chmod 0644 {} +
}

# Octal mode test: need=5 (read+execute) for dirs, need=4 (read) for files.
has_other_bits() {
  local path="$1"
  local need="$2"
  local mode
  local masked
  mode="$(stat -c '%a' "${path}")"
  masked=$(( 8#${mode} & 8#${need} ))
  [[ ${masked} -eq ${need} ]]
}

# Make a directory traversable by other accounts when we own it; symbolic mode
# keeps inherited setgid bits that group-based hosts rely on.
ensure_dir_traversable() {
  local path="$1"
  if [[ -O "${path}" ]]; then
    chmod a+rx "${path}"
  fi
}

die_on_mode() {
  local stage="$1"
  local path="$2"
  die "${stage}" \
    "安装产物对非 owner 账户不可读：${path}（mode=$(stat -c '%a' "${path}")，owner=$(stat -c '%U:%G' "${path}")，current=$(id -un)）"
}

# Fail-closed tree check: every dir needs other r+x, every file other r.
verify_tree() {
  local stage="$1"
  local root="$2"
  local path
  has_other_bits "${root}" 5 || die_on_mode "${stage}" "${root}"
  while IFS= read -r path; do
    [[ -L "${path}" ]] && continue
    if [[ -d "${path}" ]]; then
      has_other_bits "${path}" 5 || die_on_mode "${stage}" "${path}"
    else
      has_other_bits "${path}" 4 || die_on_mode "${stage}" "${path}"
    fi
  done < <(find "${root}" -mindepth 1)
}

verify_permissions() {
  local stage="verify-permissions"
  local path

  # Parent directories are checked too: a 0700 parent hides a 0755 child.
  local dirs=(
    "${OPENCODE_DIR}"
    "${OPENCODE_DIR}/plugin"
    "${OPENCODE_DIR}/issue-trigger-lib"
  )
  for path in "${dirs[@]}"; do
    has_other_bits "${path}" 5 || die_on_mode "${stage}" "${path}"
  done

  verify_tree "${stage}" "${OPENCODE_DIR}/issue-trigger-lib"

  for path in "${OPENCODE_DIR}/plugin/issue-trigger.ts"; do
    has_other_bits "${path}" 4 || die_on_mode "${stage}" "${path}"
  done

  log PASS "${stage}" "installed tree readable by other accounts (dirs 0755, files 0644)"
}

mkdir -p "${LOG_DIR}"
if ! mkdir -p "${OPENCODE_DIR}/plugin"; then
  die "start" "无法写入 opencode 配置目录：${OPENCODE_DIR}"
fi
ensure_dir_traversable "${OPENCODE_DIR}"
ensure_dir_traversable "${OPENCODE_DIR}/plugin"

if command -v flock >/dev/null 2>&1; then
  exec 9>"${LOG_DIR}/install.lock"
  if ! flock -n 9; then
    printf '❌ 另一个 install.sh 正在运行（详见 log/install.%s.log）\n' "$(date +%Y%m%dT%H)"
    exit 1
  fi
fi

replace_dir() {
  local src="$1"
  local dst="$2"
  local tmp="${dst}.new.$$"
  local old="${dst}.old.$$"
  rm -rf "${tmp}" "${old}"
  mkdir -p "${tmp}"
  CLEANUP_TARGET="${tmp}"
  # cp stderr goes to the log: without it a read-only or full target filesystem
  # aborts under `set -e` leaving only `[stage:start]` in the log and no cause
  # (observed 2026-11-19 14:43 on a read-only config dir).
  if ! cp -R "${src}/." "${tmp}/" 2>>"${LOG_FILE}"; then
    CLEANUP_TARGET=""
    rm -rf "${tmp}"
    die "install-plugin" "复制 ${src} 失败"
  fi
  # Normalize and verify before publishing so a bad tree never replaces a good one.
  normalize_permissions "${tmp}"
  verify_tree "install-plugin" "${tmp}"
  if [ -e "${dst}" ]; then
    mv "${dst}" "${old}"
  fi
  mv "${tmp}" "${dst}"
  CLEANUP_TARGET=""
  rm -rf "${old}"
}

install_file() {
  local src="$1"
  local dst="$2"
  local tmp="${dst}.tmp.$$"
  CLEANUP_TARGET="${tmp}"
  if ! cp "${src}" "${tmp}" 2>>"${LOG_FILE}"; then
    CLEANUP_TARGET=""
    rm -f "${tmp}"
    die "install-plugin" "复制 ${src} 失败"
  fi
  chmod 0644 "${tmp}"
  mv "${tmp}" "${dst}"
  CLEANUP_TARGET=""
}

# Remove installs written by older layouts. Both hosts treat every subdirectory
# of plugin/ and plugins/ as a plugin package, so the old library directory and
# the old v2 entry directory would fail to load.
remove_legacy() {
  local stage="remove-legacy"
  local path
  for path in "${OPENCODE_DIR}/plugin/issue-trigger-lib" "${OPENCODE_DIR}/plugins/issue-trigger"; do
    if [ -e "${path}" ] || [ -L "${path}" ]; then
      rm -rf "${path}"
      log INFO "${stage}" "removed legacy path ${path}"
    fi
  done
}

# Development installs link the checkout instead of copying it, so edits are
# picked up without reinstalling. Both hosts read through the symlink.
install_link() {
  local src="$1"
  local dst="$2"
  local backup="${dst}.old.$$"
  if [[ -d "${dst}" && ! -L "${dst}" ]]; then
    # A real directory cannot be replaced by `ln -sfn`; move it aside first so
    # the link is published by a single rename.
    mv "${dst}" "${backup}"
    ln -s "${src}" "${dst}"
    rm -rf "${backup}"
    return 0
  fi
  ln -sfn "${src}" "${dst}"
}

install_plugin() {
  local stage="install-plugin"
  local mode_name="copy"
  if [ "${LINK_MODE}" -eq 1 ]; then
    mode_name="link"
  fi
  log INFO "${stage}" "project=${PROJECT_ROOT} opencode=${OPENCODE_DIR} mode=${mode_name}"

  [ -f "${PROJECT_ROOT}/plugin/issue-trigger.ts" ] || die "${stage}" "缺少 plugin/issue-trigger.ts"
  [ -d "${PROJECT_ROOT}/issue-trigger-lib" ] || die "${stage}" "缺少 issue-trigger-lib"

  remove_legacy
  mkdir -p "${OPENCODE_DIR}/plugin"

  if [ "${LINK_MODE}" -eq 1 ]; then
    install_link "${PROJECT_ROOT}/plugin/issue-trigger.ts" "${OPENCODE_DIR}/plugin/issue-trigger.ts"
    install_link "${PROJECT_ROOT}/issue-trigger-lib" "${OPENCODE_DIR}/issue-trigger-lib"
  else
    install_file "${PROJECT_ROOT}/plugin/issue-trigger.ts" "${OPENCODE_DIR}/plugin/issue-trigger.ts"
    replace_dir "${PROJECT_ROOT}/issue-trigger-lib" "${OPENCODE_DIR}/issue-trigger-lib"
  fi

  [ -e "${OPENCODE_DIR}/plugin/issue-trigger.ts" ] || die "${stage}" "插件入口安装失败"
  [ -e "${OPENCODE_DIR}/issue-trigger-lib/index.mjs" ] || die "${stage}" "共享库安装失败"

  verify_permissions

  log PASS "${stage}" "插件已安装（v1 + v2 共用入口，mode=${mode_name}）"
}

# Post-install self-check step 1: every installed byte must match the checkout.
# `cmp` follows symlinks, so this also covers `--link` installs.
verify_contents() {
  local stage="verify-contents"
  local src dst file name count=0
  src="${PROJECT_ROOT}/plugin/issue-trigger.ts"
  dst="${OPENCODE_DIR}/plugin/issue-trigger.ts"
  cmp -s "${src}" "${dst}" || die "${stage}" "入口文件与仓库不一致：${dst}"
  for file in "${PROJECT_ROOT}/issue-trigger-lib/"*.mjs; do
    [[ -e "${file}" ]] || break
    name="$(basename "${file}")"
    cmp -s "${file}" "${OPENCODE_DIR}/issue-trigger-lib/${name}" ||
      die "${stage}" "共享库文件与仓库不一致：issue-trigger-lib/${name}"
    count=$((count + 1))
  done
  [[ "${count}" -gt 0 ]] || die "${stage}" "仓库内没有可安装的共享库文件"
  for file in "${OPENCODE_DIR}/issue-trigger-lib/"*.mjs; do
    [[ -e "${file}" ]] || break
    name="$(basename "${file}")"
    [[ -f "${PROJECT_ROOT}/issue-trigger-lib/${name}" ]] ||
      die "${stage}" "安装目录存在仓库外文件：issue-trigger-lib/${name}"
  done
  log PASS "${stage}" "已装文件与仓库一致（1 入口 + ${count} 库文件）"
}

# Two config trees are easy to confuse: `$HOME` may differ from the account's
# passwd home (agent sessions, hooks, container runs), and a host only reads the
# config under the HOME it was started with. compute-server-98-7 installed into
# /mnt/beegfs_data/usr/maxx/.config/opencode at 06:22 and /home/maxx/.config/
# opencode at 06:41, both logging "installed", while only one of them was live.
# Warn when a second, different install exists so the mismatch reaches the log.
verify_single_install() {
  local stage="verify-home"
  local account_home other
  account_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  if [[ -z "${account_home}" ]]; then
    log INFO "${stage}" "无法解析账户 home，跳过重复安装检查"
    return 0
  fi
  other="${account_home}/.config/opencode/plugin/issue-trigger.ts"
  if [[ "${OPENCODE_DIR}" == "${account_home}/.config/opencode" || ! -e "${other}" ]]; then
    log INFO "${stage}" "安装目录 ${OPENCODE_DIR} 无同名第二份安装"
    return 0
  fi
  if cmp -s "${PROJECT_ROOT}/plugin/issue-trigger.ts" "${other}"; then
    log INFO "${stage}" "账户 home 下存在内容相同的另一份安装：${other}"
    return 0
  fi
  # [log-review] 预期内：同一台机器用不同 HOME 安装过两次，属环境差异而非安装缺陷；
  # 降级原因：本次安装自身完整，宿主读取哪一份取决于启动时的 HOME；
  # 影响范围：仅提示，不回滚已安装文件。
  log WARN "${stage}" "本次安装到 ${OPENCODE_DIR}，但账户 home 下另有一份内容不同的安装 ${other}；宿主以 HOME=${account_home} 启动时读取后者"
}

# Post-install self-check step 2: the host must list the plugin. Skipped when no
# `opencode` binary is on PATH (installers may run on hosts that only serve the
# shared config directory).
verify_plugin_list() {
  local stage="verify-list"
  local output version major
  if ! command -v opencode >/dev/null 2>&1; then
    log INFO "${stage}" "PATH 中无 opencode，跳过插件列表检查"
    return 0
  fi
  # opencode 2.x dropped `debug info`; only the 1.x host can print the plugin
  # list. Probe the major version so a 2.x host skips the assertion instead of
  # failing the install on an unknown subcommand (host v2.3.2, 2026-11-19).
  # Version output is logged unconditionally: installs on other servers report
  # only the log, so a silent detection failure is otherwise undiagnosable
  # (compute-server-98-7, 2026-11-19 06:22:08 failed here with no version line).
  version="$(opencode --version 2>/dev/null | head -1 || true)"
  log INFO "${stage}" "opencode 版本：${version:-<未输出>}"
  major="$(printf '%s\n' "${version}" |
    awk 'match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')"
  if [[ -n "${major}" ]] && (( major >= 2 )); then
    log INFO "${stage}" "宿主 ${version} 无 debug info 子命令，跳过插件列表检查"
    return 0
  fi
  # `debug info` is an informational listing, not the install assertion: the
  # installed tree is already byte-compared by verify-contents and, with
  # --verify, loaded by a real host process. A host whose CLI lacks the
  # subcommand (or whose version line was unparseable) must not abort the
  # install, or every such server stays on the previous plugin build.
  if ! output="$(timeout 60 opencode debug info 2>&1)"; then
    # [log-review] 预期内：宿主 CLI 能力差异（无 debug info / 版本行不可解析）；
    # 降级原因：安装内容已由 verify-contents + 可选 verify-load 断言；
    # 影响范围：仅少一次插件列表展示，不回滚已安装文件。
    log WARN "${stage}" "opencode debug info 不可用，跳过插件列表检查（安装内容已由 verify-contents 校验）：${output%%$'\n'*}"
    return 0
  fi
  [[ "${output}" == *issue-trigger* ]] ||
    die "${stage}" "opencode debug info 未列出 issue-trigger"
  log PASS "${stage}" "opencode debug info 已列出 issue-trigger"
}

# Post-install self-check step 3: load the plugin in a real host process and
# assert the load-success log, no LoadError. Costs one short headless run, so it
# only runs when `--verify` is passed (the regression script always passes it).
verify_load() {
  local stage="verify-load"
  local output marker log_file loaded version major
  if [ "${VERIFY_RUNTIME}" -ne 1 ]; then
    log INFO "${stage}" "未指定 --verify，跳过加载断言"
    return 0
  fi
  if ! command -v opencode >/dev/null 2>&1; then
    log INFO "${stage}" "PATH 中无 opencode，跳过加载断言"
    return 0
  fi
  mkdir -p "${PROJECT_ROOT}/.var"
  output="${PROJECT_ROOT}/.var/install-verify.$$.log"
  # v2 writes plugin logs to <project>/log (standalone stderr is /dev/null), so
  # the assertion also accepts a project log line produced by this run. The
  # marker keeps an older line from satisfying it.
  marker="${PROJECT_ROOT}/.var/install-verify-start.$$"
  CLEANUP_TARGET="${output}"
  : >"${marker}"
  # v2.3.x rejects the v1 spelling `--log-level DEBUG`, and its `run` path talks
  # to a background service whose stderr --print-logs does not reach; the same
  # `debug agents --standalone` invocation the regression script uses loads the
  # plugin and prints host logs. v1 keeps its original command.
  version="$(opencode --version 2>/dev/null | head -1 || true)"
  major="$(printf '%s\n' "${version}" |
    awk 'match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')"
  local -a cmd
  if [[ -n "${major}" ]] && (( major >= 2 )); then
    cmd=(opencode debug agents --standalone --print-logs --log-level debug)
  else
    cmd=(opencode run verify --model nonexistent/nonexistent --print-logs --log-level DEBUG)
  fi
  log INFO "${stage}" "宿主版本：${version:-<未输出>}"
  if ! ( cd "${PROJECT_ROOT}" && timeout 90 "${cmd[@]}" ) >"${output}" 2>&1; then
    log INFO "${stage}" "宿主命令返回非 0（模型名不存在属预期），继续检查日志"
  fi
  if [[ "$(<"${output}")" == *"failed to load plugin"* ]]; then
    rm -f "${output}" "${marker}"
    CLEANUP_TARGET=""
    die "${stage}" "宿主加载插件失败（日志出现 failed to load plugin）"
  fi
  loaded=0
  if [[ "$(<"${output}")" == *"issue-trigger loaded"* ]]; then
    loaded=1
  fi
  if [ "${loaded}" -eq 0 ]; then
    for log_file in "${PROJECT_ROOT}/log/issue-trigger."*.log; do
      [ -f "${log_file}" ] || continue
      [ "${log_file}" -nt "${marker}" ] || continue
      if rg -q 'issue-trigger loaded' "${log_file}"; then
        loaded=1
        break
      fi
    done
  fi
  rm -f "${output}" "${marker}"
  CLEANUP_TARGET=""
  if [ "${loaded}" -ne 1 ]; then
    die "${stage}" "日志中未出现 issue-trigger loaded（宿主 stderr 与 ${PROJECT_ROOT}/log 均无）"
  fi
  log PASS "${stage}" "宿主加载成功且无 LoadError"
}

# opencode 2.x unloads a project's services after 60 minutes without session
# activity (`location services evicted`), which destroys the issue watcher: issues
# dropped after that are never injected until the directory is opened again
# (2026-11-24: xcrypto-work-onboarding 5h24m late, agents-tools/timed-issue same).
# `experimental.location_idle_timeout: false` disables that eviction; the host
# accepts a duration string or false (verified with `opencode debug config
# --standalone` on v2.3.2). The key belongs to the global config: the plugin is
# installed globally, so a per-project edit would only cover one directory.
# An explicit non-false value is preserved: it is the operator's decision.
ensure_location_ttl() {
  local stage="location-ttl"
  local cfg="${OPENCODE_DIR}/opencode.json"
  # Same platform prefix as PRE_COMMIT_BIN above; one fixed path, no search chain.
  local py="/opt/miniconda3/bin/python3"
  local result
  if [ ! -x "${py}" ]; then
    # [log-review] 预期内：极简宿主无平台 Python；降级原因：不改配置也能安装插件；
    # 影响范围：该目录空闲 60 分钟后停止监听，需手工设置该键。
    log WARN "${stage}" "未找到 ${py}，跳过 experimental.location_idle_timeout 检查（需手工设为 false）"
    return 0
  fi
  result="$("${py}" - "${cfg}" <<'PY'
import json
import os
import stat
import sys
import tempfile

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    # The global config holds provider API keys; a rewrite must not widen its
    # permissions (a 0600 config would otherwise become world-readable).
    mode = stat.S_IMODE(os.stat(path).st_mode)
except FileNotFoundError:
    data = {}
    mode = 0o644
except Exception as error:  # unparsable config must stay untouched
    print(f"UNPARSABLE {error}")
    sys.exit(0)

if not isinstance(data, dict):
    print("UNPARSABLE 顶层不是 JSON 对象")
    sys.exit(0)

experimental = data.get("experimental")
if experimental is not None and not isinstance(experimental, dict):
    print("UNPARSABLE experimental 不是对象")
    sys.exit(0)
if isinstance(experimental, dict) and "location_idle_timeout" in experimental:
    value = experimental["location_idle_timeout"]
    if value is False:
        print("ALREADY")
        sys.exit(0)
    print(f"KEEP {json.dumps(value, ensure_ascii=False)}")
    sys.exit(0)

try:
    if not isinstance(experimental, dict):
        experimental = {}
        data["experimental"] = experimental
    experimental["location_idle_timeout"] = False
    directory = os.path.dirname(path) or "."
    handle, tmp = tempfile.mkstemp(dir=directory, prefix=".opencode.json.", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise
    with open(path, encoding="utf-8") as stream:
        written = json.load(stream)
    if written["experimental"]["location_idle_timeout"] is not False:
        print("MISMATCH 回读值不是 false")
        sys.exit(0)
except Exception as error:
    print(f"UNWRITABLE {error}")
    sys.exit(0)
print("WRITTEN")
PY
)"
  case "${result}" in
    ALREADY)
      log PASS "${stage}" "experimental.location_idle_timeout 已为 false（${cfg}）"
      ;;
    WRITTEN)
      log PASS "${stage}" "已写入 experimental.location_idle_timeout=false 并回读校验（${cfg}）"
      ;;
    KEEP\ *)
      local kept="${result#KEEP }"
      # [log-review] 预期内：运维显式指定了其他超时；降级原因：保留其选择；
      # 影响范围：该超时到期后插件停止监听，issue 延迟到目录再次打开才注入。
      log WARN "${stage}" "保留已配置的 location_idle_timeout=${kept}，插件可能被空闲卸载（${cfg}）"
      ;;
    UNPARSABLE\ *|UNWRITABLE\ *|MISMATCH\ *)
      # [log-review] 预期内：配置文件语法错误或目录不可写；降级原因：安装内容本身完整；
      # 影响范围：需手工修正配置，否则空闲 60 分钟后停止监听。
      log WARN "${stage}" "未能写回 location_idle_timeout=${cfg}（${result}），需手工设置 false"
      ;;
    *)
      log WARN "${stage}" "location_idle_timeout 检查输出异常：${result:-<空>}"
      ;;
  esac
}

install_hooks() {
  local stage="install-hooks"
  [ -x "${PRE_COMMIT_BIN}" ] || die "${stage}" "未找到 ${PRE_COMMIT_BIN}，无法注册 git hooks"
  [ -f "${PROJECT_ROOT}/.pre-commit-config.yaml" ] || die "${stage}" "缺少 .pre-commit-config.yaml"

  if (cd "${PROJECT_ROOT}" && "${PRE_COMMIT_BIN}" install --hook-type pre-commit --hook-type post-merge >>"${LOG_FILE}" 2>&1); then
    log PASS "${stage}" "pre-commit 与 post-merge hooks 已注册"
  else
    die "${stage}" "pre-commit install 失败"
  fi
}

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

  （无参数）   复制安装入口与共享库，并做静态自检
  --link       开发期符号链接安装：入口与共享库指向本仓库，改代码无需重装
  --verify     额外做加载断言：启动一次宿主进程，要求出现 issue-trigger loaded 且无 LoadError
  -h, --help   显示本帮助
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --link) LINK_MODE=1 ;;
      --verify) VERIFY_RUNTIME=1 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "args" "未知参数: $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  log INFO "start" "开始安装 opencode-issue-trigger"
  # Runtime directories are never committed; recreate them on install.
  mkdir -p "${PROJECT_ROOT}/issues" "${PROJECT_ROOT}/plan" "${PROJECT_ROOT}/memory" "${PROJECT_ROOT}/end_task"
  install_plugin
  verify_contents
  verify_single_install
  verify_plugin_list
  ensure_location_ttl
  install_hooks
  verify_load
  log PASS "done" "安装完成"
  printf '✅ opencode-issue-trigger installed（日志 log/install.%s.log）\n' "$(date +%Y%m%dT%H)"
}

main "$@"