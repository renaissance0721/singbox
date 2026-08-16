#!/usr/bin/env bash

# shellcheck disable=SC2329

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
  jq() { command jq "$@" | tr -d '\r'; }
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

state_jq '
  .routing.split.outbounds = [
    {
      id: "keyword-route", name: "keyword-route", enabled: true,
      outbound_type: "socks", server: "127.0.0.1", port: 1080,
      username: "", password: "", method: "2022-blake3-aes-128-gcm",
      rule_sets: ["google", "chatgpt"]
    },
    {
      id: "domain-route", name: "domain-route", enabled: true,
      outbound_type: "socks", server: "127.0.0.2", port: 1080,
      username: "", password: "", method: "2022-blake3-aes-128-gcm",
      rule_sets: ["domain:google.com", "domain:mail.google.com"]
    }
  ]
'
split_rendered="$test_root/split-rendered.json"
render_config >"$split_rendered"
jq -e '
  ([.route.rules[] | select(.action == "sniff") | .timeout] == ["300ms"])
  and ([.route.rules[] | select(.action == "route" and ((.outbound // "") | startswith("split-out:"))) | .rule_set[0]] == [
    "split:domain-route:domain:mail.google.com",
    "split:domain-route:domain:google.com",
    "split:keyword-route:chatgpt",
    "split:keyword-route:google"
  ])
  and ([.outbounds[] | select(.tag == "split-out:keyword-route") | has("username")] == [false])
  and ([.outbounds[] | select(.tag == "split-out:keyword-route") | has("password")] == [false])
' "$split_rendered" >/dev/null || fail "分流优先级、sniff 超时或无认证 SOCKS5 渲染错误"
validate_state || fail "无认证 SOCKS5 分流未通过状态校验"
(
  ui_show_text() { :; }
  show_split_routing_rules
) || fail "分流规则展示生成失败"

state_jq '(.routing.split.outbounds[] | select(.id == "keyword-route") | .enabled) = false'
(
  ui_menu() { printf '1\n'; }
  apply_sing_box_state_transaction() { rm -f "$1"; return 0; }
  delete_split_routing_rule
)
jq -e '
  .routing.split.outbounds[]
  | select(.id == "keyword-route")
  | (.enabled == false and (.rule_sets | length) == 1)
' "$STATE_FILE" >/dev/null || fail "从停用落地删除规则后意外重新启用了落地"

state_jq '.meta.log_level = "info"'
transaction_snapshot="$(snapshot_sing_box_state_file)"
state_jq '.meta.log_level = "debug"'
(
  apply_attempt=0
  apply_config() {
    apply_attempt=$((apply_attempt + 1))
    (( apply_attempt > 1 ))
  }
  ui_msg() { :; }
  if apply_sing_box_state_transaction "$transaction_snapshot" "测试分流事务"; then
    fail "失败的分流事务返回了成功状态"
  fi
)
[[ "$(state_get '.meta.log_level')" == "info" ]] || fail "分流应用失败后未恢复原状态"

migration_snapshot="$(snapshot_sing_box_state_file)"
state_jq '
  .routing = {
    ai: {
      enabled: true,
      outbound_type: "socks",
      server: "127.0.0.1",
      port: 1080,
      password: "",
      method: "2022-blake3-aes-128-gcm",
      domain_suffix: ["example.com"],
      domain_keyword: ["brand"]
    }
  }
'
migrate_state_schema
jq -e '
  (.routing.split.outbounds[0].rule_sets | index("domain:example.com")) != null
  and (.routing.split.outbounds[0].rule_sets | index("brand")) != null
' "$STATE_FILE" >/dev/null || fail "旧版域名后缀迁移成了不精确的关键词规则"

state_jq '
  .routing = {
    split: {
      enabled: true,
      outbound_type: "socks",
      server: "127.0.0.1",
      port: 1080,
      username: "",
      password: "",
      method: "2022-blake3-aes-128-gcm",
      rule_sets: ["openai.com", "my-custom-rule"]
    }
  }
'
migrate_state_schema
jq -e '
  (.routing.split.outbounds[0].rule_sets | index("openai.com")) != null
  and (.routing.split.outbounds[0].rule_sets | index("my-custom-rule")) != null
' "$STATE_FILE" >/dev/null || fail "旧版迁移误删了用户自定义的常见域名规则"
install -m 0600 "$migration_snapshot" "$STATE_FILE"
rm -f "$migration_snapshot"
state_jq '.routing.split.outbounds = []'

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
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$repo_dir/index.sh" ||
  fail "sing-box systemd service does not allow required AF_NETLINK route updates"
grep -Fq 'repair_sing_box_netlink_hardening' "$repo_dir/index.sh" ||
  fail "Existing sing-box installations do not auto-repair missing AF_NETLINK access"
grep -Fq 'Restart=always' "$repo_dir/index.sh" || fail "Realm systemd service does not restart after every unexpected exit"
grep -Fq "setcap 'cap_net_bind_service=+ep'" "$repo_dir/index.sh" || fail "OpenRC 低权限服务无法兼容低端口监听"
grep -Fq 'SCRIPT_REPO_ID="1210354428"' "$repo_dir/index.sh" || fail "自动更新未固定 GitHub 仓库数字 ID"
grep -Fq 'SCRIPT_REPO_OWNER_ID="197479185"' "$repo_dir/index.sh" || fail "自动更新未固定 GitHub 所有者数字 ID"
[[ "$(grep -Fc 'install -d -m 0755 /etc/apt/keyrings' "$repo_dir/index.sh")" -eq 2 ]] ||
  fail "APT keyrings 目录未显式允许 _apt 用户读取签名密钥"
grep -Fq 'git_blob_sha1_file "$api_copy"' "$repo_dir/index.sh" || fail "自动更新未校验 GitHub API 内容的 Git blob 哈希"
grep -Fq 'git_blob_sha1_file "$raw_copy"' "$repo_dir/index.sh" || fail "自动更新未校验不可变 Raw 内容的 Git blob 哈希"
grep -Fq '"$actual_sha256" != "$api_sha256"' "$repo_dir/index.sh" || fail "自动更新未交叉校验 API 与原始文件的 SHA-256"
grep -Fq 'cp -f "$api_copy" "$project_dir/index.sh"' "$repo_dir/index.sh" || fail "Raw 不可用时未回退到已认证的 GitHub API 内容"
grep -Fq 'mktemp "$(dirname "$target_path")/.sbox-update.XXXXXX"' "$repo_dir/index.sh" || fail "自动更新未使用同目录临时文件原子替换"
if grep -q 'SBOX_UPDATE_INDEX_SHA256\|请输入可信发布说明中 index.sh' "$repo_dir/index.sh"; then
  fail "自动更新仍要求手动输入 SHA-256"
fi
grep -Fq '"12" "卸载 Realm"' "$repo_dir/index.sh" || fail "Realm 卸载选项未移动到操作菜单末尾"
grep -Fq 'realm_install_or_reset || true' "$repo_dir/index.sh" || fail "Realm 菜单未捕获操作失败状态"
grep -Fq 'quick_install || true' "$repo_dir/index.sh" || fail "主菜单未捕获操作失败状态"
grep -Fq 'read -r _ || true' "$repo_dir/index.sh" || fail "按回车返回菜单仍可能把读取状态传递为脚本失败"
grep -Fq 'if [[ -v BASH_SOURCE ]]; then' "$repo_dir/install.sh" ||
  fail "install.sh 通过标准输入执行时仍可能因 BASH_SOURCE[0] 未定义而退出"

menu_counter_file="$test_root/menu-counter"
printf '0\n' >"$menu_counter_file"
set +e
menu_test_output="$(REPO_DIR="$repo_dir" MENU_COUNTER_FILE="$menu_counter_file" bash -c '
  set -Eeuo pipefail
  source <(sed "\$d" "$REPO_DIR/index.sh")
  main_menu_text() { printf "test\n"; }
  have_cmd() { return 0; }
  quick_install() { return 1; }
  ui_menu() {
    local count
    count="$(cat "$MENU_COUNTER_FILE")"
    count=$((count + 1))
    printf "%s\n" "$count" >"$MENU_COUNTER_FILE"
    if (( count == 1 )); then printf "1\n"; else printf "0\n"; fi
  }
  main_menu
  printf "menu-survived\n"
')"
menu_test_status=$?
set -e
[[ "$menu_test_status" -eq 0 && "$menu_test_output" == *menu-survived* && "$(cat "$menu_counter_file")" -eq 2 ]] ||
  fail "主菜单操作返回非零状态后仍会退出脚本"

printf '0\n' >"$menu_counter_file"
set +e
main_view_test_output="$(REPO_DIR="$repo_dir" MENU_COUNTER_FILE="$menu_counter_file" bash -c '
  set -Eeuo pipefail
  source <(sed "\$d" "$REPO_DIR/index.sh")
  main_menu_text() { printf "test\n"; }
  have_cmd() { [[ "$1" == "jq" ]]; }
  service_exists() { return 1; }
  ui_show_text() { printf "view:%s\n" "$1"; return 0; }
  ui_menu() {
    local count
    count="$(cat "$MENU_COUNTER_FILE")"
    count=$((count + 1))
    printf "%s\n" "$count" >"$MENU_COUNTER_FILE"
    case "$count" in
      1) printf "5\n" ;;
      2) printf "6\n" ;;
      *) printf "0\n" ;;
    esac
  }
  main_menu
  printf "main-view-menu-survived\n"
