#!/usr/bin/env bash
#
# Sing-box 一键安装与管理面板
# 用于在 Linux VPS 上快速安装和管理 sing-box 的 Shell 脚本
# 支持 Shadowsocks、VLESS + Reality 和 Hysteria2
#
# 作者: renaissance0721
# 版本: 0.6.0
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

ORIGINAL_ARGS=("$@")
SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_VERSION="0.6.0"
SCRIPT_NAME="${0##*/}"
APP_TITLE="Sing-box 管理面板 | 输入 sbox 快捷打开脚本"
STATE_DIR="${STATE_DIR:-/etc/sing-box-manager}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
BACKUP_DIR="${BACKUP_DIR:-$STATE_DIR/backups}"
CLIENT_DIR="${CLIENT_DIR:-$STATE_DIR/clients}"
CERT_DIR="${CERT_DIR:-$STATE_DIR/certs}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
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
IPTABLES_MIGRATION_MARKER="${IPTABLES_MIGRATION_MARKER:-$STATE_DIR/iptables-comment-rules.migrated}"
IPTABLES_RULE_COMMENT="${IPTABLES_RULE_COMMENT:-sbox-managed}"
FIREWALL_SYSTEMD_SERVICE_FILE="${FIREWALL_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/sbox-firewall.service}"
SING_BOX_FIREWALL_DROPIN_DIR="${SING_BOX_FIREWALL_DROPIN_DIR:-/etc/systemd/system/sing-box.service.d}"
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
  install -d -m 0750 "$STATE_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")"
  install -d -m 0700 "$BACKUP_DIR" "$CLIENT_DIR"
  install -d -m 0700 "$CLIENT_DIR/shadowsocks" "$CLIENT_DIR/vless-reality" "$CLIENT_DIR/hysteria2"

  if runtime_account_exists; then
    chown root:"$RUNTIME_GROUP" "$STATE_DIR" "$CERT_DIR" "$(dirname "$CONFIG_FILE")"
  fi
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

run_as_runtime() {
  ensure_runtime_account
  if have_cmd runuser; then
    runuser -u "$RUNTIME_USER" -- "$@"
  elif have_cmd su-exec; then
    su-exec "${RUNTIME_USER}:${RUNTIME_GROUP}" "$@"
  else
    die "缺少 runuser 或 su-exec，无法以低权限运行 sing-box/Realm。"
  fi
}

ensure_openrc_low_port_capability() {
  local binary_path=$1 label=$2
  has_openrc && ! has_systemd || return 0
  [[ -x "$binary_path" ]] || return 0
  have_cmd setcap || die "OpenRC 下需要 setcap 才能让低权限 ${label} 监听 1-1023 端口。"
  setcap 'cap_net_bind_service=+ep' "$binary_path" ||
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
      apk add --no-cache bash curl jq openssl ca-certificates tar gzip openrc coreutils findutils iptables iproute2 su-exec libcap-setcap
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      normalize_debian_apt_sources || warn "Debian apt 源自动修复失败，将继续尝试 apt-get update。"
      apt-get update -y
      apt-get install -y curl jq openssl ca-certificates tar gzip iproute2 iptables gnupg
      ;;
    dnf)
      dnf install -y curl jq openssl ca-certificates tar gzip iproute iptables gnupg2
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y curl jq openssl ca-certificates tar gzip iproute iptables gnupg2
      ;;
    *)
      die "暂不支持自动安装依赖，请手动安装 bash、curl、jq、openssl、ca-certificates、tar、gzip 后再运行。"
      ;;
  esac
}

install_sing_box_apt_repo() {
  local key_tmp key_fingerprint
  normalize_debian_apt_sources || warn "Debian apt 源自动修复失败，将继续尝试安装 sing-box。"
  mkdir -p /etc/apt/keyrings || return 1
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
      if apk add --no-cache sing-box; then
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
    die "sing-box 签名软件包安装失败；为避免以 root 执行未校验的远程脚本或二进制，已拒绝不安全的后备安装。"
  fi

  hash -r 2>/dev/null || true
  have_cmd sing-box || die "安装完成后仍未找到 sing-box 命令。"
  ensure_sing_box_service
  enable_sing_box_service

  version_text="$(run_as_runtime sing-box version 2>/dev/null | head -n 1 || true)"
  log "sing-box 已安装：${version_text:-version unknown}"
}

has_systemd() {
  have_cmd systemctl && [[ -d /run/systemd/system ]]
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
  local libc_target="gnu"
  if have_cmd apk || [[ -f /etc/alpine-release ]]; then
    libc_target="musl"
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64-unknown-linux-%s\n' "$libc_target"
      ;;
    aarch64|arm64)
      printf 'aarch64-unknown-linux-%s\n' "$libc_target"
      ;;
    armv7l|armv7)
      if [[ "$libc_target" == "musl" ]]; then
        printf 'armv7-unknown-linux-musleabihf\n'
      else
        printf 'armv7-unknown-linux-gnueabihf\n'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

