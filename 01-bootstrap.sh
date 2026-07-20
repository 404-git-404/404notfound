#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly DEFAULT_SSH_PORT='53651'
readonly SSH_MAIN_CONFIG='/etc/ssh/sshd_config'
readonly SSH_DROPIN_DIR='/etc/ssh/sshd_config.d'
readonly SSH_DROPIN="$SSH_DROPIN_DIR/00-vps-bootstrap.conf"
readonly AUTHORIZED_KEYS='/root/.ssh/authorized_keys'
readonly SAGER_KEY_FINGERPRINT='2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C'

SSH_PORT="$DEFAULT_SSH_PORT"
SING_BOX_VERSION=''
PUBKEY_ARGUMENT=''
PUBKEY_FILE=''
PUBLIC_KEY=''
PUBLIC_KEY_TYPE=''
PUBLIC_KEY_BLOB=''
PUBLIC_KEY_FINGERPRINT=''
SKIP_UPGRADE=false
CURRENT_STEP='启动'
TMP_DIR=''
BACKUP_DIR=''
DEBIAN_VERSION=''
CPU_ARCH=''
SSHD_EFFECTIVE=''
SSHD_EFFECTIVE_ROOT=''
SSH_READY=false
LAST_WRITE_CHANGED=false
declare -a SSH_CHANGED_FILES=()

readonly -a BASE_PACKAGES=(
  sudo ca-certificates curl wget git rsync tar unzip xz-utils jq nano gnupg
  openssl socat cron openssh-server ufw dnsutils iproute2 iputils-ping
  netcat-openbsd mtr-tiny traceroute tcpdump procps lsof htop chrony vnstat
)

usage() {
  cat <<'EOF'
用法：
  bash 01-bootstrap.sh [选项]

选项：
  --pubkey "SSH_PUBLIC_KEY"       直接提供一个 OpenSSH 公钥
  --pubkey-file /path/key.pub     从文件读取一个 OpenSSH 公钥（优先级更高）
  --ssh-port PORT                 SSH 端口，默认 53651；不能为 22
  --sing-box-version VERSION      安装官方 APT 仓库中的指定 sing-box 版本
  --skip-upgrade                  只执行 apt-get update，跳过 full-upgrade
  --help                          显示帮助

如果没有提供公钥且 /dev/tty 可交互，脚本会提示粘贴公钥。
EOF
}

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  printf '[%s] [INFO] %s\n' "$(timestamp)" "$*"
}

warn() {
  printf '[%s] [WARN] %s\n' "$(timestamp)" "$*" >&2
}

