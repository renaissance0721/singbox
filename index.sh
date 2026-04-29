#!/usr/bin/env bash
#
# Sing-box 一键安装与管理面板
# 用于在 Linux VPS 上快速安装和管理 sing-box 的 Shell 脚本
# 支持 Shadowsocks 2022、VLESS + Reality 和 Hysteria2
#
# 作者: renaissance0721
# 版本: 0.1.0
# 许可证: MIT
#
# 使用方法:
#   sbox                        打开管理面板
#   sbox quick-install          一键安装并初始化
#   sbox add-client             打开新增客户端流程
#   sbox remove-client          打开删除客户端流程
#   sbox show                   查看客户端信息
#   SINGBOX_SERVER_ADDRESS=your.domain sbox quick-install
#

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")
SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_VERSION="0.1.0"
SCRIPT_NAME="${0##*/}"
APP_TITLE="Sing-box 管理面板 | 输入 sbox 快捷打开脚本"
STATE_DIR="${STATE_DIR:-/etc/sing-box-manager}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
CLIENT_DIR="${CLIENT_DIR:-$STATE_DIR/clients}"
CERT_DIR="${CERT_DIR:-$STATE_DIR/certs}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
REALM_DIR="${REALM_DIR:-/etc/realm}"
REALM_CONFIG_FILE="${REALM_CONFIG_FILE:-$REALM_DIR/config.toml}"
REALM_STATE_FILE="${REALM_STATE_FILE:-$STATE_DIR/realm-state.json}"
REALM_BIN="${REALM_BIN:-/usr/local/bin/realm}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-/etc/systemd/system/realm.service}"
MANAGER_SCRIPT_PATH="${MANAGER_SCRIPT_PATH:-/usr/local/bin/sbox}"
SCRIPT_REPO_OWNER="${SCRIPT_REPO_OWNER:-renaissance0721}"
SCRIPT_REPO_NAME="${SCRIPT_REPO_NAME:-singbox}"
SCRIPT_REPO_BRANCH="${SCRIPT_REPO_BRANCH:-main}"
TMP_DIR="${TMP_DIR:-/tmp}"

HAS_WHIPTAIL=0
PKG_MANAGER=""

