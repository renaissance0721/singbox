#!/usr/bin/env bash
#
# Sing-box 一键安装与管理面板
# 用于在 Linux VPS 上快速安装和管理 sing-box 的 Shell 脚本
# 支持 Shadowsocks、VLESS + Reality 和 Hysteria2
#
# 作者: renaissance0721
# 版本: 0.7.0
# 许可证: MIT
#
# 使用方法:
#   sbox                        打开管理面板
#   sbox quick-install          一键安装并初始化
#   sbox add-client             打开新增客户端流程
#   sbox remove-client          打开删除客户端流程
#   sbox show                   查看客户端信息
#

set -Eeuo pipefail
umask 077

# Root shells started by minimal images or control panels may omit sbin paths,
# even though runuser/su-exec and account-management tools are installed there.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

ORIGINAL_ARGS=("$@")
SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_VERSION="0.7.0"
SCRIPT_NAME="${0##*/}"
APP_TITLE="Sing-box 管理面板 | 输入 sbox 快捷打开脚本"
STATE_DIR="${STATE_DIR:-/etc/sing-box-manager}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
RULE_SET_CACHE_DIR="${RULE_SET_CACHE_DIR:-$STATE_DIR/rule-set-cache}"
RULE_SET_CACHE_FILE="${RULE_SET_CACHE_FILE:-$RULE_SET_CACHE_DIR/cache.db}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
CLIENT_DIR="${CLIENT_DIR:-$STATE_DIR/clients}"
CERT_DIR="${CERT_DIR:-$STATE_DIR/certs}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
XRAY_INSTALL_DIR="${XRAY_INSTALL_DIR:-/usr/local/lib/sbox-xray}"
XRAY_BIN="${XRAY_BIN:-$XRAY_INSTALL_DIR/xray}"
XRAY_ASSET_DIR="${XRAY_ASSET_DIR:-$XRAY_INSTALL_DIR/assets}"
XRAY_MANAGED_MARKER="${XRAY_MANAGED_MARKER:-$XRAY_INSTALL_DIR/.managed-by-sbox}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-$STATE_DIR/xray/config.json}"
XRAY_SYSTEMD_SERVICE_FILE="${XRAY_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/sbox-xray.service}"
XRAY_OPENRC_SERVICE_FILE="${XRAY_OPENRC_SERVICE_FILE:-/etc/init.d/sbox-xray}"
XRAY_OPENRC_LOG_FILE="${XRAY_OPENRC_LOG_FILE:-/var/log/sbox-xray.log}"
SING_BOX_OPENRC_SERVICE_FILE="${SING_BOX_OPENRC_SERVICE_FILE:-/etc/init.d/sing-box}"
SING_BOX_OPENRC_LOG_FILE="${SING_BOX_OPENRC_LOG_FILE:-/var/log/sing-box.log}"
REALM_DIR="${REALM_DIR:-/etc/realm}"
REALM_CONFIG_FILE="${REALM_CONFIG_FILE:-$REALM_DIR/config.toml}"
REALM_STATE_FILE="${REALM_STATE_FILE:-$STATE_DIR/realm-state.json}"
REALM_BIN="${REALM_BIN:-/usr/local/bin/realm}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-/etc/systemd/system/realm.service}"
REALM_OPENRC_SERVICE_FILE="${REALM_OPENRC_SERVICE_FILE:-/etc/init.d/realm}"
REALM_OPENRC_LOG_FILE="${REALM_OPENRC_LOG_FILE:-/var/log/realm.log}"
WIREGUARD_DIR="${WIREGUARD_DIR:-/etc/wireguard}"
WIREGUARD_INTERFACE_PREFIX="sbwg"
WIREGUARD_OPENRC_SERVICE_PREFIX="sbox-wg"
FIREWALL_STATE_FILE="${FIREWALL_STATE_FILE:-$STATE_DIR/firewall-managed.tsv}"
FIREWALL_PORT_POLICY_FILE="${FIREWALL_PORT_POLICY_FILE:-$STATE_DIR/firewall-port-policy.tsv}"
IPTABLES_MIGRATION_MARKER="${IPTABLES_MIGRATION_MARKER:-$STATE_DIR/iptables-comment-rules.migrated}"
IPTABLES_RULE_COMMENT="${IPTABLES_RULE_COMMENT:-sbox-managed}"
FIREWALL_SYSTEMD_SERVICE_FILE="${FIREWALL_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/sbox-firewall.service}"
SING_BOX_FIREWALL_DROPIN_DIR="${SING_BOX_FIREWALL_DROPIN_DIR:-/etc/systemd/system/sing-box.service.d}"
XRAY_FIREWALL_DROPIN_DIR="${XRAY_FIREWALL_DROPIN_DIR:-/etc/systemd/system/sbox-xray.service.d}"
REALM_FIREWALL_DROPIN_DIR="${REALM_FIREWALL_DROPIN_DIR:-/etc/systemd/system/realm.service.d}"
SING_BOX_HARDENING_DROPIN_FILE="${SING_BOX_HARDENING_DROPIN_FILE:-$SING_BOX_FIREWALL_DROPIN_DIR/20-sbox-hardening.conf}"
RUNTIME_USER="${RUNTIME_USER:-sbox-runtime}"
RUNTIME_GROUP="${RUNTIME_GROUP:-sbox-runtime}"
SAGERNET_GPG_FINGERPRINT="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"
MANAGER_SCRIPT_PATH="${MANAGER_SCRIPT_PATH:-/usr/local/bin/sbox}"
PROJECT_INSTALL_DIR="${PROJECT_INSTALL_DIR:-/usr/local/share/sbox}"
SCRIPT_REPO_OWNER="renaissance0721"
SCRIPT_REPO_NAME="singbox"
SCRIPT_REPO_BRANCH="main"
SCRIPT_REPO_ID="1210354428"
SCRIPT_REPO_OWNER_ID="197479185"
TMP_DIR="${TMP_DIR:-/tmp}"
SSHD_CONFIG_FILE="${SSHD_CONFIG_FILE:-/etc/ssh/sshd_config}"

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
      if curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 --speed-limit 1024 --speed-time 30 \
        "$url" -o "$destination"; then
        return 0
      fi
      # Some VPS networks advertise unusable IPv6 routes. Retry through IPv4
      # before falling back to wget so a single broken address family does not
      # make an otherwise reachable update source fail.
      if curl -4 -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 --speed-limit 1024 --speed-time 30 \
        "$url" -o "$destination"; then
        return 0
      fi
    done
  fi

  if have_cmd wget; then
    for url in "$@"; do
      if wget --timeout=30 --tries=2 -qO "$destination" "$url"; then
        return 0
      fi
    done
  fi

  if ! have_cmd curl && ! have_cmd wget; then
    die "未检测到 curl 或 wget，无法下载文件。"
  fi

  return 1
}

sha256_file() {
  local file=$1
  if have_cmd sha256sum; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif have_cmd openssl; then
    openssl dgst -sha256 "$file" | awk '{print tolower($NF)}'
  else
    return 1
  fi
}

git_blob_sha1_file() {
  local file=$1 file_size
  file_size="$(wc -c <"$file" | tr -d '[:space:]')" || return 1
  [[ "$file_size" =~ ^[0-9]+$ ]] || return 1

  if have_cmd sha1sum; then
    { printf 'blob %s\0' "$file_size"; command cat "$file"; } |
      sha1sum | awk '{print tolower($1)}'
  elif have_cmd openssl; then
    { printf 'blob %s\0' "$file_size"; command cat "$file"; } |
      openssl dgst -sha1 | awk '{print tolower($NF)}'
  else
    return 1
  fi
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  if have_cmd sudo; then
    exec sudo env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TERM="${TERM:-xterm-256color}" LANG="${LANG:-C.UTF-8}" LC_CTYPE="${LC_CTYPE:-C.UTF-8}" \
      bash "$SELF_PATH" "${ORIGINAL_ARGS[@]}"
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
  install -d -m 0750 "$STATE_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")" "$(dirname "$XRAY_CONFIG_FILE")"
  install -d -m 0700 "$BACKUP_DIR" "$CLIENT_DIR"
  install -d -m 0700 "$CLIENT_DIR/shadowsocks" "$CLIENT_DIR/vless-reality" "$CLIENT_DIR/hysteria2"

  if runtime_account_exists; then
    chown root:"$RUNTIME_GROUP" "$STATE_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")" "$(dirname "$XRAY_CONFIG_FILE")"
  fi
}

ensure_rule_set_cache_dir() {
  ensure_runtime_account
  install -d -o root -g "$RUNTIME_GROUP" -m 0770 "$RULE_SET_CACHE_DIR"
}

ensure_realm_dirs() {
  install -d -m 0750 "$REALM_DIR" "$STATE_DIR"
  if runtime_account_exists; then
    chown root:"$RUNTIME_GROUP" "$REALM_DIR" "$STATE_DIR"
  fi
}

ensure_wireguard_dirs() {
  install -d -m 0700 "$WIREGUARD_DIR" "$STATE_DIR"
}

runtime_account_exists() {
  id -u "$RUNTIME_USER" >/dev/null 2>&1 &&
    { getent group "$RUNTIME_GROUP" >/dev/null 2>&1 || grep -q "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null; }
}

ensure_runtime_account() {
  local nologin_shell

  if ! { getent group "$RUNTIME_GROUP" >/dev/null 2>&1 || grep -q "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null; }; then
    if have_cmd groupadd; then
      groupadd --system "$RUNTIME_GROUP"
    elif have_cmd addgroup; then
      addgroup -S "$RUNTIME_GROUP"
    else
      die "无法创建 sing-box 低权限运行组：缺少 groupadd/addgroup。"
    fi
  fi

  if ! id -u "$RUNTIME_USER" >/dev/null 2>&1; then
    nologin_shell="$(command -v nologin 2>/dev/null || true)"
    nologin_shell="${nologin_shell:-/sbin/nologin}"
    if have_cmd useradd; then
      useradd --system --gid "$RUNTIME_GROUP" --home-dir /nonexistent --shell "$nologin_shell" "$RUNTIME_USER"
    elif have_cmd adduser; then
      adduser -S -D -H -G "$RUNTIME_GROUP" -s "$nologin_shell" "$RUNTIME_USER"
    else
      die "无法创建 sing-box 低权限运行用户：缺少 useradd/adduser。"
    fi
  fi

  runtime_account_exists || die "sing-box 低权限运行用户创建失败。"
  ensure_dirs
  ensure_realm_dirs
}

runtime_launcher_path() {
  local launcher candidate

  for launcher in runuser su-exec; do
    candidate="$(command -v "$launcher" 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for candidate in /usr/sbin/runuser /sbin/runuser /usr/bin/runuser /usr/local/sbin/runuser \
    /sbin/su-exec /usr/sbin/su-exec /usr/bin/su-exec /usr/local/sbin/su-exec; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_runtime_launcher() {
  runtime_launcher_path >/dev/null 2>&1 && return 0

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache su-exec >&2 || die "自动安装 su-exec 失败。"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      repair_dpkg_state || die "无法恢复 dpkg 软件包状态，无法安装 runuser。"
      apt-get update -y >&2 || die "更新 APT 软件包索引失败，无法安装 runuser。"
      apt-get install -y util-linux >&2 || die "自动安装 util-linux/runuser 失败。"
      ;;
    dnf)
      dnf install -y util-linux >&2 || die "自动安装 util-linux/runuser 失败。"
      ;;
    yum)
      yum install -y util-linux >&2 || die "自动安装 util-linux/runuser 失败。"
      ;;
    *)
      ;;
  esac

  runtime_launcher_path >/dev/null 2>&1 ||
    die "无法安装或找到 runuser/su-exec，无法以低权限运行 sing-box/Realm。请确认 /usr/sbin、/sbin 在 PATH 中，并手动安装 util-linux（Alpine 安装 su-exec）。"
}

run_as_runtime() {
  local launcher
  ensure_runtime_account
  ensure_runtime_launcher
  launcher="$(runtime_launcher_path)"

  case "${launcher##*/}" in
    runuser)
      "$launcher" -u "$RUNTIME_USER" -- "$@"
      ;;
    su-exec)
      "$launcher" "${RUNTIME_USER}:${RUNTIME_GROUP}" "$@"
      ;;
    *)
      die "无法识别低权限执行工具：$launcher"
      ;;
  esac
}

setcap_command_path() {
  local candidate
  candidate="$(command -v setcap 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in /usr/sbin/setcap /sbin/setcap /usr/bin/setcap /usr/local/sbin/setcap; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_setcap_command() {
  setcap_command_path >/dev/null 2>&1 && return 0

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache libcap-setcap >&2 || die "自动安装 libcap-setcap 失败。"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      repair_dpkg_state || die "无法恢复 dpkg 软件包状态，无法安装 setcap。"
      apt-get update -y >&2 || die "更新 APT 软件包索引失败，无法安装 setcap。"
      apt-get install -y libcap2-bin >&2 || die "自动安装 libcap2-bin/setcap 失败。"
      ;;
    dnf)
      dnf install -y libcap >&2 || die "自动安装 libcap/setcap 失败。"
      ;;
    yum)
      yum install -y libcap >&2 || die "自动安装 libcap/setcap 失败。"
      ;;
    *)
      ;;
  esac

  setcap_command_path >/dev/null 2>&1 ||
    die "无法安装或找到 setcap。Alpine 请安装 libcap-setcap，Debian/Ubuntu 请安装 libcap2-bin，RHEL 系列请安装 libcap。"
}

ensure_openrc_low_port_capability() {
  local binary_path=$1 label=$2 setcap_bin
  has_openrc && ! has_systemd || return 0
  [[ -x "$binary_path" ]] || return 0
  ensure_setcap_command
  setcap_bin="$(setcap_command_path)"
  "$setcap_bin" 'cap_net_bind_service=+ep' "$binary_path" ||
    die "无法为 ${label} 设置低端口监听能力，已拒绝回退为 root 运行。"
}

ui_pause() {
  if is_interactive; then
    printf '按回车键返回菜单...' >&2
    read -r _ || true
    printf '\n' >&2
  fi
  return 0
}

ui_msg() {
  local text=${1:-}
  printf '\n========================================\n' >&2
  printf '%s\n' "$APP_TITLE" >&2
  printf '========================================\n' >&2
  printf '%s\n\n' "$text" >&2
  ui_pause
  return 0
}

ui_show_text() {
  local title=${1:-$APP_TITLE}
  local text=${2:-}
  printf '\n========================================\n' >&2
  printf '%s\n' "$title" >&2
  printf '========================================\n' >&2
  printf '%s\n\n' "$text" >&2
  ui_pause
  return 0
}

ui_input_error_return() {
  printf '\n\033[31m连续输入错误两次，按 Enter 退回菜单界面。\033[0m' >&2
  if [[ -t 0 ]]; then
    read -r _ || true
  fi
  printf '\n' >&2
  return 0
}

ui_yesno() {
  local text=${1:-}
  local answer attempts=0

  while (( attempts < 2 )); do
    read -r -p "$text [y/N]: " answer || return 2
    case "$answer" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      ""|[Nn]|[Nn][Oo])
        return 1
        ;;
    esac

    attempts=$((attempts + 1))
    if (( attempts >= 2 )); then
      ui_input_error_return
      return 2
    fi
    printf '请输入 y 或 n，再次输错将退回菜单界面。\n' >&2
  done
}

ui_input() {
  local text=${2:-}
  local default_value=${3:-}
  local result=""

  read -r -p "$text [$default_value]: " result || return 1
  result=${result:-$default_value}

  printf '%s\n' "$result"
}

ui_password() {
  local text=${2:-}
  local result=""

  read -r -s -p "$text: " result || return 1
  printf '\n' >&2

  printf '%s\n' "$result"
}

