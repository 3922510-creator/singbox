# Sing-box 管理面板

面向 Debian / Ubuntu / RHEL 系与 Alpine（OpenRC）服务器的 Sing-box 一键管理脚本。通过交互式菜单集中管理 VLESS-Reality / AnyTLS-Reality 节点、TCP/UDP 端口转发、Cloudflare WARP 分流、DNS 与防火墙，并内置 BBR / BBRv3 网络加速切换，提供配置校验、自动备份和失败回滚。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
```

Alpine（自带 ash、没有 bash）用这一行：

```sh
wget -qO- https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh | sh
```

安装器是 POSIX sh 写的，会把 `bash`、`curl`、`jq`、`qrencode` 等依赖一并装好（Alpine 上自动用 `apk`，需要时自动补 `community` 仓库）。
Alpine 上安装/更新核心时，脚本会实测官方二进制能否运行，不能就自动 `apk add gcompat libc6-compat`（官方 release 是 glibc 构建，Alpine 是 musl）。

安装完成后运行：

```bash
SB      # 或 sb
```

也可以直接下载脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/3922510-creator/singbox/main/singbox.sh -o singbox.sh
chmod +x singbox.sh
sudo bash singbox.sh
```

## 主要功能

### 节点与转发

- VLESS-Reality 节点添加、删除与管理
- AnyTLS-Reality 节点添加、删除与管理（需 sing-box ≥ 1.12.0，低于该版本菜单会直接拒绝并提示升级）
- 自动生成分享链接和二维码（VLESS 与 AnyTLS 节点一起按序号列出，选序号即可看对应二维码）
- TCP / UDP 端口转发规则增删查

> **AnyTLS + Reality 的客户端限制**：服务端只有 sing-box 内核能跑；客户端需 sing-box 内核（官方 sing-box、Karing、Hiddify、v2rayN 等），
> 或 Shadowrocket 2.2.65+（类型选 AnyTLS，TLS 开启后填 SNI / 公钥 / 短 ID / 指纹，导入 `anytls://…?security=reality&pbk=&sid=` 链接会自动带上）。
> mihomo（Clash Meta）明确不支持 AnyTLS+Reality（服务端与客户端都不支持），Xray 不支持 AnyTLS。
> 想要全平台可用的节点用 VLESS-Reality，要抗 TLS-in-TLS 长度特征时用 AnyTLS-Reality。

### Cloudflare WARP 分流

- 基于 sing-box 1.11+ `endpoint` 架构配置 WARP
- WARP 账号自动注册与配置
- AI 服务分流（ChatGPT、Claude、Gemini 等）
- 流媒体分流（Netflix、Disney+、YouTube 等）
- 自定义域名、域名后缀、关键词和 IP 网段分流
- 指定入站节点全部走 WARP
- 查看和删除已添加的 WARP 规则

### 网络加速（BBR / BBRv3）

菜单入口：实用工具 → 网络加速

- 一键切换 `BBR + fq` / `BBRv3 + fq`，或恢复系统默认 `CUBIC + fq_codel`
- 即时生效：写入 `/etc/sysctl.d/99-zz-bbr-mode.conf` 持久化，同时替换网卡根队列（默认队列只对新网卡生效）
- 先 `tc` 实测内核支不支持目标队列，不支持就直接拒绝且**一点配置都不改**（避免把内核没编译的 qdisc 写进 sysctl.d），回读校验失败还会把配置文件恢复原样
- 自动判定内核是否 BBRv3（内核 release 名 + `tcp_bbr` 模块 version 字段），不靠猜
- 从第三方源（`XDflight/bbr3-debs`）安装 BBRv3 内核（仅 deb 系；Alpine 用官方内核），可自选版本，不自动重启
- 查看已安装内核与完整状态判定依据

### 系统与网络工具

- 安装 / 更新 Sing-box 核心
- 服务启停、状态查看和日志查看
- 流媒体与 AI 服务连通性检测
- DNS 设置（Cloudflare、Google、Quad9、AliDNS、自定义）
- UFW 防火墙端口管理，自动保留 SSH 端口避免锁死
- 配置查看、手动编辑、校验、重置和回滚

## 安全与可靠性

- 必须使用 root 运行
- 配置修改先写入临时文件，校验通过后才正式替换
- 自动保留上一次有效配置，失败时自动回滚
- 使用并发锁，避免多个管理实例同时修改配置
- 规则集首次使用时自动下载，服务器需要能够访问 GitHub

## 系统要求

