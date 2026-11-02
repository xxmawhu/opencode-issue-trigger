#!/usr/bin/env bash
# One-click installer for opencode-issue-trigger.
# Installs the v1 and v2 plugin entries into the current user's opencode config
# and registers the repository git hooks through pre-commit.
set -euo pipefail

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

mkdir -p "${LOG_DIR}"
if ! mkdir -p "${OPENCODE_DIR}/plugin" "${OPENCODE_DIR}/plugins"; then
  die "start" "无法写入 opencode 配置目录：${OPENCODE_DIR}"
fi

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

install_plugin() {
  local stage="install-plugin"
  log INFO "${stage}" "project=${PROJECT_ROOT} opencode=${OPENCODE_DIR}"

  [ -f "${PROJECT_ROOT}/plugin/issue-trigger.ts" ] || die "${stage}" "缺少 plugin/issue-trigger.ts"
  [ -f "${PROJECT_ROOT}/plugins/issue-trigger/index.ts" ] || die "${stage}" "缺少 plugins/issue-trigger/index.ts"
  [ -d "${PROJECT_ROOT}/plugin/issue-trigger-lib" ] || die "${stage}" "缺少 plugin/issue-trigger-lib"

  mkdir -p "${OPENCODE_DIR}/plugin" "${OPENCODE_DIR}/plugins/issue-trigger"

  install_file "${PROJECT_ROOT}/plugin/issue-trigger.ts" "${OPENCODE_DIR}/plugin/issue-trigger.ts"
  replace_dir "${PROJECT_ROOT}/plugin/issue-trigger-lib" "${OPENCODE_DIR}/plugin/issue-trigger-lib"

  install_file "${PROJECT_ROOT}/plugins/issue-trigger/index.ts" "${OPENCODE_DIR}/plugins/issue-trigger/index.ts"
  replace_dir "${PROJECT_ROOT}/plugin/issue-trigger-lib" "${OPENCODE_DIR}/plugins/issue-trigger/issue-trigger-lib"

  [ -f "${OPENCODE_DIR}/plugin/issue-trigger.ts" ] || die "${stage}" "v1 入口安装失败"
  [ -f "${OPENCODE_DIR}/plugins/issue-trigger/index.ts" ] || die "${stage}" "v2 入口安装失败"
  [ -f "${OPENCODE_DIR}/plugin/issue-trigger-lib/index.mjs" ] || die "${stage}" "v1 库安装失败"
  [ -f "${OPENCODE_DIR}/plugins/issue-trigger/issue-trigger-lib/index.mjs" ] || die "${stage}" "v2 库安装失败"

  log PASS "${stage}" "v1+v2 插件已安装"
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
  install_plugin
  install_hooks
  log PASS "done" "安装完成"
  printf '✅ opencode-issue-trigger installed（日志 log/install.%s.log）\n' "$(date +%Y%m%d)"
}

main "$@"