# 404notfound

面向 Debian 12/13（amd64、arm64）VPS 的单文件交互式初始化向导。`404notfound.sh` 自包含 SmartDNS 配置和 Cloudflare 8443 UFW 更新工具，不依赖同目录下的配置或辅助脚本。

第一阶段会安装但不启动 sing-box，安装并启动 SmartDNS，安装 RealityChecker，并将 Cloudflare 更新工具部署到 `/usr/local/sbin/update-cloudflare-ufw`。它不会写入代理业务 JSON、创建代理节点、申请或部署证书，也不会配置 Cloudflare Tunnel 或 CF-WS。

## 单文件运行

下载后运行：

```bash
curl -fL \
  https://raw.githubusercontent.com/404-git-404/404notfound/main/404notfound.sh \
  -o 404notfound.sh

chmod 700 404notfound.sh
bash 404notfound.sh
```

也可以使用 Bash 进程替换一行执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/404notfound.sh)
```

运行前必须注意：

- 始终保持当前 SSH 会话，不要提前关闭；
- 最好准备云厂商 Console、VNC 或串行控制台作为应急入口；
- 快速安装会关闭 `22/tcp`，新 SSH 端口固定为 `53651/tcp`；
- 脚本不会等待或执行第二终端登录确认；
- 云安全组仍需提前允许目标 SSH 端口及所选业务端口。

## 启动体检与安装模式

直接运行后，脚本首先执行完全只读的环境体检。在选择安装模式前，不执行 APT、不创建临时文件，也不修改系统配置。体检涵盖 Debian/架构/root/systemd、SSH、CPU/内存/磁盘、地址与路由、监听端口、DNS、IPv4/IPv6、APT/dpkg、时间、UFW、BBR、sing-box、SmartDNS 和虚拟化。

存在阻断问题时只能重新体检或退出；通过后显示：

```text
1. 快速安装
2. 自定义安装
3. 退出
```

所有交互均从 `/dev/tty` 读取。无 TTY 时只输出体检结果并明确退出。TTY 输出支持 ANSI 256 色；设置 `NO_COLOR`、重定向输出或无 TTY 时自动禁用颜色。

### 快速安装

除 SSH 公钥外不再逐项询问：

- 执行 `apt-get update` 和当前 Debian 大版本内的 `full-upgrade`；
- 安装并验证基础工具、chrony 和 BBR；
- SSH 固定为 `53651/tcp`，关闭 22，仅允许 root 公钥登录；
- 开放 `443/tcp`、`443/udp`；
- `8443/tcp` 只允许 Cloudflare 官方 IPv4/IPv6 地址段；
- 安装 sing-box 并保持 `disabled`、`inactive`；
- 安装并启动 SmartDNS，使系统 DNS 只使用 `127.0.0.1`；
- 安装 RealityChecker；
- 安装可独立重复运行的 Cloudflare UFW 更新工具。

### 自定义安装

自定义模式先询问是否执行 `full-upgrade`；无论选择什么，都会执行 `apt-get update` 并安装基础工具。之后可以停止并保留基础工具，不继续修改 SSH、UFW、BBR、SmartDNS 或系统 DNS，也不安装后续组件。

继续后可选择新 SSH 端口、是否保留 22、是否开放 `443/tcp` 和 `443/udp`，以及是否启用 Cloudflare-only `8443/tcp`。自定义 SSH 端口必须为 1–65535 的数字，不能是 22、53、80、443、8443，也不能由非 sshd 进程占用。

## SSH 与 UFW 安全门禁

实际安装会在覆盖配置前备份到：

```text
/var/backups/404notfound-bootstrap/<UTC时间>-<进程号>/
```

SSH 流程保留以下门禁：

1. 验证并幂等写入 `/root/.ssh/authorized_keys`；
2. 备份 SSH 主配置与 drop-in；
3. 写入 `/etc/ssh/sshd_config.d/00-hardening.conf`；
4. 处理会覆盖受管策略的全局冲突项；
5. 执行 `sshd -t` 和 `sshd -T`；
6. 只执行 `systemctl reload ssh.service`；
7. 验证新端口以及可选的 22 实际监听；
8. 失败时恢复本轮 SSH 配置，不进入最终 UFW。

UFW 只在 SSH 门禁全部成功后收紧，并按安装模式精确生成和验证规则。

## SmartDNS 与唯一系统 DNS

SmartDNS 模板完整内嵌在 `404notfound.sh`：只监听 `127.0.0.1:53` 的 UDP/TCP，启用持久缓存、serve-expired、prefetch、`tcp:443,ping` 测速和 `first-ping` 响应策略，保留统一上游。

主脚本会先暂存并检查内嵌配置，再备份和幂等写入 `/etc/smartdns/smartdns.conf`。只有 SmartDNS 服务、本地 TCP/UDP 监听和 `dig @127.0.0.1` 全部验证成功后，才备份并替换 `/etc/resolv.conf`。最终只保留 `nameserver 127.0.0.1`；默认解析失败时恢复原文件或软链接。

## Cloudflare 8443 更新工具

主脚本将内嵌工具幂等安装为：

```text
/usr/local/sbin/update-cloudflare-ufw
root:root 0755
```

工具使用 `flock` 防并发，设置下载超时与重试，以 Python `ipaddress` 严格校验 IPv4/IPv6 CIDR，修改前备份 UFW 规则，先加入完整新规则再清理旧规则，并核对 `Cloudflare-8443` 规则数量。它绝不向全网开放 `8443/tcp`。

初始化完成后可独立重复运行：

```bash
/usr/local/sbin/update-cloudflare-ufw
/usr/local/sbin/update-cloudflare-ufw --remove
```

## RealityChecker

默认仓库为 `V2RaySSR/RealityChecker`，使用 GitHub Releases `latest/download`：

- `amd64`：`reality-checker-linux-amd64.zip`
- `arm64`：`reality-checker-linux-arm64.zip`

高级用户可用 `--reality-checker-repo OWNER/REPO` 覆盖仓库，资产文件名保持不变。下载后会验证真实文件名和 ELF 架构，再安装到 `/usr/local/bin/reality-checker`。

## 仓库结构

```text
404notfound/
├── 404notfound.sh
├── request-cloudflare-certificate.sh
├── .github/workflows/shellcheck.yml
├── .gitattributes
├── AGENTS.md
└── README.md
```

`request-cloudflare-certificate.sh` 是独立工具，保持原样，不属于初始化流程。

## CI 与限制

CI 对 `404notfound.sh`、独立证书脚本和从 heredoc 提取出的 Cloudflare 工具执行 Bash 语法检查与 ShellCheck，并检查内嵌 SmartDNS 的关键指令。CI 不执行初始化、APT、VPS 连接或 Cloudflare 更新。

脚本只能验证服务器上的公钥格式、sshd 最终配置和本机监听，不能证明本地私钥、云安全组或外部网络一定可用。
