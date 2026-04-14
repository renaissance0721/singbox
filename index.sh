#!/usr/bin/env bash
#
# Sing-box 一键安装与管理面板
# 用于在 Linux VPS 上快速安装和配置 Sing-box 的 Shell 脚本
# 支持 Shadowsocks 2022、VLESS + Reality 和 Hysteria2 协议
#
# 作者: renaissance0721
# 版本: 0.1.0
# 许可证: MIT
#
# 使用方法:
#   sbox                        启动可视化管理面板
#   sbox quick-install          使用默认参数进行一键初始化
#   sbox add-client             进入新增客户端流程
#   sbox remove-client          进入删除客户端流程
#   sbox show                   查看客户端信息
#   SINGBOX_SERVER_ADDRESS=your.domain sbox quick-install
#

set -Eeuo pipefail

ORIGINAL_ARGS=("$@")
SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_VERSION="0.1.0"
SCRIPT_NAME="${0##*/}"
APP_TITLE="Sing-box 一键安装与管理面板"
STATE_DIR="${STATE_DIR:-/etc/sing-box-manager}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
CLIENT_DIR="${CLIENT_DIR:-$STATE_DIR/clients}"
CERT_DIR="${CERT_DIR:-$STATE_DIR/certs}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
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

init_ui() {
  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    HAS_WHIPTAIL=1
  else
    HAS_WHIPTAIL=0
  fi
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
  [[ "$(uname -s)" == "Linux" ]] || die "该脚本目前仅支持 Linux VPS。"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$CLIENT_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")"
  mkdir -p "$CLIENT_DIR/shadowsocks" "$CLIENT_DIR/vless-reality" "$CLIENT_DIR/hysteria2"
}

ui_msg() {
  local text=${1:-}
  if (( HAS_WHIPTAIL )); then
    whiptail --title "$APP_TITLE" --msgbox "$text" 18 78
  else
    printf '\n%s\n\n' "$text"
  fi
}