')"
main_view_test_status=$?
set -e
[[ "$main_view_test_status" -eq 0 && "$main_view_test_output" == *view:当前概览* &&
   "$main_view_test_output" == *view:服务状态* && "$main_view_test_output" == *main-view-menu-survived* &&
   "$(cat "$menu_counter_file")" -eq 3 ]] ||
  fail "查看当前概览或服务状态后仍会退出主菜单"

printf '0\n' >"$menu_counter_file"
set +e
realm_menu_test_output="$(REPO_DIR="$repo_dir" MENU_COUNTER_FILE="$menu_counter_file" bash -c '
  set -Eeuo pipefail
  source <(sed "\$d" "$REPO_DIR/index.sh")
  realm_menu_text() { printf "test\n"; }
  realm_install_or_reset() { return 1; }
  ui_menu() {
    local count
    count="$(cat "$MENU_COUNTER_FILE")"
    count=$((count + 1))
    printf "%s\n" "$count" >"$MENU_COUNTER_FILE"
    if (( count == 1 )); then printf "2\n"; else printf "0\n"; fi
  }
  realm_submenu
  printf "realm-menu-survived\n"
')"
realm_menu_test_status=$?
set -e
[[ "$realm_menu_test_status" -eq 0 && "$realm_menu_test_output" == *realm-menu-survived* && "$(cat "$menu_counter_file")" -eq 2 ]] ||
  fail "Realm 操作返回非零状态后仍会退出脚本"

