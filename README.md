# Sing-box 管理面板 v4

面向 SSH 终端的小白用户：默认值减少技术选择，端口仍可自定义，Argo 还会询问 WS 路径。所有原有核心能力保留，新增固定 Cloudflare Tunnel 节点。

**v4 是独立新版，不迁移 v3、不接管未知 sing-box 配置或服务。** 检测到旧版安装时拒绝覆盖；可通过下方的显式清理入口先卸载旧版，再全新搭建。不要在仍需使用的 v3 生产安装上确认清理。单独的 DDNS 工具不受本次重构影响，说明见 [DDNS 文档](docs/ddns.md)。

## 使用与构建

运行入口仍为 `sb` / `SB`，安装器仍为 POSIX sh，适用于尚无 Bash 的 Alpine。

```sh
# 远端地址指向已发布 main；不会自动获取尚未发布的本地开发改动。
curl -fsSL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh -o install.sh
sh install.sh
sb
```

安装器先确认，只安装必要依赖和面板命令，不启动代理，不安装防火墙，不修改 DNS。二维码工具可在“核心与服务”中按需安装。安装器支持 `SINGBOX_RAW` 指定 HTTPS 主脚本镜像。

开发工作区：

```sh
python3 tools/build.py
bash -n singbox.sh
sh -n install.sh
python3 -m unittest discover -s tests -v
# 实际安装/配置需在干净测试机手动运行，且逐项确认：
bash singbox.sh
```

`src/` 是开发源码，`singbox.sh` 是自动拼接出的单文件分发产物。服务器不需要 Python，也不需要下载模块目录。请勿直接修改分发产物。

## 清理旧版并重新搭建

入口：**搭建 / 添加节点 → 4. 清理旧版并重新搭建**；或 **系统与高级设置 → 核心与服务 → 10**。

- 先检查旧版服务归属并列出清理路径；只有输入小写 `y` 才执行，直接回车、`n`、`Y` 均不执行。
- 清理前将旧配置（含 `.meta` 和密钥）、服务定义、旧脚本、日志保存到 `/var/lib/sb/backups/legacy-*` 私密目录。备份保留，不自动删除。
- 停止旧 sing-box、移除自启，删除旧核心、服务、`/etc/sing-box`、旧日志以及能确认属于 v3 的 `sb` / `SB` / `/root/singbox.sh`。停止或备份失败时不删除配置。
- **所有旧节点失效**；不迁移。当前 v4 脚本、已有备份、公共依赖、共享 cloudflared、云端 Tunnel / DNS 和系统 DNS / 防火墙 / BBR / Swap 均保留。
- v4 状态、未知服务、额外 systemd drop-in、配置目录符号链接或挂载点会阻止清理，不能靠这个选项删除其他软件。
- 清理后进入 v4 安装，安装仍需单独确认；取消安装不会恢复已清理的旧节点。若 `sb` 已被安装器替换为 v4，将保留该入口，可直接继续使用。

## 五个主入口

```text
1. 搭建 / 添加节点
2. 我的节点
3. 转发与分流
4. 检查与维护
5. 系统与高级设置
0. 退出
```

### 搭建 / 添加节点

- VLESS Reality：推荐、无需自有域名，可设置端口、SNI 和备注，自动生成 UUID、密钥和短 ID。
- AnyTLS Reality：自动生成密码与密钥；需要 sing-box >= 1.12 和支持 AnyTLS + Reality 的客户端。mihomo 不支持该组合。
- Argo：固定 Cloudflare Tunnel，VLESS + WebSocket + TLS，询问端口、路径、域名、Tunnel Token。
- 未安装时将引导确认安装核心、依赖和系统服务，无需先在多个菜单之间跳转。
- 检查配置与真实 TCP/UDP 监听端口，避免抢占其他程序端口；端口 1–65535，不接受前导零。
- 普通节点会提示本机防火墙和云安全组放行要求；只在用户单独确认后修改受支持的本机防火墙。

