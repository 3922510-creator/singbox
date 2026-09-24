# Sing-box 管理面板

生产级 Sing-box 一键管理脚本：VLESS-Reality 节点、TCP/UDP 端口转发、Cloudflare WARP 出口分流（AI / 流媒体 / 自定义域名），配置校验 + 自动回滚 + 并发锁。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
```

安装后使用快捷指令启动：

```bash
SB      # 或 sb
```

## 功能

- 系统管理：安装/更新 sing-box 核心、启停、卸载、状态、日志
- 节点管理：VLESS-Reality 添加/删除、分享链接、二维码
- 端口转发：TCP/UDP 转发规则增删查
- WARP 出口（sing-box 1.11+ endpoint 架构，warp-reg 本地注册账号）：
  - AI 服务走 WARP（ChatGPT / Claude / Gemini 等）
  - 流媒体走 WARP（Netflix / Disney / YouTube 等）
  - 自定义域名走 WARP
  - 查看 / 删除已添加的分流规则
- 实用小工具：
  - 流媒体解锁检测（ChatGPT / YouTube / Netflix / Disney+ / TikTok，快速原生检测）
  - 完整社区检测脚本（RegionRestrictionCheck）
  - DNS 设置（Cloudflare / Google / Quad9 / AliDNS / 自定义，带备份恢复）
  - 防火墙 ufw 设置（开放/关闭端口、启用/停用，自动保留 22/SSH 防锁死）
- 配置诊断：查看原始 JSON、手动编辑、重置、回滚上次有效备份

## 说明

- 需 root 运行，支持 Debian/Ubuntu 与 RHEL 系。
- 分流规则集来自 SagerNet/sing-geosite，首次启动自动下载（走 direct，需服务器可访问 GitHub）。
- 更新脚本：重新执行一键安装命令即可覆盖更新。