blob_fixture="$test_root/git-blob-fixture.txt"
printf 'hello\n' >"$blob_fixture"
[[ "$(git_blob_sha1_file "$blob_fixture")" == "ce013625030ba8dba906f756967f9e9ca394464a" ]] ||
  fail "Git blob 哈希计算不正确"
[[ "$(sha256_file "$blob_fixture")" == "$(sha256sum "$blob_fixture" | awk '{print tolower($1)}')" ]] ||
  fail "SHA-256 文件计算函数异常或引用了未初始化变量"

ss2022_method="2022-blake3-aes-128-gcm"
ss2022_password="AQIDBAUGBwgJCgsMDQ4PEA==:ERITFBUWFxgZGhscHR4fIA=="
ss2022_userinfo="$(base64_urlsafe "${ss2022_method}:${ss2022_password}")"
[[ "$ss2022_userinfo" == 'MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206QVFJREJBVUdCd2dKQ2dzTURRNFBFQT09OkVSSVRGQlVXRnhnWkdoc2NIUjRmSUE9PQ' ]] ||
  fail "SS2022 Shadowrocket 兼容 userinfo 的 Base64URL 编码不正确"
grep -Fq 'link="ss://$(base64_urlsafe "${ss_method}:${ss_share_password}")@${host}:${ss_port}#$(uri_encode "$display_name")"' "$repo_dir/index.sh" ||
  fail "SS2022 分享链接未使用 Shadowrocket 兼容的 Base64URL userinfo"
if grep -Fq 'link="ss://$(uri_encode "$ss_method"):$(uri_encode "$ss_share_password")@' "$repo_dir/index.sh"; then
  fail "SS2022 分享链接仍直接在 ss:// 后输出加密方式"