if [[ "$SELF_PATH" != /* ]]; then
  if resolved_path="$(command -v "$SELF_PATH" 2>/dev/null)"; then
    SELF_PATH="$resolved_path"
  elif [[ -f "$SELF_PATH" ]]; then
    SELF_PATH="$(cd "$(dirname "$SELF_PATH")" && pwd)/$(basename "$SELF_PATH")"
  fi
fi

setup_terminal_env() {
  local locale_candidate=""

  if ! is_interactive; then
    return 0
  fi

  if [[ -z "${TERM:-}" || "${TERM:-}" == "dumb" ]]; then
    export TERM="xterm-256color"
  fi

  if have_cmd locale; then
    while IFS= read -r locale_candidate; do
      case "$locale_candidate" in
        zh_CN.UTF-8|zh_CN.utf8)
          export LANG="$locale_candidate"
          export LC_CTYPE="$locale_candidate"
          return 0
          ;;
      esac
    done < <(locale -a 2>/dev/null || true)

    while IFS= read -r locale_candidate; do
      case "$locale_candidate" in
        C.UTF-8|C.utf8|en_US.UTF-8|en_US.utf8)
          export LANG="$locale_candidate"
          export LC_CTYPE="$locale_candidate"
          return 0
          ;;
      esac
    done < <(locale -a 2>/dev/null || true)
  fi
}

init_ui() {
  HAS_WHIPTAIL=0
}

ensure_ui_backend() {
  init_ui
}

log() {
  printf '[*] %s\n' "$*" >&2
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_to_file() {
  local destination=$1
  shift
  local url

  if have_cmd curl; then
    for url in "$@"; do
      if curl -fsSL "$url" -o "$destination"; then
        return 0
      fi
    done
  elif have_cmd wget; then
    for url in "$@"; do
      if wget -qO "$destination" "$url"; then
        return 0
      fi
    done
  else
    die "未检测到 curl 或 wget，无法下载文件。"
  fi

  return 1
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  if have_cmd sudo; then
    exec sudo -E bash "$SELF_PATH" "${ORIGINAL_ARGS[@]}"
  fi

  die "请使用 root 运行此脚本，或先安装 sudo。"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "该脚本仅支持 Linux VPS。"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$CLIENT_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")"
  mkdir -p "$CLIENT_DIR/shadowsocks" "$CLIENT_DIR/vless-reality" "$CLIENT_DIR/hysteria2"
}

ensure_realm_dirs() {
  mkdir -p "$REALM_DIR" "$STATE_DIR"
}

ui_pause() {
  if is_interactive; then
    printf '按回车键返回菜单...' >&2
    read -r _
    printf '\n' >&2
  fi
}

ui_msg() {
  local text=${1:-}
  printf '\n========================================\n' >&2
  printf '%s\n' "$APP_TITLE" >&2
  printf '========================================\n' >&2
  printf '%s\n\n' "$text" >&2
  ui_pause
}

ui_show_text() {
  local title=${1:-$APP_TITLE}
  local text=${2:-}
  printf '\n========================================\n' >&2
  printf '%s\n' "$title" >&2
  printf '========================================\n' >&2
  printf '%s\n\n' "$text" >&2
  ui_pause
}

ui_yesno() {
  local text=${1:-}
  if (( HAS_WHIPTAIL )); then
    whiptail --title "$APP_TITLE" --yesno "$text" 16 78
  else
    local answer
    read -r -p "$text [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
  fi
}

ui_input() {
  local title=${1:-$APP_TITLE}
  local text=${2:-}
  local default_value=${3:-}
  local result=""

  if (( HAS_WHIPTAIL )); then
    result="$(whiptail --title "$title" --inputbox "$text" 16 78 "$default_value" 3>&1 1>&2 2>&3)" || return 1
  else
    read -r -p "$text [$default_value]: " result || return 1
    result=${result:-$default_value}
  fi

  printf '%s\n' "$result"
}

ui_password() {
  local title=${1:-$APP_TITLE}
  local text=${2:-}
  local result=""

  if (( HAS_WHIPTAIL )); then
    result="$(whiptail --title "$title" --passwordbox "$text" 16 78 3>&1 1>&2 2>&3)" || return 1
  else
    read -r -s -p "$text: " result || return 1
    printf '\n' >&2
  fi

  printf '%s\n' "$result"
}

ui_menu() {
  local title=$1
  local text=$2
  shift 2

  printf '\n========================================\n' >&2
  printf '%s\n' "$title" >&2
  printf '========================================\n' >&2
  printf '%s\n' "$text" >&2
  while (( $# >= 2 )); do
    printf '  %s) %s\n' "$1" "$2" >&2
    shift 2
  done
  local choice
  read -r -p "您要进行的操作是: " choice
  printf '%s\n' "$choice"
}

ui_protocol_menu() {
  ui_menu "$APP_TITLE" "请选择需要操作的协议" \
    "1" "Shadowsocks 2022" \
    "2" "VLESS + Reality" \
    "3" "Hysteria2" \
    "0" "返回"
}

detect_pkg_manager() {
  if have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif have_cmd yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER=""
  fi
}

install_dependencies() {
  detect_pkg_manager

  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y curl jq openssl ca-certificates whiptail uuid-runtime iproute2
      ;;
    dnf)
      dnf install -y curl jq openssl ca-certificates newt util-linux iproute
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y curl jq openssl ca-certificates newt util-linux iproute
      ;;
    *)
      die "暂不支持自动安装依赖，请手动安装 curl、jq、openssl、whiptail、uuidgen 后再运行。"
      ;;
  esac

  init_ui
}

install_sing_box() {
  if have_cmd sing-box; then
    log "检测到 sing-box 已安装，开始通过官方安装脚本检查并更新到最新版本..."
  else
    log "开始通过官方安装脚本安装 sing-box..."
  fi

  curl -fsSL https://sing-box.app/install.sh | sh

  ensure_sing_box_service

  if has_systemd; then
    systemctl enable sing-box >/dev/null 2>&1 || true
  fi
}

has_systemd() {
  have_cmd systemctl && [[ -d /run/systemd/system ]]
}

service_exists() {
  has_systemd || return 1

  systemctl cat sing-box >/dev/null 2>&1 && return 0
  systemctl list-unit-files sing-box.service --no-legend 2>/dev/null | grep -q '^sing-box\.service' && return 0
  [[ -f /etc/systemd/system/sing-box.service || -f /lib/systemd/system/sing-box.service || -f /usr/lib/systemd/system/sing-box.service ]]
}

ensure_sing_box_service() {
  local sing_box_bin

  has_systemd || return 0
  service_exists && return 0

  sing_box_bin="$(command -v sing-box 2>/dev/null || true)"
  [[ -n "$sing_box_bin" ]] || return 0

  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${sing_box_bin} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
}

restart_sing_box() {
  if service_exists; then
    systemctl enable sing-box >/dev/null 2>&1 || true
    if ! systemctl restart sing-box; then
      ui_show_text "sing-box 启动失败" "$(journalctl -u sing-box -n 30 --no-pager 2>/dev/null || echo '无法读取 sing-box 日志。')"
      return 1
    fi
  else
    warn "未检测到 sing-box systemd 服务，请手动启动 sing-box。"
  fi
}

stop_sing_box() {
  if service_exists; then
    systemctl stop sing-box >/dev/null 2>&1 || true
  fi
}

realm_service_exists() {
  has_systemd || return 1

  systemctl cat realm >/dev/null 2>&1 && return 0
  systemctl list-unit-files realm.service --no-legend 2>/dev/null | grep -q '^realm\.service' && return 0
  [[ -f "$REALM_SERVICE_FILE" || -f /lib/systemd/system/realm.service || -f /usr/lib/systemd/system/realm.service ]]
}

ensure_realm_service() {
  has_systemd || return 0

  cat >"$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=Realm relay service
Documentation=https://github.com/zhboner/realm
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
}

detect_realm_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64-unknown-linux-gnu\n'
      ;;
    aarch64|arm64)
      printf 'aarch64-unknown-linux-gnu\n'
      ;;
    armv7l|armv7)
      printf 'armv7-unknown-linux-gnueabihf\n'
      ;;
    *)
      return 1
      ;;
  esac
}

install_realm_binary() {
  local arch tmp_dir archive_path extracted_bin
  arch="$(detect_realm_arch)" || die "当前架构暂不支持自动安装 Realm：$(uname -m)"
  tmp_dir="$(mktemp -d "$TMP_DIR/realm-install.XXXXXX")"
  archive_path="$tmp_dir/realm.tar.gz"

  if ! download_to_file \
    "$archive_path" \
    "https://github.com/zhboner/realm/releases/latest/download/realm-${arch}.tar.gz"; then
    rm -rf "$tmp_dir"
    die "下载 Realm 失败，请稍后重试。"
  fi

  tar -xzf "$archive_path" -C "$tmp_dir"
  extracted_bin="$(find "$tmp_dir" -type f -name realm | head -n 1)"
  [[ -n "$extracted_bin" ]] || {
    rm -rf "$tmp_dir"
    die "无法从下载包中找到 realm 可执行文件。"
  }

  install -m 755 "$extracted_bin" "$REALM_BIN"
  rm -rf "$tmp_dir"
}

detect_public_address() {
  local addr=""

  if have_cmd curl; then
    addr="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$addr" ]]; then
      addr="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$addr" ]] && have_cmd hostname; then
    addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s\n' "$addr"
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "$1" == *:* ]]
}

generate_uuid() {
  if have_cmd uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
  fi
}

generate_password() {
  openssl rand -base64 24 | tr -d '\n=' | cut -c1-24
}

generate_hex() {
  local bytes=${1:-8}
  openssl rand -hex "$bytes" | tr -d '\n'
}

generate_vless_port() {
  printf '%s\n' "$((10000 + RANDOM % 50001))"
}

generate_base64_bytes() {
  local length=${1:-32}
  if have_cmd sing-box; then
    sing-box generate rand --base64 "$length" | tr -d '\n'
  else
    openssl rand -base64 "$length" | tr -d '\n'
  fi
}

generate_reality_keypair() {
  local output private_key public_key
  output="$(sing-box generate reality-keypair 2>/dev/null || true)"
  private_key="$(printf '%s\n' "$output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$output" | awk -F': ' '/PublicKey/ {print $2; exit}')"

  [[ -n "$private_key" && -n "$public_key" ]] || die "无法生成 Reality 密钥对，请确认 sing-box 已正确安装。"

  printf '%s\t%s\n' "$private_key" "$public_key"
}

backup_config_if_exists() {
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
  fi
}

init_state_file() {
  if [[ -s "$STATE_FILE" ]]; then
    migrate_state_schema
    return 0
  fi

  local now vless_default_port
  now="$(utc_now)"
  vless_default_port="$(generate_vless_port)"

  cat >"$STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "node_name": "",
    "server_address": "",
    "created_at": "$now",
    "updated_at": "$now",
    "log_level": "info"
  },
  "protocols": {
    "shadowsocks": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": 8388,
      "network": "tcp",
      "method": "2022-blake3-aes-256-gcm",
      "server_password": "",
      "multiplex": true,
      "users": []
    },
    "vless_reality": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": $vless_default_port,
      "server_name": "www.tesla.com",
      "handshake_server": "www.tesla.com",
      "handshake_port": 443,
      "private_key": "",
      "public_key": "",
      "short_id": "",
      "users": []
    },
    "hysteria2": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": 8443,
      "up_mbps": 100,
      "down_mbps": 100,
      "tls_server_name": "",
      "cert_path": "$CERT_DIR/hysteria2.crt",
      "key_path": "$CERT_DIR/hysteria2.key",
      "obfs_password": "",
      "masquerade": "https://www.bing.com",
      "users": []
    }
  },
  "routing": {
    "ai": {
      "enabled": false,
      "outbound_type": "shadowsocks",
      "server": "",
      "port": 443,
      "method": "chacha20-ietf-poly1305",
      "password": "",
      "uuid": "",
      "flow": "",
      "tls_enabled": false,
      "tls_server_name": "",
      "tls_insecure": false,
      "reality_enabled": false,
      "reality_public_key": "",
      "reality_short_id": "",
      "network": "tcp",
      "domain_suffix": [
        "openai.com",
        "chatgpt.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "anthropic.com",
        "claude.ai",
        "perplexity.ai",
        "poe.com",
        "sora.com",
        "x.ai",
        "grok.com",
        "deepseek.com",
        "deepseek.ai",
        "generativelanguage.googleapis.com",
        "aistudio.google.com",
        "gemini.google.com"
      ],
      "domain_keyword": [
        "openai",
        "chatgpt",
        "gpt",
        "anthropic",
        "claude",
        "perplexity",
        "gemini"
      ],
      "ip_cidr": [],
      "resolved_ip_cidr": []
    }
  }
}
EOF
}

state_get() {
  jq -r "$1" "$STATE_FILE"
}

state_jq() {
  local tmp_file
  tmp_file="$(mktemp "$TMP_DIR/singbox-state.XXXXXX")"
  jq "$@" "$STATE_FILE" >"$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

migrate_state_schema() {
  if jq -e '
    (.routing.ai.enabled? != null)
    and (.routing.ai.domain_suffix? != null)
    and (.routing.ai.domain_keyword? != null)
    and (.routing.ai.uuid? != null)
    and (.routing.ai.flow? != null)
    and (.routing.ai.tls_enabled? != null)
    and (.routing.ai.tls_server_name? != null)
    and (.routing.ai.tls_insecure? != null)
    and (.routing.ai.reality_enabled? != null)
    and (.routing.ai.reality_public_key? != null)
    and (.routing.ai.reality_short_id? != null)
    and (.routing.ai.ip_cidr? != null)
    and (.routing.ai.resolved_ip_cidr? != null)
  ' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  state_jq --arg ts "$(utc_now)" '
    .routing = (.routing // {}) |
    .routing.ai = (.routing.ai // {}) |
    .routing.ai.enabled = (.routing.ai.enabled // false) |
    .routing.ai.outbound_type = (.routing.ai.outbound_type // "shadowsocks") |
    .routing.ai.server = (.routing.ai.server // "") |
    .routing.ai.port = (.routing.ai.port // 443) |
    .routing.ai.method = (.routing.ai.method // "chacha20-ietf-poly1305") |
    .routing.ai.password = (.routing.ai.password // "") |
    .routing.ai.uuid = (.routing.ai.uuid // "") |
    .routing.ai.flow = (.routing.ai.flow // "") |
    .routing.ai.tls_enabled = (.routing.ai.tls_enabled // false) |
    .routing.ai.tls_server_name = (.routing.ai.tls_server_name // "") |
    .routing.ai.tls_insecure = (.routing.ai.tls_insecure // false) |
    .routing.ai.reality_enabled = (.routing.ai.reality_enabled // false) |
    .routing.ai.reality_public_key = (.routing.ai.reality_public_key // "") |
    .routing.ai.reality_short_id = (.routing.ai.reality_short_id // "") |
    .routing.ai.network = (.routing.ai.network // "tcp") |
    .routing.ai.domain_suffix = (.routing.ai.domain_suffix // [
      "openai.com",
      "chatgpt.com",
      "oaistatic.com",
      "oaiusercontent.com",
      "anthropic.com",
      "claude.ai",
      "perplexity.ai",
      "poe.com",
      "sora.com",
      "x.ai",
      "grok.com",
      "deepseek.com",
      "deepseek.ai",
      "generativelanguage.googleapis.com",
      "aistudio.google.com",
      "gemini.google.com"
    ]) |
    .routing.ai.domain_keyword = (.routing.ai.domain_keyword // [
      "openai",
      "chatgpt",
      "gpt",
      "anthropic",
      "claude",
      "perplexity",
      "gemini"
    ]) |
    .routing.ai.ip_cidr = (.routing.ai.ip_cidr // []) |
    .routing.ai.resolved_ip_cidr = (.routing.ai.resolved_ip_cidr // []) |
    .meta.updated_at = $ts
  '
}

format_ai_rule_list() {
  jq -r '((.routing.ai.domain_suffix // []) + (.routing.ai.domain_keyword // []) + (.routing.ai.ip_cidr // [])) | join(", ")' "$STATE_FILE"
}

build_ai_rules_json() {
  local input=$1
  jq -nc --arg input "$input" '
    def is_ipv4:
      test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$");
    def is_ipv4_cidr:
      test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$");
    def is_ipv6:
      (contains(":") and test("^[0-9a-f:]+$"));
    def is_ipv6_cidr:
      test("^[0-9a-f:]+/[0-9]{1,3}$");
    def is_ip_rule:
      is_ipv4 or is_ipv4_cidr or is_ipv6 or is_ipv6_cidr;
    def to_ip_cidr:
      if is_ipv4 then . + "/32"
      elif is_ipv6 then . + "/128"
      elif is_ipv4_cidr or is_ipv6_cidr then .
      else empty
      end;
    def normalized_items:
      (. // "" | tostring | ascii_downcase)
      | gsub("，|、|；"; ",")
      | gsub("[,;[:space:]]+"; ",")
      | split(",")
      | map(
          (. // "" | tostring)
          | gsub("^\\s+|\\s+$"; "")
          | sub("^[a-z][a-z0-9+.-]*://"; "")
          | sub("^//"; "")
          | if ((is_ipv4_cidr or is_ipv6_cidr) | not) then split("/")[0] else . end
          | (. // "" | tostring)
          | sub("^\\["; "")
          | sub("\\]$"; "")
          | if contains(".") then sub(":[0-9]+$"; "") else . end
          | sub("^\\*\\."; "")
          | sub("^\\."; "")
        )
      | map(select(length > 0))
      | unique;

    ($input | normalized_items) as $items |
    {
      domain_suffix: ($items | map(select((is_ip_rule | not) and contains(".")))),
      domain_keyword: ($items | map(select((is_ip_rule | not) and (contains(".") | not)))),
      ip_cidr: ($items | map(select(is_ip_rule) | to_ip_cidr))
    }
  '
}

ip_to_cidr() {
  local ip=$1
  ip="${ip%$'\r'}"
  ip="${ip%$'\n'}"

  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32\n' "$ip"
  elif [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    printf '%s\n' "$ip"
  elif [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    printf '%s/128\n' "$ip"
  elif [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
  fi
}

ai_resolve_domain_candidates() {
  local domain=$1

  printf '%s\n' "$domain"

  case "$domain" in
    openai.com)
      printf '%s\n' \
        "api.openai.com" \
        "auth.openai.com" \
        "auth0.openai.com" \
        "chat.openai.com" \
        "ios.chat.openai.com" \
        "android.chat.openai.com"
      ;;
    chatgpt.com)
      printf '%s\n' \
        "chatgpt.com" \
        "www.chatgpt.com"
      ;;
    anthropic.com)
      printf '%s\n' \
        "api.anthropic.com" \
        "console.anthropic.com"
      ;;
    claude.ai)
      printf '%s\n' \
        "claude.ai" \
        "api.claude.ai"
      ;;
    gemini.google.com)
      printf '%s\n' \
        "gemini.google.com"
      ;;
    generativelanguage.googleapis.com)
      printf '%s\n' \
        "generativelanguage.googleapis.com"
      ;;
    aistudio.google.com)
      printf '%s\n' \
        "aistudio.google.com"
      ;;
    perplexity.ai)
      printf '%s\n' \
        "perplexity.ai" \
        "www.perplexity.ai" \
        "api.perplexity.ai"
      ;;
    poe.com)
      printf '%s\n' \
        "poe.com" \
        "www.poe.com"
      ;;
  esac

  if [[ "$domain" == *.* ]]; then
    printf '%s\n' "www.${domain}" "api.${domain}"
  fi
}

refresh_ai_resolved_ip_cidrs() {
  local tmp_raw tmp_sorted cidrs_json domain resolve_domain ip cidr resolved_count

  [[ "$(state_get '.routing.ai.enabled // false')" == "true" ]] || return 0
  have_cmd getent || return 0

  tmp_raw="$(mktemp "$TMP_DIR/sbox-ai-ip-raw.XXXXXX")"
  tmp_sorted="$(mktemp "$TMP_DIR/sbox-ai-ip.XXXXXX")"

  while IFS= read -r domain; do
    [[ -n "$domain" && "$domain" != "null" ]] || continue
    while IFS= read -r resolve_domain; do
      [[ -n "$resolve_domain" ]] || continue
      while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        cidr="$(ip_to_cidr "$ip")"
        [[ -n "$cidr" ]] && printf '%s\n' "$cidr" >>"$tmp_raw"
      done < <(getent ahosts "$resolve_domain" 2>/dev/null | awk '{print $1}' || true)
    done < <(ai_resolve_domain_candidates "$domain" | sort -u)
  done < <(jq -r '.routing.ai.domain_suffix[]? // empty' "$STATE_FILE")

  sort -u "$tmp_raw" >"$tmp_sorted"
  resolved_count="$(wc -l <"$tmp_sorted" | tr -d '[:space:]')"

  if [[ "${resolved_count:-0}" -gt 0 ]]; then
    cidrs_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$tmp_sorted")"
    state_jq --argjson cidrs "$cidrs_json" --arg ts "$(utc_now)" '
      .routing.ai.resolved_ip_cidr = $cidrs |
      .meta.updated_at = $ts
    '
    log "AI 分流已刷新 ${resolved_count} 条域名解析 IP 兜底规则。"
  else
    warn "未解析到 AI 分流域名 IP，保留上一次的 IP 兜底规则。"
  fi

  rm -f "$tmp_raw" "$tmp_sorted"
}

init_realm_state_file() {
  if [[ -s "$REALM_STATE_FILE" ]]; then
    return 0
  fi

  local now
  now="$(utc_now)"

  cat >"$REALM_STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "updated_at": "$now"
  },
  "global": {
    "log_level": "warn",
    "log_output": "stdout",
    "use_udp": true,
    "no_tcp": false
  },
  "rules": []
}
EOF
}

realm_state_get() {
  jq -r "$1" "$REALM_STATE_FILE"
}

realm_state_jq() {
  local tmp_file
  tmp_file="$(mktemp "$TMP_DIR/realm-state.XXXXXX")"
  jq "$@" "$REALM_STATE_FILE" >"$tmp_file"
  mv "$tmp_file" "$REALM_STATE_FILE"
}

uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

base64_urlsafe() {
  printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

format_uri_host() {
  local host=$1
  if is_ipv6 "$host"; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

direct_links_file() {
  printf '%s/direct-links.txt\n' "$CLIENT_DIR"
}

nekobox_route_rule_file() {
  printf '%s/nekobox-ai-route-rule.json\n' "$CLIENT_DIR"
}

nekobox_domain_rules_file() {
  printf '%s/nekobox-ai-domain-rules.txt\n' "$CLIENT_DIR"
}

nekobox_ip_rules_file() {
  printf '%s/nekobox-ai-ip-rules.txt\n' "$CLIENT_DIR"
}

nekobox_guide_file() {
  printf '%s/nekobox-ai-routing-guide.txt\n' "$CLIENT_DIR"
}

nekobox_clash_meta_file() {
  printf '%s/nekobox-ai-clash-meta.yaml\n' "$CLIENT_DIR"
}

yaml_quote() {
  jq -Rn --arg v "$1" '$v | @json'
}

render_nekobox_route_rule_json() {
  jq '{
    domain: (.routing.ai.domain_suffix // [] | map(select(contains("."))) | unique),
    domain_suffix: (.routing.ai.domain_suffix // [] | map(select(contains("."))) | map(if startswith(".") then . else "." + . end) | unique),
    domain_keyword: (.routing.ai.domain_keyword // [] | unique),
    ip_cidr: (((.routing.ai.ip_cidr // []) + (.routing.ai.resolved_ip_cidr // [])) | unique),
    outbound: "proxy"
  }' "$STATE_FILE"
}

render_nekobox_domain_rules() {
  jq -r '
    [
      (.routing.ai.domain_suffix // [] | unique | map("domain:" + .)[]?),
      (.routing.ai.domain_keyword // [] | unique | map("keyword:" + .)[]?)
    ] | join("\n")
  ' "$STATE_FILE"
}

render_nekobox_ip_rules() {
  jq -r '(((.routing.ai.ip_cidr // []) + (.routing.ai.resolved_ip_cidr // [])) | unique | join("\n"))' "$STATE_FILE"
}

append_clash_ss_proxy() {
  local file=$1 name=$2 server=$3 port=$4 method=$5 password=$6

  cat >>"$file" <<EOF
  - name: $(yaml_quote "$name")
    type: ss
    server: $(yaml_quote "$server")
    port: $port
    cipher: $(yaml_quote "$method")
    password: $(yaml_quote "$password")
    udp: true
EOF
}

append_clash_vless_proxy() {
  local file=$1 name=$2 server=$3 port=$4 uuid=$5 flow=$6 tls_enabled=$7 server_name=$8 insecure=$9 reality_enabled=${10} public_key=${11} short_id=${12}

  cat >>"$file" <<EOF
  - name: $(yaml_quote "$name")
    type: vless
    server: $(yaml_quote "$server")
    port: $port
    uuid: $(yaml_quote "$uuid")
    network: tcp
    udp: true
EOF

  if [[ -n "$flow" && "$flow" != "null" ]]; then
    printf '    flow: %s\n' "$(yaml_quote "$flow")" >>"$file"
  fi

  if [[ "$tls_enabled" == "true" || "$reality_enabled" == "true" ]]; then
    cat >>"$file" <<EOF
    tls: true
    client-fingerprint: chrome
EOF
    [[ -n "$server_name" && "$server_name" != "null" ]] && printf '    servername: %s\n' "$(yaml_quote "$server_name")" >>"$file"
    [[ "$insecure" == "true" ]] && printf '    skip-cert-verify: true\n' >>"$file"
    if [[ "$reality_enabled" == "true" ]]; then
      cat >>"$file" <<EOF
    reality-opts:
      public-key: $(yaml_quote "$public_key")
      short-id: $(yaml_quote "$short_id")
EOF
    fi
  fi
}

append_clash_hysteria2_proxy() {
  local file=$1 name=$2 server=$3 port=$4 password=$5 sni=$6 obfs_password=$7

  cat >>"$file" <<EOF
  - name: $(yaml_quote "$name")
    type: hysteria2
    server: $(yaml_quote "$server")
    port: $port
    password: $(yaml_quote "$password")
    sni: $(yaml_quote "$sni")
    skip-cert-verify: true
    udp: true
EOF

  if [[ -n "$obfs_password" && "$obfs_password" != "null" ]]; then
    cat >>"$file" <<EOF
    obfs: salamander
    obfs-password: $(yaml_quote "$obfs_password")
EOF
  fi
}

append_clash_rule_lines() {
  local file=$1

  while IFS= read -r domain; do
    [[ -n "$domain" ]] && printf '  - DOMAIN-SUFFIX,%s,AI分流\n' "$domain" >>"$file"
  done < <(jq -r '.routing.ai.domain_suffix[]? // empty' "$STATE_FILE")

  while IFS= read -r keyword; do
    [[ -n "$keyword" ]] && printf '  - DOMAIN-KEYWORD,%s,AI分流\n' "$keyword" >>"$file"
  done < <(jq -r '.routing.ai.domain_keyword[]? // empty' "$STATE_FILE")

  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    if [[ "$cidr" == *:* ]]; then
      printf '  - IP-CIDR6,%s,AI分流,no-resolve\n' "$cidr" >>"$file"
    else
      printf '  - IP-CIDR,%s,AI分流,no-resolve\n' "$cidr" >>"$file"
    fi
  done < <(jq -r '((.routing.ai.ip_cidr // []) + (.routing.ai.resolved_ip_cidr // [])) | unique | .[]?' "$STATE_FILE")

  printf '  - MATCH,普通代理\n' >>"$file"
}

write_nekobox_clash_meta_config() {
  local file server_address node_name normal_group_has_proxy=0 ai_enabled ai_type
  local ss_port ss_method ss_server_password vless_port vless_server_name vless_public_key vless_short_id
  local hy2_port hy2_sni hy2_obfs ai_name local_proxy_name
  local -a normal_names=()

  file="$(nekobox_clash_meta_file)"
  server_address="$(state_get '.meta.server_address')"
  node_name="$(state_get '.meta.node_name')"
  ai_enabled="$(state_get '.routing.ai.enabled // false')"

  cat >"$file" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
EOF

  if [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]]; then
    ss_port="$(state_get '.protocols.shadowsocks.port')"
    ss_method="$(state_get '.protocols.shadowsocks.method')"
    ss_server_password="$(state_get '.protocols.shadowsocks.server_password')"
    while IFS=$'\t' read -r name user_password; do
      [[ -n "$name" ]] || continue
      local_proxy_name="${node_name:-VPS}-SS-${name}"
      append_clash_ss_proxy "$file" "$local_proxy_name" "$server_address" "$ss_port" "$ss_method" "${ss_server_password}:${user_password}"
      normal_names+=("$local_proxy_name")
      normal_group_has_proxy=1
    done < <(jq -r '.protocols.shadowsocks.users[]? | [.name, .password] | @tsv' "$STATE_FILE")
  fi

  if [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]]; then
    vless_port="$(state_get '.protocols.vless_reality.port')"
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    vless_public_key="$(state_get '.protocols.vless_reality.public_key')"
    vless_short_id="$(state_get '.protocols.vless_reality.short_id')"
    while IFS=$'\t' read -r name uuid; do
      [[ -n "$name" ]] || continue
      local_proxy_name="${node_name:-VPS}-VLESS-${name}"
      append_clash_vless_proxy "$file" "$local_proxy_name" "$server_address" "$vless_port" "$uuid" "xtls-rprx-vision" "true" "$vless_server_name" "false" "true" "$vless_public_key" "$vless_short_id"
      normal_names+=("$local_proxy_name")
      normal_group_has_proxy=1
    done < <(jq -r '.protocols.vless_reality.users[]? | [.name, .uuid] | @tsv' "$STATE_FILE")
  fi

  if [[ "$(state_get '.protocols.hysteria2.enabled')" == "true" ]]; then
    hy2_port="$(state_get '.protocols.hysteria2.port')"
    hy2_sni="$(state_get '.protocols.hysteria2.tls_server_name')"
    hy2_obfs="$(state_get '.protocols.hysteria2.obfs_password')"
    while IFS=$'\t' read -r name password; do
      [[ -n "$name" ]] || continue
      local_proxy_name="${node_name:-VPS}-HY2-${name}"
      append_clash_hysteria2_proxy "$file" "$local_proxy_name" "$server_address" "$hy2_port" "$password" "$hy2_sni" "$hy2_obfs"
      normal_names+=("$local_proxy_name")
      normal_group_has_proxy=1
    done < <(jq -r '.protocols.hysteria2.users[]? | [.name, .password] | @tsv' "$STATE_FILE")
  fi

  if [[ "$ai_enabled" == "true" ]]; then
    ai_name="AI落地节点"
    ai_type="$(state_get '.routing.ai.outbound_type // "shadowsocks"')"
    if [[ "$ai_type" == "vless" ]]; then
      append_clash_vless_proxy \
        "$file" "$ai_name" \
        "$(state_get '.routing.ai.server')" \
        "$(state_get '.routing.ai.port')" \
        "$(state_get '.routing.ai.uuid')" \
        "$(state_get '.routing.ai.flow // ""')" \
        "$(state_get '.routing.ai.tls_enabled // false')" \
        "$(state_get '.routing.ai.tls_server_name // ""')" \
        "$(state_get '.routing.ai.tls_insecure // false')" \
        "$(state_get '.routing.ai.reality_enabled // false')" \
        "$(state_get '.routing.ai.reality_public_key // ""')" \
        "$(state_get '.routing.ai.reality_short_id // ""')"
    else
      append_clash_ss_proxy \
        "$file" "$ai_name" \
        "$(state_get '.routing.ai.server')" \
        "$(state_get '.routing.ai.port')" \
        "$(state_get '.routing.ai.method')" \
        "$(state_get '.routing.ai.password')"
    fi
  fi

  cat >>"$file" <<EOF

proxy-groups:
  - name: 普通代理
    type: select
    proxies:
EOF

  if (( normal_group_has_proxy )); then
    for local_proxy_name in "${normal_names[@]}"; do
      printf '      - %s\n' "$(yaml_quote "$local_proxy_name")" >>"$file"
    done
  else
    printf '      - DIRECT\n' >>"$file"
  fi

  cat >>"$file" <<EOF
  - name: AI分流
    type: select
    proxies:
EOF

  if [[ "$ai_enabled" == "true" ]]; then
    printf '      - %s\n' "$(yaml_quote "AI落地节点")" >>"$file"
  else
    printf '      - 普通代理\n' >>"$file"
  fi

  cat >>"$file" <<EOF

rules:
EOF
  append_clash_rule_lines "$file"
}

write_nekobox_exports() {
  local rule_file domain_file ip_file guide_file clash_file
  rule_file="$(nekobox_route_rule_file)"
  domain_file="$(nekobox_domain_rules_file)"
  ip_file="$(nekobox_ip_rules_file)"
  guide_file="$(nekobox_guide_file)"
  clash_file="$(nekobox_clash_meta_file)"

  render_nekobox_route_rule_json >"$rule_file"
  render_nekobox_domain_rules >"$domain_file"
  render_nekobox_ip_rules >"$ip_file"
  write_nekobox_clash_meta_config

  cat >"$guide_file" <<EOF
NekoBox for Android AI 分流使用说明

NekoBox 导入节点/订阅时通常只解析节点 outbound，订阅或服务端里的分流规则不会自动进入 NekoBox 路由。
请在手机端 NekoBox 本地添加路由规则：

推荐方案：
1. 在 NekoBox 中导入 Clash Meta 配置：
   $clash_file
2. 配置中已经包含「普通代理」和「AI分流」两个出站组：
   - AI 规则命中后走 AI落地节点
   - 其他流量走普通代理

备用方案：
1. 先正常导入并保存你的节点。
2. 进入该节点的「路由」或「自定义配置 / 自定义路由」页面。
3. 使用文件：
   $rule_file
   把里面的 JSON 作为 sing-box 自定义 route rule 使用，出站标签为 proxy。
4. 如果你使用 NekoBox 的简易路由界面：
   - 域名规则文件：$domain_file
   - IP 规则文件：$ip_file
5. 在 NekoBox 设置里建议开启：
   - VPN 模式
   - DNS 路由
   - Block QUIC 规则
   - 关闭 Android 系统「私人 DNS / 安全 DNS」

如果 NekoBox 的当前版本不接受自定义 JSON，请把 domain 文件内容填到「代理」域名规则，把 ip 文件内容填到「代理」目标 IP 规则。
EOF
}

default_listen_address() {
  local server_address
  server_address="$(state_get '.meta.server_address' 2>/dev/null || true)"

  if [[ -n "$server_address" && "$server_address" != "null" ]] && is_ipv6 "$server_address"; then
    printf '::\n'
  else
    printf '0.0.0.0\n'
  fi
}

normalize_protocol_listen_addresses() {
  local listen_addr
  listen_addr="$(default_listen_address)"

  state_jq --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.listen = $listen_addr |
    .protocols.vless_reality.listen = $listen_addr |
    .protocols.hysteria2.listen = $listen_addr |
    .meta.updated_at = $ts
  '
}

set_node_name_if_empty() {
  local current preset desired
  current="$(state_get '.meta.node_name')"

  if [[ -n "$current" && "$current" != "null" ]]; then
    return 0
  fi

  preset="${SINGBOX_NODE_NAME:-${NODE_NAME:-我的节点}}"
  desired="$preset"

  if is_interactive; then
    desired="$(ui_input "节点名称" "请输入该节点在客户端中显示的名称" "$desired")" || return 1
  fi

  desired="${desired//[$'\r\n']}"
  [[ -n "$desired" ]] || die "节点名称不能为空。"

  state_jq --arg node_name "$desired" --arg ts "$(utc_now)" \
    '.meta.node_name = $node_name | .meta.updated_at = $ts'
}

prompt_node_name_for_protocol() {
  local current desired
  current="$(state_get '.meta.node_name')"
  desired="$(ui_input "节点名称" "请输入该协议在客户端中显示的节点名称" "${current:-我的节点}")" || return 1
  desired="${desired//[$'\r\n']}"
  [[ -n "$desired" ]] || die "节点名称不能为空。"

  state_jq --arg node_name "$desired" --arg ts "$(utc_now)" \
    '.meta.node_name = $node_name | .meta.updated_at = $ts'
}

migrate_legacy_auto_init_state() {
  local should_reset

  should_reset="$(
    jq -r '
      (.meta.node_name == "" or .meta.node_name == null)
      and (.protocols.shadowsocks.enabled == true)
      and (.protocols.vless_reality.enabled == true)
      and (.protocols.hysteria2.enabled == true)
      and ((.protocols.shadowsocks.users | length) == 1 and .protocols.shadowsocks.users[0].name == "ss-client-1")
      and ((.protocols.vless_reality.users | length) == 1 and .protocols.vless_reality.users[0].name == "vless-client-1")
      and ((.protocols.hysteria2.users | length) == 1 and .protocols.hysteria2.users[0].name == "hy2-client-1")
    ' "$STATE_FILE" 2>/dev/null || echo false
  )"

  [[ "$should_reset" == "true" ]] || return 0

  state_jq --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = false |
    .protocols.shadowsocks.users = [] |
    .protocols.shadowsocks.server_password = "" |
    .protocols.vless_reality.enabled = false |
    .protocols.vless_reality.users = [] |
    .protocols.vless_reality.private_key = "" |
    .protocols.vless_reality.public_key = "" |
    .protocols.vless_reality.short_id = "" |
    .protocols.hysteria2.enabled = false |
    .protocols.hysteria2.users = [] |
    .protocols.hysteria2.obfs_password = "" |
    .meta.updated_at = $ts
  '
}

set_server_address_if_empty() {
  local current detected desired preset
  current="$(state_get '.meta.server_address')"

  if [[ -n "$current" && "$current" != "null" ]]; then
    return 0
  fi

  preset="${SINGBOX_SERVER_ADDRESS:-${SERVER_ADDRESS:-}}"
  detected="$(detect_public_address)"
  desired="${preset:-$detected}"

  if is_interactive; then
    desired="$(ui_input "服务器地址" "请输入节点对外地址（域名或 IP）" "$desired")" || return 1
  fi

  desired="${desired// /}"
  [[ -n "$desired" ]] || die "服务器地址不能为空。请在交互环境下运行，或通过环境变量 SINGBOX_SERVER_ADDRESS 指定。"

  state_jq --arg addr "$desired" --arg ts "$(utc_now)" \
    '.meta.server_address = $addr | .meta.updated_at = $ts'
}

prompt_nonempty() {
  local title=$1
  local text=$2
  local default_value=${3:-}
  local value=""

  while true; do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -n "$value" ]] && break
    ui_msg "输入不能为空，请重新输入。"
  done

  printf '%s\n' "$value"
}

prompt_number() {
  local title=$1
  local text=$2
  local default_value=$3
  local min_value=$4
  local max_value=$5
  local value=""

  while true; do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || {
      ui_msg "请输入数字。"
      continue
    }
    (( value >= min_value && value <= max_value )) || {
      ui_msg "请输入 ${min_value}-${max_value} 范围内的数字。"
      continue
    }
    printf '%s\n' "$value"
    return 0
  done
}

realm_prompt_nonempty_limited() {
  local counter_var=$1
  local title=$2
  local text=$3
  local default_value=${4:-}
  local value=""
  local attempts=${!counter_var:-0}

  while true; do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ -n "$value" ]]; then
      printf -v "$counter_var" '%s' 0
      printf '%s\n' "$value"
      return 0
    fi

    attempts=$((attempts + 1))
    printf -v "$counter_var" '%s' "$attempts"

    if (( attempts >= 2 )); then
      ui_msg "连续输入错误两次，已返回 Realm 菜单。"
      return 1
    fi

    ui_msg "输入不能为空，再次输错将返回 Realm 菜单。"
  done
}

realm_prompt_number_limited() {
  local counter_var=$1
  local title=$2
  local text=$3
  local default_value=$4
  local min_value=$5
  local max_value=$6
  local value=""
  local attempts=${!counter_var:-0}

  while true; do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1

    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min_value && value <= max_value )); then
      printf -v "$counter_var" '%s' 0
      printf '%s\n' "$value"
      return 0
    fi

    attempts=$((attempts + 1))
    printf -v "$counter_var" '%s' "$attempts"

    if (( attempts >= 2 )); then
      ui_msg "连续输入错误两次，已返回 Realm 菜单。"
      return 1
    fi

    ui_msg "请输入 ${min_value}-${max_value} 范围内的数字，再次输错将返回 Realm 菜单。"
  done
}

user_exists() {
  local protocol=$1
  local name=$2
  jq -e --arg name "$name" ".protocols.${protocol}.users[]? | select(.name == \$name)" "$STATE_FILE" >/dev/null 2>&1
}

append_ss_user() {
  local name=$1
  local password=$2
  state_jq --arg name "$name" --arg password "$password" --arg ts "$(utc_now)" \
    '.protocols.shadowsocks.users += [{name: $name, password: $password}] | .meta.updated_at = $ts'
}

append_vless_user() {
  local name=$1
  local uuid=$2
  state_jq --arg name "$name" --arg uuid "$uuid" --arg ts "$(utc_now)" \
    '.protocols.vless_reality.users += [{name: $name, uuid: $uuid}] | .meta.updated_at = $ts'
}

append_hy2_user() {
  local name=$1
  local password=$2
  state_jq --arg name "$name" --arg password "$password" --arg ts "$(utc_now)" \
    '.protocols.hysteria2.users += [{name: $name, password: $password}] | .meta.updated_at = $ts'
}

remove_protocol_user() {
  local protocol=$1
  local name=$2
  state_jq --arg name "$name" --arg ts "$(utc_now)" \
    ".protocols.${protocol}.users |= map(select(.name != \$name)) | .meta.updated_at = \$ts"
}

select_protocol_user() {
  local protocol=$1
  local title=$2
  local prompt=$3
  local choice selected_index name
  local -a users=()
  local -a options=()

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    users+=("$name")
  done < <(jq -r ".protocols.${protocol}.users[]?.name" "$STATE_FILE")

  if (( ${#users[@]} == 0 )); then
    ui_msg "当前协议下没有可选择的客户端。"
    return 1
  fi

  for selected_index in "${!users[@]}"; do
    options+=("$((selected_index + 1))" "${users[$selected_index]}")
  done
  options+=("0" "返回")

  choice="$(ui_menu "$title" "$prompt" "${options[@]}")" || return 1
  [[ "$choice" == "0" ]] && return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1

  selected_index=$((choice - 1))
  (( selected_index >= 0 && selected_index < ${#users[@]} )) || return 1
  printf '%s\n' "${users[$selected_index]}"
}

ensure_hysteria_cert() {
  local server_name cert_path key_path san_type openssl_conf
  server_name="$(state_get '.protocols.hysteria2.tls_server_name')"
  cert_path="$(state_get '.protocols.hysteria2.cert_path')"
  key_path="$(state_get '.protocols.hysteria2.key_path')"

  [[ -n "$server_name" && "$server_name" != "null" ]] || server_name="$(state_get '.meta.server_address')"
  [[ -n "$server_name" && "$server_name" != "null" ]] || die "Hysteria2 证书需要一个有效的服务器地址。"

  mkdir -p "$(dirname "$cert_path")" "$(dirname "$key_path")"

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    return 0
  fi

  if is_ipv4 "$server_name" || is_ipv6 "$server_name"; then
    san_type="IP"
  else
    san_type="DNS"
  fi

  openssl_conf="$(mktemp "$TMP_DIR/singbox-cert.XXXXXX")"

  cat >"$openssl_conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = $server_name

[v3_req]
subjectAltName = ${san_type}:$server_name
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -config "$openssl_conf" >/dev/null 2>&1

  chmod 600 "$key_path"
  rm -f "$openssl_conf"
}

ensure_ss_defaults() {
  local current_password user_count listen_addr
  current_password="$(state_get '.protocols.shadowsocks.server_password')"
  user_count="$(state_get '.protocols.shadowsocks.users | length')"
  listen_addr="$(default_listen_address)"

  if [[ -z "$current_password" || "$current_password" == "null" ]]; then
    current_password="$(generate_base64_bytes 32)"
  fi

  state_jq --arg password "$current_password" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = $listen_addr |
    .protocols.shadowsocks.port = (.protocols.shadowsocks.port // 8388) |
    .protocols.shadowsocks.network = "tcp" |
    .protocols.shadowsocks.method = "2022-blake3-aes-256-gcm" |
    .protocols.shadowsocks.multiplex = true |
    .protocols.shadowsocks.server_password = $password |
    .meta.updated_at = $ts
  '

  if [[ "$user_count" -eq 0 ]]; then
    append_ss_user "ss-client-1" "$(generate_base64_bytes 32)"
  fi
}

ensure_vless_defaults() {
  local private_key public_key short_id user_count keypair listen_addr vless_port vless_sni
  private_key="$(state_get '.protocols.vless_reality.private_key')"
  public_key="$(state_get '.protocols.vless_reality.public_key')"
  short_id="$(state_get '.protocols.vless_reality.short_id')"
  user_count="$(state_get '.protocols.vless_reality.users | length')"
  listen_addr="$(default_listen_address)"
  vless_port="$(state_get '.protocols.vless_reality.port')"
  vless_sni="$(state_get '.protocols.vless_reality.server_name')"

  if [[ -z "$vless_port" || "$vless_port" == "null" || "$vless_port" == "443" ]]; then
    vless_port="$(generate_vless_port)"
  fi

  if [[ -z "$vless_sni" || "$vless_sni" == "null" || "$vless_sni" == "www.cloudflare.com" ]]; then
    vless_sni="www.tesla.com"
  fi

  if [[ -z "$private_key" || "$private_key" == "null" || -z "$public_key" || "$public_key" == "null" ]]; then
    keypair="$(generate_reality_keypair)"
    private_key="${keypair%%$'\t'*}"
    public_key="${keypair##*$'\t'}"
  fi

  if [[ -z "$short_id" || "$short_id" == "null" ]]; then
    short_id="$(generate_hex 8)"
  fi

  state_jq --argjson vless_port "$vless_port" --arg vless_sni "$vless_sni" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.listen = $listen_addr |
    .protocols.vless_reality.port = $vless_port |
    .protocols.vless_reality.server_name = $vless_sni |
    .protocols.vless_reality.handshake_server = (if .protocols.vless_reality.handshake_server == "" then .protocols.vless_reality.server_name else .protocols.vless_reality.handshake_server end) |
    .protocols.vless_reality.handshake_port = (.protocols.vless_reality.handshake_port // 443) |
    .protocols.vless_reality.private_key = $private_key |
    .protocols.vless_reality.public_key = $public_key |
    .protocols.vless_reality.short_id = $short_id |
    .meta.updated_at = $ts
  '

  if [[ "$user_count" -eq 0 ]]; then
    append_vless_user "vless-client-1" "$(generate_uuid)"
  fi
}

ensure_hy2_defaults() {
  local tls_server_name obfs_password user_count listen_addr
  tls_server_name="$(state_get '.protocols.hysteria2.tls_server_name')"
  obfs_password="$(state_get '.protocols.hysteria2.obfs_password')"
  user_count="$(state_get '.protocols.hysteria2.users | length')"
  listen_addr="$(default_listen_address)"

  if [[ -z "$tls_server_name" || "$tls_server_name" == "null" ]]; then
    tls_server_name="$(state_get '.meta.server_address')"
  fi

  if [[ -z "$obfs_password" || "$obfs_password" == "null" ]]; then
    obfs_password="$(generate_password)"
  fi

  state_jq --arg tls_server_name "$tls_server_name" --arg obfs_password "$obfs_password" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.hysteria2.enabled = true |
    .protocols.hysteria2.listen = $listen_addr |
    .protocols.hysteria2.port = (.protocols.hysteria2.port // 8443) |
    .protocols.hysteria2.up_mbps = (.protocols.hysteria2.up_mbps // 100) |
    .protocols.hysteria2.down_mbps = (.protocols.hysteria2.down_mbps // 100) |
    .protocols.hysteria2.tls_server_name = $tls_server_name |
    .protocols.hysteria2.obfs_password = $obfs_password |
    .protocols.hysteria2.masquerade = (if .protocols.hysteria2.masquerade == "" then "https://www.bing.com" else .protocols.hysteria2.masquerade end) |
    .meta.updated_at = $ts
  '

  ensure_hysteria_cert

  if [[ "$user_count" -eq 0 ]]; then
    append_hy2_user "hy2-client-1" "$(generate_password)"
  fi
}

validate_state() {
  local errors=""
  local ss_enabled vless_enabled hy2_enabled
  local server_address vless_server_name handshake_server
  local ai_enabled ai_protocol ai_server ai_password ai_uuid ai_reality_enabled ai_reality_public_key

  ss_enabled="$(state_get '.protocols.shadowsocks.enabled')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  hy2_enabled="$(state_get '.protocols.hysteria2.enabled')"
  server_address="$(state_get '.meta.server_address')"
  ai_enabled="$(state_get '.routing.ai.enabled // false')"

  [[ -n "$server_address" && "$server_address" != "null" ]] || errors+=$'节点对外地址不能为空。\n'

  if [[ "$ss_enabled" == "true" ]]; then
    [[ "$(state_get '.protocols.shadowsocks.users | length')" -gt 0 ]] || errors+=$'Shadowsocks 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.shadowsocks.server_password')" ]] || errors+=$'Shadowsocks 服务端密码不能为空。\n'
  fi

  if [[ "$vless_enabled" == "true" ]]; then
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    handshake_server="$(state_get '.protocols.vless_reality.handshake_server')"
    [[ "$(state_get '.protocols.vless_reality.users | length')" -gt 0 ]] || errors+=$'VLESS + Reality 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.vless_reality.private_key')" ]] || errors+=$'VLESS + Reality 私钥不能为空。\n'
    [[ -n "$(state_get '.protocols.vless_reality.public_key')" ]] || errors+=$'VLESS + Reality 公钥不能为空。\n'
    [[ -n "$(state_get '.protocols.vless_reality.short_id')" ]] || errors+=$'VLESS + Reality short_id 不能为空。\n'
    [[ -n "$vless_server_name" && "$vless_server_name" != "null" ]] || errors+=$'VLESS + Reality 的伪装域名不能为空。\n'
    [[ -n "$handshake_server" && "$handshake_server" != "null" ]] || errors+=$'VLESS + Reality 的握手站点不能为空。\n'
    if [[ "$vless_server_name" == "$server_address" || "$handshake_server" == "$server_address" ]]; then
      errors+=$'VLESS + Reality 的伪装域名不能与节点对外地址相同，请填写第三方网站域名，例如 www.cloudflare.com。\n'
    fi
    if is_ipv4 "$vless_server_name" || is_ipv6 "$vless_server_name"; then
      errors+=$'VLESS + Reality 的伪装域名请填写域名，不要填写 IP。\n'
    fi
  fi

  if [[ "$hy2_enabled" == "true" ]]; then
    ensure_hysteria_cert
    [[ "$(state_get '.protocols.hysteria2.users | length')" -gt 0 ]] || errors+=$'Hysteria2 至少需要一个客户端。\n'
    [[ -f "$(state_get '.protocols.hysteria2.cert_path')" ]] || errors+=$'Hysteria2 证书文件不存在。\n'
    [[ -f "$(state_get '.protocols.hysteria2.key_path')" ]] || errors+=$'Hysteria2 私钥文件不存在。\n'
  fi

  if [[ "$ai_enabled" == "true" ]]; then
    ai_protocol="$(state_get '.routing.ai.outbound_type // "shadowsocks"')"
    ai_server="$(state_get '.routing.ai.server')"
    [[ "$ai_protocol" == "shadowsocks" || "$ai_protocol" == "vless" ]] || errors+=$'AI 分流出站协议仅支持 Shadowsocks 或 VLESS。\n'
    [[ -n "$ai_server" && "$ai_server" != "null" ]] || errors+=$'AI 分流落地节点地址不能为空。\n'
    [[ "$(state_get '.routing.ai.port')" =~ ^[0-9]+$ ]] || errors+=$'AI 分流落地节点端口必须是数字。\n'
    if [[ "$ai_protocol" == "shadowsocks" ]]; then
      ai_password="$(state_get '.routing.ai.password')"
      [[ -n "$(state_get '.routing.ai.method')" ]] || errors+=$'AI 分流 Shadowsocks 加密方式不能为空。\n'
      [[ -n "$ai_password" && "$ai_password" != "null" ]] || errors+=$'AI 分流 Shadowsocks 密码不能为空。\n'
    fi
    if [[ "$ai_protocol" == "vless" ]]; then
      ai_uuid="$(state_get '.routing.ai.uuid')"
      ai_reality_enabled="$(state_get '.routing.ai.reality_enabled // false')"
      ai_reality_public_key="$(state_get '.routing.ai.reality_public_key')"
      [[ -n "$ai_uuid" && "$ai_uuid" != "null" ]] || errors+=$'AI 分流 VLESS UUID 不能为空。\n'
      if [[ "$ai_reality_enabled" == "true" ]]; then
        [[ -n "$ai_reality_public_key" && "$ai_reality_public_key" != "null" ]] || errors+=$'AI 分流 VLESS Reality public key 不能为空。\n'
      fi
    fi
    [[ "$(state_get '((.routing.ai.domain_suffix // []) + (.routing.ai.domain_keyword // []) + (.routing.ai.ip_cidr // []) + (.routing.ai.resolved_ip_cidr // [])) | length')" -gt 0 ]] || errors+=$'AI 分流规则不能为空。\n'
  fi

  if [[ -n "$errors" ]]; then
    ui_show_text "配置校验失败" "$errors"
    return 1
  fi

  return 0
}

render_config() {
  jq '
  def ai_route_matcher:
    (.routing.ai.domain_suffix // []) as $suffix |
    {
      domain: ($suffix | map(select(contains("."))) | unique),
      domain_suffix: ($suffix | map(select(contains("."))) | map(if startswith(".") then . else "." + . end) | unique),
      domain_keyword: (.routing.ai.domain_keyword // [] | unique),
      ip_cidr: (((.routing.ai.ip_cidr // []) + (.routing.ai.resolved_ip_cidr // [])) | unique)
    };

  {
    log: {
      disabled: false,
      level: .meta.log_level,
      timestamp: true
    },
    inbounds: [
      (
        if .protocols.shadowsocks.enabled then
          {
            type: "shadowsocks",
            tag: "ss-in",
            listen: .protocols.shadowsocks.listen,
            listen_port: .protocols.shadowsocks.port,
            network: .protocols.shadowsocks.network,
            method: .protocols.shadowsocks.method,
            password: .protocols.shadowsocks.server_password,
            users: .protocols.shadowsocks.users,
            multiplex: {
              enabled: (.protocols.shadowsocks.multiplex // true)
            }
          }
        else empty
        end
      ),
      (
        if .protocols.vless_reality.enabled then
          {
            type: "vless",
            tag: "vless-reality-in",
            listen: .protocols.vless_reality.listen,
            listen_port: .protocols.vless_reality.port,
            users: [
              .protocols.vless_reality.users[] | {
                name: .name,
                uuid: .uuid,
                flow: "xtls-rprx-vision"
              }
            ],
            tls: {
              enabled: true,
              server_name: .protocols.vless_reality.server_name,
              alpn: ["h2", "http/1.1"],
              reality: {
                enabled: true,
                handshake: {
                  server: .protocols.vless_reality.handshake_server,
                  server_port: .protocols.vless_reality.handshake_port
                },
                private_key: .protocols.vless_reality.private_key,
                short_id: [ .protocols.vless_reality.short_id ]
              }
            }
          }
        else empty
        end
      ),
      (
        if .protocols.hysteria2.enabled then
          (
            {
              type: "hysteria2",
              tag: "hy2-in",
              listen: .protocols.hysteria2.listen,
              listen_port: .protocols.hysteria2.port,
              up_mbps: .protocols.hysteria2.up_mbps,
              down_mbps: .protocols.hysteria2.down_mbps,
              users: .protocols.hysteria2.users,
              tls: {
                enabled: true,
                alpn: ["h3"],
                certificate_path: .protocols.hysteria2.cert_path,
                key_path: .protocols.hysteria2.key_path
              }
            }
            + (if (.protocols.hysteria2.obfs_password | length) > 0 then
                {
                  obfs: {
                    type: "salamander",
                    password: .protocols.hysteria2.obfs_password
                  }
                }
              else {} end)
            + (if (.protocols.hysteria2.masquerade | length) > 0 then
                { masquerade: .protocols.hysteria2.masquerade }
              else {} end)
          )
        else empty
        end
      )
    ],
    outbounds: [
      {
        type: "direct",
        tag: "direct"
      },
      (
        if (.routing.ai.enabled // false) then
          if (.routing.ai.outbound_type // "shadowsocks") == "vless" then
            (
              {
                type: "vless",
                tag: "ai-out",
                server: .routing.ai.server,
                server_port: .routing.ai.port,
                uuid: .routing.ai.uuid,
                network: (.routing.ai.network // "tcp")
              }
              + (if (.routing.ai.flow // "") != "" then
                  { flow: .routing.ai.flow }
                else {} end)
              + (if (.routing.ai.tls_enabled // false) or (.routing.ai.reality_enabled // false) then
                  {
                    tls: (
                      {
                        enabled: true,
                        insecure: (.routing.ai.tls_insecure // false)
                      }
                      + (if (.routing.ai.tls_server_name // "") != "" then
                          { server_name: .routing.ai.tls_server_name }
                        else {} end)
                      + (if (.routing.ai.reality_enabled // false) then
                          {
                            reality: {
                              enabled: true,
                              public_key: .routing.ai.reality_public_key,
                              short_id: (.routing.ai.reality_short_id // "")
                            }
                          }
                        else {} end)
                    )
                  }
                else {} end)
            )
          else
            {
              type: "shadowsocks",
              tag: "ai-out",
              server: .routing.ai.server,
              server_port: .routing.ai.port,
              method: .routing.ai.method,
              password: .routing.ai.password,
              network: (.routing.ai.network // "tcp")
            }
          end
        else empty
        end
      )
    ],
    route: {
      rules: [
        (
          if (.routing.ai.enabled // false) then
            {
              action: "sniff",
              sniffer: ["http", "tls", "quic"],
              timeout: "2s"
            }
          else empty
          end
        ),
        (
          if (.routing.ai.enabled // false) then
            {
              network: "udp",
              port: 443,
              action: "reject",
              method: "default"
            }
          else empty
          end
        ),
        (
          if (.routing.ai.enabled // false) then
            ai_route_matcher + {
              protocol: "quic",
              action: "reject",
              method: "default"
            }
          else empty
          end
        ),
        (
          if (.routing.ai.enabled // false) then
            ai_route_matcher + {
              action: "route-options",
              udp_disable_domain_unmapping: true
            }
          else empty
          end
        ),
        (
          if (.routing.ai.enabled // false) then
            ai_route_matcher + {
              action: "route",
              outbound: "ai-out"
            }
          else empty
          end
        )
      ],
      final: "direct"
    }
  }' "$STATE_FILE"
}

enabled_protocol_count() {
  state_get '[.protocols[] | select(.enabled == true)] | length'
}

apply_firewall_rules() {
  local ss_enabled vless_enabled hy2_enabled
  ss_enabled="$(state_get '.protocols.shadowsocks.enabled')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  hy2_enabled="$(state_get '.protocols.hysteria2.enabled')"

  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    [[ "$ss_enabled" == "true" ]] && ufw allow "$(state_get '.protocols.shadowsocks.port')/tcp" >/dev/null 2>&1 || true
    [[ "$vless_enabled" == "true" ]] && ufw allow "$(state_get '.protocols.vless_reality.port')/tcp" >/dev/null 2>&1 || true
    [[ "$hy2_enabled" == "true" ]] && ufw allow "$(state_get '.protocols.hysteria2.port')/udp" >/dev/null 2>&1 || true
  fi

  if have_cmd firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    [[ "$ss_enabled" == "true" ]] && firewall-cmd --permanent --add-port="$(state_get '.protocols.shadowsocks.port')/tcp" >/dev/null 2>&1 || true
    [[ "$vless_enabled" == "true" ]] && firewall-cmd --permanent --add-port="$(state_get '.protocols.vless_reality.port')/tcp" >/dev/null 2>&1 || true
    [[ "$hy2_enabled" == "true" ]] && firewall-cmd --permanent --add-port="$(state_get '.protocols.hysteria2.port')/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

realm_rule_group_count() {
  realm_state_get '.rules | length'
}

render_realm_config() {
  local log_level log_output use_udp no_tcp
  log_level="$(realm_state_get '.global.log_level')"
  log_output="$(realm_state_get '.global.log_output')"
  use_udp="$(realm_state_get '.global.use_udp')"
  no_tcp="$(realm_state_get '.global.no_tcp')"

  cat <<EOF
[log]
level = "${log_level}"
output = "${log_output}"

[network]
use_udp = ${use_udp}
no_tcp = ${no_tcp}
EOF

  while IFS=$'\t' read -r listen remote; do
    [[ -n "$listen" && -n "$remote" ]] || continue
    cat <<EOF

[[endpoints]]
listen = "${listen}"
remote = "${remote}"
EOF
  done < <(jq -r '.rules[]?.entries[]? | [.listen, .remote] | @tsv' "$REALM_STATE_FILE")
}

write_realm_config_file() {
  local tmp_config
  tmp_config="$(mktemp "$TMP_DIR/realm-config.XXXXXX.toml")"
  render_realm_config >"$tmp_config"
  cp "$tmp_config" "$REALM_CONFIG_FILE"
  rm -f "$tmp_config"
}

realm_apply_firewall_rules() {
  local port

  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      ufw allow "${port}/udp" >/dev/null 2>&1 || true
    done < <(jq -r '.rules[]?.entries[]?.listen | capture(":(?<port>[0-9]+)$").port' "$REALM_STATE_FILE" | sort -un)
  fi

  if have_cmd firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
    done < <(jq -r '.rules[]?.entries[]?.listen | capture(":(?<port>[0-9]+)$").port' "$REALM_STATE_FILE" | sort -un)
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

apply_realm_config() {
  local rule_count message

  ensure_realm_dirs
  init_realm_state_file
  ensure_realm_service

  write_realm_config_file

  rule_count="$(realm_rule_group_count)"
  if [[ "$rule_count" -eq 0 ]]; then
    if realm_service_exists; then
      systemctl stop realm >/dev/null 2>&1 || true
    fi
    ui_msg "Realm 当前没有任何转发规则，配置已保存，服务已停止。"
    return 0
  fi

  realm_apply_firewall_rules

  systemctl enable realm >/dev/null 2>&1 || true
  if realm_service_exists && [[ "$(systemctl is-active realm 2>/dev/null || true)" == "active" ]]; then
    systemctl restart realm >/dev/null 2>&1 || {
      ui_show_text "Realm 启动失败" "$(journalctl -u realm -n 30 --no-pager 2>/dev/null || echo '无法读取 Realm 日志。')"
      return 1
    }
    message="Realm 配置已保存到 ${REALM_CONFIG_FILE}，服务已重启。"
  else
    systemctl start realm >/dev/null 2>&1 || {
      ui_show_text "Realm 启动失败" "$(journalctl -u realm -n 30 --no-pager 2>/dev/null || echo '无法读取 Realm 日志。')"
      return 1
    }
    message="Realm 配置已保存到 ${REALM_CONFIG_FILE}，服务已自动启动。"
  fi

  ui_msg "$message"
}

write_client_exports() {
  local all_file server_address host links_file node_name link display_name
  all_file="$CLIENT_DIR/all-clients.txt"

  if [[ "$(enabled_protocol_count)" -gt 0 ]]; then
    set_server_address_if_empty || return 1
  fi

  server_address="$(state_get '.meta.server_address')"
  host="$(format_uri_host "$server_address")"
  node_name="$(state_get '.meta.node_name')"
  links_file="$(direct_links_file)"
  display_name="${node_name:-我的节点}"

  : >"$all_file"
  : >"$links_file"
  rm -f "$CLIENT_DIR"/shadowsocks/*.txt "$CLIENT_DIR"/vless-reality/*.txt "$CLIENT_DIR"/hysteria2/*.txt 2>/dev/null || true

  if [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]]; then
    local ss_port ss_method ss_server_password
    ss_port="$(state_get '.protocols.shadowsocks.port')"
    ss_method="$(state_get '.protocols.shadowsocks.method')"
    ss_server_password="$(state_get '.protocols.shadowsocks.server_password')"

    while IFS=$'\t' read -r name user_password; do
      [[ -n "$name" ]] || continue
      cat >"$CLIENT_DIR/shadowsocks/${name}.txt" <<EOF
[Shadowsocks 2022]
name = $display_name
server = $server_address
port = $ss_port
method = $ss_method
password = ${ss_server_password}:${user_password}
network = tcp
multiplex = true
EOF
      link="ss://$(base64_urlsafe "${ss_method}:${ss_server_password}:${user_password}")@${host}:${ss_port}#$(uri_encode "$display_name")"
      printf '%s（%s）的订阅链接是：%s\n' "$display_name" "$name" "$link" >>"$links_file"
      cat "$CLIENT_DIR/shadowsocks/${name}.txt" >>"$all_file"
      printf '\n' >>"$all_file"
    done < <(jq -r '.protocols.shadowsocks.users[]? | [.name, .password] | @tsv' "$STATE_FILE")
  fi

  if [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]]; then
    local vless_port vless_server_name vless_public_key vless_short_id
    vless_port="$(state_get '.protocols.vless_reality.port')"
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    vless_public_key="$(state_get '.protocols.vless_reality.public_key')"
    vless_short_id="$(state_get '.protocols.vless_reality.short_id')"

    while IFS=$'\t' read -r name uuid; do
      [[ -n "$name" ]] || continue
      cat >"$CLIENT_DIR/vless-reality/${name}.txt" <<EOF
[VLESS + Reality]
name = $display_name
server = $server_address
port = $vless_port
uuid = $uuid
flow = xtls-rprx-vision
tls.server_name = $vless_server_name
reality.public_key = $vless_public_key
reality.short_id = $vless_short_id
transport = tcp
EOF
      link="vless://${uuid}@${host}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_encode "$vless_server_name")&fp=chrome&pbk=$(uri_encode "$vless_public_key")&sid=$(uri_encode "$vless_short_id")&alpn=$(uri_encode "h2,http/1.1")&type=tcp&headerType=none#$(uri_encode "$display_name")"
      printf '%s（%s）的订阅链接是：%s\n' "$display_name" "$name" "$link" >>"$links_file"
      cat "$CLIENT_DIR/vless-reality/${name}.txt" >>"$all_file"
      printf '\n' >>"$all_file"
    done < <(jq -r '.protocols.vless_reality.users[]? | [.name, .uuid] | @tsv' "$STATE_FILE")
  fi

  if [[ "$(state_get '.protocols.hysteria2.enabled')" == "true" ]]; then
    local hy2_port hy2_sni hy2_obfs
    hy2_port="$(state_get '.protocols.hysteria2.port')"
    hy2_sni="$(state_get '.protocols.hysteria2.tls_server_name')"
    hy2_obfs="$(state_get '.protocols.hysteria2.obfs_password')"

    while IFS=$'\t' read -r name password; do
      [[ -n "$name" ]] || continue
      cat >"$CLIENT_DIR/hysteria2/${name}.txt" <<EOF
[Hysteria2]
name = $display_name
server = $server_address
port = $hy2_port
password = $password
tls.server_name = $hy2_sni
tls.insecure = true
obfs = salamander
obfs_password = $hy2_obfs
EOF
      link="hysteria2://$(uri_encode "$password")@${host}:${hy2_port}?sni=$(uri_encode "$hy2_sni")&insecure=1&obfs=salamander&obfs-password=$(uri_encode "$hy2_obfs")#$(uri_encode "$display_name")"
      printf '%s（%s）的订阅链接是：%s\n' "$display_name" "$name" "$link" >>"$links_file"
      cat "$CLIENT_DIR/hysteria2/${name}.txt" >>"$all_file"
      printf '\n' >>"$all_file"
    done < <(jq -r '.protocols.hysteria2.users[]? | [.name, .password] | @tsv' "$STATE_FILE")
  fi

  write_nekobox_exports
}

apply_config() {
  local enabled_count tmp_config check_output success_text links_file
  enabled_count="$(enabled_protocol_count)"

  if [[ "$enabled_count" -eq 0 ]]; then
    stop_sing_box
    ui_msg "当前没有启用任何协议，sing-box 服务已停止。"
    return 0
  fi

  set_server_address_if_empty || return 1
  normalize_protocol_listen_addresses
  refresh_ai_resolved_ip_cidrs
  validate_state || return 1

  tmp_config="$(mktemp "$TMP_DIR/singbox-config.XXXXXX.json")"
  render_config >"$tmp_config"

  if have_cmd sing-box; then
    if ! check_output="$(sing-box check -c "$tmp_config" 2>&1)"; then
      rm -f "$tmp_config"
      ui_show_text "sing-box 配置检查失败" "$check_output"
      return 1
    fi
  fi

  backup_config_if_exists
  cp "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"

  write_client_exports
  apply_firewall_rules
  restart_sing_box || return 1

  success_text="配置已写入 $CONFIG_FILE，服务已重载。客户端信息已导出到 $CLIENT_DIR。"
  links_file="$(direct_links_file)"
  if [[ -s "$links_file" ]]; then
    success_text+=$'\n\n订阅链接：\n'"$(cat "$links_file")"
  fi
  ui_msg "$success_text"
}

quick_install() {
  require_linux
  require_root
  ensure_dirs
  install_dependencies
  install_sing_box
  init_state_file
  migrate_legacy_auto_init_state
  set_node_name_if_empty
  set_server_address_if_empty
  normalize_protocol_listen_addresses
  ui_msg "基础环境安装完成，请继续在面板中按需启用并配置协议。"
}

repair_install() {
  local manager_target
  require_linux
  require_root
  ensure_dirs
  init_state_file
  install_dependencies

  manager_target="$(manager_script_target_path)"
  if [[ "${SBOX_REPAIR_RESUMED:-0}" != "1" ]]; then
    if install_manager_script_from_repo; then
      log "管理脚本已重新安装 / 更新到 ${manager_target}。"
      log "将使用新安装的脚本继续修复，以应用最新逻辑。"
      export SBOX_REPAIR_RESUMED=1
      exec "$manager_target" repair-install
    else
      warn "管理脚本更新失败，将继续修复 sing-box 核心与配置。"
    fi
  else
    log "已切换到新安装的管理脚本，继续修复 sing-box 核心与配置。"
  fi

  install_sing_box
  ensure_sing_box_service
  apply_config || return 1
  ui_msg "重新安装 / 修复完成。原有节点、客户端和分流规则已保留。"

  if [[ "${SBOX_REPAIR_OPEN_PANEL:-0}" == "1" && -x "$manager_target" ]]; then
    exec "$manager_target"
  fi
}

configure_server_address() {
  local current desired
  current="$(state_get '.meta.server_address')"
  desired="$(prompt_nonempty "服务器地址" "请输入节点对外地址（域名或 IP）" "$current")" || return 1
  state_jq --arg addr "$desired" --arg ts "$(utc_now)" '.meta.server_address = $addr | .meta.updated_at = $ts'

  if [[ "$(state_get '.protocols.hysteria2.enabled')" == "true" ]]; then
    if ui_yesno "是否同步更新 Hysteria2 的证书域名并重新生成自签名证书？"; then
      state_jq --arg addr "$desired" --arg ts "$(utc_now)" \
        '.protocols.hysteria2.tls_server_name = $addr | .meta.updated_at = $ts'
      rm -f "$(state_get '.protocols.hysteria2.cert_path')" "$(state_get '.protocols.hysteria2.key_path')" 2>/dev/null || true
      ensure_hysteria_cert
    fi
  fi

  apply_config
}

configure_node_name() {
  local current desired
  current="$(state_get '.meta.node_name')"
  desired="$(prompt_nonempty "节点名称" "请输入该节点在客户端中显示的名称" "${current:-我的节点}")" || return 1
  state_jq --arg node_name "$desired" --arg ts "$(utc_now)" '.meta.node_name = $node_name | .meta.updated_at = $ts'
  write_client_exports
  ui_msg "节点名称已更新。"
}

configure_shadowsocks() {
  local current_port port regenerate_password server_password listen_addr

  prompt_node_name_for_protocol

  current_port="$(state_get '.protocols.shadowsocks.port')"
  port="$(prompt_number "Shadowsocks 端口" "请输入 Shadowsocks 监听端口" "$current_port" 1 65535)" || return 1

  regenerate_password="false"
  if ui_yesno "是否重新生成 Shadowsocks 服务端主密码？"; then
    regenerate_password="true"
  fi

  server_password="$(state_get '.protocols.shadowsocks.server_password')"
  if [[ "$regenerate_password" == "true" || -z "$server_password" || "$server_password" == "null" ]]; then
    server_password="$(generate_base64_bytes 32)"
  fi
  listen_addr="$(default_listen_address)"

  state_jq --argjson port "$port" --arg server_password "$server_password" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = $listen_addr |
    .protocols.shadowsocks.port = $port |
    .protocols.shadowsocks.network = "tcp" |
    .protocols.shadowsocks.method = "2022-blake3-aes-256-gcm" |
    .protocols.shadowsocks.server_password = $server_password |
    .protocols.shadowsocks.multiplex = true |
    .meta.updated_at = $ts
  '

  if [[ "$(state_get '.protocols.shadowsocks.users | length')" -eq 0 ]]; then
    append_ss_user "ss-client-1" "$(generate_base64_bytes 32)"
  fi

  apply_config
}

configure_vless_reality() {
  local current_port port current_sni sni current_handshake_port handshake_port keypair private_key public_key short_id listen_addr

  prompt_node_name_for_protocol

  current_port="$(state_get '.protocols.vless_reality.port')"
  current_sni="$(state_get '.protocols.vless_reality.server_name')"
  current_handshake_port="$(state_get '.protocols.vless_reality.handshake_port')"

  if [[ -z "$current_port" || "$current_port" == "null" || "$current_port" == "443" ]]; then
    current_port="$(generate_vless_port)"
  fi
  if [[ -z "$current_sni" || "$current_sni" == "null" || "$current_sni" == "www.cloudflare.com" ]]; then
    current_sni="www.tesla.com"
  fi

  port="$(prompt_number "VLESS 端口" "请输入 VLESS + Reality 监听端口" "$current_port" 1 65535)" || return 1
  sni="$(prompt_nonempty "Reality SNI" "请输入第三方 Reality 伪装域名（例如 www.cloudflare.com，不能填写本机 IP 或节点域名）" "$current_sni")" || return 1
  handshake_port="$(prompt_number "Reality 握手端口" "请输入 Reality 伪装站点端口" "$current_handshake_port" 1 65535)" || return 1

  private_key="$(state_get '.protocols.vless_reality.private_key')"
  public_key="$(state_get '.protocols.vless_reality.public_key')"
  short_id="$(state_get '.protocols.vless_reality.short_id')"

  if ui_yesno "是否重新生成 Reality 密钥和 short_id？"; then
    keypair="$(generate_reality_keypair)"
    private_key="${keypair%%$'\t'*}"
    public_key="${keypair##*$'\t'}"
    short_id="$(generate_hex 8)"
  fi

  if [[ -z "$private_key" || "$private_key" == "null" || -z "$public_key" || "$public_key" == "null" ]]; then
    keypair="$(generate_reality_keypair)"
    private_key="${keypair%%$'\t'*}"
    public_key="${keypair##*$'\t'}"
  fi

  if [[ -z "$short_id" || "$short_id" == "null" ]]; then
    short_id="$(generate_hex 8)"
  fi
  listen_addr="$(default_listen_address)"

  state_jq --argjson port "$port" --arg sni "$sni" --arg handshake_server "$sni" --argjson handshake_port "$handshake_port" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.listen = $listen_addr |
    .protocols.vless_reality.port = $port |
    .protocols.vless_reality.server_name = $sni |
    .protocols.vless_reality.handshake_server = $handshake_server |
    .protocols.vless_reality.handshake_port = $handshake_port |
    .protocols.vless_reality.private_key = $private_key |
    .protocols.vless_reality.public_key = $public_key |
    .protocols.vless_reality.short_id = $short_id |
    .meta.updated_at = $ts
  '

  if [[ "$(state_get '.protocols.vless_reality.users | length')" -eq 0 ]]; then
    append_vless_user "vless-client-1" "$(generate_uuid)"
  fi

  apply_config
}

configure_hysteria2() {
  local current_port current_up current_down current_sni current_masquerade
  local port up_mbps down_mbps tls_server_name masquerade obfs_password listen_addr

  prompt_node_name_for_protocol

  current_port="$(state_get '.protocols.hysteria2.port')"
  current_up="$(state_get '.protocols.hysteria2.up_mbps')"
  current_down="$(state_get '.protocols.hysteria2.down_mbps')"
  current_sni="$(state_get '.protocols.hysteria2.tls_server_name')"
  current_masquerade="$(state_get '.protocols.hysteria2.masquerade')"

  port="$(prompt_number "Hysteria2 端口" "请输入 Hysteria2 监听端口（UDP）" "$current_port" 1 65535)" || return 1
  up_mbps="$(prompt_number "上行带宽" "请输入上行 Mbps" "$current_up" 1 100000)" || return 1
  down_mbps="$(prompt_number "下行带宽" "请输入下行 Mbps" "$current_down" 1 100000)" || return 1
  tls_server_name="$(prompt_nonempty "TLS Server Name" "请输入 Hysteria2 证书域名或 IP" "$current_sni")" || return 1
  masquerade="$(prompt_nonempty "Masquerade" "请输入认证失败时伪装地址" "$current_masquerade")" || return 1

  obfs_password="$(state_get '.protocols.hysteria2.obfs_password')"
  if ui_yesno "是否重新生成 Hysteria2 的 Salamander 混淆密码？"; then
    obfs_password="$(generate_password)"
  fi
  if [[ -z "$obfs_password" || "$obfs_password" == "null" ]]; then
    obfs_password="$(generate_password)"
  fi
  listen_addr="$(default_listen_address)"

  state_jq --argjson port "$port" --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps" --arg tls_server_name "$tls_server_name" --arg masquerade "$masquerade" --arg obfs_password "$obfs_password" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.hysteria2.enabled = true |
    .protocols.hysteria2.listen = $listen_addr |
    .protocols.hysteria2.port = $port |
    .protocols.hysteria2.up_mbps = $up_mbps |
    .protocols.hysteria2.down_mbps = $down_mbps |
    .protocols.hysteria2.tls_server_name = $tls_server_name |
    .protocols.hysteria2.masquerade = $masquerade |
    .protocols.hysteria2.obfs_password = $obfs_password |
    .meta.updated_at = $ts
  '

  if ui_yesno "是否重新生成 Hysteria2 自签名证书？"; then
    rm -f "$(state_get '.protocols.hysteria2.cert_path')" "$(state_get '.protocols.hysteria2.key_path')" 2>/dev/null || true
  fi
  ensure_hysteria_cert

  if [[ "$(state_get '.protocols.hysteria2.users | length')" -eq 0 ]]; then
    append_hy2_user "hy2-client-1" "$(generate_password)"
  fi

  apply_config
}

configure_ai_routing() {
  local current_enabled current_protocol current_server current_port current_method current_password current_rules
  local current_uuid current_flow current_tls_server_name current_reality_public_key current_reality_short_id
  local protocol_choice protocol server port rules_input rules_json rules_count
  local method password uuid flow tls_enabled tls_server_name tls_insecure reality_enabled reality_public_key reality_short_id

  current_enabled="$(state_get '.routing.ai.enabled // false')"
  current_protocol="$(state_get '.routing.ai.outbound_type // "shadowsocks"')"
  current_server="$(state_get '.routing.ai.server // ""')"
  current_port="$(state_get '.routing.ai.port // 443')"
  current_method="$(state_get '.routing.ai.method // "chacha20-ietf-poly1305"')"
  current_password="$(state_get '.routing.ai.password // ""')"
  current_uuid="$(state_get '.routing.ai.uuid // ""')"
  current_flow="$(state_get '.routing.ai.flow // ""')"
  current_tls_server_name="$(state_get '.routing.ai.tls_server_name // ""')"
  current_reality_public_key="$(state_get '.routing.ai.reality_public_key // ""')"
  current_reality_short_id="$(state_get '.routing.ai.reality_short_id // ""')"
  current_rules="$(format_ai_rule_list)"

  if ! ui_yesno "是否启用或继续配置 AI 分流？选择否将关闭 AI 分流。当前状态：${current_enabled}"; then
    state_jq --arg ts "$(utc_now)" '
      .routing.ai.enabled = false |
      .meta.updated_at = $ts
    '
    apply_config
    return 0
  fi

  protocol_choice="$(ui_menu "AI 分流出站协议" "请选择落地节点协议。当前协议：${current_protocol}" \
    "1" "Shadowsocks" \
    "2" "VLESS" \
    "0" "返回")" || return 1
  case "$protocol_choice" in
    1) protocol="shadowsocks" ;;
    2) protocol="vless" ;;
    0) return 0 ;;
    *)
      ui_msg "无效选项，请重新选择。"
      return 1
      ;;
  esac

  server="$(prompt_nonempty "AI 分流落地节点地址" "请输入落地节点地址（域名、IPv4 或 IPv6）" "$current_server")" || return 1
  port="$(prompt_number "AI 分流落地端口" "请输入落地节点端口" "$current_port" 1 65535)" || return 1
  rules_input="$(prompt_nonempty "AI 分流站点规则" "请输入要走落地的域名、网址、关键词或 IP/CIDR，用逗号/空格分隔；例如 gemini, gpt, claude.ai, 1.2.3.4/32" "$current_rules")" || return 1
  if ! rules_json="$(build_ai_rules_json "$rules_input")"; then
    ui_msg "AI 分流站点规则解析失败，请检查输入内容后重试。"
    return 1
  fi
  if ! rules_count="$(printf '%s' "$rules_json" | jq -r '((.domain_suffix // []) + (.domain_keyword // []) + (.ip_cidr // [])) | length')"; then
    ui_msg "AI 分流站点规则解析失败，请检查输入内容后重试。"
    return 1
  fi
  if [[ "$rules_count" -eq 0 ]]; then
    ui_msg "AI 分流站点规则不能为空。"
    return 1
  fi

  if [[ "$protocol" == "shadowsocks" ]]; then
    method="$(prompt_nonempty "AI 分流加密方式" "请输入 Shadowsocks 加密方式，例如 chacha20-ietf-poly1305 / aes-256-gcm" "$current_method")" || return 1
    password="$(ui_input "AI 分流密码" "请输入 Shadowsocks 密码；留空则保留当前密码" "")" || return 1
    if [[ -z "$password" ]]; then
      password="$current_password"
    fi
    if [[ -z "$password" || "$password" == "null" ]]; then
      ui_msg "Shadowsocks 密码不能为空。请向节点提供方确认加密方式和密码。"
      return 1
    fi

    state_jq --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" --argjson rules "$rules_json" --arg ts "$(utc_now)" '
      .routing.ai.enabled = true |
      .routing.ai.outbound_type = "shadowsocks" |
      .routing.ai.server = $server |
      .routing.ai.port = $port |
      .routing.ai.method = $method |
      .routing.ai.password = $password |
      .routing.ai.network = "tcp" |
      .routing.ai.domain_suffix = $rules.domain_suffix |
      .routing.ai.domain_keyword = $rules.domain_keyword |
      .routing.ai.ip_cidr = ($rules.ip_cidr // []) |
      .routing.ai.resolved_ip_cidr = [] |
      .meta.updated_at = $ts
    '
  else
    uuid="$(prompt_nonempty "AI 分流 VLESS UUID" "请输入 VLESS UUID" "$current_uuid")" || return 1
    flow="$(ui_input "AI 分流 VLESS Flow" "请输入 VLESS flow；普通 VLESS 可留空，Reality Vision 常用 xtls-rprx-vision" "$current_flow")" || return 1
    flow="${flow//[$'\r\n ']}"
    tls_enabled="false"
    tls_server_name=""
    tls_insecure="false"
    reality_enabled="false"
    reality_public_key=""
    reality_short_id=""

    if ui_yesno "是否启用 VLESS TLS？如果是 Reality 节点请选择是。"; then
      tls_enabled="true"
      tls_server_name="$(ui_input "AI 分流 TLS Server Name" "请输入 TLS SNI / server_name；只有 IP 且无需 SNI 时可留空" "$current_tls_server_name")" || return 1
      tls_server_name="${tls_server_name//[$'\r\n ']}"
      if ui_yesno "是否允许不安全证书 insecure？"; then
        tls_insecure="true"
      fi
      if ui_yesno "是否启用 Reality？"; then
        reality_enabled="true"
        reality_public_key="$(prompt_nonempty "AI 分流 Reality Public Key" "请输入 Reality public key" "$current_reality_public_key")" || return 1
        reality_short_id="$(ui_input "AI 分流 Reality Short ID" "请输入 Reality short_id；可留空" "$current_reality_short_id")" || return 1
        reality_short_id="${reality_short_id//[$'\r\n ']}"
      fi
    fi

    state_jq --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" \
      --argjson tls_enabled "$tls_enabled" --arg tls_server_name "$tls_server_name" --argjson tls_insecure "$tls_insecure" \
      --argjson reality_enabled "$reality_enabled" --arg reality_public_key "$reality_public_key" --arg reality_short_id "$reality_short_id" \
      --argjson rules "$rules_json" --arg ts "$(utc_now)" '
      .routing.ai.enabled = true |
      .routing.ai.outbound_type = "vless" |
      .routing.ai.server = $server |
      .routing.ai.port = $port |
      .routing.ai.uuid = $uuid |
      .routing.ai.flow = $flow |
      .routing.ai.network = "tcp" |
      .routing.ai.tls_enabled = $tls_enabled |
      .routing.ai.tls_server_name = $tls_server_name |
      .routing.ai.tls_insecure = $tls_insecure |
      .routing.ai.reality_enabled = $reality_enabled |
      .routing.ai.reality_public_key = $reality_public_key |
      .routing.ai.reality_short_id = $reality_short_id |
      .routing.ai.domain_suffix = $rules.domain_suffix |
      .routing.ai.domain_keyword = $rules.domain_keyword |
      .routing.ai.ip_cidr = ($rules.ip_cidr // []) |
      .routing.ai.resolved_ip_cidr = [] |
      .meta.updated_at = $ts
    '
  fi

  apply_config
}

show_ai_routing_rules() {
  local rules_text summary
  rules_text="$(jq -r '
    [
      (.routing.ai.domain_suffix // [] | map("domain_suffix: " + .)[]?),
      (.routing.ai.domain_keyword // [] | map("domain_keyword: " + .)[]?),
      (.routing.ai.ip_cidr // [] | map("ip_cidr: " + .)[]?),
      (.routing.ai.resolved_ip_cidr // [] | map("resolved_ip_cidr: " + .)[]?)
    ] | if length == 0 then "当前没有 AI 分流站点规则。" else join("\n") end
  ' "$STATE_FILE")"

  summary=$(
    cat <<EOF
enabled = $(state_get '.routing.ai.enabled // false')
outbound = $(state_get '.routing.ai.outbound_type // "shadowsocks"')
address = $(state_get '.routing.ai.server // "-"')
port = $(state_get '.routing.ai.port // "-"')
tls = $(state_get '.routing.ai.tls_enabled // false')
reality = $(state_get '.routing.ai.reality_enabled // false')

[Rules]
${rules_text}
EOF
  )

  ui_show_text "AI 分流规则" "$summary"
}

append_ai_routing_rules() {
  local rules_input rules_json rules_count

  if [[ "$(state_get '.routing.ai.enabled // false')" != "true" ]]; then
    ui_msg "AI 分流当前未启用，请先完成 AI 分流配置后再新增规则。"
    return 0
  fi

  if (( $# > 0 )); then
    rules_input="$*"
  else
    rules_input="$(prompt_nonempty "新增 AI 分流规则" "请输入要追加的域名、网址、关键词或 IP/CIDR，用逗号/空格分隔；例如 openai.com, gemini, claude.ai, 1.2.3.4/32" "")" || return 1
  fi

  if ! rules_json="$(build_ai_rules_json "$rules_input")"; then
    ui_msg "AI 分流规则解析失败，请检查输入内容后重试。"
    return 1
  fi
  if ! rules_count="$(printf '%s' "$rules_json" | jq -r '((.domain_suffix // []) + (.domain_keyword // []) + (.ip_cidr // [])) | length')"; then
    ui_msg "AI 分流规则解析失败，请检查输入内容后重试。"
    return 1
  fi
  if [[ "$rules_count" -eq 0 ]]; then
    ui_msg "新增规则不能为空。"
    return 1
  fi

  state_jq --argjson rules "$rules_json" --arg ts "$(utc_now)" '
    .routing.ai.domain_suffix = (((.routing.ai.domain_suffix // []) + ($rules.domain_suffix // [])) | unique) |
    .routing.ai.domain_keyword = (((.routing.ai.domain_keyword // []) + ($rules.domain_keyword // [])) | unique) |
    .routing.ai.ip_cidr = (((.routing.ai.ip_cidr // []) + ($rules.ip_cidr // [])) | unique) |
    .meta.updated_at = $ts
  '

  apply_config
}

delete_ai_routing_rule() {
  local total_count choice selected_index selected_kind selected_rule
  local -a rule_kinds=()
  local -a rule_values=()
  local -a options=()

  total_count="$(state_get '((.routing.ai.domain_suffix // []) + (.routing.ai.domain_keyword // []) + (.routing.ai.ip_cidr // [])) | length')"
  if [[ "$total_count" -eq 0 ]]; then
    ui_msg "当前没有可删除的 AI 分流站点规则。"
    return 0
  fi

  while IFS=$'\t' read -r selected_kind selected_rule; do
    [[ -n "$selected_kind" && -n "$selected_rule" ]] || continue
    rule_kinds+=("$selected_kind")
    rule_values+=("$selected_rule")
    options+=("${#rule_values[@]}" "${selected_kind}: ${selected_rule}")
  done < <(jq -r '
    (.routing.ai.domain_suffix // [] | .[] | ["domain_suffix", .] | @tsv),
    (.routing.ai.domain_keyword // [] | .[] | ["domain_keyword", .] | @tsv),
    (.routing.ai.ip_cidr // [] | .[] | ["ip_cidr", .] | @tsv)
  ' "$STATE_FILE")

  options+=("0" "返回")
  choice="$(ui_menu "删除 AI 分流规则" "请选择要删除的规则" "${options[@]}")" || return 1
  [[ "$choice" == "0" ]] && return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || {
    ui_msg "无效选项，请重新选择。"
    return 1
  }

  selected_index=$((choice - 1))
  (( selected_index >= 0 && selected_index < ${#rule_values[@]} )) || {
    ui_msg "无效选项，请重新选择。"
    return 1
  }

  selected_kind="${rule_kinds[$selected_index]}"
  selected_rule="${rule_values[$selected_index]}"

  if [[ "$total_count" -eq 1 ]]; then
    ui_yesno "这是最后一条 AI 分流规则。删除后将自动关闭 AI 分流，是否继续？" || return 0
    state_jq --arg ts "$(utc_now)" '
      .routing.ai.enabled = false |
      .routing.ai.domain_suffix = [] |
      .routing.ai.domain_keyword = [] |
      .routing.ai.ip_cidr = [] |
      .routing.ai.resolved_ip_cidr = [] |
      .meta.updated_at = $ts
    '
  else
    state_jq --arg kind "$selected_kind" --arg rule "$selected_rule" --arg ts "$(utc_now)" '
      if $kind == "domain_suffix" then
        .routing.ai.domain_suffix |= map(select(. != $rule))
      elif $kind == "ip_cidr" then
        .routing.ai.ip_cidr |= map(select(. != $rule))
      else
        .routing.ai.domain_keyword |= map(select(. != $rule))
      end |
      .meta.updated_at = $ts
    '
  fi

  apply_config
}

add_client() {
  local protocol_choice name value
  protocol_choice="$(ui_protocol_menu)" || return 1

  case "$protocol_choice" in
    1)
      [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]] || {
        ui_msg "Shadowsocks 当前未启用，请先完成协议配置。"
        return 1
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 Shadowsocks 客户端名称" "ss-client-$(date +%H%M%S)")" || return 1
        if user_exists "shadowsocks" "$name"; then
          ui_msg "该客户端名称已存在，请换一个名称。"
          continue
        fi
        break
      done
      value="$(generate_base64_bytes 32)"
      append_ss_user "$name" "$value"
      apply_config
      ;;
    2)
      [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]] || {
        ui_msg "VLESS + Reality 当前未启用，请先完成协议配置。"
        return 1
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 VLESS 客户端名称" "vless-client-$(date +%H%M%S)")" || return 1
        if user_exists "vless_reality" "$name"; then
          ui_msg "该客户端名称已存在，请换一个名称。"
          continue
        fi
        break
      done
      value="$(generate_uuid)"
      append_vless_user "$name" "$value"
      apply_config
      ;;
    3)
      [[ "$(state_get '.protocols.hysteria2.enabled')" == "true" ]] || {
        ui_msg "Hysteria2 当前未启用，请先完成协议配置。"
        return 1
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 Hysteria2 客户端名称" "hy2-client-$(date +%H%M%S)")" || return 1
        if user_exists "hysteria2" "$name"; then
          ui_msg "该客户端名称已存在，请换一个名称。"
          continue
        fi
        break
      done
      value="$(generate_password)"
      append_hy2_user "$name" "$value"
      apply_config
      ;;
    *)
      return 0
      ;;
  esac
}

remove_client() {
  local protocol_choice protocol_key protocol_label user_name user_count
  protocol_choice="$(ui_protocol_menu)" || return 1

  case "$protocol_choice" in
    1)
      protocol_key="shadowsocks"
      protocol_label="Shadowsocks 2022"
      ;;
    2)
      protocol_key="vless_reality"
      protocol_label="VLESS + Reality"
      ;;
    3)
      protocol_key="hysteria2"
      protocol_label="Hysteria2"
      ;;
    *)
      return 0
      ;;
  esac

  [[ "$(state_get ".protocols.${protocol_key}.enabled")" == "true" ]] || {
    ui_msg "${protocol_label} 当前未启用，请先完成协议配置。"
    return 1
  }

  user_count="$(state_get ".protocols.${protocol_key}.users | length")"
  if [[ "$user_count" -eq 0 ]]; then
    ui_msg "${protocol_label} 当前没有可删除的客户端。"
    return 1
  fi

  if [[ "$user_count" -eq 1 ]]; then
    ui_msg "${protocol_label} 当前仅剩 1 个客户端。请先新增客户端，或停用该协议后再删除。"
    return 1
  fi

  user_name="$(select_protocol_user "$protocol_key" "删除客户端" "请选择要删除的 ${protocol_label} 客户端")" || return 1
  ui_yesno "确认删除客户端 ${user_name} 吗？" || return 0

  remove_protocol_user "$protocol_key" "$user_name"
  apply_config
}

realm_install_or_reset() {
  require_linux
  require_root
  has_systemd || {
    ui_msg "Realm 服务管理仅支持 systemd 环境。"
    return 1
  }
  ensure_realm_dirs
  init_realm_state_file

  if [[ -x "$REALM_BIN" || "$(realm_rule_group_count)" -gt 0 ]]; then
    ui_yesno "这会重新安装 Realm，并清空所有中转规则。是否继续？" || return 0
  fi

  install_realm_binary
  realm_state_jq --arg ts "$(utc_now)" '.rules = [] | .meta.updated_at = $ts'
  ensure_realm_service
  render_realm_config >"$REALM_CONFIG_FILE"

  if realm_service_exists; then
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi

  ui_msg "Realm 安装 / 重置完成。当前规则已清空，请继续添加转发规则。"
}

realm_uninstall() {
  ui_yesno "这将卸载 Realm，并删除所有中转规则和配置。是否继续？" || return 0

  if realm_service_exists; then
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi

  rm -f "$REALM_BIN" "$REALM_SERVICE_FILE" "$REALM_CONFIG_FILE" "$REALM_STATE_FILE" 2>/dev/null || true
  rm -rf "$REALM_DIR" 2>/dev/null || true

  if has_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed realm >/dev/null 2>&1 || true
  fi

  ui_msg "Realm 已卸载完成。"
}

add_realm_forward_rule() {
  local listen_port remote_host remote_port rule_id description entries_json error_count=0

  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  listen_port="$(realm_prompt_number_limited error_count "本地端口" "请输入需要监听的本地端口" "$(generate_vless_port)" 10000 60000)" || return 1
  remote_host="$(realm_prompt_nonempty_limited error_count "落地地址" "请输入目标地址【落地机的ip或域名】" "")" || return 1
  remote_port="$(realm_prompt_number_limited error_count "落地端口" "请输入目标端口【落地节点的端口】" "443" 1 65535)" || return 1

  rule_id="realm-$(date +%s)-$(generate_hex 4)"
  description="0.0.0.0:${listen_port} -> ${remote_host}:${remote_port}"
  entries_json="$(jq -nc --arg listen "0.0.0.0:${listen_port}" --arg remote "${remote_host}:${remote_port}" '[{listen: $listen, remote: $remote}]')"

  realm_state_jq --arg id "$rule_id" --arg description "$description" --argjson entries "$entries_json" --arg ts "$(utc_now)" '
    .rules += [{id: $id, type: "single", description: $description, entries: $entries}] |
    .meta.updated_at = $ts
  '

  apply_realm_config
}

add_realm_range_rule() {
  local listen_start listen_end remote_host remote_start remote_end count rule_id description entries_json error_count=0

  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  while true; do
    listen_start="$(realm_prompt_number_limited error_count "起始端口" "请输入本地起始端口" "$(generate_vless_port)" 10000 60000)" || return 1
    listen_end="$(realm_prompt_number_limited error_count "结束端口" "请输入本地结束端口" "$listen_start" 10000 60000)" || return 1
    if (( listen_end >= listen_start )); then
      break
    fi

    error_count=$((error_count + 1))
    if (( error_count >= 2 )); then
      ui_msg "连续输入错误两次，已返回 Realm 菜单。"
      return 1
    fi
    ui_msg "本地结束端口不能小于起始端口，再次输错将返回 Realm 菜单。"
  done

  remote_host="$(realm_prompt_nonempty_limited error_count "落地地址" "请输入目标地址【落地机的ip或域名】" "")" || return 1
  while true; do
    remote_start="$(realm_prompt_number_limited error_count "落地起始端口" "请输入目标起始端口【落地节点的端口】" "$listen_start" 1 65535)" || return 1
    remote_end="$(realm_prompt_number_limited error_count "落地结束端口" "请输入目标结束端口【落地节点的端口】" "$((remote_start + listen_end - listen_start))" 1 65535)" || return 1
    if (( remote_end >= remote_start )); then
      count=$((listen_end - listen_start))
      if (( count == (remote_end - remote_start) )); then
        break
      fi

      error_count=$((error_count + 1))
      if (( error_count >= 2 )); then
        ui_msg "连续输入错误两次，已返回 Realm 菜单。"
        return 1
      fi
      ui_msg "本地端口段和目标端口段长度必须一致，再次输错将返回 Realm 菜单。"
      continue
    fi

    error_count=$((error_count + 1))
    if (( error_count >= 2 )); then
      ui_msg "连续输入错误两次，已返回 Realm 菜单。"
      return 1
    fi
    ui_msg "目标结束端口不能小于起始端口，再次输错将返回 Realm 菜单。"
  done

  count=$((listen_end - listen_start))

  rule_id="realm-$(date +%s)-$(generate_hex 4)"
  description="0.0.0.0:${listen_start}-${listen_end} -> ${remote_host}:${remote_start}-${remote_end}"
  entries_json="$(jq -nc --arg host "$remote_host" --argjson listen_start "$listen_start" --argjson listen_end "$listen_end" --argjson remote_start "$remote_start" '
    [range(0; ($listen_end - $listen_start) + 1) | {
      listen: ("0.0.0.0:" + (($listen_start + .) | tostring)),
      remote: ($host + ":" + (($remote_start + .) | tostring))
    }]
  ')"

  realm_state_jq --arg id "$rule_id" --arg description "$description" --argjson entries "$entries_json" --arg ts "$(utc_now)" '
    .rules += [{id: $id, type: "range", description: $description, entries: $entries}] |
    .meta.updated_at = $ts
  '

  apply_realm_config
}

delete_realm_rule() {
  local choice selected_index rule_id
  local -a rule_ids=()
  local -a options=()

  ensure_realm_dirs
  init_realm_state_file

  if [[ "$(realm_rule_group_count)" -eq 0 ]]; then
    ui_msg "当前没有可删除的 Realm 转发规则。"
    return 0
  fi

  while IFS=$'\t' read -r rule_id description entry_count; do
    [[ -n "$rule_id" ]] || continue
    rule_ids+=("$rule_id")
    options+=("$(( ${#rule_ids[@]} ))" "${description}（${entry_count} 条）")
  done < <(jq -r '.rules[]? | [.id, .description, (.entries | length)] | @tsv' "$REALM_STATE_FILE")

  options+=("0" "返回")
  options+=("00" "退出脚本")

  choice="$(ui_menu "Realm 中转菜单" "请选择要删除的转发规则（输入 0 返回上一级，输入 00 退出脚本）" "${options[@]}")" || return 1
  case "$choice" in
    00)
      exit 0
      ;;
    0)
      return 0
      ;;
  esac

  [[ "$choice" =~ ^[0-9]+$ ]] || {
    ui_msg "无效选项，请重新选择。"
    return 1
  }

  selected_index=$((choice - 1))
  (( selected_index >= 0 && selected_index < ${#rule_ids[@]} )) || {
    ui_msg "无效选项，请重新选择。"
    return 1
  }

  rule_id="${rule_ids[$selected_index]}"
  realm_state_jq --arg id "$rule_id" --arg ts "$(utc_now)" '
    .rules |= map(select(.id != $id)) |
    .meta.updated_at = $ts
  '

  apply_realm_config
}

show_realm_config() {
  local summary rendered

  ensure_realm_dirs
  init_realm_state_file

  summary="$(jq -r '
    if (.rules | length) == 0 then
      "当前没有任何 Realm 转发规则。"
    else
      (.rules | to_entries | map("\(.key + 1). \(.value.description)（\(.value.entries | length) 条）") | join("\n"))
    end
  ' "$REALM_STATE_FILE")"
  rendered="$(render_realm_config)"

  ui_show_text "Realm 当前配置" "$(printf '规则列表：\n%s\n\n配置文件：%s\n\n%s\n' "$summary" "$REALM_CONFIG_FILE" "$rendered")"
}

start_realm_service() {
  has_systemd || {
    ui_msg "Realm 服务管理仅支持 systemd 环境。"
    return 1
  }
  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  [[ "$(realm_rule_group_count)" -gt 0 ]] || {
    ui_msg "当前没有任何转发规则，请先添加转发规则。"
    return 1
  }

  write_realm_config_file
  realm_apply_firewall_rules
  ensure_realm_service
  systemctl enable realm >/dev/null 2>&1 || true
  if ! systemctl start realm; then
    ui_show_text "Realm 启动失败" "$(journalctl -u realm -n 30 --no-pager 2>/dev/null || echo '无法读取 Realm 日志。')"
    return 1
  fi

  ui_msg "Realm 服务已启动。"
}

stop_realm_service() {
  has_systemd || {
    ui_msg "Realm 服务管理仅支持 systemd 环境。"
    return 1
  }
  if realm_service_exists; then
    systemctl stop realm >/dev/null 2>&1 || true
    ui_msg "Realm 服务已停止。"
  else
    ui_msg "当前未检测到 Realm systemd 服务。"
  fi
}

restart_realm_service() {
  has_systemd || {
    ui_msg "Realm 服务管理仅支持 systemd 环境。"
    return 1
  }
  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  [[ "$(realm_rule_group_count)" -gt 0 ]] || {
    ui_msg "当前没有任何转发规则，请先添加转发规则。"
    return 1
  }

  write_realm_config_file
  realm_apply_firewall_rules
  ensure_realm_service
  systemctl enable realm >/dev/null 2>&1 || true
  if ! systemctl restart realm; then
    ui_show_text "Realm 重启失败" "$(journalctl -u realm -n 30 --no-pager 2>/dev/null || echo '无法读取 Realm 日志。')"
    return 1
  fi

  ui_msg "Realm 服务已重启。"
}

manager_script_target_path() {
  printf '%s\n' "$MANAGER_SCRIPT_PATH"
}

install_manager_script_from_repo() {
  local target_path tmp_file
  local -a urls=(
    "https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/${SCRIPT_REPO_BRANCH}/index.sh"
    "https://github.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/raw/${SCRIPT_REPO_BRANCH}/index.sh"
    "https://cdn.jsdelivr.net/gh/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}@${SCRIPT_REPO_BRANCH}/index.sh"
  )

  target_path="$(manager_script_target_path)"
  tmp_file="$(mktemp "$TMP_DIR/sbox-update.XXXXXX")"
  if ! download_to_file "$tmp_file" "${urls[@]}"; then
    rm -f "$tmp_file"
    return 1
  fi

  mkdir -p "$(dirname "$target_path")"
  install -m 755 "$tmp_file" "$target_path"
  if [[ "$target_path" == "/usr/local/bin/sbox" ]]; then
    rm -f /usr/local/bin/singbox-manager 2>/dev/null || true
  fi
  rm -f "$tmp_file"
}

update_manager_script() {
  if ! install_manager_script_from_repo; then
    ui_msg "更新脚本失败，请稍后重试。"
    return 1
  fi

  ui_msg "脚本已更新完成。"
}

realm_submenu() {
  local choice
  local menu_text

  while true; do
    menu_text="$(realm_menu_text)"
    choice="$(ui_menu "Realm 中转菜单" "$menu_text" \
      "1" "安装 / 重置 Realm" \
      "2" "卸载 Realm" \
      "3" "添加转发规则" \
      "4" "添加端口段转发" \
      "5" "删除转发规则" \
      "6" "查看当前配置" \
      "7" "启动服务" \
      "8" "停止服务" \
      "9" "重启服务" \
      "10" "更新脚本" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || return 1

    case "$choice" in
      1)
        realm_install_or_reset
        ;;
      2)
        realm_uninstall
        ;;
      3)
        add_realm_forward_rule
        ;;
      4)
        add_realm_range_rule
        ;;
      5)
        delete_realm_rule
        ;;
      6)
        show_realm_config
        ;;
      7)
        start_realm_service
        ;;
      8)
        stop_realm_service
        ;;
      9)
        restart_realm_service
        ;;
      10)
        update_manager_script
        ;;
      0)
        return 0
        ;;
      00)
        exit 0
        ;;
      *)
        ui_msg "无效选项，请重新选择。"
        ;;
    esac
  done
}

sing_box_install_status() {
  if have_cmd sing-box; then
    printf '已安装\n'
  else
    printf '未安装\n'
  fi
}

realm_install_status() {
  if [[ -x "$REALM_BIN" ]]; then
    printf '已安装\n'
  else
    printf '未安装\n'
  fi
}

main_menu_text() {
  cat <<EOF
Sing-box 状态：$(sing_box_install_status)
Shadowsocks 2022 规则个数：$(state_get '.protocols.shadowsocks.users | length')
VLESS + Reality 规则个数：$(state_get '.protocols.vless_reality.users | length')
Hysteria2 规则个数：$(state_get '.protocols.hysteria2.users | length')
AI 分流状态：$(state_get '.routing.ai.enabled // false')

请选择要执行的操作
EOF
}

realm_menu_text() {
  local rule_count
  if [[ -s "$REALM_STATE_FILE" ]]; then
    rule_count="$(realm_rule_group_count)"
  else
    rule_count="0"
  fi

  cat <<EOF
Realm 状态：$(realm_install_status)
转发规则组个数：${rule_count}

请选择要执行的操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

prepare_realm_menu() {
  require_linux
  require_root
  has_systemd || {
    ui_msg "Realm 服务管理仅支持 systemd 环境。"
    return 1
  }

  ensure_realm_dirs
  init_realm_state_file

  if [[ ! -x "$REALM_BIN" ]]; then
    log "未检测到 Realm，正在自动安装..."
    install_realm_binary || {
      ui_msg "Realm 自动安装失败，请稍后重试。"
      return 1
    }
  fi

  ensure_realm_service
  write_realm_config_file
}

show_client_info() {
  local output="" links_file
  write_client_exports

  if [[ ! -s "$CLIENT_DIR/all-clients.txt" ]]; then
    ui_msg "当前还没有可展示的客户端信息。"
    return 0
  fi

  output="$(cat "$CLIENT_DIR/all-clients.txt")"
  links_file="$(direct_links_file)"
  if [[ -s "$links_file" ]]; then
    output+=$'\n[订阅链接]\n'"$(cat "$links_file")"
  fi

  ui_show_text "客户端信息" "$output"
}

show_subscription_links() {
  local links_file output
  write_client_exports
  links_file="$(direct_links_file)"

  if [[ ! -s "$links_file" ]]; then
    ui_msg "当前还没有可展示的订阅链接。"
    return 0
  fi

  output="$(cat "$links_file")"
  ui_show_text "订阅链接" "$output"
}

show_nekobox_routing_exports() {
  local output rule_file domain_file ip_file guide_file clash_file

  refresh_ai_resolved_ip_cidrs
  write_client_exports
  rule_file="$(nekobox_route_rule_file)"
  domain_file="$(nekobox_domain_rules_file)"
  ip_file="$(nekobox_ip_rules_file)"
  guide_file="$(nekobox_guide_file)"
  clash_file="$(nekobox_clash_meta_file)"

  output=$(
    cat <<EOF
NekoBox 分流规则已导出：

推荐：完整 Clash Meta 配置
$clash_file

备用：sing-box 自定义 route rule
$rule_file

简易路由域名规则
$domain_file

简易路由 IP 规则
$ip_file

使用说明
$guide_file

注意：NekoBox 导入节点/订阅通常只解析节点，不会自动应用服务端分流规则。请在 NekoBox 手机端本地路由里使用以上规则。
EOF
  )

  ui_show_text "NekoBox 分流规则" "$output"
}

show_overview() {
  local server_address service_status ss_users vless_users hy2_users overview node_name links_file
  server_address="$(state_get '.meta.server_address')"
  node_name="$(state_get '.meta.node_name')"

  if service_exists; then
    service_status="$(systemctl is-active sing-box 2>/dev/null || true)"
  else
    service_status="unknown"
  fi

  ss_users="$(jq -r '.protocols.shadowsocks.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"
  vless_users="$(jq -r '.protocols.vless_reality.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"
  hy2_users="$(jq -r '.protocols.hysteria2.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"
  links_file="$(direct_links_file)"

  overview=$(
    cat <<EOF
脚本版本: $SCRIPT_VERSION
节点名称: ${node_name:-未设置}
节点地址: ${server_address:-未设置}
sing-box 状态: $service_status
配置文件: $CONFIG_FILE
客户端导出目录: $CLIENT_DIR
导入链接文件: ${links_file}

[Shadowsocks 2022]
enabled = $(state_get '.protocols.shadowsocks.enabled')
port = $(state_get '.protocols.shadowsocks.port')
users = $ss_users

[VLESS + Reality]
enabled = $(state_get '.protocols.vless_reality.enabled')
port = $(state_get '.protocols.vless_reality.port')
sni = $(state_get '.protocols.vless_reality.server_name')
public_key = $(state_get '.protocols.vless_reality.public_key')
short_id = $(state_get '.protocols.vless_reality.short_id')
users = $vless_users

[Hysteria2]
enabled = $(state_get '.protocols.hysteria2.enabled')
port = $(state_get '.protocols.hysteria2.port')/udp
tls_server_name = $(state_get '.protocols.hysteria2.tls_server_name')
obfs_password = $(state_get '.protocols.hysteria2.obfs_password')
users = $hy2_users

[AI Routing]
enabled = $(state_get '.routing.ai.enabled // false')
outbound = $(state_get '.routing.ai.outbound_type // "shadowsocks"')
address = $(state_get '.routing.ai.server // "-"')
port = $(state_get '.routing.ai.port // "-"')
method = $(state_get '.routing.ai.method // "-"')
uuid = $(state_get '.routing.ai.uuid // "-"')
tls = $(state_get '.routing.ai.tls_enabled // false')
reality = $(state_get '.routing.ai.reality_enabled // false')
rules = $(format_ai_rule_list)
EOF
  )

  ui_show_text "当前概览" "$overview"
}

show_service_status() {
  local text=""

  if have_cmd sing-box; then
    text+="sing-box version: $(sing-box version 2>/dev/null | head -n 1)\n"
  else
    text+="sing-box version: 未安装\n"
  fi

  if service_exists; then
    text+="service active: $(systemctl is-active sing-box 2>/dev/null)\n"
    text+="service enabled: $(systemctl is-enabled sing-box 2>/dev/null)\n"
    text+="\n最近日志:\n"
    text+="$(journalctl -u sing-box -n 20 --no-pager 2>/dev/null || true)"
  else
    if has_systemd; then
      text+="未检测到 sing-box systemd 服务。\n"
      text+="可尝试执行：sbox quick-install\n"
      text+="如果 sing-box 已安装，脚本会自动补建 sing-box.service。"
    else
      text+="当前系统未检测到可用的 systemd 环境。"
    fi
  fi

  ui_show_text "服务状态" "$(printf '%b' "$text")"
}

uninstall_sbox() {
  local uninstall_text
  uninstall_text=$'这将执行以下操作：\n- 停止并禁用 sing-box\n- 停止并禁用 Realm\n- 卸载 sing-box 软件包（如果存在）\n- 删除 /etc/sing-box、/etc/realm 和 /etc/sing-box-manager\n- 删除 sbox 与 realm 命令\n\n是否继续？'

  ui_yesno "$uninstall_text" || return 0

  if have_cmd systemctl; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get remove -y sing-box >/dev/null 2>&1 || true
      apt-get purge -y sing-box >/dev/null 2>&1 || true
      apt-get autoremove -y >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf remove -y sing-box >/dev/null 2>&1 || true
      ;;
    yum)
      yum remove -y sing-box >/dev/null 2>&1 || true
      ;;
  esac

  rm -f /etc/systemd/system/sing-box.service /lib/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service /etc/systemd/system/multi-user.target.wants/sing-box.service 2>/dev/null || true
  rm -f "$REALM_SERVICE_FILE" /lib/systemd/system/realm.service /usr/lib/systemd/system/realm.service /etc/systemd/system/multi-user.target.wants/realm.service 2>/dev/null || true
  rm -rf /etc/sing-box "$REALM_DIR" "$STATE_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/sbox /usr/local/bin/singbox-manager "$REALM_BIN" 2>/dev/null || true

  if have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    systemctl reset-failed realm >/dev/null 2>&1 || true
  fi

  if is_interactive; then
    ui_msg "卸载完成。"
  else
    printf '卸载完成。\n'
  fi

  exit 0
}

main_menu() {
  local choice
  local menu_text

  while true; do
    menu_text="$(main_menu_text)"
    choice="$(ui_menu "$APP_TITLE" "$menu_text" \
      "1" "一键安装 / 初始化环境" \
      "2" "设置节点对外地址" \
      "3" "设置节点名称" \
      "4" "配置 Shadowsocks 2022" \
      "5" "配置 VLESS + Reality" \
      "6" "配置 Hysteria2" \
      "7" "新增客户端" \
      "8" "删除客户端" \
      "9" "查看客户端信息" \
      "10" "查看订阅链接" \
      "11" "重新生成配置并重载服务" \
      "12" "查看当前概览" \
      "13" "查看服务状态" \
      "14" "配置 AI 分流" \
      "15" "查看 AI 分流规则" \
      "16" "新增 AI 分流规则" \
      "17" "删除 AI 分流规则" \
      "18" "导出 NekoBox 分流规则" \
      "19" "Realm 中转" \
      "20" "重新安装 / 修复（保留规则）" \
      "21" "卸载" \
      "0" "退出")" || break

    case "$choice" in
      1)
        quick_install
        ;;
      2)
        configure_server_address
        ;;
      3)
        configure_node_name
        ;;
      4)
        configure_shadowsocks
        ;;
      5)
        configure_vless_reality
        ;;
      6)
        configure_hysteria2
        ;;
      7)
        add_client
        ;;
      8)
        remove_client
        ;;
      9)
        show_client_info
        ;;
      10)
        show_subscription_links
        ;;
      11)
        apply_config
        ;;
      12)
        show_overview
        ;;
      13)
        show_service_status
        ;;
      14)
        configure_ai_routing
        ;;
      15)
        show_ai_routing_rules
        ;;
      16)
        append_ai_routing_rules
        ;;
      17)
        delete_ai_routing_rule
        ;;
      18)
        show_nekobox_routing_exports
        ;;
      19)
        prepare_realm_menu && realm_submenu
        ;;
      20)
        export SBOX_REPAIR_OPEN_PANEL=1
        repair_install
        ;;
      21)
        uninstall_sbox
        ;;
      0)
        break
        ;;
      *)
        ui_msg "无效选项，请重新选择。"
        ;;
    esac
  done
}

version() {
  printf '%s %s\n' "$APP_TITLE" "$SCRIPT_VERSION"
}

usage() {
  cat <<EOF
用法:
  $SCRIPT_NAME                打开管理面板
  $SCRIPT_NAME quick-install  一键安装并初始化
  $SCRIPT_NAME add-client     打开新增客户端流程
  $SCRIPT_NAME remove-client  打开删除客户端流程
  $SCRIPT_NAME ai-route       配置 AI 分流到远端 SS / VLESS 落地节点
  $SCRIPT_NAME ai-rules       查看 AI 分流规则
  $SCRIPT_NAME add-ai-rule domain1 keyword2
                          新增 AI 分流规则
  $SCRIPT_NAME delete-ai-rule 删除 AI 分流规则
  $SCRIPT_NAME nekobox-rules  导出 NekoBox Clash Meta 手机端分流配置
  $SCRIPT_NAME repair-install 重新安装 / 修复环境并保留现有规则
  $SCRIPT_NAME realm          打开 Realm 中转菜单
  $SCRIPT_NAME apply          重新生成配置并重载服务
  $SCRIPT_NAME show           查看客户端信息
  $SCRIPT_NAME overview       查看当前概览
  $SCRIPT_NAME status         查看服务状态
  $SCRIPT_NAME uninstall      卸载 sing-box 和 sbox
  $SCRIPT_NAME --version      查看脚本版本

说明:
  1. 面板使用纯命令行数字输入，不依赖方向键。
  2. Hysteria2 默认使用自签名证书。
  3. 非交互安装可通过 SINGBOX_SERVER_ADDRESS=your.domain 指定节点地址。
  4. AI 分流支持 Shadowsocks 和 VLESS，落地节点地址可以是域名、IPv4 或 IPv6。
  5. repair-install 会重装 / 更新脚本和 sing-box 核心，但不会删除状态文件、客户端或分流规则。
  6. 一键安装只安装环境；当你启用协议或新增客户端后，才会生成对应的协议链接。
EOF
}

main() {
  setup_terminal_env
  init_ui

  case "${1:-panel}" in
    quick-install)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      quick_install
      ;;
    apply)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      apply_config
      ;;
    show)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_client_info
      ;;
    add-client)
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      add_client
      ;;
    remove-client)
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      remove_client
      ;;
    ai-route)
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      configure_ai_routing
      ;;
    ai-rules|show-ai-rules)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_ai_routing_rules
      ;;
    add-ai-rule|add-ai-rules|append-ai-rule|append-ai-rules)
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      append_ai_routing_rules "${@:2}"
      ;;
    delete-ai-rule|remove-ai-rule)
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      delete_ai_routing_rule
      ;;
    nekobox-rules|nekobox-clash|export-nekobox|nekobox)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_nekobox_routing_exports
      ;;
    repair-install|reinstall)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      repair_install
      ;;
    realm)
      ensure_ui_backend
      ensure_dirs
      prepare_realm_menu && realm_submenu
      ;;
    overview)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_overview
      ;;
    status)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_service_status
      ;;
    uninstall)
      require_linux
      require_root
      uninstall_sbox
      ;;
    version|-v|--version)
      version
      ;;
    help|-h|--help)
      usage
      ;;
    panel|"")
      require_linux
      require_root
      ensure_ui_backend
      ensure_dirs
      init_state_file
      main_menu
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
