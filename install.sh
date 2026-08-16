#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

REPO_OWNER="${REPO_OWNER:-renaissance0721}"
REPO_NAME="${REPO_NAME:-singbox}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARGET_PATH="${TARGET_PATH:-/usr/local/bin/sbox}"
LEGACY_PATH="/usr/local/bin/singbox-manager"
INDEX_URL="${INDEX_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/index.sh}"
EXPECTED_INDEX_SHA256="15b760f6348e35c0c73c3f17f01b3520ac78169163316b3d36de9ed90380d0eb"
INSTALL_COMMAND=""
SCRIPT_DIR=""
INSTALLER_SOURCE=""
DOWNLOAD_TMP=""
INSTALL_TMP=""

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
  local destination=$1
  if have_cmd curl; then
    curl -fsSL "$INDEX_URL" -o "$destination"
  elif have_cmd wget; then
    wget -qO "$destination" "$INDEX_URL"
  else
    die "未检测到 curl 或 wget，无法下载 index.sh。"
  fi
}

sha256_file() {
  local file=$1
  if have_cmd sha256sum; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif have_cmd openssl; then
    openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
  else
    die "缺少 sha256sum 或 openssl，无法验证管理脚本完整性。"
  fi
}

cleanup() {
  [[ -n "$DOWNLOAD_TMP" ]] && rm -f -- "$DOWNLOAD_TMP" 2>/dev/null || true
  [[ -n "$INSTALL_TMP" ]] && rm -f -- "$INSTALL_TMP" 2>/dev/null || true
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
  sudo bash install.sh
  sudo bash install.sh --repair
  git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git
  cd ${REPO_NAME} && sudo bash install.sh

Alpine Linux:
  apk add --no-cache bash curl git
  git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git
  cd ${REPO_NAME} && bash install.sh

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

trap cleanup EXIT
require_linux
require_root

if [[ -v BASH_SOURCE ]]; then
  INSTALLER_SOURCE="${BASH_SOURCE[0]}"
fi
if [[ "$INSTALLER_SOURCE" == */* && -f "$INSTALLER_SOURCE" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$INSTALLER_SOURCE")" && pwd)"
fi

DOWNLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/sbox-index.XXXXXX")"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/index.sh" && "${SBOX_INSTALL_FORCE_REMOTE:-0}" != "1" ]]; then
  cp "$SCRIPT_DIR/index.sh" "$DOWNLOAD_TMP"
else
  download_script "$DOWNLOAD_TMP"
fi

actual_sha256="$(sha256_file "$DOWNLOAD_TMP")"
[[ "$EXPECTED_INDEX_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || die "安装器内置的 index.sh 哈希无效。"
[[ "$actual_sha256" == "${EXPECTED_INDEX_SHA256,,}" ]] ||
  die "index.sh 完整性校验失败；期望 ${EXPECTED_INDEX_SHA256,,}，实际 ${actual_sha256}。"
bash -n "$DOWNLOAD_TMP" || die "index.sh Bash 语法检查失败，已拒绝安装。"

install -d -m 0755 "$(dirname "$TARGET_PATH")"
rm -f "$LEGACY_PATH" 2>/dev/null || true
INSTALL_TMP="$(mktemp "$(dirname "$TARGET_PATH")/.sbox-install.XXXXXX")"
install -o root -g root -m 0755 "$DOWNLOAD_TMP" "$INSTALL_TMP"
mv -f "$INSTALL_TMP" "$TARGET_PATH"
INSTALL_TMP=""
cleanup

log "管理脚本已安装到 $TARGET_PATH"

"$TARGET_PATH" migrate-realm-tcp-only

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