fi

wg_pairing_json='{"kind":"sbox-wireguard-invite-v1","tunnel_id":"wg-test","name":"test"}'
wg_pairing_code="$(wireguard_encode_pairing_json "$wg_pairing_json")"
[[ "$wg_pairing_code" == SBOXWG1:* ]] || fail "WireGuard 配对信息缺少固定版本前缀"
[[ "$(wireguard_decode_pairing_code "$wg_pairing_code")" == "$wg_pairing_json" ]] ||
  fail "WireGuard 配对信息无法无损编码和解码"
if wireguard_decode_pairing_code 'SBOXWG1:%%%%' >/dev/null 2>&1; then
  fail "损坏的 WireGuard 配对信息仍被接受"
fi
wireguard_valid_allowed_source '198.51.100.9' || fail "WireGuard 拒绝有效的单一中转来源"
if wireguard_valid_allowed_source '0.0.0.0/0'; then
  fail "WireGuard 落地端错误允许全网来源"
fi

(
  migration_root="$test_root/wireguard-migration"
  mkdir -p "$migration_root"
  REALM_STATE_FILE="$migration_root/realm-state.json"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"meta":{},"global":{"use_udp":false,"no_tcp":false},"rules":[{"id":"legacy","type":"single","entries":[{"listen":"0.0.0.0:30001","remote":"192.0.2.1:443"}]}]}
EOF
  migrate_realm_wireguard_schema || fail "Realm WireGuard 状态迁移失败"
  jq -e '
    .meta.realm_wireguard_schema == 1
    and (.wireguard.profiles | type == "array" and length == 0)
    and .rules[0].mode == "direct"
    and .rules[0].tunnel_id == null
  ' "$REALM_STATE_FILE" >/dev/null || fail "旧 Realm 规则未安全迁移为 direct"
)

(
  render_root="$test_root/wireguard-render"
  mkdir -p "$render_root/wireguard"
  REALM_STATE_FILE="$render_root/realm-state.json"
  # Used by sourced WireGuard path helpers.
  # shellcheck disable=SC2034
  WIREGUARD_DIR="$render_root/wireguard"
  test_wg_key="$(printf '01234567890123456789012345678901' | openssl base64 -A)"
  printf '%s\n' "$test_wg_key" >"$(wireguard_private_key_file sbwg0)"
  cat >"$REALM_STATE_FILE" <<EOF
{
  "meta":{"realm_wireguard_schema":1},
  "global":{"log_level":"warn","log_output":"stdout","use_udp":false,"no_tcp":false},
  "wireguard":{"profiles":[{
    "id":"wg-test","name":"test","interface":"sbwg0","role":"relay",
    "local_address":"10.253.10.1","peer_address":"10.253.10.2",
    "public_key":"$test_wg_key","peer_public_key":"$test_wg_key",
    "endpoint_host":"198.51.100.2","endpoint_port":51820,"listen_port":null,
    "allowed_source":null,"mtu":1420,"persistent_keepalive":25,"enabled":true,"paired":true
  }]},
  "rules":[{"id":"wg-rule","mode":"wireguard","tunnel_id":"wg-test","entries":[{"listen":"0.0.0.0:30001","remote":"10.253.10.2:443"}]}]
}
EOF
  rendered_wg="$(render_wireguard_profile_config wg-test)" || fail "WireGuard 配置渲染失败"
  grep -Fq 'Address = 10.253.10.1/32' <<<"$rendered_wg" || fail "WireGuard 本地地址未限制为 /32"
  grep -Fq 'AllowedIPs = 10.253.10.2/32' <<<"$rendered_wg" || fail "WireGuard 对端路由未限制为 /32"
  if grep -Fq '0.0.0.0/0' <<<"$rendered_wg"; then
    fail "WireGuard 配置错误接管默认路由"
  fi
  grep -Fq 'Endpoint = 198.51.100.2:51820' <<<"$rendered_wg" || fail "WireGuard Endpoint 渲染错误"
  rendered_realm="$(render_realm_config)" || fail "包含 WireGuard 规则的 Realm 配置渲染失败"
  grep -Fq 'use_udp = false' <<<"$rendered_realm" || fail "WireGuard 模式意外开启 Realm UDP"
  grep -Fq 'remote = "10.253.10.2:443"' <<<"$rendered_realm" || fail "Realm 未指向 WireGuard 对端私网地址"
  wireguard_profile_route_ready() { return 0; }
  ensure_realm_wireguard_dependencies || fail "有效的 Realm WireGuard 依赖被拒绝"
  realm_state_jq '(.wireguard.profiles[] | select(.id == "wg-test")).enabled = false'
  if ensure_realm_wireguard_dependencies; then
    fail "Realm 错误接受已停用的 WireGuard 依赖"
  fi
)