die() {
  printf '[%s] [ERROR] 步骤“%s”失败：%s\n' "$(timestamp)" "$CURRENT_STEP" "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_number=$1
  trap - ERR
  printf '[%s] [ERROR] 步骤“%s”在第 %s 行失败（退出码 %s）。\n' \
    "$(timestamp)" "$CURRENT_STEP" "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

cleanup() {
  local exit_code=$?
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT
trap 'warn "收到中断信号，停止执行。"; exit 130' INT TERM

require_option_value() {
  local option=$1
  local count=$2
  (( count >= 2 )) || die "$option 缺少参数。"
}

parse_args() {
  CURRENT_STEP='解析参数'

  while (( $# > 0 )); do
    case "$1" in
      --pubkey)
        require_option_value "$1" "$#"
        PUBKEY_ARGUMENT=$2
        shift 2
        ;;
      --pubkey-file)
        require_option_value "$1" "$#"
        PUBKEY_FILE=$2
        shift 2
        ;;
      --ssh-port)
        require_option_value "$1" "$#"
        SSH_PORT=$2
        shift 2
        ;;
      --sing-box-version)
        require_option_value "$1" "$#"
        SING_BOX_VERSION=${2#v}
        shift 2
        ;;
      --skip-upgrade)
        SKIP_UPGRADE=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1。使用 --help 查看帮助。"
        ;;
    esac
  done

  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die 'SSH 端口必须是数字。'
  (( ${#SSH_PORT} <= 5 )) || die 'SSH 端口长度无效。'
  (( 10#$SSH_PORT >= 1 && 10#$SSH_PORT <= 65535 )) ||
    die 'SSH 端口必须在 1 到 65535 之间。'
  (( 10#$SSH_PORT != 22 )) || die '为满足安全目标，--ssh-port 不能设置为 22。'
  if [[ -n "$SING_BOX_VERSION" ]]; then
    [[ "$SING_BOX_VERSION" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
      die 'sing-box 版本包含不允许的字符。'
  fi
}

preflight() {
  CURRENT_STEP='运行环境预检'
  (( EUID == 0 )) || die '必须以 root 身份运行。'
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == 'debian' ]] || die '仅支持 Debian。'
  case "${VERSION_ID:-}" in
    12|13) DEBIAN_VERSION=$VERSION_ID ;;
    *) die "仅支持 Debian 12 或 Debian 13，当前 VERSION_ID=${VERSION_ID:-未知}。" ;;
  esac

  command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg。'
  CPU_ARCH=$(dpkg --print-architecture)
  case "$CPU_ARCH" in
    amd64|arm64) ;;
    *) die "仅支持 amd64 或 arm64，当前架构为 $CPU_ARCH。" ;;
  esac

  [[ -d /run/systemd/system ]] || die '此脚本要求 systemd 正在运行。'
  command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl。'
  command -v apt-get >/dev/null 2>&1 || die '缺少 apt-get。'
  command -v mktemp >/dev/null 2>&1 || die '缺少 mktemp。'
  command -v base64 >/dev/null 2>&1 || die '缺少 base64。'

  TMP_DIR=$(mktemp -d -t 404notfound-bootstrap.XXXXXXXX)
  BACKUP_DIR="/var/backups/404notfound-bootstrap/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  log "环境预检通过：Debian $DEBIAN_VERSION，$CPU_ARCH。"
}

collect_public_key() {
  CURRENT_STEP='取得 SSH 公钥'
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -f "$PUBKEY_FILE" && -r "$PUBKEY_FILE" ]] ||
      die '无法读取 --pubkey-file 指定的文件。'
    PUBLIC_KEY=$(<"$PUBKEY_FILE")
    log '已从 --pubkey-file 读取公钥（内容不会写入日志）。'
  elif [[ -n "$PUBKEY_ARGUMENT" ]]; then
    PUBLIC_KEY=$PUBKEY_ARGUMENT
    log '已从 --pubkey 取得公钥（内容不会写入日志）。'
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '请粘贴一个 OpenSSH 公钥并按回车（输入不会回显到日志）： ' >/dev/tty
    if ! IFS= read -r PUBLIC_KEY </dev/tty; then
      die '无法从 /dev/tty 读取公钥。'
    fi
  else
    die '未提供公钥，且没有可交互的 /dev/tty；尚未修改 SSH。'
  fi

  PUBLIC_KEY=${PUBLIC_KEY%$'\r'}
  [[ -n "$PUBLIC_KEY" ]] || die '公钥不能为空。'
  [[ "$PUBLIC_KEY" != *$'\n'* && "$PUBLIC_KEY" != *$'\r'* ]] ||
    die '一次只能提供一行 OpenSSH 公钥。'

  IFS=$' \t' read -r PUBLIC_KEY_TYPE PUBLIC_KEY_BLOB _ <<<"$PUBLIC_KEY"
  case "$PUBLIC_KEY_TYPE" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com) ;;
    *) die '不支持或无法识别该 OpenSSH 公钥类型。' ;;
  esac
  [[ -n "$PUBLIC_KEY_BLOB" ]] || die '公钥数据缺失。'
  printf '%s' "$PUBLIC_KEY_BLOB" | base64 --decode >/dev/null 2>&1 ||
    die '公钥的 Base64 数据无效。'
}

apt_lock_is_held() {
  local locks
  local lock_path
  command -v lslocks >/dev/null 2>&1 || return 1
  locks=$(lslocks --noheadings --raw --output PATH 2>/dev/null || true)
  for lock_path in \
    /var/lib/dpkg/lock \
    /var/lib/dpkg/lock-frontend \
    /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock; do
    if grep -Fqx -- "$lock_path" <<<"$locks"; then
      return 0
    fi
  done
  return 1
}

wait_for_apt_locks() {
  local deadline=$((SECONDS + 300))
  local announced=false
  if ! command -v lslocks >/dev/null 2>&1; then
    warn 'lslocks 不可用；将依赖 apt/dpkg 自身的 300 秒锁等待机制。'
    return 0
  fi
  while apt_lock_is_held; do
    if [[ "$announced" == false ]]; then
      log '检测到 apt/dpkg 锁，最多等待 300 秒；不会删除锁文件。'
      announced=true
    fi
    (( SECONDS < deadline )) || die '等待 apt/dpkg 锁超时。'
    sleep 2
  done
}

