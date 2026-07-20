# 404notfound

面向全新 Debian 12/13 VPS 的第一阶段初始化脚本。它把服务器整理成“可以继续部署代理节点配置”的基础环境，重点是 SSH 防锁死、配置可验证和重复执行尽量幂等。

> [!CAUTION]
> 脚本只能验证服务器上的公钥、sshd 最终配置和本机监听状态，无法从服务器内部证明你本地的私钥一定可用，也无法验证云厂商安全组或外部网络是否放行新端口。首次运行期间必须保持当前 SSH 会话，不要提前断开；完成后先从另一个终端验证新端口登录。

## 阶段边界

第一阶段由 `01-bootstrap.sh` 完成：

- 更新 Debian 并安装基础运维工具；
- 启用并检查 chrony；
- 安装 root 公钥，把 SSH 改到默认 `53651/tcp`；
- 只允许 root 使用公钥认证；
- 配置 UFW，仅放行 SSH、`443/tcp` 和 `443/udp`；
- 尝试启用并验证 BBR；
- 从官方来源安装 sing-box；
- 从 Debian 官方仓库安装 SmartDNS；
- 保持 sing-box 和 SmartDNS 禁用、停止；
- 输出最终检查报告。

第二阶段不在本仓库当前版本中实现。脚本不会生成 sing-box 或 SmartDNS 业务配置，不会部署 Reality、Hysteria2、Cloudflare Tunnel/“小黄车”、证书、socks5/http 出站，也不会开放 `8443`、启动代理业务或自动重启。

## 文件树

```text
404notfound/
├── 01-bootstrap.sh
├── README.md
├── AGENTS.md
├── LICENSE
├── .gitignore
└── .github/
    └── workflows/
        └── shellcheck.yml
```

## 执行流程

```text
参数解析
└── root / Debian 12、13 / amd64、arm64 / systemd 预检
    └── 按优先级取得公钥
        ├── --pubkey-file
        ├── --pubkey
        └── /dev/tty 交互输入
            └── 更新 APT 索引
                ├── 默认：full-upgrade
                └── --skip-upgrade：跳过升级
                    └── 安装并验证基础工具
                        └── ssh-keygen 验证公钥
                            └── 启用并检查 chrony
                                └── 幂等写入 authorized_keys
                                    └── SSH 安全变更
                                        ├── 备份原配置
                                        ├── 优先加载受管 drop-in
                                        ├── 处理全局冲突指令
                                        ├── sshd -t
                                        ├── sshd -T
                                        ├── reload ssh
                                        └── ss 验证新端口监听且 22 停止
                                            └── SSH 安全门禁通过
                                                └── 配置并验证 UFW
                                                    └── 检测、启用并验证 BBR
                                                        └── 官方 APT 安装 sing-box
                                                            ├── 禁用服务
                                                            └── 不创建业务配置
                                                                └── Debian APT 安装 SmartDNS
                                                                    ├── 禁用服务
                                                                    └── 不改写业务配置
                                                                        └── 最终报告
```

若 UFW 在运行脚本前已经启用，脚本会在 reload SSH 之前仅预放行新 SSH 端口，保留旧规则；只有 SSH 配置、认证策略、新端口监听和 22 停止监听全部验证通过后，才会收紧 UFW。

## 支持范围与前提

- Debian 12（bookworm）或 Debian 13（trixie）；
- `amd64` 或 `arm64`；
- 以 root 运行；
- systemd 管理 `ssh.service`；
- VPS 能访问 Debian 镜像、`sing-box.app` 和 `deb.sagernet.org`；
- 云厂商安全组已允许目标 SSH TCP 端口、`443/tcp` 和 `443/udp`。

脚本安全退出而不自动转换 `ssh.socket` 套接字激活环境。先确认 VPS 使用 `ssh.service`，再运行脚本。

## 首次使用

先把脚本和公钥文件传到 VPS，保持现有 SSH 窗口打开。建议先阅读脚本和帮助：

```bash
bash 01-bootstrap.sh --help
```

使用公钥文件：

```bash
bash 01-bootstrap.sh \
  --pubkey-file /root/admin_ed25519.pub
```

直接传入占位公钥：

```bash
bash 01-bootstrap.sh \
  --pubkey 'ssh-ed25519 AAAA... admin'
```

上面的 `AAAA...` 只是文档占位符，不是有效公钥；实际运行必须替换为你自己的完整公钥，且不要把它提交到仓库。

固定 sing-box 版本（必须是官方 APT 仓库当前仍提供的精确版本号）：

```bash
bash 01-bootstrap.sh \
  --pubkey-file /root/admin_ed25519.pub \
  --sing-box-version 1.12.0
```

跳过 `full-upgrade`，但仍刷新 APT 索引：

```bash
bash 01-bootstrap.sh \
  --pubkey-file /root/admin_ed25519.pub \
  --skip-upgrade
```

指定其他 SSH 端口：

```bash
bash 01-bootstrap.sh \
  --pubkey-file /root/admin_ed25519.pub \
  --ssh-port 53651
```

