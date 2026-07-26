#!/bin/bash
#
# ============================================================================
#  Настройка собственного сайта-маскировки (dest) для VLESS Reality
#  Debian 11+ / Ubuntu 20.04+
# ============================================================================
#
#  Что делает:
#    - поднимает nginx с реальным сайтом на 127.0.0.1:<порт>
#    - выпускает сертификат Let's Encrypt и настраивает АВТОПЕРЕЗАГРУЗКУ
#      nginx после продления (без этого TLS ломается на 90-й день)
#    - определяет версию nginx и подбирает корректный синтаксис http2
#    - идемпотентен: повторный запуск не ломает конфиг и не сносит сайт
#
#  Запускать: sudo ./reality-dest-setup.sh
#
# ============================================================================

set -Eeuo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';     NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
hdr()  { echo; echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

trap 'err "Прервано на строке $LINENO."' ERR

NGINX_CONF="/etc/nginx/sites-available/reality-dest.conf"
NGINX_LINK="/etc/nginx/sites-enabled/reality-dest.conf"
WEB_ROOT="/var/www/reality-dest"
DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh"
TMP_DIR=""

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ============================================================================
# 0. ПРОВЕРКИ
# ============================================================================
hdr "0. Предварительные проверки"

[[ $EUID -eq 0 ]] || { err "Запустите от root."; exit 1; }
[[ -t 0 ]] || { err "Скрипт интерактивный, запускайте не через пайп."; exit 1; }

grep -Eq '^(ID=debian|ID=ubuntu|ID_LIKE=.*debian)' /etc/os-release \
    || { err "Поддерживаются только Debian/Ubuntu."; exit 1; }

log "ОС: $(. /etc/os-release && echo "$PRETTY_NAME")"

# ============================================================================
# 1. ПАКЕТЫ
# ============================================================================
hdr "1. Установка пакетов"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

PKGS=(dnsutils iproute2 nginx certbot python3-certbot-nginx unzip wget curl ca-certificates)
TO_INSTALL=()
for pkg in "${PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || TO_INSTALL+=("$pkg")
done

if (( ${#TO_INSTALL[@]} )); then
    log "Устанавливаю: ${TO_INSTALL[*]}"
    apt-get install -y -qq "${TO_INSTALL[@]}" >/dev/null
else
    log "Все пакеты уже установлены."
fi

# libnginx-mod-stream нужен только если вы будете терминировать stream в nginx.
# Для схемы «Xray Reality -> dest» он не требуется, но не мешает.
dpkg -s libnginx-mod-stream &>/dev/null || apt-get install -y -qq libnginx-mod-stream >/dev/null 2>&1 || true

# --- Версия nginx определяет синтаксис http2 ---
# Директива `http2 on;` появилась только в 1.25.1. На Debian 12 (1.22)
# и Ubuntu 24.04 (1.24) она вызывает "unknown directive" — и конфиг
# падает УЖЕ ПОСЛЕ выпуска сертификата, впустую расходуя квоту LE.
NGX_VER=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
if [[ -z "$NGX_VER" ]]; then
    warn "Не удалось определить версию nginx, использую старый синтаксис http2."
    NGX_VER="1.0.0"
fi

if dpkg --compare-versions "$NGX_VER" ge 1.25.1; then
    HTTP2_STYLE="new"
    log "nginx $NGX_VER — использую директиву 'http2 on;'"
else
    HTTP2_STYLE="old"
    log "nginx $NGX_VER — использую 'listen ... http2;' (старый синтаксис)"
fi

# ============================================================================
# 2. ПОРТ
# ============================================================================
hdr "2. Выбор внутреннего порта для dest"

port_in_use() { ss -tlnH "( sport = :$1 )" 2>/dev/null | grep -q .; }
port_is_ours() { [[ -f "$NGINX_CONF" ]] && grep -q "listen 127.0.0.1:$1 ssl" "$NGINX_CONF"; }

DEFAULT_PORT=8443
SPORT=""
while true; do
    read -rp "Внутренний порт для dest [$DEFAULT_PORT]: " inp
    inp="${inp:-$DEFAULT_PORT}"

    if [[ ! "$inp" =~ ^[0-9]+$ ]] || (( inp < 1024 || inp > 65535 )); then
        err "Введите число 1024-65535."; continue
    fi
    if port_in_use "$inp"; then
        if port_is_ours "$inp"; then
            log "Порт $inp занят нашим же nginx с прошлого запуска — переиспользую."
        else
            err "Порт $inp занят другим процессом:"
            ss -tlnp "( sport = :$inp )" 2>/dev/null || true
            continue
        fi
    fi
    SPORT="$inp"; break
done
log "Порт dest: 127.0.0.1:$SPORT"

# ============================================================================
# 3. ДОМЕН И DNS
# ============================================================================
hdr "3. Домен и проверка DNS"

read -rp "Доменное имя для SNI: " DOMAIN
DOMAIN="${DOMAIN,,}"
[[ -n "$DOMAIN" ]] || { err "Домен не может быть пустым."; exit 1; }
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { err "Некорректное доменное имя."; exit 1; }

read -rp "Email для Let's Encrypt: " MAIL
[[ "$MAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] \
    || { err "Некорректный email."; exit 1; }

# --- Внешний IP: два независимых источника ---
EXT_IP4=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$EXT_IP4" ]] && EXT_IP4=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
[[ -n "$EXT_IP4" ]] || { err "Не удалось определить внешний IPv4."; exit 1; }
log "Внешний IPv4 сервера: $EXT_IP4"

EXT_IP6=$(curl -s6 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
[[ "$EXT_IP6" == *:* ]] || EXT_IP6=""
[[ -n "$EXT_IP6" ]] && log "Внешний IPv6 сервера: $EXT_IP6"

# --- A-запись ---
# grep -qxF по списку строк, а НЕ сравнение строк: при CNAME-цепочке
# dig +short выдаёт несколько строк (цель CNAME + адрес), и прямое
# сравнение "$domain_ip" == "$EXT_IP4" ложно проваливается.
mapfile -t A_RECORDS < <(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

if (( ${#A_RECORDS[@]} == 0 )); then
    err "A-запись для $DOMAIN не найдена. Проверьте DNS и подождите распространения."
    exit 1
fi
log "A-записи $DOMAIN: ${A_RECORDS[*]}"

if printf '%s\n' "${A_RECORDS[@]}" | grep -qxF "$EXT_IP4"; then
    log "A-запись совпадает с IP сервера."
else
    err "A-запись НЕ указывает на этот сервер ($EXT_IP4)."
    err "Валидация Let's Encrypt провалится. Исправьте DNS."
    exit 1
fi

# --- AAAA-запись ---
# Если AAAA есть, но ведёт не сюда, Let's Encrypt предпочтёт IPv6
# и валидация упадёт с невнятной ошибкой "Timeout during connect".
mapfile -t AAAA_RECORDS < <(dig +short AAAA "$DOMAIN" | grep ':' || true)
USE_IPV6=0
if (( ${#AAAA_RECORDS[@]} > 0 )); then
    log "AAAA-записи: ${AAAA_RECORDS[*]}"
    if [[ -n "$EXT_IP6" ]] && printf '%s\n' "${AAAA_RECORDS[@]}" | grep -qxF "$EXT_IP6"; then
        log "AAAA совпадает с IPv6 сервера."
        USE_IPV6=1
    else
        err "AAAA-запись есть, но ведёт НЕ на этот сервер."
        err "Let's Encrypt предпочитает IPv6 — валидация провалится."
        read -rp "Продолжить всё равно? (y/N): " ans
        [[ "$ans" =~ ^[yY]$ ]] || exit 1
    fi
else
    log "AAAA-записей нет — валидация пойдёт по IPv4."
fi

# ============================================================================
# 4. FIREWALL (порт 80 для ACME)
# ============================================================================
hdr "4. Проверка доступности порта 80"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    # Исходная проверка `grep "^80/tcp\s+ALLOW"` давала ложный отказ:
    # правило, добавленное профилем ("Nginx Full", "Nginx HTTP"),
    # выводится под своим именем, а не как 80/tcp.
    if ufw status | grep -Eq '^(80/tcp|80|Nginx (Full|HTTP))\s+ALLOW'; then
        log "UFW: порт 80 разрешён."
    else
        warn "UFW активен, правило для 80/tcp не найдено."
        read -rp "Открыть 80/tcp сейчас? (Y/n): " ans
        if [[ ! "$ans" =~ ^[nN]$ ]]; then
            ufw allow 80/tcp >/dev/null
            log "Порт 80/tcp открыт."
        else
            err "Без порта 80 webroot-валидация невозможна."; exit 1
        fi
    fi
    # 443 нужен для Xray
    ufw status | grep -Eq '^(443/tcp|443|Nginx (Full|HTTPS))\s+ALLOW' \
        || { ufw allow 443/tcp >/dev/null; log "Порт 443/tcp открыт (для Xray)."; }
else
    log "UFW неактивен или не установлен — правила не нужны."
fi

# ============================================================================
# 5. САЙТ-МАСКИРОВКА
# ============================================================================
hdr "5. Сайт-маскировка"

if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
    warn "Каталог $WEB_ROOT уже содержит сайт."
    echo "  1) Оставить как есть (рекомендуется при повторном запуске)"
    echo "  2) Заменить новым шаблоном (старое уйдёт в бэкап)"
    read -rp "Выбор [1/2, по умолчанию 1]: " site_choice
    site_choice="${site_choice:-1}"
else
    site_choice="2"
fi

if [[ "$site_choice" == "2" ]]; then
    if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
        BK="/root/reality-dest-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar czf "$BK" -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")"
        log "Бэкап старого сайта: $BK"
    fi

    echo
    echo "Источник сайта:"
    echo "  1) Шаблон StartBootstrap (будет автоматически «обезличен»)"
    echo "  2) Свой архив .zip / .tar.gz (укажу путь)"
    echo "  3) Свой каталог (укажу путь)"
    read -rp "Выбор [1/2/3, по умолчанию 1]: " src_choice
    src_choice="${src_choice:-1}"

    TMP_DIR=$(mktemp -d)
    rm -rf "$WEB_ROOT"; mkdir -p "$WEB_ROOT"

    case "$src_choice" in
        2)
            read -rp "Путь к архиву: " ARCH
            [[ -f "$ARCH" ]] || { err "Файл не найден."; exit 1; }
            case "$ARCH" in
                *.zip)    unzip -q "$ARCH" -d "$TMP_DIR" ;;
                *.tar.gz|*.tgz) tar xzf "$ARCH" -C "$TMP_DIR" ;;
                *) err "Поддерживаются .zip, .tar.gz"; exit 1 ;;
            esac
            ;;
        3)
            read -rp "Путь к каталогу: " SRCDIR
            [[ -d "$SRCDIR" ]] || { err "Каталог не найден."; exit 1; }
            cp -a "$SRCDIR/." "$TMP_DIR/"
            ;;
        *)
            TEMPLATES=(
                "https://github.com/StartBootstrap/startbootstrap-agency/archive/refs/heads/master.zip"
                "https://github.com/StartBootstrap/startbootstrap-clean-blog/archive/refs/heads/master.zip"
                "https://github.com/StartBootstrap/startbootstrap-freelancer/archive/refs/heads/master.zip"
                "https://github.com/StartBootstrap/startbootstrap-business-casual/archive/refs/heads/master.zip"
                "https://github.com/StartBootstrap/startbootstrap-creative/archive/refs/heads/master.zip"
            )
            TPL="${TEMPLATES[$RANDOM % ${#TEMPLATES[@]}]}"
            log "Шаблон: $(basename "$(dirname "$(dirname "$(dirname "$TPL")")")")"
            wget -q -O "$TMP_DIR/tpl.zip" "$TPL" || { err "Ошибка скачивания шаблона."; exit 1; }
            unzip -q "$TMP_DIR/tpl.zip" -d "$TMP_DIR/x"
            rm -f "$TMP_DIR/tpl.zip"
            mv "$TMP_DIR/x" "$TMP_DIR/extracted"
            ;;
    esac

    # Ищем корень сайта: тот каталог, где лежит index.html.
    # Исходное `if [ -d /tmp/.../*/dist ]` полагалось на глоб внутри [ ],
    # который при нуле совпадений тестирует литеральную строку,
    # а при двух и более падает с "too many arguments".
    SITE_SRC=$(find "$TMP_DIR" -name index.html -not -path '*/node_modules/*' \
                    -printf '%d %h\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)
    [[ -n "$SITE_SRC" ]] || { err "index.html не найден в источнике."; exit 1; }

    cp -a "$SITE_SRC/." "$WEB_ROOT/"
    log "Файлы сайта размещены в $WEB_ROOT"

    # --- Обезличивание шаблона ---
    if [[ "$src_choice" == "1" ]]; then
        BRAND_DEFAULT=$(echo "${DOMAIN%%.*}" | sed 's/^./\U&/')
        read -rp "Название сайта [$BRAND_DEFAULT]: " BRAND
        BRAND="${BRAND:-$BRAND_DEFAULT}"
        read -rp "Краткое описание [Digital solutions and consulting]: " TAGLINE
        TAGLINE="${TAGLINE:-Digital solutions and consulting}"

        log "Убираю следы шаблона..."
        find "$WEB_ROOT" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' \) -print0 \
        | while IFS= read -r -d '' f; do
            sed -i \
                -e "s/Start Bootstrap/${BRAND//\//\\/}/g" \
                -e "s/StartBootstrap/${BRAND//\//\\/}/g" \
                -e "s/startbootstrap/${BRAND,,}/g" \
                -e 's#https\?://startbootstrap\.com[^"'"'"' ]*#/#g' \
                "$f"
        done

        find "$WEB_ROOT" -name '*.html' -print0 | while IFS= read -r -d '' f; do
            sed -i -e "s#<title>.*</title>#<title>${BRAND} — ${TAGLINE}</title>#" "$f"
        done
        log "Бренд заменён на «$BRAND»."
    fi

    # --- robots.txt ---
    if [[ ! -f "$WEB_ROOT/robots.txt" ]]; then
        cat > "$WEB_ROOT/robots.txt" <<EOF
User-agent: *
Allow: /

Sitemap: https://$DOMAIN/sitemap.xml
EOF
    fi

    # --- sitemap.xml ---
    if [[ ! -f "$WEB_ROOT/sitemap.xml" ]]; then
        cat > "$WEB_ROOT/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://$DOMAIN/</loc>
    <lastmod>$(date +%F)</lastmod>
    <changefreq>weekly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
EOF
    fi

    # --- favicon.ico ---
    # Отсутствие фавикона — заметная аномалия: настоящие сайты его имеют,
    # а браузеры и сканеры его всегда запрашивают.
    if [[ ! -f "$WEB_ROOT/favicon.ico" ]]; then
        python3 - "$WEB_ROOT/favicon.ico" <<'PYEOF' 2>/dev/null && log "favicon.ico создан." || warn "favicon.ico не создан."
import struct, sys, random
w = h = 16
r, g, b = random.randint(30,90), random.randint(60,140), random.randint(120,200)
xor = b''
for y in range(h):
    for x in range(w):
        d = max(abs(x-7.5), abs(y-7.5))
        f = 1.0 if d < 6 else 0.55
        xor += struct.pack('<4B', int(b*f), int(g*f), int(r*f), 255)
and_mask = b'\x00' * (4 * h)
dib = struct.pack('<IiiHHIIiiII', 40, w, h*2, 1, 32, 0, len(xor)+len(and_mask), 0, 0, 0, 0)
img = dib + xor + and_mask
ico = struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHII', w, h, 0, 0, 1, 32, len(img), 22) + img
open(sys.argv[1], 'wb').write(ico)
PYEOF
    fi

    # --- 404 ---
    if [[ ! -f "$WEB_ROOT/404.html" ]]; then
        cat > "$WEB_ROOT/404.html" <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page not found</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0;
background:#f8f9fa;color:#212529}div{text-align:center}h1{font-size:4rem;margin:0}
p{color:#6c757d}a{color:#0d6efd;text-decoration:none}</style></head>
<body><div><h1>404</h1><p>The page you requested could not be found.</p>
<p><a href="/">Return to homepage</a></p></div></body></html>
EOF
    fi
fi

mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
chown -R www-data:www-data "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +
log "Права выставлены."

# ============================================================================
# 6. PROXY_PROTOCOL
# ============================================================================
hdr "6. PROXY protocol"

# Это самая частая причина «Reality работает, но маскировка не работает».
# nginx с proxy_protocol ЖДЁТ заголовок перед TLS. Xray его шлёт только
# при xver=1/2 в realitySettings (по умолчанию 0). При несовпадении
# nginx рвёт соединение мгновенно — то есть пробер видит разрыв
# вместо сайта ровно тогда, когда маскировка и нужна.
echo "PROXY protocol передаёт nginx реальный IP клиента (нужно для access-логов)."
echo "Требует xver=1 или 2 в конфиге Xray. При рассинхроне dest не работает."
read -rp "Включить PROXY protocol? (y/N): " pp_ans

if [[ "$pp_ans" =~ ^[yY]$ ]]; then
    USE_PP=1; XVER=2
    LISTEN_EXTRA=" proxy_protocol"
    log "PROXY protocol включён → в Xray нужен \"xver\": 2"
else
    USE_PP=0; XVER=0
    LISTEN_EXTRA=""
    log "PROXY protocol выключен → в Xray нужен \"xver\": 0 (значение по умолчанию)"
fi

# ============================================================================
# 7. NGINX: ЭТАП 1 (HTTP для ACME)
# ============================================================================
hdr "7. Конфигурация nginx (этап 1: HTTP)"

LISTEN80_V6=""
(( USE_IPV6 )) && LISTEN80_V6="  listen [::]:80;"

# Конфиг пишется ЦЕЛИКОМ (>), а не дописывается (>>).
# Исходный скрипт при повторном запуске добавлял второй SSL-блок
# к уже существующему — nginx поднимался, но с conflicting server name.
cat > "$NGINX_CONF" <<EOF
# Managed by reality-dest-setup.sh — файл перезаписывается при перезапуске.

server {
  listen 80;
$LISTEN80_V6
  server_name $DOMAIN;
  root $WEB_ROOT;

  location /.well-known/acme-challenge/ {
    try_files \$uri =404;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_CONF" "$NGINX_LINK"

if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    log "nginx перезагружен (HTTP-этап)."
else
    err "Ошибка конфигурации nginx:"; nginx -t; exit 1
fi

# ============================================================================
# 8. СЕРТИФИКАТ
# ============================================================================
hdr "8. Сертификат Let's Encrypt"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
    EXP=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)
    log "Сертификат уже существует, истекает: $EXP"
else
    log "Запрашиваю сертификат для $DOMAIN..."
    certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" \
        --agree-tos -m "$MAIL" --non-interactive --no-eff-email \
        || { err "Certbot не смог выпустить сертификат. Логи: /var/log/letsencrypt/"; exit 1; }
    [[ -f "$CERT_DIR/fullchain.pem" ]] || { err "Сертификат не появился."; exit 1; }
    log "Сертификат выпущен."
fi

# --- DEPLOY HOOK: без него всё сломается на 90-й день ---
# certonly --webroot не записывает installer в renewal-конфиг.
# Certbot успешно продлит файл на диске, но nginx продолжит держать
# в памяти старый сертификат. TLS на dest сломается, а вместе с ним
# и Reality — при том, что `certbot certificates` покажет всё зелёным.
mkdir -p "$(dirname "$DEPLOY_HOOK")"
cat > "$DEPLOY_HOOK" <<'EOF'
#!/bin/sh
# Перезагрузка nginx после успешного обновления сертификата.
set -e
if systemctl is-active --quiet nginx; then
    nginx -t && systemctl reload nginx
    logger -t certbot-deploy "nginx reloaded after certificate renewal"
fi
EOF
chmod +x "$DEPLOY_HOOK"
log "Deploy-hook установлен: $DEPLOY_HOOK"

systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true

# ============================================================================
# 9. NGINX: ЭТАП 2 (полный конфиг с TLS)
# ============================================================================
hdr "9. Конфигурация nginx (этап 2: TLS)"

if [[ "$HTTP2_STYLE" == "new" ]]; then
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl${LISTEN_EXTRA} default_server;
  http2 on;"
else
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl http2${LISTEN_EXTRA} default_server;"
fi

REALIP_BLOCK=""
if (( USE_PP )); then
    REALIP_BLOCK="  real_ip_header proxy_protocol;
  set_real_ip_from 127.0.0.1;
  set_real_ip_from ::1;"
fi

cat > "$NGINX_CONF" <<EOF
# Managed by reality-dest-setup.sh — файл перезаписывается при перезапуске.

# ---------- HTTP: ACME + редирект ----------
server {
  listen 80;
$LISTEN80_V6
  server_name $DOMAIN;
  root $WEB_ROOT;

  location /.well-known/acme-challenge/ {
    try_files \$uri =404;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

# ---------- DEST для Reality ----------
# default_server: Xray пересылает сюда и трафик с чужим/пустым SNI,
# такой запрос не совпадёт с server_name и должен куда-то попасть.
server {
$LISTEN_SSL
  server_name $DOMAIN;

  ssl_certificate     $CERT_DIR/fullchain.pem;
  ssl_certificate_key $CERT_DIR/privkey.pem;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;
  ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  # OCSP stapling намеренно отключён: Let's Encrypt сворачивает
  # поддержку OCSP, и включённый stapling даёт ошибки в логах.

  add_header Strict-Transport-Security "max-age=31536000" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

$REALIP_BLOCK

  # Логи включены: для сайта-обманки это единственный способ увидеть,
  # что вас кто-то пробирует и с какими SNI.
  access_log /var/log/nginx/reality-dest.access.log;
  error_log  /var/log/nginx/reality-dest.error.log warn;

  root $WEB_ROOT;
  index index.html index.htm;

  error_page 404 /404.html;

  location / {
    try_files \$uri \$uri/ \$uri.html =404;
  }

  location = /404.html {
    internal;
  }

  location ~ /\.(?!well-known) {
    deny all;
  }
}
EOF

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log "nginx перезагружен (TLS активен)."
else
    err "Ошибка в TLS-конфигурации:"; nginx -t; exit 1
fi

# ============================================================================
# 10. ПРОВЕРКИ
# ============================================================================
hdr "10. Проверка работоспособности"

sleep 1
FAILED=0

# --- dest отвечает по TLS? ---
if (( USE_PP )); then
    RESP=$(curl -ks --haproxy-protocol --max-time 8 -o /dev/null \
           -w '%{http_code}' "https://127.0.0.1:$SPORT/" 2>/dev/null || echo "000")
else
    RESP=$(curl -ks --max-time 8 --resolve "$DOMAIN:$SPORT:127.0.0.1" \
           -o /dev/null -w '%{http_code}' "https://$DOMAIN:$SPORT/" 2>/dev/null || echo "000")
fi

if [[ "$RESP" == "200" ]]; then
    log "dest отвечает по TLS: HTTP $RESP"
else
    err "dest вернул '$RESP' вместо 200 — маскировка НЕ работает."
    err "Проверьте: tail -20 /var/log/nginx/reality-dest.error.log"
    FAILED=1
fi

# --- ALPN h2 согласуется? ---
ALPN=$(echo | timeout 8 openssl s_client -connect "127.0.0.1:$SPORT" \
        -servername "$DOMAIN" -alpn h2 2>/dev/null \
        | grep -i 'ALPN protocol' || true)
if [[ "$ALPN" == *h2* ]]; then
    log "ALPN: h2 согласован (как у настоящего сайта)."
elif (( USE_PP )); then
    warn "ALPN не проверить при включённом proxy_protocol — это нормально."
else
    warn "ALPN h2 не согласован. Клиенты Reality шлют h2 — профиль будет отличаться."
    FAILED=1
fi

# --- сайт доступен снаружи? ---
EXT=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://$DOMAIN/" 2>/dev/null || echo "000")
[[ "$EXT" =~ ^(301|302|200)$ ]] && log "Сайт доступен снаружи по HTTP: $EXT" \
    || warn "Снаружи по HTTP получен код '$EXT'."

# --- продление сертификата ---
log "Проверяю продление сертификата (--dry-run, использует staging)..."
if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
    log "Продление сертификата работает."
else
    err "certbot renew --dry-run ПРОВАЛИЛСЯ. Сертификат не обновится автоматически!"
    err "Разберитесь сейчас: certbot renew --dry-run"
    FAILED=1
fi

# ============================================================================
# ИТОГ
# ============================================================================
echo
printf "${GREEN}${BOLD}==================================================================${NC}\n"
if (( FAILED )); then
    printf "${YELLOW}${BOLD}  Установка завершена, но есть замечания — см. выше${NC}\n"
else
    printf "${GREEN}${BOLD}  Установка завершена успешно${NC}\n"
fi
printf "${GREEN}${BOLD}==================================================================${NC}\n\n"

printf "${BOLD}Параметры dest:${NC}\n"
printf "  %-14s ${YELLOW}%s${NC}\n" "Домен:"  "$DOMAIN"
printf "  %-14s ${YELLOW}%s${NC}\n" "Dest:"   "127.0.0.1:$SPORT"
printf "  %-14s ${YELLOW}%s${NC}\n" "xver:"   "$XVER"
printf "  %-14s ${CYAN}%s${NC}\n"  "Cert:"   "$CERT_DIR/fullchain.pem"
printf "  %-14s ${CYAN}%s${NC}\n"  "Key:"    "$CERT_DIR/privkey.pem"
printf "  %-14s ${CYAN}%s${NC}\n"  "Сайт:"   "$WEB_ROOT"
echo

printf "${BOLD}Фрагмент для realitySettings в конфиге Xray:${NC}\n"
cat <<EOF
  "realitySettings": {
    "show": false,
    "dest": "127.0.0.1:$SPORT",
    "xver": $XVER,
    "serverNames": ["$DOMAIN"],
    "privateKey": "<xray x25519>",
    "shortIds": ["<openssl rand -hex 8>"]
  }
EOF
echo
printf "${RED}${BOLD}xver обязан быть равен $XVER${NC} — иначе dest молча не работает.\n"
echo

printf "${BOLD}Полезные команды:${NC}\n"
echo "  Кто пробирует сайт:  tail -f /var/log/nginx/reality-dest.access.log"
echo "  Ошибки dest:         tail -f /var/log/nginx/reality-dest.error.log"
echo "  Срок сертификата:    certbot certificates"
echo "  Тест продления:      certbot renew --dry-run"
echo

printf "${YELLOW}${BOLD}Дальше — вручную:${NC}\n"
echo "  1. Отредактируйте тексты в $WEB_ROOT — стоковый шаблон"
echo "     с плейсхолдерами узнаётся автоматикой."
echo "  2. Ключи Xray: xray x25519  и  openssl rand -hex 8"
echo "  3. Порт 80 должен остаться открытым — иначе продление не пройдёт."
echo