ui_menu() {
  local title=$1
  local text=$2
  local choice option attempts=0
  local -a allowed_options=()
  local -a option_labels=()
  shift 2

  while (( $# >= 2 )); do
    allowed_options+=("$1")
    option_labels+=("$2")
    shift 2
  done

  printf '\n========================================\n' >&2
  printf '%s\n' "$title" >&2
  printf '========================================\n' >&2
  printf '%s\n' "$text" >&2
  for (( option = 0; option < ${#allowed_options[@]}; option++ )); do
    printf '  %s) %s\n' "${allowed_options[$option]}" "${option_labels[$option]}" >&2
  done

  while (( attempts < 2 )); do
    read -r -p "您要进行的操作是: " choice || return 1
    for option in "${allowed_options[@]}"; do
      if [[ "$choice" == "$option" ]]; then
        printf '%s\n' "$choice"
        return 0
      fi
    done

    attempts=$((attempts + 1))
    if (( attempts >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '输入的选项无效，再次输错将退回菜单界面。\n' >&2
  done
}

ui_protocol_menu() {
  ui_menu "$APP_TITLE" "请选择需要操作的协议" \
    "1" "Shadowsocks" \
    "2" "VLESS + Reality" \
    "3" "Hysteria2" \
    "0" "返回"
}

detect_pkg_manager() {
  if have_cmd apk; then
    PKG_MANAGER="apk"
  elif have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif have_cmd yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER=""
  fi
}

repair_dpkg_state() {
  local timeout="${SBOX_DPKG_LOCK_TIMEOUT:-180}"
  local retry_interval="${SBOX_DPKG_LOCK_RETRY_INTERVAL:-3}"
  local deadline output_file output lock_pid lock_process="" last_notice=-15

  have_cmd dpkg || return 0
  export DEBIAN_FRONTEND=noninteractive
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout >= 1 && timeout <= 3600 )) || timeout=180
  [[ "$retry_interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || retry_interval=3
  output_file="$(mktemp "$TMP_DIR/sbox-dpkg-repair.XXXXXX")" || return 1
  deadline=$((SECONDS + timeout))

  while true; do
    if dpkg --configure -a >"$output_file" 2>&1; then
      [[ ! -s "$output_file" ]] || command cat "$output_file" >&2
      rm -f "$output_file"
      return 0
    fi

    output="$(<"$output_file")"
    if ! grep -Eqi 'frontend lock.*(another process|held by process|locked)|could not get lock|unable to acquire.*lock|lock.*is another process using it' <<<"$output"; then
      [[ -z "$output" ]] || printf '%s\n' "$output" >&2
      rm -f "$output_file"
      ui_msg "dpkg 中断状态自动修复失败；错误并非软件包锁占用，请根据上方输出处理后重试。"
      return 1
    fi

    lock_pid="$(sed -nE 's/.*(pid|process)[[:space:]]+([0-9]+).*/\2/p' <<<"$output" | head -n 1)"
    lock_process=""
    if [[ "$lock_pid" =~ ^[0-9]+$ && -r "/proc/${lock_pid}/comm" ]]; then
      lock_process="$(tr -d '\r\n' <"/proc/${lock_pid}/comm")"
    fi

    if (( SECONDS >= deadline )); then
      rm -f "$output_file"
      if [[ -n "$lock_pid" ]]; then
        ui_msg "等待 APT/dpkg 释放软件包锁已超时（PID ${lock_pid}${lock_process:+，进程 ${lock_process}}）。脚本没有删除锁文件；请等待该进程正常结束后重试。"
      else
        ui_msg "等待 APT/dpkg 释放软件包锁已超时。脚本没有删除锁文件；请等待正在运行的软件包任务正常结束后重试。"
      fi
      return 1
    fi

    if (( SECONDS - last_notice >= 15 )); then
      if [[ -n "$lock_pid" ]]; then
        log "APT/dpkg 正由 PID ${lock_pid}${lock_process:+（${lock_process}）} 使用；等待其正常结束，最多 ${timeout} 秒……"
      else
        log "检测到 APT/dpkg 软件包锁；等待当前软件包任务正常结束，最多 ${timeout} 秒……"
      fi
      last_notice=$SECONDS
    fi
    sleep "$retry_interval"
  done
}

debian_os_value() {
  local key=$1

  [[ -r /etc/os-release ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = $2
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' /etc/os-release
}

disable_debian_list_sources() {
  local file tmp_file backup_file timestamp
  timestamp=$1

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$file" ]] || continue
    grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*(deb\.debian\.org/debian|security\.debian\.org|archive\.debian\.org/debian|ftp\.[^[:space:]]*debian\.org/debian)' "$file" || continue

    backup_file="/etc/apt/sbox-sources-backup/$(basename "$file").$timestamp"
    cp -p "$file" "$backup_file" || return 1
    tmp_file="$(mktemp "$TMP_DIR/sbox-sources.XXXXXX")" || return 1
    awk '
      /^[[:space:]]*deb(-src)?[[:space:]]/ &&
      $0 ~ /(deb\.debian\.org\/debian|security\.debian\.org|archive\.debian\.org\/debian|ftp\.[^[:space:]]*debian\.org\/debian)/ {
        print "# disabled by sbox Debian source normalization: " $0
        next
      }
      { print }
    ' "$file" >"$tmp_file" || {
      rm -f "$tmp_file"
      return 1
    }
    mv "$tmp_file" "$file" || {
      rm -f "$tmp_file"
      return 1
    }
  done
}

disable_debian_deb822_sources() {
  local file timestamp
  timestamp=$1

  for file in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/*debian*.sources; do
    [[ -f "$file" ]] || continue
    [[ "$(basename "$file")" == "sbox-debian.sources" ]] && continue
    grep -Eq 'URIs:[[:space:]].*(deb\.debian\.org/debian|security\.debian\.org|archive\.debian\.org/debian|ftp\.[^[:space:]]*debian\.org/debian)' "$file" || continue

    mv "$file" "/etc/apt/sbox-sources-backup/$(basename "$file").$timestamp" || return 1
  done
}

normalize_debian_apt_sources() {
  local os_id version_id version_major codename components timestamp
  local debian_uri security_uri security_suite suites managed_file

  [[ "${SBOX_SKIP_APT_SOURCE_FIX:-0}" == "1" ]] && return 0
  [[ -r /etc/os-release ]] || return 0

  os_id="$(debian_os_value ID || true)"
  version_id="$(debian_os_value VERSION_ID || true)"
  codename="$(debian_os_value VERSION_CODENAME || true)"
  version_major="${version_id%%.*}"

  [[ "$os_id" == "debian" ]] || return 0

  case "$version_major" in
    10)
      codename="${codename:-buster}"
      debian_uri="http://archive.debian.org/debian"
      security_uri="http://archive.debian.org/debian-security"
      security_suite="${codename}/updates"
      components="main contrib non-free"
      ;;
    11)
      codename="${codename:-bullseye}"
      debian_uri="http://archive.debian.org/debian"
      security_uri="http://security.debian.org/debian-security"
      security_suite="${codename}-security"
      components="main contrib non-free"
      ;;
    12)
      codename="${codename:-bookworm}"
      debian_uri="http://deb.debian.org/debian"
      security_uri="http://security.debian.org/debian-security"
      security_suite="${codename}-security"
      components="main contrib non-free non-free-firmware"
      ;;
    13)
      codename="${codename:-trixie}"
      debian_uri="http://deb.debian.org/debian"
      security_uri="http://security.debian.org/debian-security"
      security_suite="${codename}-security"
      components="main contrib non-free non-free-firmware"
      ;;
    *)
      return 0
      ;;
  esac

  mkdir -p /etc/apt/sources.list.d /etc/apt/apt.conf.d /etc/apt/sbox-sources-backup || return 1
  timestamp="$(date +%Y%m%d%H%M%S)"

  disable_debian_list_sources "$timestamp" || return 1
  disable_debian_deb822_sources "$timestamp" || return 1

  suites="$codename ${codename}-updates ${codename}-backports"
  managed_file="/etc/apt/sources.list.d/sbox-debian.sources"
  cat >"$managed_file" <<EOF || return 1
Types: deb
URIs: $debian_uri
Suites: $suites
Components: $components

Types: deb
URIs: $security_uri
Suites: $security_suite
Components: $components
EOF

  if [[ "$version_major" == "10" || "$version_major" == "11" ]]; then
    cat >/etc/apt/apt.conf.d/99sbox-debian-archive <<'EOF' || return 1
Acquire::Check-Valid-Until "false";
EOF
  else
    rm -f /etc/apt/apt.conf.d/99sbox-debian-archive 2>/dev/null || true
  fi
}

install_dependencies() {
  detect_pkg_manager

    case "$PKG_MANAGER" in
      apk)
      apk add --no-cache bash curl jq openssl ca-certificates tar gzip unzip openrc coreutils findutils iptables iptables-openrc iproute2 su-exec libcap-setcap
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      repair_dpkg_state || die "无法恢复 dpkg 软件包状态。"
      # Repair keyring directories left unreadable by this script's strict
      # umask before the first apt update (including upgrades/retries).
      install -d -m 0755 /etc/apt/keyrings || die "无法修复 APT 密钥目录权限。"
      normalize_debian_apt_sources || warn "Debian apt 源自动修复失败，将继续尝试 apt-get update。"
      apt-get update -y
      apt-get install -y curl jq openssl ca-certificates tar gzip unzip iproute2 iptables gnupg util-linux
      ;;
    dnf)
      dnf install -y curl jq openssl ca-certificates tar gzip unzip iproute iptables gnupg2 util-linux
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y curl jq openssl ca-certificates tar gzip unzip iproute iptables gnupg2 util-linux
      ;;
    *)
      die "暂不支持自动安装依赖，请手动安装 bash、curl、jq、openssl、ca-certificates、tar、gzip、unzip 后再运行。"
      ;;
  esac
}

alpine_release_branch() {
  local release_file="${ALPINE_RELEASE_FILE:-/etc/alpine-release}" version

  [[ -r "$release_file" ]] || return 1
  version="$(head -n 1 "$release_file" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.|$) ]]; then
    printf 'v%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

install_sing_box_apk_package() {
  local branch="" stable_repository=""

  if apk add --no-cache sing-box; then
    return 0
  fi

  # Minimal Alpine images commonly leave community disabled. Retry against
  # the matching official repository explicitly so apk still verifies the
  # package with Alpine's trusted signing keys.
  branch="$(alpine_release_branch || true)"
  if [[ -n "$branch" ]]; then
    stable_repository="https://dl-cdn.alpinelinux.org/alpine/${branch}/community"
    log "当前 Alpine 仓库未能安装 sing-box，尝试已签名的 ${branch}/community 软件包..."
    if apk add --no-cache --repository "$stable_repository" sing-box; then
      return 0
    fi
  fi

  # sing-box was added to Alpine after some still-used stable releases. The
  # edge package is self-contained apart from musl and remains signature-
  # checked by apk; this avoids downloading an unchecked upstream binary.
  log "当前 Alpine 版本未提供 sing-box，尝试已签名的 edge/community 软件包..."
  apk add --no-cache \
    --repository "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
    sing-box
}

install_sing_box_apt_repo() {
  local key_tmp key_fingerprint
  normalize_debian_apt_sources || warn "Debian apt 源自动修复失败，将继续尝试安装 sing-box。"
  # The script-wide umask is 077, while apt verifies repository signatures as
  # the unprivileged _apt user.  Make the directory traversable explicitly;
  # otherwise a newly created keyrings directory is 0700 and apt reports the
  # installed key as NO_PUBKEY.
  install -d -m 0755 /etc/apt/keyrings || return 1
  key_tmp="$(mktemp "$TMP_DIR/sagernet-key.XXXXXX")" || return 1
  curl -fsSL https://sing-box.app/gpg.key -o "$key_tmp" || {
    rm -f "$key_tmp"
    return 1
  }
  key_fingerprint="$(gpg --show-keys --with-colons "$key_tmp" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
  if [[ "$key_fingerprint" != "$SAGERNET_GPG_FINGERPRINT" ]]; then
    rm -f "$key_tmp"
    warn "SagerNet 软件源签名密钥指纹不匹配，已拒绝安装。"
    return 1
  fi
  install -m 0644 "$key_tmp" /etc/apt/keyrings/sagernet.asc || {
    rm -f "$key_tmp"
    return 1
  }
  rm -f "$key_tmp"
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF' || return 1
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

  export DEBIAN_FRONTEND=noninteractive
  repair_dpkg_state || return 1
  apt-get update -y || return 1
  apt-get install -y sing-box || return 1
}

install_sing_box_rpm_repo() {
  local manager=$1

  if [[ "$manager" == "dnf" ]]; then
    dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
    dnf config-manager addrepo --from-repofile=https://sing-box.app/sing-box.repo >/dev/null 2>&1 ||
      dnf config-manager --add-repo https://sing-box.app/sing-box.repo >/dev/null 2>&1 ||
      return 1
    dnf install -y sing-box || return 1
    return 0
  fi

  yum install -y yum-utils >/dev/null 2>&1 || true
  if have_cmd yum-config-manager; then
    yum-config-manager --add-repo https://sing-box.app/sing-box.repo >/dev/null 2>&1 || return 1
    yum install -y sing-box || return 1
    return 0
  fi

  return 1
}

install_sing_box() {
  local installed=0 version_text=""

  detect_pkg_manager
  log "安装官方原生 sing-box 软件包..."

  case "$PKG_MANAGER" in
    apk)
      if install_sing_box_apk_package; then
        installed=1
      fi
      ;;
    apt)
      if install_sing_box_apt_repo; then
        installed=1
      fi
      ;;
    dnf|yum)
      if install_sing_box_rpm_repo "$PKG_MANAGER"; then
        installed=1
      fi
      ;;
  esac

  if (( ! installed )); then
    die "sing-box 签名软件包安装失败（包管理器：${PKG_MANAGER}）。请检查上方软件源、网络或架构错误；为避免以 root 执行未校验的远程脚本或二进制，已拒绝不安全的后备安装。"
  fi

  hash -r 2>/dev/null || true
  have_cmd sing-box || die "安装完成后仍未找到 sing-box 命令。"
  ensure_sing_box_service
  enable_sing_box_service

  version_text="$(run_as_runtime sing-box version 2>/dev/null | head -n 1 || true)"
  log "sing-box 已安装：${version_text:-version unknown}"
}

xray_release_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64\n' ;;
    aarch64|arm64) printf 'arm64-v8a\n' ;;
    armv7l|armv7) printf 'arm32-v7a\n' ;;
    i386|i486|i586|i686) printf '32\n' ;;
    *) return 1 ;;
  esac
}

xray_version_text() {
  [[ -x "$XRAY_BIN" ]] || return 1
  "$XRAY_BIN" version 2>/dev/null | head -n 1
}

cleanup_xray_work_dir() {
  local work_dir=${1:-}
  [[ -n "$work_dir" ]] || return 0
  case "$work_dir" in
    "$TMP_DIR"/sbox-xray.*)
      rm -rf -- "$work_dir"
      ;;
    *)
      warn "拒绝清理不属于 Xray 安装流程的临时目录：$work_dir"
      return 1
      ;;
  esac
}

record_xray_runtime() {
  local version=$1 installed_at=${2:-} binary_sha256=${3:-}
  [[ -s "$STATE_FILE" ]] || return 0
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || return 1
  [[ -n "$installed_at" ]] || installed_at="$(state_get '.runtime.xray.installed_at // ""')"
  [[ -n "$installed_at" ]] || installed_at="$(utc_now)"
  [[ -n "$binary_sha256" ]] || binary_sha256="$(sha256_file "$XRAY_BIN" || true)"
  [[ "$binary_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  state_jq --arg version "$version" --arg installed_at "$installed_at" --arg binary_sha256 "$binary_sha256" '
    .runtime = (.runtime // {}) |
    .runtime.xray = {
      managed: true,
      version: $version,
      binary_sha256: $binary_sha256,
      installed_at: $installed_at
    }
  '
}

install_xray_core() {
  local arch asset_name api_file archive_file digest_file work_dir
  local tag asset_url digest_url expected_digest actual_digest version_line version recorded_digest

  [[ "$(sing_box_service_manager)" != "none" ]] || die "Xray 服务管理需要 systemd 或 OpenRC 环境。"
  if xray_service_exists && [[ ! -f "$XRAY_MANAGED_MARKER" && "$(state_get '.runtime.xray.managed // false' 2>/dev/null || true)" != "true" ]]; then
    die "检测到已有的 sbox-xray 服务但没有本脚本的托管记录。为避免覆盖用户服务，已拒绝安装。"
  fi
  if [[ ( -e "$XRAY_INSTALL_DIR" || -L "$XRAY_INSTALL_DIR" ) && ! -f "$XRAY_MANAGED_MARKER" && "$(state_get '.runtime.xray.managed // false' 2>/dev/null || true)" != "true" ]]; then
    die "Xray 隔离安装目录已存在但不属于本脚本：$XRAY_INSTALL_DIR。为避免覆盖用户文件，已拒绝安装。"
  fi

  if [[ -x "$XRAY_BIN" ]]; then
    if [[ ! -f "$XRAY_MANAGED_MARKER" && "$(state_get '.runtime.xray.managed // false' 2>/dev/null || true)" != "true" ]]; then
      die "检测到未被本脚本认领的 Xray 文件：$XRAY_BIN。为避免覆盖用户文件，已拒绝接管。"
    fi
    actual_digest="$(sha256_file "$XRAY_BIN" || true)"
    recorded_digest="$(state_get '.runtime.xray.binary_sha256 // ""' 2>/dev/null || true)"
    if [[ -n "$recorded_digest" && "$recorded_digest" != "$actual_digest" ]]; then
      die "脚本托管的 Xray 二进制摘要与安装记录不一致，已拒绝运行。请确认文件未被替换后再修复安装。"
    fi
    version_line="$(xray_version_text || true)"
    [[ -n "$version_line" ]] || die "脚本托管的 Xray 二进制无法运行：$XRAY_BIN"
    version="$(awk '{print $2; exit}' <<<"$version_line")"
    record_xray_runtime "${version:-unknown}" "" "$actual_digest" || die "无法记录 Xray 安装状态。"
    install -o root -g root -m 0644 /dev/null "$XRAY_MANAGED_MARKER"
    ensure_xray_service || die "无法创建或修复 Xray 服务。"
    log "Xray 已安装并保持当前版本：$version_line"
    return 0
  fi

  if ! have_cmd unzip; then
    detect_pkg_manager
    case "$PKG_MANAGER" in
      apk) apk add --no-cache unzip || die "安装 unzip 失败，无法安装 Xray。" ;;
      apt)
        export DEBIAN_FRONTEND=noninteractive
        repair_dpkg_state || die "无法恢复 dpkg 状态，无法安装 unzip。"
        if ! apt-get update -y || ! apt-get install -y unzip; then
          die "安装 unzip 失败，无法安装 Xray。"
        fi
        ;;
      dnf) dnf install -y unzip || die "安装 unzip 失败，无法安装 Xray。" ;;
      yum) yum install -y unzip || die "安装 unzip 失败，无法安装 Xray。" ;;
      *) die "缺少 unzip，无法安全解压 Xray 官方发布包。" ;;
    esac
  fi
  arch="$(xray_release_arch)" || die "Xray 自动安装暂不支持当前架构：$(uname -m)"
  asset_name="Xray-linux-${arch}.zip"
  api_file="$(mktemp "$TMP_DIR/sbox-xray-release.XXXXXX")" || die "无法创建 Xray 发布信息临时文件。"
  archive_file="$(mktemp "$TMP_DIR/sbox-xray-archive.XXXXXX")" || {
    rm -f "$api_file"
    die "无法创建 Xray 下载临时文件。"
  }
  digest_file="$(mktemp "$TMP_DIR/sbox-xray-digest.XXXXXX")" || {
    rm -f "$api_file" "$archive_file"
    die "无法创建 Xray 校验临时文件。"
  }
  work_dir="$(mktemp -d "$TMP_DIR/sbox-xray.XXXXXX")" || {
    rm -f "$api_file" "$archive_file" "$digest_file"
    die "无法创建 Xray 解压临时目录。"
  }

  log "获取 Xray 官方最新稳定版信息（不会选择 prerelease）..."
  download_to_file "$api_file" "https://api.github.com/repos/XTLS/Xray-core/releases/latest" || {
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "无法获取 Xray 官方稳定版信息。"
  }

  tag="$(jq -r 'select(.draft == false and .prerelease == false) | .tag_name // empty' "$api_file")"
  [[ "$tag" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || {
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布信息无效或不是稳定版，已拒绝安装。"
  }
  asset_url="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .browser_download_url' "$api_file" | head -n 1)"
  digest_url="$(jq -r --arg name "${asset_name}.dgst" '.assets[]? | select(.name == $name) | .browser_download_url' "$api_file" | head -n 1)"
  [[ "$asset_url" == "https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset_name}" ]] || {
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布包下载地址不符合预期，已拒绝安装。"
  }
  [[ "$digest_url" == "${asset_url}.dgst" ]] || {
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布包缺少官方摘要文件，已拒绝安装。"
  }

  log "下载 Xray ${tag} 官方发布包并校验 SHA-256..."
  if ! download_to_file "$archive_file" "$asset_url" || ! download_to_file "$digest_file" "$digest_url"; then
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布包或摘要文件下载失败。"
  fi
  expected_digest="$(awk -F '= ' '/256=/ {print tolower($2); exit}' "$digest_file" | tr -d '[:space:]')"
  actual_digest="$(sha256_file "$archive_file" || true)"
  if [[ ! "$expected_digest" =~ ^[0-9a-f]{64}$ || "$actual_digest" != "$expected_digest" ]]; then
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布包 SHA-256 校验失败，已拒绝安装。"
  fi

  if ! unzip -q "$archive_file" xray geoip.dat geosite.dat -d "$work_dir"; then
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 官方发布包解压失败。"
  fi
  if [[ ! -f "$work_dir/xray" || -L "$work_dir/xray" ||
    ! -f "$work_dir/geoip.dat" || -L "$work_dir/geoip.dat" ||
    ! -f "$work_dir/geosite.dat" || -L "$work_dir/geosite.dat" ]]; then
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "Xray 发布包不包含有效的核心或资源文件。"
  fi
  chmod 0755 "$work_dir/xray"
  version_line="$("$work_dir/xray" version 2>/dev/null | head -n 1 || true)"
  if [[ -z "$version_line" ]]; then
    rm -f "$api_file" "$archive_file" "$digest_file"
    cleanup_xray_work_dir "$work_dir"
    die "下载的 Xray 二进制自检失败，已拒绝安装。"
  fi

  install -d -m 0755 "$XRAY_INSTALL_DIR" "$XRAY_ASSET_DIR"
  install -o root -g root -m 0644 /dev/null "$XRAY_MANAGED_MARKER"
  install -o root -g root -m 0644 "$work_dir/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat"
  install -o root -g root -m 0644 "$work_dir/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat"
  # Install the executable last. Its presence is the completion marker used by
  # subsequent runs, so an interrupted asset copy is repaired by a new download.
  install -o root -g root -m 0755 "$work_dir/xray" "$XRAY_BIN"
  version="$(awk '{print $2; exit}' <<<"$version_line")"
  record_xray_runtime "${version:-$tag}" "$(utc_now)" "$(sha256_file "$XRAY_BIN")" || die "Xray 已安装，但无法记录版本状态。"

  rm -f "$api_file" "$archive_file" "$digest_file"
  cleanup_xray_work_dir "$work_dir"
  ensure_xray_service || die "Xray 已安装，但服务创建失败。"
  log "Xray 已按固定版本安装：$version_line"
}

has_systemd() {
  have_cmd systemctl && [[ -d /run/systemd/system ]]
}

xray_service_exists() {
  case "$(sing_box_service_manager)" in
    systemd)
      systemctl cat sbox-xray >/dev/null 2>&1 || [[ -f "$XRAY_SYSTEMD_SERVICE_FILE" ]]
      ;;
    openrc)
      [[ -x "$XRAY_OPENRC_SERVICE_FILE" ]]
      ;;
    *) return 1 ;;
  esac
}

ensure_xray_service() {
  local service_manager
  [[ -x "$XRAY_BIN" ]] || return 1
  ensure_runtime_account
  ensure_dirs
  service_manager="$(sing_box_service_manager)"
  [[ "$service_manager" != "none" ]] || return 1

  if [[ "$service_manager" == "systemd" ]]; then
    cat >"$XRAY_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=sbox managed Xray service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target sbox-firewall.service
Wants=network-online.target

[Service]
Type=simple
User=${RUNTIME_USER}
Group=${RUNTIME_GROUP}
UMask=0077
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    return 0
  fi

  ensure_openrc_low_port_capability "$XRAY_BIN" "Xray"
  cat >"$XRAY_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="sbox-xray"
description="sbox managed Xray service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG_FILE}"
command_user="${RUNTIME_USER}:${RUNTIME_GROUP}"
command_background="yes"
pidfile="/run/sbox-xray.pid"
output_log="${XRAY_OPENRC_LOG_FILE}"
error_log="${XRAY_OPENRC_LOG_FILE}"
export XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /run
  checkpath --file --owner "${RUNTIME_USER}:${RUNTIME_GROUP}" --mode 0640 "${XRAY_OPENRC_LOG_FILE}"
}
EOF
  chmod 0755 "$XRAY_OPENRC_SERVICE_FILE"
}

enable_xray_service() {
  case "$(sing_box_service_manager)" in
    systemd) systemctl enable sbox-xray >/dev/null 2>&1 || true ;;
    openrc) rc-update add sbox-xray default >/dev/null 2>&1 || true ;;
  esac
}

disable_xray_service() {
  case "$(sing_box_service_manager)" in
    systemd) systemctl disable sbox-xray >/dev/null 2>&1 || true ;;
    openrc) rc-update del sbox-xray default >/dev/null 2>&1 || true ;;
  esac
}

xray_service_active() {
  case "$(sing_box_service_manager)" in
    systemd) systemctl is-active sbox-xray 2>/dev/null ;;
    openrc)
      if rc-service sbox-xray status >/dev/null 2>&1; then printf 'active\n'; else printf 'inactive\n'; fi
      ;;
    *) printf 'unknown\n' ;;
  esac
}

xray_service_enabled() {
  case "$(sing_box_service_manager)" in
    systemd) systemctl is-enabled sbox-xray 2>/dev/null ;;
    openrc)
      if rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])sbox-xray([[:space:]]|$)'; then printf 'enabled\n'; else printf 'disabled\n'; fi
      ;;
    *) printf 'unknown\n' ;;
  esac
}

xray_recent_logs() {
  case "$(sing_box_service_manager)" in
    systemd) journalctl -u sbox-xray -n 30 --no-pager 2>/dev/null || true ;;
    openrc) tail -n 30 "$XRAY_OPENRC_LOG_FILE" 2>/dev/null || true ;;
  esac
}

restart_xray() {
  xray_service_exists || return 1
  enable_xray_service
  case "$(sing_box_service_manager)" in
    systemd) systemctl restart sbox-xray ;;
    openrc) rc-service sbox-xray restart >/dev/null 2>&1 || rc-service sbox-xray start >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

stop_xray() {
  xray_service_exists || return 0
  case "$(sing_box_service_manager)" in
    systemd) systemctl stop sbox-xray >/dev/null 2>&1 || true ;;
    openrc) rc-service sbox-xray stop >/dev/null 2>&1 || true ;;
  esac
}

has_openrc() {
  have_cmd rc-service && have_cmd rc-update
}

sing_box_service_manager() {
  if has_systemd; then
    printf 'systemd\n'
  elif has_openrc; then
    printf 'openrc\n'
  else
    printf 'none\n'
  fi
}

service_exists() {
  case "$(sing_box_service_manager)" in
    systemd)
      systemctl cat sing-box >/dev/null 2>&1 && return 0
      systemctl list-unit-files sing-box.service --no-legend 2>/dev/null | grep -q '^sing-box\.service' && return 0
      [[ -f /etc/systemd/system/sing-box.service || -f /lib/systemd/system/sing-box.service || -f /usr/lib/systemd/system/sing-box.service ]]
      ;;
    openrc)
      [[ -x "$SING_BOX_OPENRC_SERVICE_FILE" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

sing_box_service_exec_path() {
  local exec_line exec_path arg
  local -a exec_parts=()

  if has_openrc && ! has_systemd; then
    command -v sing-box
    return
  fi

  has_systemd || return 1
  exec_line="$(systemctl cat sing-box 2>/dev/null | awk -F= '/^[[:space:]]*ExecStart=/ {print $2; exit}')"
  [[ -n "$exec_line" ]] || return 1

  read -r -a exec_parts <<<"$exec_line"
  set -- "${exec_parts[@]}"
  exec_path=${1:-}
  exec_path="${exec_path#-}"
  exec_path="${exec_path#\"}"
  exec_path="${exec_path%\"}"

  if [[ "$exec_path" == "/usr/bin/env" || "$exec_path" == "/bin/env" ]]; then
    shift || true
    for arg in "$@"; do
      [[ "$arg" == *=* ]] && continue
      if [[ "$arg" == */sing-box ]]; then
        exec_path="$arg"
      else
        exec_path="$(command -v "$arg" 2>/dev/null || true)"
      fi
      break
    done
  fi

  [[ "$exec_path" == /* ]] || return 1

  printf '%s\n' "$exec_path"
}

sing_box_check_bin() {
  local service_bin cli_bin
  service_bin="$(sing_box_service_exec_path 2>/dev/null || true)"
  if [[ -n "$service_bin" && -x "$service_bin" ]]; then
    printf '%s\n' "$service_bin"
    return 0
  fi

  cli_bin="$(command -v sing-box 2>/dev/null || true)"
  if [[ -n "$cli_bin" && -x "$cli_bin" ]]; then
    printf '%s\n' "$cli_bin"
    return 0
  fi

  return 1
}

ensure_sing_box_service() {
  local sing_box_bin service_manager

  ensure_runtime_account
  service_manager="$(sing_box_service_manager)"
  [[ "$service_manager" != "none" ]] || return 0

  sing_box_bin="$(command -v sing-box 2>/dev/null || true)"
  [[ -n "$sing_box_bin" ]] || return 0

  if [[ "$service_manager" == "systemd" ]]; then
    if ! service_exists; then
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
    fi

    install -d -m 0755 "$SING_BOX_FIREWALL_DROPIN_DIR"
    cat >"$SING_BOX_HARDENING_DROPIN_FILE" <<EOF
[Service]
User=${RUNTIME_USER}
Group=${RUNTIME_GROUP}
UMask=0077
WorkingDirectory=/
ExecStart=
ExecStart=${sing_box_bin} run -c ${CONFIG_FILE}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=${RULE_SET_CACHE_DIR}
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  ensure_openrc_low_port_capability "$sing_box_bin" "sing-box"
  cat >"$SING_BOX_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="${sing_box_bin}"
command_args="run -c ${CONFIG_FILE}"
command_user="${RUNTIME_USER}:${RUNTIME_GROUP}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="${SING_BOX_OPENRC_LOG_FILE}"
error_log="${SING_BOX_OPENRC_LOG_FILE}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /run
  checkpath --file --owner "${RUNTIME_USER}:${RUNTIME_GROUP}" --mode 0640 "${SING_BOX_OPENRC_LOG_FILE}"
}
EOF
  chmod 755 "$SING_BOX_OPENRC_SERVICE_FILE"
}

repair_sing_box_netlink_hardening() {
  local active_state sub_state
  [[ "$(sing_box_service_manager)" == "systemd" ]] || return 0
  have_cmd sing-box || return 0

  if service_exists && grep -Eq '^RestrictAddressFamilies=.*AF_NETLINK([[:space:]]|$)' "$SING_BOX_HARDENING_DROPIN_FILE" 2>/dev/null; then
    return 0
  fi

  active_state="$(systemctl show sing-box -p ActiveState --value 2>/dev/null || true)"
  sub_state="$(systemctl show sing-box -p SubState --value 2>/dev/null || true)"
  ensure_sing_box_service || return 1

  if [[ "$active_state" == "failed" || "$sub_state" == auto-restart* ]]; then
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    if ! systemctl restart sing-box >/dev/null 2>&1 || ! verify_sing_box_service_ready; then
      warn "已修复 sing-box 的 AF_NETLINK 权限，但服务或监听端口尚未恢复，请查看 sing-box 日志。"
      return 1
    fi
  fi
}

enable_sing_box_service() {
  case "$(sing_box_service_manager)" in
    systemd)
      systemctl enable sing-box >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update add sing-box default >/dev/null 2>&1 || true
      ;;
  esac
}

disable_sing_box_service() {
  case "$(sing_box_service_manager)" in
    systemd) systemctl disable sing-box >/dev/null 2>&1 || true ;;
    openrc) rc-update del sing-box default >/dev/null 2>&1 || true ;;
  esac
}

sing_box_service_active() {
  case "$(sing_box_service_manager)" in
    systemd)
      systemctl is-active sing-box 2>/dev/null
      ;;
    openrc)
      if rc-service sing-box status >/dev/null 2>&1; then
        printf 'active\n'
      else
        printf 'inactive\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

sing_box_service_enabled() {
  case "$(sing_box_service_manager)" in
    systemd)
      systemctl is-enabled sing-box 2>/dev/null
      ;;
    openrc)
      if rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])sing-box([[:space:]]|$)'; then
        printf 'enabled\n'
      else
        printf 'disabled\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

sing_box_recent_logs() {
  case "$(sing_box_service_manager)" in
    systemd)
      journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
      ;;
    openrc)
      tail -n 30 "$SING_BOX_OPENRC_LOG_FILE" 2>/dev/null || true
      ;;
  esac
}

restart_sing_box() {
  if service_exists; then
    enable_sing_box_service
    case "$(sing_box_service_manager)" in
      systemd)
        systemctl restart sing-box || {
          ui_show_text "sing-box 启动失败" "$(sing_box_recent_logs)"
          return 1
        }
        ;;
      openrc)
        rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || {
          ui_show_text "sing-box 启动失败" "$(sing_box_recent_logs)"
          return 1
        }
        ;;
    esac
  else
    warn "未检测到可用的 sing-box 服务，请手动启动 sing-box。"
  fi
}

stop_sing_box() {
  if service_exists; then
    case "$(sing_box_service_manager)" in
      systemd)
        systemctl stop sing-box >/dev/null 2>&1 || true
        ;;
      openrc)
        rc-service sing-box stop >/dev/null 2>&1 || true
        ;;
    esac
  fi
}

realm_service_exists() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl cat realm >/dev/null 2>&1 && return 0
      systemctl list-unit-files realm.service --no-legend 2>/dev/null | grep -q '^realm\.service' && return 0
      [[ -f "$REALM_SERVICE_FILE" || -f /lib/systemd/system/realm.service || -f /usr/lib/systemd/system/realm.service ]]
      ;;
    openrc)
      [[ -x "$REALM_OPENRC_SERVICE_FILE" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

realm_service_manager() {
  if has_systemd; then
    printf 'systemd\n'
  elif has_openrc; then
    printf 'openrc\n'
  else
    printf 'none\n'
  fi
}

ensure_realm_service() {
  local service_manager interface wg_systemd_units="" wg_openrc_services=""
  ensure_runtime_account
  service_manager="$(realm_service_manager)"
  [[ "$service_manager" != "none" ]] || return 0

  if [[ -s "$REALM_STATE_FILE" ]] && jq -e . "$REALM_STATE_FILE" >/dev/null 2>&1; then
    while IFS= read -r interface; do
      wireguard_valid_interface "$interface" || continue
      wg_systemd_units+=" wg-quick@${interface}.service"
      wg_openrc_services+=" $(wireguard_service_name "$interface")"
    done < <(jq -r '
      [.rules[]? | select(.mode == "wireguard") | .tunnel_id] as $ids |
      .wireguard.profiles[]? | select(.enabled == true) | select(.id as $id | $ids | index($id)) | .interface
    ' "$REALM_STATE_FILE" | sort -u)
  fi

  if [[ "$service_manager" == "systemd" ]]; then
    cat >"$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=Realm relay service
Documentation=https://github.com/zhboner/realm
After=network-online.target nss-lookup.target${wg_systemd_units}
Wants=network-online.target${wg_systemd_units}

[Service]
Type=simple
User=${RUNTIME_USER}
Group=${RUNTIME_GROUP}
UMask=0077
ExecStart=${REALM_BIN} -c ${REALM_CONFIG_FILE}
Restart=always
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  ensure_openrc_low_port_capability "$REALM_BIN" "Realm"
  cat >"$REALM_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="realm"
description="Realm relay service"
command="${REALM_BIN}"
command_args="-c ${REALM_CONFIG_FILE}"
command_user="${RUNTIME_USER}:${RUNTIME_GROUP}"
command_background="yes"
pidfile="/run/realm.pid"
output_log="${REALM_OPENRC_LOG_FILE}"
error_log="${REALM_OPENRC_LOG_FILE}"

depend() {
  need net${wg_openrc_services}
  after firewall${wg_openrc_services}
}

start_pre() {
  checkpath --directory --mode 0755 /run
  checkpath --file --owner "${RUNTIME_USER}:${RUNTIME_GROUP}" --mode 0640 "${REALM_OPENRC_LOG_FILE}"
}
EOF
  chmod 755 "$REALM_OPENRC_SERVICE_FILE"
}

enable_realm_service() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl enable realm >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update add realm default >/dev/null 2>&1 || true
      ;;
  esac
}

disable_realm_service() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl disable realm >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del realm default >/dev/null 2>&1 || true
      ;;
  esac
}

realm_service_active() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl is-active realm 2>/dev/null
      ;;
    openrc)
      if rc-service realm status >/dev/null 2>&1; then
        printf 'active\n'
      else
        printf 'inactive\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

realm_recent_logs() {
  case "$(realm_service_manager)" in
    systemd)
      journalctl -u realm -n 30 --no-pager 2>/dev/null || true
      ;;
    openrc)
      tail -n 30 "$REALM_OPENRC_LOG_FILE" 2>/dev/null || true
      ;;
  esac
}

start_realm_service_raw() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl start realm
      ;;
    openrc)
      rc-service realm start
      ;;
    *)
      return 1
      ;;
  esac
}

stop_realm_service_raw() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl stop realm
      ;;
    openrc)
      rc-service realm stop
      ;;
    *)
      return 1
      ;;
  esac
}

restart_realm_service_raw() {
  case "$(realm_service_manager)" in
    systemd)
      systemctl restart realm
      ;;
    openrc)
      rc-service realm restart || rc-service realm start
      ;;
    *)
      return 1
      ;;
  esac
}

detect_realm_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64-unknown-linux-musl\n'
      ;;
    aarch64|arm64)
      printf 'aarch64-unknown-linux-musl\n'
      ;;
    armv7l|armv7)
      printf 'armv7-unknown-linux-musleabihf\n'
      ;;
    *)
      return 1
      ;;
  esac
}

install_realm_binary() {
  local arch tmp_dir archive_path extracted_bin release_json asset_name asset_url expected_digest actual_digest version_output
  arch="$(detect_realm_arch)" || die "当前架构暂不支持自动安装 Realm：$(uname -m)"
  ensure_runtime_account
  tmp_dir="$(mktemp -d "$TMP_DIR/realm-install.XXXXXX")" || return 1
  archive_path="$tmp_dir/realm.tar.gz"
  release_json="$tmp_dir/release.json"
  asset_name="realm-${arch}.tar.gz"

  if ! download_to_file "$release_json" "https://api.github.com/repos/zhboner/realm/releases/latest"; then
    rm -rf "$tmp_dir"
    die "读取 Realm 官方发布元数据失败，请稍后重试。"
  fi
  asset_url="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .browser_download_url // empty' "$release_json" | head -n 1)"
  expected_digest="$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .digest // empty' "$release_json" | head -n 1)"
  expected_digest="${expected_digest#sha256:}"
  [[ -n "$asset_url" && "$expected_digest" =~ ^[A-Fa-f0-9]{64}$ ]] || {
    rm -rf "$tmp_dir"
    die "Realm 官方发布未提供可用的 SHA-256 摘要，已拒绝安装。"
  }
  download_to_file "$archive_path" "$asset_url" || {
    rm -rf "$tmp_dir"
    die "下载 Realm 失败，请稍后重试。"
  }
  actual_digest="$(sha256_file "$archive_path")"
  [[ "$actual_digest" == "${expected_digest,,}" ]] || {
    rm -rf "$tmp_dir"
    die "Realm 下载包 SHA-256 校验失败，已拒绝安装。"
  }

  chown -R "$RUNTIME_USER":"$RUNTIME_GROUP" "$tmp_dir"

  if ! run_as_runtime tar -xzf "$archive_path" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  extracted_bin="$(find "$tmp_dir" -type f -name realm | head -n 1)"
  [[ -n "$extracted_bin" && -f "$extracted_bin" && ! -L "$extracted_bin" ]] || {
    rm -rf "$tmp_dir"
    die "无法从下载包中找到 realm 可执行文件。"
  }
  chmod 0755 "$extracted_bin" || {
    rm -rf "$tmp_dir"
    die "无法设置 Realm 临时二进制权限。"
  }
  if ! version_output="$(run_as_runtime "$extracted_bin" --version 2>&1)"; then
    rm -rf "$tmp_dir"
    die "Realm 官方 ${arch} 二进制与当前系统不兼容，已拒绝安装：${version_output:-无法执行}"
  fi

  install -m 755 "$extracted_bin" "$REALM_BIN"
  rm -rf "$tmp_dir"
  log "Realm 已安装：${version_output}（${arch}）"
}

repair_realm_binary_compatibility() {
  local output=""

  [[ -x "$REALM_BIN" ]] || return 0
  if output="$(run_as_runtime "$REALM_BIN" --version 2>&1)"; then
    return 0
  fi

  if ! grep -Eqi 'GLIBC_[0-9.]+.*not found|required file not found|No such file or directory|Exec format error' <<<"$output"; then
    warn "Realm 二进制自检失败，未自动覆盖现有文件：${output:-未知错误}"
    return 1
  fi

  warn "检测到 Realm 二进制与当前 libc/架构不兼容，正在安装经 SHA-256 校验的便携 musl 构建。"
  install_realm_binary
}

detect_public_ipv4() {
  local addr="" candidate

  if have_cmd curl; then
    addr="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    addr="${addr//$'\r'/}"
    addr="${addr//$'\n'/}"
    if is_ipv4 "$addr"; then
      printf '%s\n' "$addr"
      return 0
    fi
  fi

  if have_cmd hostname; then
    while IFS= read -r candidate; do
      if is_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(hostname -I 2>/dev/null | tr '[:space:]' '\n')
  fi

  return 1
}

is_public_ipv6_candidate() {
  local addr=${1,,}
  is_valid_ipv6_or_cidr "$addr" || return 1
  [[ "$addr" != */* ]] || return 1

  case "$addr" in
    ::|::1|fe8*|fe9*|fea*|feb*|fec*|fed*|fee*|fef*|fc*|fd*|ff*|2001:db8:*)
      return 1
      ;;
  esac

  return 0
}

detect_public_ipv6() {
  local addr="" candidate

  if have_cmd curl; then
    addr="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    addr="${addr//$'\r'/}"
    addr="${addr//$'\n'/}"
    if is_public_ipv6_candidate "$addr"; then
      printf '%s\n' "$addr"
      return 0
    fi
  fi

  if have_cmd hostname; then
    while IFS= read -r candidate; do
      if is_public_ipv6_candidate "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(hostname -I 2>/dev/null | tr '[:space:]' '\n')
  fi

  return 1
}

detect_public_address() {
  local addr=""

  addr="$(detect_public_ipv4 2>/dev/null || true)"
  [[ -n "$addr" ]] || addr="$(detect_public_ipv6 2>/dev/null || true)"
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

generate_random_service_port() {
  printf '%s\n' "$((10000 + ((RANDOM * 32768 + RANDOM) % 50001)))"
}

generate_random_service_port_excluding() {
  local excluded_port=${1:-}
  local port
  port="$(generate_random_service_port)"
  while [[ -n "$excluded_port" && "$port" == "$excluded_port" ]]; do
    port="$(generate_random_service_port)"
  done
  printf '%s\n' "$port"
}

generate_base64_bytes() {
  local length=${1:-32}
  if have_cmd sing-box; then
    run_as_runtime sing-box generate rand --base64 "$length" | tr -d '\n'
  else
    openssl rand -base64 "$length" | tr -d '\n'
  fi
}

generate_reality_keypair() {
  local core=${1:-sing-box} output private_key public_key
  case "$core" in
    xray)
      [[ -x "$XRAY_BIN" ]] || die "Xray 尚未安装，无法生成 Reality 密钥对。"
      output="$(run_as_runtime "$XRAY_BIN" x25519 2>/dev/null || true)"
      private_key="$(printf '%s\n' "$output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
      public_key="$(printf '%s\n' "$output" | awk -F': ' '/PublicKey|Password/ {print $2; exit}')"
      ;;
    sing-box)
      output="$(run_as_runtime sing-box generate reality-keypair 2>/dev/null || true)"
      private_key="$(printf '%s\n' "$output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
      public_key="$(printf '%s\n' "$output" | awk -F': ' '/PublicKey/ {print $2; exit}')"
      ;;
    *) die "未知的 Reality 内核：$core" ;;
  esac

  [[ -n "$private_key" && -n "$public_key" ]] || die "无法使用 ${core} 生成 Reality 密钥对。"

  printf '%s\t%s\n' "$private_key" "$public_key"
}

backup_config_if_exists() {
  if [[ -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$CONFIG_FILE" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
  fi
}

init_state_file() {
  if [[ -s "$STATE_FILE" ]]; then
    migrate_state_schema
    migrate_realm_tcp_only
    migrate_realm_wireguard_schema
    repair_sing_box_netlink_hardening
    return 0
  fi

  local now ss_default_port vless_default_port
  now="$(utc_now)"
  ss_default_port="$(generate_random_service_port)"
  vless_default_port="$(generate_random_service_port_excluding "$ss_default_port")"

  cat >"$STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "node_name": "",
    "server_address": "",
    "server_address_ipv6": "",
    "dual_stack": false,
    "outbound_ip_preference": "auto",
    "created_at": "$now",
    "updated_at": "$now",
    "log_level": "info"
  },
  "protocols": {
    "shadowsocks": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": $ss_default_port,
    "network": "tcp",
    "method": "2022-blake3-aes-128-gcm",
    "server_password": "",
    "multiplex": true,
    "users": []
    },
    "vless_reality": {
      "enabled": false,
      "core": "sing-box",
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
    "split": {
      "legacy_defaults_removed": true,
      "outbounds": []
    }
  },
  "runtime": {
    "xray": {
      "managed": false,
      "version": "",
      "binary_sha256": "",
      "installed_at": ""
    }
  }
}
EOF

  chmod 0600 "$STATE_FILE"

  migrate_realm_tcp_only
  migrate_realm_wireguard_schema
  repair_sing_box_netlink_hardening
}

state_get() {
  jq -r "$@" "$STATE_FILE"
}

state_jq() {
  local tmp_file
  tmp_file="$(mktemp "$TMP_DIR/singbox-state.XXXXXX")"
  jq "$@" "$STATE_FILE" >"$tmp_file"
  install -m 0600 "$tmp_file" "$STATE_FILE"
  rm -f "$tmp_file"
}

snapshot_sing_box_state_file() {
  local snapshot_file
  snapshot_file="$(mktemp "$TMP_DIR/singbox-state-backup.XXXXXX")" || return 1
  install -m 0600 "$STATE_FILE" "$snapshot_file" || {
    rm -f "$snapshot_file"
    return 1
  }
  printf '%s\n' "$snapshot_file"
}

apply_sing_box_state_transaction() {
  local previous_state_file=$1
  local description=${2:-配置变更}
  local state_restored=true runtime_restored=true

  if apply_config; then
    rm -f "$previous_state_file"
    return 0
  fi

  install -m 0600 "$previous_state_file" "$STATE_FILE" || state_restored=false
  if [[ "$state_restored" == "true" ]]; then
    apply_config || runtime_restored=false
  else
    runtime_restored=false
  fi
  rm -f "$previous_state_file"

  if [[ "$state_restored" == "true" && "$runtime_restored" == "true" ]]; then
    ui_msg "${description}应用失败，已自动恢复原状态和运行配置。"
  elif [[ "$state_restored" == "true" ]]; then
    ui_msg "${description}应用失败；状态文件已恢复，但运行配置未能自动恢复，请执行 sbox repair-install。"
  else
    ui_msg "${description}应用失败且状态恢复失败，请立即检查 ${STATE_FILE} 和 sing-box 服务。"
  fi
  return 1
}

cleanup_removed_traffic_state() {
  state_jq --arg version "$SCRIPT_VERSION" --arg ts "$(utc_now)" '
    def cleanup_users:
      map(del(.traffic_limit_gb, .traffic_used_bytes, .traffic_last_api_bytes, .expires_at));
    del(.traffic_stats) |
    .meta = (.meta // {}) |
    .meta.server_address_ipv6 = (.meta.server_address_ipv6 // "") |
    .meta.dual_stack = (.meta.dual_stack // false) |
    .meta.outbound_ip_preference = (.meta.outbound_ip_preference // "auto") |
    .protocols.vless_reality.core = (.protocols.vless_reality.core // "sing-box") |
    .runtime = (if ((.runtime // {}) | type) == "object" then .runtime else {} end) |
    .runtime.xray = (if ((.runtime.xray // {}) | type) == "object" then .runtime.xray else {managed: false, version: "", binary_sha256: "", installed_at: ""} end) |
    .runtime.xray.managed = (.runtime.xray.managed // false) |
    .runtime.xray.version = (.runtime.xray.version // "") |
    .runtime.xray.binary_sha256 = (.runtime.xray.binary_sha256 // "") |
    .runtime.xray.installed_at = (.runtime.xray.installed_at // "") |
    del(.protocols.shadowsocks.allowed_sources) |
    .protocols.shadowsocks.users = ((.protocols.shadowsocks.users // []) | cleanup_users) |
    .protocols.vless_reality.users = ((.protocols.vless_reality.users // []) | cleanup_users) |
    .protocols.hysteria2.users = ((.protocols.hysteria2.users // []) | cleanup_users) |
    .meta.version = $version |
    .meta.updated_at = $ts
  '
}

migrate_state_schema() {
  if jq -e '
    (.routing.split.legacy_defaults_removed? == true)
    and (.routing.split.outbounds? | type == "array")
  ' "$STATE_FILE" >/dev/null 2>&1; then
    cleanup_removed_traffic_state
    return 0
  fi

  state_jq --arg ts "$(utc_now)" '
    def legacy_default_rules_v1:
      [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
        "anthropic.com", "claude.ai", "perplexity.ai", "poe.com",
        "gemini.google.com", "openai", "chatgpt", "gpt", "anthropic",
        "claude", "perplexity", "gemini"
      ];
    def legacy_default_rules_v2:
      [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
        "anthropic.com", "claude.ai", "perplexity.ai", "poe.com", "sora.com",
        "x.ai", "grok.com", "deepseek.com", "deepseek.ai", "google.com",
        "googleapis.com", "gstatic.com", "googleusercontent.com", "ggpht.com",
        "generativelanguage.googleapis.com", "aistudio.google.com",
        "gemini.google.com", "openai", "chatgpt", "gpt", "anthropic",
        "claude", "perplexity", "gemini"
      ];
    def clean_rules:
      map(select(type == "string") | ascii_downcase)
      | unique
      | . as $rules
      | ($rules | map(ltrimstr("domain:")) | sort) as $canonical_rules
      | if ($canonical_rules == (legacy_default_rules_v1 | sort))
          or ($canonical_rules == (legacy_default_rules_v2 | sort)) then
          []
        else
          $rules
        end;
    def normalize_method:
      if . == "plain" then "none"
      elif . == "chacha20-poly1305" then "chacha20-ietf-poly1305"
      elif . == "xchacha20-poly1305" then "xchacha20-ietf-poly1305"
      else . end;
    def legacy_split:
      {
        id: "default",
        name: "default",
        enabled: (
          (.enabled // false)
          and (((.rule_sets // []) | clean_rules | length) > 0)
        ),
        outbound_type: (.outbound_type // "socks"),
        server: (.server // ""),
        port: (.port // 1080),
        username: (.username // ""),
        password: (.password // ""),
        method: ((.method // "2022-blake3-aes-128-gcm") | normalize_method),
        rule_sets: ((.rule_sets // []) | clean_rules)
      };
    def legacy_ai:
      {
        id: "default",
        name: "default",
        enabled: false,
        outbound_type: (
          if (.outbound_type // "") == "shadowsocks" then "shadowsocks"
          else "socks" end
        ),
        server: (.server // ""),
        port: (.port // 1080),
        username: "",
        password: (
          if (.outbound_type // "") == "shadowsocks" then (.password // "")
          else "" end
        ),
        method: ((.method // "2022-blake3-aes-128-gcm") | normalize_method),
        rule_sets: (
          (
            ((.domain_suffix // []) | map(select(type == "string") | "domain:" + ascii_downcase))
            + ((.domain_keyword // []) | map(select(type == "string") | ascii_downcase))
          ) | clean_rules
        )
      };
    .routing = (.routing // {}) |
    (.routing.split // {}) as $split |
    .routing.split = {
      legacy_defaults_removed: true,
      outbounds: (
        if ($split.outbounds? | type) == "array" then
          $split.outbounds
        elif ($split.server // "") != "" or (($split.rule_sets // []) | length) > 0 then
          [$split | legacy_split]
        elif (.routing.ai? != null) then
          [.routing.ai | legacy_ai]
        else
          []
        end
      )
    } |
    del(.routing.ai) |
    .meta.updated_at = $ts
  '

  cleanup_removed_traffic_state
}

format_split_rule_list() {
  jq -r '
    [.routing.split.outbounds[]?.rule_sets[]?]
    | unique
    | map(
        if startswith("domain:") then
          (ltrimstr("domain:") + "（网址）")
        elif startswith("geosite:") then
          (ltrimstr("geosite:") + "（GeoSite）")
        elif startswith("srs:") then
          (ltrimstr("srs:") + "（远程 SRS）")
        else
          .
        end
      )
    | join(", ")
  ' "$STATE_FILE"
}

build_split_rules_json() {
  local input=$1
  jq -nc --arg input "$input" '
    ($input | ascii_downcase)
    | gsub("，|、|；"; ",")
    | gsub("[,;[:space:]]+"; ",")
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(test("^[a-z0-9][a-z0-9._-]*$")))
    | unique
  '
}

build_split_domains_json() {
  local input=$1
  jq -nc --arg input "$input" '
    ($input | ascii_downcase)
    | gsub("，|、|；"; ",")
    | gsub("[,;[:space:]]+"; ",")
    | split(",")
    | map(
        gsub("^\\s+|\\s+$"; "")
        | sub("^https?://"; "")
        | sub("^//"; "")
        | split("/")[0]
        | split("?")[0]
        | split("#")[0]
        | sub("^.*@"; "")
        | sub(":[0-9]+$"; "")
        | sub("^www\\."; "")
        | sub("\\.$"; "")
      )
    | map(select(
        (split(".") | length) >= 2
        and (split(".")[-1] | test("[a-z]"))
        and all(split(".")[];
          test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
          and (length <= 63)
        )
      ))
    | map("domain:" + .)
    | unique
  '
}

build_split_geosite_json() {
  local input=$1
  jq -nc --arg input "$input" '
    ($input | ascii_downcase)
    | gsub("，|、|；"; ",")
    | gsub("[,;[:space:]]+"; ",")
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(test("^[a-z0-9][a-z0-9._@!+\\-]*$")))
    | map("geosite:" + .)
    | unique
  '
}

build_split_srs_json() {
  local input=$1
  jq -nc --arg input "$input" '
    $input
    | gsub("，|、|；"; ",")
    | gsub("[,;[:space:]]+"; ",")
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(test("^https://[^[:space:],]+\\.srs([?#][^[:space:],]*)?$")))
    | map("srs:" + .)
    | unique
  '
}

normalize_shadowsocks_method() {
  case "$1" in
    chacha20-poly1305)
      printf 'chacha20-ietf-poly1305\n'
      ;;
    xchacha20-poly1305)
      printf 'xchacha20-ietf-poly1305\n'
      ;;
    plain)
      printf 'none\n'
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

is_supported_shadowsocks_method() {
  case "$(normalize_shadowsocks_method "$1")" in
    aes-256-gcm|aes-128-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|none|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_supported_split_shadowsocks_method() {
  is_supported_shadowsocks_method "$1"
}

is_shadowsocks_2022_method() {
  case "$(normalize_shadowsocks_method "$1")" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

shadowsocks_2022_key_bytes() {
  case "$(normalize_shadowsocks_method "$1")" in
    2022-blake3-aes-128-gcm)
      printf '16\n'
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      printf '32\n'
      ;;
    *)
      printf '0\n'
      ;;
  esac
}

generate_shadowsocks_password() {
  local method=$1 key_bytes
  key_bytes="$(shadowsocks_2022_key_bytes "$method")"

  if [[ "$key_bytes" -gt 0 ]]; then
    generate_base64_bytes "$key_bytes"
  else
    generate_password
  fi
}

shadowsocks_share_password() {
  local method=$1 server_password=$2 user_password=$3

  if is_shadowsocks_2022_method "$method"; then
    printf '%s:%s\n' "$server_password" "$user_password"
  else
    printf '%s\n' "$user_password"
  fi
}

select_shadowsocks_method() {
  local current_method=${1:-2022-blake3-aes-128-gcm}
  local method_choice method

  method_choice="$(ui_split_shadowsocks_method_menu "$current_method")" || return 1
  case "$method_choice" in
    1) method="2022-blake3-aes-128-gcm" ;;
    2) method="2022-blake3-aes-256-gcm" ;;
    3) method="2022-blake3-chacha20-poly1305" ;;
    0) return 1 ;;
    *) ui_msg "Invalid Shadowsocks method."; return 1 ;;
  esac

  normalize_shadowsocks_method "$method"
}

ui_split_shadowsocks_method_menu() {
  local current_method=${1:-2022-blake3-aes-128-gcm}
  ui_menu "Shadowsocks 加密方式" "公网节点仅允许 SS2022。当前：${current_method}" \
    "1" "2022-blake3-aes-128-gcm" \
    "2" "2022-blake3-aes-256-gcm" \
    "3" "2022-blake3-chacha20-poly1305" \
    "0" "返回"
}

init_realm_state_file() {
  if [[ -s "$REALM_STATE_FILE" ]]; then
    migrate_realm_tcp_only
    migrate_realm_wireguard_schema
    return 0
  fi

  local now
  now="$(utc_now)"

  cat >"$REALM_STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "updated_at": "$now",
    "realm_tcp_only_migrated": true
  },
  "global": {
    "log_level": "warn",
    "log_output": "stdout",
    "use_udp": false,
    "no_tcp": false
  },
  "wireguard": {
    "profiles": []
  },
  "rules": []
}
EOF

  chmod 0600 "$REALM_STATE_FILE"
  migrate_realm_wireguard_schema
}

realm_state_get() {
  jq -r "$1" "$REALM_STATE_FILE"
}

realm_state_jq() {
  local tmp_file
  tmp_file="$(mktemp "$TMP_DIR/realm-state.XXXXXX")" || return 1
  if ! jq "$@" "$REALM_STATE_FILE" >"$tmp_file" ||
    ! install -m 0600 "$tmp_file" "$REALM_STATE_FILE"; then
    rm -f "$tmp_file"
    return 1
  fi
  rm -f "$tmp_file"
}

migrate_realm_wireguard_schema() {
  [[ -s "$REALM_STATE_FILE" ]] || return 0
  jq -e . "$REALM_STATE_FILE" >/dev/null 2>&1 || return 1

  if jq -e '
    (.wireguard.profiles? | type == "array")
    and ([.rules[]? | has("mode")] | all)
    and (.meta.realm_wireguard_schema? == 1)
  ' "$REALM_STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  realm_state_jq --arg version "$SCRIPT_VERSION" --arg ts "$(utc_now)" '
    .wireguard = (.wireguard // {}) |
    .wireguard.profiles = ((.wireguard.profiles // []) | map(select(type == "object"))) |
    .rules = ((.rules // []) | map(
      .mode = (if .mode == "wireguard" then "wireguard" else "direct" end) |
      .tunnel_id = (if .mode == "wireguard" then (.tunnel_id // null) else null end)
    )) |
    .meta = (.meta // {}) |
    .meta.realm_wireguard_schema = 1 |
    .meta.version = $version |
    .meta.updated_at = $ts
  '
}

snapshot_realm_state_file() {
  local snapshot_file
  snapshot_file="$(mktemp "$TMP_DIR/realm-state-backup.XXXXXX")" || return 1
  if ! install -m 0600 "$REALM_STATE_FILE" "$snapshot_file"; then
    rm -f "$snapshot_file"
    return 1
  fi
  printf '%s\n' "$snapshot_file"
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

default_listen_address() {
  local server_address dual_stack
  server_address="$(state_get '.meta.server_address' 2>/dev/null || true)"
  dual_stack="$(state_get '.meta.dual_stack // false' 2>/dev/null || true)"

  if [[ "$dual_stack" == "true" ]] ||
    { [[ -n "$server_address" && "$server_address" != "null" ]] && is_ipv6 "$server_address"; }; then
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

prompt_node_name_for_protocol() {
  local desired
  desired="$(prompt_nonempty "节点名称" "请输入该协议在客户端中显示的节点名称" "")" || return 1

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

prompt_nonempty() {
  local title=$1
  local text=$2
  local default_value=${3:-}
  local value=""
  local attempts=0

  while (( attempts < 2 )); do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi

    attempts=$((attempts + 1))
    if (( attempts >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '输入不能为空，再次输错将退回菜单界面。\n' >&2
  done
}

prompt_number() {
  local title=$1
  local text=$2
  local default_value=$3
  local min_value=$4
  local max_value=$5
  local value=""
  local attempts=0

  while (( attempts < 2 )); do
    value="$(ui_input "$title" "$text" "$default_value")" || return 1
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min_value && value <= max_value )); then
      printf '%s\n' "$value"
      return 0
    fi

    attempts=$((attempts + 1))
    if (( attempts >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '请输入 %s-%s 范围内的数字，再次输错将退回菜单界面。\n' "$min_value" "$max_value" >&2
  done
}

is_valid_ipv4_or_cidr() {
  local value=$1 address prefix octet
  local -a octets=()

  address="${value%%/*}"
  prefix=""
  if [[ "$value" == */* ]]; then
    prefix="${value#*/}"
    [[ -n "$prefix" && "$prefix" =~ ^[0-9]+$ && ${#prefix} -le 3 ]] || return 1
    (( 10#$prefix <= 32 )) || return 1
  fi
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$address"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

is_valid_ipv6_or_cidr() {
  local value=$1 address prefix
  address="${value%%/*}"
  prefix=""
  if [[ "$value" == */* ]]; then
    prefix="${value#*/}"
    [[ -n "$prefix" && "$prefix" =~ ^[0-9]+$ && ${#prefix} -le 3 ]] || return 1
    (( 10#$prefix <= 128 )) || return 1
  fi
  [[ "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  return 0
}

is_valid_ip_or_cidr() {
  is_valid_ipv4_or_cidr "$1" || is_valid_ipv6_or_cidr "$1"
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
      ui_input_error_return
      return 1
    fi

    printf '输入不能为空，再次输错将退回菜单界面。\n' >&2
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
      ui_input_error_return
      return 1
    fi

    printf '请输入 %s-%s 范围内的数字，再次输错将退回菜单界面。\n' "$min_value" "$max_value" >&2
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

reset_ss_user_passwords_for_method() {
  local method=$1 users_json='[]' name password

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    password="$(generate_shadowsocks_password "$method")"
    users_json="$(jq -c --arg name "$name" --arg password "$password" \
      '. + [{name: $name, password: $password}]' <<<"$users_json")"
  done < <(jq -r '.protocols.shadowsocks.users[]?.name' "$STATE_FILE")

  state_jq --argjson users "$users_json" --arg ts "$(utc_now)" \
    '.protocols.shadowsocks.users = $users | .meta.updated_at = $ts'
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
    chown root:"$RUNTIME_GROUP" "$cert_path" "$key_path"
    chmod 0640 "$cert_path" "$key_path"
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

  chown root:"$RUNTIME_GROUP" "$cert_path" "$key_path"
  chmod 0640 "$cert_path" "$key_path"
  rm -f "$openssl_conf"
}

validate_state() {
  local errors=""
  local ss_enabled vless_enabled hy2_enabled
  local server_address server_address_ipv6 dual_stack outbound_ip_preference vless_server_name handshake_server vless_core
  local split_name split_enabled split_type split_server split_port split_username split_password split_method split_rule_count split_rule vless_short_id

  ss_enabled="$(state_get '.protocols.shadowsocks.enabled')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  hy2_enabled="$(state_get '.protocols.hysteria2.enabled')"
  server_address="$(state_get '.meta.server_address')"
  server_address_ipv6="$(state_get '.meta.server_address_ipv6 // ""')"
  dual_stack="$(state_get '.meta.dual_stack // false')"
  outbound_ip_preference="$(state_get '.meta.outbound_ip_preference // "auto"')"

  [[ -n "$server_address" && "$server_address" != "null" ]] || errors+=$'节点对外地址不能为空。\n'
  if [[ "$dual_stack" == "true" ]] && ! is_public_ipv6_candidate "$server_address_ipv6"; then
    errors+=$'双栈节点缺少有效的公网 IPv6 地址。\n'
  fi
  case "$outbound_ip_preference" in
    auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only)
      ;;
    *)
      errors+=$'出站 IPv4 / IPv6 策略设置无效。\n'
      ;;
  esac

  if [[ "$ss_enabled" == "true" ]]; then
    [[ "$(state_get '.protocols.shadowsocks.users | length')" -gt 0 ]] || errors+=$'Shadowsocks 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.shadowsocks.server_password')" ]] || errors+=$'Shadowsocks 服务端密码不能为空。\n'
  fi

  if [[ "$vless_enabled" == "true" ]]; then
    vless_core="$(state_get '.protocols.vless_reality.core // "sing-box"')"
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    handshake_server="$(state_get '.protocols.vless_reality.handshake_server')"
    vless_short_id="$(state_get '.protocols.vless_reality.short_id')"
    [[ "$(state_get '.protocols.vless_reality.users | length')" -gt 0 ]] || errors+=$'VLESS + Reality 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.vless_reality.private_key')" ]] || errors+=$'VLESS + Reality 私钥不能为空。\n'
    [[ -n "$(state_get '.protocols.vless_reality.public_key')" ]] || errors+=$'VLESS + Reality 公钥不能为空。\n'
    if [[ ! "$vless_short_id" =~ ^[0-9a-fA-F]{2,16}$ ]] || (( ${#vless_short_id} % 2 != 0 )); then
      errors+=$'VLESS + Reality short_id 必须是 2-16 位且长度为偶数的十六进制字符串。\n'
    fi
    [[ -n "$vless_server_name" && "$vless_server_name" != "null" ]] || errors+=$'VLESS + Reality 的伪装域名不能为空。\n'
    [[ -n "$handshake_server" && "$handshake_server" != "null" ]] || errors+=$'VLESS + Reality 的握手站点不能为空。\n'
    [[ "$vless_core" == "sing-box" || "$vless_core" == "xray" ]] || errors+=$'VLESS + Reality 内核必须是 sing-box 或 xray。\n'
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

  while IFS=$'\x1f' read -r split_name split_enabled split_type split_server split_port split_username split_password split_method split_rule_count; do
    split_rule_count="${split_rule_count%$'\r'}"
    [[ "$split_enabled" == "true" ]] || continue
    [[ "$split_type" == "socks" || "$split_type" == "shadowsocks" ]] || errors+="分流落地 ${split_name} 类型仅支持 SOCKS5 或 Shadowsocks。"$'\n'
    [[ -n "$split_server" && "$split_server" != "null" ]] || errors+="分流落地 ${split_name} 地址不能为空。"$'\n'
    [[ "$split_port" =~ ^[0-9]+$ ]] || errors+="分流落地 ${split_name} 端口必须是数字。"$'\n'
    if [[ "$split_type" == "socks" ]]; then
      if [[ -n "$split_username" && "$split_username" != "null" ]] &&
        [[ -z "$split_password" || "$split_password" == "null" ]]; then
        errors+="分流落地 ${split_name} 已填写 SOCKS5 用户名，密码不能为空。"$'\n'
      elif [[ ( -z "$split_username" || "$split_username" == "null" ) && -n "$split_password" && "$split_password" != "null" ]]; then
        errors+="分流落地 ${split_name} 已填写 SOCKS5 密码，用户名不能为空。"$'\n'
      fi
    else
      is_supported_split_shadowsocks_method "$split_method" || errors+="分流落地 ${split_name} 的 Shadowsocks 加密方式不受支持。"$'\n'
      [[ -n "$split_password" && "$split_password" != "null" ]] || errors+="分流落地 ${split_name} 的 Shadowsocks 密码不能为空。"$'\n'
    fi
    [[ "$split_rule_count" -gt 0 ]] || errors+="分流落地 ${split_name} 至少需要一个分流规则。"$'\n'
  done < <(jq -r '
    .routing.split.outbounds[]? |
    [
      .name,
      (.enabled // false),
      (.outbound_type // "socks"),
      (.server // ""),
      (.port // 0),
      (.username // ""),
      (.password // ""),
      (.method // ""),
      ((.rule_sets // []) | length)
    ] | map(tostring) | join("\u001f")
  ' "$STATE_FILE")

  while IFS=$'\x1f' read -r split_name split_rule; do
    split_rule="${split_rule%$'\r'}"
    case "$split_rule" in
      geosite:*)
        [[ "${split_rule#geosite:}" =~ ^[a-z0-9][a-z0-9._@!+-]*$ ]] ||
          errors+="分流落地 ${split_name} 的 GeoSite 分类名无效：${split_rule#geosite:}"$'\n'
        ;;
      srs:*)
        [[ "${split_rule#srs:}" =~ ^https://[^[:space:],]+\.srs([?#][^[:space:],]*)?$ ]] ||
          errors+="分流落地 ${split_name} 的远程 SRS 地址无效，必须是 HTTPS .srs：${split_rule#srs:}"$'\n'
        ;;
    esac
  done < <(jq -r '
    .routing.split.outbounds[]?
    | select(.enabled // false)
    | .name as $name
    | (.rule_sets // [])[]?
    | [$name, .] | join("\u001f")
  ' "$STATE_FILE")

  if [[ -n "$errors" ]]; then
    ui_show_text "配置校验失败" "$errors"
    return 1
  fi

  return 0
}

render_config() {
  jq --arg rule_set_cache_file "$RULE_SET_CACHE_FILE" '
  def sing_box_vless_enabled:
    .protocols.vless_reality.enabled
    and ((.protocols.vless_reality.core // "sing-box") == "sing-box");
  def split_outbound_tag:
    "split-out:" + .;
  def split_rule_tag($id; $index):
    "split:" + $id + ":" + ($index | tostring);
  def split_ss_method:
    if . == "plain" then
      "none"
    elif . == "chacha20-poly1305" then
      "chacha20-ietf-poly1305"
    elif . == "xchacha20-poly1305" then
      "xchacha20-ietf-poly1305"
    else
      .
    end;

  {
    log: {
      disabled: false,
      level: .meta.log_level,
      timestamp: true
    },
    dns: {
      servers: [
        {
          type: "local",
          tag: "local",
          prefer_go: true
        }
      ]
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
        if sing_box_vless_enabled then
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
        .routing.split.outbounds[]?
        | select((.enabled // false) and ((.rule_sets // []) | length > 0))
        | if (.outbound_type // "socks") == "shadowsocks" then
            {
              type: "shadowsocks",
              tag: (.id | split_outbound_tag),
              server: .server,
              server_port: .port,
              method: (.method | split_ss_method),
              password: .password
            }
          else
            ({
              type: "socks",
              tag: (.id | split_outbound_tag),
              server: .server,
              server_port: .port,
              version: "5"
            } + (if ((.username // "") | length) > 0 then
                   { username: .username, password: (.password // "") }
                 else
                   {}
                 end))
          end
      )
    ],
    route: {
      rule_set: [
        (
          .routing.split.outbounds[]?
          | select((.enabled // false) and ((.rule_sets // []) | length > 0))
          | . as $outbound
          | .rule_sets
          | to_entries[]
          | . as $entry
          | if $entry.value | startswith("geosite:") then
              {
                type: "remote",
                tag: split_rule_tag($outbound.id; $entry.key),
                format: "binary",
                url: ("https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-" + ($entry.value | ltrimstr("geosite:")) + ".srs"),
                update_interval: "1d"
              }
            elif $entry.value | startswith("srs:") then
              {
                type: "remote",
                tag: split_rule_tag($outbound.id; $entry.key),
                format: "binary",
                url: ($entry.value | ltrimstr("srs:")),
                update_interval: "1d"
              }
            else
              {
                type: "inline",
                tag: split_rule_tag($outbound.id; $entry.key),
                rules: [
                  if $entry.value | startswith("domain:") then
                    { domain_suffix: [$entry.value | ltrimstr("domain:")] }
                  else
                    { domain_keyword: [$entry.value] }
                  end
                ]
              }
            end
        )
      ],
      rules: [
        (
          if (.protocols.shadowsocks.enabled or sing_box_vless_enabled or .protocols.hysteria2.enabled) then
            [
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if sing_box_vless_enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                ip_cidr: [
                  "169.254.169.254/32",
                  "100.100.100.200/32",
                  "fd00:ec2::254/128"
                ],
                action: "reject"
              },
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if sing_box_vless_enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                ip_is_private: true,
                action: "reject"
              }
            ][]
          else empty
          end
        ),
        (
          if ([.routing.split.outbounds[]? | select((.enabled // false) and ((.rule_sets // []) | length > 0))] | length) > 0 then
            {
              action: "sniff",
              sniffer: ["http", "tls", "quic"],
              timeout: "300ms"
            }
          else empty
          end
        ),
        (
          [
            .routing.split.outbounds[]?
            | select((.enabled // false) and ((.rule_sets // []) | length > 0))
            | . as $outbound
            | .rule_sets
            | to_entries[]
            | {
                outbound_id: $outbound.id,
                rule_index: .key,
                rule: .value,
                kind_rank: (
                  if .value | startswith("domain:") then 0
                  elif (.value | startswith("geosite:")) or (.value | startswith("srs:")) then 1
                  else 2
                  end
                ),
                specificity: (
                  if (.value | startswith("domain:")) or
                     (((.value | startswith("geosite:")) or (.value | startswith("srs:"))) | not) then
                    (.value | length)
                  else
                    0
                  end
                )
              }
          ]
          | sort_by([.kind_rank, (-.specificity), .rule, .outbound_id])[]
          | {
              rule_set: [split_rule_tag(.outbound_id; .rule_index)],
              action: "route",
              outbound: (.outbound_id | split_outbound_tag)
            }
        ),
        (
          if (.protocols.shadowsocks.enabled or sing_box_vless_enabled or .protocols.hysteria2.enabled) then
            [
              ({
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if sing_box_vless_enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                action: "resolve",
                server: "local"
              } + (
                if (.meta.outbound_ip_preference // "auto") == "auto" then
                  {}
                else
                  { strategy: .meta.outbound_ip_preference }
                end
              )),
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if sing_box_vless_enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                ip_cidr: [
                  "169.254.169.254/32",
                  "100.100.100.200/32",
                  "fd00:ec2::254/128"
                ],
                action: "reject"
              },
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if sing_box_vless_enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                ip_is_private: true,
                action: "reject"
              }
            ][]
          else empty
          end
        )
      ],
      final: "direct"
    },
    experimental: {
      cache_file: {
        enabled: true,
        path: $rule_set_cache_file
      }
    }
  }' "$STATE_FILE"
}

render_xray_config() {
  jq '
    def xray_log_level:
      if .meta.log_level == "warn" then "warning"
      elif .meta.log_level == "trace" then "debug"
      else (.meta.log_level // "warning") end;
    def xray_domain_strategy:
      if .meta.outbound_ip_preference == "prefer_ipv4" then "UseIPv4v6"
      elif .meta.outbound_ip_preference == "prefer_ipv6" then "UseIPv6v4"
      elif .meta.outbound_ip_preference == "ipv4_only" then "ForceIPv4"
      elif .meta.outbound_ip_preference == "ipv6_only" then "ForceIPv6"
      else "AsIs" end;
    {
      log: {
        loglevel: xray_log_level
      },
      inbounds: [
        {
          tag: "vless-reality-in",
          listen: .protocols.vless_reality.listen,
          port: .protocols.vless_reality.port,
          protocol: "vless",
          settings: {
            clients: [
              .protocols.vless_reality.users[] | {
                id: .uuid,
                email: .name,
                flow: "xtls-rprx-vision"
              }
            ],
            decryption: "none"
          },
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: {
              show: false,
              target: (.protocols.vless_reality.handshake_server + ":" + (.protocols.vless_reality.handshake_port | tostring)),
              xver: 0,
              serverNames: [ .protocols.vless_reality.server_name ],
              privateKey: .protocols.vless_reality.private_key,
              shortIds: [ .protocols.vless_reality.short_id ]
            }
          }
        }
      ],
      outbounds: [
        {
          tag: "direct",
          protocol: "freedom",
          settings: {
            domainStrategy: xray_domain_strategy
          }
        },
        {
          tag: "block",
          protocol: "blackhole",
          settings: {}
        }
      ],
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: [
          {
            type: "field",
            inboundTag: ["vless-reality-in"],
            ip: [
              "10.0.0.0/8",
              "100.64.0.0/10",
              "127.0.0.0/8",
              "169.254.0.0/16",
              "172.16.0.0/12",
              "192.168.0.0/16",
              "::1/128",
              "fc00::/7",
              "fe80::/10",
              "169.254.169.254/32",
              "100.100.100.200/32",
              "fd00:ec2::254/128"
            ],
            outboundTag: "block"
          }
        ]
      }
    }
  ' "$STATE_FILE"
}

enabled_protocol_count() {
  state_get '[.protocols[] | select(.enabled == true)] | length'
}

sing_box_protocol_count() {
  state_get '[
    .protocols.shadowsocks.enabled,
    .protocols.hysteria2.enabled,
    (.protocols.vless_reality.enabled and ((.protocols.vless_reality.core // "sing-box") == "sing-box"))
  ] | map(select(. == true)) | length'
}

xray_protocol_enabled() {
  [[ "$(state_get '.protocols.vless_reality.enabled and ((.protocols.vless_reality.core // "sing-box") == "xray")')" == "true" ]]
}

add_managed_iptables_rule() {
  local command_name=$1 insert_position
  shift

  insert_position="$("$command_name" -S INPUT 2>/dev/null | awk '
    $1 == "-A" && $2 == "INPUT" {
      position++
      if ($3 == "-j" && ($4 == "DROP" || $4 == "REJECT")) {
        print position
        exit
      }
    }
  ')"

  if [[ "$insert_position" =~ ^[0-9]+$ ]]; then
    "$command_name" -I INPUT "$insert_position" "$@"
  else
    "$command_name" -A INPUT "$@"
  fi
}

allow_iptables_port() {
  local port=$1
  local protocol=$2
  local source=${3:-*}
  local applied=false

  if [[ "$source" == "*" ]]; then
    if have_cmd iptables; then
      applied=true
      iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 ||
        add_managed_iptables_rule iptables -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
    fi
    if have_cmd ip6tables; then
      applied=true
      ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 ||
        add_managed_iptables_rule ip6tables -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
    fi
  elif [[ "$source" == *:* ]]; then
    if have_cmd ip6tables; then
      applied=true
      ip6tables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 ||
        add_managed_iptables_rule ip6tables -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
    fi
  elif have_cmd iptables; then
    applied=true
    iptables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 ||
      add_managed_iptables_rule iptables -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
  fi
  [[ "$applied" == "true" ]]
}

remove_iptables_port() {
  local port=$1
  local protocol=$2
  local source=${3:-*}

  if [[ "$source" == "*" ]]; then
    if have_cmd iptables; then
      while iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
    if have_cmd ip6tables; then
      while ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
  elif [[ "$source" == *:* ]]; then
    if have_cmd ip6tables; then
      while ip6tables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
  elif have_cmd iptables; then
    while iptables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
    done
  fi
}

remove_legacy_iptables_port() {
  local port=$1 protocol=$2 source=${3:-*}

  if [[ "$source" == "*" ]]; then
    if have_cmd iptables; then
      while iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
    if have_cmd ip6tables; then
      while ip6tables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
  elif [[ "$source" == *:* ]]; then
    if have_cmd ip6tables; then
      while ip6tables -C INPUT -p "$protocol" -s "$source" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$protocol" -s "$source" --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
  elif have_cmd iptables; then
    while iptables -C INPUT -p "$protocol" -s "$source" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
      iptables -D INPUT -p "$protocol" -s "$source" --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
    done
  fi
}

migrate_legacy_iptables_rules() {
  local owner protocol port source rules
  [[ -e "$IPTABLES_MIGRATION_MARKER" ]] && return 0

  rules="$(mktemp "$TMP_DIR/firewall-legacy.XXXXXX")" || return 1
  if [[ -s "$FIREWALL_STATE_FILE" ]]; then
    cp "$FIREWALL_STATE_FILE" "$rules"
  fi

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    remove_legacy_iptables_port "$port" "$protocol" "${source:-*}"
    if have_cmd iptables; then
      while iptables -C INPUT -p "$protocol" --dport "$port" -j DROP >/dev/null 2>&1; do
        iptables -D INPUT -p "$protocol" --dport "$port" -j DROP >/dev/null 2>&1 || break
      done
    fi
    if have_cmd ip6tables; then
      while ip6tables -C INPUT -p "$protocol" --dport "$port" -j DROP >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$protocol" --dport "$port" -j DROP >/dev/null 2>&1 || break
      done
    fi
  done <"$rules"
  rm -f "$rules"
  : >"$IPTABLES_MIGRATION_MARKER"
  chmod 0600 "$IPTABLES_MIGRATION_MARKER"
}

persist_openrc_firewall_rules() {
  has_openrc || return 0

  if [[ -x /etc/init.d/iptables ]]; then
    rc-update add iptables default >/dev/null 2>&1 || true
    rc-service iptables save >/dev/null 2>&1 || true
  fi
  if [[ -x /etc/init.d/ip6tables ]]; then
    rc-update add ip6tables default >/dev/null 2>&1 || true
    rc-service ip6tables save >/dev/null 2>&1 || true
  fi
}

active_firewall_backend() {
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    printf 'ufw\n'
  elif have_cmd firewall-cmd && has_systemd && systemctl is-active firewalld >/dev/null 2>&1; then
    printf 'firewalld\n'
  elif have_cmd iptables || have_cmd ip6tables; then
    printf 'iptables\n'
  else
    printf 'none\n'
  fi
}

ensure_managed_firewall_backend() {
  [[ "$(active_firewall_backend)" != "none" ]] && return 0

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache iptables iptables-openrc >&2 || die "自动安装 Alpine 防火墙组件失败。"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      repair_dpkg_state || die "无法恢复 dpkg 软件包状态，无法安装防火墙组件。"
      apt-get update -y >&2 || die "更新 APT 软件包索引失败，无法安装防火墙组件。"
      apt-get install -y iptables >&2 || die "自动安装 iptables 失败。"
      ;;
    dnf)
      dnf install -y iptables >&2 || die "自动安装 iptables 失败。"
      ;;
    yum)
      yum install -y iptables >&2 || die "自动安装 iptables 失败。"
      ;;
    *)
      ;;
  esac

  [[ "$(active_firewall_backend)" != "none" ]] ||
    die "无法安装或找到本地防火墙后端。Alpine 请安装 iptables 和 iptables-openrc。"
}

ensure_socket_inspection_command() {
  have_cmd ss && return 0

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache iproute2-ss >&2 || die "自动安装 ss 端口检查工具失败。"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      repair_dpkg_state || die "无法恢复 dpkg 软件包状态，无法安装 ss。"
      apt-get update -y >&2 || die "更新 APT 软件包索引失败，无法安装 ss。"
      apt-get install -y iproute2 >&2 || die "自动安装 iproute2/ss 失败。"
      ;;
    dnf)
      dnf install -y iproute >&2 || die "自动安装 iproute/ss 失败。"
      ;;
    yum)
      yum install -y iproute >&2 || die "自动安装 iproute/ss 失败。"
      ;;
    *)
      ;;
  esac

  have_cmd ss || die "无法安装或找到 ss，无法安全检查节点端口冲突。"
}

managed_firewall_rules_present() {
  [[ -s "$FIREWALL_STATE_FILE" ]] && return 0
  [[ -n "$(desired_managed_firewall_rules 2>/dev/null | head -n 1)" ]]
}

ensure_firewall_restore_service() {
  has_systemd || return 0

  mkdir -p "$(dirname "$FIREWALL_SYSTEMD_SERVICE_FILE")" \
    "$SING_BOX_FIREWALL_DROPIN_DIR" "$XRAY_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR"
  cat >"$FIREWALL_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=Restore sbox managed firewall rules
After=network-pre.target ufw.service firewalld.service
Before=sing-box.service sbox-xray.service realm.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${MANAGER_SCRIPT_PATH} firewall-sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SING_BOX_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" <<'EOF'
[Unit]
Requires=sbox-firewall.service
After=sbox-firewall.service
EOF

  cat >"$XRAY_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" <<'EOF'
[Unit]
Requires=sbox-firewall.service
After=sbox-firewall.service
EOF

  cat >"$REALM_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" <<'EOF'
[Unit]
Requires=sbox-firewall.service
After=sbox-firewall.service
EOF

  systemctl daemon-reload >/dev/null 2>&1 || return 1
  systemctl enable sbox-firewall.service >/dev/null 2>&1 || return 1
}

prepare_managed_firewall() {
  local backend
  if [[ -s "$STATE_FILE" ]] && ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    warn "节点状态文件无效，已拒绝修改防火墙。"
    return 1
  fi
  if [[ -s "$REALM_STATE_FILE" ]] && ! jq -e . "$REALM_STATE_FILE" >/dev/null 2>&1; then
    warn "Realm 状态文件无效，已拒绝修改防火墙。"
    return 1
  fi
  managed_firewall_rules_present || return 0
  backend="$(active_firewall_backend)"
  if [[ "$backend" == "none" ]]; then
    ensure_managed_firewall_backend
    backend="$(active_firewall_backend)"
  fi
  ensure_firewall_restore_service || {
    warn "无法安装防火墙开机恢复服务。"
    return 1
  }
}

remove_firewall_restore_service() {
  has_systemd || return 0
  systemctl disable --now sbox-firewall.service >/dev/null 2>&1 || true
  rm -f "$FIREWALL_SYSTEMD_SERVICE_FILE" \
    "$SING_BOX_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" \
    "$XRAY_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" \
    "$REALM_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" 2>/dev/null || true
  rmdir "$SING_BOX_FIREWALL_DROPIN_DIR" "$XRAY_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

firewalld_rich_rule() {
  local protocol=$1 port=$2 source=$3 family=ipv4
  [[ "$source" == *:* ]] && family=ipv6
  printf 'rule family="%s" source address="%s" port port="%s" protocol="%s" accept\n' \
    "$family" "$source" "$port" "$protocol"
}

firewalld_reject_rule() {
  local protocol=$1 port=$2
  printf 'rule priority="100" port port="%s" protocol="%s" reject\n' "$port" "$protocol"
}

remove_firewall_restriction() {
  local protocol=$1 port=$2 rich_rule

  if have_cmd ufw; then
    ufw --force delete deny "${port}/${protocol}" >/dev/null 2>&1 || true
  fi
  if have_cmd firewall-cmd && has_systemd && systemctl is-active firewalld >/dev/null 2>&1; then
    rich_rule="$(firewalld_reject_rule "$protocol" "$port")"
    firewall-cmd --permanent --remove-rich-rule="$rich_rule" >/dev/null 2>&1 || true
  fi
  if have_cmd iptables; then
    while iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1; do
      iptables -D INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || break
    done
  fi
  if have_cmd ip6tables; then
    while ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1; do
      ip6tables -D INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || break
    done
  fi
}

add_firewall_restriction() {
  local backend=$1 protocol=$2 port=$3 rich_rule
  case "$backend" in
    ufw)
      ufw deny "${port}/${protocol}" >/dev/null 2>&1
      ;;
    firewalld)
      rich_rule="$(firewalld_reject_rule "$protocol" "$port")"
      firewall-cmd --permanent --add-rich-rule="$rich_rule" >/dev/null 2>&1
      ;;
    iptables)
        if have_cmd iptables; then
          iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 ||
          add_managed_iptables_rule iptables -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || return 1
      fi
        if have_cmd ip6tables; then
          ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 ||
          add_managed_iptables_rule ip6tables -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || return 1
      fi
      ;;
  esac
}

remove_firewall_rule() {
  local protocol=$1 port=$2 source=${3:-*} rich_rule

  if have_cmd ufw; then
    if [[ "$source" == "*" ]]; then
      ufw --force delete allow "${port}/${protocol}" >/dev/null 2>&1 || true
    else
      ufw --force delete allow proto "$protocol" from "$source" to any port "$port" >/dev/null 2>&1 || true
    fi
  fi

  if have_cmd firewall-cmd && has_systemd && systemctl is-active firewalld >/dev/null 2>&1; then
    if [[ "$source" == "*" ]]; then
      firewall-cmd --permanent --remove-port="${port}/${protocol}" >/dev/null 2>&1 || true
    else
      rich_rule="$(firewalld_rich_rule "$protocol" "$port" "$source")"
      firewall-cmd --permanent --remove-rich-rule="$rich_rule" >/dev/null 2>&1 || true
    fi
  fi

  remove_iptables_port "$port" "$protocol" "$source"
}

add_firewall_rule() {
  local backend=$1 protocol=$2 port=$3 source=${4:-*} rich_rule

  case "$backend" in
    ufw)
      if [[ "$source" == "*" ]]; then
        ufw allow "${port}/${protocol}" >/dev/null 2>&1
      else
        ufw allow proto "$protocol" from "$source" to any port "$port" >/dev/null 2>&1
      fi
      ;;
    firewalld)
      if [[ "$source" == "*" ]]; then
        firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1
      else
        rich_rule="$(firewalld_rich_rule "$protocol" "$port" "$source")"
        firewall-cmd --permanent --add-rich-rule="$rich_rule" >/dev/null 2>&1
      fi
      ;;
    iptables)
      allow_iptables_port "$port" "$protocol" "$source"
      ;;
    *)
      return 1
      ;;
  esac
}

ufw_rule_is_added() {
  local expected=$1
  ufw show added 2>/dev/null | tr -d '\r' | grep -Fqx "$expected"
}

firewall_allow_rule_exists() {
  local backend=$1 protocol=$2 port=$3 source=${4:-*} rich_rule
  case "$backend" in
    ufw)
      if [[ "$source" == "*" ]]; then
        ufw_rule_is_added "ufw allow ${port}/${protocol}"
      else
        ufw_rule_is_added "ufw allow proto ${protocol} from ${source} to any port ${port}"
      fi
      ;;
    firewalld)
      if [[ "$source" == "*" ]]; then
        firewall-cmd --permanent --query-port="${port}/${protocol}" >/dev/null 2>&1 &&
          firewall-cmd --query-port="${port}/${protocol}" >/dev/null 2>&1
      else
        rich_rule="$(firewalld_rich_rule "$protocol" "$port" "$source")"
        firewall-cmd --permanent --query-rich-rule="$rich_rule" >/dev/null 2>&1 &&
          firewall-cmd --query-rich-rule="$rich_rule" >/dev/null 2>&1
      fi
      ;;
    iptables)
      if [[ "$source" == "*" ]]; then
        if have_cmd iptables; then
          iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
        fi
        if have_cmd ip6tables; then
          ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1 || return 1
        fi
      elif [[ "$source" == *:* ]]; then
        have_cmd ip6tables && ip6tables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1
      else
        have_cmd iptables && iptables -C INPUT -p "$protocol" -s "$source" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j ACCEPT >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

firewall_restriction_exists() {
  local backend=$1 protocol=$2 port=$3 rich_rule
  case "$backend" in
    ufw)
      ufw_rule_is_added "ufw deny ${port}/${protocol}"
      ;;
    firewalld)
      rich_rule="$(firewalld_reject_rule "$protocol" "$port")"
      firewall-cmd --permanent --query-rich-rule="$rich_rule" >/dev/null 2>&1 &&
        firewall-cmd --query-rich-rule="$rich_rule" >/dev/null 2>&1
      ;;
    iptables)
      if have_cmd iptables; then
        iptables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || return 1
      fi
      if have_cmd ip6tables; then
        ip6tables -C INPUT -p "$protocol" --dport "$port" -m comment --comment "$IPTABLES_RULE_COMMENT" -j DROP >/dev/null 2>&1 || return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

automatic_managed_firewall_rules() {
  if [[ -s "$STATE_FILE" ]]; then
    jq -e . "$STATE_FILE" >/dev/null 2>&1 || return 1
    jq -r '
      def row($owner; $protocol; $port; $source):
        [$owner, $protocol, ($port | tostring), $source] | @tsv;
      . as $root |
      (if $root.protocols.shadowsocks.enabled then
        row("shadowsocks"; "tcp"; $root.protocols.shadowsocks.port; "*")
      else empty end),
      (if $root.protocols.vless_reality.enabled then
        row("vless_reality"; "tcp"; $root.protocols.vless_reality.port; "*")
      else empty end),
      (if $root.protocols.hysteria2.enabled then
        row("hysteria2"; "udp"; $root.protocols.hysteria2.port; "*")
      else empty end)
    ' "$STATE_FILE" 2>/dev/null || return 1
  fi

  if [[ -s "$REALM_STATE_FILE" ]]; then
    jq -e . "$REALM_STATE_FILE" >/dev/null 2>&1 || return 1
    jq -r '
      (.rules[]?.entries[]?.listen
        | try capture(":(?<port>[0-9]+)$").port catch empty
        | ["realm", "tcp", ., "*"] | @tsv),
      (.wireguard.profiles[]?
        | select(.role == "landing" and .enabled == true and (.listen_port | type == "number") and (.allowed_source | type == "string") and (.allowed_source | length > 0))
        | ["wireguard", "udp", (.listen_port | tostring), .allowed_source] | @tsv)
    ' "$REALM_STATE_FILE" 2>/dev/null || return 1
  fi
}

is_valid_service_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ && ${#port} -le 5 ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_valid_firewall_protocol() {
  [[ "$1" == "tcp" || "$1" == "udp" ]]
}

firewall_port_policy_rows() {
  [[ -s "$FIREWALL_PORT_POLICY_FILE" ]] || return 0
  awk -F '\t' '
    ($1 == "tcp" || $1 == "udp") && $2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535 && ($3 == "open" || $3 == "closed") {
        key = $1 FS ($2 + 0)
        action[key] = $3
      }
    END {
      for (key in action) print key FS action[key]
    }
  ' "$FIREWALL_PORT_POLICY_FILE" | sort -t $'\t' -k1,1 -k2,2n
}

firewall_port_policy_action() {
  local protocol=$1 port=$2
  firewall_port_policy_rows | awk -F '\t' -v protocol="$protocol" -v port="$port" '
    $1 == protocol && $2 == port {action=$3}
    END {if (action != "") print action}
  '
}

desired_managed_firewall_rules() {
  local automatic_file owner protocol port source action
  automatic_file="$(mktemp "$TMP_DIR/firewall-automatic.XXXXXX")" || return 1
  if ! automatic_managed_firewall_rules | sort -u >"$automatic_file"; then
    rm -f "$automatic_file"
    return 1
  fi

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    action="$(firewall_port_policy_action "$protocol" "$port")"
    [[ "$action" == "closed" ]] || printf '%s\t%s\t%s\t%s\n' "$owner" "$protocol" "$port" "${source:-*}"
  done <"$automatic_file"

  while IFS=$'\t' read -r protocol port action; do
    case "$action" in
      open)
        if ! awk -F '\t' -v protocol="$protocol" -v port="$port" '
          $2 == protocol && $3 == port {found=1}
          END {exit !found}
        ' "$automatic_file"; then
          printf 'manual\t%s\t%s\t*\n' "$protocol" "$port"
        fi
        ;;
      closed)
        printf 'manual_closed\t%s\t%s\t!closed\n' "$protocol" "$port"
        ;;
    esac
  done < <(firewall_port_policy_rows)

  rm -f "$automatic_file"
}

sync_managed_firewall_rules() {
  local strict=${1:-true}
  local old_rules desired_rules backend owner protocol port source failed=false
  old_rules="$(mktemp "$TMP_DIR/firewall-old.XXXXXX")" || return 1
  desired_rules="$(mktemp "$TMP_DIR/firewall-desired.XXXXXX")" || {
    rm -f "$old_rules"
    return 1
  }

  if [[ -s "$FIREWALL_STATE_FILE" ]]; then
    if ! cp "$FIREWALL_STATE_FILE" "$old_rules"; then
      rm -f "$old_rules" "$desired_rules"
      return 1
    fi
  else
    : >"$old_rules"
  fi
  if ! desired_managed_firewall_rules | sort -u >"$desired_rules"; then
    warn "节点或 Realm 状态文件无效，已拒绝修改防火墙规则。"
    rm -f "$old_rules" "$desired_rules"
    return 1
  fi

  backend="$(active_firewall_backend)"
  if [[ "$backend" == "iptables" ]]; then
    migrate_legacy_iptables_rules || {
      rm -f "$old_rules" "$desired_rules"
      return 1
    }
  fi

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if [[ "${source:-*}" != "!closed" ]]; then
      remove_firewall_rule "$protocol" "$port" "${source:-*}"
    fi
    remove_firewall_restriction "$protocol" "$port"
  done <"$old_rules"

  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    remove_firewall_rule "$protocol" "$port" "*"
    remove_firewall_restriction "$protocol" "$port"
  done < <(awk -F '\t' '{print $2 "\t" $3}' "$desired_rules" | sort -u)

  if [[ "$backend" == "none" && -s "$desired_rules" ]]; then
    warn "未检测到可用的 UFW、firewalld 或 iptables，无法应用脚本托管端口规则。"
    install -m 600 "$desired_rules" "$FIREWALL_STATE_FILE"
    rm -f "$old_rules" "$desired_rules"
    [[ "$strict" == "false" ]] && return 0
    return 1
  fi
  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if [[ "${source:-*}" != "!closed" ]]; then
      add_firewall_rule "$backend" "$protocol" "$port" "${source:-*}" || failed=true
    fi
  done <"$desired_rules"

  if [[ "$backend" == "iptables" ]]; then
    while IFS=$'\t' read -r protocol port; do
      [[ -n "$protocol" && -n "$port" ]] || continue
      add_firewall_restriction "$backend" "$protocol" "$port" || failed=true
    done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$desired_rules" | sort -u)
  fi

  if [[ "$backend" == "ufw" || "$backend" == "firewalld" ]]; then
    while IFS=$'\t' read -r protocol port; do
      [[ -n "$protocol" && -n "$port" ]] || continue
      add_firewall_restriction "$backend" "$protocol" "$port" || failed=true
    done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$desired_rules" | sort -u)
  fi

  if [[ "$backend" == "firewalld" ]]; then
    firewall-cmd --reload >/dev/null 2>&1 || failed=true
  fi
  persist_openrc_firewall_rules

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if [[ "${source:-*}" != "!closed" ]]; then
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" || failed=true
    else
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "*" && failed=true
    fi
  done <"$desired_rules"
  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    firewall_restriction_exists "$backend" "$protocol" "$port" || failed=true
  done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$desired_rules" | sort -u)

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if ! awk -F '\t' -v protocol="$protocol" -v port="$port" -v source="${source:-*}" '
      $2 == protocol && $3 == port && $4 == source {found=1}
      END {exit !found}
    ' "$desired_rules"; then
      if [[ "${source:-*}" != "!closed" ]]; then
        firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" && failed=true
      fi
    fi
  done <"$old_rules"
  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if ! awk -F '\t' -v protocol="$protocol" -v port="$port" '
      $2 == protocol && $3 == port && $4 != "*" {found=1}
      END {exit !found}
    ' "$desired_rules"; then
      firewall_restriction_exists "$backend" "$protocol" "$port" && failed=true
    fi
  done < <(awk -F '\t' '{print $2 "\t" $3}' "$old_rules" | sort -u)

  if [[ "$failed" == "true" ]]; then
    warn "部分防火墙规则应用失败，未更新托管状态；请修复防火墙后重试。"
    rm -f "$old_rules" "$desired_rules"
    return 1
  fi
  install -m 600 "$desired_rules" "$FIREWALL_STATE_FILE"
  rm -f "$old_rules" "$desired_rules"
}

initialize_managed_firewall_state() {
  if [[ ! -e "$FIREWALL_STATE_FILE" ]]; then
    sync_managed_firewall_rules false || return 1
  fi
  if managed_firewall_rules_present && [[ "$(active_firewall_backend)" != "none" ]]; then
    ensure_firewall_restore_service || warn "防火墙规则已应用，但开机恢复服务安装失败，请执行 sbox repair-install。"
  fi
}

remove_all_managed_firewall_rules() {
  local owner protocol port source backend firewalld_changed=false failed=false rules_file
  [[ -s "$FIREWALL_STATE_FILE" ]] || return 0

  backend="$(active_firewall_backend)"
  if [[ "$backend" == "none" ]]; then
    warn "未检测到可用的本地防火墙，无法验证托管规则是否已清理。"
    return 1
  fi
  rules_file="$(mktemp "$TMP_DIR/firewall-remove-all.XXXXXX")" || return 1
  cp "$FIREWALL_STATE_FILE" "$rules_file"

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if [[ "${source:-*}" != "!closed" ]]; then
      remove_firewall_rule "$protocol" "$port" "${source:-*}"
    fi
    remove_firewall_restriction "$protocol" "$port"
    firewalld_changed=true
  done <"$rules_file"
  if [[ "$firewalld_changed" == "true" && "$backend" == "firewalld" ]]; then
    firewall-cmd --reload >/dev/null 2>&1 || failed=true
  fi
  persist_openrc_firewall_rules

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if [[ "${source:-*}" != "!closed" ]]; then
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" && failed=true
    fi
    firewall_restriction_exists "$backend" "$protocol" "$port" && failed=true
  done <"$rules_file"
  rm -f "$rules_file"
  if [[ "$failed" == "true" ]]; then
    warn "部分托管防火墙规则清理失败，已保留托管状态以便重试。"
    return 1
  fi
  rm -f "$FIREWALL_STATE_FILE"
}

apply_firewall_rules() {
  sync_managed_firewall_rules
}

port_is_listening() {
  local protocol=$1 port=$2
  have_cmd ss || return 1
  case "$protocol" in
    tcp)
      ss -H -lnt 2>/dev/null | awk -v suffix=":${port}" '$4 ~ (suffix "$" ) {found=1} END {exit !found}'
      ;;
    udp)
      ss -H -lnu 2>/dev/null | awk -v suffix=":${port}" '$4 ~ (suffix "$" ) {found=1} END {exit !found}'
      ;;
    *)
      return 1
      ;;
  esac
}

desired_sing_box_listeners() {
  jq -r '
    (if .protocols.shadowsocks.enabled then ["tcp", (.protocols.shadowsocks.port | tostring), "Shadowsocks"] | @tsv else empty end),
    (if (.protocols.vless_reality.enabled and ((.protocols.vless_reality.core // "sing-box") == "sing-box")) then ["tcp", (.protocols.vless_reality.port | tostring), "VLESS + Reality (sing-box)"] | @tsv else empty end),
    (if .protocols.hysteria2.enabled then ["udp", (.protocols.hysteria2.port | tostring), "Hysteria2"] | @tsv else empty end)
  ' "$STATE_FILE"
}

desired_xray_listeners() {
  jq -r '
    if (.protocols.vless_reality.enabled and ((.protocols.vless_reality.core // "sing-box") == "xray")) then
      ["tcp", (.protocols.vless_reality.port | tostring), "VLESS + Reality (Xray)"] | @tsv
    else empty end
  ' "$STATE_FILE"
}

desired_managed_listeners() {
  desired_sing_box_listeners
  desired_xray_listeners
}

validate_sing_box_listener_ports_available() {
  local rows duplicates protocol port label
  have_cmd ss || {
    printf '缺少 ss 命令，无法在放行防火墙前检查端口冲突。\n'
    return 1
  }

  rows="$(desired_managed_listeners)" || return 1
  duplicates="$(printf '%s\n' "$rows" | awk -F '\t' 'NF >= 2 {key=$1 FS $2; count[key]++; labels[key]=labels[key] (labels[key] ? ", " : "") $3} END {for (key in count) if (count[key] > 1) print key FS labels[key]}')"
  if [[ -n "$duplicates" ]]; then
    printf '配置中的协议监听端口发生冲突：\n%s\n' "$duplicates"
    return 1
  fi

  while IFS=$'\t' read -r protocol port label; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if port_is_listening "$protocol" "$port"; then
      printf '%s 计划使用的 %s/%s 已被其他进程占用。\n' "$label" "$protocol" "$port"
      return 1
    fi
  done <<<"$rows"
}

verify_xray_service_ready() {
  local protocol port label ready
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ready=true
    if ! xray_service_exists || [[ "$(xray_service_active 2>/dev/null || true)" != "active" ]]; then
      ready=false
    fi
    while IFS=$'\t' read -r protocol port label; do
      [[ -n "$protocol" && -n "$port" ]] || continue
      port_is_listening "$protocol" "$port" || ready=false
    done < <(desired_xray_listeners)
    if [[ "$ready" == "true" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

verify_sing_box_service_ready() {
  local protocol port label ready
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ready=true
    if ! service_exists || [[ "$(sing_box_service_active 2>/dev/null || true)" != "active" ]]; then
      ready=false
    fi
    while IFS=$'\t' read -r protocol port label; do
      [[ -n "$protocol" && -n "$port" ]] || continue
      port_is_listening "$protocol" "$port" || ready=false
    done < <(desired_sing_box_listeners)
    if [[ "$ready" == "true" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

validate_realm_listener_ports_available() {
  local previous_state_file=${1:-}
  local realm_was_active=${2:-false}
  local port duplicate_ports
  have_cmd ss || {
    printf '缺少 ss 命令，无法在放行防火墙前检查 Realm 端口冲突。\n'
    return 1
  }

  duplicate_ports="$(jq -r '
    [.rules[]?.entries[]?.listen | try capture(":(?<port>[0-9]+)$").port catch empty]
    | group_by(.)[]
    | select(length > 1)
    | .[0]
  ' "$REALM_STATE_FILE")" || return 1
  if [[ -n "$duplicate_ports" ]]; then
    printf 'Realm 配置中存在重复监听端口：%s\n' "$(paste -sd, <<<"$duplicate_ports")"
    return 1
  fi

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    if [[ "$realm_was_active" == "true" && -s "$previous_state_file" ]] &&
      realm_managed_ports "$previous_state_file" | awk -v expected="$port" '
        $0 == expected {found=1}
        END {exit !found}
      '; then
      continue
    fi
    if port_is_listening tcp "$port"; then
      printf 'Realm 计划使用的 tcp/%s 已被其他进程占用。\n' "$port"
      return 1
    fi
  done < <(realm_managed_ports)
}

listening_port_rows() {
  have_cmd ss || return 1
  ss -H -lntup 2>/dev/null | awk '
    $1 ~ /^(tcp|udp)[0-9]*$/ {
      protocol = $1
      sub(/[0-9]+$/, "", protocol)
      port = $5
      sub(/^.*:/, "", port)
      if (port !~ /^[0-9]+$/ || port < 1 || port > 65535) next
      process = "-"
      details = $0
      if (details ~ /users:\(\(["]/) {
        sub(/^.*users:\(\(["]/, "", details)
        sub(/["].*$/, "", details)
        if (details != "") process = details
      }
      print protocol "\t" port "\t" process
    }
  ' | sort -t $'\t' -k1,1 -k2,2n -k3,3 | awk -F '\t' '
    {
      key = $1 FS $2
      if (!(key in seen)) {
        order[++count] = key
        protocol[key] = $1
        port[key] = $2
      }
      if ($3 != "-" && index("," processes[key] ",", "," $3 ",") == 0) {
        processes[key] = processes[key] (processes[key] == "" ? "" : ",") $3
      }
      seen[key] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        print protocol[key] FS port[key] FS (processes[key] == "" ? "-" : processes[key])
      }
    }
  '
}

detected_ssh_ports() {
  {
    { listening_port_rows 2>/dev/null || true; } | awk -F '\t' '$1 == "tcp" && ("," $3 ",") ~ /,sshd,/ {print $2}'
    if have_cmd sshd; then
      sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' || true
    fi
    if [[ -r "$SSHD_CONFIG_FILE" ]]; then
      awk '
        {
          sub(/[[:space:]]*#.*/, "")
          if (tolower($1) == "port" && $2 ~ /^[0-9]+$/) print $2
        }
      ' "$SSHD_CONFIG_FILE"
    fi
  } | awk '$1 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 65535' | sort -nu
}

firewall_owner_label() {
  case "$1" in
    shadowsocks) printf 'Shadowsocks (SS)\n' ;;
    vless_reality) printf 'VLESS + Reality\n' ;;
    hysteria2) printf 'Hysteria2\n' ;;
    realm) printf 'Realm\n' ;;
    wireguard) printf 'WireGuard\n' ;;
    manual) printf '手动开放\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

firewall_port_usage() {
  local protocol=$1 port=$2 process=${3:--} automatic_file=$4 ssh_ports_file=$5 owner
  {
    while IFS= read -r owner; do
      [[ -n "$owner" ]] && firewall_owner_label "$owner"
    done < <(awk -F '\t' -v protocol="$protocol" -v port="$port" \
      '$2 == protocol && $3 == port {print $1}' "$automatic_file" | sort -u)

    if [[ "$protocol" == "tcp" ]] && awk -v port="$port" '$1 == port {found=1} END {exit !found}' "$ssh_ports_file"; then
      printf 'SSH\n'
    fi
    if [[ "$protocol" == "tcp" ]]; then
      case "$port" in
        22) printf 'SSH 默认端口\n' ;;
        80) printf 'HTTP\n' ;;
        443) printf 'HTTPS\n' ;;
      esac
    fi

    if [[ "$process" != "-" ]]; then
      tr ',' '\n' <<<"$process" | while IFS= read -r owner; do
        case "$owner" in
          sshd) printf 'SSH\n' ;;
          sing-box) printf 'sing-box\n' ;;
          xray) printf 'Xray\n' ;;
          realm) printf 'Realm\n' ;;
          *) printf '进程 %s\n' "$owner" ;;
        esac
      done
    fi
  } | awk 'NF && !seen[$0]++' | paste -sd '、' -
}

managed_firewall_port_is_open() {
  local backend=$1 protocol=$2 port=$3 rules_file=$4 source found=false
  [[ "$backend" != "none" ]] || return 1

  if firewall_allow_rule_exists "$backend" "$protocol" "$port" "*"; then
    return 0
  fi
  while IFS= read -r source; do
    [[ -n "$source" && "$source" != "*" && "$source" != "!closed" ]] || continue
    found=true
    firewall_allow_rule_exists "$backend" "$protocol" "$port" "$source" && return 0
  done < <(awk -F '\t' -v protocol="$protocol" -v port="$port" \
    '$2 == protocol && $3 == port {print $4}' "$rules_file" | sort -u)
  [[ "$found" == "false" ]] && return 1
  return 1
}

show_listening_port_status() {
  local listening_file automatic_file desired_file known_rules_file ssh_ports_file
  local backend output="" unopened="" stale="" protocol port process usage status owner source
  ensure_socket_inspection_command
  listening_file="$(mktemp "$TMP_DIR/firewall-listening.XXXXXX")" || return 1
  automatic_file="$(mktemp "$TMP_DIR/firewall-automatic-status.XXXXXX")" || { rm -f "$listening_file"; return 1; }
  desired_file="$(mktemp "$TMP_DIR/firewall-desired-status.XXXXXX")" || { rm -f "$listening_file" "$automatic_file"; return 1; }
  known_rules_file="$(mktemp "$TMP_DIR/firewall-known-status.XXXXXX")" || { rm -f "$listening_file" "$automatic_file" "$desired_file"; return 1; }
  ssh_ports_file="$(mktemp "$TMP_DIR/firewall-ssh-ports.XXXXXX")" || { rm -f "$listening_file" "$automatic_file" "$desired_file" "$known_rules_file"; return 1; }

  if ! listening_port_rows >"$listening_file" ||
    ! automatic_managed_firewall_rules | sort -u >"$automatic_file" ||
    ! desired_managed_firewall_rules | sort -u >"$desired_file"; then
    rm -f "$listening_file" "$automatic_file" "$desired_file" "$known_rules_file" "$ssh_ports_file"
    ui_msg "无法读取监听端口或节点状态。"
    return 1
  fi
  detected_ssh_ports >"$ssh_ports_file"
  {
    [[ -s "$FIREWALL_STATE_FILE" ]] && cat "$FIREWALL_STATE_FILE"
    cat "$desired_file"
  } | awk -F '\t' 'NF >= 4' | sort -u >"$known_rules_file"
  backend="$(active_firewall_backend)"

  output+=$'[正在监听的端口]\n'
  while IFS=$'\t' read -r protocol port process; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    usage="$(firewall_port_usage "$protocol" "$port" "$process" "$automatic_file" "$ssh_ports_file")"
    if managed_firewall_port_is_open "$backend" "$protocol" "$port" "$known_rules_file"; then
      status="已开放"
    else
      status="未开放"
      unopened+="${protocol^^}/${port}  用途=${usage:-未知}  进程=${process}"$'\n'
    fi
    output+="${protocol^^}/${port}  用途=${usage:-未知}  进程=${process}  防火墙=${status}"$'\n'
  done <"$listening_file"
  [[ -s "$listening_file" ]] || output+="无"$'\n'

  output+=$'\n[已监听未开放的端口]\n'
  output+="${unopened:-无$'\n'}"

  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if ! awk -F '\t' -v protocol="$protocol" -v port="$port" \
      '$1 == protocol && $2 == port {found=1} END {exit !found}' "$listening_file" &&
      managed_firewall_port_is_open "$backend" "$protocol" "$port" "$known_rules_file"; then
      owner="$(awk -F '\t' -v protocol="$protocol" -v port="$port" '$2 == protocol && $3 == port {print $1; exit}' "$known_rules_file")"
      source="$(firewall_port_usage "$protocol" "$port" "-" "$automatic_file" "$ssh_ports_file")"
      [[ -n "$source" ]] || source="$(firewall_owner_label "${owner:-manual}")"
      stale+="${protocol^^}/${port}  用途=${source}"$'\n'
    fi
  done < <(awk -F '\t' 'NF >= 4 {print $2 "\t" $3}' "$known_rules_file" | sort -u)
  output+=$'\n[已开放未监听的端口]\n'
  output+="${stale:-无$'\n'}"
  output+="\n本地防火墙后端：${backend}\n仅统计和操作本脚本托管的放行规则；云安全组与 NAT 不在检测范围内。"

  rm -f "$listening_file" "$automatic_file" "$desired_file" "$known_rules_file" "$ssh_ports_file"
  ui_show_text "正在监听的端口" "$output"
}

write_updated_firewall_port_policy() {
  local changes_file=$1 output_file=$2 protocol port action tmp_file
  firewall_port_policy_rows >"$output_file"
  tmp_file="$(mktemp "$TMP_DIR/firewall-policy-update.XXXXXX")" || return 1

  while IFS=$'\t' read -r protocol port action; do
    if ! is_valid_firewall_protocol "$protocol" || ! is_valid_service_port "$port"; then
      continue
    fi
    port=$((10#$port))
    [[ "$action" == "open" || "$action" == "closed" || "$action" == "clear" ]] || continue
    awk -F '\t' -v protocol="$protocol" -v port="$port" \
      '!($1 == protocol && $2 == port)' "$output_file" >"$tmp_file"
    mv "$tmp_file" "$output_file"
    tmp_file="$(mktemp "$TMP_DIR/firewall-policy-update.XXXXXX")" || return 1
    if [[ "$action" != "clear" ]]; then
      printf '%s\t%s\t%s\n' "$protocol" "$port" "$action" >>"$output_file"
    fi
  done <"$changes_file"
  rm -f "$tmp_file"
  sort -t $'\t' -k1,1 -k2,2n -u -o "$output_file" "$output_file"
}

apply_firewall_port_policy_changes() {
  local changes_file=$1 success_message=$2 previous_policy updated_policy restored=true
  previous_policy="$(mktemp "$TMP_DIR/firewall-policy-backup.XXXXXX")" || return 1
  updated_policy="$(mktemp "$TMP_DIR/firewall-policy-new.XXXXXX")" || { rm -f "$previous_policy"; return 1; }
  firewall_port_policy_rows >"$previous_policy"
  if ! write_updated_firewall_port_policy "$changes_file" "$updated_policy" ||
    ! install -m 0600 "$updated_policy" "$FIREWALL_PORT_POLICY_FILE"; then
    rm -f "$previous_policy" "$updated_policy"
    ui_msg "无法保存端口策略，防火墙未修改。"
    return 1
  fi

  if prepare_managed_firewall && sync_managed_firewall_rules; then
    rm -f "$previous_policy" "$updated_policy"
    ui_msg "$success_message"
    return 0
  fi

  install -m 0600 "$previous_policy" "$FIREWALL_PORT_POLICY_FILE" || restored=false
  if [[ "$restored" == "true" ]]; then
    prepare_managed_firewall >/dev/null 2>&1 || true
    sync_managed_firewall_rules >/dev/null 2>&1 || restored=false
  fi
  rm -f "$previous_policy" "$updated_policy"
  if [[ "$restored" == "true" ]]; then
    ui_msg "端口策略应用失败，已恢复原防火墙策略。"
  else
    ui_msg "端口策略应用失败且未能完整恢复，请立即检查本机防火墙。"
  fi
  return 1
}

append_open_firewall_policy_change() {
  local changes_file=$1 automatic_file=$2 protocol=$3 port=$4
  if awk -F '\t' -v protocol="$protocol" -v port="$port" \
    '$2 == protocol && $3 == port {found=1} END {exit !found}' "$automatic_file"; then
    printf '%s\t%s\tclear\n' "$protocol" "$port" >>"$changes_file"
  else
    printf '%s\t%s\topen\n' "$protocol" "$port" >>"$changes_file"
  fi
}

select_firewall_protocols() {
  local choice
  choice="$(ui_menu "端口协议" "请选择要操作的协议" \
    "1" "TCP" \
    "2" "UDP" \
    "3" "TCP + UDP" \
    "0" "返回")" || return 1
  case "$choice" in
    1) printf 'tcp\n' ;;
    2) printf 'udp\n' ;;
    3) printf 'tcp\nudp\n' ;;
    0) return 1 ;;
    *) return 1 ;;
  esac
}

open_all_listening_ports() {
  local listening_file automatic_file changes_file protocol port process count result
  ensure_socket_inspection_command
  listening_file="$(mktemp "$TMP_DIR/firewall-open-listening.XXXXXX")" || return 1
  automatic_file="$(mktemp "$TMP_DIR/firewall-open-automatic.XXXXXX")" || { rm -f "$listening_file"; return 1; }
  changes_file="$(mktemp "$TMP_DIR/firewall-open-changes.XXXXXX")" || { rm -f "$listening_file" "$automatic_file"; return 1; }
  listening_port_rows >"$listening_file"
  automatic_managed_firewall_rules | sort -u >"$automatic_file"
  count="$(awk -F '\t' 'NF >= 2 {count++} END {print count+0}' "$listening_file")"
  if (( count == 0 )); then
    rm -f "$listening_file" "$automatic_file" "$changes_file"
    ui_msg "当前没有检测到正在监听的 TCP/UDP 端口。"
    return 0
  fi
  ui_yesno "将为当前检测到的 ${count} 个监听端口创建脚本托管放行规则，是否继续？" || {
    rm -f "$listening_file" "$automatic_file" "$changes_file"
    return 0
  }
  while IFS=$'\t' read -r protocol port process; do
    append_open_firewall_policy_change "$changes_file" "$automatic_file" "$protocol" "$port"
  done <"$listening_file"
  sort -u -o "$changes_file" "$changes_file"
  apply_firewall_port_policy_changes "$changes_file" "已开放并验证 ${count} 个正在监听的端口。"
  result=$?
  rm -f "$listening_file" "$automatic_file" "$changes_file"
  return "$result"
}

default_firewall_tcp_ports() {
  {
    printf '22\n80\n443\n'
    detected_ssh_ports
  } | awk '$1 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 65535' | sort -nu
}

manual_firewall_port_action() {
  local action=$1 protocols port automatic_file changes_file protocol protocol_display result
  protocols="$(select_firewall_protocols)" || return 0
  port="$(prompt_number "${action}指定端口" "请输入要${action}的端口（1-65535）" "" 1 65535)" || return 1
  port=$((10#$port))
  automatic_file="$(mktemp "$TMP_DIR/firewall-manual-automatic.XXXXXX")" || return 1
  changes_file="$(mktemp "$TMP_DIR/firewall-manual-changes.XXXXXX")" || { rm -f "$automatic_file"; return 1; }
  automatic_managed_firewall_rules | sort -u >"$automatic_file"
  protocol_display="$(paste -sd '+' <<<"${protocols^^}")"

  if [[ "$action" == "开放" ]]; then
    while IFS= read -r protocol; do
      append_open_firewall_policy_change "$changes_file" "$automatic_file" "$protocol" "$port"
    done <<<"$protocols"
  else
    while IFS= read -r protocol; do
      printf '%s\t%s\tclosed\n' "$protocol" "$port" >>"$changes_file"
    done <<<"$protocols"
    if grep -Fxq tcp <<<"$protocols" && grep -Fxq "$port" < <(detected_ssh_ports); then
      ui_yesno "警告：${protocol_display}/${port} 是当前 SSH 端口，关闭后可能立即中断远程连接。确认继续？" || {
        rm -f "$automatic_file" "$changes_file"
        return 0
      }
    else
      ui_yesno "确认关闭 ${protocol_display}/${port} 的脚本托管放行规则？" || {
        rm -f "$automatic_file" "$changes_file"
        return 0
      }
    fi
  fi

  apply_firewall_port_policy_changes "$changes_file" "已${action}并验证 ${protocol_display}/${port}。"
  result=$?
  rm -f "$automatic_file" "$changes_file"
  return "$result"
}

open_default_firewall_ports() {
  local automatic_file changes_file ports_file port display result
  automatic_file="$(mktemp "$TMP_DIR/firewall-default-automatic.XXXXXX")" || return 1
  changes_file="$(mktemp "$TMP_DIR/firewall-default-changes.XXXXXX")" || { rm -f "$automatic_file"; return 1; }
  ports_file="$(mktemp "$TMP_DIR/firewall-default-ports.XXXXXX")" || { rm -f "$automatic_file" "$changes_file"; return 1; }
  automatic_managed_firewall_rules | sort -u >"$automatic_file"
  default_firewall_tcp_ports >"$ports_file"
  display="$(paste -sd, "$ports_file" | sed 's/,/, /g')"
  ui_yesno "将开放 TCP/${display}。其中包含 SSH 当前端口以及固定端口 22、80、443，是否继续？" || {
    rm -f "$automatic_file" "$changes_file" "$ports_file"
    return 0
  }
  while IFS= read -r port; do
    append_open_firewall_policy_change "$changes_file" "$automatic_file" tcp "$port"
  done <"$ports_file"
  apply_firewall_port_policy_changes "$changes_file" "已开放默认 TCP 端口：${display}。"
  result=$?
  rm -f "$automatic_file" "$changes_file" "$ports_file"
  return "$result"
}

firewall_port_action_menu() {
  local choice
  while true; do
    choice="$(ui_menu "开放 / 关闭指定端口" "手动策略会持久保存，配置重载和服务器重启后仍然生效。" \
      "1" "一键开放所有正在监听的端口" \
      "2" "手动开放指定端口" \
      "3" "手动关闭指定端口" \
      "0" "返回端口管理" \
      "00" "退出脚本")" || continue
    case "$choice" in
      1) open_all_listening_ports || true ;;
      2) manual_firewall_port_action "开放" || true ;;
      3) manual_firewall_port_action "关闭" || true ;;
      0) return 0 ;;
      00) exit 0 ;;
      *) ui_msg "无效选项，请重新选择。" ;;
    esac
  done
}

port_management_menu() {
  local choice
  while true; do
    choice="$(ui_menu "端口管理" "管理本脚本托管的本机防火墙端口；云安全组和 NAT 需在服务商控制台管理。" \
      "1" "正在监听的端口" \
      "2" "开放 / 关闭指定端口" \
      "3" "开放默认端口（SSH、22、80、443）" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue
    case "$choice" in
      1) show_listening_port_status || true ;;
      2) firewall_port_action_menu || true ;;
      3) open_default_firewall_ports || true ;;
      0) return 0 ;;
      00) exit 0 ;;
      *) ui_msg "无效选项，请重新选择。" ;;
    esac
  done
}

run_common_script() {
  local script_name=$1
  local script_url=$2
  local tmp_script status

  if ! have_cmd curl && ! have_cmd wget; then
    ui_msg "未检测到 curl 或 wget，无法下载 ${script_name}。"
    return 1
  fi

  tmp_script="$(mktemp "$TMP_DIR/sbox-common-script.XXXXXX")" || {
    ui_msg "无法创建临时文件，${script_name} 未运行。"
    return 1
  }

  log "正在下载并运行 ${script_name}..."
  if ! download_to_file "$tmp_script" "$script_url"; then
    rm -f -- "$tmp_script"
    ui_msg "${script_name} 下载失败，请检查网络后重试。"
    return 1
  fi

  if [[ ! -s "$tmp_script" ]] || ! bash -n "$tmp_script"; then
    rm -f -- "$tmp_script"
    ui_msg "${script_name} 下载内容为空或 Bash 语法检查失败，已拒绝运行。"
    return 1
  fi

  if bash "$tmp_script"; then
    status=0
    log "${script_name} 已运行完毕。"
  else
    status=$?
    warn "${script_name} 运行失败（退出码：${status}）。"
  fi

  rm -f -- "$tmp_script"
  ui_pause
  return "$status"
}

common_scripts_menu() {
  local choice

  while true; do
    choice="$(ui_menu "一键常用脚本" "请选择要运行的第三方脚本（脚本将以当前 root 权限执行）。" \
      "1" "NodeQuality" \
      "2" "TcpQuality" \
      "3" "Tcpfit" \
      "4" "流媒体解锁" \
      "5" "IP 质量体检" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue

    case "$choice" in
      1) run_common_script "NodeQuality" "https://run.NodeQuality.com" || true ;;
      2) run_common_script "TcpQuality" "https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh" || true ;;
      3) run_common_script "Tcpfit" "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" || true ;;
      4) run_common_script "流媒体解锁" "http://check.unlock.media" || true ;;
      5) run_common_script "IP 质量体检" "https://IP.Check.Place" || true ;;
      0) return 0 ;;
      00) exit 0 ;;
      *) ui_msg "无效选项，请重新选择。" ;;
    esac
  done
}

wireguard_config_file() {
  wireguard_valid_interface "$1" || return 1
  printf '%s/%s.conf\n' "$WIREGUARD_DIR" "$1"
}

wireguard_private_key_file() {
  wireguard_valid_interface "$1" || return 1
  printf '%s/%s.key\n' "$WIREGUARD_DIR" "$1"
}

wireguard_public_key_file() {
  wireguard_valid_interface "$1" || return 1
  printf '%s/%s.pub\n' "$WIREGUARD_DIR" "$1"
}

wireguard_profile_count() {
  realm_state_get '(.wireguard.profiles // []) | length'
}

wireguard_profile_exists() {
  jq -e --arg id "$1" '.wireguard.profiles[]? | select(.id == $id)' "$REALM_STATE_FILE" >/dev/null 2>&1
}

wireguard_profile_field() {
  local id=$1 field=$2
  jq -r --arg id "$id" --arg field "$field" '.wireguard.profiles[]? | select(.id == $id) | .[$field] // empty' "$REALM_STATE_FILE" | tr -d '\r'
}

wireguard_valid_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  [[ "$(printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')" == "32" ]]
}

wireguard_valid_interface() {
  [[ "$1" =~ ^${WIREGUARD_INTERFACE_PREFIX}[0-9]{1,2}$ && ${#1} -le 15 ]]
}

wireguard_valid_endpoint_host() {
  local host=$1
  (( ${#host} <= 253 )) || return 1
  is_valid_ipv4_or_cidr "$host" && [[ "$host" != */* ]] && return 0
  is_valid_ipv6_or_cidr "$host" && [[ "$host" != */* ]] && return 0
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$host" == *.* ]]
}

wireguard_valid_allowed_source() {
  is_valid_ip_or_cidr "$1" || return 1
  [[ "$1" != "0.0.0.0/0" && "$1" != "::/0" ]]
}

wireguard_base64url_decode() {
  local value=$1 padding=""
  case $(( ${#value} % 4 )) in
    0) ;;
    2) padding="==" ;;
    3) padding="=" ;;
    *) return 1 ;;
  esac
  printf '%s%s' "$value" "$padding" | tr '_-' '/+' | openssl base64 -d -A
}

wireguard_decode_pairing_code() {
  local code=$1 payload
  [[ "$code" == SBOXWG1:* && ${#code} -le 8192 ]] || return 1
  payload="$(wireguard_base64url_decode "${code#SBOXWG1:}")" || return 1
  jq -ce . <<<"$payload" 2>/dev/null
}

wireguard_encode_pairing_json() {
  printf 'SBOXWG1:%s\n' "$(base64_urlsafe "$1")"
}

wireguard_next_interface() {
  local index interface
  for index in $(seq 0 99); do
    interface="${WIREGUARD_INTERFACE_PREFIX}${index}"
    if ! jq -e --arg interface "$interface" '.wireguard.profiles[]? | select(.interface == $interface)' "$REALM_STATE_FILE" >/dev/null 2>&1 &&
      ! ip link show dev "$interface" >/dev/null 2>&1; then
      printf '%s\n' "$interface"
      return 0
    fi
  done
  return 1
}

wireguard_valid_address_pair() {
  local relay_address=$1 landing_address=$2 relay_subnet landing_subnet
  [[ "$relay_address" =~ ^10\.253\.([1-9][0-9]{0,2})\.1$ ]] || return 1
  relay_subnet="${BASH_REMATCH[1]}"
  [[ "$landing_address" =~ ^10\.253\.([1-9][0-9]{0,2})\.2$ ]] || return 1
  landing_subnet="${BASH_REMATCH[1]}"
  [[ "$relay_subnet" == "$landing_subnet" ]] && (( 10#$relay_subnet >= 1 && 10#$relay_subnet <= 253 ))
}

wireguard_address_pair_in_use() {
  local relay_address=$1 landing_address=$2 ignored_interface=${3:-}
  local address_output line interface
  address_output="$(ip -o address show 2>/dev/null)" || return 1
  while IFS= read -r line; do
    interface="$(awk '{print $2}' <<<"$line")"
    interface="${interface%:}"
    [[ -n "$ignored_interface" && "$interface" == "$ignored_interface" ]] && continue
    if [[ "$line" == *" ${relay_address}/"* || "$line" == *" ${landing_address}/"* ]]; then
      return 0
    fi
  done <<<"$address_output"
  return 1
}

wireguard_generate_address_pair() {
  local subnet relay_address landing_address
  for _ in $(seq 1 100); do
    subnet=$((1 + ((RANDOM * 32768 + RANDOM) % 253)))
    relay_address="10.253.${subnet}.1"
    landing_address="10.253.${subnet}.2"
    if ! jq -e --arg relay "$relay_address" --arg landing "$landing_address" '
      .wireguard.profiles[]? | select(.local_address == $relay or .peer_address == $relay or .local_address == $landing or .peer_address == $landing)
    ' "$REALM_STATE_FILE" >/dev/null 2>&1 &&
      ! wireguard_address_pair_in_use "$relay_address" "$landing_address"; then
      printf '%s\t%s\n' "$relay_address" "$landing_address"
      return 0
    fi
  done
  return 1
}

install_wireguard_tools() {
  local test_interface cmd install_failed=false
  local -a packages=() missing_commands=()

  if ! have_cmd wg || ! have_cmd wg-quick; then
    packages+=(wireguard-tools)
  fi

  detect_pkg_manager
  if ! have_cmd ip; then
    case "$PKG_MANAGER" in
      apk|apt) packages+=(iproute2) ;;
      dnf|yum) packages+=(iproute) ;;
      *)
        ui_msg "当前系统不支持自动安装 WireGuard，请手动安装 wireguard-tools 和 iproute2。"
        return 1
        ;;
    esac
  fi

  if (( ${#packages[@]} > 0 )); then
    case "$PKG_MANAGER" in
      apk)
        apk add --no-cache "${packages[@]}" || install_failed=true
        ;;
      apt)
        export DEBIAN_FRONTEND=noninteractive
        if ! repair_dpkg_state; then
          install_failed=true
        elif ! apt-get update -y; then
          install_failed=true
        elif ! apt-get install -y "${packages[@]}"; then
          install_failed=true
        fi
        ;;
      dnf)
        dnf install -y "${packages[@]}" || install_failed=true
        ;;
      yum)
        if [[ " ${packages[*]} " == *" wireguard-tools "* ]]; then
          yum install -y epel-release >/dev/null 2>&1 || true
        fi
        yum install -y "${packages[@]}" || install_failed=true
        ;;
      *)
        ui_msg "当前系统不支持自动安装 WireGuard，请手动安装 wireguard-tools 和 iproute2。"
        return 1
        ;;
    esac
    hash -r 2>/dev/null || true
  fi

  for cmd in wg wg-quick ip; do
    have_cmd "$cmd" || missing_commands+=("$cmd")
  done
  if (( ${#missing_commands[@]} > 0 )); then
    if [[ "$install_failed" == "true" ]]; then
      ui_msg "WireGuard 软件包安装失败，仍缺少：${missing_commands[*]}。"
    else
      ui_msg "WireGuard 工具安装不完整，仍缺少：${missing_commands[*]}。"
    fi
    return 1
  fi
  if [[ "$install_failed" == "true" ]]; then
    ui_msg "软件包管理器异常退出，但 WireGuard 所需命令已安装，将继续配置。"
  fi
  have_cmd modprobe && modprobe wireguard >/dev/null 2>&1 || true
  test_interface="sbwgt$((RANDOM % 10000))"
  if ! ip link add dev "$test_interface" type wireguard >/dev/null 2>&1; then
    ui_msg "当前内核无法创建 WireGuard 接口，请检查内核模块或 VPS 虚拟化限制。"
    return 1
  fi
  ip link del dev "$test_interface" >/dev/null 2>&1 || true
}

wireguard_generate_keypair() {
  local interface=$1 private_file public_file
  wireguard_valid_interface "$interface" || return 1
  ensure_wireguard_dirs
  private_file="$(wireguard_private_key_file "$interface")"
  public_file="$(wireguard_public_key_file "$interface")"
  (umask 077; wg genkey >"$private_file") || return 1
  wg pubkey <"$private_file" >"$public_file" || {
    rm -f "$private_file" "$public_file"
    return 1
  }
  chmod 0600 "$private_file" "$public_file"
}

render_wireguard_profile_config() {
  local id=$1 interface role local_address peer_address peer_public_key endpoint_host endpoint_port
  local listen_port mtu keepalive private_file private_key endpoint
  interface="$(wireguard_profile_field "$id" interface)"
  role="$(wireguard_profile_field "$id" role)"
  local_address="$(wireguard_profile_field "$id" local_address)"
  peer_address="$(wireguard_profile_field "$id" peer_address)"
  peer_public_key="$(wireguard_profile_field "$id" peer_public_key)"
  endpoint_host="$(wireguard_profile_field "$id" endpoint_host)"
  endpoint_port="$(wireguard_profile_field "$id" endpoint_port)"
  listen_port="$(wireguard_profile_field "$id" listen_port)"
  mtu="$(wireguard_profile_field "$id" mtu)"
  keepalive="$(wireguard_profile_field "$id" persistent_keepalive)"
  private_file="$(wireguard_private_key_file "$interface")"

  wireguard_valid_interface "$interface" || return 1
  is_valid_ipv4_or_cidr "${local_address}/32" || return 1
  is_valid_ipv4_or_cidr "${peer_address}/32" || return 1
  [[ -s "$private_file" ]] || return 1
  private_key="$(tr -d '\r\n' <"$private_file")"
  wireguard_valid_key "$private_key" || return 1
  [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 1280 && mtu <= 1500 )) || return 1

  cat <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${local_address}/32
MTU = ${mtu}
SaveConfig = false
EOF

  if [[ "$role" == "landing" ]]; then
    [[ "$listen_port" =~ ^[0-9]+$ ]] && (( listen_port >= 1 && listen_port <= 65535 )) || return 1
    printf 'ListenPort = %s\n' "$listen_port"
  elif [[ "$role" != "relay" ]]; then
    return 1
  fi

  if [[ -n "$peer_public_key" ]]; then
    wireguard_valid_key "$peer_public_key" || return 1
    cat <<EOF

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = ${peer_address}/32
EOF
    if [[ "$role" == "relay" ]]; then
      wireguard_valid_endpoint_host "$endpoint_host" || return 1
      [[ "$endpoint_port" =~ ^[0-9]+$ ]] && (( endpoint_port >= 1 && endpoint_port <= 65535 )) || return 1
      endpoint="$(format_uri_host "$endpoint_host"):${endpoint_port}"
      printf 'Endpoint = %s\n' "$endpoint"
      [[ "$keepalive" =~ ^[0-9]+$ ]] && (( keepalive >= 0 && keepalive <= 65535 )) || return 1
      if (( keepalive > 0 )); then
        printf 'PersistentKeepalive = %s\n' "$keepalive"
      fi
    fi
  fi
}

write_wireguard_profile_config() {
  local id=$1 interface config_file tmp_file
  interface="$(wireguard_profile_field "$id" interface)"
  config_file="$(wireguard_config_file "$interface")"
  tmp_file="$(mktemp "$TMP_DIR/wireguard-config.XXXXXX")" || return 1
  if ! render_wireguard_profile_config "$id" >"$tmp_file" ||
    ! install -o root -g root -m 0600 "$tmp_file" "$config_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  rm -f "$tmp_file"
}

wireguard_openrc_service_file() {
  wireguard_valid_interface "$1" || return 1
  printf '/etc/init.d/%s-%s\n' "$WIREGUARD_OPENRC_SERVICE_PREFIX" "$1"
}

wireguard_service_name() {
  wireguard_valid_interface "$1" || return 1
  printf '%s-%s\n' "$WIREGUARD_OPENRC_SERVICE_PREFIX" "$1"
}

wireguard_systemd_dropin_dir() {
  wireguard_valid_interface "$1" || return 1
  printf '/etc/systemd/system/wg-quick@%s.service.d\n' "$1"
}

ensure_wireguard_systemd_firewall_ordering() {
  local interface=$1 dropin_dir
  has_systemd || return 0
  dropin_dir="$(wireguard_systemd_dropin_dir "$interface")"
  install -d -m 0755 "$dropin_dir" || return 1
  cat >"$dropin_dir/10-sbox-firewall.conf" <<'EOF'
[Unit]
Requires=sbox-firewall.service
After=sbox-firewall.service
EOF
  systemctl daemon-reload >/dev/null 2>&1
}

ensure_wireguard_openrc_service() {
  local interface=$1 service_file wg_quick
  wireguard_valid_interface "$interface" || return 1
  service_file="$(wireguard_openrc_service_file "$interface")"
  wg_quick="$(command -v wg-quick)"
  cat >"$service_file" <<EOF
#!/sbin/openrc-run
name="Sbox WireGuard ${interface}"
description="Sbox managed WireGuard tunnel ${interface}"

start() {
  ebegin "Starting WireGuard ${interface}"
  ${wg_quick} up "$(wireguard_config_file "$interface")"
  eend \$?
}

stop() {
  ebegin "Stopping WireGuard ${interface}"
  ${wg_quick} down "$(wireguard_config_file "$interface")"
  eend \$?
}
EOF
  chmod 0755 "$service_file"
}

wireguard_profile_active() {
  local interface=$1
  wireguard_valid_interface "$interface" || return 1
  ip link show dev "$interface" >/dev/null 2>&1 && wg show "$interface" >/dev/null 2>&1
}

wireguard_start_profile() {
  local id=$1 interface role
  interface="$(wireguard_profile_field "$id" interface)"
  wireguard_valid_interface "$interface" || return 1
  role="$(wireguard_profile_field "$id" role)"
  if [[ "$role" == "landing" ]]; then
    prepare_managed_firewall || return 1
  fi
  write_wireguard_profile_config "$id" || return 1
  if has_systemd; then
    if [[ "$role" == "landing" ]]; then
      ensure_wireguard_systemd_firewall_ordering "$interface" || return 1
    fi
    systemctl enable "wg-quick@${interface}.service" >/dev/null 2>&1 || return 1
    if wireguard_profile_active "$interface"; then
      systemctl restart "wg-quick@${interface}.service" >/dev/null 2>&1 || return 1
    else
      systemctl start "wg-quick@${interface}.service" >/dev/null 2>&1 || return 1
    fi
  elif has_openrc; then
    ensure_wireguard_openrc_service "$interface" || return 1
    rc-update add "$(wireguard_service_name "$interface")" default >/dev/null 2>&1 || return 1
    if wireguard_profile_active "$interface"; then
      rc-service "$(wireguard_service_name "$interface")" restart >/dev/null 2>&1 || return 1
    else
      rc-service "$(wireguard_service_name "$interface")" start >/dev/null 2>&1 || return 1
    fi
  else
    return 1
  fi
  wireguard_profile_active "$interface" || return 1
  if [[ "$(wireguard_profile_field "$id" paired)" == "true" ]]; then
    wireguard_profile_route_ready "$id" || return 1
  fi
}

wireguard_stop_profile() {
  local id=$1 interface
  interface="$(wireguard_profile_field "$id" interface)"
  wireguard_valid_interface "$interface" || return 1
  if has_systemd; then
    systemctl disable --now "wg-quick@${interface}.service" >/dev/null 2>&1 || true
  elif has_openrc; then
    rc-service "$(wireguard_service_name "$interface")" stop >/dev/null 2>&1 || true
    rc-update del "$(wireguard_service_name "$interface")" default >/dev/null 2>&1 || true
  fi
  if wireguard_profile_active "$interface"; then
    wg-quick down "$(wireguard_config_file "$interface")" >/dev/null 2>&1 || ip link del dev "$interface" >/dev/null 2>&1 || true
  fi
}

wireguard_profile_route_ready() {
  local id=$1 interface peer_address
  interface="$(wireguard_profile_field "$id" interface)"
  peer_address="$(wireguard_profile_field "$id" peer_address)"
  wireguard_profile_active "$interface" || return 1
  ip route get "$peer_address" 2>/dev/null | head -n 1 | grep -Eq "(^|[[:space:]])dev[[:space:]]+${interface}([[:space:]]|$)"
}

wireguard_probe_tcp() {
  local host=$1 port=$2
  have_cmd timeout || return 1
  timeout 4 bash -c 'exec 3<>"/dev/tcp/${1}/${2}"' _ "$host" "$port" >/dev/null 2>&1
}

ensure_realm_wireguard_dependencies() {
  local id enabled paired role
  while IFS= read -r id; do
    id="${id%$'\r'}"
    [[ -n "$id" && "$id" != "null" ]] || return 1
    wireguard_profile_exists "$id" || return 1
    role="$(wireguard_profile_field "$id" role)"
    enabled="$(wireguard_profile_field "$id" enabled)"
    paired="$(wireguard_profile_field "$id" paired)"
    [[ "$role" == "relay" && "$enabled" == "true" && "$paired" == "true" ]] || return 1
    if ! wireguard_profile_route_ready "$id"; then
      wireguard_start_profile "$id" || return 1
      wireguard_profile_route_ready "$id" || return 1
    fi
  done < <(jq -r '.rules[]? | select(.mode == "wireguard") | .tunnel_id' "$REALM_STATE_FILE" | sort -u)
}

select_wireguard_profile() {
  local role_filter=${1:-any} choice index id name role interface paired
  local -a ids=() options=()
  while IFS=$'\t' read -r id name role interface paired; do
    [[ -n "$id" ]] || continue
    [[ "$role_filter" == "any" || "$role" == "$role_filter" ]] || continue
    ids+=("$id")
    options+=("${#ids[@]}" "${name}（${role}/${interface}，配对=${paired}）")
  done < <(jq -r '.wireguard.profiles[]? | [.id, .name, .role, .interface, (.paired | tostring)] | @tsv' "$REALM_STATE_FILE")
  if (( ${#ids[@]} == 0 )); then
    ui_msg "当前没有符合条件的 WireGuard 隧道。"
    return 1
  fi
  options+=("0" "返回")
  choice="$(ui_menu "WireGuard 隧道" "请选择隧道" "${options[@]}")" || return 1
  [[ "$choice" != "0" && "$choice" =~ ^[0-9]+$ ]] || return 1
  index=$((choice - 1))
  (( index >= 0 && index < ${#ids[@]} )) || return 1
  printf '%s\n' "${ids[$index]}"
}

wireguard_invitation_for_profile() {
  local id=$1 json
  json="$(jq -c --arg id "$id" '
    .wireguard.profiles[] | select(.id == $id) |
    {
      kind: "sbox-wireguard-invite-v1",
      tunnel_id: .id,
      name: .name,
      landing_public_key: .public_key,
      endpoint_host: .endpoint_host,
      endpoint_port: (.endpoint_port // .listen_port),
      relay_address: .peer_address,
      landing_address: .local_address,
      mtu: .mtu
    }
  ' "$REALM_STATE_FILE")" || return 1
  wireguard_encode_pairing_json "$json"
}

show_wireguard_landing_invitation() {
  local id invitation
  id="$(select_wireguard_profile landing)" || return 0
  invitation="$(wireguard_invitation_for_profile "$id")" || {
    ui_msg "无法生成该隧道的配对信息。"
    return 1
  }
  ui_show_text "WireGuard 落地端配对信息" "请在中转 VPS 的【加入隧道】中粘贴：

${invitation}

配对信息仅包含公钥、Endpoint 和私网地址，不包含私钥。"
}

create_wireguard_landing_profile() {
  local name endpoint_host endpoint_port listen_port allowed_source interface id addresses relay_address landing_address public_key invitation
  local error_count=0
  install_wireguard_tools || return 1
  ensure_wireguard_dirs
  init_realm_state_file
  name="$(realm_prompt_nonempty_limited error_count "WireGuard 落地端" "请输入隧道名称" "WG落地-$(( $(wireguard_profile_count) + 1 ))")" || return 1
  (( ${#name} <= 80 )) || { ui_msg "WireGuard 隧道名称不能超过 80 个字符。"; return 1; }
  endpoint_host="$(realm_prompt_nonempty_limited error_count "WireGuard 落地端" "请输入落地 VPS 公网 IP 或域名" "$(detect_public_address)")" || return 1
  wireguard_valid_endpoint_host "$endpoint_host" || { ui_msg "落地 Endpoint 地址无效。"; return 1; }
  listen_port="$(realm_prompt_number_limited error_count "WireGuard 落地端" "请输入本机 WireGuard UDP 监听端口" "$(generate_random_service_port)" 1024 65535)" || return 1
  endpoint_port="$(realm_prompt_number_limited error_count "WireGuard 落地端" "请输入公网 Endpoint UDP 端口；普通 VPS 与本机监听端口相同" "$listen_port" 1 65535)" || return 1
  if port_is_listening udp "$listen_port" || jq -e --argjson port "$listen_port" '.wireguard.profiles[]? | select(.role == "landing" and .listen_port == $port)' "$REALM_STATE_FILE" >/dev/null 2>&1; then
    ui_msg "UDP/${listen_port} 已被占用，请选择其他 WireGuard 监听端口。"
    return 1
  fi
  allowed_source="$(realm_prompt_nonempty_limited error_count "WireGuard 落地端" "请输入中转 VPS 公网来源 IP/CIDR" "")" || return 1
  wireguard_valid_allowed_source "$allowed_source" || { ui_msg "中转来源 IP/CIDR 无效；WireGuard 监听不允许设置为全网来源。"; return 1; }
  interface="$(wireguard_next_interface)" || { ui_msg "没有可用的 WireGuard 接口名称。"; return 1; }
  addresses="$(wireguard_generate_address_pair)" || { ui_msg "无法分配无冲突的 WireGuard 私网地址。"; return 1; }
  IFS=$'\t' read -r relay_address landing_address <<<"$addresses"
  id="wg-$(date +%s)-$(generate_hex 4)"
  wireguard_generate_keypair "$interface" || { ui_msg "WireGuard 密钥生成失败。"; return 1; }
  public_key="$(tr -d '\r\n' <"$(wireguard_public_key_file "$interface")")"
  if ! realm_state_jq --arg id "$id" --arg name "$name" --arg interface "$interface" --arg local "$landing_address" --arg peer "$relay_address" \
    --arg public_key "$public_key" --arg endpoint_host "$endpoint_host" --arg allowed_source "$allowed_source" --argjson listen_port "$listen_port" --argjson endpoint_port "$endpoint_port" --arg ts "$(utc_now)" '
      .wireguard.profiles += [{
        id: $id, name: $name, interface: $interface, role: "landing",
        local_address: $local, peer_address: $peer, public_key: $public_key,
        peer_public_key: "", endpoint_host: $endpoint_host, endpoint_port: $endpoint_port,
        listen_port: $listen_port, allowed_source: $allowed_source,
        mtu: 1420, persistent_keepalive: 25, enabled: true, paired: false
      }] |
      .meta.updated_at = $ts
    '; then
    rm -f "$(wireguard_private_key_file "$interface")" "$(wireguard_public_key_file "$interface")"
    ui_msg "WireGuard 状态写入失败。"
    return 1
  fi
  if ! prepare_managed_firewall || ! sync_managed_firewall_rules || ! wireguard_start_profile "$id"; then
    wireguard_stop_profile "$id"
    realm_state_jq --arg id "$id" '.wireguard.profiles |= map(select(.id != $id))' || true
    sync_managed_firewall_rules || true
    rm -f "$(wireguard_config_file "$interface")" "$(wireguard_private_key_file "$interface")" "$(wireguard_public_key_file "$interface")"
    rm -f "$(wireguard_systemd_dropin_dir "$interface")/10-sbox-firewall.conf" 2>/dev/null || true
    rmdir "$(wireguard_systemd_dropin_dir "$interface")" 2>/dev/null || true
    ui_msg "WireGuard 落地端启动失败，新增配置已撤销。"
    return 1
  fi
  invitation="$(wireguard_invitation_for_profile "$id")" || return 1
  ui_show_text "WireGuard 落地端已创建" "请在中转 VPS 选择【加入隧道（中转端）】并粘贴以下配对信息：

${invitation}

接口：${interface}
落地私网地址：${landing_address}
中转私网地址：${relay_address}
本机 UDP 监听：${listen_port}（仅允许 ${allowed_source}）
公网 Endpoint：${endpoint_host}:${endpoint_port}

配对信息不包含任何私钥。若云厂商另有安全组，请同时把公网 UDP/${endpoint_port} 映射或放行到本机 UDP/${listen_port}，来源限制为 ${allowed_source}。"
}

join_wireguard_relay_profile() {
  local code payload id name interface landing_public_key endpoint_host endpoint_port relay_address landing_address mtu public_key response addresses
  local error_count=0
  install_wireguard_tools || return 1
  ensure_wireguard_dirs
  init_realm_state_file
  code="$(realm_prompt_nonempty_limited error_count "WireGuard 中转端" "请粘贴落地端配对信息" "")" || return 1
  payload="$(wireguard_decode_pairing_code "$code")" || { ui_msg "WireGuard 配对信息无法解析。"; return 1; }
  [[ "$(jq -r '.kind // empty' <<<"$payload")" == "sbox-wireguard-invite-v1" ]] || { ui_msg "配对信息类型不正确。"; return 1; }
  id="$(jq -r '.tunnel_id // empty' <<<"$payload")"
  name="$(jq -r '.name // empty' <<<"$payload")"
  landing_public_key="$(jq -r '.landing_public_key // empty' <<<"$payload")"
  endpoint_host="$(jq -r '.endpoint_host // empty' <<<"$payload")"
  endpoint_port="$(jq -r '.endpoint_port // empty' <<<"$payload")"
  relay_address="$(jq -r '.relay_address // empty' <<<"$payload")"
  landing_address="$(jq -r '.landing_address // empty' <<<"$payload")"
  mtu="$(jq -r '.mtu // 1420' <<<"$payload")"
  if [[ ! "$id" =~ ^wg-[A-Za-z0-9-]+$ || ${#id} -gt 80 || -z "$name" || ${#name} -gt 80 ]] || wireguard_profile_exists "$id"; then
    ui_msg "隧道标识无效或已经存在。"
    return 1
  fi
  if ! wireguard_valid_key "$landing_public_key" || ! wireguard_valid_endpoint_host "$endpoint_host"; then
    ui_msg "配对信息中的公钥或 Endpoint 无效。"
    return 1
  fi
  if [[ ! "$endpoint_port" =~ ^[0-9]+$ ]] || (( endpoint_port < 1 || endpoint_port > 65535 )); then
    ui_msg "配对信息中的端口无效。"
    return 1
  fi
  wireguard_valid_address_pair "$relay_address" "$landing_address" || { ui_msg "配对信息中的私网地址无效。"; return 1; }
  if wireguard_address_pair_in_use "$relay_address" "$landing_address"; then
    addresses="$(wireguard_generate_address_pair)" || { ui_msg "配对地址冲突，且无法分配新的 WireGuard 私网地址。"; return 1; }
    IFS=$'\t' read -r relay_address landing_address <<<"$addresses"
    ui_msg "配对信息中的私网地址已被本机占用，已自动改用 ${relay_address}/32 和 ${landing_address}/32。"
  fi
  if [[ ! "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 1280 || mtu > 1500 )); then
    ui_msg "配对信息中的 MTU 无效。"
    return 1
  fi
  interface="$(wireguard_next_interface)" || { ui_msg "没有可用的 WireGuard 接口名称。"; return 1; }
  wireguard_generate_keypair "$interface" || { ui_msg "WireGuard 密钥生成失败。"; return 1; }
  public_key="$(tr -d '\r\n' <"$(wireguard_public_key_file "$interface")")"
  if ! realm_state_jq --arg id "$id" --arg name "$name" --arg interface "$interface" --arg local "$relay_address" --arg peer "$landing_address" \
    --arg public_key "$public_key" --arg peer_public_key "$landing_public_key" --arg endpoint_host "$endpoint_host" --argjson endpoint_port "$endpoint_port" --argjson mtu "$mtu" --arg ts "$(utc_now)" '
      .wireguard.profiles += [{
        id: $id, name: $name, interface: $interface, role: "relay",
        local_address: $local, peer_address: $peer, public_key: $public_key,
        peer_public_key: $peer_public_key, endpoint_host: $endpoint_host,
        endpoint_port: $endpoint_port, listen_port: null, allowed_source: null,
        mtu: $mtu, persistent_keepalive: 25, enabled: true, paired: true
      }] |
      .meta.updated_at = $ts
    '; then
    rm -f "$(wireguard_private_key_file "$interface")" "$(wireguard_public_key_file "$interface")"
    ui_msg "WireGuard 状态写入失败。"
    return 1
  fi
  if ! wireguard_start_profile "$id" || ! wireguard_profile_route_ready "$id"; then
    wireguard_stop_profile "$id"
    realm_state_jq --arg id "$id" '.wireguard.profiles |= map(select(.id != $id))' || true
    rm -f "$(wireguard_config_file "$interface")" "$(wireguard_private_key_file "$interface")" "$(wireguard_public_key_file "$interface")"
    ui_msg "WireGuard 中转端启动失败，新增配置已撤销。"
    return 1
  fi
  response="$(jq -nc --arg id "$id" --arg public_key "$public_key" --arg relay "$relay_address" --arg landing "$landing_address" '
    {kind:"sbox-wireguard-response-v1", tunnel_id:$id, relay_public_key:$public_key, relay_address:$relay, landing_address:$landing}
  ')"
  response="$(wireguard_encode_pairing_json "$response")"
  ui_show_text "WireGuard 中转端已加入" "请返回落地 VPS，选择【完成隧道配对（落地端）】并粘贴以下响应信息：

${response}

落地端完成配对前，当前隧道不会产生有效握手。"
}

complete_wireguard_landing_pairing() {
  local code payload id relay_public_key relay_address landing_address expected_relay expected_landing interface previous_state address_notice=""
  local error_count=0
  init_realm_state_file
  code="$(realm_prompt_nonempty_limited error_count "完成 WireGuard 配对" "请粘贴中转端响应信息" "")" || return 1
  payload="$(wireguard_decode_pairing_code "$code")" || { ui_msg "WireGuard 响应信息无法解析。"; return 1; }
  [[ "$(jq -r '.kind // empty' <<<"$payload")" == "sbox-wireguard-response-v1" ]] || { ui_msg "响应信息类型不正确。"; return 1; }
  id="$(jq -r '.tunnel_id // empty' <<<"$payload")"
  relay_public_key="$(jq -r '.relay_public_key // empty' <<<"$payload")"
  relay_address="$(jq -r '.relay_address // empty' <<<"$payload")"
  landing_address="$(jq -r '.landing_address // empty' <<<"$payload")"
  wireguard_profile_exists "$id" && [[ "$(wireguard_profile_field "$id" role)" == "landing" ]] || { ui_msg "找不到对应的落地端隧道。"; return 1; }
  wireguard_valid_key "$relay_public_key" || { ui_msg "中转端公钥无效。"; return 1; }
  if [[ "$(wireguard_profile_field "$id" paired)" == "true" ]] &&
    [[ "$(wireguard_profile_field "$id" peer_public_key)" != "$relay_public_key" ]]; then
    ui_yesno "该落地隧道已经配对。继续会替换原中转公钥并中断旧隧道，是否继续？" || return 0
  fi
  expected_relay="$(wireguard_profile_field "$id" peer_address)"
  expected_landing="$(wireguard_profile_field "$id" local_address)"
  interface="$(wireguard_profile_field "$id" interface)"
  wireguard_valid_address_pair "$relay_address" "$landing_address" || { ui_msg "响应中的隧道地址无效。"; return 1; }
  if wireguard_address_pair_in_use "$relay_address" "$landing_address" "$interface"; then
    ui_msg "中转端协商的 WireGuard 私网地址也被落地端其他接口占用，请删除该隧道后重新创建。"
    return 1
  fi
  if [[ "$relay_address" != "$expected_relay" || "$landing_address" != "$expected_landing" ]]; then
    address_notice="；私网地址已协商调整为 ${landing_address}/32 ↔ ${relay_address}/32"
  fi
  previous_state="$(snapshot_realm_state_file)" || return 1
  if ! realm_state_jq --arg id "$id" --arg peer_public_key "$relay_public_key" --arg relay_address "$relay_address" --arg landing_address "$landing_address" --arg ts "$(utc_now)" '
    (.wireguard.profiles[] | select(.id == $id)).peer_public_key = $peer_public_key |
    (.wireguard.profiles[] | select(.id == $id)).peer_address = $relay_address |
    (.wireguard.profiles[] | select(.id == $id)).local_address = $landing_address |
    (.wireguard.profiles[] | select(.id == $id)).paired = true |
    .meta.updated_at = $ts
  ' || ! wireguard_start_profile "$id"; then
    install -m 0600 "$previous_state" "$REALM_STATE_FILE" || true
    write_wireguard_profile_config "$id" || true
    wireguard_start_profile "$id" || true
    rm -f "$previous_state"
    ui_msg "完成 WireGuard 配对失败，已恢复原配置。"
    return 1
  fi
  rm -f "$previous_state"
  ui_msg "WireGuard 配对已完成。接口 ${interface} 已启动${address_notice}；请在中转端执行隧道测试，确认最近握手和目标端口均正常。Shadowsocks 等落地服务端口请在端口管理中统一管理。"
}

show_wireguard_profiles() {
  local output="" id name role interface local_address peer_address enabled paired active handshake now age references transfer
  init_realm_state_file
  if [[ "$(wireguard_profile_count)" -eq 0 ]]; then
    ui_msg "当前没有 WireGuard 隧道。"
    return 0
  fi
  now="$(date +%s)"
  while IFS=$'\t' read -r id name role interface local_address peer_address enabled paired; do
    active="未运行"
    handshake="无"
    transfer="0 / 0 bytes"
    if wireguard_profile_active "$interface"; then
      active="运行中"
      handshake="$(wg show "$interface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
      if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
        age=$((now - handshake))
        handshake="${age} 秒前"
      else
        handshake="尚未握手"
      fi
      transfer="$(wg show "$interface" transfer 2>/dev/null | awk 'NR==1 {print $2 " / " $3 " bytes"}')"
      transfer="${transfer:-0 / 0 bytes}"
    fi
    references="$(jq -r --arg id "$id" '[.rules[]? | select(.mode == "wireguard" and .tunnel_id == $id)] | length' "$REALM_STATE_FILE")"
    output+="${name} [${id}]\n  角色=${role}  接口=${interface}  状态=${active}  启用=${enabled}  配对=${paired}\n  ${local_address} -> ${peer_address}  最近握手=${handshake}\n  接收/发送=${transfer}  Realm 引用=${references}\n\n"
  done < <(jq -r '.wireguard.profiles[]? | [.id,.name,.role,.interface,.local_address,.peer_address,(.enabled|tostring),(.paired|tostring)] | @tsv' "$REALM_STATE_FILE")
  ui_show_text "WireGuard 隧道状态" "$(printf '%b' "$output")"
}

test_wireguard_profile() {
  local id interface peer_address port handshake now age output
  id="$(select_wireguard_profile any)" || return 0
  interface="$(wireguard_profile_field "$id" interface)"
  peer_address="$(wireguard_profile_field "$id" peer_address)"
  ping -c 1 -W 2 "$peer_address" >/dev/null 2>&1 || true
  if ! wireguard_profile_route_ready "$id"; then
    ui_msg "隧道接口或到 ${peer_address} 的 /32 路由不正常。"
    return 1
  fi
  handshake="$(wg show "$interface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ ! "$handshake" =~ ^[0-9]+$ || "$handshake" -eq 0 ]]; then
    ui_msg "接口和路由正常，但尚未产生有效 WireGuard 握手。请检查对端公钥、Endpoint 和 UDP 防火墙。"
    return 1
  fi
  now="$(date +%s)"
  age=$((now - handshake))
  output="接口和路由正常。\n最近握手：${age} 秒前。"
  port="$(ui_input "WireGuard 目标测试" "请输入要测试的对端 TCP 端口，输入 0 跳过" "0")" || return 1
  if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
    if wireguard_probe_tcp "$peer_address" "$port"; then
      output+="\n目标 ${peer_address}:${port} 可以连接。"
    else
      output+="\n目标 ${peer_address}:${port} 无法连接，请检查落地服务监听和防火墙。"
    fi
  fi
  ui_show_text "WireGuard 测试结果" "$(printf '%b' "$output")"
}

modify_wireguard_profile() {
  local id role name endpoint_host endpoint_port listen_port current_endpoint_port allowed_source mtu keepalive previous_state error_count=0
  local update_ok=true
  id="$(select_wireguard_profile any)" || return 0
  role="$(wireguard_profile_field "$id" role)"
  name="$(realm_prompt_nonempty_limited error_count "修改 WireGuard 隧道" "请输入隧道名称" "$(wireguard_profile_field "$id" name)")" || return 1
  (( ${#name} <= 80 )) || { ui_msg "WireGuard 隧道名称不能超过 80 个字符。"; return 1; }
  mtu="$(realm_prompt_number_limited error_count "修改 WireGuard 隧道" "请输入 MTU" "$(wireguard_profile_field "$id" mtu)" 1280 1500)" || return 1
  if [[ "$role" == "relay" ]]; then
    endpoint_host="$(realm_prompt_nonempty_limited error_count "修改 WireGuard 中转端" "请输入落地公网 IP 或域名" "$(wireguard_profile_field "$id" endpoint_host)")" || return 1
    wireguard_valid_endpoint_host "$endpoint_host" || { ui_msg "Endpoint 地址无效。"; return 1; }
    endpoint_port="$(realm_prompt_number_limited error_count "修改 WireGuard 中转端" "请输入落地 WireGuard UDP 端口" "$(wireguard_profile_field "$id" endpoint_port)" 1 65535)" || return 1
    keepalive="$(realm_prompt_number_limited error_count "修改 WireGuard 中转端" "请输入 PersistentKeepalive，0 表示关闭" "$(wireguard_profile_field "$id" persistent_keepalive)" 0 65535)" || return 1
  else
    endpoint_host="$(realm_prompt_nonempty_limited error_count "修改 WireGuard 落地端" "请输入本机公网 IP 或域名（用于后续配对信息）" "$(wireguard_profile_field "$id" endpoint_host)")" || return 1
    wireguard_valid_endpoint_host "$endpoint_host" || { ui_msg "Endpoint 地址无效。"; return 1; }
    listen_port="$(realm_prompt_number_limited error_count "修改 WireGuard 落地端" "请输入 WireGuard UDP 监听端口" "$(wireguard_profile_field "$id" listen_port)" 1 65535)" || return 1
    current_endpoint_port="$(wireguard_profile_field "$id" endpoint_port)"
    current_endpoint_port="${current_endpoint_port:-$listen_port}"
    endpoint_port="$(realm_prompt_number_limited error_count "修改 WireGuard 落地端" "请输入公网 Endpoint UDP 端口" "$current_endpoint_port" 1 65535)" || return 1
    if [[ "$listen_port" != "$(wireguard_profile_field "$id" listen_port)" ]] &&
      { port_is_listening udp "$listen_port" || jq -e --arg id "$id" --argjson port "$listen_port" '.wireguard.profiles[]? | select(.id != $id and .role == "landing" and .listen_port == $port)' "$REALM_STATE_FILE" >/dev/null 2>&1; }; then
      ui_msg "UDP/${listen_port} 已被占用。"
      return 1
    fi
    allowed_source="$(realm_prompt_nonempty_limited error_count "修改 WireGuard 落地端" "请输入中转 VPS 公网来源 IP/CIDR" "$(wireguard_profile_field "$id" allowed_source)")" || return 1
    wireguard_valid_allowed_source "$allowed_source" || { ui_msg "中转来源 IP/CIDR 无效；WireGuard 监听不允许设置为全网来源。"; return 1; }
  fi

  previous_state="$(snapshot_realm_state_file)" || return 1
  if [[ "$role" == "relay" ]]; then
    realm_state_jq --arg id "$id" --arg name "$name" --arg endpoint_host "$endpoint_host" --argjson endpoint_port "$endpoint_port" --argjson mtu "$mtu" --argjson keepalive "$keepalive" --arg ts "$(utc_now)" '
      (.wireguard.profiles[] | select(.id == $id)) |= (
        .name = $name | .endpoint_host = $endpoint_host | .endpoint_port = $endpoint_port |
        .mtu = $mtu | .persistent_keepalive = $keepalive
      ) | .meta.updated_at = $ts
    ' || update_ok=false
  else
    realm_state_jq --arg id "$id" --arg name "$name" --arg endpoint_host "$endpoint_host" --arg allowed_source "$allowed_source" --argjson listen_port "$listen_port" --argjson endpoint_port "$endpoint_port" --argjson mtu "$mtu" --arg ts "$(utc_now)" '
      (.wireguard.profiles[] | select(.id == $id)) |= (
        .name = $name | .endpoint_host = $endpoint_host | .listen_port = $listen_port |
        .endpoint_port = $endpoint_port | .allowed_source = $allowed_source | .mtu = $mtu
      ) | .meta.updated_at = $ts
    ' || update_ok=false
  fi

  if [[ "$update_ok" != "true" ]] || ! sync_managed_firewall_rules || ! wireguard_start_profile "$id"; then
    install -m 0600 "$previous_state" "$REALM_STATE_FILE" || true
    sync_managed_firewall_rules || true
    write_wireguard_profile_config "$id" || true
    wireguard_start_profile "$id" || true
    rm -f "$previous_state"
    ui_msg "WireGuard 修改失败，已恢复原配置。"
    return 1
  fi
  rm -f "$previous_state"
  ensure_realm_service || true
  ui_msg "WireGuard 隧道配置已更新。"
}

control_wireguard_profile() {
  local id action interface previous_state
  id="$(select_wireguard_profile any)" || return 0
  interface="$(wireguard_profile_field "$id" interface)"
  action="$(ui_menu "WireGuard 服务控制" "接口：${interface}" "1" "启动/重启" "2" "停止" "0" "返回")" || return 1
  case "$action" in
    1)
      previous_state="$(snapshot_realm_state_file)" || return 1
      if ! realm_state_jq --arg id "$id" '(.wireguard.profiles[] | select(.id == $id)).enabled = true' ||
        ! sync_managed_firewall_rules || ! wireguard_start_profile "$id"; then
        wireguard_stop_profile "$id"
        install -m 0600 "$previous_state" "$REALM_STATE_FILE" || true
        sync_managed_firewall_rules || true
        rm -f "$previous_state"
        ui_msg "WireGuard 隧道启动失败，已恢复原状态。"
        return 1
      fi
      rm -f "$previous_state"
      ensure_realm_service || true
      ui_msg "WireGuard 隧道已启动。"
      ;;
    2)
      if jq -e --arg id "$id" '.rules[]? | select(.mode == "wireguard" and .tunnel_id == $id)' "$REALM_STATE_FILE" >/dev/null 2>&1; then
        ui_yesno "该隧道仍被 Realm 规则引用，停止后相关转发会中断。是否继续？" || return 0
      fi
      previous_state="$(snapshot_realm_state_file)" || return 1
      wireguard_stop_profile "$id"
      if ! realm_state_jq --arg id "$id" '(.wireguard.profiles[] | select(.id == $id)).enabled = false' || ! sync_managed_firewall_rules; then
        install -m 0600 "$previous_state" "$REALM_STATE_FILE" || true
        sync_managed_firewall_rules || true
        wireguard_start_profile "$id" || true
        rm -f "$previous_state"
        ui_msg "WireGuard 隧道停止后的状态同步失败，已尝试恢复。"
        return 1
      fi
      rm -f "$previous_state"
      ensure_realm_service || true
      ui_msg "WireGuard 隧道已停止。"
      ;;
  esac
}

repair_wireguard_profiles() {
  local id enabled failed=false
  install_wireguard_tools || return 1
  ensure_wireguard_dirs
  init_realm_state_file
  sync_managed_firewall_rules || failed=true
  while IFS=$'\t' read -r id enabled; do
    [[ -n "$id" ]] || continue
    write_wireguard_profile_config "$id" || failed=true
    if [[ "$enabled" == "true" ]]; then
      wireguard_start_profile "$id" || failed=true
    fi
  done < <(jq -r '.wireguard.profiles[]? | [.id,(.enabled|tostring)] | @tsv' "$REALM_STATE_FILE")
  ensure_realm_service || failed=true
  if [[ "$failed" == "true" ]]; then
    ui_msg "WireGuard 修复未完全成功，请查看隧道状态和系统日志。"
    return 1
  fi
  ui_msg "WireGuard 工具、配置、服务和防火墙已修复。"
}

delete_wireguard_profile() {
  local id interface previous_state
  id="$(select_wireguard_profile any)" || return 0
  if jq -e --arg id "$id" '.rules[]? | select(.mode == "wireguard" and .tunnel_id == $id)' "$REALM_STATE_FILE" >/dev/null 2>&1; then
    ui_msg "该隧道仍被 Realm 转发规则引用。请先删除相关规则或将其改为直接转发。"
    return 1
  fi
  interface="$(wireguard_profile_field "$id" interface)"
  wireguard_valid_interface "$interface" || { ui_msg "隧道接口名称无效，已拒绝删除。"; return 1; }
  ui_yesno "确定删除 WireGuard 隧道 ${interface}？本机密钥将一并删除。" || return 0
  previous_state="$(snapshot_realm_state_file)" || return 1
  wireguard_stop_profile "$id"
  if ! realm_state_jq --arg id "$id" --arg ts "$(utc_now)" '.wireguard.profiles |= map(select(.id != $id)) | .meta.updated_at = $ts' ||
    ! sync_managed_firewall_rules; then
    install -m 0600 "$previous_state" "$REALM_STATE_FILE" || true
    sync_managed_firewall_rules || true
    wireguard_start_profile "$id" || true
    rm -f "$previous_state"
    ui_msg "WireGuard 删除失败，已恢复原隧道和防火墙。"
    return 1
  fi
  rm -f "$previous_state"
  rm -f "$(wireguard_config_file "$interface")" "$(wireguard_private_key_file "$interface")" "$(wireguard_public_key_file "$interface")" "$(wireguard_openrc_service_file "$interface")"
  rm -f "$(wireguard_systemd_dropin_dir "$interface")/10-sbox-firewall.conf" 2>/dev/null || true
  rmdir "$(wireguard_systemd_dropin_dir "$interface")" 2>/dev/null || true
  ui_msg "WireGuard 隧道已删除。"
}

remove_all_managed_wireguard_profiles() {
  local id interface
  [[ -s "$REALM_STATE_FILE" ]] || return 0
  while IFS=$'\t' read -r id interface; do
    [[ -n "$id" && -n "$interface" ]] || continue
    wireguard_valid_interface "$interface" || return 1
    wireguard_stop_profile "$id"
    rm -f "$(wireguard_config_file "$interface")" "$(wireguard_private_key_file "$interface")" \
      "$(wireguard_public_key_file "$interface")" "$(wireguard_openrc_service_file "$interface")"
    rm -f "$(wireguard_systemd_dropin_dir "$interface")/10-sbox-firewall.conf" 2>/dev/null || true
    rmdir "$(wireguard_systemd_dropin_dir "$interface")" 2>/dev/null || true
    if has_systemd; then
      systemctl reset-failed "wg-quick@${interface}.service" >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.wireguard.profiles[]? | [.id,.interface] | @tsv' "$REALM_STATE_FILE")
  realm_state_jq '.wireguard.profiles = []' || return 1
}

wireguard_submenu() {
  local choice
  while true; do
    choice="$(ui_menu "WireGuard 隧道管理" "隧道数量：$(wireguard_profile_count)" \
      "1" "创建隧道（落地端）" \
      "2" "加入隧道（中转端）" \
      "3" "完成隧道配对（落地端）" \
      "4" "重新显示落地端配对信息" \
      "5" "查看隧道列表和状态" \
      "6" "测试隧道连通性" \
      "7" "修改隧道" \
      "8" "启动 / 停止 / 重启隧道" \
      "9" "修复 WireGuard 环境" \
      "10" "删除隧道" \
      "0" "返回")" || continue
    case "$choice" in
      1) create_wireguard_landing_profile || true ;;
      2) join_wireguard_relay_profile || true ;;
      3) complete_wireguard_landing_pairing || true ;;
      4) show_wireguard_landing_invitation || true ;;
      5) show_wireguard_profiles || true ;;
      6) test_wireguard_profile || true ;;
      7) modify_wireguard_profile || true ;;
      8) control_wireguard_profile || true ;;
      9) repair_wireguard_profiles || true ;;
      10) delete_wireguard_profile || true ;;
      0) return 0 ;;
    esac
  done
}

realm_rule_group_count() {
  realm_state_get '.rules | length'
}

realm_managed_ports() {
  local state_file=${1:-$REALM_STATE_FILE}
  jq -r '
    .rules[]?.entries[]?.listen
    | try capture(":(?<port>[0-9]+)$").port catch empty
  ' "$state_file" | sort -un
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
    listen="${listen%$'\r'}"
    remote="${remote%$'\r'}"
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
  tmp_config="$(mktemp "$TMP_DIR/realm-config.XXXXXX")" || return 1
  if ! render_realm_config >"$tmp_config" ||
    ! install -o root -g "$RUNTIME_GROUP" -m 0640 "$tmp_config" "$REALM_CONFIG_FILE"; then
    rm -f "$tmp_config"
    return 1
  fi
  rm -f "$tmp_config"
}

realm_remove_udp_firewall_rules() {
  local port firewalld_changed=false

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue

    if have_cmd ufw; then
      ufw --force delete allow "${port}/udp" >/dev/null 2>&1 || true
    fi

    if have_cmd firewall-cmd && has_systemd && systemctl is-active firewalld >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1 || true
      firewalld_changed=true
    fi

    remove_iptables_port "$port" udp
  done < <(realm_managed_ports)

  if [[ "$firewalld_changed" == "true" ]]; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  persist_openrc_firewall_rules
}

migrate_realm_tcp_only() {
  if [[ ! -s "$REALM_STATE_FILE" ]]; then
    initialize_managed_firewall_state
    return 0
  fi

  if ! jq -e . "$REALM_STATE_FILE" >/dev/null 2>&1; then
    warn "Realm 状态文件无效，已跳过 TCP-only 迁移：$REALM_STATE_FILE"
    return 1
  fi

  if jq -e '
    (.global.use_udp? == false)
    and (.meta.realm_tcp_only_migrated? == true)
  ' "$REALM_STATE_FILE" >/dev/null 2>&1; then
    initialize_managed_firewall_state
    return 0
  fi

  ensure_runtime_account
  realm_state_jq --arg version "$SCRIPT_VERSION" --arg ts "$(utc_now)" '
    .global = (.global // {}) |
    .global.use_udp = false |
    .global.no_tcp = (.global.no_tcp // false) |
    .meta = (.meta // {}) |
    .meta.version = $version |
    .meta.updated_at = $ts |
    del(.meta.realm_tcp_only_migrated)
  '

  if ! write_realm_config_file; then
    warn "写入 Realm TCP-only 配置失败，下次运行脚本时将自动重试。"
    return 1
  fi

  realm_remove_udp_firewall_rules

  if realm_service_exists && [[ "$(realm_service_active)" == "active" ]]; then
    if ! restart_realm_service_raw >/dev/null 2>&1; then
      warn "关闭 UDP 后重启 Realm 失败，下次运行脚本时将自动重试。"
      return 1
    fi
  fi

  realm_state_jq --arg ts "$(utc_now)" '
    .meta.realm_tcp_only_migrated = true |
    .meta.updated_at = $ts
  '

  log "Realm TCP-only 迁移完成：已关闭 UDP 转发并清理脚本管理的 UDP 防火墙规则。"
  warn "如果 VPS 商家另有云防火墙或安全组，请同时删除其中的 Realm UDP 端口。"
  initialize_managed_firewall_state
}

realm_apply_firewall_rules() {
  realm_remove_udp_firewall_rules
  sync_managed_firewall_rules
}

preflight_realm_config() {
  local rendered_config preflight_config output status
  [[ "$(realm_rule_group_count)" -gt 0 ]] || return 0
  have_cmd timeout || {
    warn "缺少 timeout 命令，无法在切换前预检 Realm 配置。"
    return 1
  }

  rendered_config="$(mktemp "$TMP_DIR/realm-rendered.XXXXXX")" || return 1
  preflight_config="$(mktemp "$TMP_DIR/realm-preflight.XXXXXX")" || {
    rm -f "$rendered_config"
    return 1
  }
  if ! render_realm_config >"$rendered_config" ||
    ! sed -E 's/^listen = ".*"$/listen = "127.0.0.1:0"/' "$rendered_config" >"$preflight_config" ||
    ! chown root:"$RUNTIME_GROUP" "$preflight_config" ||
    ! chmod 0640 "$preflight_config"; then
    rm -f "$rendered_config" "$preflight_config"
    return 1
  fi

  if output="$(run_as_runtime timeout 2 "$REALM_BIN" -c "$preflight_config" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  rm -f "$rendered_config" "$preflight_config"

  if [[ "$status" -eq 124 ]]; then
    return 0
  fi
  warn "Realm 新配置预检失败：${output:-未知错误}"
  return 1
}

verify_realm_service_ready() {
  local port ready
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ready=true
    if ! realm_service_exists || [[ "$(realm_service_active)" != "active" ]]; then
      ready=false
    fi
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      port_is_listening tcp "$port" || ready=false
    done < <(realm_managed_ports)
    if [[ "$ready" == "true" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

restore_realm_transaction() {
  local previous_state_file=$1 previous_config_file=$2 previous_config_existed=$3
  local realm_was_active=$4 config_was_switched=$5 restored=true

  install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || restored=false
  if [[ "$config_was_switched" == "true" ]]; then
    if [[ "$previous_config_existed" == "true" ]]; then
      install -o root -g "$RUNTIME_GROUP" -m 0640 "$previous_config_file" "$REALM_CONFIG_FILE" || restored=false
    else
      rm -f "$REALM_CONFIG_FILE" || restored=false
    fi
  fi
  sync_managed_firewall_rules || restored=false

  if [[ "$config_was_switched" == "true" ]]; then
    if [[ "$realm_was_active" == "true" ]]; then
      if realm_service_exists && [[ "$(realm_service_active)" == "active" ]]; then
        restart_realm_service_raw >/dev/null 2>&1 || restored=false
      else
        start_realm_service_raw >/dev/null 2>&1 || restored=false
      fi
      verify_realm_service_ready || restored=false
    elif realm_service_exists && [[ "$(realm_service_active)" == "active" ]]; then
      stop_realm_service_raw >/dev/null 2>&1 || restored=false
    fi
  fi

  [[ "$restored" == "true" ]]
}

apply_realm_config() {
  local previous_state_file=${1:-}
  local rule_count message port_error realm_was_active=false
  local previous_config_file previous_config_existed=false config_was_switched=false rollback_ok=true

  if [[ -z "$previous_state_file" || ! -s "$previous_state_file" ]]; then
    ui_msg "缺少 Realm 变更前状态，已拒绝执行不可回滚的配置切换。"
    return 1
  fi
  if ! ensure_realm_dirs || ! init_realm_state_file || ! ensure_realm_service; then
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    rm -f "$previous_state_file"
    ui_msg "准备 Realm 服务环境失败，变更已撤销。"
    return 1
  fi
  previous_config_file="$(mktemp "$TMP_DIR/realm-config-backup.XXXXXX")" || {
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    rm -f "$previous_state_file"
    ui_msg "无法创建 Realm 配置备份，变更已撤销。"
    return 1
  }
  if [[ -f "$REALM_CONFIG_FILE" ]]; then
    if ! cp "$REALM_CONFIG_FILE" "$previous_config_file"; then
      install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
      rm -f "$previous_state_file" "$previous_config_file"
      ui_msg "无法备份 Realm 现有配置，变更已撤销。"
      return 1
    fi
    previous_config_existed=true
  fi
  if realm_service_exists && [[ "$(realm_service_active)" == "active" ]]; then
    realm_was_active=true
  fi

  if ! prepare_managed_firewall; then
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    rm -f "$previous_state_file" "$previous_config_file"
    ui_msg "防火墙环境不可用，Realm 变更已撤销、现有服务未停止。请执行 sbox repair-install 后重试。"
    return 1
  fi

  if ! ensure_realm_wireguard_dependencies; then
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    ensure_realm_service || true
    rm -f "$previous_state_file" "$previous_config_file"
    ui_msg "Realm 变更已撤销：关联的 WireGuard 隧道未配对、未启用，或接口和 /32 路由不可用。"
    return 1
  fi

  if ! port_error="$(validate_realm_listener_ports_available "$previous_state_file" "$realm_was_active")"; then
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    rm -f "$previous_state_file" "$previous_config_file"
    ui_msg "Realm 变更已撤销，现有服务和防火墙未修改。${port_error}"
    return 1
  fi

  rule_count="$(realm_rule_group_count)"
  if [[ "$rule_count" -gt 0 ]] && ! preflight_realm_config; then
    install -m 0600 "$previous_state_file" "$REALM_STATE_FILE" || true
    rm -f "$previous_state_file" "$previous_config_file"
    ui_msg "Realm 新配置预检失败，变更已撤销，原服务保持运行。"
    return 1
  fi

  if ! realm_apply_firewall_rules; then
    restore_realm_transaction "$previous_state_file" "$previous_config_file" "$previous_config_existed" "$realm_was_active" false || rollback_ok=false
    rm -f "$previous_state_file" "$previous_config_file"
    if [[ "$rollback_ok" == "true" ]]; then
      ui_msg "Realm 防火墙同步失败，变更已自动撤销，原服务仍在运行。"
    else
      ui_msg "Realm 防火墙同步失败，且自动恢复未完全成功；请立即查看 sbox-firewall 状态。"
    fi
    return 1
  fi

  if ! write_realm_config_file; then
    restore_realm_transaction "$previous_state_file" "$previous_config_file" "$previous_config_existed" "$realm_was_active" false || rollback_ok=false
    rm -f "$previous_state_file" "$previous_config_file"
    if [[ "$rollback_ok" == "true" ]]; then
      ui_msg "Realm 配置写入失败，变更已自动撤销，原服务未停止。"
    else
      ui_msg "Realm 配置写入失败，且防火墙自动恢复未完全成功。"
    fi
    return 1
  fi
  config_was_switched=true

  if [[ "$rule_count" -eq 0 ]]; then
    if realm_service_exists && ! stop_realm_service_raw >/dev/null 2>&1; then
      restore_realm_transaction "$previous_state_file" "$previous_config_file" "$previous_config_existed" "$realm_was_active" "$config_was_switched" || rollback_ok=false
      rm -f "$previous_state_file" "$previous_config_file"
      ui_msg "Realm 停止失败，删除操作已回滚。"
      return 1
    fi
    rm -f "$previous_state_file" "$previous_config_file"
    ui_msg "Realm 当前没有任何转发规则，配置已保存，服务已停止。"
    return 0
  fi

  enable_realm_service
  if [[ "$realm_was_active" == "true" ]]; then
    if restart_realm_service_raw >/dev/null 2>&1 && verify_realm_service_ready; then
      message="Realm 配置已保存到 ${REALM_CONFIG_FILE}，服务已重启。"
    else
      restore_realm_transaction "$previous_state_file" "$previous_config_file" "$previous_config_existed" "$realm_was_active" "$config_was_switched" || rollback_ok=false
      rm -f "$previous_state_file" "$previous_config_file"
      ui_show_text "Realm 新配置启动失败，已自动恢复旧配置" "$(realm_recent_logs)"
      return 1
    fi
  elif start_realm_service_raw >/dev/null 2>&1 && verify_realm_service_ready; then
    message="Realm 配置已保存到 ${REALM_CONFIG_FILE}，服务已自动启动。"
  else
    restore_realm_transaction "$previous_state_file" "$previous_config_file" "$previous_config_existed" "$realm_was_active" "$config_was_switched" || rollback_ok=false
    rm -f "$previous_state_file" "$previous_config_file"
    ui_show_text "Realm 新配置启动失败，已自动恢复旧配置" "$(realm_recent_logs)"
    return 1
  fi

  rm -f "$previous_state_file" "$previous_config_file"
  ui_msg "$message"
}

apply_current_realm_state() {
  local previous_state_file
  previous_state_file="$(snapshot_realm_state_file)" || {
    ui_msg "无法创建 Realm 状态快照，未执行配置切换。"
    return 1
  }
  apply_realm_config "$previous_state_file"
}

write_client_exports() {
  local all_file server_address host links_file node_name link display_name
  all_file="$CLIENT_DIR/all-clients.txt"
  server_address="$(state_get '.meta.server_address')"
  host="$(format_uri_host "$server_address")"
  node_name="$(state_get '.meta.node_name')"
  links_file="$(direct_links_file)"
  display_name="${node_name:-我的节点}"

  : >"$all_file"
  : >"$links_file"
  rm -f "$CLIENT_DIR"/shadowsocks/*.txt "$CLIENT_DIR"/vless-reality/*.txt "$CLIENT_DIR"/hysteria2/*.txt 2>/dev/null || true

  if [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]]; then
    local ss_port ss_method ss_server_password ss_share_password
    ss_port="$(state_get '.protocols.shadowsocks.port')"
    ss_method="$(state_get '.protocols.shadowsocks.method')"
    ss_server_password="$(state_get '.protocols.shadowsocks.server_password')"

    while IFS=$'\t' read -r name user_password; do
      [[ -n "$name" ]] || continue
      ss_share_password="$(shadowsocks_share_password "$ss_method" "$ss_server_password" "$user_password")"
      cat >"$CLIENT_DIR/shadowsocks/${name}.txt" <<EOF
[Shadowsocks]
name = $display_name
server = $server_address
port = $ss_port
method = $ss_method
password = $ss_share_password
network = tcp
multiplex = true
EOF
      # Shadowrocket compatibility: encode method:password as one Base64URL userinfo token.
      link="ss://$(base64_urlsafe "${ss_method}:${ss_share_password}")@${host}:${ss_port}#$(uri_encode "$display_name")"
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
server_core = $(state_get '.protocols.vless_reality.core // "sing-box"')
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

  chmod 0600 "$all_file" "$links_file"
  find "$CLIENT_DIR/shadowsocks" "$CLIENT_DIR/vless-reality" "$CLIENT_DIR/hysteria2" \
    -maxdepth 1 -type f -name '*.txt' -exec chmod 0600 {} +

}

restore_managed_runtime_configs() {
  local sing_snapshot=$1 sing_existed=$2 xray_snapshot=$3 xray_existed=$4
  local sing_was_active=$5 xray_was_active=$6

  stop_sing_box
  stop_xray
  if [[ "$sing_existed" == "true" ]]; then
    install -o root -g "$RUNTIME_GROUP" -m 0640 "$sing_snapshot" "$CONFIG_FILE"
  else
    rm -f "$CONFIG_FILE"
  fi
  if [[ "$xray_existed" == "true" ]]; then
    install -o root -g "$RUNTIME_GROUP" -m 0640 "$xray_snapshot" "$XRAY_CONFIG_FILE"
  else
    rm -f "$XRAY_CONFIG_FILE"
  fi
  if [[ "$sing_was_active" == "true" ]]; then
    restart_sing_box >/dev/null 2>&1 || warn "sing-box 原服务未能自动恢复，请查看日志。"
  fi
  if [[ "$xray_was_active" == "true" ]]; then
    restart_xray >/dev/null 2>&1 || warn "Xray 原服务未能自动恢复，请查看日志。"
  fi
}

cleanup_apply_temp_configs() {
  local sing_config=${1:-} xray_config=${2:-} xray_dir=${3:-}
  [[ -z "$sing_config" ]] || rm -f "$sing_config"
  [[ -z "$xray_config" ]] || rm -f "$xray_config"
  [[ -z "$xray_dir" ]] || cleanup_xray_work_dir "$xray_dir"
}

apply_config() {
  local enabled_count sing_count tmp_config="" tmp_xray_config="" tmp_xray_dir="" check_output success_text links_file check_bin port_error
  local sing_snapshot xray_snapshot
  local service_was_active=false xray_was_active=false sing_config_existed=false xray_config_existed=false

  sing_count="$(sing_box_protocol_count)"
  if xray_protocol_enabled; then
    install_xray_core
    ensure_xray_service || {
      ui_msg "Xray 服务准备失败，配置未应用。"
      return 1
    }
  fi
  if [[ "$sing_count" -gt 0 ]]; then
    ensure_sing_box_service
  fi
  ensure_rule_set_cache_dir || {
    ui_msg "无法准备远程规则集缓存目录，配置未应用。"
    return 1
  }
  enabled_count="$(enabled_protocol_count)"

  if ! prepare_managed_firewall; then
    ui_msg "防火墙环境准备失败，配置未应用、现有服务未停止。请根据上方具体错误处理后重试。"
    return 1
  fi

  if [[ "$enabled_count" -eq 0 ]]; then
    stop_sing_box
    stop_xray
    disable_sing_box_service
    disable_xray_service
    write_client_exports
    if ! sync_managed_firewall_rules; then
      ui_msg "节点已停止，但清理防火墙规则失败，请进入端口管理重试。"
      return 1
    fi
    rm -f "$CONFIG_FILE" "$XRAY_CONFIG_FILE"
    ui_msg "当前没有启用任何协议，sing-box 与 Xray 服务已停止。"
    return 0
  fi

  ensure_socket_inspection_command
  normalize_protocol_listen_addresses
  validate_state || return 1

  if [[ "$sing_count" -gt 0 ]]; then
    tmp_config="$(mktemp "$TMP_DIR/singbox-config.XXXXXX")" || {
      ui_msg "无法创建 sing-box 临时配置文件。"
      return 1
    }
    render_config >"$tmp_config"
    chown root:"$RUNTIME_GROUP" "$tmp_config"
    chmod 0640 "$tmp_config"
    check_bin="$(sing_box_check_bin 2>/dev/null || true)"
    if [[ -z "$check_bin" ]]; then
      rm -f "$tmp_config"
      ui_msg "未找到可用的 sing-box 配置检查程序，已拒绝替换配置。"
      return 1
    fi
    if ! check_output="$(run_as_runtime "$check_bin" check -c "$tmp_config" 2>&1)"; then
      rm -f "$tmp_config"
      ui_show_text "sing-box 配置检查失败" "$check_output"
      return 1
    fi
  fi

  if xray_protocol_enabled; then
    tmp_xray_dir="$(mktemp -d "$TMP_DIR/sbox-xray.XXXXXX")" || {
      rm -f "$tmp_config"
      ui_msg "无法创建 Xray 临时配置目录。"
      return 1
    }
    tmp_xray_config="$tmp_xray_dir/config.json"
    render_xray_config >"$tmp_xray_config"
    chown root:"$RUNTIME_GROUP" "$tmp_xray_dir"
    chmod 0750 "$tmp_xray_dir"
    chown root:"$RUNTIME_GROUP" "$tmp_xray_config"
    chmod 0640 "$tmp_xray_config"
    if ! check_output="$(run_as_runtime env XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp_xray_config" 2>&1)"; then
      cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"
      ui_show_text "Xray 配置检查失败" "$check_output"
      return 1
    fi
  fi

  sing_snapshot="$(mktemp "$TMP_DIR/singbox-config-backup.XXXXXX")" || {
    cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"
    return 1
  }
  xray_snapshot="$(mktemp "$TMP_DIR/xray-config-backup.XXXXXX")" || {
    cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"
    rm -f "$sing_snapshot"
    return 1
  }
  if [[ -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$CONFIG_FILE" "$sing_snapshot"
    sing_config_existed=true
  fi
  if [[ -f "$XRAY_CONFIG_FILE" ]]; then
    install -m 0600 "$XRAY_CONFIG_FILE" "$xray_snapshot"
    xray_config_existed=true
  fi

  if service_exists && [[ "$(sing_box_service_active 2>/dev/null || true)" == "active" ]]; then
    service_was_active=true
  fi
  if xray_service_exists && [[ "$(xray_service_active 2>/dev/null || true)" == "active" ]]; then
    xray_was_active=true
  fi
  stop_sing_box
  stop_xray
  if ! port_error="$(validate_sing_box_listener_ports_available)"; then
    cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"
    restore_managed_runtime_configs "$sing_snapshot" "$sing_config_existed" "$xray_snapshot" "$xray_config_existed" "$service_was_active" "$xray_was_active"
    rm -f "$sing_snapshot" "$xray_snapshot"
    ui_msg "配置未应用，防火墙未修改。${port_error}"
    return 1
  fi
  if ! apply_firewall_rules; then
    cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"
    restore_managed_runtime_configs "$sing_snapshot" "$sing_config_existed" "$xray_snapshot" "$xray_config_existed" "$service_was_active" "$xray_was_active"
    rm -f "$sing_snapshot" "$xray_snapshot"
    ui_msg "防火墙规则同步失败；原配置和原服务状态已恢复。"
    return 1
  fi

  if [[ "$sing_count" -gt 0 ]]; then
    backup_config_if_exists
    install -o root -g "$RUNTIME_GROUP" -m 0640 "$tmp_config" "$CONFIG_FILE"
  fi
  if xray_protocol_enabled; then
    if [[ -f "$XRAY_CONFIG_FILE" ]]; then
      install -m 0600 "$XRAY_CONFIG_FILE" "$BACKUP_DIR/xray-config-$(date +%Y%m%d-%H%M%S).json"
    fi
    install -o root -g "$RUNTIME_GROUP" -m 0640 "$tmp_xray_config" "$XRAY_CONFIG_FILE"
  fi
  cleanup_apply_temp_configs "$tmp_config" "$tmp_xray_config" "$tmp_xray_dir"

  if [[ "$sing_count" -gt 0 ]]; then
    if ! restart_sing_box || ! verify_sing_box_service_ready; then
      restore_managed_runtime_configs "$sing_snapshot" "$sing_config_existed" "$xray_snapshot" "$xray_config_existed" "$service_was_active" "$xray_was_active"
      rm -f "$sing_snapshot" "$xray_snapshot"
      ui_show_text "sing-box 启动失败，原运行配置已恢复" "$(sing_box_recent_logs)"
      return 1
    fi
  else
    stop_sing_box
    disable_sing_box_service
  fi

  if xray_protocol_enabled; then
    if ! restart_xray || ! verify_xray_service_ready; then
      restore_managed_runtime_configs "$sing_snapshot" "$sing_config_existed" "$xray_snapshot" "$xray_config_existed" "$service_was_active" "$xray_was_active"
      rm -f "$sing_snapshot" "$xray_snapshot"
      ui_show_text "Xray 启动失败，原运行配置已恢复" "$(xray_recent_logs)"
      return 1
    fi
  else
    stop_xray
    disable_xray_service
  fi

  if [[ "$sing_count" -eq 0 ]]; then
    rm -f "$CONFIG_FILE"
  fi
  if ! xray_protocol_enabled; then
    rm -f "$XRAY_CONFIG_FILE"
  fi
  rm -f "$sing_snapshot" "$xray_snapshot"
  write_client_exports
  if [[ "$sing_count" -gt 0 ]] && ! verify_sing_box_service_ready; then
    ui_show_text "sing-box 启动后未能建立全部监听端口" "$(sing_box_recent_logs)"
    return 1
  fi

  success_text="配置已通过内核预检并完成服务切换。客户端信息已导出到 $CLIENT_DIR。"
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
  normalize_protocol_listen_addresses
  if [[ "$(enabled_protocol_count)" -eq 0 ]]; then
    stop_sing_box
    disable_sing_box_service
  fi
  ensure_firewall_restore_service || {
    ui_msg "防火墙开机恢复服务安装失败，请修复 systemd 后重试。"
    return 1
  }
  ui_msg "基础环境安装完成，请继续在面板中按需启用并配置协议。"
}

repair_install() {
  local manager_target
  require_linux
  require_root
  if is_interactive; then
    export SBOX_REPAIR_OPEN_PANEL="${SBOX_REPAIR_OPEN_PANEL:-1}"
  fi
  ensure_dirs
  init_state_file
  install_dependencies

  manager_target="$MANAGER_SCRIPT_PATH"
  log "repair-install 将使用当前已安装脚本修复核心、权限、服务和配置；如需更新脚本，请在面板选择 [更新脚本]。"

  install_sing_box
  if [[ -x "$REALM_BIN" ]]; then
    repair_realm_binary_compatibility || return 1
    ensure_realm_service
  fi
  ensure_firewall_restore_service || {
    ui_msg "防火墙开机恢复服务安装失败，请修复 systemd 后重试。"
    return 1
  }
  apply_config || return 1
  ui_msg "重新安装 / 修复完成。原有节点、客户端和分流规则已保留。"

  if [[ "${SBOX_REPAIR_OPEN_PANEL:-0}" == "1" && -x "$manager_target" ]]; then
    exec "$manager_target"
  fi
}

configure_shadowsocks() {
  local vless_port port server_password listen_addr method

  prompt_node_name_for_protocol || return 1

  vless_port="$(state_get '.protocols.vless_reality.port')"
  port="$(prompt_number "Shadowsocks 端口" "请输入 Shadowsocks 监听端口" "$(generate_random_service_port_excluding "$vless_port")" 1 65535)" || return 1
  method="$(select_shadowsocks_method "$(state_get '.protocols.shadowsocks.method // "2022-blake3-aes-128-gcm"')")" || return 1
  server_password="$(generate_shadowsocks_password "$method")"
  listen_addr="$(default_listen_address)"

  state_jq --argjson port "$port" --arg method "$method" --arg server_password "$server_password" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = $listen_addr |
    .protocols.shadowsocks.port = $port |
    .protocols.shadowsocks.network = "tcp" |
    .protocols.shadowsocks.method = $method |
    .protocols.shadowsocks.server_password = $server_password |
    .protocols.shadowsocks.multiplex = true |
    del(.protocols.shadowsocks.allowed_sources) |
    .meta.updated_at = $ts
  '

  if [[ "$(state_get '.protocols.shadowsocks.users | length')" -eq 0 ]]; then
    append_ss_user "ss-client-1" "$(generate_shadowsocks_password "$method")"
  else
    reset_ss_user_passwords_for_method "$method"
  fi

  apply_config
}

select_reality_sni_default() {
  local current_sni=${1:-}
  local include_current=${2:-false}
  local region_choice japan_choice

  while true; do
    if [[ "$include_current" == "true" && -n "$current_sni" && "$current_sni" != "null" ]]; then
      region_choice="$(ui_menu "Reality SNI 地区" "请选择与服务器所在地区匹配的默认伪装域名；选定后仍可手动修改。" \
        "1" "美西（www.cartoonbrew.com）" \
        "2" "香港（ani-com.hk）" \
        "3" "日本" \
        "4" "其他地区（www.tesla.com）" \
        "5" "保持当前 SNI（${current_sni}）" \
        "0" "返回")" || return 1
    else
      region_choice="$(ui_menu "Reality SNI 地区" "请选择与服务器所在地区匹配的默认伪装域名；选定后仍可手动修改。" \
        "1" "美西（www.cartoonbrew.com）" \
        "2" "香港（ani-com.hk）" \
        "3" "日本" \
        "4" "其他地区（www.tesla.com）" \
        "0" "返回")" || return 1
    fi

    case "$region_choice" in
      1)
        printf 'www.cartoonbrew.com\n'
        return 0
        ;;
      2)
        printf 'ani-com.hk\n'
        return 0
        ;;
      3)
        japan_choice="$(ui_menu "日本 Reality SNI" "请选择日本地区使用的默认伪装域名。" \
          "1" "shin-ei-animation.jp（默认）" \
          "2" "www.ritao.co（阿里精品）" \
          "0" "返回地区选择")" || return 1
        case "$japan_choice" in
          1)
            printf 'shin-ei-animation.jp\n'
            return 0
            ;;
          2)
            printf 'www.ritao.co\n'
            return 0
            ;;
          0) continue ;;
          *) return 1 ;;
        esac
        ;;
      4)
        printf 'www.tesla.com\n'
        return 0
        ;;
      5)
        if [[ "$include_current" == "true" && -n "$current_sni" && "$current_sni" != "null" ]]; then
          printf '%s\n' "$current_sni"
          return 0
        fi
        return 1
        ;;
      0) return 1 ;;
      *) return 1 ;;
    esac
  done
}

configure_vless_reality() {
  local core_choice core ss_port port selected_sni sni handshake_port keypair private_key public_key short_id listen_addr previous_state_file
  local default_port default_sni default_handshake_port vless_enabled

  core_choice="$(ui_menu "VLESS + Reality 内核" "两种内核使用相同的端口、Reality 参数、客户端和分享链接。Xray 仅在首次选择时下载固定稳定版本，配置变更不会自动升级。" \
    "1" "Xray-core（未安装则自动下载）" \
    "2" "sing-box（使用现有内核）" \
    "0" "返回")" || return 1
  case "$core_choice" in
    1)
      core="xray"
      if [[ "$(state_get '[.routing.split.outbounds[]? | select(.enabled == true)] | length')" -gt 0 ]]; then
        ui_msg "提示：当前分流落地使用 sing-box SRS/GeoSite 规则，Xray 承载的 VLESS 不会套用这些分流规则；Shadowsocks/Hysteria2 的现有分流不受影响。"
      fi
      install_xray_core
      ;;
    2)
      core="sing-box"
      have_cmd sing-box || install_sing_box
      ;;
    0) return 0 ;;
    *)
      ui_msg "无效选项，请重新选择。"
      return 1
      ;;
  esac

  previous_state_file="$(snapshot_sing_box_state_file)" || {
    ui_msg "无法创建节点状态快照，未修改 VLESS + Reality。"
    return 1
  }

  if ! prompt_node_name_for_protocol; then
    install -m 0600 "$previous_state_file" "$STATE_FILE"
    rm -f "$previous_state_file"
    return 1
  fi

  ss_port="$(state_get '.protocols.shadowsocks.port')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  if [[ "$vless_enabled" == "true" ]]; then
    default_port="$(state_get '.protocols.vless_reality.port')"
    default_sni="$(state_get '.protocols.vless_reality.server_name')"
    default_handshake_port="$(state_get '.protocols.vless_reality.handshake_port')"
  else
    default_port="$(generate_random_service_port_excluding "$ss_port")"
    default_sni="www.tesla.com"
    default_handshake_port="443"
  fi
  port="$(prompt_number "VLESS 端口" "请输入 VLESS + Reality 监听端口" "$default_port" 1 65535)" || {
    install -m 0600 "$previous_state_file" "$STATE_FILE"; rm -f "$previous_state_file"; return 1;
  }
  selected_sni="$(select_reality_sni_default "$default_sni" "$vless_enabled")" || {
    install -m 0600 "$previous_state_file" "$STATE_FILE"; rm -f "$previous_state_file"; return 1;
  }
  sni="$(prompt_nonempty "Reality SNI" "请确认地区默认域名，或输入其他第三方 Reality 伪装域名（不能填写本机 IP 或节点域名）" "$selected_sni")" || {
    install -m 0600 "$previous_state_file" "$STATE_FILE"; rm -f "$previous_state_file"; return 1;
  }
  handshake_port="$(prompt_number "Reality 握手端口" "请输入 Reality 伪装站点端口" "$default_handshake_port" 1 65535)" || {
    install -m 0600 "$previous_state_file" "$STATE_FILE"; rm -f "$previous_state_file"; return 1;
  }

  private_key="$(state_get '.protocols.vless_reality.private_key // ""')"
  public_key="$(state_get '.protocols.vless_reality.public_key // ""')"
  short_id="$(state_get '.protocols.vless_reality.short_id // ""')"
  if [[ -z "$private_key" || -z "$public_key" || -z "$short_id" ]]; then
    keypair="$(generate_reality_keypair "$core")"
    private_key="${keypair%%$'\t'*}"
    public_key="${keypair##*$'\t'}"
    short_id="$(generate_hex 8)"
  fi
  listen_addr="$(default_listen_address)"

  state_jq --arg core "$core" --argjson port "$port" --arg sni "$sni" --arg handshake_server "$sni" --argjson handshake_port "$handshake_port" --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" --arg listen_addr "$listen_addr" --arg ts "$(utc_now)" '
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.core = $core |
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

  apply_sing_box_state_transaction "$previous_state_file" "VLESS + Reality 配置"
}

configure_hysteria2() {
  local port up_mbps down_mbps tls_server_name masquerade obfs_password listen_addr

  prompt_node_name_for_protocol || return 1

  port="$(prompt_number "Hysteria2 端口" "请输入 Hysteria2 监听端口（UDP）" "$(generate_random_service_port)" 1 65535)" || return 1
  up_mbps="$(prompt_number "上行带宽" "请输入上行 Mbps" "100" 1 100000)" || return 1
  down_mbps="$(prompt_number "下行带宽" "请输入下行 Mbps" "100" 1 100000)" || return 1
  tls_server_name="$(prompt_nonempty "TLS Server Name" "请输入 Hysteria2 证书域名或 IP" "$(state_get '.meta.server_address')")" || return 1
  masquerade="$(prompt_nonempty "Masquerade" "请输入认证失败时伪装地址" "https://www.bing.com")" || return 1

  obfs_password="$(generate_password)"
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

  rm -f "$(state_get '.protocols.hysteria2.cert_path')" "$(state_get '.protocols.hysteria2.key_path')" 2>/dev/null || true
  ensure_hysteria_cert

  if [[ "$(state_get '.protocols.hysteria2.users | length')" -eq 0 ]]; then
    append_hy2_user "hy2-client-1" "$(generate_password)"
  fi

  apply_config
}

outbound_ip_preference_label() {
  case "$(state_get '.meta.outbound_ip_preference // "auto"' 2>/dev/null || true)" in
    prefer_ipv4)
      printf 'IPv4 优先\n'
      ;;
    prefer_ipv6)
      printf 'IPv6 优先\n'
      ;;
    ipv4_only)
      printf '禁用 IPv6（仅 IPv4）\n'
      ;;
    ipv6_only)
      printf '禁用 IPv4（仅 IPv6）\n'
      ;;
    *)
      printf '跟随系统\n'
      ;;
  esac
}

configure_outbound_ip_preference() {
  local current choice desired previous_state_file
  current="$(state_get '.meta.outbound_ip_preference // "auto"')"

  choice="$(ui_menu "出站 IPv4 / IPv6 策略" "当前设置：$(outbound_ip_preference_label)。该设置只影响 VPS 访问目标域名时的 IPv4 / IPv6 选择，不影响客户端连接节点所用的地址。" \
    "1" "IPv4 优先（目标无 IPv4 时使用 IPv6）" \
    "2" "IPv6 优先（目标无 IPv6 时使用 IPv4）" \
    "3" "禁用 IPv4（仅使用 IPv6）" \
    "4" "禁用 IPv6（仅使用 IPv4）" \
    "5" "跟随系统默认顺序" \
    "0" "返回")" || return 1

  case "$choice" in
    1) desired="prefer_ipv4" ;;
    2) desired="prefer_ipv6" ;;
    3) desired="ipv6_only" ;;
    4) desired="ipv4_only" ;;
    5) desired="auto" ;;
    0) return 0 ;;
    *)
      ui_msg "无效选项，请重新选择。"
      return 1
      ;;
  esac

  if [[ "$desired" == "$current" ]]; then
    ui_msg "出站 IPv4 / IPv6 策略未发生变化。"
    return 0
  fi

  previous_state_file="$(snapshot_sing_box_state_file)" || {
    ui_msg "无法创建节点状态快照，未修改出站 IPv4 / IPv6 策略。"
    return 1
  }
  state_jq --arg preference "$desired" --arg ts "$(utc_now)" '
    .meta.outbound_ip_preference = $preference |
    .meta.updated_at = $ts
  '
  apply_sing_box_state_transaction "$previous_state_file" "出站 IPv4 / IPv6 策略变更"
}

node_menu_text() {
  local vless_enabled vless_core vless_status
  vless_enabled="$(state_get '.protocols.vless_reality.enabled // false')"
  vless_status="VLESS + Reality：${vless_enabled}"
  if [[ "$vless_enabled" == "true" ]]; then
    vless_core="$(state_get '.protocols.vless_reality.core // "sing-box"')"
    case "$vless_core" in
      xray|sing-box) ;;
      *) vless_core="未知" ;;
    esac
    vless_status+=$'\n'"VLESS 核心类型：${vless_core}"
  fi

  cat <<EOF
节点地址：$(state_get '.meta.server_address // "-"')
IPv6 地址：$(state_get 'if (.meta.dual_stack // false) then (.meta.server_address_ipv6 // "-") else "未启用" end')
网络模式：$(state_get 'if (.meta.dual_stack // false) then "IPv4 / IPv6 双栈" elif ((.meta.server_address // "") | contains(":")) then "IPv6" else "IPv4" end')
出站访问：$(outbound_ip_preference_label)
Shadowsocks：$(state_get '.protocols.shadowsocks.enabled')
${vless_status}
Hysteria2：$(state_get '.protocols.hysteria2.enabled')

请选择要执行的节点操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

build_node() {
  local protocol_choice detected_ipv4 detected_ipv6 detected_address server_address
  local dual_stack=false

  protocol_choice="$(ui_menu "搭建节点" "请选择要搭建的节点协议" \
    "1" "Shadowsocks" \
    "2" "VLESS + Reality" \
    "3" "Hysteria2" \
    "0" "返回")" || return 1

  case "$protocol_choice" in
    1|2|3)
      ;;
    0)
      return 0
      ;;
    *)
      ui_msg "无效选项，请重新选择。"
      return 1
      ;;
  esac

  detected_ipv4="$(detect_public_ipv4 2>/dev/null || true)"
  detected_ipv6="$(detect_public_ipv6 2>/dev/null || true)"
  detected_address="${detected_ipv4:-$detected_ipv6}"

  [[ -n "$detected_ipv4" && -n "$detected_ipv6" ]] && dual_stack=true

  server_address="$(prompt_nonempty "节点出口地址" "请输入节点出口 IP 或域名(留空默认使用本机 IP)" "$detected_address")" || return 1
  state_jq --arg addr "$server_address" --arg ipv6 "$detected_ipv6" --argjson dual_stack "$dual_stack" --arg ts "$(utc_now)" '
    .meta.server_address = $addr |
    .meta.server_address_ipv6 = (if $dual_stack then $ipv6 else "" end) |
    .meta.dual_stack = $dual_stack |
    .meta.updated_at = $ts
  '

  case "$protocol_choice" in
    1)
      configure_shadowsocks
      ;;
    2)
      configure_vless_reality
      ;;
    3)
      configure_hysteria2
      ;;
  esac
}

change_node_address() {
  local current_address new_address current_ipv6 new_ipv6 dual_stack
  local vless_server_name handshake_server previous_state_file

  current_address="$(state_get '.meta.server_address // ""')"
  current_ipv6="$(state_get '.meta.server_address_ipv6 // ""')"
  dual_stack="$(state_get '.meta.dual_stack // false')"
  new_address="$(prompt_nonempty "更改节点地址" "请输入新的节点出口 IP 或域名" "$current_address")" || return 1
  new_ipv6="$current_ipv6"
  if [[ "$dual_stack" == "true" ]]; then
    new_ipv6="$(prompt_nonempty "更改 IPv6 地址" "请输入新的公网 IPv6 地址" "$current_ipv6")" || return 1
    if ! is_public_ipv6_candidate "$new_ipv6"; then
      ui_msg "请输入有效的公网 IPv6 地址。"
      return 1
    fi
  fi

  if [[ "$new_address" == "$current_address" && "$new_ipv6" == "$current_ipv6" ]]; then
    ui_msg "节点地址未发生变化。"
    return 0
  fi

  if [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]]; then
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    handshake_server="$(state_get '.protocols.vless_reality.handshake_server')"
    if [[ "$new_address" == "$vless_server_name" || "$new_address" == "$handshake_server" ||
      "$new_ipv6" == "$vless_server_name" || "$new_ipv6" == "$handshake_server" ]]; then
      ui_msg "新的节点地址不能与 VLESS + Reality 的伪装域名相同。"
      return 1
    fi
  fi

  previous_state_file="$(snapshot_sing_box_state_file)" || {
    ui_msg "无法创建节点状态快照，未更改节点地址。"
    return 1
  }
  state_jq --arg addr "$new_address" --arg ipv6 "$new_ipv6" --arg ts "$(utc_now)" '
    .meta.server_address = $addr |
    .meta.server_address_ipv6 = $ipv6 |
    .meta.updated_at = $ts
  '

  apply_sing_box_state_transaction "$previous_state_file" "节点地址变更"
}

node_submenu() {
  local choice menu_text

  while true; do
    menu_text="$(node_menu_text)"
    choice="$(ui_menu "代理节点管理" "$menu_text" \
      "1" "新建节点" \
      "2" "删除节点" \
      "3" "管理客户端" \
      "4" "查看订阅链接" \
      "5" "重新生成配置并重载服务" \
      "6" "更改节点地址" \
      "7" "设置出站 IPv4 / IPv6 策略" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue

    case "$choice" in
      1)
        build_node || true
        ;;
      2)
        delete_node || true
        ;;
      3)
        client_submenu || true
        ;;
      4)
        show_subscription_links || true
        ;;
      5)
        apply_config || true
        ;;
      6)
        change_node_address || true
        ;;
      7)
        configure_outbound_ip_preference || true
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

delete_node() {
  local choice selected_index protocol label cert_path="" key_path="" previous_state_file
  local -a protocols=()
  local -a labels=()
  local -a options=()

  if [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]]; then
    protocols+=("shadowsocks")
    labels+=("Shadowsocks")
  fi
  if [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]]; then
    protocols+=("vless_reality")
    labels+=("VLESS + Reality")
  fi
  if [[ "$(state_get '.protocols.hysteria2.enabled')" == "true" ]]; then
    protocols+=("hysteria2")
    labels+=("Hysteria2")
  fi

  if (( ${#protocols[@]} == 0 )); then
    ui_msg "当前没有已启用的节点可删除。"
    return 0
  fi

  for selected_index in "${!protocols[@]}"; do
    options+=("$((selected_index + 1))" "${labels[$selected_index]}")
  done
  options+=("0" "返回")
  options+=("00" "退出脚本")

  choice="$(ui_menu "删除节点" "请选择要删除的节点。删除后会停用该协议并清空该协议下的客户端。" "${options[@]}")" || return 0
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
    return 0
  }

  selected_index=$((choice - 1))
  (( selected_index >= 0 && selected_index < ${#protocols[@]} )) || {
    ui_msg "无效选项，请重新选择。"
    return 0
  }

  protocol="${protocols[$selected_index]}"
  label="${labels[$selected_index]}"
  ui_yesno "确认删除 ${label} 节点吗？该协议下的客户端会被清空。" || return 0
  previous_state_file="$(snapshot_sing_box_state_file)" || {
    ui_msg "无法创建节点状态快照，未删除 ${label}。"
    return 1
  }

  case "$protocol" in
    shadowsocks)
      state_jq --arg ts "$(utc_now)" '
        .protocols.shadowsocks.enabled = false |
        .protocols.shadowsocks.users = [] |
        .protocols.shadowsocks.server_password = "" |
        .meta.updated_at = $ts
      '
      ;;
    vless_reality)
      state_jq --arg ts "$(utc_now)" '
        .protocols.vless_reality.enabled = false |
        .protocols.vless_reality.users = [] |
        .protocols.vless_reality.private_key = "" |
        .protocols.vless_reality.public_key = "" |
        .protocols.vless_reality.short_id = "" |
        .meta.updated_at = $ts
      '
      ;;
    hysteria2)
      cert_path="$(state_get '.protocols.hysteria2.cert_path')"
      key_path="$(state_get '.protocols.hysteria2.key_path')"
      state_jq --arg ts "$(utc_now)" '
        .protocols.hysteria2.enabled = false |
        .protocols.hysteria2.users = [] |
        .protocols.hysteria2.obfs_password = "" |
        .meta.updated_at = $ts
      '
      ;;
  esac

  if ! apply_sing_box_state_transaction "$previous_state_file" "删除 ${label} 节点"; then
    return 1
  fi
  if [[ "$protocol" == "hysteria2" && "$cert_path" == "$CERT_DIR/"* && "$key_path" == "$CERT_DIR/"* ]]; then
    rm -f "$cert_path" "$key_path" 2>/dev/null || true
  fi
}

split_outbound_count() {
  state_get '(.routing.split.outbounds // []) | length'
}

select_split_outbound_id() {
  local title=${1:-选择分流落地}
  local prompt=${2:-请选择分流落地}
  local choice index id name type server port enabled
  local -a ids=()
  local -a options=()

  while IFS=$'\t' read -r id name type server port enabled; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    options+=("${#ids[@]}" "${name} | ${type} | ${server}:${port} | enabled=${enabled}")
  done < <(jq -r '.routing.split.outbounds[]? | [.id, .name, .outbound_type, .server, .port, (.enabled // false)] | @tsv' "$STATE_FILE")

  (( ${#ids[@]} > 0 )) || return 1
  options+=("0" "返回")
  choice="$(ui_menu "$title" "$prompt" "${options[@]}")" || return 1
  [[ "$choice" == "0" ]] && return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  index=$((choice - 1))
  (( index >= 0 && index < ${#ids[@]} )) || return 1
  printf '%s\n' "${ids[$index]}"
}

configure_split_routing() {
  local outbound_id=${1:-}
  local is_new=0 current_enabled current_type current_server current_port current_username current_password current_method current_rules current_special_rules
  local type_choice outbound_type server port username password password_default method_choice method rules_input rules_json name yesno_result auth_choice previous_state_file
  local name_attempts=0 password_attempts=0

  if [[ -z "$outbound_id" ]]; then
    is_new=1
    while (( name_attempts < 2 )); do
      name="$(prompt_nonempty "新增分流落地" "请输入唯一名称，只能包含字母、数字、点、下划线和连字符" "route-$(($(split_outbound_count) + 1))")" || return 1
      name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      if [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] &&
        ! jq -e --arg id "$name" '.routing.split.outbounds[]? | select(.id == $id)' "$STATE_FILE" >/dev/null; then
        break
      fi

      name_attempts=$((name_attempts + 1))
      if (( name_attempts >= 2 )); then
        ui_input_error_return
        return 1
      fi
      printf '落地名称格式无效或已存在，再次输错将退回菜单界面。\n' >&2
    done
    outbound_id="$name"
    current_enabled="false"
    current_type="socks"
    current_server=""
    current_port="1080"
    current_username=""
    current_password=""
    current_method="2022-blake3-aes-128-gcm"
    current_rules=""
    current_special_rules="[]"
  else
    name="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | .name')"
    current_enabled="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.enabled // false)')"
    current_type="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.outbound_type // "socks")')"
    current_server="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.server // "")')"
    current_port="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.port // 1080)')"
    current_username="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.username // "")')"
    current_password="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.password // "")')"
    current_method="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.method // "2022-blake3-aes-128-gcm")')"
    current_rules="$(state_get --arg id "$outbound_id" '
      .routing.split.outbounds[]
      | select(.id == $id)
      | (.rule_sets // [])
      | map(select(test("^(domain|geosite|srs):") | not))
      | join(", ")
    ')"
    current_special_rules="$(jq -c --arg id "$outbound_id" '
      [.routing.split.outbounds[]
        | select(.id == $id)
        | (.rule_sets // [])[]
        | select(test("^(domain|geosite|srs):"))
      ]
    ' "$STATE_FILE")"
  fi

  if (( ! is_new )); then
    if ui_yesno "是否启用并编辑落地 ${name}？选择否将停用该落地。当前状态：${current_enabled}"; then
      :
    else
      yesno_result=$?
      (( yesno_result == 2 )) && return 1
      previous_state_file="$(snapshot_sing_box_state_file)" || {
        ui_msg "无法创建状态快照，未停用分流落地。"
        return 1
      }
      if ! state_jq --arg id "$outbound_id" --arg ts "$(utc_now)" '
        (.routing.split.outbounds[] | select(.id == $id) | .enabled) = false |
        .meta.updated_at = $ts
      '; then
        rm -f "$previous_state_file"
        return 1
      fi
      apply_sing_box_state_transaction "$previous_state_file" "停用分流落地" || return 1
      return 0
    fi
  fi

  type_choice="$(ui_menu "分流落地类型" "请选择落地代理类型。当前：${current_type}" \
    "1" "SOCKS5" \
    "2" "Shadowsocks" \
    "0" "返回")" || return 1
  case "$type_choice" in
    1) outbound_type="socks" ;;
    2) outbound_type="shadowsocks" ;;
    0) return 0 ;;
    *) ui_msg "无效选项，请重新选择。"; return 1 ;;
  esac

  server="$(prompt_nonempty "分流落地地址" "请输入落地 IP 或域名" "$current_server")" || return 1
  port="$(prompt_number "分流落地端口" "请输入落地端口" "$current_port" 1 65535)" || return 1
  username=""
  password=""
  method="$current_method"

  if [[ "$outbound_type" == "socks" ]]; then
    if [[ "$current_type" == "socks" ]]; then
      username="$current_username"
      password_default="$current_password"
    else
      password_default=""
    fi
    if [[ -n "$username" ]]; then
      auth_choice="已启用"
    else
      auth_choice="未启用"
    fi
    if ui_yesno "SOCKS5 是否使用用户名/密码认证？当前：${auth_choice}"; then
      username="$(prompt_nonempty "分流落地用户名" "请输入 SOCKS5 用户名" "$username")" || return 1
      while (( password_attempts < 2 )); do
        password="$(ui_password "分流落地密码" "请输入 SOCKS5 密码；留空则保留当前密码")" || return 1
        [[ -n "$password" ]] || password="$password_default"
        [[ -n "$password" && "$password" != "null" ]] && break
        password_attempts=$((password_attempts + 1))
        if (( password_attempts >= 2 )); then
          ui_input_error_return
          return 1
        fi
        printf 'SOCKS5 密码不能为空，再次输错将退回菜单界面。\n' >&2
      done
    else
      yesno_result=$?
      (( yesno_result == 2 )) && return 1
      username=""
      password=""
    fi
  else
    username=""
    if [[ "$current_type" == "shadowsocks" ]]; then
      password_default="$current_password"
    else
      password_default=""
    fi
    method_choice="$(ui_split_shadowsocks_method_menu "$current_method")" || return 1
    case "$method_choice" in
      1) method="2022-blake3-aes-128-gcm" ;;
      2) method="2022-blake3-aes-256-gcm" ;;
      3) method="2022-blake3-chacha20-poly1305" ;;
      0) return 0 ;;
      *) ui_msg "无效加密方式，请重新选择。"; return 1 ;;
    esac
    method="$(normalize_shadowsocks_method "$method")"
    while (( password_attempts < 2 )); do
      password="$(ui_password "分流落地密码" "请输入 Shadowsocks 密码；留空则保留当前密码")" || return 1
      [[ -n "$password" ]] || password="$password_default"
      [[ -n "$password" && "$password" != "null" ]] && break
      password_attempts=$((password_attempts + 1))
      if (( password_attempts >= 2 )); then
        ui_input_error_return
        return 1
      fi
      printf 'Shadowsocks 密码不能为空，再次输错将退回菜单界面。\n' >&2
    done
  fi

  rules_input="$(ui_input "落地关键词规则" "请输入该落地绑定的关键词，可用逗号或空格分隔；已有网址、GeoSite 和远程 SRS 规则会保留" "$current_rules")" || return 1
  rules_json="$(build_split_rules_json "$rules_input")"

  previous_state_file="$(snapshot_sing_box_state_file)" || {
    ui_msg "无法创建状态快照，分流落地未保存。"
    return 1
  }
  if ! state_jq --arg id "$outbound_id" --arg name "$name" --arg outbound_type "$outbound_type" \
    --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" \
    --arg method "$method" --argjson rules "$rules_json" --argjson special_rules "$current_special_rules" --arg ts "$(utc_now)" '
    (($rules + $special_rules) | unique) as $all_rules |
    {
      id: $id,
      name: $name,
      enabled: (($all_rules | length) > 0),
      outbound_type: $outbound_type,
      server: $server,
      port: $port,
      username: $username,
      password: $password,
      method: $method,
      rule_sets: $all_rules
    } as $outbound |
    .routing.split.outbounds |= map(
      if .id == $id then
        .
      else
        .rule_sets = ((.rule_sets // []) - $all_rules) |
        .enabled = ((.enabled // false) and ((.rule_sets | length) > 0))
      end
    ) |
    if any(.routing.split.outbounds[]?; .id == $id) then
      .routing.split.outbounds |= map(if .id == $id then $outbound else . end)
    else
      .routing.split.outbounds += [$outbound]
    end |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    return 1
  fi

  if [[ "$(jq -nc --argjson rules "$rules_json" --argjson special_rules "$current_special_rules" '$rules + $special_rules | length')" -eq 0 ]]; then
    rm -f "$previous_state_file"
    ui_msg "落地已保存但未启用，请为它添加至少一个关键词、网址、GeoSite 或远程 SRS 分流规则。"
  else
    apply_sing_box_state_transaction "$previous_state_file" "保存分流落地"
  fi
}

edit_split_routing() {
  local outbound_id
  outbound_id="$(select_split_outbound_id "编辑分流落地" "请选择要编辑或停用的落地")" || return 0
  configure_split_routing "$outbound_id"
}

delete_split_outbound() {
  local outbound_id name previous_state_file
  outbound_id="$(select_split_outbound_id "删除分流落地" "请选择要删除的落地")" || return 0
  name="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | .name')"
  ui_yesno "确认删除分流落地 ${name} 及其全部规则集吗？" || return 0
  previous_state_file="$(snapshot_sing_box_state_file)" || return 1
  if ! state_jq --arg id "$outbound_id" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(select(.id != $id)) |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    return 1
  fi
  apply_sing_box_state_transaction "$previous_state_file" "删除分流落地"
}

show_split_routing_rules() {
  local summary
  summary="$(jq -r '
    if (.routing.split.outbounds // [] | length) == 0 then
      "当前没有分流落地。"
    else
      "匹配优先级：自定义域名 > GeoSite / 远程 SRS > 关键词；域名和关键词同类规则越长越优先。\n\n"
      + (.routing.split.outbounds
        | map(
          "[\(.name)]\n"
          + "enabled = \(.enabled // false)\n"
          + "outbound = \(.outbound_type // "socks")\n"
          + "address = \(.server):\(.port)\n"
          + "username = \(if ((.username // "") | length) > 0 then .username else "-" end)\n"
          + "method = \(.method // "-")\n"
          + "keyword_rules = \((.rule_sets // []) | map(select(test("^(domain|geosite|srs):") | not)) | join(", "))\n"
          + "domains = \((.rule_sets // []) | map(select(startswith("domain:")) | ltrimstr("domain:")) | join(", "))\n"
          + "geosite = \((.rule_sets // []) | map(select(startswith("geosite:")) | ltrimstr("geosite:")) | join(", "))\n"
          + "remote_srs = \((.rule_sets // []) | map(select(startswith("srs:")) | ltrimstr("srs:")) | join(", "))"
        )
        | join("\n\n"))
    end
  ' "$STATE_FILE")"
  ui_show_text "分流落地与分流规则" "$summary"
}

append_split_routing_rules() {
  local outbound_id rule_type rules_input rules_json previous_state_file
  [[ "$(split_outbound_count)" -gt 0 ]] || {
    ui_msg "请先新增分流落地。"
    return 0
  }
  outbound_id="$(select_split_outbound_id "新增分流规则" "请选择规则要绑定的落地")" || return 0
  if (( $# > 0 )); then
    rule_type="keyword"
    rules_input="$*"
  else
    rule_type="$(ui_menu "新增分流规则" "请选择规则类型" \
      "1" "关键词规则，例如 chatgpt" \
      "2" "自定义网址 / 域名，例如 nodeseek.com" \
      "3" "GeoSite 分类，例如 openai、netflix" \
      "4" "远程 SRS 规则集（HTTPS）" \
      "0" "返回")" || return 1
    case "$rule_type" in
      1)
        rule_type="keyword"
        rules_input="$(prompt_nonempty "新增关键词规则" "请输入关键词，可用逗号或空格分隔；例如 chatgpt, claude" "")" || return 1
        ;;
      2)
        rule_type="domain"
        rules_input="$(prompt_nonempty "新增自定义网址" "请输入网址或域名，可不带 http:// 或 https://；例如 nodeseek.com" "")" || return 1
        ;;
      3)
        rule_type="geosite"
        rules_input="$(prompt_nonempty "新增 GeoSite 分类" "请输入 SagerNet GeoSite 分类名，可用逗号或空格分隔；例如 openai, netflix" "")" || return 1
        ;;
      4)
        rule_type="srs"
        rules_input="$(prompt_nonempty "新增远程 SRS" "请输入可信来源的 HTTPS .srs 地址，可用逗号或空格分隔" "")" || return 1
        ;;
      0) return 0 ;;
      *) ui_msg "无效选项，请重新选择。"; return 1 ;;
    esac
  fi
  case "$rule_type" in
    domain) rules_json="$(build_split_domains_json "$rules_input")" ;;
    geosite) rules_json="$(build_split_geosite_json "$rules_input")" ;;
    srs) rules_json="$(build_split_srs_json "$rules_input")" ;;
    *) rules_json="$(build_split_rules_json "$rules_input")" ;;
  esac
  [[ "$(printf '%s' "$rules_json" | jq -r 'length')" -gt 0 ]] || {
    case "$rule_type" in
      domain) ui_msg "网址格式无效，请输入类似 nodeseek.com 的域名。" ;;
      geosite) ui_msg "GeoSite 分类名格式无效，请输入类似 openai 或 netflix 的分类名。" ;;
      srs) ui_msg "远程 SRS 地址无效，只接受 HTTPS 的 .srs 地址。" ;;
      *) ui_msg "关键词规则格式无效。" ;;
    esac
    return 1
  }
  previous_state_file="$(snapshot_sing_box_state_file)" || return 1
  if ! state_jq --arg id "$outbound_id" --argjson rules "$rules_json" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(
      if .id == $id then
        ((.rule_sets // []) | length) as $old_rule_count |
        .rule_sets = (((.rule_sets // []) + $rules) | unique) |
        .enabled = ((.enabled // false) or ($old_rule_count == 0))
      else
        .rule_sets = ((.rule_sets // []) - $rules) |
        .enabled = ((.enabled // false) and ((.rule_sets | length) > 0))
      end
    ) |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    return 1
  fi
  apply_sing_box_state_transaction "$previous_state_file" "新增分流规则"
}

delete_split_routing_rule() {
  local outbound_id total_count choice selected_index selected_rule previous_state_file
  local -a rule_values=()
  local -a options=()
  outbound_id="$(select_split_outbound_id "删除分流规则" "请选择规则所属的落地")" || return 0
  total_count="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | (.rule_sets // []) | length')"
  [[ "$total_count" -gt 0 ]] || {
    ui_msg "该落地没有可删除的规则集。"
    return 0
  }
  while IFS= read -r selected_rule; do
    rule_values+=("$selected_rule")
    if [[ "$selected_rule" == domain:* ]]; then
      options+=("${#rule_values[@]}" "网址：${selected_rule#domain:}")
    elif [[ "$selected_rule" == geosite:* ]]; then
      options+=("${#rule_values[@]}" "GeoSite：${selected_rule#geosite:}")
    elif [[ "$selected_rule" == srs:* ]]; then
      options+=("${#rule_values[@]}" "远程 SRS：${selected_rule#srs:}")
    else
      options+=("${#rule_values[@]}" "关键词：$selected_rule")
    fi
  done < <(jq -r --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | .rule_sets[]?' "$STATE_FILE")
  options+=("0" "返回")
  choice="$(ui_menu "删除分流规则" "请选择要删除的分流规则" "${options[@]}")" || return 1
  [[ "$choice" == "0" ]] && return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  selected_index=$((choice - 1))
  (( selected_index >= 0 && selected_index < ${#rule_values[@]} )) || return 1
  selected_rule="${rule_values[$selected_index]}"
  previous_state_file="$(snapshot_sing_box_state_file)" || return 1
  if ! state_jq --arg id "$outbound_id" --arg rule "$selected_rule" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(
      if .id == $id then
        .rule_sets = ((.rule_sets // []) | map(select(. != $rule))) |
        .enabled = ((.enabled // false) and ((.rule_sets | length) > 0))
      else
        .
      end
    ) |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    return 1
  fi
  apply_sing_box_state_transaction "$previous_state_file" "删除分流规则"
}

split_routing_menu_text() {
  cat <<EOF
分流落地数量：$(split_outbound_count)
已启用落地数量：$(state_get '[.routing.split.outbounds[]? | select(.enabled == true)] | length')
分流规则总数：$(state_get '[.routing.split.outbounds[]?.rule_sets[]?] | length')

每个落地可绑定关键词、自定义域名、GeoSite 分类或远程 SRS。优先级：自定义域名 > GeoSite / SRS > 关键词。
请选择要执行的操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

split_routing_submenu() {
  local choice menu_text
  while true; do
    menu_text="$(split_routing_menu_text)"
    choice="$(ui_menu "分流管理" "$menu_text" \
      "1" "新增分流落地" \
      "2" "编辑 / 停用分流落地" \
      "3" "删除分流落地" \
      "4" "查看全部落地与分流规则" \
      "5" "为落地新增分流规则" \
      "6" "删除落地分流规则" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue
    case "$choice" in
      1) configure_split_routing || true ;;
      2) edit_split_routing || true ;;
      3) delete_split_outbound || true ;;
      4) show_split_routing_rules || true ;;
      5) append_split_routing_rules || true ;;
      6) delete_split_routing_rule || true ;;
      0) return 0 ;;
      00) exit 0 ;;
      *) ui_msg "无效选项，请重新选择。" ;;
    esac
  done
}

add_client() {
  local protocol_choice name value ss_method duplicate_attempts=0
  protocol_choice="$(ui_protocol_menu)" || return 1

  case "$protocol_choice" in
    1)
      [[ "$(state_get '.protocols.shadowsocks.enabled')" == "true" ]] || {
        ui_msg "Shadowsocks 当前未启用，请先完成协议配置。"
        return 0
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 Shadowsocks 客户端名称" "ss-client-$(date +%H%M%S)")" || return 1
        if user_exists "shadowsocks" "$name"; then
          duplicate_attempts=$((duplicate_attempts + 1))
          if (( duplicate_attempts >= 2 )); then
            ui_input_error_return
            return 1
          fi
          printf '该客户端名称已存在，再次输错将退回菜单界面。\n' >&2
          continue
        fi
        break
      done
      ss_method="$(state_get '.protocols.shadowsocks.method // "2022-blake3-aes-128-gcm"')"
      value="$(generate_shadowsocks_password "$ss_method")"
      append_ss_user "$name" "$value"
      apply_config
      ;;
    2)
      [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]] || {
        ui_msg "VLESS + Reality 当前未启用，请先完成协议配置。"
        return 0
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 VLESS 客户端名称" "vless-client-$(date +%H%M%S)")" || return 1
        if user_exists "vless_reality" "$name"; then
          duplicate_attempts=$((duplicate_attempts + 1))
          if (( duplicate_attempts >= 2 )); then
            ui_input_error_return
            return 1
          fi
          printf '该客户端名称已存在，再次输错将退回菜单界面。\n' >&2
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
        return 0
      }
      while true; do
        name="$(prompt_nonempty "新增客户端" "请输入 Hysteria2 客户端名称" "hy2-client-$(date +%H%M%S)")" || return 1
        if user_exists "hysteria2" "$name"; then
          duplicate_attempts=$((duplicate_attempts + 1))
          if (( duplicate_attempts >= 2 )); then
            ui_input_error_return
            return 1
          fi
          printf '该客户端名称已存在，再次输错将退回菜单界面。\n' >&2
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
      protocol_label="Shadowsocks"
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
    return 0
  }

  user_count="$(state_get ".protocols.${protocol_key}.users | length")"
  if [[ "$user_count" -eq 0 ]]; then
    ui_msg "${protocol_label} 当前没有可删除的客户端。"
    return 0
  fi

  if [[ "$user_count" -eq 1 ]]; then
    ui_msg "${protocol_label} 当前仅剩 1 个客户端。请先新增客户端，或停用该协议后再删除。"
    return 0
  fi

  user_name="$(select_protocol_user "$protocol_key" "删除客户端" "请选择要删除的 ${protocol_label} 客户端")" || return 1
  ui_yesno "确认删除客户端 ${user_name} 吗？" || return 0

  remove_protocol_user "$protocol_key" "$user_name"
  apply_config
}

client_menu_text() {
  cat <<EOF
Shadowsocks 客户端数：$(state_get '.protocols.shadowsocks.users | length')
VLESS + Reality 客户端数：$(state_get '.protocols.vless_reality.users | length')
Hysteria2 客户端数：$(state_get '.protocols.hysteria2.users | length')

请选择要执行的客户端操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

client_submenu() {
  local choice menu_text

  while true; do
    menu_text="$(client_menu_text)"
    choice="$(ui_menu "管理客户端" "$menu_text" \
      "1" "新增客户端" \
      "2" "删除客户端" \
      "3" "查看客户端信息" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue

    case "$choice" in
      1)
        add_client || true
        ;;
      2)
        remove_client || true
        ;;
      3)
        show_client_info || true
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

realm_install_or_reset() {
  require_linux
  require_root
  [[ "$(realm_service_manager)" != "none" ]] || {
    ui_msg "Realm 服务管理需要 systemd 或 OpenRC 环境。"
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
  write_realm_config_file
  sync_managed_firewall_rules

  if realm_service_exists; then
    stop_realm_service_raw >/dev/null 2>&1 || true
    disable_realm_service
  fi

  ui_msg "Realm 安装 / 重置完成。当前规则已清空，请继续添加转发规则。"
}

realm_uninstall() {
  ui_yesno "这将卸载 Realm，并删除所有中转规则和配置。是否继续？" || return 0

  if realm_service_exists; then
    stop_realm_service_raw >/dev/null 2>&1 || true
    disable_realm_service
  fi

  rm -f "$REALM_BIN" "$REALM_SERVICE_FILE" "$REALM_OPENRC_SERVICE_FILE" \
    "$REALM_OPENRC_LOG_FILE" "$REALM_CONFIG_FILE" 2>/dev/null || true
  rm -rf "$REALM_DIR" 2>/dev/null || true
  if [[ -s "$REALM_STATE_FILE" ]] && [[ "$(wireguard_profile_count)" -gt 0 ]]; then
    realm_state_jq --arg ts "$(utc_now)" '.rules = [] | .meta.updated_at = $ts' || return 1
  else
    rm -f "$REALM_STATE_FILE" 2>/dev/null || true
  fi
  sync_managed_firewall_rules

  if has_systemd; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed realm >/dev/null 2>&1 || true
  fi

  ui_msg "Realm 已卸载完成。已创建的 WireGuard 隧道会继续保留，可在重新安装 Realm 后继续使用。"
}

select_realm_forward_mode() {
  ui_menu "Realm 转发链路" "请选择本条规则使用的链路" \
    "1" "直接转发" \
    "2" "通过 WireGuard 隧道" \
    "0" "返回"
}

add_realm_forward_rule() {
  local listen_port remote_host remote_port rule_id description entries_json previous_state_file mode_choice mode tunnel_id="" tunnel_name="" error_count=0

  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  listen_port="$(realm_prompt_number_limited error_count "本地端口" "请输入需要监听的本地端口" "$(generate_random_service_port)" 1 65535)" || return 1
  mode_choice="$(select_realm_forward_mode)" || return 1
  case "$mode_choice" in
    1)
      mode="direct"
      remote_host="$(realm_prompt_nonempty_limited error_count "落地地址" "请输入目标地址【落地机的 IP 或域名】" "")" || return 1
      ;;
    2)
      mode="wireguard"
      tunnel_id="$(select_wireguard_profile relay)" || return 1
      [[ "$(wireguard_profile_field "$tunnel_id" paired)" == "true" && "$(wireguard_profile_field "$tunnel_id" enabled)" == "true" ]] || {
        ui_msg "所选 WireGuard 隧道尚未配对或未启用。"
        return 1
      }
      remote_host="$(wireguard_profile_field "$tunnel_id" peer_address)"
      tunnel_name="$(wireguard_profile_field "$tunnel_id" name)"
      ;;
    0) return 0 ;;
    *) return 1 ;;
  esac
  remote_port="$(realm_prompt_number_limited error_count "落地端口" "请输入目标端口【落地节点的端口】" "443" 1 65535)" || return 1

  if [[ "$mode" == "wireguard" ]]; then
    if ! wireguard_profile_route_ready "$tunnel_id"; then
      wireguard_start_profile "$tunnel_id" || { ui_msg "WireGuard 隧道无法启动。"; return 1; }
    fi
    wireguard_probe_tcp "$remote_host" "$remote_port" || {
      ui_msg "WireGuard 隧道存在，但目标 ${remote_host}:${remote_port} 无法连接。规则未保存，请检查落地节点监听和防火墙。"
      return 1
    }
  fi

  rule_id="realm-$(date +%s)-$(generate_hex 4)"
  if [[ "$mode" == "wireguard" ]]; then
    description="0.0.0.0:${listen_port} -> [WG:${tunnel_name}] ${remote_host}:${remote_port}"
  else
    description="0.0.0.0:${listen_port} -> ${remote_host}:${remote_port}"
  fi
  entries_json="$(jq -nc --arg listen "0.0.0.0:${listen_port}" --arg remote "${remote_host}:${remote_port}" '[{listen: $listen, remote: $remote}]')"

  previous_state_file="$(snapshot_realm_state_file)" || {
    ui_msg "无法创建 Realm 状态快照，未执行变更。"
    return 1
  }

  if ! realm_state_jq --arg id "$rule_id" --arg description "$description" --arg mode "$mode" --arg tunnel_id "$tunnel_id" --argjson entries "$entries_json" --arg ts "$(utc_now)" '
    .rules += [{id: $id, type: "single", mode: $mode, tunnel_id: (if $mode == "wireguard" then $tunnel_id else null end), description: $description, entries: $entries}] |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    ui_msg "写入 Realm 规则失败，未执行变更。"
    return 1
  fi

  apply_realm_config "$previous_state_file"
}

add_realm_range_rule() {
  local listen_start listen_end remote_host remote_start remote_end count rule_id description entries_json previous_state_file mode_choice mode tunnel_id="" tunnel_name="" error_count=0

  ensure_realm_dirs
  init_realm_state_file

  [[ -x "$REALM_BIN" ]] || {
    ui_msg "请先安装 Realm。"
    return 1
  }

  while true; do
    listen_start="$(realm_prompt_number_limited error_count "起始端口" "请输入本地起始端口" "$(generate_random_service_port)" 1 65535)" || return 1
    listen_end="$(realm_prompt_number_limited error_count "结束端口" "请输入本地结束端口" "$listen_start" 1 65535)" || return 1
    if (( listen_end >= listen_start )); then
      break
    fi

    error_count=$((error_count + 1))
    if (( error_count >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '本地结束端口不能小于起始端口，再次输错将退回菜单界面。\n' >&2
  done

  mode_choice="$(select_realm_forward_mode)" || return 1
  case "$mode_choice" in
    1)
      mode="direct"
      remote_host="$(realm_prompt_nonempty_limited error_count "落地地址" "请输入目标地址【落地机的 IP 或域名】" "")" || return 1
      ;;
    2)
      mode="wireguard"
      tunnel_id="$(select_wireguard_profile relay)" || return 1
      [[ "$(wireguard_profile_field "$tunnel_id" paired)" == "true" && "$(wireguard_profile_field "$tunnel_id" enabled)" == "true" ]] || {
        ui_msg "所选 WireGuard 隧道尚未配对或未启用。"
        return 1
      }
      remote_host="$(wireguard_profile_field "$tunnel_id" peer_address)"
      tunnel_name="$(wireguard_profile_field "$tunnel_id" name)"
      ;;
    0) return 0 ;;
    *) return 1 ;;
  esac
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
        ui_input_error_return
        return 1
      fi
      printf '本地端口段和目标端口段长度必须一致，再次输错将退回菜单界面。\n' >&2
      continue
    fi

    error_count=$((error_count + 1))
    if (( error_count >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '目标结束端口不能小于起始端口，再次输错将退回菜单界面。\n' >&2
  done

  count=$((listen_end - listen_start))

  if [[ "$mode" == "wireguard" ]]; then
    if ! wireguard_profile_route_ready "$tunnel_id"; then
      wireguard_start_profile "$tunnel_id" || { ui_msg "WireGuard 隧道无法启动。"; return 1; }
    fi
    wireguard_probe_tcp "$remote_host" "$remote_start" || {
      ui_msg "WireGuard 隧道存在，但目标起始端口 ${remote_host}:${remote_start} 无法连接。规则未保存。"
      return 1
    }
  fi

  rule_id="realm-$(date +%s)-$(generate_hex 4)"
  if [[ "$mode" == "wireguard" ]]; then
    description="0.0.0.0:${listen_start}-${listen_end} -> [WG:${tunnel_name}] ${remote_host}:${remote_start}-${remote_end}"
  else
    description="0.0.0.0:${listen_start}-${listen_end} -> ${remote_host}:${remote_start}-${remote_end}"
  fi
  entries_json="$(jq -nc --arg host "$remote_host" --argjson listen_start "$listen_start" --argjson listen_end "$listen_end" --argjson remote_start "$remote_start" '
    [range(0; ($listen_end - $listen_start) + 1) | {
      listen: ("0.0.0.0:" + (($listen_start + .) | tostring)),
      remote: ($host + ":" + (($remote_start + .) | tostring))
    }]
  ')"

  previous_state_file="$(snapshot_realm_state_file)" || {
    ui_msg "无法创建 Realm 状态快照，未执行变更。"
    return 1
  }

  if ! realm_state_jq --arg id "$rule_id" --arg description "$description" --arg mode "$mode" --arg tunnel_id "$tunnel_id" --argjson entries "$entries_json" --arg ts "$(utc_now)" '
    .rules += [{id: $id, type: "range", mode: $mode, tunnel_id: (if $mode == "wireguard" then $tunnel_id else null end), description: $description, entries: $entries}] |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    ui_msg "写入 Realm 规则失败，未执行变更。"
    return 1
  fi

  apply_realm_config "$previous_state_file"
}

select_realm_rule_id() {
  local choice index id description entry_count
  local -a ids=() options=()
  while IFS=$'\t' read -r id description entry_count; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    options+=("${#ids[@]}" "${description}（${entry_count} 条）")
  done < <(jq -r '.rules[]? | [.id, .description, (.entries | length)] | @tsv' "$REALM_STATE_FILE")
  if (( ${#ids[@]} == 0 )); then
    ui_msg "当前没有 Realm 转发规则。"
    return 1
  fi
  options+=("0" "返回")
  choice="$(ui_menu "Realm 中转菜单" "请选择转发规则" "${options[@]}")" || return 1
  [[ "$choice" != "0" && "$choice" =~ ^[0-9]+$ ]] || return 1
  index=$((choice - 1))
  (( index >= 0 && index < ${#ids[@]} )) || return 1
  printf '%s\n' "${ids[$index]}"
}

change_realm_rule_transport() {
  local id mode_choice mode tunnel_id="" tunnel_name="" remote_host first_port last_port old_description left description previous_state_file error_count=0
  init_realm_state_file
  id="$(select_realm_rule_id)" || return 0
  first_port="$(jq -r --arg id "$id" '.rules[] | select(.id == $id) | .entries[0].remote | capture(":(?<port>[0-9]+)$").port' "$REALM_STATE_FILE")" || return 1
  last_port="$(jq -r --arg id "$id" '.rules[] | select(.id == $id) | .entries[-1].remote | capture(":(?<port>[0-9]+)$").port' "$REALM_STATE_FILE")" || return 1
  mode_choice="$(select_realm_forward_mode)" || return 1
  case "$mode_choice" in
    1)
      mode="direct"
      remote_host="$(realm_prompt_nonempty_limited error_count "切换为直接转发" "请输入落地公网 IP 或域名" "")" || return 1
      ;;
    2)
      mode="wireguard"
      tunnel_id="$(select_wireguard_profile relay)" || return 1
      [[ "$(wireguard_profile_field "$tunnel_id" paired)" == "true" && "$(wireguard_profile_field "$tunnel_id" enabled)" == "true" ]] || {
        ui_msg "所选 WireGuard 隧道尚未配对或未启用。"
        return 1
      }
      remote_host="$(wireguard_profile_field "$tunnel_id" peer_address)"
      tunnel_name="$(wireguard_profile_field "$tunnel_id" name)"
      if ! wireguard_profile_route_ready "$tunnel_id"; then
        wireguard_start_profile "$tunnel_id" || { ui_msg "WireGuard 隧道无法启动。"; return 1; }
      fi
      wireguard_probe_tcp "$remote_host" "$first_port" || {
        ui_msg "WireGuard 目标 ${remote_host}:${first_port} 无法连接，链路未切换。"
        return 1
      }
      ;;
    0) return 0 ;;
    *) return 1 ;;
  esac

  old_description="$(jq -r --arg id "$id" '.rules[] | select(.id == $id) | .description' "$REALM_STATE_FILE")"
  left="${old_description%% -> *}"
  if [[ "$first_port" == "$last_port" ]]; then
    if [[ "$mode" == "wireguard" ]]; then
      description="${left} -> [WG:${tunnel_name}] ${remote_host}:${first_port}"
    else
      description="${left} -> ${remote_host}:${first_port}"
    fi
  elif [[ "$mode" == "wireguard" ]]; then
    description="${left} -> [WG:${tunnel_name}] ${remote_host}:${first_port}-${last_port}"
  else
    description="${left} -> ${remote_host}:${first_port}-${last_port}"
  fi

  previous_state_file="$(snapshot_realm_state_file)" || return 1
  if ! realm_state_jq --arg id "$id" --arg mode "$mode" --arg tunnel_id "$tunnel_id" --arg remote_host "$remote_host" --arg description "$description" --arg ts "$(utc_now)" '
    (.rules[] | select(.id == $id)) |= (
      .mode = $mode |
      .tunnel_id = (if $mode == "wireguard" then $tunnel_id else null end) |
      .description = $description |
      .entries |= map(.remote = ($remote_host + ":" + (.remote | capture(":(?<port>[0-9]+)$").port)))
    ) |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    ui_msg "Realm 链路更新失败，原规则未改变。"
    return 1
  fi
  apply_realm_config "$previous_state_file"
}

delete_realm_rule() {
  local choice selected_index rule_id previous_state_file
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
  previous_state_file="$(snapshot_realm_state_file)" || {
    ui_msg "无法创建 Realm 状态快照，未执行变更。"
    return 1
  }

  if ! realm_state_jq --arg id "$rule_id" --arg ts "$(utc_now)" '
    .rules |= map(select(.id != $id)) |
    .meta.updated_at = $ts
  '; then
    rm -f "$previous_state_file"
    ui_msg "写入 Realm 规则失败，未执行变更。"
    return 1
  fi

  apply_realm_config "$previous_state_file"
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
  [[ "$(realm_service_manager)" != "none" ]] || {
    ui_msg "Realm 服务管理需要 systemd 或 OpenRC 环境。"
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

  if realm_service_exists && [[ "$(realm_service_active)" == "active" ]]; then
    ui_msg "Realm 服务已经在运行。"
    return 0
  fi
  apply_current_realm_state
}

stop_realm_service() {
  [[ "$(realm_service_manager)" != "none" ]] || {
    ui_msg "Realm 服务管理需要 systemd 或 OpenRC 环境。"
    return 1
  }
  if realm_service_exists; then
    stop_realm_service_raw >/dev/null 2>&1 || true
    ui_msg "Realm 服务已停止。"
  else
    ui_msg "当前未检测到 Realm 服务。"
  fi
}

restart_realm_service() {
  [[ "$(realm_service_manager)" != "none" ]] || {
    ui_msg "Realm 服务管理需要 systemd 或 OpenRC 环境。"
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

  apply_current_realm_state
}

fetch_latest_project_from_repo() {
  local tmp_dir project_dir api_root repo_json branch_json commit_json content_json
  local repo_id owner_id full_name default_branch commit_sha commit_author_id commit_committer_id
  local content_type content_path content_encoding content_sha download_url api_copy raw_copy
  local api_blob_sha raw_blob_sha actual_sha256 api_sha256
  tmp_dir="$(mktemp -d "$TMP_DIR/sbox-repo.XXXXXX")" || return 1
  project_dir="$tmp_dir/repo"
  mkdir -p "$project_dir"

  api_root="https://api.github.com/repos/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}"
  repo_json="$tmp_dir/repository.json"
  branch_json="$tmp_dir/branch.json"
  commit_json="$tmp_dir/commit.json"
  content_json="$tmp_dir/content.json"

  download_to_file "$repo_json" "$api_root" || {
    warn "无法访问 GitHub 仓库 API；请检查 VPS 的 DNS、IPv4/IPv6 路由或 GitHub 连通性。"
    rm -rf "$tmp_dir"
    return 1
  }
  repo_id="$(jq -r '.id // empty | tostring' "$repo_json")"
  owner_id="$(jq -r '.owner.id // empty | tostring' "$repo_json")"
  full_name="$(jq -r '.full_name // empty' "$repo_json")"
  default_branch="$(jq -r '.default_branch // empty' "$repo_json")"
  if [[ "$repo_id" != "$SCRIPT_REPO_ID" || "$owner_id" != "$SCRIPT_REPO_OWNER_ID" ||
        "$full_name" != "${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}" || "$default_branch" != "$SCRIPT_REPO_BRANCH" ]]; then
    warn "GitHub 仓库身份校验失败，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  fi

  download_to_file "$branch_json" "$api_root/branches/$SCRIPT_REPO_BRANCH" || {
    warn "无法读取 GitHub 分支信息，未能确定最新提交。"
    rm -rf "$tmp_dir"
    return 1
  }
  commit_sha="$(jq -r '.commit.sha // empty' "$branch_json")"
  [[ "$commit_sha" =~ ^[A-Fa-f0-9]{40}$ ]] || {
    warn "GitHub 返回的更新提交标识无效，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  }
  commit_sha="${commit_sha,,}"

  download_to_file "$commit_json" "$api_root/commits/$commit_sha" || {
    warn "无法读取 GitHub 提交身份信息，已拒绝在无法验证作者时更新。"
    rm -rf "$tmp_dir"
    return 1
  }
  [[ "$(jq -r '.sha // empty' "$commit_json")" == "$commit_sha" ]] || {
    warn "GitHub 提交元数据与分支头不一致，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  }
  commit_author_id="$(jq -r '.author.id // empty | tostring' "$commit_json")"
  commit_committer_id="$(jq -r '.committer.id // empty | tostring' "$commit_json")"
  if [[ "$commit_author_id" != "$SCRIPT_REPO_OWNER_ID" && "$commit_committer_id" != "$SCRIPT_REPO_OWNER_ID" ]]; then
    warn "最新提交无法关联到固定仓库所有者，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  fi

  download_to_file "$content_json" "$api_root/contents/index.sh?ref=$commit_sha" || {
    warn "无法读取 GitHub API 中不可变提交的 index.sh 内容。"
    rm -rf "$tmp_dir"
    return 1
  }
  content_type="$(jq -r '.type // empty' "$content_json")"
  content_path="$(jq -r '.path // empty' "$content_json")"
  content_encoding="$(jq -r '.encoding // empty' "$content_json")"
  content_sha="$(jq -r '.sha // empty' "$content_json")"
  download_url="$(jq -r '.download_url // empty' "$content_json")"
  if [[ "$content_type" != "file" || "$content_path" != "index.sh" || "$content_encoding" != "base64" || ! "$content_sha" =~ ^[A-Fa-f0-9]{40}$ ||
        "$download_url" != "https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/${commit_sha}/index.sh" ]]; then
    warn "GitHub 文件元数据校验失败，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  fi

  api_copy="$tmp_dir/index.api"
  if ! jq -r '.content // empty' "$content_json" | tr -d '\r\n' | base64 -d >"$api_copy"; then
    warn "GitHub API 文件内容解码失败，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  fi

  api_blob_sha="$(git_blob_sha1_file "$api_copy")" || {
    warn "无法计算 GitHub API 文件的 Git Blob 哈希，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  }
  if [[ "$api_blob_sha" != "${content_sha,,}" ]]; then
    warn "GitHub API 文件的 Git Blob 哈希与不可变提交不匹配，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  fi

  api_sha256="$(sha256_file "$api_copy")" || {
    warn "无法计算 GitHub API 文件的 SHA-256，已拒绝更新。"
    rm -rf "$tmp_dir"
    return 1
  }

  # The authenticated GitHub API copy is sufficient after the pinned
  # repository/owner/commit/blob checks above. An immutable Raw copy remains
  # an additional cross-endpoint check, but Raw being unreachable must not
  # block updates on VPS networks where only api.github.com is reachable.
  raw_copy="$tmp_dir/index.raw"
  if download_to_file "$raw_copy" "$download_url"; then
    raw_blob_sha="$(git_blob_sha1_file "$raw_copy")" || {
      warn "无法计算不可变 Raw 文件的 Git Blob 哈希，已拒绝更新。"
      rm -rf "$tmp_dir"
      return 1
    }
    if [[ "$raw_blob_sha" != "${content_sha,,}" ]]; then
      warn "不可变 Raw 文件的 Git Blob 哈希与 GitHub API 不匹配，已拒绝更新。"
      rm -rf "$tmp_dir"
      return 1
    fi

    actual_sha256="$(sha256_file "$raw_copy")" || {
      warn "无法计算不可变 Raw 文件的 SHA-256，已拒绝更新。"
      rm -rf "$tmp_dir"
      return 1
    }
    if [[ "$actual_sha256" != "$api_sha256" ]]; then
      warn "GitHub API 与不可变 commit 原始文件的 SHA-256 不一致，已拒绝更新。"
      rm -rf "$tmp_dir"
      return 1
    fi
    cp -f "$raw_copy" "$project_dir/index.sh" || {
      warn "无法准备已经校验的更新脚本。"
      rm -rf "$tmp_dir"
      return 1
    }
    log "更新内容已通过 GitHub API 与不可变 Raw 双路径交叉校验。"
  else
    cp -f "$api_copy" "$project_dir/index.sh" || {
      warn "无法准备已经校验的 GitHub API 更新脚本。"
      rm -rf "$tmp_dir"
      return 1
    }
    warn "不可变 Raw 下载入口不可用；已使用通过仓库、所有者、提交及 Blob 哈希校验的 GitHub API 内容继续更新。"
  fi

  bash -n "$project_dir/index.sh" || {
    warn "下载脚本未通过 Bash 语法校验，现有脚本不会被修改。"
    rm -rf "$tmp_dir"
    return 1
  }

  log "更新来源校验通过。"
  printf '%s\n' "$project_dir"
}

install_manager_project_from_repo() {
  local target_path project_dir install_tmp=""

  target_path="$MANAGER_SCRIPT_PATH"
  project_dir="$(fetch_latest_project_from_repo)" || return 1

  install -d -m 0755 "$(dirname "$target_path")"
  install_tmp="$(mktemp "$(dirname "$target_path")/.sbox-update.XXXXXX")" || {
    warn "无法在脚本目录创建更新临时文件，现有脚本未修改。"
    rm -rf "$(dirname "$project_dir")"
    return 1
  }
  if ! install -o root -g root -m 0755 "$project_dir/index.sh" "$install_tmp"; then
    warn "无法写入更新临时文件，现有脚本未修改。"
    rm -f "$install_tmp"
    rm -rf "$(dirname "$project_dir")"
    return 1
  fi
  if ! mv -f "$install_tmp" "$target_path"; then
    warn "无法原子替换管理脚本，现有脚本未修改。"
    rm -f "$install_tmp"
    rm -rf "$(dirname "$project_dir")"
    return 1
  fi

  if [[ "$target_path" == "/usr/local/bin/sbox" ]]; then
    rm -f /usr/local/bin/singbox-manager 2>/dev/null || true
  fi
  rm -rf "$(dirname "$project_dir")"
}

update_manager_script() {
  log "正在从固定 GitHub 仓库检查并安全更新管理脚本..."
  install_manager_project_from_repo || {
    ui_msg "安全更新失败；具体失败阶段见上方提示，现有脚本未修改。"
    return 1
  }

  log "管理脚本更新完成，正在重新打开面板。"
  exec "$MANAGER_SCRIPT_PATH"
}

realm_submenu() {
  local choice
  local menu_text

  while true; do
    menu_text="$(realm_menu_text)"
    choice="$(ui_menu "Realm 中转菜单" "$menu_text" \
      "1" "WireGuard 隧道管理" \
      "2" "安装 / 重置 Realm" \
      "3" "添加转发规则" \
      "4" "添加端口段转发" \
      "5" "修改转发链路（直连 / WireGuard）" \
      "6" "删除转发规则" \
      "7" "查看当前配置" \
      "8" "启动服务" \
      "9" "停止服务" \
      "10" "重启服务" \
      "11" "更新脚本" \
      "12" "卸载 Realm" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue

    case "$choice" in
      1)
        wireguard_submenu || true
        ;;
      2)
        realm_install_or_reset || true
        ;;
      3)
        add_realm_forward_rule || true
        ;;
      4)
        add_realm_range_rule || true
        ;;
      5)
        change_realm_rule_transport || true
        ;;
      6)
        delete_realm_rule || true
        ;;
      7)
        show_realm_config || true
        ;;
      8)
        start_realm_service || true
        ;;
      9)
        stop_realm_service || true
        ;;
      10)
        restart_realm_service || true
        ;;
      11)
        update_manager_script || true
        ;;
      12)
        realm_uninstall || true
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

xray_install_status() {
  if [[ -x "$XRAY_BIN" ]]; then
    printf '已安装（%s）\n' "$(state_get '.runtime.xray.version // "版本未知"' 2>/dev/null || printf '版本未知')"
  else
    printf '未安装（按需安装）\n'
  fi
}

realm_install_status() {
  if [[ -x "$REALM_BIN" ]]; then
    if run_as_runtime "$REALM_BIN" --version >/dev/null 2>&1; then
      printf '已安装\n'
    else
      printf '已安装（当前无法运行，进入 Realm 菜单后自动修复）\n'
    fi
  else
    printf '未安装\n'
  fi
}

main_menu_text() {
  local realm_forward_count=0 wireguard_tunnel_count=0

  if ! have_cmd jq; then
    cat <<EOF
Sing-box 状态：$(sing_box_install_status)
Xray 状态：$(xray_install_status)
管理环境：未初始化

请先选择 1 安装 / 初始化 sing-box；一键常用脚本无需初始化
EOF
    return 0
  fi

  if [[ -s "$REALM_STATE_FILE" ]]; then
    realm_forward_count="$(realm_rule_group_count)"
    wireguard_tunnel_count="$(wireguard_profile_count)"
  fi

  cat <<EOF
Sing-box 状态：$(sing_box_install_status)
Xray 状态：$(xray_install_status)
节点个数：$(state_get '[.protocols[]?.users[]?] | length') 个
Realm转发个数：${realm_forward_count} 个
WireGuard隧道：${wireguard_tunnel_count} 个
分流落地：$(state_get '(.routing.split.outbounds // []) | length') 个

请选择要执行的操作
EOF
}

realm_menu_text() {
  local rule_count tunnel_count
  if [[ -s "$REALM_STATE_FILE" ]]; then
    rule_count="$(realm_rule_group_count)"
    tunnel_count="$(wireguard_profile_count)"
  else
    rule_count="0"
    tunnel_count="0"
  fi

  cat <<EOF
Realm 状态：$(realm_install_status)
转发规则组个数：${rule_count}
WireGuard 隧道个数：${tunnel_count}

请选择要执行的操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

prepare_realm_menu() {
  require_linux
  require_root
  [[ "$(realm_service_manager)" != "none" ]] || {
    ui_msg "Realm 服务管理需要 systemd 或 OpenRC 环境。"
    return 1
  }

  ensure_realm_dirs
  init_realm_state_file

  if [[ -x "$REALM_BIN" ]]; then
    repair_realm_binary_compatibility || {
      ui_msg "Realm 二进制与当前系统不兼容，自动修复失败。请检查上方下载或校验错误。"
      return 1
    }
    ensure_realm_service
  fi
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

show_overview() {
  local server_address service_status xray_status ss_users vless_users hy2_users overview node_name links_file
  server_address="$(state_get '.meta.server_address' 2>/dev/null || true)"
  node_name="$(state_get '.meta.node_name' 2>/dev/null || true)"

  if service_exists; then
    service_status="$(sing_box_service_active 2>/dev/null || printf 'unknown\n')"
  else
    service_status="unknown"
  fi
  if xray_service_exists; then
    xray_status="$(xray_service_active 2>/dev/null || printf 'unknown\n')"
  else
    xray_status="未安装"
  fi

  ss_users="$(jq -r '.protocols.shadowsocks.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE" 2>/dev/null || printf -- '-\n')"
  vless_users="$(jq -r '.protocols.vless_reality.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE" 2>/dev/null || printf -- '-\n')"
  hy2_users="$(jq -r '.protocols.hysteria2.users | map(.name) | if length == 0 then "-" else join(", ") end' "$STATE_FILE" 2>/dev/null || printf -- '-\n')"
  links_file="$(direct_links_file 2>/dev/null || true)"

  overview=$(
    cat <<EOF
脚本版本: $SCRIPT_VERSION
节点名称: ${node_name:-未设置}
节点地址: ${server_address:-未设置}
网络模式: $(state_get 'if (.meta.dual_stack // false) then "IPv4 / IPv6 双栈" elif ((.meta.server_address // "") | contains(":")) then "IPv6" else "IPv4" end' 2>/dev/null || printf '未知')
IPv6 地址: $(state_get 'if (.meta.dual_stack // false) then (.meta.server_address_ipv6 // "未设置") else "未启用" end' 2>/dev/null || printf '未知')
出站访问: $(outbound_ip_preference_label 2>/dev/null || printf '未知')
sing-box 状态: $service_status
Xray 状态: $xray_status
配置文件: $CONFIG_FILE
客户端导出目录: $CLIENT_DIR
导入链接文件: ${links_file}

[Shadowsocks]
enabled = $(state_get '.protocols.shadowsocks.enabled')
port = $(state_get '.protocols.shadowsocks.port')
users = $ss_users

[VLESS + Reality]
enabled = $(state_get '.protocols.vless_reality.enabled')
core = $(state_get '.protocols.vless_reality.core // "sing-box"')
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

[Split Routing]
outbounds = $(state_get '(.routing.split.outbounds // []) | length')
enabled_outbounds = $(state_get '[.routing.split.outbounds[]? | select(.enabled == true)] | length')
rule_sets = $(format_split_rule_list)
EOF
  )

  ui_show_text "当前概览" "$overview" || true
  return 0
}

show_service_status() {
  local text="" service_manager version_output active_status enabled_status recent_logs
  service_manager="$(sing_box_service_manager 2>/dev/null || printf 'unknown\n')"

  if have_cmd sing-box; then
    version_output="$(run_as_runtime sing-box version 2>/dev/null | head -n 1 || true)"
    text+="sing-box version: ${version_output:-读取失败}\n"
  else
    text+="sing-box version: 未安装\n"
  fi

  if service_exists; then
    active_status="$(sing_box_service_active 2>/dev/null || printf 'unknown\n')"
    enabled_status="$(sing_box_service_enabled 2>/dev/null || printf 'unknown\n')"
    recent_logs="$(sing_box_recent_logs 2>/dev/null || printf '无法读取最近日志。\n')"
    text+="service manager: ${service_manager}\n"
    text+="service active: ${active_status}\n"
    text+="service enabled: ${enabled_status}\n"
    text+="\n最近日志:\n"
    text+="${recent_logs}"
  else
    if [[ "$service_manager" != "none" ]]; then
      text+="未检测到 sing-box ${service_manager} 服务。\n"
      text+="可尝试执行：sbox quick-install\n"
      text+="如果 sing-box 已安装，脚本会自动补建服务。"
    else
      text+="当前系统未检测到可用的 systemd 或 OpenRC 环境。"
    fi
  fi

  text+="\n\n[Xray]\n"
  if [[ -x "$XRAY_BIN" ]]; then
    version_output="$(xray_version_text 2>/dev/null || true)"
    text+="Xray version: ${version_output:-读取失败}\n"
    text+="managed binary: ${XRAY_BIN}\n"
    text+="recorded SHA-256: $(state_get '.runtime.xray.binary_sha256 // "未记录"' 2>/dev/null || printf '未记录')\n"
  else
    text+="Xray version: 未安装\n"
  fi
  if xray_service_exists; then
    active_status="$(xray_service_active 2>/dev/null || printf 'unknown\n')"
    enabled_status="$(xray_service_enabled 2>/dev/null || printf 'unknown\n')"
    recent_logs="$(xray_recent_logs 2>/dev/null || printf '无法读取最近日志。\n')"
    text+="service active: ${active_status}\n"
    text+="service enabled: ${enabled_status}\n"
    text+="\n最近日志:\n${recent_logs}"
  fi

  ui_show_text "服务状态" "$(printf '%b' "$text")" || true
  return 0
}

uninstall_sbox() {
  local uninstall_text xray_managed=false
  uninstall_text=$'这将执行以下操作：\n- 停止并禁用 sing-box 与脚本托管的 Xray\n- 停止并禁用 Realm 及脚本托管的 sbwg* WireGuard 隧道\n- 卸载 sing-box 软件包（如果存在）\n- 删除脚本托管的 Xray 二进制、节点、Realm、WireGuard 密钥和状态\n- 删除 sbox 与 realm 命令\n\n不会删除系统中其他 xray.service、/usr/local/bin/xray 或非 sbwg* 的用户 WireGuard 配置。是否继续？'

  ui_yesno "$uninstall_text" || return 0
  xray_managed="$(state_get '.runtime.xray.managed // false' 2>/dev/null || printf 'false\n')"

  if have_cmd systemctl; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    systemctl stop sbox-xray >/dev/null 2>&1 || true
    systemctl disable sbox-xray >/dev/null 2>&1 || true
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi
  if has_openrc; then
    rc-service sing-box stop >/dev/null 2>&1 || true
    rc-update del sing-box default >/dev/null 2>&1 || true
    rc-service sbox-xray stop >/dev/null 2>&1 || true
    rc-update del sbox-xray default >/dev/null 2>&1 || true
    rc-service realm stop >/dev/null 2>&1 || true
    rc-update del realm default >/dev/null 2>&1 || true
  fi

  remove_all_managed_wireguard_profiles || {
    ui_msg "脚本托管的 WireGuard 隧道未能完全清理，卸载已中止。"
    return 1
  }

  remove_firewall_restore_service
  if ! remove_all_managed_firewall_rules; then
    ui_msg "托管防火墙规则未能完全清理。相关服务已停止，卸载已中止；请修复防火墙后重新执行卸载。"
    return 1
  fi

  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk del sing-box >/dev/null 2>&1 || true
      apk del sing-box-openrc >/dev/null 2>&1 || true
      ;;
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
  rm -f "$XRAY_SYSTEMD_SERVICE_FILE" /etc/systemd/system/multi-user.target.wants/sbox-xray.service 2>/dev/null || true
  rm -f "$XRAY_OPENRC_SERVICE_FILE" "$XRAY_OPENRC_LOG_FILE" 2>/dev/null || true
  rm -f "$SING_BOX_OPENRC_SERVICE_FILE" "$SING_BOX_OPENRC_LOG_FILE" 2>/dev/null || true
  rm -f "$REALM_SERVICE_FILE" /lib/systemd/system/realm.service /usr/lib/systemd/system/realm.service /etc/systemd/system/multi-user.target.wants/realm.service 2>/dev/null || true
  rm -f "$REALM_OPENRC_SERVICE_FILE" "$REALM_OPENRC_LOG_FILE" 2>/dev/null || true
  rm -f "$SING_BOX_HARDENING_DROPIN_FILE" 2>/dev/null || true
  rmdir "$SING_BOX_FIREWALL_DROPIN_DIR" "$XRAY_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR" 2>/dev/null || true
  if [[ "$xray_managed" == "true" || -f "$XRAY_MANAGED_MARKER" ]]; then
    case "$XRAY_INSTALL_DIR" in
      /usr/local/lib/sbox-xray|/usr/local/lib/sbox-xray/*)
        rm -rf -- "$XRAY_INSTALL_DIR"
        ;;
      *)
        warn "Xray 安装目录不在脚本允许的卸载范围内，已保留：$XRAY_INSTALL_DIR"
        ;;
    esac
  fi
  rm -rf /etc/sing-box "$REALM_DIR" "$STATE_DIR" 2>/dev/null || true
  rm -rf "$PROJECT_INSTALL_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/sbox /usr/local/bin/singbox-manager "$REALM_BIN" 2>/dev/null || true

  if id -u "$RUNTIME_USER" >/dev/null 2>&1 && have_cmd userdel; then
    userdel "$RUNTIME_USER" >/dev/null 2>&1 || true
  elif id -u "$RUNTIME_USER" >/dev/null 2>&1 && have_cmd deluser; then
    deluser "$RUNTIME_USER" >/dev/null 2>&1 || true
  fi
  if { getent group "$RUNTIME_GROUP" >/dev/null 2>&1 || grep -q "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null; }; then
    if have_cmd groupdel; then
      groupdel "$RUNTIME_GROUP" >/dev/null 2>&1 || true
    elif have_cmd delgroup; then
      delgroup "$RUNTIME_GROUP" >/dev/null 2>&1 || true
    fi
  fi

  if have_cmd systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    systemctl reset-failed sbox-xray >/dev/null 2>&1 || true
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
      "1" "安装 / 初始化 sing-box" \
      "2" "代理节点管理" \
      "3" "分流管理" \
      "4" "Realm 中转" \
      "5" "查看当前概览" \
      "6" "查看服务状态" \
      "7" "端口管理" \
      "8" "一键常用脚本" \
      "9" "更新脚本" \
      "10" "卸载" \
      "0" "退出")" || continue

    if ! have_cmd jq && [[ "$choice" != "1" && "$choice" != "8" && "$choice" != "0" ]]; then
      ui_msg "管理环境尚未初始化，请先选择 1 安装 / 初始化 sing-box。"
      continue
    fi

    case "$choice" in
      1)
        quick_install || true
        ;;
      2)
        node_submenu || true
        ;;
      3)
        split_routing_submenu || true
        ;;
      4)
        if prepare_realm_menu; then
          realm_submenu || true
        fi
        ;;
      5)
        show_overview
        continue
        ;;
      6)
        show_service_status
        continue
        ;;
      7)
        port_management_menu || true
        ;;
      8)
        common_scripts_menu || true
        ;;
      9)
        update_manager_script || true
        ;;
      10)
        uninstall_sbox || true
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
  $SCRIPT_NAME node           打开代理节点管理菜单
  $SCRIPT_NAME ports          打开端口管理菜单
  $SCRIPT_NAME tools          打开一键常用脚本菜单
  $SCRIPT_NAME change-address 更改节点出口 IP 或域名
  $SCRIPT_NAME delete-node    删除已启用的协议节点
  $SCRIPT_NAME add-client     打开新增客户端流程
  $SCRIPT_NAME remove-client  打开删除客户端流程
  $SCRIPT_NAME split          打开分流管理菜单
  $SCRIPT_NAME split-route    新增 SOCKS5 / Shadowsocks 分流落地
  $SCRIPT_NAME edit-split-route
                          编辑或停用分流落地
  $SCRIPT_NAME delete-split-route
                          删除分流落地
  $SCRIPT_NAME split-rules    查看全部分流落地与规则
  $SCRIPT_NAME add-split-rule chatgpt claude
                          新增关键词分流规则
  $SCRIPT_NAME delete-split-rule
                          删除关键词或网址分流规则
  $SCRIPT_NAME repair-install 重新安装 / 修复环境并保留现有规则
  $SCRIPT_NAME realm          打开 Realm 中转菜单
  $SCRIPT_NAME apply          重新生成配置并重载服务
  $SCRIPT_NAME show           查看客户端信息
  $SCRIPT_NAME overview       查看当前概览
  $SCRIPT_NAME status         查看服务状态
  $SCRIPT_NAME uninstall      卸载 sing-box、脚本托管的 Xray 和 sbox
  $SCRIPT_NAME --version      查看脚本版本

说明:
  1. 面板使用纯命令行数字输入，不依赖方向键。
  2. Hysteria2 默认使用自签名证书。
  3. 一键安装使用官方原生 sing-box 软件包；选择 Xray VLESS 时按需下载经 SHA-256 校验的官方稳定版。
  4. 支持添加多个 SOCKS5 / Shadowsocks 分流落地，每个落地独立绑定规则集。
  5. 新建 Shadowsocks 节点与分流仅提供 SS2022，节点端口由端口管理统一控制。
  6. repair-install 会修复 sing-box、已选用的 Xray、Realm 二进制兼容性、权限和服务，但不会删除状态文件、客户端或分流规则，也不会隐式升级 Xray。
  7. 一键安装只安装环境；节点名称和出口地址在新建节点时填写。
EOF
}

main() {
  setup_terminal_env

  case "${1:-panel}" in
    quick-install)
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
    node|nodes|manage-node)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      node_submenu
      ;;
    change-address|edit-address)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      change_node_address
      ;;
    delete-node|remove-node)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      delete_node
      ;;
    split|split-menu|routing|ai|ai-menu|ai-route-menu)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      split_routing_submenu
      ;;
    split-route|ai-route)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      configure_split_routing
      ;;
    edit-split-route|edit-split-outbound)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      edit_split_routing
      ;;
    delete-split-route|remove-split-route|delete-split-outbound)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      delete_split_outbound
      ;;
    split-rules|show-split-rules|ai-rules|show-ai-rules)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      show_split_routing_rules
      ;;
    add-split-rule|add-split-rules|append-split-rule|append-split-rules|add-ai-rule|add-ai-rules|append-ai-rule|append-ai-rules)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      append_split_routing_rules "${@:2}"
      ;;
    delete-split-rule|remove-split-rule|delete-ai-rule|remove-ai-rule)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      delete_split_routing_rule
      ;;
    repair-install|reinstall)
      repair_install
      ;;
    realm)
      ensure_dirs
      prepare_realm_menu && realm_submenu
      ;;
    ports|port|port-menu)
      require_linux
      require_root
      ensure_dirs
      init_state_file
      port_management_menu
      ;;
    tools|tool|common-scripts)
      require_linux
      require_root
      common_scripts_menu
      ;;
    firewall-sync)
      require_linux
      require_root
      ensure_dirs
      have_cmd jq || die "缺少 jq，无法恢复托管防火墙规则。"
      sync_managed_firewall_rules
      ;;
    migrate-realm-tcp-only)
      require_linux
      require_root
      ensure_dirs
      migrate_realm_tcp_only
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
      ensure_dirs
      if have_cmd jq; then
        init_state_file
      fi
      main_menu
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
