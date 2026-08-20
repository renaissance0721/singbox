# 更新日志

本文件记录项目对外发布后的主要变更。

## [Unreleased]

- 检测到 APT/dpkg 软件包锁被其他进程持有时，安全等待其正常结束后自动重试 `dpkg --configure -a`；等待超时会报告持锁 PID，且绝不删除锁文件。
- 将 VLESS Reality 的默认 SNI 与握手站点恢复为 `www.tesla.com`，避免未经跨线路验证的目标站点导致握手兼容性问题。
- 修复未启用 `systemd-resolved` 的 Linux 上 sing-box 本地 DNS 解析失败：启用 Go 解析器，避免 VLESS Reality 握手站域名解析报错。
- WireGuard 中转端检测到邀请中的私网地址冲突时，会自动协商新的空闲地址并由落地端同步应用。
- 修复 WireGuard 工具安装流程：检测到缺少 `ip` 时，会按发行版自动补装 `iproute2` 或 `iproute`，并避免重复安装已有工具；APT 安装前会自动执行 `dpkg --configure -a` 恢复中断的软件包状态；包管理器安装完成后异常退出时，以实际命令检测结果为准，避免误报安装失败。

### 新增

- 节点管理新增出站 IPv4 / IPv6 策略设置，支持 IPv4 优先、IPv6 优先、禁用 IPv4、禁用 IPv6 及跟随系统，并在应用失败时自动恢复原设置
- 新建节点时分别探测公网 IPv4 与 IPv6；检测到双栈网络后自动启用双栈监听，客户端仅生成一个主地址链接，不再额外生成 IPv6 节点
- 主菜单新增“一键常用脚本”，可直接运行 NodeQuality、TcpQuality、Tcpfit、流媒体解锁和 IP 质量体检
- Realm 规则支持按规则选择公网直连或点对点 WireGuard 隧道
- 新增 WireGuard 落地端/中转端双向公钥配对、状态、测试、修改、服务控制、修复和安全删除菜单
- WireGuard 落地 UDP 监听支持中转来源白名单，Realm 启动前验证关联隧道接口和 `/32` 路由

### 变更

- Shadowsocks 来源白名单改为独立的新增与删除操作；新增来源不再覆盖原列表，删除时逐项选择，并禁止删除最后一条以避免意外全网放行
- 旧 Realm 规则自动迁移为 `direct`，不会因升级改变原转发路径
- WireGuard 与 Realm 安装生命周期解耦；落地端进入隧道菜单不会被强制安装 Realm
- Realm 卸载时保留独立 WireGuard 隧道；完整卸载仅删除脚本托管的 `sbwg*` 配置和密钥

### 修复

- Debian/Ubuntu 与 RHEL 系列显式安装提供 `runuser` 的 `util-linux`；节点配置检查会自动补装缺失的低权限执行工具，并能识别不在原始 `PATH` 中的 `/usr/sbin/runuser` 或 `/sbin/su-exec`
- OpenRC 服务准备阶段自动补装并定位 `setcap`，不再因绕过初始化安装流程而阻止新建 sing-box 节点
- Alpine 初始化依赖补充 `iptables-openrc`；节点应用时会自动补装缺失的 iptables/OpenRC 持久化组件和 `ss` 端口检查工具，不再要求先手动执行 `repair-install`
- 修复严格 `umask` 将 `/etc/apt/keyrings` 创建为仅 root 可访问，导致 Debian/Ubuntu 安装 sing-box 时误报 `NO_PUBKEY` 的问题
- 安全更新增加 curl IPv4 与 wget 备用下载路径；不可变 Raw 入口不可用时，允许使用已通过仓库、所有者、提交身份及 Git Blob 哈希校验的 GitHub API 内容继续更新
- 更新失败时显示明确的网络、身份、哈希、语法或写入阶段，不再只返回无法定位原因的合并提示
- Realm 卸载移动到子菜单末尾，降低数字误输入导致误操作的风险
- 主菜单、Realm、WireGuard、节点、分流和端口菜单统一捕获操作失败状态，修复提示“按回车返回菜单”后因 `set -e` 直接退出脚本的问题
- “查看当前概览”和“查看服务状态”改为独立容错页面，单项状态读取失败时显示未知并强制返回主菜单

