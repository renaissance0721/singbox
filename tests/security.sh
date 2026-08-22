#!/usr/bin/env bash

# Test doubles are invoked indirectly through functions sourced from index.sh.
# shellcheck disable=SC2317,SC2329

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

existing_sources='["198.51.100.10/32","2001:db8::10/128"]'
added_sources="$(build_allowed_sources_json '198.51.100.20/32, 2001:db8::10/128')"
merged_sources="$(merge_allowed_sources_json "$existing_sources" "$added_sources")"
jq -e '
  length == 3
  and index("198.51.100.10/32") != null
  and index("198.51.100.20/32") != null
  and index("2001:db8::10/128") != null
' <<<"$merged_sources" >/dev/null || fail "新增 Shadowsocks 白名单来源时覆盖了旧条目或未正确去重"
remaining_sources="$(remove_allowed_source_json "$merged_sources" '198.51.100.20/32')"
jq -e '
  length == 2
  and index("198.51.100.20/32") == null
  and index("198.51.100.10/32") != null
  and index("2001:db8::10/128") != null
' <<<"$remaining_sources" >/dev/null || fail "删除 Shadowsocks 白名单来源时影响了未选中的条目"
grep -Fq '管理 Shadowsocks 来源白名单（新增 / 删除）' "$repo_dir/index.sh" ||
  fail "节点管理未明确区分 Shadowsocks 白名单新增与删除"

(
  curl() {
    case "$1" in
      -4) printf '198.51.100.20\n' ;;
      -6) printf '2001:4860:4860::20\n' ;;
      *) return 1 ;;
    esac
  }
  hostname() { return 1; }

  [[ "$(detect_public_ipv4)" == "198.51.100.20" ]] || fail "公网 IPv4 未被独立探测"
  [[ "$(detect_public_ipv6)" == "2001:4860:4860::20" ]] || fail "公网 IPv6 未被独立探测"
  [[ "$(detect_public_address)" == "198.51.100.20" ]] || fail "兼容地址探测未优先返回 IPv4"
)

test_build_node_dual_stack() {
  local STATE_FILE="$test_root/build-node-state.json"
  install -m 0600 "$test_root/state/state.json" "$STATE_FILE"

  detect_public_ipv4() { printf '198.51.100.21\n'; }
  detect_public_ipv6() { printf '2001:4860:4860::21\n'; }
  ui_menu() { printf '1\n'; }
  ui_yesno() { fail "检测到双栈时不应再询问是否启用"; }
  prompt_nonempty() { printf '%s\n' "$3"; }
  configure_shadowsocks() { normalize_protocol_listen_addresses; }

  build_node || fail "自动搭建双栈节点失败"
  jq -e '
    .meta.server_address == "198.51.100.21"
    and .meta.server_address_ipv6 == "2001:4860:4860::21"
    and .meta.dual_stack == true
    and ([.protocols[] | .listen == "::"] | all)
  ' "$STATE_FILE" >/dev/null || fail "检测到双栈后未自动保存双栈地址或监听配置"

  install -m 0600 "$test_root/state/state.json" "$STATE_FILE"
  detect_public_ipv6() { return 1; }
  build_node || fail "仅检测到 IPv4 时新建节点失败"
  jq -e '
    .meta.server_address == "198.51.100.21"
    and .meta.server_address_ipv6 == ""
    and .meta.dual_stack == false
    and ([.protocols[] | .listen == "0.0.0.0"] | all)
  ' "$STATE_FILE" >/dev/null || fail "未检测到公网 IPv6 时未保持 IPv4 节点"
}
(test_build_node_dual_stack)

test_configure_outbound_ip_preference() {
  local STATE_FILE="$test_root/outbound-preference-state.json"
  install -m 0600 "$test_root/state/state.json" "$STATE_FILE"

  ui_menu() {
    [[ "$*" == *"IPv6 优先"* && "$*" == *"禁用 IPv4"* && "$*" == *"禁用 IPv6"* ]] ||
      fail "节点管理缺少 IPv4/IPv6 优先或禁用选项"
    printf '2\n'
  }
  apply_sing_box_state_transaction() { rm -f "$1"; return 0; }

  configure_outbound_ip_preference || fail "节点管理无法设置 IPv6 优先"
  [[ "$(state_get '.meta.outbound_ip_preference')" == "prefer_ipv6" ]] ||
    fail "节点管理未保存 IPv6 优先设置"
}
(test_configure_outbound_ip_preference)

