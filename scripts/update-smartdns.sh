#!/usr/bin/env bash

if (return 0 2>/dev/null); then
  printf '[FAIL] 请执行此脚本，不要 source。\n' >&2
  return 1
fi

set -Eeuo pipefail

readonly CONFIG_TARGET='/etc/smartdns/smartdns.conf'
readonly RELEASE_API='https://api.github.com/repos/pymumu/smartdns/releases/latest'
readonly CA_FILE='/etc/ssl/certs/ca-certificates.crt'

TMP_DIR=''
STAGED_CONFIG=''
BACKUP_DIR=''
START_TIME=''
JOURNAL_FILE=''
ARCH=''
ASSET_SUFFIX=''
ASSET_NAME=''
ASSET_VERSION=''
DOWNLOAD_URL=''
DEB_PATH=''
DEB_PACKAGE_VERSION=''
RELEASE_TAG=''
SMARTDNS_VERSION_TEXT=''
SMARTDNS_COMMAND=''
SMARTDNS_BINARY_PATH=''
PACKAGE_VERSION=''
ENABLED_STATUS=''
ACTIVE_STATUS=''
SOCKET_OUTPUT=''
IPV4_ANSWER=''
AAAA_QUERY_OUTPUT=''
CONFIG_PREEXISTED=false

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

shorten_line() {
  local value=${1//$'\n'/ }
  printf '%.300s' "$value"
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

trap cleanup EXIT

require_root_and_debian() {
  local os_id
  local os_version

  ((EUID == 0)) || die '必须以 root 身份执行此脚本。'
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'

  os_id=$(awk -F= '$1 == "ID" { print $2; exit }' /etc/os-release | tr -d '"')
  os_version=$(awk -F= '$1 == "VERSION_ID" { print $2; exit }' /etc/os-release | tr -d '"')
  [[ "$os_id" == 'debian' ]] || die "仅支持 Debian，当前系统 ID：${os_id:-未知}。"
  case "$os_version" in
    12 | 13) ;;
    *) die "仅支持 Debian 12/13，当前版本：${os_version:-未知}。" ;;
  esac
}

install_dependencies() {
  local package
  local -a missing_packages=()
  local -a required_packages=(curl jq ca-certificates dnsutils)

  for package in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null |
      grep -q '^ii'; then
      missing_packages+=("$package")
    fi
  done

  if ((${#missing_packages[@]} > 0)); then
    log "安装缺少的依赖：${missing_packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${missing_packages[@]}"
  else
    log 'curl、jq、ca-certificates 和 dnsutils 已安装。'
  fi

  [[ -r "$CA_FILE" && -s "$CA_FILE" ]] ||
    die "系统 CA 文件不可读或为空：$CA_FILE。"
}

verify_required_commands() {
  local command_name
  local -a required_commands=(
    apt-get awk cat cmp cp curl date dig dpkg dpkg-deb dpkg-query grep
    install journalctl jq mktemp readlink rm sleep ss stat systemctl tr
  )

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "缺少必要命令：$command_name。"
  done
}

select_architecture() {
  ARCH=$(dpkg --print-architecture)
  case "$ARCH" in
    amd64) ASSET_SUFFIX='x86_64-debian-all.deb' ;;
    arm64) ASSET_SUFFIX='aarch64-debian-all.deb' ;;
    armhf) ASSET_SUFFIX='arm-debian-all.deb' ;;
    *) die "不支持的 Debian 架构：$ARCH；仅支持 amd64、arm64 和 armhf。" ;;
  esac
  log "Debian 架构：$ARCH；目标资产后缀：$ASSET_SUFFIX"
}

create_temporary_directory() {
  TMP_DIR=$(mktemp -d /tmp/update-smartdns.XXXXXXXX)
  STAGED_CONFIG="$TMP_DIR/smartdns.conf"
  JOURNAL_FILE="$TMP_DIR/smartdns-startup.log"
  DEB_PATH="$TMP_DIR/smartdns.deb"
}

