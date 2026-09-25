# Sing-box 管理面板

面向 Debian / Ubuntu / RHEL 系服务器的 Sing-box 一键管理脚本。通过交互式菜单集中管理 VLESS-Reality 节点、TCP/UDP 端口转发、Cloudflare WARP 分流、DNS 与防火墙，并提供配置校验、自动备份和失败回滚。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
```

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
- 自动生成分享链接和二维码
- TCP / UDP 端口转发规则增删查

### Cloudflare WARP 分流

- 基于 sing-box 1.11+ `endpoint` 架构配置 WARP
- WARP 账号自动注册与配置
- AI 服务分流（ChatGPT、Claude、Gemini 等）
- 流媒体分流（Netflix、Disney+、YouTube 等）
- 自定义域名、域名后缀、关键词和 IP 网段分流
- 指定入站节点全部走 WARP
- 查看和删除已添加的 WARP 规则

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

- Debian / Ubuntu 或 RHEL 系 Linux
- root 权限
- 建议使用支持 UTF-8 的终端
- 安装脚本会自动安装 `curl`、`jq`、`wget`、`qrencode`、`ufw` 等依赖

## 更新

重新执行一键安装命令即可更新脚本：

```bash
bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
```

## 项目文件

- `singbox.sh`：主管理脚本
- `install.sh`：一键安装与更新脚本

## 免责声明

本项目仅用于合法的服务器运维和网络测试。请遵守所在地区法律法规以及服务提供商的使用条款。