(
  firewall_root="$test_root/wireguard-firewall"
  mkdir -p "$firewall_root"
  STATE_FILE="$firewall_root/state.json"
  REALM_STATE_FILE="$firewall_root/realm-state.json"
  cat >"$STATE_FILE" <<'EOF'
{"protocols":{"shadowsocks":{"enabled":false},"vless_reality":{"enabled":false},"hysteria2":{"enabled":false}}}
EOF
  cat >"$REALM_STATE_FILE" <<'EOF'
{"wireguard":{"profiles":[{"role":"landing","enabled":true,"listen_port":51820,"allowed_source":"198.51.100.9/32"}]},"rules":[]}
EOF
  desired_managed_firewall_rules | grep -Fq $'wireguard\tudp\t51820\t198.51.100.9/32' ||
    fail "WireGuard 落地端 UDP 端口未限制为中转来源"
)

grep -Fq '.global.use_udp = false' "$repo_dir/index.sh" || fail "Realm TCP-only 约束被 WireGuard 功能意外移除"
grep -Fq 'AllowedIPs = ${peer_address}/32' "$repo_dir/index.sh" || fail "WireGuard 配置未固定对端 /32 路由"
if grep -Fq 'net.ipv4.ip_forward=1' "$repo_dir/index.sh" || grep -Fq 'MASQUERADE' "$repo_dir/index.sh"; then
  fail "WireGuard Realm 模式不应启用全局转发或 NAT"
fi

(
  # Used by sourced Realm menu preparation.
  # shellcheck disable=SC2034
  REALM_BIN="$test_root/not-installed-realm"
  require_linux() { :; }
  require_root() { :; }
  realm_service_manager() { printf 'systemd\n'; }
  ensure_realm_dirs() { :; }
  init_realm_state_file() { :; }
  install_realm_binary() { fail "进入 WireGuard/Realm 菜单时不应强制安装 Realm"; }
  ensure_realm_service() { fail "Realm 未安装时不应创建无效服务"; }
  prepare_realm_menu || fail "未安装 Realm 时无法进入 WireGuard 管理菜单"
)

(
  repair_root="$test_root/sing-box-netlink-repair"
  mkdir -p "$repair_root"
  SING_BOX_HARDENING_DROPIN_FILE="$repair_root/20-sbox-hardening.conf"
  printf '[Service]\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6\n' >"$SING_BOX_HARDENING_DROPIN_FILE"
  ensure_calls=0
  restart_calls=0
  verify_calls=0
  sing_box_service_manager() { printf 'systemd\n'; }
  have_cmd() { [[ "$1" == "sing-box" ]]; }
  service_exists() { return 0; }
  systemctl() {
    if [[ "$1" == "show" && "$4" == "ActiveState" ]]; then
      printf 'activating\n'
    elif [[ "$1" == "show" && "$4" == "SubState" ]]; then
      printf 'auto-restart-queued\n'
    elif [[ "$1" == "restart" ]]; then
      restart_calls=$((restart_calls + 1))
    fi
  }
  ensure_sing_box_service() {
    ensure_calls=$((ensure_calls + 1))
    printf '[Service]\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK\n' >"$SING_BOX_HARDENING_DROPIN_FILE"
  }
  verify_sing_box_service_ready() { verify_calls=$((verify_calls + 1)); }

  repair_sing_box_netlink_hardening || fail "Existing sing-box AF_NETLINK restriction was not repaired"
  [[ "$ensure_calls" -eq 1 && "$restart_calls" -eq 1 && "$verify_calls" -eq 1 ]] ||
    fail "AF_NETLINK repair did not reload, restart, and verify the crashed sing-box service"
  repair_sing_box_netlink_hardening || fail "Already repaired AF_NETLINK restriction was rejected"
  [[ "$ensure_calls" -eq 1 && "$restart_calls" -eq 1 && "$verify_calls" -eq 1 ]] ||
    fail "AF_NETLINK repair was not idempotent"
)

