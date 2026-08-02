# Sing-box 一键安装与管理面板

![CI](https://github.com/renaissance0721/singbox/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/renaissance0721/singbox)

一个只面向 Linux VPS 的 `Sing-box` 一键安装与管理脚本。

## 功能特性

- 只支持 Linux VPS
- 输入安装命令后先进入终端管理面板
- 在面板选择“安装 / 初始化 sing-box”后安装依赖与官方原生 `sing-box`
- 退出后可直接输入 `sbox` 重新打开面板
- 支持输入 `sbox uninstall` 一键卸载
- 支持重新安装 / 修复时从 GitHub 拉取最新项目并保留现有规则
- 新建节点时询问节点名称和出口地址，并支持在节点管理中随时更改地址
- 支持 `Shadowsocks`、`VLESS + Reality`、`Hysteria2`
- 支持客户端新增、删除、导出
- 自动生成 Reality 密钥、随机密码和 Hysteria2 自签名证书
- 新建 Shadowsocks 主节点与分流仅提供 SS2022；主节点支持来源 IP/CIDR 白名单
- 经 Shadowsocks 入站转发的流量会拒绝访问私网、链路本地地址和常见云元数据地址
- Realm 仅启用 TCP 转发；升级时会迁移旧配置并清理脚本管理的 Realm UDP 放行规则
- 支持查看监听端口和占用进程，并管理本脚本托管的防火墙端口
- 支持 UFW、firewalld、iptables/ip6tables，并为托管规则提供 systemd/OpenRC 重启恢复
- 支持零预置的自定义分流规则集，可随时新增、查看和删除
- 支持添加多个 SOCKS5 / Shadowsocks 分流落地

## 适用环境

- Linux VPS
- Debian / Ubuntu、RHEL 系列或 Alpine Linux
- `systemd` 或 OpenRC
- `root` 或具备 `sudo` 权限的用户
- 云厂商安全组或 NAT 映射已允许协议对应端口；脚本只能管理 VPS 本机防火墙

## 快速开始

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | sudo bash
```

Alpine Linux 请先安装 Bash 和 curl，并使用 root 执行：

```sh
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | bash
```

安装脚本会：

- 安装管理命令到 `/usr/local/bin/sbox`
- 自动打开管理面板
- 由用户选择“安装 / 初始化 sing-box”后执行初始化安装

以后重新进入面板，只需要执行：

```bash
sbox
```

如需直接更改所有协议共用的节点出口 IP 或域名，也可以执行：

```bash
sbox change-address
```

修改后会自动重新生成客户端配置和订阅链接，并按需重载 sing-box 服务。

常用管理命令：

```bash
sbox node             # 节点管理
sbox realm            # Realm TCP 中转管理
sbox ports            # 端口与本机防火墙管理
sbox repair-install   # 更新/修复并保留现有配置
sbox status           # 查看 sing-box 服务状态
```

## 分流管理

进入面板后选择“分流管理”，可以新增多个落地。每个落地拥有独立名称、代理信息和规则集，例如：

```text
us-ai  -> chatgpt, openai
jp-ai  -> claude
```

同一个规则集只会绑定一个落地；将它添加到另一个落地时，脚本会自动从原落地解绑。

可重复执行以下命令新增落地：

```bash
sbox split-route
```

也可以通过面板或命令编辑、停用和删除落地：

```bash
sbox edit-split-route
sbox delete-split-route
```

每个落地可选择：

- SOCKS5：填写 IP 或域名、端口、用户名和密码
- Shadowsocks：填写 IP 或域名、端口、加密方式和密码

新建或编辑 Shadowsocks 分流落地时仅提供：

```text
2022-blake3-aes-128-gcm
2022-blake3-aes-256-gcm
2022-blake3-chacha20-poly1305
```

升级前已经保存的传统 AEAD、`none` 或 `plain` 配置会继续保留兼容，但菜单不再允许新建这些配置。

脚本不预置任何规则集。新增落地或为已有落地追加规则时，可以选择关键词规则，例如：

```text
chatgpt
claude
```

每个名称会创建一个独立的内联规则集，并按域名关键词匹配。也可以一次输入多个名称：

```bash
sbox add-split-rule chatgpt claude
```

执行后会提示选择这些规则要绑定到哪个落地。

也可以在“为落地新增分流规则”中选择“自定义网址 / 域名”，直接输入：

```text
nodeseek.com
https://www.nodeseek.com/space
```

网址可以不带 `http://` 或 `https://`。脚本会自动去除协议、`www.`、端口和路径，并让该域名及其子域名通过指定落地。

查看全部落地和分流规则：

```bash
sbox split-rules
```

删除关键词或网址分流规则：

```bash
sbox delete-split-rule
```

如需卸载：

```bash
sbox uninstall
```

## 使用流程

1. 执行安装命令，脚本会先打开管理面板。
2. 选择“安装 / 初始化 sing-box”。
3. 等待脚本安装依赖和 `sing-box`。
4. 退出面板后，输入 `sbox` 可再次打开。

## 生成文件位置

- 主配置文件：`/etc/sing-box/config.json`
- 面板状态文件：`/etc/sing-box-manager/state.json`
- 配置备份目录：`/etc/sing-box-manager/backups/`
- 客户端导出目录：`/etc/sing-box-manager/clients/`
- Hysteria2 证书目录：`/etc/sing-box-manager/certs/`
- Realm 配置目录：`/etc/realm/`
- 脚本托管防火墙状态：`/etc/sing-box-manager/firewall-managed.tsv`

## 协议说明

### Shadowsocks

- 默认使用 `2022-blake3-aes-128-gcm`
- 默认端口在 `10000-60000` 范围内随机生成
- 新建节点可选择三种 SS2022 加密方式，并分别生成服务端主密码和用户密码
- 创建节点时必须填写来源 IP/CIDR 白名单；中转场景应填写中转 VPS 的出口 IP
- 公网直连需要明确填写 `0.0.0.0/0` 和/或 `::/0`，这等同于相应地址族全网可访问
- 旧状态文件没有来源白名单时保持全网放行，升级后应在“节点管理”中手动设置
- SS 入站会在域名解析前后拒绝私网、链路本地地址和常见云元数据地址

### VLESS + Reality

- 默认端口在 `10000-60000` 范围内随机生成，并避开 Shadowsocks 默认端口
- 默认流控为 `xtls-rprx-vision`
- 会自动生成 Reality 密钥对和 `short_id`
- 首次配置建议确认伪装域名和端口是否可访问

### Hysteria2

- 默认使用自签名证书
- 如需改为正式证书，可将证书放到 `/etc/sing-box-manager/certs/` 并修改状态文件中的路径
- 若继续使用自签名证书，客户端侧通常需要允许 `insecure`

### Realm 中转

- Realm 仅创建 TCP 转发，不启用 UDP
- 每条规则由本机监听端口和远端地址/端口组成
- 更新旧安装时，脚本会把 Realm 配置迁移为 TCP-only，并清理本机由脚本管理的 UDP 放行规则
- 云厂商安全组、控制面板防火墙和 NAT 映射不受脚本管理，原有 UDP 映射需要自行删除

## 端口与防火墙管理

执行 `sbox ports` 可以：

- 查看全部 TCP/UDP 监听端口及占用进程
- 查看 Shadowsocks、VLESS、Hysteria2 和 Realm 的脚本托管端口状态
- 关闭当前未监听端口对应的脚本托管放行规则
- 开启当前正在监听端口对应的脚本托管放行规则

注意事项：

- 自动开关按脚本状态文件处理托管端口，不会主动选择其他系统端口；但相同端口/协议的同形人工防火墙规则也可能受到同步影响
- 不要把节点或 Realm 监听端口设置成 SSH、Web 服务或其他程序已经占用的端口
- UFW 或 firewalld 已启用时优先使用对应后端，否则使用 iptables/ip6tables
- systemd 使用 `sbox-firewall.service` 在 sing-box/Realm 启动前恢复规则；Alpine/OpenRC 在对应 iptables/ip6tables 服务存在时保存规则
- NAT VPS 的客户端使用商家分配的公网端口；sing-box 监听的是 NAT 映射后的内部端口，两者可能不同
- 本页面不检测也不修改云厂商安全组、外部防火墙或 NAT 控制面板

## 故障排查

### `sing-box` 启动失败

```bash
journalctl -u sing-box -n 50 --no-pager
```

### 配置重载失败

- 确认协议至少保留 1 个客户端
- 确认证书、私钥和伪装域名配置有效
- systemd：执行 `journalctl -u sing-box -n 50 --no-pager` 查看最近日志
- Alpine/OpenRC：sing-box 执行 `tail -n 50 /var/log/sing-box.log`，Realm 执行 `tail -n 50 /var/log/realm.log`

### 防火墙同步失败

```bash
sbox ports
sbox repair-install
```

- 确认系统至少存在一个可用后端：已启用的 UFW、已运行的 firewalld，或 iptables/ip6tables
- systemd 可执行 `journalctl -u sbox-firewall -n 50 --no-pager` 查看恢复日志
- Alpine/OpenRC 请确认 `/etc/init.d/iptables`（以及需要 IPv6 时的 `ip6tables`）存在并已加入默认运行级别

### 依赖安装失败

按发行版手动安装：

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install curl jq openssl ca-certificates git tar gzip iproute2 iptables

# RHEL / CentOS
sudo yum install curl jq openssl ca-certificates git tar gzip iproute iptables

# Alpine Linux
apk add --no-cache bash curl jq openssl ca-certificates git tar gzip openrc coreutils findutils iproute2 iptables iptables-openrc
```

## 安全提醒

- 请在你拥有管理权限的服务器上使用本脚本
- 对外分享客户端配置前，请确认端口、域名、证书和密码都已按预期生成
- 来源白名单只限制 Shadowsocks 入站来源；VLESS 和 Hysteria2 仍依赖各自的认证信息
- 私网和元数据访问阻断目前仅应用于 Shadowsocks 入站
- 本机防火墙放行不能代替云厂商安全组配置，也不能创建或删除 NAT 端口映射
- 公开仓库时不要提交任何真实节点配置、证书或导出的客户端信息
- 安全问题请优先查看 [SECURITY.md](SECURITY.md)

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
