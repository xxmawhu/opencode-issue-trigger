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
LOG_FILE="${LOG_DIR}/install.$(date +%Y%m%d).log"
CLEANUP_TARGET=""

log() {
  local level="$1"
  local stage="$2"
  local message="$3"
  printf '[%s] [%s] [stage:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${stage}" "${message}" >>"${LOG_FILE}"
}

die() {
  log ERROR "$1" "$2"
  printf '❌ %s（详见 log/install.%s.log）\n' "$2" "$(date +%Y%m%d)"
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
    printf '❌ 另一个 install.sh 正在运行（详见 log/install.%s.log）\n' "$(date +%Y%m%d)"
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
  cp -R "${src}/." "${tmp}/"
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
  cp "${src}" "${tmp}"
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

install_plugin() {
  local stage="install-plugin"
  log INFO "${stage}" "project=${PROJECT_ROOT} opencode=${OPENCODE_DIR}"

  [ -f "${PROJECT_ROOT}/plugin/issue-trigger.ts" ] || die "${stage}" "缺少 plugin/issue-trigger.ts"
  [ -d "${PROJECT_ROOT}/issue-trigger-lib" ] || die "${stage}" "缺少 issue-trigger-lib"

  remove_legacy
  mkdir -p "${OPENCODE_DIR}/plugin"

  install_file "${PROJECT_ROOT}/plugin/issue-trigger.ts" "${OPENCODE_DIR}/plugin/issue-trigger.ts"
  replace_dir "${PROJECT_ROOT}/issue-trigger-lib" "${OPENCODE_DIR}/issue-trigger-lib"

  [ -f "${OPENCODE_DIR}/plugin/issue-trigger.ts" ] || die "${stage}" "插件入口安装失败"
  [ -f "${OPENCODE_DIR}/issue-trigger-lib/index.mjs" ] || die "${stage}" "共享库安装失败"

  verify_permissions

  log PASS "${stage}" "插件已安装（v1 + v2 共用入口）"
}

install_hooks() {
  local stage="install-hooks"
  if ! command -v pre-commit >/dev/null 2>&1; then
    die "${stage}" "未找到 pre-commit，无法注册 git hooks"
  fi
  [ -f "${PROJECT_ROOT}/.pre-commit-config.yaml" ] || die "${stage}" "缺少 .pre-commit-config.yaml"

  if (cd "${PROJECT_ROOT}" && pre-commit install --hook-type pre-commit --hook-type post-merge >>"${LOG_FILE}" 2>&1); then
    log PASS "${stage}" "pre-commit 与 post-merge hooks 已注册"
  else
    die "${stage}" "pre-commit install 失败"
  fi
}

main() {
  log INFO "start" "开始安装 opencode-issue-trigger"
  # Runtime directories are never committed; recreate them on install.
  mkdir -p "${PROJECT_ROOT}/issues" "${PROJECT_ROOT}/plan" "${PROJECT_ROOT}/memory" "${PROJECT_ROOT}/end_task"
  install_plugin
  install_hooks
  log PASS "done" "安装完成"
  printf '✅ opencode-issue-trigger installed（日志 log/install.%s.log）\n' "$(date +%Y%m%d)"
}

main "$@"