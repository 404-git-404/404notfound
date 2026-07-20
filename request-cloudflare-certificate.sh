#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 运行，例如：sudo bash $0" >&2
    exit 1
fi

ACME_EMAIL=''

printf '请输入需要申请证书的完整子域名: ' >/dev/tty
IFS= read -r DOMAIN </dev/tty
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "错误：域名格式不正确：$DOMAIN" >&2
    exit 1
fi

CREDENTIALS_DIR='/etc/letsencrypt/cloudflare-credentials'
CF_CREDS="$CREDENTIALS_DIR/$DOMAIN.ini"

LE_DIR="/etc/letsencrypt/live/$DOMAIN"
EXPORT_DIR="/etc/ssl/$DOMAIN"
FULLCHAIN="$EXPORT_DIR/fullchain.pem"
PRIVATE_KEY="$EXPORT_DIR/privkey.pem"

DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/export-$DOMAIN"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y certbot python3-certbot-dns-cloudflare openssl

printf '请输入该域名专用的 Cloudflare API Token（输入不会显示）: ' >/dev/tty
IFS= read -r -s CF_API_TOKEN </dev/tty
printf '\n' >/dev/tty

if [ -z "$CF_API_TOKEN" ]; then
    echo '错误：Cloudflare API Token 不能为空。' >&2
    exit 1
fi

# 每个完整域名单独保存一个 Token 文件
install -d -o root -g root -m 0700 "$CREDENTIALS_DIR"

umask 077
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$CF_CREDS"
unset CF_API_TOKEN

chown root:root "$CF_CREDS"
chmod 0600 "$CF_CREDS"

echo
echo "当前证书使用的独立凭据文件：$CF_CREDS"
echo

# 只使用当前域名对应的 Token 文件
certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS" \
    --dns-cloudflare-propagation-seconds 30 \
    --email "$ACME_EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring \
    --cert-name "$DOMAIN" \
    -d "$DOMAIN"

test -s "$LE_DIR/fullchain.pem"
test -s "$LE_DIR/privkey.pem"

# 检测 sing-box 服务用户和用户组
SERVICE_USER="$(systemctl show sing-box.service -p User --value 2>/dev/null || true)"
[ -n "$SERVICE_USER" ] || SERVICE_USER='root'

if id "$SERVICE_USER" >/dev/null 2>&1; then
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
else
    SERVICE_GROUP='root'
fi

# 导出两个真实普通文件
install -d \
    -o root \
    -g "$SERVICE_GROUP" \
    -m 0750 \
    "$EXPORT_DIR"

install \
    -o root \
    -g "$SERVICE_GROUP" \
    -m 0644 \
    "$LE_DIR/fullchain.pem" \
    "$FULLCHAIN"

install \
    -o root \
    -g "$SERVICE_GROUP" \
    -m 0640 \
    "$LE_DIR/privkey.pem" \
    "$PRIVATE_KEY"

# 创建该域名专用的续期部署钩子
install -d -o root -g root -m 0755 \
    /etc/letsencrypt/renewal-hooks/deploy

cat > "$DEPLOY_HOOK" <<EOF
#!/bin/sh
set -eu

SOURCE='$LE_DIR'
DESTINATION='$EXPORT_DIR'
SERVICE_GROUP='$SERVICE_GROUP'

# 只响应这个证书的续期
[ "\${RENEWED_LINEAGE:-}" = "\$SOURCE" ] || exit 0

install -d \
    -o root \
    -g "\$SERVICE_GROUP" \
    -m 0750 \
    "\$DESTINATION"

install \
    -o root \
    -g "\$SERVICE_GROUP" \
    -m 0644 \
    "\$SOURCE/fullchain.pem" \
    "\$DESTINATION/fullchain.pem"

install \
    -o root \
    -g "\$SERVICE_GROUP" \
    -m 0640 \
    "\$SOURCE/privkey.pem" \
    "\$DESTINATION/privkey.pem"

if systemctl cat sing-box.service >/dev/null 2>&1; then
    systemctl try-reload-or-restart sing-box.service
fi
EOF

chown root:root "$DEPLOY_HOOK"
chmod 0755 "$DEPLOY_HOOK"

systemctl enable --now certbot.timer

# 确认导出的文件不是软链接
if [ -L "$FULLCHAIN" ] || [ -L "$PRIVATE_KEY" ]; then
    echo '错误：导出的证书文件仍然是软链接。' >&2
    exit 1
fi

# 检查续期配置确实引用当前域名专用 Token
RENEWAL_CONFIG="/etc/letsencrypt/renewal/$DOMAIN.conf"

echo
echo '续期配置使用的 Cloudflare 凭据：'
grep -E 'dns_cloudflare_credentials|authenticator' \
    "$RENEWAL_CONFIG" || true

# 如果 sing-box 已安装，重启并检查
if systemctl cat sing-box.service >/dev/null 2>&1; then
    if ! systemctl restart sing-box.service; then
        journalctl -u sing-box.service -n 50 --no-pager
        exit 1
    fi
fi

echo
echo '申请及导出完成：'

stat -c '%n | 类型=%F | 权限=%a | 所有者=%U:%G | 大小=%s' \
    "$FULLCHAIN" \
    "$PRIVATE_KEY"

echo
openssl x509 \
    -in "$FULLCHAIN" \
    -noout \
    -subject \
    -issuer \
    -dates

echo
echo "证书：$FULLCHAIN"
echo "私钥：$PRIVATE_KEY"
echo "Token：$CF_CREDS"