### 我的节点

统一选择 Reality / Argo 节点，再查看链接和二维码、修改备注、检查完整链路或删除。备注只影响显示和分享链接的名称，不需要重启；中文、空格和特殊字符进行 URL 编码。

删除节点时同步清理其分流关联；共享规则保留其余节点，不会因为删除一个节点而误删整条共享规则。

### 转发与分流

- TCP / UDP 转发：添加、查看、删除；保留直连到目标地址的默认行为。
- WARP：通过 warp-reg 注册 / 重置账号、查看出口、删除出口与相关规则。
- AI、流媒体、自定义域名后缀、指定节点全部走 WARP。
- 查看 / 删除具体分流规则，避免重复添加相同预设。
- Argo 是入口，WARP 是出口；两者独立，可以组合使用。AnyTLS 和 VLESS 节点都可按节点分流。

### 检查与维护

- 一键检查只读，不重置、不静默修复。
- sing-box / cloudflared 服务状态与日志。
- 配置查看、在副本上编辑、核心校验、重置、按备份目录回滚。
- 流媒体快速检测、完整社区脚本检测、BestTrace 回程路由测试。
- 第三方检测脚本需用户确认；HTTPS 下载并做 Bash 语法检查，独立子进程运行、结束清理。语法检查不代表第三方脚本已经经过安全审计。

### 系统与高级设置

- 核心安装 / 更新、启停 / 重启、查看版本、卸载（保留配置和备份）。
- Argo 本机隧道的启停、日志和无引用资源移除。
- DNS 预设 / 自定义 / 备份恢复。遇到由其他网络管理器维护的 `resolv.conf` 符号链接时拒绝直接覆盖，不关闭 systemd-resolved，不强行解锁文件。
- UFW 规则开放 / 删除 / 启用 / 关闭 / 重载。启用前识别实际监听的 SSH 端口，不能确认时拒绝自动启用，不假定端口是 22。面板不能修改云安全组。
- BBR + fq_codel、BBR + fq、CUBIC + fq_codel；BBRv3 内核安装 / 查看。
- TCP 缓冲区推荐值、8 / 16 / 32 MB、自定义、带宽 × RTT 估算和恢复。
- Swap 状态、创建、删除；只管理面板自己的 Swap，不接管系统或其他程序创建的 Swap。

系统工具不会作为节点搭建的默认附加步骤执行。内核安装后不自动重启服务器。

## Argo 配置流程

1. 在面板选择 Argo，填写本机回源端口、WS 路径，可回车采用默认值。
2. 面板显示回源地址；用户自行在 Cloudflare 创建固定 Tunnel，并配置公开主机名：
   - 类型：`HTTP`
   - 服务地址：`127.0.0.1:所选端口`
   - 此服务地址不附加 WS 路径。
3. 回到面板填写节点域名与 **Tunnel Token**。只粘贴 Token 本身，不是整条安装命令，也不是 Cloudflare API Token。
4. 确认后安装 cloudflared、创建或复用本机隧道服务、生成节点入站与 UUID、设置自启。
5. 通过真实 sing-box 客户端发起代理请求验证完整链路。失败则回退本次节点变更；不会拿 cloudflared 进程存活冒充连接成功。

```text
客户端 -- WSS / 域名:443 --> Cloudflare
                               |
                          固定加密隧道
                               |
                          cloudflared
                               |
             HTTP / WS / 127.0.0.1:用户端口
                               |
                    sing-box VLESS 入站
                               |
                      直连 / WARP 出口
```