(
  readiness_root="$test_root/sing-box-readiness"
  mkdir -p "$readiness_root"
  STATE_FILE="$readiness_root/state.json"
  cat >"$STATE_FILE" <<'EOF'
{"protocols":{"shadowsocks":{"enabled":true,"port":29991},"vless_reality":{"enabled":false,"port":29992},"hysteria2":{"enabled":false,"port":29993}}}
EOF
  service_exists() { return 0; }
  sing_box_service_active() { printf 'active\n'; }
  port_is_listening() {
    local checked_port=${2%$'\r'}
    [[ "$1" == "tcp" && "$checked_port" == "29991" ]]
  }
  sleep() { fail "Ready sing-box service unnecessarily waited"; }
  verify_sing_box_service_ready || fail "Ready sing-box listener failed post-start verification"
)

(
  validation_root="$test_root/realm-port-validation"
  mkdir -p "$validation_root"
  REALM_STATE_FILE="$validation_root/state.json"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"rules":[{"id":"old","entries":[{"listen":"0.0.0.0:30001","remote":"192.0.2.1:30001"}]}]}
EOF
  previous_state_file="$(snapshot_realm_state_file)"
  realm_state_jq '.rules += [{"id":"new","entries":[{"listen":"0.0.0.0:30002","remote":"192.0.2.2:30002"}]}]'
  checked_ports=""
  have_cmd() { [[ "$1" == "ss" ]]; }
  port_is_listening() {
    local checked_port=${2%$'\r'}
    checked_ports="${checked_ports}${checked_ports:+,}${checked_port}"
    [[ "$checked_port" == "30001" ]]
  }
  validate_realm_listener_ports_available "$previous_state_file" true ||
    fail "Running Realm's existing listener was treated as a port conflict"
  [[ "$checked_ports" == "30002" ]] ||
    fail "Realm port validation did not limit checks to newly added listeners"
  rm -f "$previous_state_file"
)

(
  readiness_root="$test_root/realm-readiness"
  mkdir -p "$readiness_root"
  REALM_STATE_FILE="$readiness_root/state.json"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"rules":[{"id":"ready","entries":[{"listen":"0.0.0.0:30501","remote":"192.0.2.1:30501"},{"listen":"0.0.0.0:30502","remote":"192.0.2.2:30502"}]}]}
EOF
  realm_service_exists() { return 0; }
  realm_service_active() { printf 'active\n'; }
  port_is_listening() { return 0; }
  sleep() { fail "Ready Realm service unnecessarily waited"; }
  verify_realm_service_ready || fail "Ready Realm service failed readiness verification"
)

(
  transaction_root="$test_root/realm-firewall-failure"
  mkdir -p "$transaction_root"
  REALM_STATE_FILE="$transaction_root/state.json"
  REALM_CONFIG_FILE="$transaction_root/config.toml"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"global":{"log_level":"warn","log_output":"stdout","use_udp":false,"no_tcp":false},"rules":[{"id":"old","entries":[{"listen":"0.0.0.0:31001","remote":"192.0.2.1:31001"}]}],"meta":{}}
EOF
  printf 'old-config\n' >"$REALM_CONFIG_FILE"
  previous_state_file="$(snapshot_realm_state_file)"
  realm_state_jq '.rules += [{"id":"new","entries":[{"listen":"0.0.0.0:31002","remote":"192.0.2.2:31002"}]}]'

  rollback_sync_calls=0
  ensure_realm_dirs() { :; }
  init_realm_state_file() { :; }
  ensure_realm_service() { :; }
  prepare_managed_firewall() { :; }
  realm_service_exists() { return 0; }
  realm_service_active() { printf 'active\n'; }
  validate_realm_listener_ports_available() { :; }
  preflight_realm_config() { :; }
  realm_apply_firewall_rules() { return 1; }
  sync_managed_firewall_rules() { rollback_sync_calls=$((rollback_sync_calls + 1)); }
  write_realm_config_file() { fail "Realm config was written after firewall failure"; }
  stop_realm_service_raw() { fail "Realm was stopped after firewall failure"; }
  restart_realm_service_raw() { fail "Realm was restarted after firewall failure"; }
  ui_msg() { :; }

  if apply_realm_config "$previous_state_file"; then
    fail "Realm firewall failure was reported as success"
  fi
  jq -e '.rules | length == 1 and .[0].id == "old"' "$REALM_STATE_FILE" >/dev/null ||
    fail "Realm state was not restored after firewall failure"
  [[ "$(cat "$REALM_CONFIG_FILE")" == "old-config" ]] ||
    fail "Realm config changed after firewall failure"
  [[ "$rollback_sync_calls" -eq 1 ]] ||
    fail "Realm firewall rollback did not run exactly once"
)