- Debian / Ubuntu / RHEL 系，或 Alpine（OpenRC）；init 系统自动识别
- root 权限
- 建议使用支持 UTF-8 的终端
- 安装脚本会自动安装 `curl`、`jq`、`wget`、`qrencode`、`bash` 等依赖

## 各发行版差异

| 项目 | Debian / Ubuntu / RHEL | Alpine |
| --- | --- | --- |
| 服务管理 | systemd (`systemctl`)，`Restart=on-failure` | OpenRC (`rc-service` / `rc-update`)，服务文件 `/etc/init.d/sing-box`；由 `supervise-daemon` 托管，进程崩溃/被 OOM 杀掉后 10s 内自动拉起（v3.4.8+） |
| 官方二进制 | 直接可用 | 需 `gcompat` + `libc6-compat`（脚本实测不能跑就自动装）；备选 `apk add sing-box`（musl 原生，版本略旧） |
| 日志 | `journalctl -u sing-box` | `/var/log/sing-box.log` |
| 包管理 | `apt` / `yum` | `apk`（二维码在 `libqrencode-tools`，需 community 仓库） |
| 防火墙 | ufw / firewalld | 默认无防火墙；若自建了 DROP 规则，添加节点时会用 `iptables` 放行 |
| BBR 切换 | 支持 | 支持（首次自动 `apk add iproute2` 拿到 `tc`） |
| BBRv3 内核安装 | 支持（deb） | 不支持，用官方内核：`apk add linux-lts` 等 |
| 无 init 的容器 | — | 自动降级为 `nohup` 托管，重启后需手动拉起 |

## 更新

重新执行一键安装命令即可更新脚本：

```bash
bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
```

## 项目文件

- `singbox.sh`：主管理脚本（需要 bash；systemd / OpenRC 兼容）
- `install.sh`：一键安装与更新脚本（POSIX sh，Alpine 可直接用 `sh` 跑）

## 免责声明

本项目仅用于合法的服务器运维和网络测试。请遵守所在地区法律法规以及服务提供商的使用条款。

## 节点备注

- 添加 VLESS-Reality / AnyTLS-Reality 节点时可输入备注（最多 80 字），支持中文、空格及特殊符号；分享链接的名称会自动 URL 编码。
- 已有节点：`sb → 节点管理 → 5 修改节点备注`，留空恢复默认名称。
- 列表、分享链接及二维码同步使用备注；已经导入客户端的名称不会自动变化，需重新导入或在客户端手动修改。
- 备注保存在 `/etc/sing-box/.meta/node-names.json`（权限 600），不修改节点内部 tag、端口、认证或路由，修改备注无需重启服务；原有节点未设置备注时继续显示 tag。

备注功能回归测试（隔离临时目录，不操作生产配置/服务）：

```bash
python3 -m unittest discover -s tests -v
```

## Swap 管理

入口：`sb → 实用工具 → 6 Swap 管理`。

- 查看系统全部 Swap 和内存状态；自定义 128–65536 MiB 创建 Swap，并写入 `/etc/fstab` 开机启用。
- 只创建和删除 `/var/lib/sb-swap/swapfile`，使用独立标记识别归属，不接管已有 `/swapfile`、Swap 分区或 zram；目录已存在时拒绝覆盖。
- 添加、删除都需输入 `确认`；删除前检查可用内存，`swapoff` 失败不会删文件或持久化条目。
- 修改 fstab 前保留 `/etc/fstab.sb-swap.bak.*` 备份，以同目录临时文件原子替换；不修改其他条目。持久化失败会尝试撤销创建/恢复启用，失败则保留文件并提示人工处理。
- 当前仅提供普通磁盘文件系统上的通用 Swap 文件流程；拒绝 Btrfs/ZFS、内存文件系统、NFS 和 overlay。容器没有 `swapon` 权限时会报错并清理本次创建文件，不改 fstab。
- 调整容量请先删除再添加；不会调整 swappiness，也不会重启 sing-box 或服务器。面板卸载 sing-box 不会删除 Swap。

## NAT 服务器 Cloudflare DDNS（独立脚本）

适合共享公网 IPv4 会变化、商家映射端口固定的 NAT 服务器。独立安装，**不依赖、不修改、不重启 sing-box**。

```sh
curl -fSL https://raw.githubusercontent.com/3922510-creator/singbox/main/install-ddns.sh -o /tmp/install-cloudflare-ddns.sh && sudo sh /tmp/install-cloudflare-ddns.sh
```

已经是 root 时可以去掉 `sudo`。支持 Debian / Ubuntu / RHEL 系（systemd）与 Alpine（OpenRC）；仅依赖 `sh`、`curl`、`jq` 和 CA 证书，不需要 Python。