rendered="$test_root/rendered.json"
render_config >"$rendered"
if [[ -n "${SBOX_TEST_RENDERED_CONFIG:-}" ]]; then
  cp "$rendered" "$SBOX_TEST_RENDERED_CONFIG"
fi
jq -e '
  .dns.servers == [{type:"local", tag:"local", prefer_go:true}]
  and ([.route.rules[] | select(.action == "reject" and ((.inbound // []) | index("vless-reality-in")) and .ip_is_private == true)] | length) == 2
  and ([.route.rules[] | select(.action == "reject" and ((.inbound // []) | index("vless-reality-in")) and ((.ip_cidr // []) | index("169.254.169.254/32")))] | length) == 2
  and ([.route.rules[] | select(.action == "resolve" and ((.inbound // []) | index("vless-reality-in")))] | length) == 1
  and ([.route.rules[] | select(.action == "resolve") | has("strategy")] == [false])
  and .route.final == "direct"
' "$rendered" >/dev/null || fail "VLESS 私网/元数据两阶段阻断规则缺失"

preference_rendered="$test_root/preference-rendered.json"
state_jq '.meta.outbound_ip_preference = "prefer_ipv6"'
render_config >"$preference_rendered"
jq -e '
  [.route.rules[] | select(.action == "resolve") | .strategy] == ["prefer_ipv6"]
' "$preference_rendered" >/dev/null || fail "IPv6 优先设置未写入域名解析规则"
state_jq '.meta.outbound_ip_preference = "prefer_ipv4"'
render_config >"$preference_rendered"
jq -e '
  [.route.rules[] | select(.action == "resolve") | .strategy] == ["prefer_ipv4"]
' "$preference_rendered" >/dev/null || fail "IPv4 优先设置未写入域名解析规则"
state_jq '.meta.outbound_ip_preference = "ipv6_only"'
render_config >"$preference_rendered"
jq -e '
  [.route.rules[] | select(.action == "resolve") | .strategy] == ["ipv6_only"]
' "$preference_rendered" >/dev/null || fail "禁用 IPv4 设置未写入域名解析规则"
state_jq '.meta.outbound_ip_preference = "ipv4_only"'
render_config >"$preference_rendered"
jq -e '
  [.route.rules[] | select(.action == "resolve") | .strategy] == ["ipv4_only"]
' "$preference_rendered" >/dev/null || fail "禁用 IPv6 设置未写入域名解析规则"
state_jq '.meta.outbound_ip_preference = "auto"'

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
      rule_sets: [
        "domain:google.com",
        "domain:mail.google.com",
        "geosite:openai",
        "srs:https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs"
      ]
    }
  ]
'
split_rendered="$test_root/split-rendered.json"
render_config >"$split_rendered"
if [[ -n "${SBOX_TEST_SPLIT_RENDERED_CONFIG:-}" ]]; then
  cp "$split_rendered" "$SBOX_TEST_SPLIT_RENDERED_CONFIG"
fi
jq -e '
  ([.route.rules[] | select(.action == "sniff") | .timeout] == ["300ms"])
  and ([.route.rules[] | select(.action == "route" and ((.outbound // "") | startswith("split-out:"))) | .rule_set[0]] == [
    "split:domain-route:1",
    "split:domain-route:0",
    "split:domain-route:2",
    "split:domain-route:3",
    "split:keyword-route:1",
    "split:keyword-route:0"
  ])
  and ([.route.rule_set[] | select(.tag == "split:domain-route:2")] == [{
    type: "remote",
    tag: "split:domain-route:2",
    format: "binary",
    url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs",
    update_interval: "1d"
  }])
  and ([.route.rule_set[] | select(.tag == "split:domain-route:3") | .url] == ["https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs"])
  and ([.outbounds[] | select(.tag == "split-out:keyword-route") | has("username")] == [false])
  and ([.outbounds[] | select(.tag == "split-out:keyword-route") | has("password")] == [false])
' "$split_rendered" >/dev/null || fail "分流优先级、GeoSite/SRS、sniff 超时或无认证 SOCKS5 渲染错误"
jq -e --arg cache_file "$RULE_SET_CACHE_FILE" '
  .experimental.cache_file == {enabled: true, path: $cache_file}
' "$split_rendered" >/dev/null || fail "远程规则集缓存没有启用或路径错误"

geosite_rules="$(build_split_geosite_json 'OpenAI, geolocation-!cn, bad/name')"
jq -e '
  length == 2
  and index("geosite:openai") != null
  and index("geosite:geolocation-!cn") != null
' <<<"$geosite_rules" >/dev/null || fail "GeoSite 分类解析或校验错误"
srs_rules="$(build_split_srs_json 'https://rules.example.com/a.srs, http://rules.example.com/b.srs, https://rules.example.com/not-json.json')"
jq -e 'length == 1 and .[0] == "srs:https://rules.example.com/a.srs"' <<<"$srs_rules" >/dev/null ||
  fail "远程 SRS URL 解析或 HTTPS 限制错误"
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

state_jq '
  .meta.dual_stack = true |
  .meta.server_address_ipv6 = "2001:4860:4860::22"
'
normalize_protocol_listen_addresses
[[ "$(default_listen_address)" == "::" ]] || fail "双栈节点未使用 IPv6 通配监听"
write_client_exports
grep -Fq '@203.0.113.10:24443' "$CLIENT_DIR/direct-links.txt" ||
  fail "双栈节点缺少主地址订阅链接"
if grep -Fq '2001:4860:4860::22' "$CLIENT_DIR/direct-links.txt" ||
  grep -Fq 'security-test-IPv6' "$CLIENT_DIR/direct-links.txt"; then
  fail "双栈节点仍生成了额外的 IPv6 订阅链接"
fi
state_jq '
  .meta.dual_stack = false |
  .meta.server_address_ipv6 = ""
'
normalize_protocol_listen_addresses
[[ "$(default_listen_address)" == "0.0.0.0" ]] || fail "关闭双栈后未恢复 IPv4 监听"
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
grep -Fq 'ReadWritePaths=${RULE_SET_CACHE_DIR}' "$repo_dir/index.sh" ||
  fail "systemd 沙箱没有放行远程规则集缓存目录"
grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$repo_dir/index.sh" ||
  fail "sing-box systemd service does not allow required AF_NETLINK route updates"
grep -Fq 'repair_sing_box_netlink_hardening' "$repo_dir/index.sh" ||
  fail "Existing sing-box installations do not auto-repair missing AF_NETLINK access"
grep -Fq 'Restart=always' "$repo_dir/index.sh" || fail "Realm systemd service does not restart after every unexpected exit"
grep -Fq "'cap_net_bind_service=+ep'" "$repo_dir/index.sh" || fail "OpenRC 低权限服务无法兼容低端口监听"
grep -Fq 'ensure_setcap_command' "$repo_dir/index.sh" || fail "OpenRC 节点流程不会自动修复缺失的 setcap"
grep -Eq 'apk add .*libcap-setcap' "$repo_dir/index.sh" || fail "APK 无法自动安装 setcap"
grep -Eq 'apk add .*iptables-openrc' "$repo_dir/index.sh" || fail "APK 依赖未安装 OpenRC 防火墙持久化组件"
grep -Fq 'ensure_managed_firewall_backend' "$repo_dir/index.sh" || fail "节点应用流程不会自动修复缺失的防火墙后端"
grep -Fq 'ensure_socket_inspection_command' "$repo_dir/index.sh" || fail "节点应用流程不会自动修复缺失的 ss 端口检查工具"
grep -Eq 'apt-get install .*libcap2-bin' "$repo_dir/index.sh" || fail "APT 无法自动安装 setcap"
grep -Eq 'dnf install .*libcap' "$repo_dir/index.sh" || fail "DNF 无法自动安装 setcap"
grep -Eq 'yum install .*libcap' "$repo_dir/index.sh" || fail "YUM 无法自动安装 setcap"
grep -Eq 'apt-get install .*util-linux' "$repo_dir/index.sh" || fail "APT 依赖未安装提供 runuser 的 util-linux"
grep -Eq 'dnf install .*util-linux' "$repo_dir/index.sh" || fail "DNF 依赖未安装提供 runuser 的 util-linux"
grep -Eq 'yum install .*util-linux' "$repo_dir/index.sh" || fail "YUM 依赖未安装提供 runuser 的 util-linux"
grep -Eq 'apk add .*su-exec' "$repo_dir/index.sh" || fail "APK 依赖未安装低权限执行工具 su-exec"
grep -Fq 'ensure_runtime_launcher' "$repo_dir/index.sh" || fail "节点配置检查不会自动修复缺失的低权限执行工具"
grep -Fq '/usr/sbin/runuser /sbin/runuser' "$repo_dir/index.sh" || fail "低权限执行工具检查仍完全依赖 PATH"
(
  runtime_launcher_log="$test_root/runtime-launcher.log"
  runtime_launcher_path() {
    [[ -s "$runtime_launcher_log" ]] || return 1
    printf '/usr/sbin/runuser\n'
  }
  detect_pkg_manager() { PKG_MANAGER=apt; }
  apt-get() { printf '%s\n' "$*" | tee -a "$runtime_launcher_log"; }

  runtime_launcher_output="$(ensure_runtime_launcher 2>/dev/null)"
  [[ -z "$runtime_launcher_output" ]] || fail "自动安装 runuser 的输出污染了 SS2022 密码生成结果"
  grep -Fxq 'update -y' "$runtime_launcher_log" || fail "节点流程缺少 runuser 时未更新 APT 索引"
  grep -Fxq 'install -y util-linux' "$runtime_launcher_log" || fail "节点流程缺少 runuser 时未自动安装 util-linux"
)
(
  setcap_install_log="$test_root/setcap-install.log"
  setcap_command_path() {
    [[ -s "$setcap_install_log" ]] || return 1
    printf '/usr/sbin/setcap\n'
  }
  detect_pkg_manager() { PKG_MANAGER=apk; }
  apk() { printf '%s\n' "$*" | tee -a "$setcap_install_log"; }

  setcap_install_output="$(ensure_setcap_command 2>/dev/null)"
  [[ -z "$setcap_install_output" ]] || fail "自动安装 setcap 时意外向调用方输出内容"
  grep -Fxq 'add --no-cache libcap-setcap' "$setcap_install_log" || fail "OpenRC 节点流程缺少 setcap 时未自动安装 libcap-setcap"
)
(
  firewall_install_log="$test_root/firewall-install.log"
  active_firewall_backend() {
    if [[ -s "$firewall_install_log" ]]; then
      printf 'iptables\n'
    else
      printf 'none\n'
    fi
  }
  detect_pkg_manager() { PKG_MANAGER=apk; }
  apk() { printf '%s\n' "$*" | tee -a "$firewall_install_log"; }

  firewall_install_output="$(ensure_managed_firewall_backend 2>/dev/null)"
  [[ -z "$firewall_install_output" ]] || fail "自动安装防火墙组件时意外向调用方输出内容"
  grep -Fxq 'add --no-cache iptables iptables-openrc' "$firewall_install_log" || fail "Alpine 节点流程缺少防火墙时未自动安装 iptables-openrc"
)
(
  socket_install_log="$test_root/socket-install.log"
  have_cmd() {
    [[ "$1" == "ss" && -s "$socket_install_log" ]]
  }
  detect_pkg_manager() { PKG_MANAGER=apk; }
  apk() { printf '%s\n' "$*" | tee -a "$socket_install_log"; }

  socket_install_output="$(ensure_socket_inspection_command 2>/dev/null)"
  [[ -z "$socket_install_output" ]] || fail "自动安装 ss 时意外向调用方输出内容"
  grep -Fxq 'add --no-cache iproute2-ss' "$socket_install_log" || fail "Alpine 节点流程缺少 ss 时未自动安装 iproute2-ss"
)
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
grep -Fq '"8" "一键常用脚本"' "$repo_dir/index.sh" || fail "主菜单缺少一键常用脚本入口"
grep -Fq 'run_common_script "NodeQuality" "https://run.NodeQuality.com"' "$repo_dir/index.sh" || fail "NodeQuality 入口缺失或地址错误"
grep -Fq 'run_common_script "TcpQuality" "https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh"' "$repo_dir/index.sh" || fail "TcpQuality 入口缺失或地址错误"
grep -Fq 'run_common_script "Tcpfit" "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh"' "$repo_dir/index.sh" || fail "Tcpfit 入口缺失或地址错误"
grep -Fq 'run_common_script "流媒体解锁" "http://check.unlock.media"' "$repo_dir/index.sh" || fail "流媒体解锁入口缺失或地址错误"
grep -Fq 'run_common_script "IP 质量体检" "https://IP.Check.Place"' "$repo_dir/index.sh" || fail "IP 质量体检入口缺失或地址错误"
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

common_script_output="$({
  have_cmd() { [[ "$1" == "curl" ]]; }
  download_to_file() {
    printf '#!/usr/bin/env bash\nprintf "common-script-ran\\n"\n' >"$1"
  }
  ui_pause() { :; }
  run_common_script "测试脚本" "https://example.invalid/test.sh"
} 2>&1)"
[[ "$common_script_output" == *common-script-ran* && "$common_script_output" == *"测试脚本 已运行完毕"* ]] ||
  fail "常用脚本未在下载和语法检查成功后运行"
if find "$TMP_DIR" -maxdepth 1 -name 'sbox-common-script.*' -print -quit | grep -q .; then
  fail "常用脚本运行后未清理临时文件"
fi

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

test_wireguard_dependency_install_case() (
  local wireguard_available=$1 ip_available=$2 expected_install=$3
  local dpkg_calls=0
  local -a apt_calls=()

  detect_pkg_manager() { PKG_MANAGER="apt"; }
  have_cmd() {
    case "$1" in
      wg|wg-quick) [[ "$wireguard_available" == "true" ]] ;;
      ip) [[ "$ip_available" == "true" ]] ;;
      dpkg) return 0 ;;
      modprobe) return 1 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  apt-get() {
    apt_calls+=("$*")
    if [[ "$1" == "install" ]]; then
      [[ " $* " == *" wireguard-tools "* ]] && wireguard_available=true
      [[ " $* " == *" iproute2 "* ]] && ip_available=true
    fi
    return 0
  }
  dpkg() {
    [[ "$*" == "--configure -a" ]] || return 1
    dpkg_calls=$((dpkg_calls + 1))
  }
  ip() { return 0; }

  install_wireguard_tools || return 1
  if [[ -z "$expected_install" ]]; then
    (( dpkg_calls == 0 && ${#apt_calls[@]} == 0 ))
  else
    (( dpkg_calls == 1 && ${#apt_calls[@]} == 2 )) &&
      [[ "${apt_calls[0]}" == "update -y" ]] &&
      [[ "${apt_calls[1]}" == "install -y $expected_install" ]]
  fi
)

test_wireguard_dependency_install_case false false "wireguard-tools iproute2" ||
  fail "WireGuard 未能自动补装全部缺失命令"
test_wireguard_dependency_install_case true false "iproute2" ||
  fail "WireGuard 未能单独补装缺失的 ip 命令"
test_wireguard_dependency_install_case false true "wireguard-tools" ||
  fail "WireGuard 未能单独补装缺失的 wg/wg-quick 命令"
test_wireguard_dependency_install_case true true "" ||
  fail "WireGuard 工具齐全时仍重复调用包管理器"

test_wireguard_package_manager_killed_after_install() (
  local wireguard_available=false
  detect_pkg_manager() { PKG_MANAGER="apt"; }
  have_cmd() {
    case "$1" in
      wg|wg-quick) [[ "$wireguard_available" == "true" ]] ;;
      ip|dpkg) return 0 ;;
      modprobe) return 1 ;;
      *) return 1 ;;
    esac
  }
  dpkg() { return 0; }
  apt-get() {
    if [[ "$1" == "install" ]]; then
      wireguard_available=true
      return 137
    fi
    return 0
  }
  ip() { return 0; }

  install_wireguard_tools >/dev/null
)
test_wireguard_package_manager_killed_after_install ||
  fail "WireGuard 已安装后包管理器被终止仍被误判为安装失败"

test_dpkg_lock_wait_and_retry() (
  local counter_file="$test_root/dpkg-lock-retry-counter"
  local output
  printf '0\n' >"$counter_file"
  have_cmd() { [[ "$1" == "dpkg" ]]; }
  dpkg() {
    local calls
    calls="$(cat "$counter_file")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$counter_file"
    if (( calls < 3 )); then
      printf 'dpkg: error: dpkg frontend lock was locked by another process with pid 8866\n' >&2
      return 2
    fi
    printf 'dpkg configured\n'
  }
  sleep() { :; }

  output="$(SBOX_DPKG_LOCK_TIMEOUT=10 SBOX_DPKG_LOCK_RETRY_INTERVAL=0 repair_dpkg_state 2>&1)" || return 1
  [[ "$(cat "$counter_file")" -eq 3 ]] &&
    [[ "$output" == *"PID 8866"* ]] &&
    [[ "$output" == *"dpkg configured"* ]]
)
test_dpkg_lock_wait_and_retry ||
  fail "dpkg 软件包锁释放后未自动重试修复"

test_dpkg_lock_wait_timeout() (
  local output
  have_cmd() { [[ "$1" == "dpkg" ]]; }
  dpkg() {
    printf 'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 8866\n' >&2
    return 100
  }
  sleep() { SECONDS=$((SECONDS + 1)); }

  if output="$(SBOX_DPKG_LOCK_TIMEOUT=1 SBOX_DPKG_LOCK_RETRY_INTERVAL=0 repair_dpkg_state 2>&1)"; then
    return 1
  fi
  [[ "$output" == *"已超时"* ]] && [[ "$output" == *"没有删除锁文件"* ]]
)
test_dpkg_lock_wait_timeout ||
  fail "dpkg 软件包锁等待超时未安全退出"

test_wireguard_dpkg_repair_failure() (
  local wireguard_apt_call_count=0
  # PKG_MANAGER is consumed indirectly by install_wireguard_tools.
  # shellcheck disable=SC2034
  detect_pkg_manager() { PKG_MANAGER="apt"; }
  have_cmd() {
    case "$1" in
      wg|wg-quick) return 1 ;;
      ip|dpkg) return 0 ;;
      *) return 1 ;;
    esac
  }
  dpkg() { return 1; }
  apt-get() { wireguard_apt_call_count=$((wireguard_apt_call_count + 1)); }

  if install_wireguard_tools >/dev/null 2>&1; then
    return 1
  fi
  (( wireguard_apt_call_count == 0 ))
)
test_wireguard_dpkg_repair_failure ||
  fail "dpkg 状态恢复失败后仍继续调用 APT"

wireguard_valid_address_pair "10.253.42.1" "10.253.42.2" ||
  fail "WireGuard 拒绝有效的托管私网地址对"
if wireguard_valid_address_pair "10.253.42.1" "10.253.43.2" ||
  wireguard_valid_address_pair "10.253.0.1" "10.253.0.2" ||
  wireguard_valid_address_pair "192.0.2.1" "192.0.2.2"; then
  fail "WireGuard 接受了托管地址池以外或子网不匹配的地址对"
fi
(
  ip() {
    printf '2: eth0    inet 10.253.42.1/32 scope global eth0\n'
    printf '3: sbwg0    inet 10.253.43.2/32 scope global sbwg0\n'
  }
  wireguard_address_pair_in_use "10.253.42.1" "10.253.42.2" ||
    fail "WireGuard 未检测到其他接口上的私网地址冲突"
  if wireguard_address_pair_in_use "10.253.43.1" "10.253.43.2" "sbwg0"; then
    fail "WireGuard 地址冲突检测未忽略当前托管接口"
  fi
)
grep -Fq '(.wireguard.profiles[] | select(.id == $id)).peer_address = $relay_address' "$repo_dir/index.sh" ||
  fail "落地端未同步中转端重新协商的 WireGuard 地址"

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

if grep -q 'EXPECTED_INDEX_SHA256\|index.sh 完整性校验失败' "$repo_dir/install.sh"; then
  fail "install.sh 仍使用需要手动同步的固定 index.sh 哈希"
fi
grep -Fq '[[ -s "$DOWNLOAD_TMP" ]]' "$repo_dir/install.sh" || fail "install.sh 未拒绝空的 index.sh"
grep -Fq 'bash -n "$DOWNLOAD_TMP"' "$repo_dir/install.sh" || fail "install.sh 未检查 index.sh Bash 语法"

(
  STATE_FILE="$test_root/xray-render-state.json"
  jq --arg private_key "$reality_private_key" '
    .protocols.shadowsocks.enabled = false |
    .protocols.hysteria2.enabled = false |
    .protocols.vless_reality.enabled = true |
    .protocols.vless_reality.core = "xray" |
    .protocols.vless_reality.port = 24443 |
    .protocols.vless_reality.server_name = "www.example.com" |
    .protocols.vless_reality.handshake_server = "www.example.com" |
    .protocols.vless_reality.handshake_port = 443 |
    .protocols.vless_reality.private_key = $private_key |
    .protocols.vless_reality.public_key = "test-public-key" |
    .protocols.vless_reality.short_id = "0123456789abcdef" |
    .protocols.vless_reality.users = [{name:"vless-client-1", uuid:"00000000-0000-4000-8000-000000000001"}] |
    .meta.outbound_ip_preference = "prefer_ipv4" |
    .routing.split.outbounds = []
  ' "$test_root/state/state.json" >"$STATE_FILE"

  sing_rendered="$test_root/xray-sing-box-rendered.json"
  xray_rendered="$test_root/xray-rendered.json"
  render_config >"$sing_rendered"
  render_xray_config >"$xray_rendered"
  if [[ -n "${SBOX_TEST_XRAY_RENDERED_CONFIG:-}" ]]; then
    cp "$xray_rendered" "$SBOX_TEST_XRAY_RENDERED_CONFIG"
  fi

  jq -e '
    [.inbounds[]? | select(.tag == "vless-reality-in")] | length == 0
  ' "$sing_rendered" >/dev/null || fail "Xray 模式仍把 VLESS 写入 sing-box，可能导致双内核抢占端口"
  jq -e '
    .inbounds[0].protocol == "vless"
    and .inbounds[0].settings.decryption == "none"
    and .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"
    and .inbounds[0].streamSettings.network == "raw"
    and .inbounds[0].streamSettings.security == "reality"
    and .inbounds[0].streamSettings.realitySettings.target == "www.example.com:443"
    and .inbounds[0].streamSettings.realitySettings.shortIds == ["0123456789abcdef"]
    and .outbounds[0].settings.domainStrategy == "UseIPv4v6"
    and ([.routing.rules[] | select(.outboundTag == "block") | .ip[]] | index("10.0.0.0/8")) != null
    and ([.routing.rules[] | select(.outboundTag == "block") | .ip[]] | index("fc00::/7")) != null
    and ([.routing.rules[] | select(.outboundTag == "block") | .ip[]] | index("100.100.100.200/32")) != null
  ' "$xray_rendered" >/dev/null || fail "Xray VLESS + Reality 配置缺少必要字段、出站策略或私网/元数据阻断"
  [[ "$(sing_box_protocol_count)" == "0" ]] || fail "Xray-only VLESS 被错误计入 sing-box 协议数"
  xray_protocol_enabled || fail "Xray VLESS 状态未被识别"
  [[ "$(desired_xray_listeners)" == $'tcp\t24443\tVLESS + Reality (Xray)' ]] || fail "Xray 监听端口未进入统一端口管理"
)

(
  STATE_FILE="$test_root/xray-migration-state.json"
  jq 'del(.protocols.vless_reality.core, .runtime)' "$test_root/state/state.json" >"$STATE_FILE"
  migrate_state_schema
  jq -e '
    .protocols.vless_reality.core == "sing-box"
    and .runtime.xray.managed == false
    and .runtime.xray.version == ""
    and .runtime.xray.binary_sha256 == ""
  ' "$STATE_FILE" >/dev/null || fail "旧状态未安全迁移到 sing-box 默认内核或缺少 Xray 安装记录"
)

(
  XRAY_BIN="$test_root/fake-xray"
  printf '#!/usr/bin/env sh\nexit 0\n' >"$XRAY_BIN"
  chmod 0755 "$XRAY_BIN"
  run_as_runtime() {
    printf 'PrivateKey: test-private\nPassword: test-public\nHash32: ignored\n'
  }
  [[ "$(generate_reality_keypair xray)" == $'test-private\ttest-public' ]] ||
    fail "Xray 新版 x25519 Password 公钥输出未被兼容解析"
  run_as_runtime() {
    printf 'PrivateKey: legacy-private\nPublicKey: legacy-public\n'
  }
  [[ "$(generate_reality_keypair xray)" == $'legacy-private\tlegacy-public' ]] ||
    fail "Xray 旧版 x25519 PublicKey 输出未被兼容解析"
)

grep -Fq 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' "$repo_dir/index.sh" ||
  fail "Xray 安装未限定官方 latest stable API"
grep -Fq 'select(.draft == false and .prerelease == false)' "$repo_dir/index.sh" ||
  fail "Xray 安装未拒绝 draft/prerelease"
grep -Fq 'Xray 发布包 SHA-256 校验失败' "$repo_dir/index.sh" ||
  fail "Xray 安装缺少失败关闭的 SHA-256 校验"
grep -Fq 'run -test -config "$tmp_xray_config"' "$repo_dir/index.sh" ||
  fail "替换 Xray 配置前未调用内核预检"
grep -Fq 'XRAY_BIN="${XRAY_BIN:-$XRAY_INSTALL_DIR/xray}"' "$repo_dir/index.sh" ||
  fail "Xray 未使用隔离的脚本托管路径"
if grep -Eq 'curl[^\n|]*\|[[:space:]]*(ba)?sh' "$repo_dir/index.sh"; then
  fail "Xray 或其他安装流程仍会把远程内容直接传给 shell"
fi

(
  XRAY_BIN="$test_root/service-xray"
  XRAY_CONFIG_FILE="$test_root/service-xray-config.json"
  XRAY_ASSET_DIR="$test_root/service-xray-assets"
  XRAY_OPENRC_SERVICE_FILE="$test_root/sbox-xray.init"
  # Consumed indirectly while ensure_xray_service renders the init script.
  # shellcheck disable=SC2034
  XRAY_OPENRC_LOG_FILE="$test_root/sbox-xray.log"
  printf '#!/usr/bin/env sh\nexit 0\n' >"$XRAY_BIN"
  chmod 0755 "$XRAY_BIN"
  sing_box_service_manager() { printf 'openrc\n'; }
  ensure_runtime_account() { :; }
  ensure_dirs() { mkdir -p "$XRAY_ASSET_DIR"; }
  ensure_openrc_low_port_capability() { :; }
  ensure_xray_service || fail "无法生成 Xray OpenRC 服务"
  bash -n "$XRAY_OPENRC_SERVICE_FILE" || fail "Xray OpenRC 服务脚本语法无效"
  grep -Fq 'command_user="sbox-runtime:sbox-runtime"' "$XRAY_OPENRC_SERVICE_FILE" ||
    fail "Xray OpenRC 服务未使用低权限账户"
  grep -Fq 'export XRAY_LOCATION_ASSET=' "$XRAY_OPENRC_SERVICE_FILE" ||
    fail "Xray OpenRC 服务未固定资源目录"
)

(
  XRAY_BIN="$test_root/service-xray"
  # Consumed indirectly while ensure_xray_service renders the unit.
  # shellcheck disable=SC2034
  XRAY_CONFIG_FILE="$test_root/service-xray-config.json"
  XRAY_ASSET_DIR="$test_root/service-xray-assets"
  XRAY_SYSTEMD_SERVICE_FILE="$test_root/sbox-xray.service"
  sing_box_service_manager() { printf 'systemd\n'; }
  ensure_runtime_account() { :; }
  ensure_dirs() { :; }
  systemctl() { :; }
  ensure_xray_service || fail "无法生成 Xray systemd 服务"
  grep -Fq 'User=sbox-runtime' "$XRAY_SYSTEMD_SERVICE_FILE" || fail "Xray systemd 服务未使用低权限账户"
  grep -Fq 'NoNewPrivileges=true' "$XRAY_SYSTEMD_SERVICE_FILE" || fail "Xray systemd 服务缺少 NoNewPrivileges"
  grep -Fq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$XRAY_SYSTEMD_SERVICE_FILE" ||
    fail "Xray systemd 服务权限范围过宽或缺少低端口能力"
  grep -Fq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "$XRAY_SYSTEMD_SERVICE_FILE" ||
    fail "Xray systemd 服务未限制地址族"
)

printf '[security-test] all checks passed\n'
