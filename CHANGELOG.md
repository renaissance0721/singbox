# 更新日志

本文件记录项目对外发布后的主要变更。

## [0.1.0] - 2026-04-14

### 新增

- 初始公开版本发布
- 面向 Linux VPS 的 `install.sh` 一键安装入口
- 安装完成后自动打开管理面板，并注册全局命令 `sbox`
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