apt_get() {
  wait_for_apt_locks
  apt-get -o DPkg::Lock::Timeout=300 "$@"
}

update_system() {
  CURRENT_STEP='更新系统'
  log '刷新 APT 软件包索引。'
  apt_get update
  if [[ "$SKIP_UPGRADE" == true ]]; then
    log '已通过 --skip-upgrade 跳过 full-upgrade。'
  else
    log '执行非交互式 full-upgrade；不会自动重启。'
    apt_get full-upgrade -y
  fi
}

install_base_packages() {
  CURRENT_STEP='安装基础软件包'
  log '安装基础工具、OpenSSH、UFW、chrony 和 vnStat。'
  apt_get install -y "${BASE_PACKAGES[@]}"

  local -a required_commands=(
    sudo curl wget git rsync tar unzip xz jq nano gpg openssl socat cron
    crontab ssh sshd ssh-keygen ufw dig ip ss ping nc mtr traceroute
    tcpdump ps lsof htop chronyd chronyc vnstat
  )
  local command_name
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "安装后仍找不到关键命令：$command_name。"
  done
  log '基础软件包及关键命令验证通过。'
}

validate_public_key() {
  CURRENT_STEP='验证 SSH 公钥'
  local key_file
  key_file=$(mktemp "$TMP_DIR/public-key.XXXXXXXX")
  printf '%s\n' "$PUBLIC_KEY" >"$key_file"
  ssh-keygen -l -f "$key_file" >/dev/null 2>&1 ||
    die 'ssh-keygen 无法验证该 OpenSSH 公钥。'
  PUBLIC_KEY_FINGERPRINT=$(
    ssh-keygen -l -f "$key_file" | awk 'NR == 1 { print $2 }'
  )
  [[ -n "$PUBLIC_KEY_FINGERPRINT" ]] || die '无法取得公钥指纹。'
  log 'OpenSSH 公钥验证通过（公钥和指纹均未写入日志）。'
}

backup_file() {
  local source_path=$1
  local backup_path="$BACKUP_DIR$source_path"
  local absent_marker="$backup_path.absent"
  if [[ -e "$backup_path" || -e "$absent_marker" ]]; then
    return 0
  fi
  mkdir -p -- "$(dirname "$backup_path")"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$backup_path"
  else
    : >"$absent_marker"
  fi
}

restore_file() {
  local target_path=$1
  local backup_path="$BACKUP_DIR$target_path"
  if [[ -e "$backup_path.absent" ]]; then
    rm -f -- "$target_path"
  elif [[ -e "$backup_path" || -L "$backup_path" ]]; then
    mkdir -p -- "$(dirname "$target_path")"
    cp -a -- "$backup_path" "$target_path"
  else
    warn "找不到 $target_path 的本轮备份，无法自动恢复。"
    return 1
  fi
}

write_managed_file() {
  local target_path=$1
  local mode=$2
  local owner=$3
  local group=$4
  local staged_file
  [[ ! -L "$target_path" ]] || die "$target_path 是符号链接，拒绝覆盖。"
  LAST_WRITE_CHANGED=false
  staged_file=$(mktemp "$TMP_DIR/managed.XXXXXXXX")
  cat >"$staged_file"
  if [[ -f "$target_path" ]] && cmp -s -- "$staged_file" "$target_path"; then
    backup_file "$target_path"
    chmod "$mode" "$target_path"
    chown "$owner:$group" "$target_path"
    return 0
  fi
  backup_file "$target_path"
  install -D -o "$owner" -g "$group" -m "$mode" "$staged_file" "$target_path"
  LAST_WRITE_CHANGED=true
}

configure_chrony() {
  CURRENT_STEP='配置时间同步'
  systemctl enable --now chrony.service
  log 'timedatectl 状态：'
  timedatectl status || warn 'timedatectl 暂时无法返回完整状态。'
  log 'chrony 跟踪状态：'
  chronyc tracking || warn 'chrony 首次同步可能尚未完成。'
  log 'chrony 时间源：'
  chronyc sources || warn 'chrony 暂时没有可用时间源。'
  systemctl is-active --quiet chrony.service ||
    die 'chrony 服务未处于 active 状态。'
}