- 本机回源端口仅监听 `127.0.0.1`，不向公网开放。客户端连接端口始终是 443。
- WS 路径由 sing-box 校验，分享链接自动填写同一路径。
- 每个固定 Tunnel ID 托管一个 cloudflared 服务；多个不同域名的节点可以复用同一隧道，云端各自配置对应回源端口。
- 相同域名不重复创建节点；本版不做一个域名按不同路径映射多个回源的复杂配置。
- 最后一个关联节点删除后，移除对应本机服务和 Token；仍有关联时不停止共享隧道。
- 没有 Cloudflare API 权限，因此不创建、不修改、不删除云端 Tunnel 或 DNS。

## 安全、存储与恢复

- 打开菜单不安装依赖、不创建配置、不更新服务定义。非交互 EOF 返回或退出，不死循环。
- root 权限；systemd / OpenRC 服务管理。没有可靠 init 系统时，拒绝部署服务，不使用 nohup 凑合托管。
- 配置和节点元数据必须保持关联；手动编辑不能将 Argo 回源改成公网监听。
- 修改流程：生成候选 → 核心校验 → 展示影响与确认 → 加锁 → 备份 → 原子写入 → 重启验收。失败恢复本次变更前的配置和元数据；服务恢复失败会明确报错。
- 共享 sing-box 配置变更会短暂重启核心，可能中断所有节点的现有连接，确认时明确提示。
- 核心升级前使用候选二进制校验现有配置；更新失败恢复上一核心。不使用过时版本兜底，不清理 `/tmp/sing-box*` 之类通配路径。
- Tunnel Token 隐藏输入，文件权限 `600`，所在目录 `700`；cloudflared 使用 `--token-file`，Token 不进入进程参数、分享链接或面板日志。
- `/etc/sing-box/config.json`：核心配置。
- `/etc/sing-box/.meta/state.json`：v4 格式标记及节点元数据。
- `/etc/sing-box/.meta/tunnels/<Tunnel ID>/`：私密 Token 与隧道归属记录。
- `/var/lib/sb/backups/change-*`：每次已确认配置变更的配置、元数据和隧道凭据快照。含私密信息，目录权限 `700`，不上传、不自动删除。
- 配置回滚可从快照恢复已删除节点所需的本机隧道资源；云端资源始终由用户管理。回滚后应再次运行节点检查。
- DNS、BBR、TCP 缓冲区、Swap 的系统变更使用各自备份 / 恢复入口，不随节点配置回滚自动改变。

## 验证范围

自动测试覆盖原有 DDNS、Swap、BestTrace，以及 v4 节点、菜单、端口与输入校验、配置失败回退、Token 存储、共享隧道和资源恢复。

当本机存在真实核心时，额外校验 Reality / AnyTLS / WS / 转发 / WARP 配置，并执行仅绑定 loopback 的真实 VLESS + WS 代理测试。可用 `SB_TEST_CORE=/path/to/sing-box` 指定测试核心。

已在私有 mount / PID / network / UTS / IPC 命名空间中运行真实 systemd 和 Alpine OpenRC：安装、启用自启、启动、停止、节点添加、崩溃重拉、端口冲突回滚、卸载后重装均通过。Alpine 优先安装上游原生 musl 包，另覆盖 glibc + gcompat 的进程识别。

真实 cloudflared 在上述隔离环境启动，并以虚构 Token、断网条件验证探测失败后的配置与资源回退。**这不是 Cloudflare 真实固定隧道成功验收，也不是整机重启自启验收。** 云端全链路和小白交互体验仍待验证；生产安装未替换。详见 [验证记录](docs/v4-validation.md)。

## 文件结构

```text
src/header.sh         常量、平台、配置事务、核心与服务
src/core.sh           维护、恢复、DNS 和防火墙
src/legacy.sh         显式识别、备份和清理旧版
src/nodes.sh          节点与转发
src/argo.sh           固定隧道和完整节点检测
src/warp.sh           WARP 出口与分流
src/system-tools.sh   网络调优、Swap、解锁和回程检测
src/menus.sh          五个入口与交互
singbox.sh            生成的单文件
install.sh            POSIX 安装器
DDNS 相关文件          独立工具，见 docs/ddns.md
```
