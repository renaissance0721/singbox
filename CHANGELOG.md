# 更新日志

本文件记录项目对外发布后的主要变更。

## [0.3.0] - 2026-06-07

### 新增

- 新增通用分流管理，默认不预置任何规则集
- 支持仅输入 `chatgpt`、`claude` 等名称创建域名关键词规则集
- 支持随时新增、查看和删除分流规则集
- 支持 SOCKS5 和 Shadowsocks 分流落地
- Shadowsocks 分流落地支持传统 AEAD、`none` / `plain` 和 AEAD 2022 加密方式

### 变更

- 旧 AI 分流命令保留为兼容别名
- 删除所有历史内置默认规则集，迁移时仅保留非默认的自定义规则

## [0.1.0] - 2026-04-14

### 新增

- 初始公开版本发布
- 面向 Linux VPS 的 `install.sh` 一键安装入口
- 安装完成后自动打开管理面板，并注册全局命令 `sbox`
- 新增 `sbox uninstall` 卸载入口
- 一键安装 `sing-box` 与常用依赖
- 基于 `whiptail` 的终端交互式管理面板
- `Shadowsocks 2022`、`VLESS + Reality`、`Hysteria2` 三协议初始化
- 多用户新增、删除与客户端信息导出
- `show`、`overview`、`status`、`--help`、`--version` 命令入口
- 旧配置自动备份与服务重载
- GitHub 开源配套文档、Issue 模板与 CI 检查

### 说明

- `Hysteria2` 默认使用自签名证书
- 非交互初始化支持通过 `SINGBOX_SERVER_ADDRESS` 指定节点地址
- 脚本目前面向 `systemd` 环境
- 运行脚本需要 `root` 或 `sudo` 权限
