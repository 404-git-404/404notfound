# 404notfound

面向 Debian 12/13（amd64、arm64）VPS 的交互式初始化向导。脚本必须以 root 运行，使用 Debian 默认 Bash；不会申请证书、配置 Cloudflare Tunnel、CF-WS、Reality/Hysteria2 节点或生成 sing-box 业务 JSON。

## 启动方式

上传整个仓库并保持现有 SSH 会话，然后运行：

```bash
bash 01-bootstrap.sh
```

RealityChecker 默认使用官方仓库 `V2RaySSR/RealityChecker`，从 GitHub Releases 的 `latest/download` 地址按架构下载固定资产。高级用户可用 `--reality-checker-repo OWNER/REPO` 覆盖仓库，资产文件名保持不变。

- `amd64`：`reality-checker-linux-amd64.zip`
- `arm64`：`reality-checker-linux-arm64.zip`

脚本首先执行完全只读的启动体检。在用户选择安装模式前，不执行 APT、不创建临时文件，也不修改系统配置。体检涵盖 Debian/架构/root/systemd、SSH、CPU/内存/磁盘、地址与路由、监听端口、DNS、IPv4/IPv6、APT/dpkg、时间、UFW、BBR、sing-box、SmartDNS 和虚拟化。

体检存在阻断问题时只能重新体检或退出；通过后显示：

```text
1. 快速安装
2. 自定义安装
3. 退出
```

所有交互均从 `/dev/tty` 读取。无 TTY 时只输出体检结果，随后明确退出。TTY 输出支持 ANSI 256 色；设置 `NO_COLOR`、重定向输出或无 TTY 时自动禁用颜色。

## 快速安装

快速安装除 SSH 公钥外不再逐项询问：

- 执行 `apt-get update` 和当前 Debian 大版本内的 `full-upgrade`；
- 安装并验证基础工具、chrony、BBR；
- SSH 固定为 `53651/tcp`，关闭 22，仅允许 root 公钥登录；
- 开放 `443/tcp`、`443/udp`；
- `8443/tcp` 只允许 Cloudflare 官方 IPv4/IPv6 地址段；
- 从 SagerNet APT 源安装 sing-box，保持 `disabled`、`inactive`；
- 安装并启动 SmartDNS，使系统 DNS 只使用 `127.0.0.1`；
- 从 RealityChecker 官方 GitHub Release 选择当前架构资产安装；
- 不要求第二终端确认，也不会主动终止现有 SSH 会话。

## 自定义安装

自定义模式先询问是否执行 `full-upgrade`；无论选择什么，都会执行 `apt-get update` 并安装基础工具。之后提供明确的停止点：

```text
基础工具已经安装完成。
1. 继续完整初始化
2. 退出，用于测试 IP、线路和基础环境
```

选择退出会保留已安装软件包，但不会配置 BBR、SSH、UFW、SmartDNS 或系统 DNS，也不会安装 sing-box/RealityChecker。

继续后依次输入公钥并选择：

- 新 SSH 端口；
- 是否保留 `22/tcp`；
- 是否开放 `443/tcp`；
- 是否开放 `443/udp`；
- 是否仅为 Cloudflare 开放 `8443/tcp`。

自定义端口必须为 1–65535 的数字，不能是 22、53、80、443、8443，也不能由非 sshd 进程占用。若需要 22，应使用单独的“保留 22”选项。

## 安全门禁与备份

每次实际安装会将覆盖前文件备份到：

```text
/var/backups/404notfound-bootstrap/<UTC时间>-<进程号>/
```

SSH 流程保留原有防锁死逻辑：

1. 验证并幂等写入 `/root/.ssh/authorized_keys`；
2. 备份主配置与 drop-in；
3. 写入 `/etc/ssh/sshd_config.d/00-hardening.conf`；
4. 处理会覆盖受管策略的全局冲突项；
5. 执行 `sshd -t` 和 `sshd -T`；
6. 只执行 `systemctl reload ssh.service`；
7. 验证新端口以及可选的 22 实际监听；
8. 任一步失败就恢复本轮 SSH 配置，且不进入最终 UFW。

UFW 只在 SSH 门禁全部成功后收紧。脚本精确清理 OpenSSH、旧 sshd 端口、本项目 Cloudflare 注释规则及全网 `8443/tcp` 规则，不删除无关的受限业务规则。

## SmartDNS 与系统 DNS

统一配置位于 `configs/smartdns.conf`，只监听 `127.0.0.1:53` 的 UDP/TCP，启用持久缓存、serve-expired、预取和测速策略。

主脚本会先检查 53 端口、备份并部署配置、启动 SmartDNS，然后验证：

- SmartDNS 配置可加载；
- `127.0.0.1:53/udp` 与 `/tcp` 均监听；
- `dig @127.0.0.1` 能解析。

全部成功后才备份并替换 `/etc/resolv.conf`。最终只保留 `nameserver 127.0.0.1`，没有公共备用 DNS；默认解析测试失败时恢复原来的普通文件或软链接。

## Cloudflare 8443

`scripts/update-cloudflare-ufw.sh` 独立维护 Cloudflare 地址段。它使用 `flock` 防并发，设置下载超时/重试，以 Python `ipaddress` 校验 CIDR，先加入完整新规则再清理旧规则，并核对带 `Cloudflare-8443` 注释的实际数量。

可独立运行：

```bash
bash scripts/update-cloudflare-ufw.sh
bash scripts/update-cloudflare-ufw.sh --remove
```

这会访问 Cloudflare 官方地址段接口；不会将 `8443/tcp` 向全网开放。

## 仓库结构

```text
404notfound/
├── 01-bootstrap.sh
├── request-cloudflare-certificate.sh
├── configs/
│   └── smartdns.conf
├── scripts/
│   └── update-cloudflare-ufw.sh
├── .github/workflows/shellcheck.yml
├── .gitattributes
├── AGENTS.md
└── README.md
```

`request-cloudflare-certificate.sh` 始终是独立工具，不属于初始化主流程。

## CI 与限制

CI 对三个 Shell 脚本执行 `bash -n` 和 ShellCheck，并确认 SmartDNS 配置存在且非空。仓库不会在 CI 中执行初始化、APT、VPS 连接或 Cloudflare 更新。

脚本只能验证服务器上的公钥格式、sshd 最终配置和本机监听，不能证明本地私钥、云安全组或外部网络一定可用。首次运行务必保持当前 SSH 会话，完成后自行从另一终端验证新端口。
