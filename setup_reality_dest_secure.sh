#!/usr/bin/env bash
set -Eeuo pipefail

# --- Цветной вывод ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*"; }
trap 'err "Ошибка на строке $LINENO."' ERR

# --- Проверки окружения ---
[[ $EUID -eq 0 ]] || { err "Запустите от root."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Установка зависимостей (Nginx, Certbot, jq, curl, fail2ban)..."
apt-get update -qq && apt-get install -y -qq nginx certbot jq curl dnsutils fail2ban >/dev/null

# --- Интерактивный ввод ---
read -rp "Доменное имя для SNI: " DOMAIN
DOMAIN="${DOMAIN,,}"
read -rp "Email для Let's Encrypt: " MAIL
read -rp "Внутренний порт для dest [8443]: " SPORT
SPORT="${SPORT:-8443}"
echo -e "${YELLOW}Для защиты от ботов через Fail2ban ОБЯЗАТЕЛЕН PROXY protocol!${NC}"
read -rp "Включить PROXY protocol (xver=2 в Xray)? (Y/n): " PP_ANS
PP_ANS="${PP_ANS:-y}"

USE_PP=0; XVER=0; LISTEN_PP=""
if [[ "$PP_ANS" =~ ^[yY]$ ]]; then
    USE_PP=1; XVER=2; LISTEN_PP=" proxy_protocol"
fi

read -rsp "Ключ Pixabay API: " PIXABAY_KEY; echo
[[ -n "$PIXABAY_KEY" ]] || { err "Ключ не может быть пустым."; exit 1; }

# --- Пути ---
WEB_ROOT="/var/www/reality-dest"
NGINX_CONF="/etc/nginx/sites-available/reality-dest.conf"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$WEB_ROOT.new"' EXIT

# --- Детерминированное оформление из sha256(домен) ---
SEED=$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)
SEED_NUM=$(( 16#$SEED ))
PALETTES=("#1f6b6b" "#2f4b7c" "#4a6b45" "#5a3f88" "#8a4a2a" "#1f5f96")
ACCENT="${PALETTES[$(( SEED_NUM % ${#PALETTES[@]} ))]}"
CSS_FILE="style_${SEED:0:4}.css"

# --- 1. Проверка DNS ---
IP_EXT=$(curl -s4 https://api.ipify.org || true)
IP_DNS=$(dig +short A "$DOMAIN" | tail -n1)
if [[ "$IP_EXT" != "$IP_DNS" ]]; then
    err "A-запись ($IP_DNS) не совпадает с IP сервера ($IP_EXT)."
    exit 1
fi

# --- 2. Скачивание видео с Pixabay ---
log "Получаем каталог видео..."
HTTP_CODE=$(curl -sS -o "$TMP_DIR/api.json" -w "%{http_code}" "https://pixabay.com/api/videos/?key=${PIXABAY_KEY}&q=architecture&per_page=30&safesearch=true")

if [[ "$HTTP_CODE" != "200" ]]; then
    err "Ошибка API Pixabay (HTTP $HTTP_CODE). Проверьте ключ API или доступность сети."
    cat "$TMP_DIR/api.json" 2>/dev/null || true
    exit 1
fi

jq -c '.hits[] | select(.duration >= 10) | {url: .videos.large.url, tags: .tags}' "$TMP_DIR/api.json" \
    | shuf -n 6 > "$TMP_DIR/pool.jsonl"

if [[ ! -s "$TMP_DIR/pool.jsonl" ]]; then
    err "Не найдено подходящих видео (длиной >= 10 сек). Проверьте запрос к API."
    exit 1
fi

mkdir -p "$WEB_ROOT.new/assets/video" "$WEB_ROOT.new/assets/css" "$WEB_ROOT.new/.well-known/acme-challenge"

idx=1
declare -a VIDEOS
while read -r row; do
    v_url=$(jq -r '.url' <<<"$row")
    v_tag=$(jq -r '.tags' <<<"$row")
    v_file="assets/video/clip-${idx}.mp4"
    log "Скачиваем видео $idx..."
    if curl -fsSL -o "$WEB_ROOT.new/$v_file" "$v_url"; then
        VIDEOS+=("$v_file|$v_tag")
        ((idx++))
    fi
done < "$TMP_DIR/pool.jsonl"

# --- 3. Генерация CSS и HTML ---
cat > "$WEB_ROOT.new/assets/css/$CSS_FILE" <<CSS
body { font-family: system-ui, sans-serif; background: #f8f9fa; color: #212529; margin: 0; padding: 0; }
header { background: #fff; border-bottom: 1px solid #dee2e6; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; }
a { color: $ACCENT; text-decoration: none; }
.logo { font-weight: bold; font-size: 1.2rem; }
.container { max-width: 1100px; margin: 2rem auto; padding: 0 1rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1.5rem; }
.card { background: #fff; border: 1px solid #dee2e6; border-radius: 6px; overflow: hidden; }
video { width: 100%; aspect-ratio: 16/9; background: #000; }
.card-body { padding: 1rem; }
CSS

render_header() {
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$1 — Studio</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' fill='${ACCENT//#/ %23}'/></svg>">
    <link rel="stylesheet" href="/assets/css/$CSS_FILE">
</head>
<body>
<header>
    <div class="logo">$DOMAIN Studio</div>
    <nav><a href="/">Work</a> | <a href="/about.html">About</a></nav>
</header>
<div class="container">
HTML
}

render_footer() {
    cat <<HTML
</div>
<footer style="margin-top: 3rem; padding-bottom: 2rem; text-align: center; color: #6c757d; font-size: 0.9rem;">
    &copy; $(date +%Y) $DOMAIN Studio. All rights reserved.
</footer>
</body>
</html>
HTML
}

# index.html
{
    render_header "Portfolio"
    echo '<h1>Selected Works</h1><div class="grid">'
    for item in "${VIDEOS[@]}"; do
        IFS='|' read -r v_file v_tag <<<"$item"
        cat <<CARD
        <div class="card">
            <video controls preload="metadata" poster="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"><source src="/$v_file" type="video/mp4"></video>
            <div class="card-body"><h3>Work</h3><p>$v_tag</p></div>
        </div>
CARD
    done
    echo '</div>'
    render_footer
} > "$WEB_ROOT.new/index.html"

# about.html, 404.html, robots.txt
{ render_header "About"; echo '<h1>About Us</h1><p>Minimalist production & motion design studio.</p>'; render_footer; } > "$WEB_ROOT.new/about.html"
{ render_header "404"; echo '<h1>404 Not Found</h1>'; render_footer; } > "$WEB_ROOT.new/404.html"
echo -e "User-agent: *\nAllow: /" > "$WEB_ROOT.new/robots.txt"

# Атомарная подмена каталога
rm -rf "$WEB_ROOT"
mv "$WEB_ROOT.new" "$WEB_ROOT"

# --- 4. Выпуск Сертификата ---
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
    log "Получение SSL сертификата..."
    certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --agree-tos -m "$MAIL" --non-interactive
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
echo -e '#!/bin/sh\nsystemctl reload nginx' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# --- 5. Проверка HTTP/2 ---
HTTP2_LISTEN=" http2"
HTTP2_DIR=""
cat > "$TMP_DIR/test-h2.conf" <<EOF
events {}
http { server { listen 8080; http2 on; } }
EOF
if nginx -t -c "$TMP_DIR/test-h2.conf" &>/dev/null; then
    HTTP2_LISTEN=""
    HTTP2_DIR="http2 on;"
fi

# --- 6. Генерация Nginx конфига ---
REALIP_CFG=""
LIMIT_REQ_ZONE=""
LIMIT_REQ_APPLY=""

if (( USE_PP )); then
    REALIP_CFG="real_ip_header proxy_protocol; set_real_ip_from 127.0.0.1;"
    LIMIT_REQ_ZONE="limit_req_zone \$binary_remote_addr zone=dest_limit:10m rate=30r/m;"
    LIMIT_REQ_APPLY="limit_req zone=dest_limit burst=30 nodelay;"
fi

cat > "$NGINX_CONF" <<EOF
$LIMIT_REQ_ZONE

server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 127.0.0.1:$SPORT ssl$HTTP2_LISTEN$LISTEN_PP default_server;
    server_name $DOMAIN;
    root $WEB_ROOT;

    include /etc/nginx/mime.types;
    $HTTP2_DIR

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:reality_dest:10m;

    $REALIP_CFG
    $LIMIT_REQ_APPLY

    server_tokens off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    access_log off;
    error_log /var/log/nginx/error.log error; # Важно для Fail2ban
    error_page 404 /404.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /assets/video/ {
        add_header Cache-Control "public, max-age=604800";
    }
}
EOF

nginx -t && systemctl reload nginx

# --- 7. Настройка Fail2ban ---
if (( USE_PP )); then
    log "Настройка Fail2ban для блокировки ботов..."
    
    # Создаем правило для защиты Nginx (limit_req)
    cat > /etc/fail2ban/jail.d/reality-nginx.conf <<EOF
[nginx-limit-req]
enabled = true
filter  = nginx-limit-req
logpath = /var/log/nginx/error.log
# Блокируем IP-адрес нарушителя на всех портах (включая 443 для защиты Xray)
action  = iptables-allports[name=Reality, protocol=all]
findtime = 600
bantime  = 86400
maxretry = 3
EOF

    systemctl restart fail2ban
    systemctl enable fail2ban
    log "Fail2ban успешно настроен! Нарушители будут заблокированы на 24 часа."
else
    warn "PROXY protocol отключен. Настройка Fail2ban для веб-сервера пропущена, так как это приведет к блокировке локального трафика."
fi

log "Развертывание завершено успешно!"

cat <<EOF

==================================================
  Параметры для конфига Xray (realitySettings):
==================================================
  "dest": "127.0.0.1:$SPORT",
  "xver": $XVER,
  "serverNames": ["$DOMAIN"]
==================================================
EOF
