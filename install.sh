#!/usr/bin/env bash

set -Eeuo pipefail

REPO_OWNER="${REPO_OWNER:-renaissance0721}"
REPO_NAME="${REPO_NAME:-singbox}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARGET_PATH="${TARGET_PATH:-/usr/local/bin/singbox-manager}"
INDEX_URL="${INDEX_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/index.sh}"
RUN_AFTER_INSTALL=1
SERVER_ADDRESS="${SINGBOX_SERVER_ADDRESS:-${SERVER_ADDRESS:-}}"

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

usage() {
  cat <<EOF
用法:
  bash install.sh [--server-address <domain-or-ip>] [--skip-run] [--target <path>]

示例:
  bash install.sh
  bash install.sh --server-address node.example.com
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash -s -- --server-address node.example.com

参数:
  --server-address  指定节点对外地址，适合非交互安装
  --skip-run        仅安装管理脚本，不立即执行 quick-install
  --target          指定安装路径，默认 ${TARGET_PATH}
  -h, --help        查看帮助
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --server-address)
      [[ $# -ge 2 ]] || die "--server-address 需要一个值。"
      SERVER_ADDRESS="$2"
      shift 2
      ;;
    --skip-run)
      RUN_AFTER_INSTALL=0
      shift
      ;;
    --target)
      [[ $# -ge 2 ]] || die "--target 需要一个值。"
      TARGET_PATH="$2"
      shift 2
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
download_script >"$TARGET_PATH"
chmod 755 "$TARGET_PATH"

log "管理脚本已安装到 $TARGET_PATH"

if (( RUN_AFTER_INSTALL )); then
  if [[ -n "$SERVER_ADDRESS" ]]; then
    export SINGBOX_SERVER_ADDRESS="$SERVER_ADDRESS"
    log "将使用指定节点地址: $SERVER_ADDRESS"
  else
    log "未显式指定节点地址，将尝试自动探测公网 IP。"
  fi

  exec "$TARGET_PATH" quick-install
fi

cat <<EOF

已完成安装。你现在可以使用以下命令：

  sudo $TARGET_PATH
  sudo $TARGET_PATH quick-install
  sudo $TARGET_PATH show

如果需要非交互初始化，可执行：

  sudo SINGBOX_SERVER_ADDRESS=your.domain.com $TARGET_PATH quick-install
EOF
