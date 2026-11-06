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

IP 来源固定为三个免费 HTTPS 接口，无需选择：

- ip.sb：`https://api.ip.sb/ip`
- ipify：`https://api4.ipify.org`
- icanhazip：`https://ipv4.icanhazip.com`

**三个接口必须全部返回相同且有效的公网 IPv4 才更新**，不是二比一多数投票。任一个超时、失败、返回无效内容或结果不一致，都保留原 DNS，等待下次检查。查询强制 IPv4，绕过环境代理；不读取本地网卡、不查询商家域名、不接受自定义来源。

**注意：接口获取的是公网出口 IPv4。** 三方一致不代表能验证 NAT 入站映射，使用前仍应核实出口与入站映射 IP 相同。

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

**首页直接显示目标域名、三接口校验策略、开机自启状态、自动更新运行状态、当前 Cloudflare A 记录和灰云状态**，无需进入子菜单。首页只读查询，不更新 DNS、不执行三接口 IP 检测；选 `1` 刷新状态。菜单另有三接口检测、立即更新 DNS、查看查询接口、最近 10 条换 IP 记录、开启/关闭自动更新、Bark 配置（`8`）和测试通知（`9`）。它是 SSH 终端菜单，**不开放 Web 端口，不改 SSH 服务**。状态展示使用中文，不输出 Token；菜单自动清屏，操作结果按回车返回，不再反复堆叠。所有 DDNS 确认统一使用 `[y/N]`：`y` / `Y` 执行，`n` 或直接回车取消。

**已安装 Shell 版**：重新运行上面的一键安装命令，输入 `y` 后升级，原 Token、域名和自启设置保留，不用重新填写，IP 来源统一切换为三个接口交叉验证。升级前自动备份旧脚本到 `/usr/local/lib/cloudflare-ddns.sh.bak.*`，校验新脚本并原子替换；systemd 同时备份并精确更新 DDNS service（`--scheduled` 静默运行、`StateDirectory=cloudflare-ddns` 可写目录），校验并 reload，下次运行加载新版本，不改变 timer 的开关；OpenRC 会在确认后重启 DDNS 服务。旧配置中的 `source_mode` / `source` 字段不再读取，不需要手动清理；无论旧版选过哪种来源，升级后均只走三个固定接口。

Token 仅在本机隐藏输入，存放于 `/etc/cloudflare-ddns/config.json`（目录 700、文件 600），不要发给别人或提交到 Git。安装后手动检查：

```sh
sh /usr/local/lib/cloudflare-ddns.sh --once
```

### 换 IP 日志：只保留最近 10 条

菜单 `5` 读取 `/var/lib/cloudflare-ddns/changes.log`（目录 700、文件 600），格式：

```text
2026-11-04 13:00:00 +0800  nat.example.com  1.1.1.1 -> 8.8.8.8
```

只有**已有 A 记录的 IP 改变且 Cloudflare 更新成功**才记一条；无变化、首次创建、仅灰云设置变化、查询失败或 DNS 更新失败均不写记录。每次原子替换，仅保留最新 10 条，时间为服务器本地时间并附 UTC 偏移。更新加锁，避免手动更新和定时任务同时写日志或重复推送。

后台正常轮询不再输出接口 IP 或“无变化”；系统 journal 自身的服务启停消息不属于这 10 条记录。升级不删除历史 journal、旧 OpenRC 日志或备份，也不会把旧调试日志导入新的换 IP 记录。

### Bark Webhook（支持自建）

在菜单 `8` 只填写一条基础推送链接，隐藏输入并保存到现有的私有配置文件：

```text
https://api.day.app/你的设备Key
http://192.168.1.3:8080/你的设备Key
https://bark.example.com/反代前缀/你的设备Key
https://用户名:密码@bark.example.com/你的设备Key
```

支持 HTTP / HTTPS、自建端口、反代前缀和 URL 内的 **HTTP Basic Auth（`用户名:密码@`）**，无需再填写鉴权字段。用户名或密码包含 `@`、`/`、`#` 等保留字符时须使用 URL 百分号编码。**不要附推送标题、正文或查询参数**。HTTP 会明文传输设备 Key，跨公网建议 HTTPS；URL 不出现在进程参数、换 IP 日志或首页。菜单 `8` 留空后确认可以关闭通知。

成功换 IP 后以 JSON POST 发送域名和 `原 IP -> 现 IP`，不变更 DNS 时不推送。菜单 `9` 发送测试通知，严格检查 HTTP 成功和 Bark JSON `code=200`，不修改 DNS、不写换 IP 日志。显示成功只代表 Bark 服务端确认接收，手机是否实际收到还需自行核对。通知失败不会回滚已成功的 DNS 更新，也不自动重复推送，可用菜单 `9` 检查连接。

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
cat /var/lib/cloudflare-ddns/changes.log
# 停用自动更新
rc-service cloudflare-ddns stop
rc-update del cloudflare-ddns default
```

修改配置前先备份；systemd / OpenRC 均会在下次检查时重新读取配置。此安装器不会覆盖旧版 Python 安装，已装旧版的机器需先停用旧服务并备份、迁移，不会自动卸载系统 Python。新的换 IP 日志自动保留 10 条，无需 logrotate。离线测试（不会访问 Cloudflare、不会通知真实设备，也不会操作宿主服务；Webhook 测试仅在本地随机空闲端口运行模拟服务器）：

```sh
python3 -m unittest discover -s tests -p 'test_ddns.py' -v
```
