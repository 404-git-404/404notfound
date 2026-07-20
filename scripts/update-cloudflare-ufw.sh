#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export LC_ALL=C

readonly PORT='8443'
readonly COMMENT='Cloudflare-8443'
readonly LOCK_FILE='/run/lock/404notfound-cloudflare-ufw.lock'

TMP_DIR=''
BACKUP_DIR=''

cleanup() {
  local exit_code=$?
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  exit "$exit_code"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT
trap 'printf "[ERROR] Cloudflare UFW 更新在第 %s 行失败。\n" "$LINENO" >&2' ERR
trap 'printf "[WARN] 收到中断信号，停止更新。\n" >&2; exit 130' INT TERM

(( EUID == 0 )) || die '必须以 root 身份运行。'
command -v curl >/dev/null 2>&1 || die '缺少 curl。'
command -v flock >/dev/null 2>&1 || die '缺少 flock。'
command -v python3 >/dev/null 2>&1 || die '缺少 python3，无法严格校验 CIDR。'
command -v ufw >/dev/null 2>&1 || die '缺少 ufw。'

mkdir -p -- "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || die '已有另一个 Cloudflare UFW 更新正在运行。'

TMP_DIR=$(mktemp -d -t cloudflare-ufw.XXXXXXXX)

ufw status | grep -q '^Status: active$' ||
  die 'UFW 必须处于 active 状态，才能可靠更新并核对 Cloudflare 规则。'

BACKUP_DIR="/var/backups/404notfound-cloudflare-ufw/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
install -d -o root -g root -m 0700 "$BACKUP_DIR/etc/ufw"
for ufw_file in /etc/ufw/user.rules /etc/ufw/user6.rules; do
  if [[ -e "$ufw_file" ]]; then
    cp -a -- "$ufw_file" "$BACKUP_DIR$ufw_file"
  fi
done

ufw_ipv6_enabled() {
  [[ -r /etc/default/ufw ]] && grep -Eq '^IPV6=yes([[:space:]]*)$' /etc/default/ufw
}

download_cidr_list() {
  local url=$1
  local destination=$2
  curl --fail --silent --show-error --location \
    --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 1 \
    "$url" --output "$destination"
  [[ -s "$destination" ]] || die "下载结果为空：$url"
}

validate_cidr_file() {
  local family=$1
  local path=$2
  python3 - "$family" "$path" <<'PY'
import ipaddress
import pathlib
import sys

family = int(sys.argv[1])
path = pathlib.Path(sys.argv[2])
lines = [line.strip() for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
if not lines:
    raise SystemExit("CIDR list is empty")
for line in lines:
    network = ipaddress.ip_network(line, strict=True)
    if network.version != family:
        raise SystemExit(f"unexpected IPv{network.version} CIDR: {line}")
PY
}

managed_rule_numbers() {
  ufw status numbered | awk -v comment="$COMMENT" '
    index($0, "# " comment) {
      number = $0
      sub(/^\[[[:space:]]*/, "", number)
      sub(/\].*$/, "", number)
      print number
    }
  '
}

global_8443_rule_numbers() {
  ufw status numbered | awk -v port="$PORT/tcp" '
    {
      original = $0
      sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
      field = 2
      if ($2 == "(v6)") {
        field = 3
      }
      if ($1 == port && toupper($(field)) == "ALLOW" &&
          toupper($(field + 1)) == "IN" && $(field + 2) == "Anywhere") {
        number = original
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*$/, "", number)
        print number
      }
    }
  '
}

delete_rule_numbers() {
  local number
  while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    ufw --force delete "$number"
  done < <(sort -rn)
}

remove_managed_rules() {
  managed_rule_numbers | delete_rule_numbers
}

if [[ "${1:-}" == '--remove' ]]; then
  remove_managed_rules
  global_8443_rule_numbers | delete_rule_numbers
  (( $(managed_rule_numbers | wc -l) == 0 )) || die 'Cloudflare-8443 规则未完全删除。'
  printf 'Cloudflare 8443 规则已删除。备份：%s\n' "$BACKUP_DIR"
  exit 0
fi
(( $# == 0 )) || die '唯一支持的参数是 --remove。'

download_cidr_list 'https://www.cloudflare.com/ips-v4' "$TMP_DIR/v4"
download_cidr_list 'https://www.cloudflare.com/ips-v6' "$TMP_DIR/v6"
validate_cidr_file 4 "$TMP_DIR/v4"
validate_cidr_file 6 "$TMP_DIR/v6"

awk 'NF { print }' "$TMP_DIR/v4" >"$TMP_DIR/desired"
if ufw_ipv6_enabled; then
  awk 'NF { print }' "$TMP_DIR/v6" >>"$TMP_DIR/desired"
fi

# Add the complete new set first. UFW ignores exact duplicates, so the old
# allow-list remains effective until every new source has been prepared.
while IFS= read -r cidr; do
  [[ -n "$cidr" ]] || continue
  ufw allow proto tcp from "$cidr" to any port "$PORT" comment "$COMMENT"
done <"$TMP_DIR/desired"

# Remove stale and duplicate managed rules only after the new set exists.
ufw status numbered | awk -v comment="$COMMENT" -v desired="$TMP_DIR/desired" '
  BEGIN {
    while ((getline line < desired) > 0) {
      wanted[line] = 1
    }
    close(desired)
  }
  index($0, "# " comment) {
    original = $0
    sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
    field = 2
    if ($2 == "(v6)") {
      field = 3
    }
    source = $(field + 2)
    number = original
    sub(/^\[[[:space:]]*/, "", number)
    sub(/\].*$/, "", number)
    if (!wanted[source] || seen[source]++) {
      print number
    }
  }
' | delete_rule_numbers

# A global allow would defeat the source allow-list; remove only exact
# Anywhere rules for this port and leave unrelated restricted rules alone.
global_8443_rule_numbers | delete_rule_numbers

expected=$(awk 'NF { count++ } END { print count + 0 }' "$TMP_DIR/desired")
actual=$(managed_rule_numbers | wc -l)

printf '\nCloudflare 规则：%s/%s\n\n' "$actual" "$expected"
ufw status numbered
(( actual == expected )) || die 'Cloudflare 规则实际数量与预期不一致。'
printf '\n更新完成，规则数量正常，8443/tcp 未向全网开放。\n'
printf 'UFW 规则备份：%s\n' "$BACKUP_DIR"