(
  transaction_root="$test_root/realm-readiness-failure"
  mkdir -p "$transaction_root"
  REALM_STATE_FILE="$transaction_root/state.json"
  REALM_CONFIG_FILE="$transaction_root/config.toml"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"global":{"log_level":"warn","log_output":"stdout","use_udp":false,"no_tcp":false},"rules":[{"id":"old","entries":[{"listen":"0.0.0.0:32001","remote":"192.0.2.1:32001"}]}],"meta":{}}
EOF
  printf 'old-config\n' >"$REALM_CONFIG_FILE"
  previous_state_file="$(snapshot_realm_state_file)"
  realm_state_jq '.rules += [{"id":"new","entries":[{"listen":"0.0.0.0:32002","remote":"192.0.2.2:32002"}]}]'

  restart_calls=0
  readiness_calls=0
  ensure_realm_dirs() { :; }
  init_realm_state_file() { :; }
  ensure_realm_service() { :; }
  prepare_managed_firewall() { :; }
  realm_service_exists() { return 0; }
  realm_service_active() { printf 'active\n'; }
  validate_realm_listener_ports_available() { :; }
  preflight_realm_config() { :; }
  realm_apply_firewall_rules() { :; }
  sync_managed_firewall_rules() { :; }
  write_realm_config_file() { printf 'new-config\n' >"$REALM_CONFIG_FILE"; }
  enable_realm_service() { :; }
  restart_realm_service_raw() { restart_calls=$((restart_calls + 1)); }
  start_realm_service_raw() { fail "Rollback unexpectedly used start instead of restart"; }
  stop_realm_service_raw() { fail "Rollback unexpectedly stopped Realm"; }
  verify_realm_service_ready() {
    readiness_calls=$((readiness_calls + 1))
    (( readiness_calls >= 2 ))
  }
  realm_recent_logs() { :; }
  ui_show_text() { :; }

  if apply_realm_config "$previous_state_file"; then
    fail "Realm readiness failure was reported as success"
  fi
  jq -e '.rules | length == 1 and .[0].id == "old"' "$REALM_STATE_FILE" >/dev/null ||
    fail "Realm state was not restored after readiness failure"
  [[ "$(cat "$REALM_CONFIG_FILE")" == "old-config" ]] ||
    fail "Realm config was not restored after readiness failure"
  [[ "$restart_calls" -eq 2 ]] ||
    fail "Realm old service was not restarted during rollback"
  [[ "$readiness_calls" -eq 2 ]] ||
    fail "Realm old service was not verified after rollback"
)