install_realm_binary() {
  local arch tmp_dir archive_path extracted_bin release_json asset_name asset_url expected_digest actual_digest
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
  local output private_key public_key
  output="$(run_as_runtime sing-box generate reality-keypair 2>/dev/null || true)"
  private_key="$(printf '%s\n' "$output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$output" | awk -F': ' '/PublicKey/ {print $2; exit}')"

  [[ -n "$private_key" && -n "$public_key" ]] || die "无法生成 Reality 密钥对，请确认 sing-box 已正确安装。"

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
    "allowed_sources": [],
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
    "split": {
      "legacy_defaults_removed": true,
      "outbounds": []
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

cleanup_removed_traffic_state() {
  state_jq --arg version "$SCRIPT_VERSION" --arg ts "$(utc_now)" '
    def cleanup_users:
      map(del(.traffic_limit_gb, .traffic_used_bytes, .traffic_last_api_bytes, .expires_at));
    del(.traffic_stats) |
    .protocols.shadowsocks.users = ((.protocols.shadowsocks.users // []) | cleanup_users) |
    .protocols.shadowsocks.allowed_sources = ((.protocols.shadowsocks.allowed_sources // []) | map(select(type == "string")) | unique) |
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
    def clean_rules:
      map(ascii_downcase)
      | map(select(. as $rule | [
          "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
          "anthropic.com", "claude.ai", "perplexity.ai", "poe.com", "sora.com",
          "x.ai", "grok.com", "deepseek.com", "deepseek.ai", "google.com",
          "googleapis.com", "gstatic.com", "googleusercontent.com", "ggpht.com",
          "generativelanguage.googleapis.com", "aistudio.google.com",
          "gemini.google.com", "openai", "chatgpt", "gpt", "anthropic",
          "claude", "perplexity", "gemini"
        ] | index($rule) | not))
      | unique;
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
          ((.domain_suffix // []) + (.domain_keyword // [])) | clean_rules
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
    | map(if startswith("domain:") then (ltrimstr("domain:") + "（网址）") else . end)
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

build_allowed_sources_json() {
  local input=$1 source sources_json='[]'

  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    if ! is_valid_ip_or_cidr "$source"; then
      printf '无效的来源 IP/CIDR：%s\n' "$source" >&2
      return 1
    fi
    sources_json="$(jq -c --arg source "$source" '. + [$source] | unique' <<<"$sources_json")"
  done < <(jq -rn --arg input "$input" '
    $input | gsub("[,;[:space:]]+"; "\n") | split("\n")[] | select(length > 0)
  ')

  [[ "$(jq -r 'length' <<<"$sources_json")" -gt 0 ]] || return 1
  printf '%s\n' "$sources_json"
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
  local server_address vless_server_name handshake_server
  local split_name split_enabled split_type split_server split_port split_username split_password split_method split_rule_count ss_source

  ss_enabled="$(state_get '.protocols.shadowsocks.enabled')"
  vless_enabled="$(state_get '.protocols.vless_reality.enabled')"
  hy2_enabled="$(state_get '.protocols.hysteria2.enabled')"
  server_address="$(state_get '.meta.server_address')"

  [[ -n "$server_address" && "$server_address" != "null" ]] || errors+=$'节点对外地址不能为空。\n'

  if [[ "$ss_enabled" == "true" ]]; then
    [[ "$(state_get '.protocols.shadowsocks.users | length')" -gt 0 ]] || errors+=$'Shadowsocks 至少需要一个客户端。\n'
    [[ -n "$(state_get '.protocols.shadowsocks.server_password')" ]] || errors+=$'Shadowsocks 服务端密码不能为空。\n'
    while IFS= read -r ss_source; do
      [[ -n "$ss_source" ]] || continue
      is_valid_ip_or_cidr "$ss_source" || errors+="Shadowsocks 来源白名单无效：${ss_source}"$'\n'
    done < <(state_get '.protocols.shadowsocks.allowed_sources[]?')
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

  while IFS=$'\x1f' read -r split_name split_enabled split_type split_server split_port split_username split_password split_method split_rule_count; do
    split_rule_count="${split_rule_count%$'\r'}"
    [[ "$split_enabled" == "true" ]] || continue
    [[ "$split_type" == "socks" || "$split_type" == "shadowsocks" ]] || errors+="分流落地 ${split_name} 类型仅支持 SOCKS5 或 Shadowsocks。"$'\n'
    [[ -n "$split_server" && "$split_server" != "null" ]] || errors+="分流落地 ${split_name} 地址不能为空。"$'\n'
    [[ "$split_port" =~ ^[0-9]+$ ]] || errors+="分流落地 ${split_name} 端口必须是数字。"$'\n'
    if [[ "$split_type" == "socks" ]]; then
      [[ -n "$split_username" && "$split_username" != "null" ]] || errors+="分流落地 ${split_name} 的 SOCKS5 用户名不能为空。"$'\n'
    else
      is_supported_split_shadowsocks_method "$split_method" || errors+="分流落地 ${split_name} 的 Shadowsocks 加密方式不受支持。"$'\n'
    fi
    [[ -n "$split_password" && "$split_password" != "null" ]] || errors+="分流落地 ${split_name} 密码不能为空。"$'\n'
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

  if [[ -n "$errors" ]]; then
    ui_show_text "配置校验失败" "$errors"
    return 1
  fi

  return 0
}

render_config() {
  jq '
  def split_outbound_tag:
    "split-out:" + .;
  def split_rule_tag($id; $rule):
    "split:" + $id + ":" + $rule;
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
          tag: "local"
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
            {
              type: "socks",
              tag: (.id | split_outbound_tag),
              server: .server,
              server_port: .port,
              version: "5",
              username: .username,
              password: .password
            }
          end
      )
    ],
    route: {
      rule_set: [
        (
          .routing.split.outbounds[]?
          | select((.enabled // false) and ((.rule_sets // []) | length > 0))
          | . as $outbound
          | .rule_sets[] | {
              type: "inline",
              tag: split_rule_tag($outbound.id; .),
              rules: [
                if startswith("domain:") then
                  { domain_suffix: [ltrimstr("domain:")] }
                else
                  { domain_keyword: [.] }
                end
              ]
            }
        )
      ],
      rules: [
        (
          if (.protocols.shadowsocks.enabled or .protocols.vless_reality.enabled or .protocols.hysteria2.enabled) then
            [
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if .protocols.vless_reality.enabled then "vless-reality-in" else empty end,
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
                  if .protocols.vless_reality.enabled then "vless-reality-in" else empty end,
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
              timeout: "2s"
            }
          else empty
          end
        ),
        (
          .routing.split.outbounds[]?
          | select((.enabled // false) and ((.rule_sets // []) | length > 0))
          | . as $outbound
          | {
              rule_set: [.rule_sets[] | split_rule_tag($outbound.id; .)],
              action: "route",
              outbound: ($outbound.id | split_outbound_tag)
            }
        ),
        (
          if (.protocols.shadowsocks.enabled or .protocols.vless_reality.enabled or .protocols.hysteria2.enabled) then
            [
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if .protocols.vless_reality.enabled then "vless-reality-in" else empty end,
                  if .protocols.hysteria2.enabled then "hy2-in" else empty end
                ],
                action: "resolve",
                server: "local"
              },
              {
                inbound: [
                  if .protocols.shadowsocks.enabled then "ss-in" else empty end,
                  if .protocols.vless_reality.enabled then "vless-reality-in" else empty end,
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
                  if .protocols.vless_reality.enabled then "vless-reality-in" else empty end,
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
    }
  }' "$STATE_FILE"
}

enabled_protocol_count() {
  state_get '[.protocols[] | select(.enabled == true)] | length'
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

managed_firewall_rules_present() {
  [[ -s "$FIREWALL_STATE_FILE" ]] && return 0
  [[ -n "$(desired_managed_firewall_rules 2>/dev/null | head -n 1)" ]]
}

ensure_firewall_restore_service() {
  has_systemd || return 0

  mkdir -p "$(dirname "$FIREWALL_SYSTEMD_SERVICE_FILE")" \
    "$SING_BOX_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR"
  cat >"$FIREWALL_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=Restore sbox managed firewall rules
After=network-pre.target ufw.service firewalld.service
Before=sing-box.service realm.service
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
    warn "未检测到可用的 UFW、firewalld 或 iptables。请先执行 sbox repair-install 安装依赖。"
    return 1
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
    "$REALM_FIREWALL_DROPIN_DIR/10-sbox-firewall.conf" 2>/dev/null || true
  rmdir "$SING_BOX_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR" 2>/dev/null || true
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

desired_managed_firewall_rules() {
  if [[ -s "$STATE_FILE" ]]; then
    jq -e . "$STATE_FILE" >/dev/null 2>&1 || return 1
    jq -r '
      def row($owner; $protocol; $port; $source):
        [$owner, $protocol, ($port | tostring), $source] | @tsv;
      . as $root |
      (if $root.protocols.shadowsocks.enabled then
        ($root.protocols.shadowsocks.allowed_sources // []) as $sources |
        if ($sources | length) == 0 then
          row("shadowsocks"; "tcp"; $root.protocols.shadowsocks.port; "*")
        else
          $sources[] as $source |
          row("shadowsocks"; "tcp"; $root.protocols.shadowsocks.port; $source)
        end
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
    remove_firewall_rule "$protocol" "$port" "${source:-*}"
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
    add_firewall_rule "$backend" "$protocol" "$port" "${source:-*}" || failed=true
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
    firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" || failed=true
  done <"$desired_rules"
  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    firewall_restriction_exists "$backend" "$protocol" "$port" || failed=true
  done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$desired_rules" | sort -u)

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
    remove_firewall_rule "$protocol" "$port" "${source:-*}"
    remove_firewall_restriction "$protocol" "$port"
    firewalld_changed=true
  done <"$rules_file"
  if [[ "$firewalld_changed" == "true" && "$backend" == "firewalld" ]]; then
    firewall-cmd --reload >/dev/null 2>&1 || failed=true
  fi
  persist_openrc_firewall_rules

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" && failed=true
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
    (if .protocols.vless_reality.enabled then ["tcp", (.protocols.vless_reality.port | tostring), "VLESS + Reality"] | @tsv else empty end),
    (if .protocols.hysteria2.enabled then ["udp", (.protocols.hysteria2.port | tostring), "Hysteria2"] | @tsv else empty end)
  ' "$STATE_FILE"
}

validate_sing_box_listener_ports_available() {
  local rows duplicates protocol port label
  have_cmd ss || {
    printf '缺少 ss 命令，无法在放行防火墙前检查端口冲突。\n'
    return 1
  }

  rows="$(desired_sing_box_listeners)" || return 1
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

save_desired_firewall_state() {
  local tmp_file
  tmp_file="$(mktemp "$TMP_DIR/firewall-state.XXXXXX")" || return 1
  if ! desired_managed_firewall_rules | sort -u >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  install -m 600 "$tmp_file" "$FIREWALL_STATE_FILE"
  rm -f "$tmp_file"
}

show_all_listening_ports() {
  local output
  if ! have_cmd ss; then
    ui_msg "未检测到 ss 命令，无法查看端口占用。"
    return 1
  fi
  output="$(ss -lntup 2>&1)"
  ui_show_text "全部监听端口与占用进程" "$output"
}

show_managed_port_status() {
  local owner protocol port source listen_status firewall_status output="" backend rules_file
  local sources_display restricted complete wildcard_present
  rules_file="$(mktemp "$TMP_DIR/firewall-status.XXXXXX")" || return 1
  if ! desired_managed_firewall_rules | sort -u >"$rules_file"; then
    rm -f "$rules_file"
    ui_msg "节点或 Realm 状态文件无效，无法读取托管端口。"
    return 1
  fi
  backend="$(active_firewall_backend)"

  while IFS=$'\t' read -r owner protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if port_is_listening "$protocol" "$port"; then
      listen_status="监听中"
    else
      listen_status="未监听"
    fi

    sources_display=""
    restricted=false
    complete=true
    wildcard_present=false
    while IFS= read -r source; do
      [[ -n "$source" ]] || continue
      if [[ "$source" == "*" ]]; then
        sources_display="全网（高风险）"
      else
        restricted=true
        sources_display+="${sources_display:+, }${source}"
      fi
      if [[ "$backend" == "none" ]] || ! firewall_allow_rule_exists "$backend" "$protocol" "$port" "$source"; then
        complete=false
      fi
    done < <(awk -F '\t' -v owner="$owner" -v protocol="$protocol" -v port="$port" \
      '$1 == owner && $2 == protocol && $3 == port {print $4}' "$rules_file")

    if [[ "$backend" == "none" ]]; then
      firewall_status="不可用（未检测到本地防火墙）"
    elif [[ "$restricted" == "true" ]]; then
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "*" && wildcard_present=true
      firewall_restriction_exists "$backend" "$protocol" "$port" || complete=false
      if [[ "$wildcard_present" == "true" ]]; then
        firewall_status="危险：仍存在全网放行规则"
      elif [[ "$complete" == "true" ]]; then
        firewall_status="已限制来源"
      else
        firewall_status="规则不完整"
      fi
    elif [[ "$complete" == "true" ]]; then
      firewall_status="已放行"
    else
      firewall_status="未放行或规则缺失"
    fi

    output+="${owner}  ${protocol}/${port}  ${listen_status}  防火墙=${firewall_status}  来源=${sources_display:-未知}"$'\n'
  done < <(awk -F '\t' '{print $1 "\t" $2 "\t" $3}' "$rules_file" | sort -u)

  rm -f "$rules_file"
  [[ -n "$output" ]] || output="当前没有脚本托管端口。"$'\n'
  output+="\n当前本地防火墙后端：${backend}"
  output+=$'\n说明：云厂商安全组不在本页检测范围内。'
  ui_show_text "脚本托管端口状态" "$output"
}

close_inactive_managed_ports() {
  local owner protocol port source backend rules_file inactive_file closed=0 failed=0 operation_failed=false reload_failed=false
  prepare_managed_firewall || {
    ui_msg "防火墙环境不可用，未执行清理。请执行 sbox repair-install 后重试。"
    return 1
  }
  backend="$(active_firewall_backend)"
  rules_file="$(mktemp "$TMP_DIR/firewall-close-rules.XXXXXX")" || return 1
  inactive_file="$(mktemp "$TMP_DIR/firewall-close-ports.XXXXXX")" || {
    rm -f "$rules_file"
    return 1
  }
  if ! desired_managed_firewall_rules | sort -u >"$rules_file"; then
    rm -f "$rules_file" "$inactive_file"
    ui_msg "节点或 Realm 状态文件无效，未修改防火墙。"
    return 1
  fi

  while IFS=$'\t' read -r owner protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if ! port_is_listening "$protocol" "$port"; then
      printf '%s\t%s\t%s\n' "$owner" "$protocol" "$port" >>"$inactive_file"
      remove_firewall_rule "$protocol" "$port" "*"
      while IFS= read -r source; do
        [[ -n "$source" && "$source" != "*" ]] || continue
        remove_firewall_rule "$protocol" "$port" "$source"
      done < <(awk -F '\t' -v owner="$owner" -v protocol="$protocol" -v port="$port" \
        '$1 == owner && $2 == protocol && $3 == port {print $4}' "$rules_file")
      remove_firewall_restriction "$protocol" "$port"
    fi
  done < <(awk -F '\t' '{print $1 "\t" $2 "\t" $3}' "$rules_file" | sort -u)

  if [[ -s "$inactive_file" && "$backend" == "firewalld" ]] && ! firewall-cmd --reload >/dev/null 2>&1; then
    reload_failed=true
  fi
  persist_openrc_firewall_rules

  while IFS=$'\t' read -r owner protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    operation_failed="$reload_failed"
    firewall_allow_rule_exists "$backend" "$protocol" "$port" "*" && operation_failed=true
    while IFS= read -r source; do
      [[ -n "$source" && "$source" != "*" ]] || continue
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "$source" && operation_failed=true
    done < <(awk -F '\t' -v owner="$owner" -v protocol="$protocol" -v port="$port" \
      '$1 == owner && $2 == protocol && $3 == port {print $4}' "$rules_file")
    firewall_restriction_exists "$backend" "$protocol" "$port" && operation_failed=true
    if [[ "$operation_failed" == "true" ]]; then
      failed=$((failed + 1))
    else
      closed=$((closed + 1))
    fi
  done <"$inactive_file"

  if ! save_desired_firewall_state; then
    failed=$((failed + 1))
  fi
  rm -f "$rules_file" "$inactive_file"
  if (( failed > 0 )); then
    ui_msg "已清理 ${closed} 个未监听端口，但有 ${failed} 个端口清理或验证失败。"
    return 1
  fi
  ui_msg "已清理 ${closed} 个当前未监听端口的脚本放行规则。"
}

open_active_managed_ports() {
  local backend owner protocol port source opened=0 active_rules desired_rules failed=false restricted
  prepare_managed_firewall || {
    ui_msg "防火墙环境不可用，未开启托管端口。请执行 sbox repair-install 后重试。"
    return 1
  }
  active_rules="$(mktemp "$TMP_DIR/firewall-active.XXXXXX")" || return 1
  desired_rules="$(mktemp "$TMP_DIR/firewall-open-desired.XXXXXX")" || {
    rm -f "$active_rules"
    return 1
  }
  if ! desired_managed_firewall_rules | sort -u >"$desired_rules"; then
    rm -f "$active_rules" "$desired_rules"
    ui_msg "节点或 Realm 状态文件无效，未修改防火墙。"
    return 1
  fi
  backend="$(active_firewall_backend)"

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    if port_is_listening "$protocol" "$port"; then
      printf '%s\t%s\t%s\t%s\n' "$owner" "$protocol" "$port" "${source:-*}" >>"$active_rules"
    fi
  done <"$desired_rules"

  if [[ "$backend" == "none" && -s "$active_rules" ]]; then
    rm -f "$active_rules" "$desired_rules"
    ui_msg "未检测到可用的 UFW、firewalld 或 iptables，无法开启托管端口。"
    return 1
  fi

  while IFS=$'\t' read -r protocol port; do
    remove_firewall_rule "$protocol" "$port" "*"
    remove_firewall_restriction "$protocol" "$port"
  done < <(awk -F '\t' '{print $2 "\t" $3}' "$active_rules" | sort -u)

  while IFS=$'\t' read -r owner protocol port source; do
    if ! add_firewall_rule "$backend" "$protocol" "$port" "${source:-*}"; then
      failed=true
    fi
  done <"$active_rules"

  if [[ "$backend" == "iptables" ]]; then
    while IFS=$'\t' read -r protocol port; do
      add_firewall_restriction "$backend" "$protocol" "$port" || failed=true
    done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$active_rules" | sort -u)
  fi

  if [[ "$backend" == "ufw" || "$backend" == "firewalld" ]]; then
    while IFS=$'\t' read -r protocol port; do
      add_firewall_restriction "$backend" "$protocol" "$port" || failed=true
    done < <(awk -F '\t' '$4 != "*" {print $2 "\t" $3}' "$active_rules" | sort -u)
  fi

  if [[ "$backend" == "firewalld" ]] && ! firewall-cmd --reload >/dev/null 2>&1; then
    failed=true
  fi
  persist_openrc_firewall_rules

  while IFS=$'\t' read -r owner protocol port source; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    firewall_allow_rule_exists "$backend" "$protocol" "$port" "${source:-*}" || failed=true
  done <"$active_rules"
  while IFS=$'\t' read -r protocol port; do
    [[ -n "$protocol" && -n "$port" ]] || continue
    restricted=false
    awk -F '\t' -v protocol="$protocol" -v port="$port" \
      '$2 == protocol && $3 == port && $4 != "*" {found=1} END {exit !found}' "$active_rules" && restricted=true
    if [[ "$restricted" == "true" ]]; then
      firewall_restriction_exists "$backend" "$protocol" "$port" || failed=true
      firewall_allow_rule_exists "$backend" "$protocol" "$port" "*" && failed=true
    fi
  done < <(awk -F '\t' '{print $2 "\t" $3}' "$active_rules" | sort -u)

  if [[ "$failed" == "true" ]] || ! save_desired_firewall_state; then
    rm -f "$active_rules" "$desired_rules"
    ui_msg "部分托管端口开启失败，请检查防火墙状态后重试。"
    return 1
  fi
  opened="$(awk -F '\t' '{print $2 "\t" $3}' "$active_rules" | sort -u | awk 'NF {count++} END {print count+0}')"
  rm -f "$active_rules" "$desired_rules"
  ui_msg "已开启并验证 ${opened} 个当前正在监听的脚本托管端口。"
}

port_management_menu() {
  local choice
  while true; do
    choice="$(ui_menu "端口管理" "查看全部监听端口；自动开关仅作用于本脚本托管端口。" \
      "1" "查看全部监听端口及占用进程" \
      "2" "查看脚本托管端口状态" \
      "3" "一键关闭未监听的托管端口" \
      "4" "一键开启正在监听的托管端口" \
      "0" "返回上一级菜单" \
      "00" "退出脚本")" || continue
    case "$choice" in
      1) show_all_listening_ports || true ;;
      2) show_managed_port_status || true ;;
      3) close_inactive_managed_ports || true ;;
      4) open_active_managed_ports || true ;;
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

wireguard_generate_address_pair() {
  local subnet relay_address landing_address
  for _ in $(seq 1 100); do
    subnet=$((1 + ((RANDOM * 32768 + RANDOM) % 253)))
    relay_address="10.253.${subnet}.1"
    landing_address="10.253.${subnet}.2"
    if ! jq -e --arg relay "$relay_address" --arg landing "$landing_address" '
      .wireguard.profiles[]? | select(.local_address == $relay or .peer_address == $relay or .local_address == $landing or .peer_address == $landing)
    ' "$REALM_STATE_FILE" >/dev/null 2>&1 &&
      ! ip -o address show 2>/dev/null | grep -Fq " ${relay_address}/" &&
      ! ip -o address show 2>/dev/null | grep -Fq " ${landing_address}/"; then
      printf '%s\t%s\n' "$relay_address" "$landing_address"
      return 0
    fi
  done
  return 1
}

install_wireguard_tools() {
  local test_interface
  detect_pkg_manager
  case "$PKG_MANAGER" in
    apk)
      apk add --no-cache wireguard-tools
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y wireguard-tools
      ;;
    dnf)
      dnf install -y wireguard-tools
      ;;
    yum)
      yum install -y epel-release >/dev/null 2>&1 || true
      yum install -y wireguard-tools
      ;;
    *)
      ui_msg "当前系统不支持自动安装 WireGuard，请手动安装 wireguard-tools。"
      return 1
      ;;
  esac

  if ! have_cmd wg || ! have_cmd wg-quick || ! have_cmd ip; then
    ui_msg "WireGuard 工具安装不完整，缺少 wg、wg-quick 或 ip。"
    return 1
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

offer_wireguard_peer_for_shadowsocks() {
  local peer_address=$1 source current_sources previous_state
  [[ -s "$STATE_FILE" ]] && jq -e '.protocols.shadowsocks.enabled == true' "$STATE_FILE" >/dev/null 2>&1 || return 0
  source="${peer_address}/32"
  if jq -e --arg source "$source" '.protocols.shadowsocks.allowed_sources[]? | select(. == $source)' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi
  current_sources="$(state_get '(.protocols.shadowsocks.allowed_sources // []) | join(", ")')"
  if [[ -z "$current_sources" ]]; then
    ui_yesno "检测到本机 Shadowsocks 当前对全网开放。是否改为只允许 WireGuard 中转来源 ${source}？这会关闭原有公网直连。" || return 0
  else
    ui_yesno "是否将 WireGuard 中转来源 ${source} 加入 Shadowsocks 白名单？当前来源：${current_sources}" || return 0
  fi
  previous_state="$(mktemp "$TMP_DIR/singbox-state-backup.XXXXXX")" || return 1
  install -m 0600 "$STATE_FILE" "$previous_state" || { rm -f "$previous_state"; return 1; }
  if ! state_jq --arg source "$source" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.allowed_sources = ((.protocols.shadowsocks.allowed_sources // []) + [$source] | unique) |
    .meta.updated_at = $ts
  ' || ! apply_config; then
    install -m 0600 "$previous_state" "$STATE_FILE" || true
    apply_config || true
    rm -f "$previous_state"
    ui_msg "Shadowsocks 来源白名单更新失败，已恢复原配置。"
    return 1
  fi
  rm -f "$previous_state"
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
  local code payload id name interface landing_public_key endpoint_host endpoint_port relay_address landing_address mtu public_key response
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
  is_valid_ipv4_or_cidr "${relay_address}/32" && is_valid_ipv4_or_cidr "${landing_address}/32" && [[ "$relay_address" != "$landing_address" ]] || { ui_msg "配对信息中的私网地址无效。"; return 1; }
  if ip -o address show 2>/dev/null | grep -Fq " ${relay_address}/" ||
    ip -o address show 2>/dev/null | grep -Fq " ${landing_address}/"; then
    ui_msg "配对信息中的 WireGuard 私网地址已被本机其他接口占用。"
    return 1
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
  local code payload id relay_public_key relay_address landing_address expected_relay expected_landing interface previous_state
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
  [[ "$relay_address" == "$expected_relay" && "$landing_address" == "$expected_landing" ]] || { ui_msg "响应中的隧道地址与落地端记录不一致。"; return 1; }
  previous_state="$(snapshot_realm_state_file)" || return 1
  if ! realm_state_jq --arg id "$id" --arg peer_public_key "$relay_public_key" --arg ts "$(utc_now)" '
    (.wireguard.profiles[] | select(.id == $id)).peer_public_key = $peer_public_key |
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
  interface="$(wireguard_profile_field "$id" interface)"
  offer_wireguard_peer_for_shadowsocks "$relay_address" || true
  ui_msg "WireGuard 配对已完成。接口 ${interface} 已启动；请在中转端执行隧道测试，确认最近握手和目标端口均正常。落地节点防火墙应允许来源 ${relay_address}/32。"
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

apply_config() {
  local enabled_count tmp_config check_output success_text links_file check_bin port_error
  local service_was_active=false
  ensure_sing_box_service
  enabled_count="$(enabled_protocol_count)"

  if ! prepare_managed_firewall; then
    ui_msg "防火墙环境不可用，配置未应用、现有服务未停止。请执行 sbox repair-install 后重试。"
    return 1
  fi

  if [[ "$enabled_count" -eq 0 ]]; then
    stop_sing_box
    write_client_exports
    if ! sync_managed_firewall_rules; then
      ui_msg "节点已停止，但清理防火墙规则失败，请进入端口管理重试。"
      return 1
    fi
    ui_msg "当前没有启用任何协议，sing-box 服务已停止。"
    return 0
  fi

  normalize_protocol_listen_addresses
  validate_state || return 1

  tmp_config="$(mktemp "$TMP_DIR/singbox-config.XXXXXX")" || {
    ui_msg "无法创建临时配置文件。"
    return 1
  }
  render_config >"$tmp_config"
  chown root:"$RUNTIME_GROUP" "$tmp_config"
  chmod 0640 "$tmp_config"

  check_bin="$(sing_box_check_bin 2>/dev/null || true)"
  if [[ -n "$check_bin" ]]; then
    if ! check_output="$(run_as_runtime "$check_bin" check -c "$tmp_config" 2>&1)"; then
      rm -f "$tmp_config"
      ui_show_text "sing-box 配置检查失败" "$check_output"
      return 1
    fi
  fi

  if service_exists && [[ "$(sing_box_service_active 2>/dev/null || true)" == "active" ]]; then
    service_was_active=true
  fi
  stop_sing_box
  if ! port_error="$(validate_sing_box_listener_ports_available)"; then
    rm -f "$tmp_config"
    if [[ "$service_was_active" == "true" ]]; then
      restart_sing_box >/dev/null 2>&1 || true
    fi
    ui_msg "配置未应用，防火墙未修改。${port_error}"
    return 1
  fi
  if ! apply_firewall_rules; then
    rm -f "$tmp_config"
    ui_msg "防火墙规则同步失败；原配置未替换，服务已保持停止，请先修复防火墙。"
    return 1
  fi

  backup_config_if_exists
  install -o root -g "$RUNTIME_GROUP" -m 0640 "$tmp_config" "$CONFIG_FILE"
  rm -f "$tmp_config"

  write_client_exports
  restart_sing_box || return 1
  if ! verify_sing_box_service_ready; then
    ui_show_text "sing-box 启动后未能建立全部监听端口" "$(sing_box_recent_logs)"
    return 1
  fi

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
  normalize_protocol_listen_addresses
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
  local vless_port port server_password listen_addr method sources_input sources_json current_sources

  prompt_node_name_for_protocol || return 1

  vless_port="$(state_get '.protocols.vless_reality.port')"
  port="$(prompt_number "Shadowsocks 端口" "请输入 Shadowsocks 监听端口" "$(generate_random_service_port_excluding "$vless_port")" 1 65535)" || return 1
  method="$(select_shadowsocks_method "$(state_get '.protocols.shadowsocks.method // "2022-blake3-aes-128-gcm"')")" || return 1
  current_sources="$(state_get '(.protocols.shadowsocks.allowed_sources // []) | join(",")')"
  sources_input="$(prompt_nonempty "Shadowsocks 来源白名单" "请输入允许连接此 SS 节点的来源公网 IP。中转场景请填写中转 VPS 的出口 IP，不要填写端口。多个 IP 使用英文逗号分隔。单个 IPv4 地址与 /32 写法效果相同。公网直连需明确填写 0.0.0.0/0 和/或 ::/0。" "$current_sources")" || return 1
  sources_json="$(build_allowed_sources_json "$sources_input")" || {
    ui_msg "来源白名单格式无效，请填写 IP 或 CIDR。"
    return 1
  }
  server_password="$(generate_shadowsocks_password "$method")"
  listen_addr="$(default_listen_address)"

  state_jq --argjson port "$port" --arg method "$method" --arg server_password "$server_password" --arg listen_addr "$listen_addr" --argjson allowed_sources "$sources_json" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.enabled = true |
    .protocols.shadowsocks.listen = $listen_addr |
    .protocols.shadowsocks.port = $port |
    .protocols.shadowsocks.network = "tcp" |
    .protocols.shadowsocks.method = $method |
    .protocols.shadowsocks.server_password = $server_password |
    .protocols.shadowsocks.multiplex = true |
    .protocols.shadowsocks.allowed_sources = $allowed_sources |
    .meta.updated_at = $ts
  '

  if [[ "$(state_get '.protocols.shadowsocks.users | length')" -eq 0 ]]; then
    append_ss_user "ss-client-1" "$(generate_shadowsocks_password "$method")"
  else
    reset_ss_user_passwords_for_method "$method"
  fi

  apply_config
}

configure_shadowsocks_allowed_sources() {
  local current_sources sources_input sources_json

  if [[ "$(state_get '.protocols.shadowsocks.enabled')" != "true" ]]; then
    ui_msg "Shadowsocks 当前未启用。"
    return 0
  fi

  current_sources="$(state_get '(.protocols.shadowsocks.allowed_sources // []) | join(",")')"
  sources_input="$(prompt_nonempty "Shadowsocks 来源白名单" "请输入允许连接此 SS 节点的来源公网 IP。中转场景请填写中转 VPS 的出口 IP，不要填写端口。多个 IP 使用英文逗号分隔。单个 IPv4 地址与 /32 写法效果相同。公网直连需明确填写 0.0.0.0/0 和/或 ::/0。" "$current_sources")" || return 1
  sources_json="$(build_allowed_sources_json "$sources_input")" || {
    ui_msg "来源白名单格式无效，请填写 IP 或 CIDR。"
    return 1
  }

  state_jq --argjson allowed_sources "$sources_json" --arg ts "$(utc_now)" '
    .protocols.shadowsocks.allowed_sources = $allowed_sources |
    .meta.updated_at = $ts
  '
  if ! prepare_managed_firewall; then
    ui_msg "防火墙环境不可用，来源白名单已保存但尚未应用；现有服务未停止。请执行 sbox repair-install 后重试。"
    return 1
  fi
  stop_sing_box
  if ! sync_managed_firewall_rules; then
    ui_msg "来源白名单已保存，但防火墙同步失败；sing-box 已保持停止，请修复防火墙后重试。"
    return 1
  fi
  restart_sing_box || return 1
  ui_msg "Shadowsocks 来源白名单已更新并同步到防火墙。"
}

configure_vless_reality() {
  local ss_port port sni handshake_port keypair private_key public_key short_id listen_addr

  prompt_node_name_for_protocol || return 1

  ss_port="$(state_get '.protocols.shadowsocks.port')"
  port="$(prompt_number "VLESS 端口" "请输入 VLESS + Reality 监听端口" "$(generate_random_service_port_excluding "$ss_port")" 1 65535)" || return 1
  sni="$(prompt_nonempty "Reality SNI" "请输入第三方 Reality 伪装域名（例如 www.cloudflare.com，不能填写本机 IP 或节点域名）" "www.tesla.com")" || return 1
  handshake_port="$(prompt_number "Reality 握手端口" "请输入 Reality 伪装站点端口" "443" 1 65535)" || return 1

  keypair="$(generate_reality_keypair)"
  private_key="${keypair%%$'\t'*}"
  public_key="${keypair##*$'\t'}"
  short_id="$(generate_hex 8)"
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

node_menu_text() {
  cat <<EOF
节点地址：$(state_get '.meta.server_address // "-"')
Shadowsocks：$(state_get '.protocols.shadowsocks.enabled')
VLESS + Reality：$(state_get '.protocols.vless_reality.enabled')
Hysteria2：$(state_get '.protocols.hysteria2.enabled')

请选择要执行的节点操作（输入 0 返回上一级，输入 00 退出脚本）
EOF
}

build_node() {
  local protocol_choice detected_address server_address

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

  detected_address="$(detect_public_address)"
  server_address="$(prompt_nonempty "节点出口地址" "请输入节点出口 IP 或域名(留空默认使用本机 IP)" "$detected_address")" || return 1
  state_jq --arg addr "$server_address" --arg ts "$(utc_now)" \
    '.meta.server_address = $addr | .meta.updated_at = $ts'

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
  local current_address new_address
  local vless_server_name handshake_server

  current_address="$(state_get '.meta.server_address // ""')"
  new_address="$(prompt_nonempty "更改节点地址" "请输入新的节点出口 IP 或域名" "$current_address")" || return 1

  if [[ "$new_address" == "$current_address" ]]; then
    ui_msg "节点地址未发生变化。"
    return 0
  fi

  if [[ "$(state_get '.protocols.vless_reality.enabled')" == "true" ]]; then
    vless_server_name="$(state_get '.protocols.vless_reality.server_name')"
    handshake_server="$(state_get '.protocols.vless_reality.handshake_server')"
    if [[ "$new_address" == "$vless_server_name" || "$new_address" == "$handshake_server" ]]; then
      ui_msg "新的节点地址不能与 VLESS + Reality 的伪装域名相同。"
      return 1
    fi
  fi

  state_jq --arg addr "$new_address" --arg ts "$(utc_now)" \
    '.meta.server_address = $addr | .meta.updated_at = $ts'

  apply_config
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
      "7" "设置 Shadowsocks 来源白名单" \
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
        configure_shadowsocks_allowed_sources || true
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
  local choice selected_index protocol label cert_path key_path
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
      if [[ "$cert_path" == "$CERT_DIR/"* && "$key_path" == "$CERT_DIR/"* ]]; then
        rm -f "$cert_path" "$key_path" 2>/dev/null || true
      fi
      ;;
  esac

  apply_config || return 0
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
  local is_new=0 current_enabled current_type current_server current_port current_username current_password current_method current_rules current_domains
  local type_choice outbound_type server port username password method_choice method rules_input rules_json name yesno_result
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
    current_domains="[]"
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
      | map(select(startswith("domain:") | not))
      | join(", ")
    ')"
    current_domains="$(jq -c --arg id "$outbound_id" '
      [.routing.split.outbounds[]
        | select(.id == $id)
        | (.rule_sets // [])[]
        | select(startswith("domain:"))
      ]
    ' "$STATE_FILE")"
  fi

  if (( ! is_new )); then
    if ui_yesno "是否启用并编辑落地 ${name}？选择否将停用该落地。当前状态：${current_enabled}"; then
      :
    else
      yesno_result=$?
      (( yesno_result == 2 )) && return 1
      state_jq --arg id "$outbound_id" --arg ts "$(utc_now)" '
        (.routing.split.outbounds[] | select(.id == $id) | .enabled) = false |
        .meta.updated_at = $ts
      '
      apply_config
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
  username="$current_username"
  method="$current_method"

  if [[ "$outbound_type" == "socks" ]]; then
    username="$(prompt_nonempty "分流落地用户名" "请输入 SOCKS5 用户名" "$current_username")" || return 1
  else
    method_choice="$(ui_split_shadowsocks_method_menu "$current_method")" || return 1
    case "$method_choice" in
      1) method="2022-blake3-aes-128-gcm" ;;
      2) method="2022-blake3-aes-256-gcm" ;;
      3) method="2022-blake3-chacha20-poly1305" ;;
      0) return 0 ;;
      *) ui_msg "无效加密方式，请重新选择。"; return 1 ;;
    esac
    method="$(normalize_shadowsocks_method "$method")"
  fi

  while (( password_attempts < 2 )); do
    password="$(ui_password "分流落地密码" "请输入落地密码；留空则保留当前密码")" || return 1
    [[ -n "$password" ]] || password="$current_password"
    if [[ -n "$password" && "$password" != "null" ]]; then
      break
    fi

    password_attempts=$((password_attempts + 1))
    if (( password_attempts >= 2 )); then
      ui_input_error_return
      return 1
    fi
    printf '落地密码不能为空，再次输错将退回菜单界面。\n' >&2
  done

  rules_input="$(ui_input "落地关键词规则" "请输入该落地绑定的关键词，可用逗号或空格分隔；已有网址规则会保留" "$current_rules")" || return 1
  rules_json="$(build_split_rules_json "$rules_input")"

  state_jq --arg id "$outbound_id" --arg name "$name" --arg outbound_type "$outbound_type" \
    --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" \
    --arg method "$method" --argjson rules "$rules_json" --argjson domains "$current_domains" --arg ts "$(utc_now)" '
    (($rules + $domains) | unique) as $all_rules |
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
  '

  if [[ "$(jq -nc --argjson rules "$rules_json" --argjson domains "$current_domains" '$rules + $domains | length')" -eq 0 ]]; then
    ui_msg "落地已保存但未启用，请为它添加至少一个关键词或网址分流规则。"
  else
    apply_config
  fi
}

edit_split_routing() {
  local outbound_id
  outbound_id="$(select_split_outbound_id "编辑分流落地" "请选择要编辑或停用的落地")" || return 0
  configure_split_routing "$outbound_id"
}

delete_split_outbound() {
  local outbound_id name
  outbound_id="$(select_split_outbound_id "删除分流落地" "请选择要删除的落地")" || return 0
  name="$(state_get --arg id "$outbound_id" '.routing.split.outbounds[] | select(.id == $id) | .name')"
  ui_yesno "确认删除分流落地 ${name} 及其全部规则集吗？" || return 0
  state_jq --arg id "$outbound_id" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(select(.id != $id)) |
    .meta.updated_at = $ts
  '
  apply_config
}

show_split_routing_rules() {
  local summary
  summary="$(jq -r '
    if (.routing.split.outbounds // [] | length) == 0 then
      "当前没有分流落地。"
    else
      .routing.split.outbounds
      | map(
          "[\(.name)]\n"
          + "enabled = \(.enabled // false)\n"
          + "outbound = \(.outbound_type // "socks")\n"
          + "address = \(.server):\(.port)\n"
          + "username = \(.username // "-")\n"
          + "method = \(.method // "-")\n"
          + "keyword_rules = \((.rule_sets // []) | map(select(startswith("domain:") | not)) | join(", "))\n"
          + "domains = \((.rule_sets // []) | map(select(startswith("domain:")) | ltrimstr("domain:")) | join(", "))"
        )
      | join("\n\n")
    end
  ' "$STATE_FILE")"
  ui_show_text "分流落地与分流规则" "$summary"
}

append_split_routing_rules() {
  local outbound_id rule_type rules_input rules_json
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
      0) return 0 ;;
      *) ui_msg "无效选项，请重新选择。"; return 1 ;;
    esac
  fi
  if [[ "$rule_type" == "domain" ]]; then
    rules_json="$(build_split_domains_json "$rules_input")"
  else
    rules_json="$(build_split_rules_json "$rules_input")"
  fi
  [[ "$(printf '%s' "$rules_json" | jq -r 'length')" -gt 0 ]] || {
    if [[ "$rule_type" == "domain" ]]; then
      ui_msg "网址格式无效，请输入类似 nodeseek.com 的域名。"
    else
      ui_msg "关键词规则格式无效。"
    fi
    return 1
  }
  state_jq --arg id "$outbound_id" --argjson rules "$rules_json" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(
      if .id == $id then
        .rule_sets = (((.rule_sets // []) + $rules) | unique) |
        .enabled = true
      else
        .rule_sets = ((.rule_sets // []) - $rules) |
        .enabled = ((.enabled // false) and ((.rule_sets | length) > 0))
      end
    ) |
    .meta.updated_at = $ts
  '
  apply_config
}

delete_split_routing_rule() {
  local outbound_id total_count choice selected_index selected_rule
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
  state_jq --arg id "$outbound_id" --arg rule "$selected_rule" --arg ts "$(utc_now)" '
    .routing.split.outbounds |= map(
      if .id == $id then
        .rule_sets = ((.rule_sets // []) | map(select(. != $rule))) |
        .enabled = ((.rule_sets | length) > 0)
      else
        .
      end
    ) |
    .meta.updated_at = $ts
  '
  apply_config
}

split_routing_menu_text() {
  cat <<EOF
分流落地数量：$(split_outbound_count)
已启用落地数量：$(state_get '[.routing.split.outbounds[]? | select(.enabled == true)] | length')
分流规则总数：$(state_get '[.routing.split.outbounds[]?.rule_sets[]?] | length')

每个落地可绑定关键词或自定义网址，例如 chatgpt、nodeseek.com。
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

  listen_port="$(realm_prompt_number_limited error_count "本地端口" "请输入需要监听的本地端口" "$(generate_random_service_port)" 10000 60000)" || return 1
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
    listen_start="$(realm_prompt_number_limited error_count "起始端口" "请输入本地起始端口" "$(generate_random_service_port)" 10000 60000)" || return 1
    listen_end="$(realm_prompt_number_limited error_count "结束端口" "请输入本地结束端口" "$listen_start" 10000 60000)" || return 1
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

realm_install_status() {
  if [[ -x "$REALM_BIN" ]]; then
    printf '已安装\n'
  else
    printf '未安装\n'
  fi
}

main_menu_text() {
  local realm_forward_count=0 wireguard_tunnel_count=0

  if ! have_cmd jq; then
    cat <<EOF
Sing-box 状态：$(sing_box_install_status)
管理环境：未初始化

请先选择 1 安装 / 初始化 sing-box
EOF
    return 0
  fi

  if [[ -s "$REALM_STATE_FILE" ]]; then
    realm_forward_count="$(realm_rule_group_count)"
    wireguard_tunnel_count="$(wireguard_profile_count)"
  fi

  cat <<EOF
Sing-box 状态：$(sing_box_install_status)
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
  local server_address service_status ss_users vless_users hy2_users overview node_name links_file
  server_address="$(state_get '.meta.server_address')"
  node_name="$(state_get '.meta.node_name')"

  if service_exists; then
    service_status="$(sing_box_service_active)"
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

[Shadowsocks]
enabled = $(state_get '.protocols.shadowsocks.enabled')
port = $(state_get '.protocols.shadowsocks.port')
allowed_sources = $(state_get 'if ((.protocols.shadowsocks.allowed_sources // []) | length) == 0 then "*（旧配置：全网）" else (.protocols.shadowsocks.allowed_sources | join(", ")) end')
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

[Split Routing]
outbounds = $(state_get '(.routing.split.outbounds // []) | length')
enabled_outbounds = $(state_get '[.routing.split.outbounds[]? | select(.enabled == true)] | length')
rule_sets = $(format_split_rule_list)
EOF
  )

  ui_show_text "当前概览" "$overview"
}

show_service_status() {
  local text="" service_manager
  service_manager="$(sing_box_service_manager)"

  if have_cmd sing-box; then
    text+="sing-box version: $(run_as_runtime sing-box version 2>/dev/null | head -n 1)\n"
  else
    text+="sing-box version: 未安装\n"
  fi

  if service_exists; then
    text+="service manager: ${service_manager}\n"
    text+="service active: $(sing_box_service_active)\n"
    text+="service enabled: $(sing_box_service_enabled)\n"
    text+="\n最近日志:\n"
    text+="$(sing_box_recent_logs)"
  else
    if [[ "$service_manager" != "none" ]]; then
      text+="未检测到 sing-box ${service_manager} 服务。\n"
      text+="可尝试执行：sbox quick-install\n"
      text+="如果 sing-box 已安装，脚本会自动补建服务。"
    else
      text+="当前系统未检测到可用的 systemd 或 OpenRC 环境。"
    fi
  fi

  ui_show_text "服务状态" "$(printf '%b' "$text")"
}

uninstall_sbox() {
  local uninstall_text
  uninstall_text=$'这将执行以下操作：\n- 停止并禁用 sing-box\n- 停止并禁用 Realm 及脚本托管的 sbwg* WireGuard 隧道\n- 卸载 sing-box 软件包（如果存在）\n- 删除脚本托管的节点、Realm、WireGuard 密钥和状态\n- 删除 sbox 与 realm 命令\n\n不会删除非 sbwg* 的用户 WireGuard 配置。是否继续？'

  ui_yesno "$uninstall_text" || return 0

  if have_cmd systemctl; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi
  if has_openrc; then
    rc-service sing-box stop >/dev/null 2>&1 || true
    rc-update del sing-box default >/dev/null 2>&1 || true
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
  rm -f "$SING_BOX_OPENRC_SERVICE_FILE" "$SING_BOX_OPENRC_LOG_FILE" 2>/dev/null || true
  rm -f "$REALM_SERVICE_FILE" /lib/systemd/system/realm.service /usr/lib/systemd/system/realm.service /etc/systemd/system/multi-user.target.wants/realm.service 2>/dev/null || true
  rm -f "$REALM_OPENRC_SERVICE_FILE" "$REALM_OPENRC_LOG_FILE" 2>/dev/null || true
  rm -f "$SING_BOX_HARDENING_DROPIN_FILE" 2>/dev/null || true
  rmdir "$SING_BOX_FIREWALL_DROPIN_DIR" "$REALM_FIREWALL_DROPIN_DIR" 2>/dev/null || true
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
      "8" "更新脚本" \
      "9" "卸载" \
      "0" "退出")" || continue

    if ! have_cmd jq && [[ "$choice" != "1" && "$choice" != "0" ]]; then
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
        show_overview || true
        ;;
      6)
        show_service_status || true
        ;;
      7)
        port_management_menu || true
        ;;
      8)
        update_manager_script || true
        ;;
      9)
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
  $SCRIPT_NAME uninstall      卸载 sing-box 和 sbox
  $SCRIPT_NAME --version      查看脚本版本

说明:
  1. 面板使用纯命令行数字输入，不依赖方向键。
  2. Hysteria2 默认使用自签名证书。
  3. 一键安装使用官方原生 sing-box 软件包。
  4. 支持添加多个 SOCKS5 / Shadowsocks 分流落地，每个落地独立绑定规则集。
  5. 新建 Shadowsocks 节点与分流仅提供 SS2022，并支持来源 IP/CIDR 白名单。
  6. repair-install 会修复 sing-box 核心、权限和服务，但不会删除状态文件、客户端或分流规则。
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
