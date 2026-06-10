#!/usr/bin/env bash

set -Eeuo pipefail

REPO_OWNER="${REPO_OWNER:-renaissance0721}"
REPO_NAME="${REPO_NAME:-singbox}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARGET_PATH="${TARGET_PATH:-/usr/local/bin/sbox}"
LEGACY_PATH="/usr/local/bin/singbox-manager"
INDEX_URL="${INDEX_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/index.sh}"
INSTALL_COMMAND=""

log() {
  printf '[*] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "该安装脚本仅支持 Linux VPS。"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 或 sudo 运行安装脚本。"
}

download_script() {
  if have_cmd curl; then
    curl -fsSL "$INDEX_URL"
  elif have_cmd wget; then
    wget -qO- "$INDEX_URL"
  else
    die "未检测到 curl 或 wget，无法下载 index.sh。"
  fi
}

attach_tty() {
  if [[ -t 0 && -t 1 ]]; then
    return 0
  fi

  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  exec </dev/tty >/dev/tty 2>&1
}

usage() {
  cat <<EOF
用法:
  bash install.sh

示例:
  bash install.sh
  bash install.sh --repair
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash -s -- --repair

Alpine Linux:
  apk add --no-cache bash curl
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | bash

参数:
  --repair          重新安装 / 修复环境并保留现有规则
  -h, --help        查看帮助
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --repair|--reinstall)
      INSTALL_COMMAND="repair-install"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

require_linux
require_root

mkdir -p "$(dirname "$TARGET_PATH")"
rm -f "$LEGACY_PATH" 2>/dev/null || true
download_script >"$TARGET_PATH"
chmod 755 "$TARGET_PATH"

log "管理脚本已安装到 $TARGET_PATH"

if [[ -n "$INSTALL_COMMAND" ]]; then
  "$TARGET_PATH" "$INSTALL_COMMAND"
fi

if [[ "${SBOX_INSTALL_NO_PANEL:-0}" == "1" ]]; then
  exit 0
fi

printf '\n管理脚本安装完成，正在打开 sbox 管理面板...\n\n'

if attach_tty; then
  exec "$TARGET_PATH"
fi

cat <<EOF
管理脚本已安装，但当前未检测到可交互终端。

请手动执行以下命令打开面板，并选择 1 安装 / 初始化 sing-box：
  sbox
EOF