安装过程中输入：

1. Cloudflare **API Token**：权限 `Zone / DNS / Edit` 和 `Zone / Zone / Read`，资源限制为对应域名，不用 Global API Key。
2. **Zone ID**：Cloudflare 域名概述页面可查看。
3. 目标完整域名，例如 `nat.example.com`。
4. 入站 IP 来源，三选一：商家的动态域名、返回纯文本 IPv4 的 HTTPS 接口、已确认与入站相同的本机出口 IP。

**重要：NAT 出口 IP 不一定是入站映射 IP。** 首选商家提供的动态域名或查询接口（JSON/鉴权接口目前不支持，需要按商家实际格式适配）。只有核实两者一致后才能选择本机公网 IP 模式：优先读取本机 IPv4 路由的源地址；网卡只有内网地址或没有 ip 命令时，通过 ipify 独立查询本机公网 IP，然后与 `https://api.ip.sb/ip` 比对。两者一致且都是有效公网 IPv4 才更新，任一接口失败或不一致都保留原 DNS。公网查询强制 IPv4、绕过环境代理，不会把内网地址写进 DNS。不能确定 IP 来源时不要随便选出口模式。商家域名通过 Cloudflare DNS-over-HTTPS 查询，不需要另装 dig；来源域名不能间接 CNAME 回目标域名，否则会形成自引用。

脚本每 60 秒检查一次，变化后更新 A 记录并设为**仅 DNS（灰云）**、TTL 60 秒。首次写 DNS 前展示地址并要求确认；无变化不写入，获取失败保留原 DNS；已有 Shell 安装会进入确认升级流程，未知同名文件拒绝覆盖，遇到同名 CNAME 或多条 A 记录会拒绝。域名生效速度受 DNS 缓存影响，不保证一分钟内全球生效。不会改 AAAA，若目标域名已有 AAAA，请自行核对，避免客户端优先连接错误 IPv6。

访问仍需带商家分配的**外部端口**，例如：

```sh
ssh -p 30001 root@nat.example.com
```

### SSH 终端管理菜单

安装或升级后，以 root 执行：

```sh
ddns
```

菜单提供：查看服务状态和 Cloudflare A 记录、检测本机公网 IP 并与 ip.sb 比对、立即更新 DNS、修改 IP 来源、查看日志、开启/关闭自动更新。它是 SSH 终端菜单，**不开放 Web 端口，不改 SSH 服务**。配置修改和服务开关先确认；修改 IP 来源前备份配置，原子替换后下一次检查生效。状态展示使用中文，不输出 Token；菜单自动清屏，操作结果按回车返回，不再反复堆叠。所有 DDNS 确认统一使用 `[y/N]`：`y` / `Y` 执行，`n` 或直接回车取消。

**已安装 Shell 版**：重新运行上面的一键安装命令，输入 `y` 后升级，原 Token、域名、来源和自启设置保留，不用重新填写。升级前自动备份旧脚本到 `/usr/local/lib/cloudflare-ddns.sh.bak.*`，校验新脚本并原子替换；systemd 下次运行加载新版本，OpenRC 会在确认后重启 DDNS 服务。已选择本机公网模式的配置会直接使用新校验逻辑；原先选择商家域名或接口的配置保持不变，可在菜单 **4 → 3** 切换到本机公网模式。

Token 仅在本机隐藏输入，存放于 `/etc/cloudflare-ddns/config.json`（目录 700、文件 600），不要发给别人或提交到 Git。安装后手动检查：

```sh
sh /usr/local/lib/cloudflare-ddns.sh --once
```

systemd 管理：

```sh
systemctl status cloudflare-ddns.timer
journalctl -u cloudflare-ddns.service -n 30 --no-pager
# 停用自动更新
systemctl disable --now cloudflare-ddns.timer
```

Alpine / OpenRC 管理：

```sh
rc-service cloudflare-ddns status
tail -n 30 /var/log/cloudflare-ddns.log
# 停用自动更新
rc-service cloudflare-ddns stop
rc-update del cloudflare-ddns default
```

修改配置前先备份；systemd / OpenRC 均会在下次检查时重新读取配置。此安装器不会覆盖旧版 Python 安装，已装旧版的机器需先停用旧服务并备份、迁移，不会自动卸载系统 Python。OpenRC 日志为本机文件，长期运行应纳入系统 logrotate。离线测试（不会访问 Cloudflare，也不会操作服务）：

```sh
python3 -m unittest discover -s tests -p 'test_ddns.py' -v
```