install_authorized_key() {
  CURRENT_STEP='安装 root SSH 公钥'
  local existing_fingerprints
  [[ ! -L /root/.ssh && ! -L "$AUTHORIZED_KEYS" ]] ||
    die '拒绝通过符号链接写入 root SSH 密钥目录或 authorized_keys。'
  install -d -o root -g root -m 0700 /root/.ssh
  backup_file "$AUTHORIZED_KEYS"
  touch "$AUTHORIZED_KEYS"
  chown root:root "$AUTHORIZED_KEYS"
  chmod 0600 "$AUTHORIZED_KEYS"

  existing_fingerprints=$(
    ssh-keygen -l -f "$AUTHORIZED_KEYS" 2>/dev/null |
      awk '{ print $2 }' || true
  )
  if grep -Fqx -- "$PUBLIC_KEY_FINGERPRINT" <<<"$existing_fingerprints"; then
    log 'authorized_keys 已包含相同公钥，未重复追加。'
  else
    printf '%s\n' "$PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
    log '公钥已添加到 /root/.ssh/authorized_keys（内容未写入日志）。'
  fi

  chown root:root /root/.ssh "$AUTHORIZED_KEYS"
  chmod 0700 /root/.ssh
  chmod 0600 "$AUTHORIZED_KEYS"
  ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1 ||
    die 'authorized_keys 中没有可由 ssh-keygen 识别的有效公钥。'
}

record_ssh_change() {
  local path=$1
  local existing
  for existing in "${SSH_CHANGED_FILES[@]}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  SSH_CHANGED_FILES+=("$path")
}

neutralize_ssh_conflicts() {
  local config_file=$1
  local staged_file
  [[ -f "$config_file" ]] || return 0
  if [[ -L "$config_file" ]]; then
    warn "跳过符号链接 SSH 配置：$config_file；最终 sshd -T 将检查其影响。"
    return 0
  fi

  staged_file=$(mktemp "$TMP_DIR/ssh-conflict.XXXXXXXX")
  awk '
    BEGIN {
      global_scope = 1
      blocked["port"] = 1
      blocked["permitrootlogin"] = 1
      blocked["allowusers"] = 1
      blocked["allowgroups"] = 1
      blocked["denyusers"] = 1
      blocked["denygroups"] = 1
      blocked["pubkeyauthentication"] = 1
      blocked["authenticationmethods"] = 1
      blocked["passwordauthentication"] = 1
      blocked["kbdinteractiveauthentication"] = 1
      blocked["challengeresponseauthentication"] = 1
      blocked["permitemptypasswords"] = 1
      blocked["usepam"] = 1
    }
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)
      split(trimmed, fields, /[[:space:]]+/)
      keyword = tolower(fields[1])
      if (keyword == "match") {
        global_scope = 0
      }
      if (global_scope && blocked[keyword]) {
        print "# Disabled by 404notfound bootstrap: " $0
        next
      }
      print
    }
  ' "$config_file" >"$staged_file"

  if ! cmp -s -- "$config_file" "$staged_file"; then
    backup_file "$config_file"
    install -o root -g root -m 0644 "$staged_file" "$config_file"
    record_ssh_change "$config_file"
  fi
}

ensure_bootstrap_include_first() {
  local cleaned_file
  local staged_file
  [[ -f "$SSH_MAIN_CONFIG" && ! -L "$SSH_MAIN_CONFIG" ]] ||
    die "$SSH_MAIN_CONFIG 必须是普通文件。"

  cleaned_file=$(mktemp "$TMP_DIR/sshd-main-clean.XXXXXXXX")
  staged_file=$(mktemp "$TMP_DIR/sshd-main-stage.XXXXXXXX")
  awk '
    $0 == "# BEGIN 404NOTFOUND BOOTSTRAP INCLUDE" { skipping = 1; next }
    $0 == "# END 404NOTFOUND BOOTSTRAP INCLUDE" {
      skipping = 0
      after_managed_block = 1
      next
    }
    skipping { next }
    after_managed_block && $0 == "" { next }
    {
      after_managed_block = 0
      print
    }
  ' "$SSH_MAIN_CONFIG" >"$cleaned_file"

  {
    printf '%s\n' \
      '# BEGIN 404NOTFOUND BOOTSTRAP INCLUDE' \
      'Include /etc/ssh/sshd_config.d/00-vps-bootstrap.conf' \
      '# END 404NOTFOUND BOOTSTRAP INCLUDE' \
      ''
    cat "$cleaned_file"
  } >"$staged_file"

  if ! cmp -s -- "$SSH_MAIN_CONFIG" "$staged_file"; then
    backup_file "$SSH_MAIN_CONFIG"
    install -o root -g root -m 0644 "$staged_file" "$SSH_MAIN_CONFIG"
    record_ssh_change "$SSH_MAIN_CONFIG"
  fi
}

