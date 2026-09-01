# Sing-box / Xray 一键安装与管理面板

![CI](https://github.com/renaissance0721/singbox/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/github/license/renaissance0721/singbox)

一个只面向 Linux VPS、以 `sing-box` 为基础并支持按需安装 `Xray-core` 的一键管理脚本。

## 功能特性

- 只支持 Linux VPS
- 输入安装命令后先进入终端管理面板
- 在面板选择“安装 / 初始化 sing-box”后安装依赖与软件源可用的最新 sing-box **1.13 系列稳定版**，并自动确保内核包含 `with_v2ray_api`
- 退出后可直接输入 `sbox` 重新打开面板
- 支持输入 `sbox uninstall` 一键卸载
- 支持重新安装 / 修复并保留现有规则；面板可一键安全更新管理脚本
- 新建节点时询问节点名称和出口地址；同时检测到公网 IPv4/IPv6 后自动搭建双栈节点，并支持在节点管理中随时更改地址
- 支持在节点管理中设置 VPS 出站 IPv4/IPv6 优先级、禁用其中一个地址族或跟随系统
- 支持在节点管理中开启 CN IP 出站限制，阻止代理请求访问中国大陆目标 IP，默认关闭，不限制国内客户端入站连接
- 支持 `Shadowsocks`、`VLESS + Reality`、`Hysteria2`
- VLESS + Reality 可选择 Xray-core 或 sing-box；两种内核共用相同的搭建、客户端和分享链接流程
- Xray 使用隔离的脚本托管路径和独立 `sbox-xray` 服务，不覆盖系统已有 Xray；管理脚本更新和配置重载不会隐式升级核心
- 支持客户端新增、删除、导出
- 自动生成 Reality 密钥、随机密码和 Hysteria2 自签名证书
- 新建 Shadowsocks 主节点与分流仅提供 SS2022；主节点的监听端口由端口与防火墙管理统一控制
- 经 Shadowsocks、VLESS 或 Hysteria2 入站转发的流量都会拒绝访问本机、私网、链路本地地址和常见云元数据地址
- Realm 仅启用 TCP 转发；升级时会迁移旧配置并清理脚本管理的 Realm UDP 放行规则
- Realm 每条规则可选择直接转发或通过脚本托管的点对点 WireGuard 隧道转发
- 支持 WireGuard 落地端/中转端公钥配对、状态检查、目标端口测试、修改、修复和依赖保护
- 支持按用途查看监听端口、已监听未开放端口和已开放未监听端口，并持久开放或关闭指定端口
- 支持 UFW、firewalld、iptables/ip6tables，并为托管规则提供 systemd/OpenRC 重启恢复
- iptables/ip6tables 托管规则保留既有拒绝、限速和 Fail2ban 的优先级，并兼容链末端默认拒绝规则
- 支持零预置的自定义分流规则集，可随时新增、查看和删除
- 支持添加多个 SOCKS5 / Shadowsocks 分流落地
- 集成 NodeQuality、TcpQuality、Tcpfit、流媒体解锁和 IP 质量体检的一键入口

## 适用环境

- Linux VPS
- Debian / Ubuntu、RHEL 系列或 Alpine Linux
- `systemd` 或 OpenRC
- `root` 或具备 `sudo` 权限的用户
- Realm 自动安装支持 `x86_64/amd64` 与 `aarch64/arm64`，并自动区分 glibc 和 musl
- Xray 自动安装支持 `x86_64/amd64`、`aarch64/arm64`、`armv7` 与 32 位 x86
- 云厂商安全组或 NAT 映射已允许协议对应端口；脚本只能管理 VPS 本机防火墙

## 快速开始

已经进入 root shell 时，可使用一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | bash
```

当前用户不是 root 时使用：

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | sudo bash
```

Alpine Linux 请先安装 Bash 和 curl，再使用 root 执行：

```sh
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/renaissance0721/singbox/main/install.sh | bash
```

一键命令会直接执行 `main` 分支上的安装器。希望先审查代码或固定安装内容时，建议下载仓库后执行：

```bash
git clone https://github.com/renaissance0721/singbox.git
cd singbox
sudo bash install.sh
```

Alpine 使用本地仓库安装时：

```sh
apk add --no-cache bash curl git
git clone https://github.com/renaissance0721/singbox.git
cd singbox
bash install.sh
```

安装脚本会：

- 安装管理命令到 `/usr/local/bin/sbox`
- 在安装前校验 `index.sh` 的内置 SHA-256，并使用临时文件原子替换
- 自动打开管理面板
- 由用户选择“安装 / 初始化 sing-box”后执行初始化安装
- 选择 Xray-core 搭建 VLESS 时，按需下载 XTLS 官方稳定版并校验官方 SHA-256 摘要；不会执行远程 Xray 安装脚本
- 自动创建无登录权限的 `sbox-runtime` 用户，代理服务不以 root 运行
- systemd/OpenRC 均保留低端口监听能力，不需要手动设置权限或 capabilities

以后重新进入面板，只需要执行：

```bash
sbox
```

如需直接更改所有协议共用的节点出口 IP 或域名，也可以执行：

```bash
sbox change-address
```

修改后会自动重新生成客户端配置和订阅链接，并按需重载 sing-box 服务。

## 命令速查

所有管理操作均需要 root 权限；非 root 用户请在命令前添加 `sudo`。

| 命令 | 说明 |
| --- | --- |
| `sbox` | 打开主菜单 |
| `sbox quick-install` | 安装依赖与 sing-box 1.13 系列稳定版，初始化基础环境；不会自动创建节点 |
| `sbox enable-v2ray-api` | 按当前版本在本机重编译，只补充 `with_v2ray_api`，不升级内核；也可在主菜单选择 11 |
| `sbox node` | 打开代理节点管理菜单 |
| `sbox change-address` | 更改所有协议共用的节点出口 IP 或域名 |
| `sbox delete-node` | 删除一个已经启用的协议节点及其客户端 |
| `sbox add-client` | 为指定协议新增客户端 |
| `sbox remove-client` | 删除指定协议的客户端 |
| `sbox show` | 查看全部客户端信息和订阅链接 |
| `sbox apply` | 重新生成配置、同步防火墙并重载服务 |
| `sbox overview` | 查看节点、协议、客户端和分流概览 |
| `sbox status` | 查看服务状态与最近日志 |
| `sbox split` | 打开分流管理菜单 |
| `sbox split-route` | 新增 SOCKS5 或 Shadowsocks 分流落地 |
| `sbox edit-split-route` | 编辑、启用或停用分流落地 |
| `sbox delete-split-route` | 删除分流落地 |
| `sbox split-rules` | 查看全部分流落地与规则 |
| `sbox add-split-rule chatgpt claude` | 新增关键词规则并选择绑定落地 |
| `sbox delete-split-rule` | 删除关键词、域名、GeoSite 或远程 SRS 规则 |
| `sbox realm` | 打开 Realm 与 WireGuard 管理菜单 |
| `sbox ports` | 查看端口并管理本机防火墙规则 |
| `sbox tools` | 打开一键常用脚本菜单 |
| `sbox repair-install` | 使用当前脚本修复依赖、权限、服务和配置，保留现有规则 |
| `sbox uninstall` | 卸载 sing-box、Realm 和本脚本管理的数据 |
| `sbox --version` | 查看脚本版本 |
| `sbox --help` | 查看命令帮助 |

## 节点与客户端管理

“安装 / 初始化 sing-box”只准备基础环境。安装完成后，需要进入“代理节点管理 → 新建节点”，选择并配置至少一个协议。选择 VLESS + Reality 后还会选择 Xray-core 或 sing-box；Xray 仅在第一次选择时安装，后续配置和用户操作不会触发升级。Shadowsocks、VLESS + Reality 和 Hysteria2 可以分别启用，并共用节点名称与出口地址。新建节点时会分别探测公网 IPv4 和 IPv6；同时检测到两种地址后会自动启用双栈监听，不再额外询问。双栈只生成一个使用主地址的客户端链接，默认主地址为探测到的 IPv4，不再额外生成 IPv6 节点。

节点管理会在 VLESS + Reality 已启用时单独显示“VLESS 核心类型”，值为 `xray` 或 `sing-box`；未启用 VLESS 时不显示该行。

节点管理中的“设置出站 IPv4 / IPv6 策略”控制 VPS 访问目标域名时的地址选择，可设为 IPv4 优先、IPv6 优先、禁用 IPv4、禁用 IPv6 或跟随系统。该设置不改变客户端连接节点所用的地址；“优先”模式在首选地址族不可用时仍允许使用另一地址族，“禁用”模式则只允许指定的单一地址族。

节点管理中的第 8 项“设置禁止访问 CN IP”提供开启和关闭选项，节点菜单及概览会显示当前状态。新安装和旧配置迁移默认关闭；设置保存在 `state.json` 的 `routing.block_cn_ip`，更新脚本或重启后保留。开关对本机所有已启用的 Shadowsocks、Hysteria2 和 VLESS 节点生效，VLESS 的 sing-box / Xray 两种核心均支持。

开启后，只拒绝代理请求访问规则库中标记为 CN 的中国大陆目标 IP，包括 IPv4 和 IPv6。不会按 `.cn` 后缀或国内域名分类拦截，也不额外封锁 HK/MO/TW 地址段；国内客户端仍能连接节点，SSH、系统自身联网及 Realm / WireGuard 中转不受这条代理规则影响。“系统代理 / TUN + 国内直连”中没有经过节点的请求不受限制。纯 Realm 中转不需要开启，应在实际处理代理请求的落地节点开启；此功能是访问限制，不承诺降低 IP 被墙概率。

CN IP 检查优先于已有分流：直接输入的目标 IP 先检查，域名在节点解析后再次检查，未命中才继续分流或直连。原有私网和云元数据保护继续保留；关闭开关后恢复原有分流和解析顺序。域名按当前地址族策略得到的候选地址判断，只要候选中命中 CN 就拒绝整个请求，因此混合境内外地址的域名也可能被拒绝。开启后，原先直接交给分流落地的域名也需要先在本机解析，可能影响解析耗时和 CDN 选择；如果远端落地再次解析域名，其结果可能不同，严格限制最终出口时应在最终落地同样配置限制。

sing-box 使用 SagerNet 的 `geoip-cn.srs` 远程规则集，每日检查更新，复用现有缓存。首次下载或加载失败时不能完成启用，脚本会尝试恢复原状态和运行配置；后续更新下载失败时继续使用已加载的规则。Xray 使用脚本已安装的 `geoip.dat`，在应用配置时检查可用性；该数据库随 Xray 安装 / 显式升级更新，不会每日自动更新，也不会因切换开关隐式升级核心。两套数据库的分类和更新时间可能有差异，实际拦截以节点当时的解析结果及对应规则库为准。切换开关会应用配置并重启托管代理服务，现有连接可能短暂中断。

首次创建某个协议节点时，脚本会自动创建一个默认客户端并立即生成服务端配置、客户端参数和订阅链接。之后可以通过“管理客户端”或以下命令继续增删客户端：

```bash
sbox add-client
sbox remove-client
sbox show
```

每次创建、删除或修改节点后，脚本会分别调用目标内核检查配置，再检查监听端口、同步本机防火墙并切换服务。任一服务启动失败时会恢复原配置和原服务状态。若没有启用任何协议，sing-box 与脚本托管的 Xray 服务都会停止，但状态文件会保留。

## 一键常用脚本

主菜单选择“一键常用脚本”，或执行 `sbox tools`，可以运行以下第三方项目：

| 选项 | 下载入口 |
| --- | --- |
| NodeQuality | `https://run.NodeQuality.com` |
| TcpQuality | `https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh` |
| Tcpfit | `https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh` |
| 流媒体解锁 | `http://check.unlock.media`（入口会跳转到上游脚本） |
| IP 质量体检 | `https://IP.Check.Place` |

管理面板会先将脚本下载到临时文件，确认内容非空且通过 Bash 语法检查后再执行，结束后删除临时文件。这些脚本由第三方维护，未固定版本或内容哈希，并会继承当前 root 权限；Tcpfit 等工具还可能修改系统网络参数。运行前应自行确认上游来源和行为。“更新脚本”的仓库身份与哈希校验不适用于这些第三方入口。

## 分流管理

进入面板后选择“分流管理”，可以新增多个落地。每个落地拥有独立名称、代理信息和规则集，例如：

```text
us-ai  -> chatgpt, openai
jp-ai  -> claude
```

同一个规则集只会绑定一个落地；将它添加到另一个落地时，脚本会自动从原落地解绑。存在重叠匹配时，域名后缀优先于关键词，同类规则按内容长度从长到短匹配，避免落地结果取决于创建顺序。

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

- SOCKS5：填写 IP 或域名、端口；用户名和密码认证可选
- Shadowsocks：填写 IP 或域名、端口、加密方式和密码

新建或编辑 Shadowsocks 分流落地时仅提供：

```text
2022-blake3-aes-128-gcm
2022-blake3-aes-256-gcm
2022-blake3-chacha20-poly1305
```

升级前已经保存的传统 AEAD、`none` 或 `plain` 配置会继续保留兼容，但菜单不再允许新建这些配置。

脚本不预置任何分流规则。新增落地或为已有落地追加规则时，可以选择以下四种类型：

- 自定义网址 / 域名：精确匹配该域名及其子域名，优先推荐
- GeoSite 分类：例如 `openai`、`netflix`、`youtube`
- 远程 SRS：可信来源提供的 HTTPS `.srs` 地址
- 关键词：按域名子串匹配，例如：

```text
chatgpt
claude
```

每个关键词会创建一个独立的内联规则集。也可以一次输入多个名称：

```bash
sbox add-split-rule chatgpt claude
```

执行后会提示选择这些规则要绑定到哪个落地。

关键词是域名子串匹配，可能覆盖名称相近的其他站点。需要精确匹配某个站点及其子域名时，优先使用“自定义网址 / 域名”。

也可以在“为落地新增分流规则”中选择“自定义网址 / 域名”，直接输入：

```text
nodeseek.com
https://www.nodeseek.com/space
```

网址可以不带 `http://` 或 `https://`。脚本会自动去除协议、`www.`、端口和路径，并让该域名及其子域名通过指定落地。

GeoSite 入口使用熟悉的分类名，但不会生成已被新版 sing-box 移除的旧 `geosite` 配置字段。脚本会把分类名转换为 SagerNet 官方发布的二进制规则集，例如 `openai` 对应：

```text
https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs
```

远程规则集每天检查更新，并使用 sing-box 缓存文件，服务重启时不必重复下载未变化的内容。自定义 SRS 只接受 HTTPS 地址；请仅使用可信来源，因为上游规则变化会直接影响流量去向。

匹配优先级固定为“自定义域名 > GeoSite / 远程 SRS > 关键词”。域名和关键词规则内部按长度从长到短匹配，避免较宽泛规则抢先命中。GeoSite 与远程 SRS 的内部规则由其发布者维护，若两个远程集合存在重叠，应避免把它们绑定到不同落地。

查看全部落地和分流规则：

```bash
sbox split-rules
```

删除关键词、网址、GeoSite 或远程 SRS 分流规则：

```bash
sbox delete-split-rule
```

## 使用流程

1. 执行安装命令，脚本会先打开管理面板。
2. 选择“安装 / 初始化 sing-box”。
3. 等待脚本安装依赖和官方 `sing-box` 软件包。
4. 进入“代理节点管理 → 新建节点”，选择协议并确认监听端口、节点地址及协议参数。
5. 保存后检查脚本输出的订阅链接，并在云厂商安全组或 NAT 面板放行、映射对应端口。
6. 使用客户端连接并测试；需要增加用户时进入“管理客户端”。
7. 退出面板后，输入 `sbox` 可随时重新打开。

## 生成文件位置

- 主配置文件：`/etc/sing-box/config.json`
- 面板状态文件：`/etc/sing-box-manager/state.json`
- Realm/WireGuard 状态文件：`/etc/sing-box-manager/realm-state.json`
- 配置备份目录：`/etc/sing-box-manager/backups/`
- 客户端导出目录：`/etc/sing-box-manager/clients/`
- Hysteria2 证书目录：`/etc/sing-box-manager/certs/`
- 远程规则集缓存：`/etc/sing-box-manager/rule-set-cache/cache.db`
- Realm 配置目录：`/etc/realm/`
- 脚本托管 WireGuard 配置与密钥：`/etc/wireguard/sbwg*.conf`、`sbwg*.key`、`sbwg*.pub`（不会修改其他 WireGuard 配置）
- 脚本托管防火墙状态：`/etc/sing-box-manager/firewall-managed.tsv`
- 手动端口开放/关闭策略：`/etc/sing-box-manager/firewall-port-policy.tsv`
- 管理脚本项目目录：`/usr/local/share/sbox/`
- OpenRC 日志：`/var/log/sing-box.log`、`/var/log/realm.log`

## 协议说明

### Shadowsocks

- 默认使用 `2022-blake3-aes-128-gcm`
- 默认端口在 `10000-60000` 范围内随机生成
- 新建节点可选择三种 SS2022 加密方式，并分别生成服务端主密码和用户密码
- Shadowsocks 不再设置来源 IP/CIDR 白名单；启用时与其他协议一样创建普通的托管端口放行规则
- SS 入站会在域名解析前后拒绝私网、链路本地地址和常见云元数据地址

### VLESS + Reality

- 默认端口在 `10000-60000` 范围内随机生成，并避开 Shadowsocks 默认端口
- 创建时可选择 Xray-core 或 sing-box；客户端仍使用同一种 `vless://` Reality 链接
- Xray 安装在 `/usr/local/lib/sbox-xray/` 并使用独立 `sbox-xray` 服务，不占用或覆盖 `/usr/local/bin/xray` 与 `xray.service`
- Xray 首次安装只选择 GitHub 标记的官方稳定版，校验 `.dgst` SHA-256 后记录版本和二进制摘要；配置操作不会自动升级
- 默认流控为 `xtls-rprx-vision`
- 会自动生成 Reality 密钥对和 `short_id`
- 创建时可按服务器地区选择默认 SNI：美西使用 `www.cartoonbrew.com`，香港使用 `ani-com.hk`，日本可选 `shin-ei-animation.jp` 或 `www.ritao.co`，其他地区使用 `www.tesla.com`；选定后仍可手动修改
- 已存在 VLESS 时重新选择内核会复用 UUID、Reality 密钥和 `short_id`，避免现有客户端链接失效
- 已存在 VLESS 时可在地区菜单中保持当前 SNI，避免重新配置时意外更换伪装域名
- 首次配置建议确认伪装域名和端口是否可访问
- VLESS 入站会在域名解析前后拒绝本机、私网、链路本地地址和常见云元数据地址
- 当前 SRS/GeoSite 分流由 sing-box 实现；选择 Xray 的 VLESS 不继承这些分流，其他由 sing-box 承载的协议不受影响

### Hysteria2

- 默认使用自签名证书
- 如需改为正式证书，可将证书放到 `/etc/sing-box-manager/certs/` 并修改状态文件中的路径
- 若继续使用自签名证书，客户端侧通常需要允许 `insecure`

### Realm 中转

- Realm 仅创建 TCP 转发，不启用 UDP
- 每条规则由本机监听端口和远端地址/端口组成
- 每条规则可以独立选择直接转发，或选择一个已经配对的 WireGuard 隧道
- WireGuard 只封装中转到落地之间的 TCP 数据包，Realm 和落地节点仍处理 TCP
- WireGuard 配置只添加对端 `/32` 路由，不修改默认路由，不启用 IP 转发或 NAT
- 落地端 WireGuard UDP 端口由脚本限制为指定中转公网 IP/CIDR
- 建立顺序为：落地端创建配对信息 → 中转端加入并生成响应 → 落地端完成配对 → 中转端测试隧道
- WireGuard 只能保护中转到落地这一段，不能隐藏客户端正在连接的中转公网 IP
- 更新旧安装时，脚本会把 Realm 配置迁移为 TCP-only，并清理本机由脚本管理的 UDP 放行规则
- 云厂商安全组、控制面板防火墙和 NAT 映射不受脚本管理，原有 UDP 映射需要自行删除

## 端口与防火墙管理

执行 `sbox ports` 可以：

- 查看全部 TCP/UDP 监听端口，并标注 Shadowsocks、VLESS、Hysteria2、Realm、WireGuard、SSH、HTTP/HTTPS 或实际占用进程
- 分别查看“已监听未开放”和“已开放未监听”的端口
- 一键开放当前全部监听端口
- 手动开放或关闭 `1-65535` 范围内的 TCP、UDP 或 TCP+UDP 端口
- 一键开放默认 TCP 端口：SSH 当前配置/监听端口以及固定的 `22`、`80`、`443`

注意事项：

- 应用配置前会停止旧服务并检查目标端口；端口被其他进程占用时不会修改防火墙
- 手动开放/关闭状态会持久保存；手动关闭会创建明确的拒绝规则，并覆盖节点自动放行，直至再次手动开放
- 修改 SSH 端口后，“开放默认端口”会同时开放新 SSH 端口与固定的 `22`；未再监听的 `22` 会显示在“已开放未监听”列表
- “一键开放所有正在监听端口”可能同时开放系统中的其他服务，执行前会显示确认提示
- iptables/ip6tables 规则带有 `sbox-managed` 标记并追加到现有策略之后，不会插到 Fail2ban、限速或人工拒绝规则之前
- UFW/firewalld 自动开关按脚本状态文件处理托管端口；相同端口/协议的同形人工规则仍可能受到同步影响
- 不要把节点或 Realm 监听端口设置成 SSH、Web 服务或其他程序已经占用的端口
- UFW 或 firewalld 已启用时优先使用对应后端，否则使用 iptables/ip6tables
- systemd 使用 `sbox-firewall.service` 在 sing-box、sbox-xray、Realm 启动前恢复规则；Alpine/OpenRC 在对应 iptables/ip6tables 服务存在时保存规则
- NAT VPS 的客户端使用商家分配的公网端口；sing-box 监听的是 NAT 映射后的内部端口，两者可能不同
- 本页面不检测也不修改云厂商安全组、外部防火墙或 NAT 控制面板

## 更新、修复与卸载

- “更新脚本”只更新管理脚本项目。更新成功后会重新打开面板；sing-box、Xray、节点和规则不会因此被删除或升级。
- `sbox repair-install` 使用当前已经安装的管理脚本重新检查依赖，修复 sing-box、已选用的 Xray、Realm 二进制兼容性、运行用户、文件权限、服务与防火墙恢复环境，然后重新应用现有配置。已有 Xray 保持记录版本，不会隐式升级。
- `sbox uninstall` 会在确认后停止并禁用 sing-box、脚本托管的 `sbox-xray`、Realm 和脚本托管的 `sbwg*` WireGuard 隧道，清理托管防火墙规则，卸载 sing-box 软件包，并删除本项目的配置、状态、密钥、客户端导出和管理命令。
- 完整卸载不会删除 `/usr/local/bin/xray`、用户已有的 `xray.service`、非 `sbwg*` WireGuard 配置，也不会修改云安全组、外部防火墙或 NAT 映射。
- 完整卸载不会删除非 `sbwg*` 的用户 WireGuard 配置，也不会修改云安全组、外部防火墙或 NAT 映射。卸载前请自行备份需要保留的客户端信息和配置。

## 故障排查

### `sing-box` 启动失败

```bash
journalctl -u sing-box -n 50 --no-pager
```

### 脚本托管的 Xray 启动失败

```bash
journalctl -u sbox-xray -n 50 --no-pager
```

### Realm 提示缺少 `GLIBC_x.x`

```bash
sbox repair-install
/usr/local/bin/realm --version
```

修复流程会保留 Realm 与 WireGuard 状态，下载 Realm 官方便携 musl 构建，核对 GitHub 发布资产的 SHA-256，并在覆盖现有二进制前执行版本自检。

### 配置重载失败

- 确认协议至少保留 1 个客户端
- 确认证书、私钥和伪装域名配置有效
- systemd：执行 `journalctl -u sing-box -n 50 --no-pager` 查看最近日志
- Alpine/OpenRC：sing-box 执行 `tail -n 50 /var/log/sing-box.log`，Realm 执行 `tail -n 50 /var/log/realm.log`

### WireGuard 隧道无法握手

```bash
sudo wg show
sudo ip route get 对端私网IP
sudo journalctl -u wg-quick@sbwg0 -n 50 --no-pager
```

- 确认落地云安全组已放行 WireGuard UDP 端口，且来源是中转公网 IP
- 确认中转 Endpoint 填写的是落地公网地址和公网映射端口
- 接口和握手正常但目标 TCP 端口不通时，检查落地节点监听及端口/防火墙放行状态
- 线路不支持 UDP 时 WireGuard 无法工作，应将 Realm 规则切回直接转发

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
sudo apt install curl jq openssl ca-certificates git tar gzip unzip iproute2 iptables util-linux

# RHEL / CentOS
sudo yum install curl jq openssl ca-certificates git tar gzip unzip iproute iptables util-linux

# Alpine Linux
apk add --no-cache bash curl jq openssl ca-certificates git tar gzip unzip openrc coreutils findutils iproute2 iptables iptables-openrc su-exec libcap-setcap
```

### `sing-box` 软件包安装失败

- 安装/修复时从 `sing-box` 与 `sing-box-oldstable` 的可用软件包中选择补丁号最高的 **1.13.x 稳定版**，排除 alpha、beta、rc 等预发布版本，并指定完整软件包版本安装。没有合适版本就报错，不自动改装 1.14 或其他系列；软件源可能晚于官方 Release 更新，Alpine 仍优先使用当前发行版的软件源。
- 已有高于 1.13 的内核不会被自动降级。主菜单 11 / `sbox enable-v2ray-api` 不受安装选版限制，始终按已有内核的原版本补充 API。
- 安装软件包后若缺少 `with_v2ray_api`，自动在 VPS 上重编译该版本；已有内核可执行 `sbox enable-v2ray-api` 或选择主菜单 **11**，不经过软件包安装/升级流程。已有此标签时直接跳过，无需 GitHub Actions 或预先发布内核。
- 编译优先固定原 `Revision`，无 revision 时使用当前版本的官方 tag；保留原有全部标签、CGO 设置与 Go 版本，只追加 `with_v2ray_api`。无法取得对应源码或工具链时明确失败，不改用最新版，也不删减功能。自动下载的 Go SDK 会校验官方 SHA-256，不覆盖系统 Go。
- 当前本机编译支持 amd64/arm64；含 Naive 且未使用 purego 的原内核还需下载对应 Chromium 工具链，并要求 amd64/glibc 构建主机（此类内核暂不能在 Alpine 或 ARM 主机本机编译）。大体积编译工作区默认放在 `/var/tmp`（不可用时回退到 `/tmp`），开始下载前要求至少 2 GiB 可用空间并建议预留 4 GiB；可用 `SBOX_BUILD_TMP_DIR=/mnt/data/tmp sbox enable-v2ray-api` 指向其他本地文件系统。编译期间原服务继续运行，结束后自动删除工作区。
- 新内核通过版本、revision、全部标签、V2Ray API 和现有配置检查后才替换，运行中的服务会短暂重启；启动失败会回退。原内核备份保留在 `/etc/sing-box-manager/backups/sing-box-before-v2ray-api-*.bin`。不修改 Agent、节点、客户端或 API 配置；启用 API 监听仍由后续配置完成。
- 1.13 选版限制仅作用于本脚本的安装流程；系统包管理器单独升级仍遵循系统的软件源策略，也可能覆盖自编译内核。之后执行 `sbox enable-v2ray-api` 可按升级后的当前版本重新补齐。
- Alpine 会先使用当前已配置的软件源，再显式尝试当前版本的官方 `community` 仓库；旧稳定版没有该软件包时，最后尝试由 `apk` 验签的官方 `edge/community` 软件包
- Debian / Ubuntu 请检查错误上方的 `apt-get update` 输出，以及 `https://sing-box.app/gpg.key`、`https://deb.sagernet.org/` 是否可访问
- RHEL / CentOS 请检查错误上方的 DNF/YUM 输出，以及 `https://sing-box.app/sing-box.repo` 是否可访问
- 脚本不会用未经签名或摘要校验的远程脚本、软件包或裸二进制绕过安装失败

## 安全提醒

- 请在你拥有管理权限的服务器上使用本脚本
- 一键安装命令会以 root 权限执行 `main` 分支上的 `install.sh`；安装器会拒绝空文件和 Bash 语法错误，但不再绑定 `index.sh` 固定哈希，安全敏感环境应先克隆仓库并审查代码
- 对外分享客户端配置前，请确认端口、域名、证书和密码都已按预期生成
- Shadowsocks、VLESS 和 Hysteria2 入站都依赖各自的认证信息，请妥善保管客户端配置
- 私网、链路本地地址和元数据阻断应用于 Shadowsocks、VLESS 与 Hysteria2 全部代理入站
- 客户端订阅、状态、备份和私钥使用最小文件权限；sing-box、脚本托管的 Xray 与 Realm 使用 `sbox-runtime` 低权限用户运行
- “更新脚本”无需手动输入哈希：脚本会固定校验 GitHub 仓库数字 ID，将 `main` 解析为不可变 commit，并核对提交身份、Git blob 哈希、SHA-256 与 Bash 语法；任一失败都不会覆盖当前脚本
- “一键常用脚本”运行的是未固定版本的第三方代码，并以当前 root 权限执行；语法检查不等于代码安全审计，使用前请确认来源可信
- 自动校验无法抵御 GitHub 所有者账号本身被完全接管；请为仓库所有者账号启用双重验证或 Passkey，并妥善保管访问令牌
- 本机防火墙放行不能代替云厂商安全组配置，也不能创建或删除 NAT 端口映射
- 公开仓库时不要提交任何真实节点配置、证书或导出的客户端信息
- 安全问题请优先查看 [SECURITY.md](SECURITY.md)

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
