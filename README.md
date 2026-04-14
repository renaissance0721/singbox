# Sing-box 一键安装与管理面板

![CI](https://github.com/renaissance0721/singbox/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/renaissance0721/singbox)

一个面向 Linux VPS 的 `Sing-box` 管理脚本，提供终端交互式面板和常用命令入口，帮助你快速完成安装、三协议初始化、多用户管理、客户端信息导出和服务维护。

## 功能特性

- 一键安装 `sing-box` 与常用依赖
- 基于 `whiptail` 的终端可视化面板，无图形环境也能使用
- 支持 `Shadowsocks 2022`、`VLESS + Reality`、`Hysteria2`
- 支持新增、删除、导出多用户客户端信息
- 自动生成 Reality 密钥、UUID、随机密码和 Hysteria2 自签名证书
- 自动备份旧配置并在变更后重载 `sing-box`
- 可查看当前概览、服务状态和最近日志
- 自动适配 `apt`、`dnf`、`yum`

## 适用环境

- Linux VPS
- `systemd`
- `root` 或具备 `sudo` 权限的用户
- 已开放协议对应的 TCP / UDP 端口

## 快速开始

### 方式一：克隆仓库

```bash
git clone https://github.com/renaissance0721/singbox.git
cd singbox
sudo bash index.sh
```

### 方式二：直接下载脚本

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/index.sh -o index.sh
chmod +x index.sh
sudo ./index.sh
```

### 常用命令

```bash
# 启动交互式管理面板
sudo bash index.sh

# 使用默认参数完成三协议初始化
sudo bash index.sh quick-install

# 新增或删除客户端
sudo bash index.sh add-client
sudo bash index.sh remove-client

# 导出客户端信息 / 查看概览 / 查看服务状态
sudo bash index.sh show
sudo bash index.sh overview
sudo bash index.sh status

# 重新生成配置并重载服务
sudo bash index.sh apply
```

## 使用流程

1. 首次运行时执行 `quick-install`，或直接进入面板选择“一键安装 / 初始化三协议”。
2. 设置节点对外地址，建议填写最终给客户端使用的域名或公网 IP。
3. 按需启用并调整 `Shadowsocks 2022`、`VLESS + Reality`、`Hysteria2`。
4. 通过“新增客户端”或 `add-client` 创建用户。
5. 通过“查看客户端信息”或 `show` 导出连接参数。

## 生成文件位置

- 主配置文件：`/etc/sing-box/config.json`
- 面板状态文件：`/etc/sing-box-manager/state.json`
- 配置备份目录：`/etc/sing-box-manager/backups/`
- 客户端导出目录：`/etc/sing-box-manager/clients/`
- Hysteria2 证书目录：`/etc/sing-box-manager/certs/`

## 协议说明

### Shadowsocks 2022

- 默认使用 `2022-blake3-aes-256-gcm`
- 服务端主密码和用户密码会分开生成

### VLESS + Reality

- 默认流控为 `xtls-rprx-vision`
- 会自动生成 Reality 密钥对和 `short_id`
- 首次配置建议确认伪装域名和端口是否可访问

### Hysteria2

- 默认使用自签名证书
- 如需改为正式证书，可将证书放到 `/etc/sing-box-manager/certs/` 并修改状态文件中的路径
- 若继续使用自签名证书，客户端侧通常需要允许 `insecure`

## 故障排查

### `sing-box` 启动失败

```bash
journalctl -u sing-box -n 50 --no-pager
```

### 配置重载失败

- 确认协议至少保留 1 个客户端
- 确认证书、私钥和伪装域名配置有效
- 手动执行 `sudo bash index.sh status` 查看最近日志

### 依赖安装失败

按发行版手动安装：

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install curl jq openssl ca-certificates whiptail uuid-runtime iproute2

# RHEL / CentOS
sudo yum install curl jq openssl ca-certificates newt util-linux iproute
```

## 安全提醒

- 请在你拥有管理权限的服务器上使用本脚本
- 对外分享客户端配置前，请确认端口、域名、证书和密码都已按预期生成
- 公开仓库时不要提交任何真实节点配置、证书或导出的客户端信息
- 安全问题请优先查看 [SECURITY.md](SECURITY.md)

## 贡献

欢迎提交 Issue 和 Pull Request。开始之前建议先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