(
  transaction_root="$test_root/realm-success"
  mkdir -p "$transaction_root"
  REALM_STATE_FILE="$transaction_root/state.json"
  REALM_CONFIG_FILE="$transaction_root/config.toml"
  cat >"$REALM_STATE_FILE" <<'EOF'
{"global":{"log_level":"warn","log_output":"stdout","use_udp":false,"no_tcp":false},"rules":[{"id":"old","entries":[{"listen":"0.0.0.0:33001","remote":"192.0.2.1:33001"}]}],"meta":{}}
EOF
  printf 'old-config\n' >"$REALM_CONFIG_FILE"
  previous_state_file="$(snapshot_realm_state_file)"
  realm_state_jq '.rules += [{"id":"new","entries":[{"listen":"0.0.0.0:33002","remote":"192.0.2.2:33002"}]}]'

  restart_calls=0
  ensure_realm_dirs() { :; }
  init_realm_state_file() { :; }
  ensure_realm_service() { :; }
  prepare_managed_firewall() { :; }
  realm_service_exists() { return 0; }
  realm_service_active() { printf 'active\n'; }
  validate_realm_listener_ports_available() { :; }
  preflight_realm_config() { :; }
  realm_apply_firewall_rules() { :; }
  write_realm_config_file() { printf 'new-config\n' >"$REALM_CONFIG_FILE"; }
  enable_realm_service() { :; }
  restart_realm_service_raw() { restart_calls=$((restart_calls + 1)); }
  verify_realm_service_ready() { :; }
  ui_msg() { :; }

  apply_realm_config "$previous_state_file" || fail "Valid Realm transaction failed"
  jq -e '.rules | length == 2 and .[1].id == "new"' "$REALM_STATE_FILE" >/dev/null ||
    fail "Successful Realm transaction did not keep the new state"
  [[ "$(cat "$REALM_CONFIG_FILE")" == "new-config" ]] ||
    fail "Successful Realm transaction did not keep the new config"
  [[ "$restart_calls" -eq 1 ]] ||
    fail "Successful Realm transaction did not perform exactly one restart"
)

(
  # shellcheck disable=SC2329
  download_to_file() {
    local destination=$1
    printf '{"id":0,"owner":{"id":0},"full_name":"attacker/singbox","default_branch":"main"}\n' >"$destination"
  }
  if fetch_latest_project_from_repo >/dev/null 2>&1; then
    fail "仓库或所有者数字 ID 不匹配时仍允许自动更新"
  fi
)

(
  test_commit_sha="1111111111111111111111111111111111111111"
  test_content_sha="$(git_blob_sha1_file "$repo_dir/index.sh")"

  download_to_file() {
    local destination=$1 url=$2
    case "$url" in
      "https://api.github.com/repos/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}")
        jq -n \
          --argjson repo_id "$SCRIPT_REPO_ID" \
          --argjson owner_id "$SCRIPT_REPO_OWNER_ID" \
          --arg full_name "${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}" \
          --arg branch "$SCRIPT_REPO_BRANCH" \
          '{id:$repo_id,owner:{id:$owner_id},full_name:$full_name,default_branch:$branch}' >"$destination"
        ;;
      */branches/*)
        jq -n --arg sha "$test_commit_sha" '{commit:{sha:$sha}}' >"$destination"
        ;;
      */commits/*)
        jq -n --arg sha "$test_commit_sha" --argjson owner_id "$SCRIPT_REPO_OWNER_ID" \
          '{sha:$sha,author:{id:$owner_id},committer:null}' >"$destination"
        ;;
      */contents/index.sh*)
        jq -Rs \
          --arg sha "$test_content_sha" \
          --arg download_url "https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/${test_commit_sha}/index.sh" \
          '{type:"file",path:"index.sh",encoding:"base64",sha:$sha,download_url:$download_url,content:@base64}' \
          "$repo_dir/index.sh" >"$destination"
        ;;
      https://raw.githubusercontent.com/*)
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  }

  fallback_project="$(fetch_latest_project_from_repo)" || fail "Raw 不可用时未使用已认证的 GitHub API 内容继续更新"
  cmp -s "$repo_dir/index.sh" "$fallback_project/index.sh" || fail "Raw 回退得到的脚本与 GitHub API 内容不一致"
  rm -rf -- "$(dirname "$fallback_project")"
)

if [[ "${SBOX_TEST_REMOTE_UPDATE:-0}" == "1" ]]; then
  remote_project="$(fetch_latest_project_from_repo)" || fail "线上自动更新来源校验失败"
  bash -n "$remote_project/index.sh" || fail "线上自动更新脚本语法无效"
  rm -rf -- "$(dirname "$remote_project")"
fi

expected_hash="$(sed -n 's/^EXPECTED_INDEX_SHA256="\([A-Fa-f0-9]\{64\}\)"$/\1/p' "$repo_dir/install.sh")"
actual_hash="$(sha256sum "$repo_dir/index.sh" | awk '{print tolower($1)}')"
[[ -n "$expected_hash" && "${expected_hash,,}" == "$actual_hash" ]] || fail "install.sh 内置 index.sh 哈希不匹配"

printf '[security-test] all checks passed\n'