write_ssh_dropin() {
  [[ ! -L "$SSH_DROPIN" ]] || die "$SSH_DROPIN 不能是符号链接。"
  write_managed_file "$SSH_DROPIN" 0644 root root <<EOF
# Managed by 404notfound/01-bootstrap.sh.
# Proxy application configuration intentionally does not belong here.
Port $SSH_PORT
PermitRootLogin prohibit-password
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
EOF
  if [[ "$LAST_WRITE_CHANGED" == true ]]; then
    record_ssh_change "$SSH_DROPIN"
  fi
}

prepare_ssh_configuration() {
  local config_file
  local -a dropin_files=()
  mkdir -p "$SSH_DROPIN_DIR"
  write_ssh_dropin
  ensure_bootstrap_include_first
  neutralize_ssh_conflicts "$SSH_MAIN_CONFIG"

  shopt -s nullglob
  dropin_files=("$SSH_DROPIN_DIR"/*.conf)
  shopt -u nullglob
  for config_file in "${dropin_files[@]}"; do
    [[ "$config_file" == "$SSH_DROPIN" ]] && continue
    neutralize_ssh_conflicts "$config_file"
  done
}

sshd_value_is() {
  local config=$1
  local key=$2
  local expected=$3
  awk -v key="$key" -v expected="$expected" \
    '$1 == key && $2 == expected { found = 1 } END { exit !found }' <<<"$config"
}

validate_effective_sshd_config() {
  local port
  local port_count=0
  SSHD_EFFECTIVE=$(sshd -T)
  SSHD_EFFECTIVE_ROOT=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1)

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    ((port_count += 1))
    [[ "$port" == "$SSH_PORT" ]] || return 1
  done < <(awk '$1 == "port" { print $2 }' <<<"$SSHD_EFFECTIVE")
  (( port_count > 0 )) || return 1

  if ! sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitrootlogin prohibit-password &&
    ! sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitrootlogin without-password; then
    return 1
  fi
  awk '$1 == "allowusers" && NF == 2 && $2 == "root" { found = 1 }
    END { exit !found }' <<<"$SSHD_EFFECTIVE_ROOT" || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" pubkeyauthentication yes || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" authenticationmethods publickey || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" passwordauthentication no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" kbdinteractiveauthentication no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitemptypasswords no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" usepam yes || return 1
}

rollback_ssh_configuration() {
  local index
  warn '正在恢复本轮修改过的 SSH 配置文件；当前 SSH 会话不会被主动断开。'
  set +e
  for (( index=${#SSH_CHANGED_FILES[@]} - 1; index >= 0; index-- )); do
    restore_file "${SSH_CHANGED_FILES[$index]}"
  done
  if sshd -t >/dev/null 2>&1 && systemctl is-active --quiet ssh.service; then
    systemctl reload ssh.service
  else
    warn '旧 SSH 配置未能自动 reload；当前已有 sshd 进程和会话保持不动。'
  fi
  set -e
}

is_tcp_port_listening() {
  local port=$1
  [[ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null)" ]]
}

ufw_is_active() {
  local status_output
  status_output=$(ufw status 2>/dev/null || true)
  grep -q '^Status: active$' <<<"$status_output"
}

ufw_allows_port() {
  local port_protocol=$1
  local status_output
  status_output=$(ufw status 2>/dev/null || true)
  awk -v target="$port_protocol" \
    '$1 == target && toupper($2) == "ALLOW" { found = 1 } END { exit !found }' \
    <<<"$status_output"
}

backup_ufw_configuration() {
  local path
  for path in \
    /etc/default/ufw \
    /etc/ufw/ufw.conf \
    /etc/ufw/user.rules \
    /etc/ufw/user6.rules; do
    backup_file "$path"
  done
}

preauthorize_active_ufw() {
  if ufw_is_active && ! ufw_allows_port "$SSH_PORT/tcp"; then
    backup_ufw_configuration
    log "UFW 原本已启用；先保留现有规则并预放行 $SSH_PORT/tcp。"
    ufw allow "$SSH_PORT/tcp"
  fi
}

configure_ssh() {
  CURRENT_STEP='配置并验证 SSH'
  systemctl is-active --quiet ssh.service ||
    die 'ssh.service 当前未运行；为避免锁死，脚本不会尝试替换现有连接方式。'
  if systemctl is-active --quiet ssh.socket; then
    die '检测到 ssh.socket 套接字激活；第一版不会自动转换它，以免锁死。请先改用 ssh.service。'
  fi

  prepare_ssh_configuration
  if ! sshd -t; then
    rollback_ssh_configuration
    die 'sshd -t 失败，已尝试恢复本轮 SSH 配置。'
  fi
  if ! validate_effective_sshd_config; then
    rollback_ssh_configuration
    die 'sshd -T 的最终端口或认证策略不符合目标，已尝试恢复。'
  fi
  ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1 || {
    rollback_ssh_configuration
    die 'authorized_keys 最终验证失败，未 reload SSH。'
  }

  preauthorize_active_ufw
  if ! systemctl reload ssh.service; then
    rollback_ssh_configuration
    die 'reload ssh.service 失败，已尝试恢复旧配置。'
  fi

  local attempt
  for attempt in {1..10}; do
    is_tcp_port_listening "$SSH_PORT" && break
    sleep 1
  done
  if ! is_tcp_port_listening "$SSH_PORT"; then
    rollback_ssh_configuration
    die "$SSH_PORT/tcp 未开始监听；未启用或收紧 UFW。"
  fi
  if is_tcp_port_listening 22; then
    rollback_ssh_configuration
    die '22/tcp 仍在监听；未启用或收紧 UFW。'
  fi
  if ! validate_effective_sshd_config; then
    rollback_ssh_configuration
    die 'reload 后 sshd 最终策略验证失败；未启用或收紧 UFW。'
  fi

  SSH_READY=true
  log "SSH 已通过 sshd -t、sshd -T 和监听检查：仅目标端口 $SSH_PORT/tcp。"
}

ensure_ufw_ipv6() {
  local target='/etc/default/ufw'
  local staged_file
  [[ -f "$target" && ! -L "$target" ]] || die "$target 必须是普通文件。"
  staged_file=$(mktemp "$TMP_DIR/ufw-default.XXXXXXXX")
  awk '
    BEGIN { replaced = 0 }
    /^IPV6=/ {
      print "IPV6=yes"
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "IPV6=yes"
      }
    }
  ' "$target" >"$staged_file"
  if ! cmp -s -- "$target" "$staged_file"; then
    backup_file "$target"
    install -o root -g root -m 0644 "$staged_file" "$target"
  fi
}

find_forbidden_ufw_allow_rule() {
  local status_output
  status_output=$(ufw status numbered 2>/dev/null || true)
  awk '
    {
      lower = tolower($0)
      if (lower !~ /allow/) {
        next
      }
      if (lower ~ /(^|[[:space:]])22(\/tcp)?([[:space:]]|$)/ ||
          lower ~ /(^|[[:space:]])8443(\/tcp)?([[:space:]]|$)/ ||
          lower ~ /openssh/) {
        number = $0
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*$/, "", number)
        print number
        exit
      }
    }
  ' <<<"$status_output"
}

remove_forbidden_ufw_allows() {
  local rule_number
  local count=0
  while rule_number=$(find_forbidden_ufw_allow_rule) && [[ -n "$rule_number" ]]; do
    ((count += 1))
    (( count <= 50 )) || die '清理 UFW 冲突规则超过安全上限。'
    ufw --force delete "$rule_number"
  done
}

verify_ufw() {
  ufw_is_active || return 1
  ufw_allows_port "$SSH_PORT/tcp" || return 1
  ufw_allows_port '443/tcp' || return 1
  ufw_allows_port '443/udp' || return 1
  [[ -z "$(find_forbidden_ufw_allow_rule)" ]] || return 1
}

configure_ufw() {
  CURRENT_STEP='配置 UFW'
  [[ "$SSH_READY" == true ]] || die 'SSH 安全门禁未通过，拒绝配置 UFW。'
  backup_ufw_configuration
  ensure_ufw_ipv6

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT/tcp"
  ufw allow 443/tcp
  ufw allow 443/udp
  remove_forbidden_ufw_allows
  ufw --force enable

  verify_ufw || die 'UFW 最终规则验证失败；请保持当前 SSH 会话并人工检查。'
  ufw status verbose
  log 'UFW 已启用，IPv6 保持开启；22/OpenSSH/8443 不存在允许规则。'
}

read_sysctl() {
  local key=$1
  sysctl -n "$key" 2>/dev/null || printf '不可用'
}

configure_bbr() {
  CURRENT_STEP='配置 BBR'
  local available_before
  local available_after
  local current_control
  local current_qdisc

  log "当前内核：$(uname -r)"
  available_before=$(read_sysctl net.ipv4.tcp_available_congestion_control)
  current_control=$(read_sysctl net.ipv4.tcp_congestion_control)
  current_qdisc=$(read_sysctl net.core.default_qdisc)
  log "配置前可用拥塞算法：$available_before"
  log "配置前当前拥塞算法：$current_control；默认 qdisc：$current_qdisc"

  if command -v modinfo >/dev/null 2>&1; then
    if modinfo tcp_bbr >/dev/null 2>&1; then
      log '内核提供 tcp_bbr 模块。'
    else
      warn 'modinfo 未找到 tcp_bbr；将尝试 modprobe 并以 sysctl 结果为准。'
    fi
  fi

  if [[ " $available_before " != *' bbr '* ]]; then
    if ! command -v modprobe >/dev/null 2>&1 || ! modprobe tcp_bbr; then
      warn '当前云厂商内核无法加载 tcp_bbr；不会宣称 BBR 已启用。'
      return 0
    fi
  fi

  available_after=$(read_sysctl net.ipv4.tcp_available_congestion_control)
  if [[ " $available_after " != *' bbr '* ]]; then
    warn "加载后可用拥塞算法仍不包含 bbr：$available_after"
    return 0
  fi

  write_managed_file /etc/modules-load.d/bbr.conf 0644 root root <<'EOF'
tcp_bbr
EOF
  write_managed_file /etc/sysctl.d/99-bbr.conf 0644 root root <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  if ! sysctl --system; then
    warn 'sysctl --system 返回失败；将报告实际内核状态并继续。'
  fi
  sysctl net.ipv4.tcp_available_congestion_control || true
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true

  current_control=$(read_sysctl net.ipv4.tcp_congestion_control)
  current_qdisc=$(read_sysctl net.core.default_qdisc)
  if [[ "$current_control" == 'bbr' && "$current_qdisc" == 'fq' ]]; then
    log 'BBR 已验证启用，默认 qdisc 为 fq。'
  else
    warn "BBR 未达到目标状态：拥塞算法=$current_control，qdisc=$current_qdisc。"
  fi
}

configure_sagernet_repository() {
  local downloaded_key
  local fingerprints
  downloaded_key=$(mktemp "$TMP_DIR/sagernet-key.XXXXXXXX")
  curl --fail --silent --show-error --location \
    https://sing-box.app/gpg.key --output "$downloaded_key"
  [[ -s "$downloaded_key" ]] || die '下载的 SagerNet 签名密钥为空。'

  fingerprints=$(gpg --batch --with-colons --show-keys "$downloaded_key" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }')
  grep -Fqx "$SAGER_KEY_FINGERPRINT" <<<"$fingerprints" ||
    die 'SagerNet 签名密钥指纹不符合脚本内置值。'

  [[ ! -L /etc/apt/keyrings/sagernet.asc ]] ||
    die 'SagerNet APT 密钥路径不能是符号链接。'
  backup_file /etc/apt/keyrings/sagernet.asc
  install -D -o root -g root -m 0644 \
    "$downloaded_key" /etc/apt/keyrings/sagernet.asc
  write_managed_file /etc/apt/sources.list.d/sagernet.sources 0644 root root <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
}

sing_box_version_text() {
  local output
  output=$(sing-box version 2>&1 || true)
  printf '%s' "${output%%$'\n'*}"
}

install_sing_box() {
  CURRENT_STEP='安装 sing-box'
  configure_sagernet_repository
  apt_get update

  if [[ -n "$SING_BOX_VERSION" ]]; then
    if ! apt-cache madison sing-box | awk '{ print $3 }' |
      grep -Fqx -- "$SING_BOX_VERSION"; then
      die "官方 APT 仓库中找不到 sing-box 版本 $SING_BOX_VERSION。"
    fi
    apt_get install -y --allow-downgrades "sing-box=$SING_BOX_VERSION"
  else
    apt_get install -y sing-box
  fi

  command -v sing-box >/dev/null 2>&1 || die '安装后找不到 sing-box。'
  [[ -n "$(sing_box_version_text)" ]] || die 'sing-box version 验证失败。'
  install -d -o root -g root -m 0755 /etc/sing-box
  systemctl disable --now sing-box.service
  if systemctl is-active --quiet sing-box.service; then
    die 'sing-box 服务仍在运行。'
  fi
  log "sing-box 已安装但未运行：$(sing_box_version_text)"
}

smartdns_version_text() {
  local output
  output=$(smartdns -V 2>&1 || true)
  if [[ -z "$output" ]]; then
    output=$(smartdns --version 2>&1 || true)
  fi
  printf '%s' "${output%%$'\n'*}"
}

install_smartdns() {
  CURRENT_STEP='安装 SmartDNS'
  apt_get install -y smartdns
  command -v smartdns >/dev/null 2>&1 || die '安装后找不到 smartdns。'
  [[ -n "$(smartdns_version_text)" ]] || die 'SmartDNS 版本验证失败。'
  install -d -o root -g root -m 0755 /etc/smartdns
  systemctl disable --now smartdns.service
  if systemctl is-active --quiet smartdns.service; then
    die 'SmartDNS 服务仍在运行。'
  fi
  log "SmartDNS 已安装但未运行：$(smartdns_version_text)"
}

service_state() {
  local unit=$1
  local state
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  printf '%s' "${state:-unknown}"
}

print_final_report() {
  CURRENT_STEP='输出最终报告'
  local reboot_required='否'
  local ssh_listeners
  local system_time
  [[ -e /var/run/reboot-required ]] &&
    reboot_required='是（建议在新 SSH 登录验证后手动重启）'
  system_time=$(date --iso-8601=seconds)
  ssh_listeners=$(ss -H -ltnp 2>/dev/null | awk '/sshd/ { print }' || true)
  [[ -n "$ssh_listeners" ]] || ssh_listeners='未能从 ss 输出识别 sshd 进程'

  printf '\n'
  printf '%s\n' '================ 初始化检查摘要 ================'
  printf '%-24s %s\n' 'Debian 版本:' "$DEBIAN_VERSION"
  printf '%-24s %s\n' 'CPU 架构:' "$CPU_ARCH"
  printf '%-24s %s\n' '当前内核:' "$(uname -r)"
  printf '%-24s %s\n' '系统时间:' "$system_time"
  printf '%-24s %s\n' 'chrony 状态:' "$(service_state chrony.service)"
  printf '%-24s %s\n' 'SSH 最终端口:' "$SSH_PORT/tcp"
  printf '%-24s %s\n' 'SSH 认证策略:' \
    '仅 root + publickey；密码、键盘交互和空密码均禁用'
  printf '%-24s\n%s\n' 'SSH 当前监听:' "$ssh_listeners"
  printf '%-24s %s\n' 'TCP 拥塞算法:' \
    "$(read_sysctl net.ipv4.tcp_congestion_control)"
  printf '%-24s %s\n' '默认 qdisc:' "$(read_sysctl net.core.default_qdisc)"
  printf '%-24s %s\n' 'sing-box 版本:' "$(sing_box_version_text)"
  printf '%-24s %s\n' 'sing-box 服务:' "$(service_state sing-box.service)"
  printf '%-24s %s\n' 'SmartDNS 版本:' "$(smartdns_version_text)"
  printf '%-24s %s\n' 'SmartDNS 服务:' "$(service_state smartdns.service)"
  printf '%-24s %s\n' '需要重启:' "$reboot_required"
  printf '%-24s %s\n' '本轮备份目录:' "$BACKUP_DIR"
  printf '%s\n' 'UFW 状态与规则：'
  ufw status verbose || true
  printf '%s\n' '=================================================='
  printf '%s\n' '代理节点配置尚未部署。'
  printf '%s\n' '请保持当前 SSH 会话，并从另一个终端用新端口和对应私钥验证登录。'
}

main() {
  parse_args "$@"
  preflight
  collect_public_key
  update_system
  install_base_packages
  validate_public_key
  configure_chrony
  install_authorized_key
  configure_ssh
  configure_ufw
  configure_bbr
  install_sing_box
  install_smartdns
  print_final_report
}

main "$@"
