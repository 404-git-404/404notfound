# Project rules

- 项目只面向 Debian 12/13，支持 Debian 默认 Bash 环境。
- 用户入口主脚本固定为 `404notfound.sh`，不得保留旧名称的兼容副本或软链接。
- Shell 脚本必须使用 `set -Eeuo pipefail`。
- 所有系统修改必须可验证、尽量幂等，并在覆盖配置前创建备份。
- SSH 变更首先考虑防止用户被锁在服务器外；UFW 收紧必须晚于 SSH 全部门禁。
- 不得提交密钥、密码、Token、UUID、证书、真实域名、服务器 IP 或节点参数。
- 第一阶段允许安装但不启动 sing-box，安装、配置并启动 SmartDNS，安装 RealityChecker，以及安装 Cloudflare 8443 UFW 更新工具。
- 第一阶段不得写入 sing-box 业务 JSON，不得创建 Reality、Hysteria2 或其他代理节点，不得申请或部署证书，不得配置 Cloudflare Tunnel 或 CF-WS，也不得写入节点 UUID、密码、私钥、Token、真实域名或服务器信息。
- 修改 Shell 脚本后必须运行 `bash -n` 和 ShellCheck。
- README 必须与脚本实际行为保持一致。
- 不得无理由增加依赖，也不要过早拆分大量文件。