ui_show_text() {
  local title=${1:-$APP_TITLE}
  local text=${2:-}
  if (( HAS_WHIPTAIL )); then
    local tmp_file
    tmp_file="$(mktemp "$TMP_DIR/singbox-panel.XXXXXX")"
    printf '%s\n' "$text" >"$tmp_file"
    whiptail --title "$title" --scrolltext --textbox "$tmp_file" 28 100
    rm -f "$tmp_file"
  else
    printf '\n[%s]\n%s\n\n' "$title" "$text"
  fi
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

  if (( HAS_WHIPTAIL )); then
    whiptail --title "$title" --menu "$text" 22 86 12 "$@" 3>&1 1>&2 2>&3
  else
    printf '\n[%s]\n%s\n' "$title" "$text"
    while (( $# >= 2 )); do
      printf '  %s) %s\n' "$1" "$2"
      shift 2
    done
    local choice
    read -r -p "请选择: " choice
    printf '%s\n' "$choice"
  fi
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
    log "检测到 sing-box 已安装，跳过安装步骤。"
  else
    log "开始通过官方安装脚本安装 sing-box..."
    curl -fsSL https://sing-box.app/install.sh | sh
  fi

  if have_cmd systemctl; then
    systemctl enable sing-box >/dev/null 2>&1 || true
  fi
}

service_exists() {
  have_cmd systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^sing-box\.service'
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
    return 0
  fi

  local now
  now="$(utc_now)"

  cat >"$STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "server_address": "",
    "created_at": "$now",
    "updated_at": "$now",
    "log_level": "info"
  },
  "protocols": {
    "shadowsocks": {
      "enabled": false,
      "listen": "::",
      "port": 8388,
      "network": "tcp",
      "method": "2022-blake3-aes-256-gcm",
      "server_password": "",
      "multiplex": true,
      "users": []
    },
    "vless_reality": {
      "enabled": false,
      "listen": "::",
      "port": 443,
      "server_name": "www.cloudflare.com",
      "handshake_server": "www.cloudflare.com",
      "handshake_port": 443,
      "private_key": "",
      "public_key": "",
      "short_id": "",
      "users": []
    },
    "hysteria2": {
      "enabled": false,
      "listen": "::",
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
  local current_password user_count
  current_password="$(state_get '.protocols.shadowsocks.server_password')"
  user_count="$(state_get '.protocols.shadowsocks.users | length')"

  if [[ -z "$current_password" || "$current_password" == "null" ]]; then
    current_password="$(generate_base64_bytes 32)"
  fi

  state_jq --arg password "$current_password" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = "::" |
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
  local private_key public_key short_id user_count keypair
  private_key="$(state_get '.protocols.vless_reality.private_key')"
  public_key="$(state_get '.protocols.vless_reality.public_key')"
  short_id="$(state_get '.protocols.vless_reality.short_id')"
  user_count="$(state_get '.protocols.vless_reality.users | length')"

  if [[ -z "$private_key" || "$private_key" == "null" || -z "$public_key" || "$public_key" == "null" ]]; then
    keypair="$(generate_reality_keypair)"
    private_key="${keypair%%$'\t'*}"
    public_key="${keypair##*$'\t'}"
  fi

  if [[ -z "$short_id" || "$short_id" == "null" ]]; then
    short_id="$(generate_hex 8)"
  fi

  state_jq --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" --arg ts "$(utc_now)" '
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.listen = "::" |
    .protocols.vless_reality.port = (.protocols.vless_reality.port // 443) |
    .protocols.vless_reality.server_name = (if .protocols.vless_reality.server_name == "" then "www.cloudflare.com" else .protocols.vless_reality.server_name end) |
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
  local tls_server_name obfs_password user_count
  tls_server_name="$(state_get '.protocols.hysteria2.tls_server_name')"
  obfs_password="$(state_get '.protocols.hysteria2.obfs_password')"
  user_count="$(state_get '.protocols.hysteria2.users | length')"

  if [[ -z "$tls_server_name" || "$tls_server_name" == "null" ]]; then
    tls_server_name="$(state_get '.meta.server_address')"
  fi

  if [[ -z "$obfs_password" || "$obfs_password" == "null" ]]; then
    obfs_password="$(generate_password)"
  fi

  state_jq --arg tls_server_name "$tls_server_name" --arg obfs_password "$obfs_password" --arg ts "$(utc_now)" '
    .protocols.hysteria2.enabled = true |
    .protocols.hysteria2.listen = "::" |
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

  ss_enabled="$(state_get '.protocols.shadowsocks.enabled')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  hy2_enabled="$(state_get '.protocols.hysteria2.enabled')"

  if [[ "$ss_enabled" == "true" ]]; then
    [[ "$(state_get '.protocols.shadowsocks.users | length')" -gt 0 ]] || errors+=$'Shadowsocks 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.shadowsocks.server_password')" ]] || errors+=$'Shadowsocks 服务端密码不能为空。\n'
  fi

  if [[ "$vless_enabled" == "true" ]]; then
    [[ "$(state_get '.protocols.vless_reality.users | length')" -gt 0 ]] || errors+=$'VLESS + Reality 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.vless_reality.private_key')" ]] || errors+=$'VLESS + Reality 私钥不能为空。\n'
    [[ -n "$(state_get '.protocols.vless_reality.public_key')" ]] || errors+=$'VLESS + Reality 公钥不能为空。\n'
    [[ -n "$(state_get '.protocols.vless_reality.short_id')" ]] || errors+=$'VLESS + Reality short_id 不能为空。\n'
  fi

  if [[ "$hy2_enabled" == "true" ]]; then
    ensure_hysteria_cert
    [[ "$(state_get '.protocols.hysteria2.users | length')" -gt 0 ]] || errors+=$'Hysteria2 至少需要一个客户端。\n'
    [[ -f "$(state_get '.protocols.hysteria2.cert_path')" ]] || errors+=$'Hysteria2 证书文件不存在。\n'
    [[ -f "$(state_get '.protocols.hysteria2.key_path')" ]] || errors+=$'Hysteria2 私钥文件不存在。\n'
  fi

  if [[ -n "$errors" ]]; then
    ui_show_text "配置校验失败" "$errors"
    return 1
  fi

  return 0
}

render_config() {
  jq '{
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
    ]
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

write_client_exports() {
  local all_file server_address
  all_file="$CLIENT_DIR/all-clients.txt"
  server_address="$(state_get '.meta.server_address')"

  : >"$all_file"
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
name = $name
server = $server_address
port = $ss_port
method = $ss_method
password = ${ss_server_password}:${user_password}
network = tcp
multiplex = true
EOF
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
name = $name
server = $server_address
port = $vless_port
uuid = $uuid
flow = xtls-rprx-vision
tls.server_name = $vless_server_name
reality.public_key = $vless_public_key
reality.short_id = $vless_short_id
transport = tcp
EOF
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
name = $name
server = $server_address
port = $hy2_port
password = $password
tls.server_name = $hy2_sni
tls.insecure = true
obfs = salamander
obfs_password = $hy2_obfs
EOF
      cat "$CLIENT_DIR/hysteria2/${name}.txt" >>"$all_file"
      printf '\n' >>"$all_file"
    done < <(jq -r '.protocols.hysteria2.users[]? | [.name, .password] | @tsv' "$STATE_FILE")
  fi
}

apply_config() {
  local enabled_count tmp_config check_output
  enabled_count="$(enabled_protocol_count)"

  if [[ "$enabled_count" -eq 0 ]]; then
    stop_sing_box
    ui_msg "当前没有启用任何协议，sing-box 服务已停止。"
    return 0
  fi

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

  ui_msg "配置已写入 $CONFIG_FILE，服务已重载。客户端信息已导出到 $CLIENT_DIR。"
}

quick_install() {
  require_linux
  require_root
  ensure_dirs
  install_dependencies
  install_sing_box
  init_state_file
  set_server_address_if_empty
  ensure_ss_defaults
  ensure_vless_defaults
  ensure_hy2_defaults
  apply_config
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

configure_shadowsocks() {
  local current_port port regenerate_password server_password

  if ! ui_yesno "是否启用或保持启用 Shadowsocks 2022？选择“否”将停用该协议。"; then
    state_jq --arg ts "$(utc_now)" '.protocols.shadowsocks.enabled = false | .meta.updated_at = $ts'
    apply_config
    return 0
  fi

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

  state_jq --argjson port "$port" --arg server_password "$server_password" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = "::" |
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
  local current_port port current_sni sni current_handshake_port handshake_port keypair private_key public_key short_id

  if ! ui_yesno "是否启用或保持启用 VLESS + Reality？选择“否”将停用该协议。"; then
    state_jq --arg ts "$(utc_now)" '.protocols.vless_reality.enabled = false | .meta.updated_at = $ts'
    apply_config
    return 0
  fi

  current_port="$(state_get '.protocols.vless_reality.port')"
  current_sni="$(state_get '.protocols.vless_reality.server_name')"
  current_handshake_port="$(state_get '.protocols.vless_reality.handshake_port')"

  port="$(prompt_number "VLESS 端口" "请输入 VLESS + Reality 监听端口" "$current_port" 1 65535)" || return 1
  sni="$(prompt_nonempty "Reality SNI" "请输入 Reality 伪装域名（例如 www.cloudflare.com）" "$current_sni")" || return 1
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

  state_jq --argjson port "$port" --arg sni "$sni" --arg handshake_server "$sni" --argjson handshake_port "$handshake_port" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" --arg ts "$(utc_now)" '
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.listen = "::" |
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
  local port up_mbps down_mbps tls_server_name masquerade obfs_password

  if ! ui_yesno "是否启用或保持启用 Hysteria2？选择“否”将停用该协议。"; then
    state_jq --arg ts "$(utc_now)" '.protocols.hysteria2.enabled = false | .meta.updated_at = $ts'
    apply_config
    return 0
  fi

  current_port="$(state_get '.protocols.hysteria2.port')"
  current_up="$(state_get '.protocols.hysteria2.up_mbps')"
  current_down="$(state_get '.protocols.hysteria2.down_mbps')"
  current_sni="$(state_get '.protocols.hysteria2.tls_server_name')"
  current_masquerade="$(state_get '.protocols.hysteria2.masquerade')"

  port="$(prompt_number "Hysteria2 端口" "请输入 Hysteria2 监听端口（UDP）" "$current_port" 1 65535)" || return 1
  up_mbps="$(prompt_number "上行带宽" "请输入上行 Mbps" "$current_up" 1 100000)" || return 1
  down_mbps="$(prompt_number "下行带宽" "请输入下行 Mbps" "$current_down" 1 100000)" || return 1
  tls_server_name="$(prompt_nonempty "TLS Server Name" "请输入 Hysteria2 证书域名或 IP（初版默认自签名）" "$current_sni")" || return 1
  masquerade="$(prompt_nonempty "Masquerade" "请输入认证失败时伪装地址" "$current_masquerade")" || return 1

  obfs_password="$(state_get '.protocols.hysteria2.obfs_password')"
  if ui_yesno "是否重新生成 Hysteria2 的 Salamander 混淆密码？"; then
    obfs_password="$(generate_password)"
  fi
  if [[ -z "$obfs_password" || "$obfs_password" == "null" ]]; then
    obfs_password="$(generate_password)"
  fi

  state_jq --argjson port "$port" --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps" --arg tls_server_name "$tls_server_name" --arg masquerade "$masquerade" --arg obfs_password "$obfs_password" --arg ts "$(utc_now)" '
    .protocols.hysteria2.enabled = true |
    .protocols.hysteria2.listen = "::" |
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

show_client_info() {
  write_client_exports

  if [[ ! -s "$CLIENT_DIR/all-clients.txt" ]]; then
    ui_msg "当前还没有可展示的客户端信息。"
    return 0
  fi

  ui_show_text "客户端信息" "$(cat "$CLIENT_DIR/all-clients.txt")"
}

show_overview() {
  local server_address service_status ss_users vless_users hy2_users overview
  server_address="$(state_get '.meta.server_address')"

  if service_exists; then
    service_status="$(systemctl is-active sing-box 2>/dev/null || true)"
  else
    service_status="unknown"
  fi

  ss_users="$(jq -r '.protocols.shadowsocks.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"
  vless_users="$(jq -r '.protocols.vless_reality.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"
  hy2_users="$(jq -r '.protocols.hysteria2.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE")"

  overview=$(
    cat <<EOF
脚本版本: $SCRIPT_VERSION
节点地址: ${server_address:-未设置}
sing-box 状态: $service_status
配置文件: $CONFIG_FILE
客户端导出目录: $CLIENT_DIR

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
    text+="未检测到 sing-box systemd 服务。"
  fi

  ui_show_text "服务状态" "$(printf '%b' "$text")"
}

main_menu() {
  local choice

  while true; do
    choice="$(ui_menu "$APP_TITLE" "请选择要执行的操作" \
      "1" "一键安装 / 初始化三协议" \
      "2" "设置节点对外地址" \
      "3" "配置 Shadowsocks 2022" \
      "4" "配置 VLESS + Reality" \
      "5" "配置 Hysteria2" \
      "6" "新增客户端" \
      "7" "删除客户端" \
      "8" "查看客户端信息" \
      "9" "重新生成配置并重载服务" \
      "10" "查看当前概览" \
      "11" "查看服务状态" \
      "0" "退出")" || break

    case "$choice" in
      1)
        quick_install
        ;;
      2)
        configure_server_address
        ;;
      3)
        configure_shadowsocks
        ;;
      4)
        configure_vless_reality
        ;;
      5)
        configure_hysteria2
        ;;
      6)
        add_client
        ;;
      7)
        remove_client
        ;;
      8)
        show_client_info
        ;;
      9)
        apply_config
        ;;
      10)
        show_overview
        ;;
      11)
        show_service_status
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
  $SCRIPT_NAME                启动终端可视化管理面板
  $SCRIPT_NAME quick-install  使用默认参数进行一键初始化
  $SCRIPT_NAME add-client     进入新增客户端流程
  $SCRIPT_NAME remove-client  进入删除客户端流程
  $SCRIPT_NAME apply          重新生成配置并重载服务
  $SCRIPT_NAME show           查看客户端信息
  $SCRIPT_NAME overview       查看当前概览
  $SCRIPT_NAME status         查看服务状态
  $SCRIPT_NAME --version      查看脚本版本

说明:
  1. 面板优先使用 whiptail；在非交互环境下会自动回退为命令行提示。
  2. Hysteria2 默认使用自签名证书，客户端侧需要允许 insecure 或后续替换为正式证书。
  3. 已内置 Shadowsocks 2022、VLESS + Reality、Hysteria2 的多用户配置生成逻辑。
  4. 非交互初始化可通过 SINGBOX_SERVER_ADDRESS=your.domain 指定节点地址。
EOF
}

main() {
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
      ensure_dirs
      init_state_file
      add_client
      ;;
    remove-client)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      remove_client
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
    version|-v|--version)
      version
      ;;
    help|-h|--help)
      usage
      ;;
    panel|"")
      require_linux
      require_root
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
