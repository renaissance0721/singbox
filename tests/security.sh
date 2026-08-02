#!/usr/bin/env bash

set -Eeuo pipefail

fail() {
  printf '[security-test] %s\n' "$*" >&2
  exit 1
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export STATE_DIR="$test_root/state"
export STATE_FILE="$STATE_DIR/state.json"
export BACKUP_DIR="$STATE_DIR/backups"
export CLIENT_DIR="$STATE_DIR/clients"
export CERT_DIR="$STATE_DIR/certs"
export CONFIG_FILE="$test_root/sing-box/config.json"
export REALM_DIR="$test_root/realm"
export REALM_CONFIG_FILE="$REALM_DIR/config.toml"
export REALM_STATE_FILE="$STATE_DIR/realm-state.json"
export FIREWALL_STATE_FILE="$STATE_DIR/firewall-managed.tsv"
export IPTABLES_MIGRATION_MARKER="$STATE_DIR/iptables-comment-rules.migrated"
export TMP_DIR="$test_root/tmp"
mkdir -p "$TMP_DIR"

# Load functions without executing main.
# shellcheck disable=SC1090
source <(sed '$d' "$repo_dir/index.sh")

if [[ "${SBOX_SECURITY_TEST_PORTABLE:-0}" == "1" ]]; then
  install() {
    local directory_mode=false
    while (( $# > 0 )); do
      case "$1" in
        -d) directory_mode=true; shift ;;
        -m|-o|-g) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    if [[ "$directory_mode" == "true" ]]; then
      mkdir -p "$@"
    else
      local source_index=$(( $# - 1 ))
      local source_path="${!source_index}"
      local destination_path="${!#}"
      cp -f "$source_path" "$destination_path"
    fi
  }
  chmod() { :; }
  chown() { :; }
fi

ensure_dirs
reality_private_key="${SBOX_TEST_REALITY_PRIVATE_KEY:-test-private-key}"
cat >"$STATE_FILE" <<EOF
{
  "meta": {
    "version": "$SCRIPT_VERSION",
    "node_name": "security-test",
    "server_address": "203.0.113.10",
    "created_at": "2026-08-02T00:00:00Z",
    "updated_at": "2026-08-02T00:00:00Z",
    "log_level": "info"
  },
  "protocols": {
    "shadowsocks": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": 24442,
      "network": "tcp",
      "method": "2022-blake3-aes-128-gcm",
      "server_password": "",
      "multiplex": true,
      "allowed_sources": [],
      "users": []
    },
    "vless_reality": {
      "enabled": true,
      "listen": "0.0.0.0",
      "port": 24443,
      "server_name": "www.example.com",
      "handshake_server": "www.example.com",
      "handshake_port": 443,
      "private_key": "$reality_private_key",
      "public_key": "test-public-key",
      "short_id": "0123456789abcdef",
      "users": [{"name": "vless-client-1", "uuid": "00000000-0000-4000-8000-000000000001"}]
    },
    "hysteria2": {
      "enabled": false,
      "listen": "0.0.0.0",
      "port": 24444,
      "up_mbps": 100,
      "down_mbps": 100,
      "tls_server_name": "",
      "cert_path": "$CERT_DIR/hysteria2.crt",
      "key_path": "$CERT_DIR/hysteria2.key",
      "obfs_password": "",
      "masquerade": "https://www.example.com",
      "users": []
    }
  },
  "routing": {"split": {"legacy_defaults_removed": true, "outbounds": []}}
}
EOF
chmod 0600 "$STATE_FILE"

rendered="$test_root/rendered.json"
render_config >"$rendered"
if [[ -n "${SBOX_TEST_RENDERED_CONFIG:-}" ]]; then
  cp "$rendered" "$SBOX_TEST_RENDERED_CONFIG"
fi
jq -e '
  ([.route.rules[] | select(.action == "reject" and ((.inbound // []) | index("vless-reality-in")) and .ip_is_private == true)] | length) == 2
  and ([.route.rules[] | select(.action == "reject" and ((.inbound // []) | index("vless-reality-in")) and ((.ip_cidr // []) | index("169.254.169.254/32")))] | length) == 2
  and ([.route.rules[] | select(.action == "resolve" and ((.inbound // []) | index("vless-reality-in")))] | length) == 1
  and .route.final == "direct"
' "$rendered" >/dev/null || fail "VLESS 私网/元数据两阶段阻断规则缺失"

write_client_exports
if [[ "${SBOX_SECURITY_TEST_PORTABLE:-0}" != "1" ]]; then
  [[ "$(stat -c '%a' "$STATE_FILE")" == "600" ]] || fail "state.json 权限不是 0600"
  [[ "$(stat -c '%a' "$CLIENT_DIR/direct-links.txt")" == "600" ]] || fail "direct-links.txt 权限不是 0600"
  [[ "$(stat -c '%a' "$CLIENT_DIR/all-clients.txt")" == "600" ]] || fail "all-clients.txt 权限不是 0600"
  [[ "$(stat -c '%a' "$CLIENT_DIR/vless-reality/vless-client-1.txt")" == "600" ]] || fail "VLESS 客户端文件权限不是 0600"
  [[ "$(stat -c '%a' "$CLIENT_DIR")" == "700" ]] || fail "客户端目录权限不是 0700"
fi

# shellcheck disable=SC2329
port_is_listening() { [[ "$1" == "tcp" && "$2" == "24443" ]]; }
if validate_sing_box_listener_ports_available >/dev/null; then
  fail "端口被占用时仍通过可用性检查"
fi

# shellcheck disable=SC2329
port_is_listening() { return 1; }
state_jq '
  .protocols.shadowsocks.enabled = true |
  .protocols.shadowsocks.port = .protocols.vless_reality.port |
  .protocols.shadowsocks.server_password = "test" |
  .protocols.shadowsocks.users = [{"name":"ss-client-1","password":"test"}]
'
if validate_sing_box_listener_ports_available >/dev/null; then
  fail "协议监听端口重复时仍通过检查"
fi

(
  firewall_log="$test_root/iptables.log"
  # shellcheck disable=SC2329
  iptables() {
    if [[ "$1" == "-S" ]]; then
      printf '%s\n' \
        '-A INPUT -m conntrack --ctstate INVALID -j DROP' \
        '-A INPUT -j DROP'
      return 0
    fi
    printf '%s\n' "$*" >>"$firewall_log"
  }
  add_managed_iptables_rule iptables -p tcp --dport 24443 -j ACCEPT
  grep -Fq -- '-I INPUT 2 -p tcp --dport 24443 -j ACCEPT' "$firewall_log" ||
    fail "iptables 托管规则未放在既有条件规则之后、无条件终止规则之前"
)

if grep -Eq 'iptables[[:space:]]+-I[[:space:]]+INPUT|ip6tables[[:space:]]+-I[[:space:]]+INPUT' "$repo_dir/index.sh"; then
  fail "仍存在插到 INPUT 链首的托管规则"
fi
grep -Fq -- '--comment "$IPTABLES_RULE_COMMENT"' "$repo_dir/index.sh" || fail "iptables 托管规则缺少标记"
grep -Fq 'User=${RUNTIME_USER}' "$repo_dir/index.sh" || fail "systemd sing-box 服务未设置低权限用户"
grep -Fq 'NoNewPrivileges=true' "$repo_dir/index.sh" || fail "systemd 服务缺少 NoNewPrivileges"
grep -Fq "setcap 'cap_net_bind_service=+ep'" "$repo_dir/index.sh" || fail "OpenRC 低权限服务无法兼容低端口监听"

expected_hash="$(sed -n 's/^EXPECTED_INDEX_SHA256="\([A-Fa-f0-9]\{64\}\)"$/\1/p' "$repo_dir/install.sh")"
actual_hash="$(sha256sum "$repo_dir/index.sh" | awk '{print tolower($1)}')"
[[ -n "$expected_hash" && "${expected_hash,,}" == "$actual_hash" ]] || fail "install.sh 内置 index.sh 哈希不匹配"

printf '[security-test] all checks passed\n'