### 安全

- VLESS、Hysteria2 与 Shadowsocks 统一阻断本机、私网、链路本地和云元数据目标，并在域名解析后再次检查
- sing-box 与 Realm 改由无登录权限的 `sbox-runtime` 用户运行，systemd 服务增加最小权限沙箱，OpenRC 使用最小文件能力兼容低端口
- 状态、客户端订阅、备份和密钥目录强制使用最小权限
- 应用防火墙前检查端口占用；冲突时恢复旧服务且不修改防火墙
- iptables/ip6tables 托管规则增加 `sbox-managed` 标记，置于现有规则之后、无条件终止规则之前，避免越过拒绝、限速和 Fail2ban 且兼容默认拒绝策略
- 管理脚本支持一键安全更新：固定校验 GitHub 仓库/所有者数字 ID，将分支解析为不可变 commit，并自动验证提交身份、Git blob 哈希、SHA-256 和 Bash 语法；取消未经校验的 `curl | sudo bash` 更新链
- 安装器不再绑定需要随 `index.sh` 手动同步的固定 SHA-256；下载后仍检查文件非空与 Bash 语法并原子替换，避免正常更新导致安装失败
- APT 仓库密钥固定校验官方指纹；Realm 发布包校验 GitHub 发布摘要并以低权限解压和运行
- WireGuard 只允许对端 `/32` 路由，拒绝默认路由设计；不启用系统 IP 转发或 NAT，私钥始终留在本机

## [0.4.1] - 2026-08-02

### 新增

- 新增 Realm TCP 中转管理；旧 Realm 配置会迁移为 TCP-only，并清理脚本管理的 UDP 放行规则
- 新增 Shadowsocks 来源 IP/CIDR 白名单，可限制为中转 VPS 出口地址
- 新增 Shadowsocks 私网、链路本地地址和常见云元数据地址访问阻断
- 新增端口管理菜单，可查看监听端口/占用进程及脚本托管端口状态
- 新增 UFW、firewalld、iptables/ip6tables 托管规则同步和 systemd/OpenRC 重启恢复
- 节点管理新增更改节点地址功能，修改后自动更新客户端配置与订阅链接

### 变更

- 新建 Shadowsocks 主节点与分流落地仅提供三种 SS2022 加密方式
- 保留已有传统 AEAD、`none` 和 `plain` 状态兼容，但不再允许从菜单新建
- Realm 转发仅开放 TCP
- Debian/Ubuntu、RHEL 和 Alpine 依赖增加 `iproute`/`iproute2` 与 `iptables`

### 修复

- 修复托管防火墙规则在服务重启和系统重启后的生命周期问题
- 防火墙同步、清理或验证失败时停止继续启动相关服务，避免配置处于不确定状态
- 修复 ShellCheck 0.9、0.10 与 0.11 的兼容性问题

## [0.3.0] - 2026-06-07

### 新增

- 新增通用分流管理，默认不预置任何规则集
- 支持仅输入 `chatgpt`、`claude` 等名称创建域名关键词规则集
- 支持随时新增、查看和删除分流规则集
- 支持 SOCKS5 和 Shadowsocks 分流落地
- 支持添加多个分流落地，每个落地独立绑定规则集
- 现有单落地配置自动迁移为名为 `default` 的落地
- 规则集改绑到新落地时自动从旧落地解绑
- Shadowsocks 分流落地支持传统 AEAD、`none` / `plain` 和 AEAD 2022 加密方式
- Shadowsocks 与 VLESS 默认端口改为在 `10000-60000` 范围内随机生成，并避免相互冲突

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
