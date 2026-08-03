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
grep -Fq 'Restart=always' "$repo_dir/index.sh" || fail "Realm systemd service does not restart after every unexpected exit"
grep -Fq "setcap 'cap_net_bind_service=+ep'" "$repo_dir/index.sh" || fail "OpenRC 低权限服务无法兼容低端口监听"
grep -Fq 'SCRIPT_REPO_ID="1210354428"' "$repo_dir/index.sh" || fail "自动更新未固定 GitHub 仓库数字 ID"
grep -Fq 'SCRIPT_REPO_OWNER_ID="197479185"' "$repo_dir/index.sh" || fail "自动更新未固定 GitHub 所有者数字 ID"
grep -Fq 'git_blob_sha1_file "$project_dir/index.sh"' "$repo_dir/index.sh" || fail "自动更新未校验不可变 commit 的 Git blob 哈希"
grep -Fq '"$actual_sha256" != "$api_sha256"' "$repo_dir/index.sh" || fail "自动更新未交叉校验 API 与原始文件的 SHA-256"
grep -Fq 'mktemp "$(dirname "$target_path")/.sbox-update.XXXXXX"' "$repo_dir/index.sh" || fail "自动更新未使用同目录临时文件原子替换"
if grep -q 'SBOX_UPDATE_INDEX_SHA256\|请输入可信发布说明中 index.sh' "$repo_dir/index.sh"; then
  fail "自动更新仍要求手动输入 SHA-256"
fi
grep -Fq 'if [[ -v BASH_SOURCE ]]; then' "$repo_dir/install.sh" ||
  fail "install.sh 通过标准输入执行时仍可能因 BASH_SOURCE[0] 未定义而退出"

blob_fixture="$test_root/git-blob-fixture.txt"
printf 'hello\n' >"$blob_fixture"
[[ "$(git_blob_sha1_file "$blob_fixture")" == "ce013625030ba8dba906f756967f9e9ca394464a" ]] ||
  fail "Git blob 哈希计算不正确"

ss2022_method="2022-blake3-aes-128-gcm"
ss2022_password="AQIDBAUGBwgJCgsMDQ4PEA==:ERITFBUWFxgZGhscHR4fIA=="
ss2022_userinfo="$(uri_encode "$ss2022_method"):$(uri_encode "$ss2022_password")"
[[ "$ss2022_userinfo" == '2022-blake3-aes-128-gcm:AQIDBAUGBwgJCgsMDQ4PEA%3D%3D%3AERITFBUWFxgZGhscHR4fIA%3D%3D' ]] ||
  fail "SS2022 SIP002 userinfo 未使用百分号编码"
if grep -Fq 'base64_urlsafe "${ss_method}:${ss_share_password}"' "$repo_dir/index.sh"; then
  fail "SS2022 分享链接仍使用 SIP002 禁止的 Base64URL userinfo"
fi
grep -Fq 'link="ss://$(uri_encode "$ss_method"):$(uri_encode "$ss_share_password")@${host}:${ss_port}#$(uri_encode "$display_name")"' "$repo_dir/index.sh" ||
  fail "SS2022 分享链接未使用 SIP002 百分号编码 userinfo"

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

if [[ "${SBOX_TEST_REMOTE_UPDATE:-0}" == "1" ]]; then
  remote_project="$(fetch_latest_project_from_repo)" || fail "线上自动更新来源校验失败"
  bash -n "$remote_project/index.sh" || fail "线上自动更新脚本语法无效"
  rm -rf -- "$(dirname "$remote_project")"
fi

expected_hash="$(sed -n 's/^EXPECTED_INDEX_SHA256="\([A-Fa-f0-9]\{64\}\)"$/\1/p' "$repo_dir/install.sh")"
actual_hash="$(sha256sum "$repo_dir/index.sh" | awk '{print tolower($1)}')"
[[ -n "$expected_hash" && "${expected_hash,,}" == "$actual_hash" ]] || fail "install.sh 内置 index.sh 哈希不匹配"

printf '[security-test] all checks passed\n'
