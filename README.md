# Sing-box 一键安装与管理面板

![CI](https://github.com/renaissance0721/singbox/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/renaissance0721/singbox)

一个只面向 Linux VPS 的 `Sing-box` 一键安装与管理脚本。

## 功能特性

- 只支持 Linux VPS
- 输入一键安装命令后自动安装依赖与 `sing-box`
- 安装完成后自动进入终端管理面板
- 退出后可直接输入 `sbox` 重新打开面板
- 支持输入 `sbox uninstall` 一键卸载
- 安装时会询问节点名称，并生成可直接导入 v2rayN 的协议链接
- 支持 `Shadowsocks 2022`、`VLESS + Reality`、`Hysteria2`
- 支持客户端新增、删除、导出
- 自动生成 Reality 密钥、随机密码和 Hysteria2 自签名证书

## 适用环境

- Linux VPS
- `systemd`
- `root` 或具备 `sudo` 权限的用户
- 已开放协议对应的 TCP / UDP 端口

## 快速开始

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | sudo bash
```

如果需要手动指定节点域名或公网 IP：

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | sudo bash -s -- --server-address your.domain.com
```

安装脚本会：

- 安装管理命令到 `/usr/local/bin/sbox`
- 自动执行初始化安装
- 安装完成后自动打开管理面板

以后重新进入面板，只需要执行：

```bash
sbox
```

如需卸载：

```bash
sbox uninstall
```

## 使用流程

1. 执行一键安装命令。
2. 等待脚本自动安装依赖和 `sing-box`。
3. 安装完成后会自动进入管理面板。
4. 退出面板后，输入 `sbox` 可再次打开。

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
- 手动执行 `journalctl -u sing-box -n 50 --no-pager` 查看最近日志

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

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
