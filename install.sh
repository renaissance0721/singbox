#!/usr/bin/env bash

set -Eeuo pipefail

REPO_OWNER="${REPO_OWNER:-renaissance0721}"
REPO_NAME="${REPO_NAME:-singbox}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARGET_PATH="${TARGET_PATH:-/usr/local/bin/sbox}"
LEGACY_PATH="/usr/local/bin/singbox-manager"
INDEX_URL="${INDEX_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/index.sh}"
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
  [[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux VPS."
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run the installer as root or with sudo."
}

download_script() {
  if have_cmd curl; then
    curl -fsSL "$INDEX_URL"
  elif have_cmd wget; then
    wget -qO- "$INDEX_URL"
  else
    die "curl or wget is required to download index.sh."
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
Usage:
  bash install.sh [--server-address <domain-or-ip>]

Examples:
  bash install.sh
  bash install.sh --server-address node.example.com
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/install.sh | sudo bash -s -- --server-address node.example.com

Options:
  --server-address  Set the public server domain or IP for non-interactive installation
  -h, --help        Show help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --server-address)
      [[ $# -ge 2 ]] || die "--server-address requires a value."
      SERVER_ADDRESS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_linux
require_root

mkdir -p "$(dirname "$TARGET_PATH")"
rm -f "$LEGACY_PATH" 2>/dev/null || true
download_script >"$TARGET_PATH"
chmod 755 "$TARGET_PATH"

log "Management script installed to $TARGET_PATH"

if [[ -n "$SERVER_ADDRESS" ]]; then
  export SINGBOX_SERVER_ADDRESS="$SERVER_ADDRESS"
  log "Using explicit server address: $SERVER_ADDRESS"
else
  log "No explicit server address provided. Trying to detect the public IP automatically."
fi

"$TARGET_PATH" quick-install

printf '\nInstallation completed. Opening the sbox management panel...\n\n'

if attach_tty; then
  exec "$TARGET_PATH"
fi

cat <<EOF
Installation completed, but no interactive terminal was detected.

Run the following command to open the panel manually:
  sbox
EOF