write_embedded_configuration() {
  cat >"$STAGED_CONFIG" <<'SMARTDNS_CONFIG'
bind 127.0.0.1:53
bind-tcp 127.0.0.1:53

cache-persist yes
cache-file /var/cache/smartdns/smartdns.cache
cache-checkpoint-time 86400
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3
serve-expired-prefetch-time 21600
prefetch-domain yes

speed-check-mode tcp:443,ping
response-mode first-ping
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt

server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
server-https https://dns10.quad9.net/dns-query -host-ip 9.9.9.10 -fallback
SMARTDNS_CONFIG

  [[ -s "$STAGED_CONFIG" ]] || die '生成内嵌 SmartDNS 配置失败。'
}

fetch_latest_release() {
  local asset_info
  local release_file="$TMP_DIR/latest-release.json"

  if ! curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
    "$RELEASE_API" -o "$release_file"; then
    die '无法获取 SmartDNS GitHub latest Release 信息。'
  fi

  if ! jq -e '.draft == false and .prerelease == false' "$release_file" >/dev/null; then
    die 'GitHub latest Release 不是稳定版本，拒绝继续。'
  fi
  if ! RELEASE_TAG=$(jq -er '.tag_name | strings | select(length > 0)' "$release_file"); then
    die 'GitHub latest Release 缺少有效标签。'
  fi

  if ! asset_info=$(jq -er --arg suffix "$ASSET_SUFFIX" '
    [.assets[]
      | select((.name | type) == "string")
      | select(.name | endswith($suffix))] as $matches
    | if ($matches | length) == 1 then
        $matches[0]
        | select((.browser_download_url | type) == "string")
        | [.name, .browser_download_url]
        | @tsv
      else
        error("expected exactly one matching Debian package")
      end
  ' "$release_file"); then
    die "Release $RELEASE_TAG 中没有唯一匹配 $ASSET_SUFFIX 的 Debian 软件包。"
  fi

  IFS=$'\t' read -r ASSET_NAME DOWNLOAD_URL <<<"$asset_info"
  [[ "$ASSET_NAME" == smartdns.*."$ASSET_SUFFIX" ]] ||
    die "匹配到的资产名称异常：$ASSET_NAME。"
  [[ "$DOWNLOAD_URL" == 'https://github.com/pymumu/smartdns/releases/download/'* ]] ||
    die '匹配到的下载地址不是 SmartDNS 官方 GitHub Release 地址。'

  ASSET_VERSION=${ASSET_NAME#smartdns.}
  ASSET_VERSION=${ASSET_VERSION%."$ASSET_SUFFIX"}
  [[ -n "$ASSET_VERSION" && "$ASSET_VERSION" != "$ASSET_NAME" ]] ||
    die "无法从资产名称解析版本：$ASSET_NAME。"
  log "GitHub latest Release：$RELEASE_TAG；资产：$ASSET_NAME"
}

download_and_verify_package() {
  local deb_architecture
  local deb_package_name

  if ! curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors --connect-timeout 10 --max-time 300 \
    "$DOWNLOAD_URL" -o "$DEB_PATH"; then
    die "下载 SmartDNS Debian 软件包失败：$ASSET_NAME。"
  fi
  [[ -s "$DEB_PATH" ]] || die '下载的 SmartDNS Debian 软件包为空。'

  deb_package_name=$(dpkg-deb --field "$DEB_PATH" Package)
  deb_architecture=$(dpkg-deb --field "$DEB_PATH" Architecture)
  DEB_PACKAGE_VERSION=$(dpkg-deb --field "$DEB_PATH" Version)

  [[ "$deb_package_name" == 'smartdns' ]] ||
    die "下载的软件包名称不是 smartdns：$deb_package_name。"
  [[ "$deb_architecture" == "$ARCH" || "$deb_architecture" == 'all' ]] ||
    die "下载的软件包架构字段为 $deb_architecture，与目标架构 $ARCH 不兼容。"
  [[ -n "$DEB_PACKAGE_VERSION" ]] || die '下载的软件包缺少版本信息。'
  if [[ "$DEB_PACKAGE_VERSION" != *"$ASSET_VERSION"* &&
    "$ASSET_VERSION" != *"$DEB_PACKAGE_VERSION"* ]]; then
    die "资产版本 $ASSET_VERSION 与 Debian 包版本 $DEB_PACKAGE_VERSION 不对应。"
  fi
  log "Debian 包元数据：Version=$DEB_PACKAGE_VERSION，Architecture=$deb_architecture"
}

create_backup() {
  local timestamp

  timestamp=$(date '+%Y%m%d-%H%M%S')
  BACKUP_DIR="/root/smartdns-backup-$timestamp"
  while [[ -e "$BACKUP_DIR" ]]; do
    sleep 1
    timestamp=$(date '+%Y%m%d-%H%M%S')
    BACKUP_DIR="/root/smartdns-backup-$timestamp"
  done
  install -d -o root -g root -m 0700 "$BACKUP_DIR"

  if [[ -e "$CONFIG_TARGET" || -L "$CONFIG_TARGET" ]]; then
    cp -a -- "$CONFIG_TARGET" "$BACKUP_DIR/smartdns.conf"
    CONFIG_PREEXISTED=true
  else
    printf '配置在升级前不存在。\n' >"$BACKUP_DIR/config-was-absent.txt"
  fi

  if command -v smartdns >/dev/null 2>&1; then
    smartdns -v >"$BACKUP_DIR/smartdns-version-before.txt" 2>&1 || true
  else
    printf 'smartdns command not installed\n' >"$BACKUP_DIR/smartdns-version-before.txt"
  fi
  if ! dpkg-query -W smartdns >"$BACKUP_DIR/dpkg-version-before.txt" 2>&1; then
    printf 'smartdns package not installed\n' >"$BACKUP_DIR/dpkg-version-before.txt"
  fi

  log "升级前状态已备份到：$BACKUP_DIR"
}

install_official_package() {
  log "安装 SmartDNS 官方 Debian 软件包：$ASSET_NAME"
  if ! DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::='--force-confold' install --yes "$DEB_PATH"; then
    die '安装 SmartDNS 官方 Debian 软件包失败；配置尚未部署。'
  fi
  hash -r
}

verify_installed_package() {
  local package_status
  local version_output

  SMARTDNS_COMMAND=$(command -v smartdns) ||
    die '安装后找不到 smartdns 命令。'
  SMARTDNS_BINARY_PATH=$(readlink -f "$SMARTDNS_COMMAND")
  [[ -n "$SMARTDNS_BINARY_PATH" && -x "$SMARTDNS_BINARY_PATH" ]] ||
    die "SmartDNS 实际二进制路径无效：$SMARTDNS_BINARY_PATH。"

  if ! version_output=$(smartdns -v 2>&1); then
    die "smartdns -v 执行失败：$(shorten_line "$version_output")"
  fi
  SMARTDNS_VERSION_TEXT=$(awk 'NF { print; exit }' <<<"$version_output")
  [[ -n "$SMARTDNS_VERSION_TEXT" ]] || die 'smartdns -v 未返回版本信息。'

  package_status=$(dpkg-query -W -f='${db:Status-Abbrev}' smartdns)
  PACKAGE_VERSION=$(dpkg-query -W -f='${Version}' smartdns)
  [[ "$package_status" == ii* ]] ||
    die "SmartDNS Debian 软件包状态异常：$package_status。"
  [[ "$PACKAGE_VERSION" == "$DEB_PACKAGE_VERSION" ]] ||
    die "已安装包版本 $PACKAGE_VERSION 与下载包版本 $DEB_PACKAGE_VERSION 不一致。"
  [[ "$SMARTDNS_VERSION_TEXT" == *"$ASSET_VERSION"* ]] ||
    die "smartdns -v 输出与 Release 资产版本 $ASSET_VERSION 不对应：$SMARTDNS_VERSION_TEXT。"

  log "smartdns -v：$SMARTDNS_VERSION_TEXT"
  log "dpkg-query -W smartdns：smartdns $PACKAGE_VERSION"
  log "command -v smartdns：$SMARTDNS_COMMAND"
  log "SmartDNS 实际二进制：$SMARTDNS_BINARY_PATH"
}

capture_start_journal() {
  [[ -n "$START_TIME" ]] || return 1
  journalctl -u smartdns --since "$START_TIME" --no-pager >"$JOURNAL_FILE" 2>&1
}

restore_configuration() {
  local restore_status=0

  warn '正在恢复升级前的 SmartDNS 配置。'
  if [[ "$CONFIG_PREEXISTED" == true ]]; then
    if [[ -f "$BACKUP_DIR/smartdns.conf" || -L "$BACKUP_DIR/smartdns.conf" ]]; then
      if ! rm -f -- "$CONFIG_TARGET" ||
        ! cp -a -- "$BACKUP_DIR/smartdns.conf" "$CONFIG_TARGET"; then
        restore_status=1
      fi
    else
      warn '备份目录中找不到原 SmartDNS 配置。'
      restore_status=1
    fi
  else
    rm -f -- "$CONFIG_TARGET" || restore_status=1
  fi

  if ! systemctl restart smartdns; then
    warn '恢复配置后 SmartDNS 仍无法重新启动。'
    restore_status=1
  fi
  return "$restore_status"
}

fail_with_recovery() {
  local reason=$1
  local recovery_result='失败'

  capture_start_journal || true
  if restore_configuration; then
    recovery_result='成功'
  fi

  printf '[FAIL] %s\n' "$reason" >&2
  printf '[INFO] 配置恢复：%s；备份目录：%s\n' "$recovery_result" "$BACKUP_DIR" >&2
  if [[ -s "$JOURNAL_FILE" ]]; then
    printf '%s\n' '----- smartdns 本次启动日志 -----' >&2
    cat "$JOURNAL_FILE" >&2
    printf '%s\n' '----- 日志结束 -----' >&2
  else
    warn '没有取得 SmartDNS 本次启动日志。'
  fi
  exit 1
}

deploy_configuration() {
  local cache_mode
  local config_mode
  local config_owner
  local etc_mode

  install -d -m 0755 /etc/smartdns /var/cache/smartdns
  if ! rm -f -- "$CONFIG_TARGET" ||
    ! install -o root -g root -m 0644 "$STAGED_CONFIG" "$CONFIG_TARGET"; then
    fail_with_recovery '部署 /etc/smartdns/smartdns.conf 失败。'
  fi
  cmp -s "$STAGED_CONFIG" "$CONFIG_TARGET" ||
    fail_with_recovery '部署后的 SmartDNS 配置与内嵌模板不一致。'

  if ! etc_mode=$(stat -c '%a' /etc/smartdns) ||
    ! cache_mode=$(stat -c '%a' /var/cache/smartdns) ||
    ! config_mode=$(stat -c '%a' "$CONFIG_TARGET") ||
    ! config_owner=$(stat -c '%U:%G' "$CONFIG_TARGET"); then
    fail_with_recovery '无法验证 SmartDNS 目录或配置权限。'
  fi
  [[ "$etc_mode" == '755' && "$cache_mode" == '755' ]] ||
    fail_with_recovery "SmartDNS 目录权限异常：/etc=$etc_mode，cache=$cache_mode。"
  [[ "$config_mode" == '644' && "$config_owner" == 'root:root' ]] ||
    fail_with_recovery "SmartDNS 配置权限异常：$config_owner $config_mode。"
}

listener_present() {
  local protocol=$1

  awk -v protocol="$protocol" '
    $1 == protocol &&
    $5 ~ /^127\.0\.0\.1(%[^:[:space:]]+)?:53$/ &&
    $0 ~ /users:\(\("smartdns"/ { found = 1 }
    END { exit !found }
  ' <<<"$SOCKET_OUTPUT"
}

valid_ipv4_answer() {
  awk -F. '
    NF == 4 {
      valid = 1
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
          valid = 0
        }
      }
      if (valid) {
        found = 1
      }
    }
    END { exit !found }
  ' <<<"$IPV4_ANSWER"
}

start_and_validate_service() {
  START_TIME=$(date --iso-8601=seconds)

  systemctl daemon-reload ||
    fail_with_recovery 'systemctl daemon-reload 失败。'
  systemctl enable smartdns ||
    fail_with_recovery '无法设置 SmartDNS 开机启动。'
  systemctl restart smartdns ||
    fail_with_recovery '无法启动或重启 SmartDNS。'

  if ! ENABLED_STATUS=$(systemctl is-enabled smartdns); then
    fail_with_recovery '无法取得 SmartDNS 开机启动状态。'
  fi
  if ! ACTIVE_STATUS=$(systemctl is-active smartdns); then
    fail_with_recovery '无法取得 SmartDNS 当前运行状态。'
  fi
  [[ "$ENABLED_STATUS" == 'enabled' ]] ||
    fail_with_recovery "SmartDNS 开机启动状态不是 enabled：$ENABLED_STATUS。"
  [[ "$ACTIVE_STATUS" == 'active' ]] ||
    fail_with_recovery "SmartDNS 当前运行状态不是 active：$ACTIVE_STATUS。"

  if ! capture_start_journal; then
    fail_with_recovery '无法读取 SmartDNS 本次启动日志。'
  fi
  if grep -Eiq \
    'unsupported[[:space:]]+config|failed[[:space:]]+to[[:space:]]+start|configuration[[:space:]]+error|parse[[:space:]]+error|failed[[:space:]]+to[[:space:]]+parse' \
    "$JOURNAL_FILE"; then
    fail_with_recovery 'SmartDNS 本次启动日志包含配置或启动错误。'
  fi

  for _ in {1..10}; do
    SOCKET_OUTPUT=$(ss -H -lntup 'sport = :53' 2>/dev/null || true)
    if listener_present udp && listener_present tcp; then
      break
    fi
    sleep 1
  done
  listener_present udp ||
    fail_with_recovery 'SmartDNS 未在 127.0.0.1:53/udp 监听。'
  listener_present tcp ||
    fail_with_recovery 'SmartDNS 未在 127.0.0.1:53/tcp 监听。'

  if ! IPV4_ANSWER=$(dig @127.0.0.1 cloudflare.com A +short +time=5 +tries=1 2>&1) ||
    ! valid_ipv4_answer; then
    fail_with_recovery "SmartDNS IPv4 查询失败：$(shorten_line "$IPV4_ANSWER")"
  fi
  if ! AAAA_QUERY_OUTPUT=$(dig @127.0.0.1 cloudflare.com AAAA +time=5 +tries=1 2>&1); then
    fail_with_recovery "SmartDNS AAAA 查询执行失败：$(shorten_line "$AAAA_QUERY_OUTPUT")"
  fi
  if ! grep -Eq 'status:[[:space:]]*NOERROR([,[:space:]]|$)' <<<"$AAAA_QUERY_OUTPUT"; then
    fail_with_recovery "SmartDNS AAAA 查询状态不是 NOERROR：$(shorten_line "$AAAA_QUERY_OUTPUT")"
  fi

  log "systemctl is-enabled smartdns：$ENABLED_STATUS"
  log "systemctl is-active smartdns：$ACTIVE_STATUS"
  log '本次启动日志未发现 unsupported config、启动或配置解析错误。'
  log '127.0.0.1:53 的 TCP 和 UDP 监听验证通过。'
  log "IPv4 查询结果：$(shorten_line "$IPV4_ANSWER")"
  log 'AAAA 查询状态：NOERROR（允许 ANSWER 为 0）。'
}

print_summary() {
  printf '\nSmartDNS 更新成功\n'
  printf 'GitHub latest Release：%s\n' "$RELEASE_TAG"
  printf 'SmartDNS 当前版本：%s\n' "$SMARTDNS_VERSION_TEXT"
  printf 'Debian 软件包版本：%s\n' "$PACKAGE_VERSION"
  printf 'SmartDNS 二进制路径：%s\n' "$SMARTDNS_BINARY_PATH"
  printf '配置文件路径：%s\n' "$CONFIG_TARGET"
  printf '开机启动状态：%s\n' "$ENABLED_STATUS"
  printf '当前运行状态：%s\n' "$ACTIVE_STATUS"
  printf 'TCP 53：正常\n'
  printf 'UDP 53：正常\n'
  printf 'IPv4 查询：正常\n'
  printf 'AAAA 查询：NOERROR（允许空答案）\n'
  printf '旧配置备份路径：%s\n' "$BACKUP_DIR"
}

main() {
  require_root_and_debian
  install_dependencies
  verify_required_commands
  select_architecture
  create_temporary_directory
  write_embedded_configuration
  fetch_latest_release
  download_and_verify_package
  create_backup
  install_official_package
  verify_installed_package
  deploy_configuration
  start_and_validate_service
  print_summary
}

main "$@"