`--pubkey-file` 的优先级高于 `--pubkey`。两者都未提供时，脚本只会在 `/dev/tty` 可交互的情况下提示输入；否则在修改 SSH 前退出。目标端口不能是 22。

## SSH 防锁死设计

脚本执行以下门禁：

1. 用 `ssh-keygen` 验证公钥，并确认 `/root/.ssh/authorized_keys` 中至少存在一个有效公钥；
2. 备份要修改的 SSH 文件；
3. 把受管配置作为 `/etc/ssh/sshd_config` 的首个有效 Include；
4. 备份并注释其他文件中与目标策略冲突的全局指令；
5. 执行 `sshd -t`；
6. 用 `sshd -T` 检查最终端口和 root 的最终认证策略；
7. 只执行 `systemctl reload ssh.service`，不 restart；
8. 用 `ss` 确认目标端口已监听且 22 已停止监听；
9. 全部通过后才启用或收紧 UFW。

任一步失败时，脚本不会继续启用/收紧 UFW，并尝试从本轮备份恢复 SSH 配置后 reload。已有 SSH 会话不会被脚本主动终止。

最终受管策略为：

```text
Port 53651
PermitRootLogin prohibit-password
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
```

脚本没有设置 `AllowTcpForwarding no`，因此不会无故禁用 SSH TCP forwarding。

## 安装来源

- sing-box 使用[官方 Package Manager 文档](https://sing-box.sagernet.org/installation/package-manager/)给出的 SagerNet APT 仓库。下载的仓库签名密钥会与脚本内置指纹核对；
- SmartDNS 使用 Debian 12/13 官方 `smartdns` 软件包；
- 不执行任何第三方一键安装脚本。

未指定 `--sing-box-version` 时，APT 安装官方稳定仓库的当前候选版本。指定版本时使用精确 APT 版本匹配；仓库不再保留该版本会导致脚本明确失败。

## 安装后检查

脚本末尾会打印摘要。不要立即关闭原会话，另开一个终端测试：

```bash
ssh -p 53651 root@SERVER_IP
```

`SERVER_IP` 仅是占位符。确认新连接成功后，再按需执行以下检查：

```bash
sshd -t
sshd -T | grep -E '^(port|permitrootlogin|allowusers|pubkeyauthentication|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|usepam) '
ss -ltnp
ufw status verbose
timedatectl status
chronyc tracking
chronyc sources
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sing-box version
systemctl is-enabled sing-box
systemctl is-active sing-box
smartdns -V
systemctl is-enabled smartdns
systemctl is-active smartdns
```

预期 sing-box 和 SmartDNS 为 `disabled`、`inactive`。本阶段故意不让它们启动。

## 备份、恢复与卸载

每次运行会把本轮首次修改前的文件备份到：

```text
/var/backups/404notfound-bootstrap/<UTC时间>-<进程号>/
```

最终报告会打印确切目录。恢复前先保持一个可用的 root 会话，并核对备份内容。大致步骤是：

1. 从对应备份目录恢复 `/etc/ssh`、`/etc/default/ufw`、`/etc/ufw`、`/etc/sysctl.d/99-bbr.conf` 等文件；
2. 对 SSH 先运行 `sshd -t`，成功后再 `systemctl reload ssh.service`；
3. 根据恢复后的 SSH 监听端口调整云防火墙和 UFW，确认新连接后再退出旧会话；
4. 如需移除程序，可用 APT 卸载 `sing-box`、`smartdns`，并人工确认是否保留 `/etc/sing-box`、`/etc/smartdns`；
5. 删除公钥前必须先保证另一个可用登录方式，避免锁死。

恢复和卸载不会自动执行，因为服务器原有规则、云防火墙和业务配置无法由通用脚本安全推断。

## 敏感信息规则

仓库中不得提交：

- SSH 公钥或私钥；
- 密码、Token、API 密钥；
- UUID；
- 证书或证书私钥；
- 真实域名、服务器 IP；
- sing-box、SmartDNS 或任何代理节点的真实业务参数。

`.gitignore` 只能降低误提交概率，不能替代提交前人工检查。

## 已知限制

- 本项目没有在 Windows 本机执行初始化流程；CI 只做 Bash 语法和 ShellCheck 静态检查；
- 仍需在一次性的 Debian 12/13 测试 VPS 上做端到端验证；
- 无法从服务器内部验证本地私钥、云安全组、NAT 或外部连通性；
- 仅支持由 `ssh.service` 管理的 OpenSSH，不自动迁移 `ssh.socket`；
- 特殊的 `Match` 块、符号链接 SSH drop-in 或非标准服务单元可能导致最终校验安全失败并回滚；
- BBR 取决于云厂商内核；不支持时仅警告，不伪报成功；
- SagerNet 仓库签名密钥轮换后，需要审查官方公告并更新脚本内置指纹；
- UFW 规则检查依赖标准英文输出（脚本固定 `LC_ALL=C`）；
- 第一阶段不包含任何代理节点业务配置。

## CI

`.github/workflows/shellcheck.yml` 在 `push` 和 `pull_request` 时运行：

- `bash -n 01-bootstrap.sh`
- `shellcheck 01-bootstrap.sh`

工作流不需要 GitHub Secret。
