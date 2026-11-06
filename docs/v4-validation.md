# v4 验证记录

范围：全新 v4，不迁移旧版；保留原管理功能并增加固定 Argo 隧道。本轮仅更新仓库，不覆盖生产安装。

## 已完成

- 模块化源码 `src/*.sh` 经 `python3 -B tools/build.py` 生成单文件 `singbox.sh`；用户部署不依赖 Python。
- 111 项自动测试通过，包括原有 DDNS、Swap、BestTrace 回归，v4 输入校验、节点、配置事务、共享隧道、凭据快照与失败恢复，以及旧版清理的 14 项回归。
- 真实 sing-box 1.14.4 校验 Reality / AnyTLS / WS / 转发 / WARP 配置；loopback VLESS + WS 完整代理请求成功。真实核心用例实际执行，未 skip。
- 真实 systemd 与 Alpine 3.24.4 OpenRC 在私有 mount / PID / network / UTS / IPC 命名空间中测试：安装、启用自启、启停、节点添加、SIGKILL 后自动拉起、锁不泄漏、端口冲突回滚、卸载保留配置后重装。
- Alpine 优先使用原生 musl 包，并实测 glibc + gcompat 的加载器进程识别；补有错误参数识别的回归用例。
- 真实 cloudflared 2026.10.7 在两种 init 环境启动；使用虚构 Token 和断网网络，实测真实节点探测失败、配置与元数据恢复、新建隧道服务及凭据清理。没有使用真实账号凭据。
- `bash -n`、`sh -n`、ShellCheck 0.11.0 warning 级检查、构建一致性、`git diff --check` 与 PTY 主菜单退出冒烟。

## v4.0.1 旧版清理入口

增加 `src/legacy.sh`：仅显式菜单操作后识别旧版服务，展示范围、精确 `y` 确认、加锁和二次核验；先保存私密备份，再停服务、检查残留旧 argv 进程、移除自启并删除已确认的旧安装。未知归属、v4 状态、配置挂载点、符号链接和 systemd drop-in 拒绝自动清理；保留新面板、已有备份及共享资源。清理成功后才进入单独确认的 v4 安装。

本次新增 14 项测试在临时目录实际执行文件备份与删除，仅 init 命令使用替身，覆盖取消、v4 面板保留、备份 / 停止失败、残留进程、systemd / OpenRC、异常归属与安装确认边界。没有在本机生产环境执行旧版清理，也不将替身测试冒充旧版真实 init 卸载验收。此前 v4 的真实隔离生命周期结果见上文；此次新增清理分支尚未在真实 init 隔离环境重跑。

## 尚未验证

- Cloudflare 真实固定域名隧道成功全链路。离线失败回退和本机 WS 测试不能代替此项。
- 完整虚拟机 / 实机断电重启后的自启；隔离环境验证了服务 enable 和启动、异常恢复，不冒充整机重启。
- 菜单措辞与小白体验待用户确认；没有部署到生产。

## 常规回归

```sh
python3 -B tools/build.py
bash -n singbox.sh
sh -n install.sh
python3 -B -m unittest discover -s tests -v
shellcheck --severity=warning singbox.sh install.sh tests/isolated-*.sh tests/run-isolated-openrc.sh
git diff --check
```

真实核心可用 `SB_TEST_CORE=/path/to/sing-box` 指定；缺少时会明确 skip。

## 手动隔离生命周期回归

这两个测试需要 root、Linux 命名空间；systemd 测试还需要 merged-/usr 主机和 cgroup v2。只接受 `/var/tmp/sb-v4-isolated.*` 下的专用测试目录，不接受生产根目录。不把它们作为普通单元测试自动运行。

预先从上游下载并核对 release API 摘要，准备：

- 测试目录：`release.json`、`core.tar.gz`（Linux amd64 核心压缩包）、`cloudflared` 可执行文件。
- OpenRC：另准备该目录下的 `root/` Alpine minirootfs，安装 bash、jq、curl、util-linux、iproute2、openrc、ifupdown-ng、gcompat、libc6-compat、ca-certificates；其 `work/` 中放 `release.json`、`core.tar.gz`、`core-musl.tar.gz`、`official-core`（解包的标准核心）和 `cloudflared`。创建独立设备节点，不绑定宿主 `/dev`。

```sh
bash tests/run-isolated-openrc.sh /var/tmp/sb-v4-isolated.XXXXXX/root
python3 -B tests/run-isolated-systemd.py /var/tmp/sb-v4-isolated.XXXXXX
```

下载过程在隔离测试之前完成。测试网络仅 loopback，curl 下载接缝只提供已经核验的上游文件；核心、cloudflared、init 服务和失败探测均实际运行。systemd 创建唯一专用 cgroup，结束后只回收自己的进程与 cgroup；OpenRC 使用独立 chroot。服务操作前强制核验各命名空间确实与宿主不同。

测试后核对生产面板与配置散列、服务 PID 和启动时间均未变。曾在早期测试发现遗漏 UTS 隔离导致宿主运行时主机名变化，已停止测试、经用户确认恢复，并给两个测试入口补上 UTS / IPC 隔离与回归保护。
