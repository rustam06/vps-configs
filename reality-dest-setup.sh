#!/usr/bin/env bash
#
# ============================================================================
#  Настройка собственного сайта-маскировки (dest) для VLESS Reality
#  с видеогалереей вместо стокового Bootstrap-шаблона.
#  Debian 11+ / Ubuntu 20.04+
# ============================================================================
#
#  Что делает:
#    - собирает сайт студии моушн-дизайна и наполняет его видео с Pixabay
#    - поднимает nginx с этим сайтом на 127.0.0.1:<порт>
#    - выпускает сертификат Let's Encrypt и настраивает автоперезагрузку
#      nginx после продления (без этого TLS ломается на 90-й день)
#    - определяет версию nginx и подбирает корректный синтаксис http2
#    - идемпотентен: повторный запуск не ломает конфиг и не сносит сайт
#
#  Ключ Pixabay спрашивается интерактивно и нигде не сохраняется.
#  Получить: зарегистрироваться на pixabay.com и открыть
#  https://pixabay.com/api/docs/ — ключ показан в разделе Parameters.
#
#  Запускать: sudo ./reality-dest-setup.sh
#
# ============================================================================

set -Eeuo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';     NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
hdr()  { echo; echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

trap 'err "Прервано на строке $LINENO."' ERR

NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/reality-dest.conf}"
NGINX_LINK="/etc/nginx/sites-enabled/$(basename "$NGINX_CONF")"
WEB_ROOT="${WEB_ROOT:-/var/www/reality-dest}"
DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh"

# Тестовый режим: сертификат берётся из staging-центра Let's Encrypt.
# Он не проходит проверку в браузере, зато не расходует боевую квоту
# (5 сертификатов на один набор доменов в неделю). Для прогона скрипта
# «вхолостую» это единственный безопасный вариант.
CERTBOT_STAGING="${CERTBOT_STAGING:-0}"
LOG_PREFIX="${LOG_PREFIX:-reality-dest}"
# Имена переменных и зон nginx допускают только [A-Za-z0-9_]: дефис из
# LOG_PREFIX превратил бы $reality-dest_bad_ua в "$reality" плюс мусор.
SAFE_PREFIX="${LOG_PREFIX//[^a-zA-Z0-9]/_}"

# --- Параметры видеогалереи (можно переопределить через окружение) ---
VIDEO_COUNT="${VIDEO_COUNT:-8}"          # сколько клипов на витрине
VIDEO_QUALITY="${VIDEO_QUALITY:-large}"  # large = 1080p
MIN_DURATION="${MIN_DURATION:-15}"       # секунд, короче — отбрасываем
MIN_SIZE_MB="${MIN_SIZE_MB:-4}"          # МБ, легче — отбрасываем
FETCH_POOL=60                            # кандидатов запросить у API
MIN_FREE_MB=1024                         # запас места на разделе

TMP_DIR=""; STAGE=""
cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    [[ -n "$STAGE"   && -d "$STAGE"   ]] && rm -rf "$STAGE"
    return 0
}
trap cleanup EXIT

# HTML-экранирование строк из API
esc() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' \
                            -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# ============================================================================
# 0. ПРОВЕРКИ
# ============================================================================
hdr "0. Предварительные проверки"

[[ $EUID -eq 0 ]] || { err "Запустите от root."; exit 1; }
[[ -t 0 ]] || { err "Скрипт интерактивный, запускайте не через пайп."; exit 1; }

grep -Eq '^(ID=debian|ID=ubuntu|ID_LIKE=.*debian)' /etc/os-release \
    || { err "Поддерживаются только Debian/Ubuntu."; exit 1; }

log "ОС: $(. /etc/os-release && echo "$PRETTY_NAME")"

FREE_MB=$(df -Pm /var/www 2>/dev/null | awk 'NR==2{print $4}' || df -Pm / | awk 'NR==2{print $4}')
if [[ "$FREE_MB" -lt "$MIN_FREE_MB" ]]; then
    err "На разделе свободно ${FREE_MB} МБ, для видеогалереи нужно минимум ${MIN_FREE_MB} МБ."
    exit 1
fi
log "Свободно на разделе: ${FREE_MB} МБ"

# ============================================================================
# 1. ПАКЕТЫ
# ============================================================================
hdr "1. Установка пакетов"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

PKGS=(dnsutils iproute2 nginx certbot python3-certbot-nginx jq curl wget
      ca-certificates coreutils tar python3)
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
# 2. ВСЕ ВОПРОСЫ — СРАЗУ
# ============================================================================
# Собираем ввод одним блоком: дальше идут скачивание видео и выпуск
# сертификата, и уходить от терминала на 10 минут, чтобы потом упереться
# в очередной вопрос, неудобно.
hdr "2. Параметры установки"

# --- 2.1 Порт ---
port_in_use()  { ss -tlnH "( sport = :$1 )" 2>/dev/null | grep -q .; }
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

# --- 2.2 Домен и email ---
read -rp "Доменное имя для SNI: " DOMAIN
DOMAIN="${DOMAIN,,}"
[[ -n "$DOMAIN" ]] || { err "Домен не может быть пустым."; exit 1; }
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { err "Некорректное доменное имя."; exit 1; }

read -rp "Email для Let's Encrypt: " MAIL
[[ "$MAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] \
    || { err "Некорректный email."; exit 1; }

# --- 2.3 Ключ Pixabay ---
echo
echo -e "${BOLD}Ключ Pixabay API${NC} (нужен для наполнения витрины видео)."
echo "Взять: зарегистрируйтесь на pixabay.com, откройте https://pixabay.com/api/docs/"
echo "— ключ показан в разделе Parameters напротив параметра key."
echo "Ключ нигде не сохраняется и в скрипт не записывается."
echo

PIXABAY_KEY="${PIXABAY_API_KEY:-}"
if [[ -n "$PIXABAY_KEY" ]]; then
    log "Ключ взят из переменной окружения PIXABAY_API_KEY."
fi

TMP_DIR=$(mktemp -d)
chmod 700 "$TMP_DIR"

while true; do
    if [[ -z "$PIXABAY_KEY" ]]; then
        # -s: ключ не отображается и не попадёт в вывод при демонстрации экрана
        read -rsp "Ключ Pixabay API: " PIXABAY_KEY
        echo
    fi
    [[ -n "$PIXABAY_KEY" ]] || { err "Ключ не может быть пустым."; continue; }

    printf "    проверяю ключ… "
    CHECK=$(curl -sS --get "https://pixabay.com/api/videos/" \
        --data-urlencode "key=${PIXABAY_KEY}" \
        --data-urlencode "q=test" --data-urlencode "per_page=3" \
        --connect-timeout 15 --max-time 30 \
        -o "$TMP_DIR/check.json" -w '%{http_code}' 2>/dev/null || echo "000")

    if [[ "$CHECK" == "200" ]]; then
        echo -e "${GREEN}ключ рабочий${NC}"
        break
    elif [[ "$CHECK" == "400" || "$CHECK" == "401" || "$CHECK" == "403" ]]; then
        echo -e "${RED}отклонён (HTTP $CHECK)${NC}"
        head -c 200 "$TMP_DIR/check.json"; echo
        PIXABAY_KEY=""
    elif [[ "$CHECK" == "429" ]]; then
        echo -e "${RED}лимит запросов исчерпан${NC}"
        err "Pixabay разрешает 100 запросов за 60 секунд. Подождите минуту."
        PIXABAY_KEY=""
    else
        echo -e "${RED}нет ответа (HTTP $CHECK)${NC}"
        err "Проверьте, что с сервера есть доступ к pixabay.com."
        PIXABAY_KEY=""
    fi
done

# --- 2.4 Содержание витрины ---
BRAND_DEFAULT="$(echo "${DOMAIN%%.*}" | sed 's/^./\U&/') Studio"
read -rp "Название студии на сайте [$BRAND_DEFAULT]: " STUDIO_NAME
STUDIO_NAME="${STUDIO_NAME:-$BRAND_DEFAULT}"
STUDIO_NAME="$(esc "$STUDIO_NAME")"

echo "Тема видео: technology, architecture, city, nature, abstract, people…"
read -rp "Тема видео [architecture]: " SEARCH_QUERY
SEARCH_QUERY="${SEARCH_QUERY:-architecture}"

read -rp "Количество клипов [$VIDEO_COUNT]: " inp
[[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= 24 )) && VIDEO_COUNT="$inp"

# --- 2.5 PROXY protocol ---
echo
# Это самая частая причина «Reality работает, но маскировка не работает».
# nginx с proxy_protocol ЖДЁТ заголовок перед TLS. Xray его шлёт только
# при xver=1/2 в realitySettings (по умолчанию 0). При несовпадении
# nginx рвёт соединение мгновенно — то есть пробер видит разрыв
# вместо сайта ровно тогда, когда маскировка и нужна.
echo "PROXY protocol передаёт nginx реальный IP клиента (нужно для access-логов)."
echo "Требует xver=1 или 2 в конфиге Xray. При рассинхроне dest не работает."
read -rp "Включить PROXY protocol? (y/N): " pp_ans

if [[ "$pp_ans" =~ ^[yY]$ ]]; then
    USE_PP=1; XVER=2; LISTEN_EXTRA=" proxy_protocol"
    log "PROXY protocol включён → в Xray нужен \"xver\": 2"
else
    USE_PP=0; XVER=0; LISTEN_EXTRA=""
    log "PROXY protocol выключен → в Xray нужен \"xver\": 0"
fi

# --- 2.6 Защита от ботов ---
# Фильтрация по IP имеет смысл ТОЛЬКО при PROXY protocol: без него
# $remote_addr для каждого запроса равен 127.0.0.1, лимиты считают весь
# мир одним клиентом, а fail2ban банит localhost и рубит сайт целиком.
echo
if (( USE_PP )); then
    echo "Защита от ботов: лимиты запросов, ограничение скорости отдачи видео,"
    echo "бан сканеров через fail2ban ответом 403 (не через файрвол)."
    read -rp "Включить? (Y/n): " hd_ans
    [[ "$hd_ans" =~ ^[nN]$ ]] && HARDEN=0 || HARDEN=1
else
    HARDEN=0
    warn "PROXY protocol выключен — фильтрация по IP недоступна."
    warn "nginx видел бы все запросы как 127.0.0.1. Защита пропущена."
fi
(( HARDEN )) && log "Защита от ботов будет настроена."

# --- 2.7 Что делать с существующим сайтом ---
REBUILD_SITE=1
if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
    echo
    warn "Каталог $WEB_ROOT уже содержит сайт."
    read -rp "Пересобрать витрину заново? (y/N): " rb_ans
    [[ "$rb_ans" =~ ^[yY]$ ]] || { REBUILD_SITE=0; log "Оставляю существующий сайт."; }
fi

log "Ввод собран, дальше всё автоматически."

# ============================================================================
# 3. DNS
# ============================================================================
hdr "3. Проверка DNS"

EXT_IP4=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$EXT_IP4" ]] && EXT_IP4=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
[[ -n "$EXT_IP4" ]] || { err "Не удалось определить внешний IPv4."; exit 1; }
log "Внешний IPv4 сервера: $EXT_IP4"

EXT_IP6=$(curl -s6 --max-time 5 https://api64.ipify.org 2>/dev/null || true)
[[ "$EXT_IP6" == *:* ]] || EXT_IP6=""
[[ -n "$EXT_IP6" ]] && log "Внешний IPv6 сервера: $EXT_IP6"

# grep -qxF по списку строк, а НЕ сравнение строк: при CNAME-цепочке
# dig +short выдаёт несколько строк, и прямое сравнение ложно проваливается.
mapfile -t A_RECORDS < <(dig +short A "$DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
(( ${#A_RECORDS[@]} )) || { err "A-запись для $DOMAIN не найдена."; exit 1; }
log "A-записи $DOMAIN: ${A_RECORDS[*]}"

if printf '%s\n' "${A_RECORDS[@]}" | grep -qxF "$EXT_IP4"; then
    log "A-запись совпадает с IP сервера."
else
    err "A-запись НЕ указывает на этот сервер ($EXT_IP4). Валидация LE провалится."
    exit 1
fi

# Если AAAA есть, но ведёт не сюда, Let's Encrypt предпочтёт IPv6
# и валидация упадёт с невнятной ошибкой "Timeout during connect".
mapfile -t AAAA_RECORDS < <(dig +short AAAA "$DOMAIN" | grep ':' || true)
USE_IPV6=0
if (( ${#AAAA_RECORDS[@]} )); then
    log "AAAA-записи: ${AAAA_RECORDS[*]}"
    if [[ -n "$EXT_IP6" ]] && printf '%s\n' "${AAAA_RECORDS[@]}" | grep -qxF "$EXT_IP6"; then
        log "AAAA совпадает с IPv6 сервера."; USE_IPV6=1
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
# 4. FIREWALL
# ============================================================================
hdr "4. Проверка доступности порта 80"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    # Правило, добавленное профилем ("Nginx Full"), выводится под своим
    # именем, а не как 80/tcp — проверять надо оба варианта.
    if ufw status | grep -Eq '^(80/tcp|80|Nginx (Full|HTTP))\s+ALLOW'; then
        log "UFW: порт 80 разрешён."
    else
        warn "UFW активен, правило для 80/tcp не найдено."
        read -rp "Открыть 80/tcp сейчас? (Y/n): " ans
        if [[ ! "$ans" =~ ^[nN]$ ]]; then
            ufw allow 80/tcp >/dev/null; log "Порт 80/tcp открыт."
        else
            err "Без порта 80 webroot-валидация невозможна."; exit 1
        fi
    fi
    ufw status | grep -Eq '^(443/tcp|443|Nginx (Full|HTTPS))\s+ALLOW' \
        || { ufw allow 443/tcp >/dev/null; log "Порт 443/tcp открыт (для Xray)."; }
else
    log "UFW неактивен или не установлен — правила не нужны."
fi

# ============================================================================
# 5. СБОРКА ВИДЕОГАЛЕРЕИ
# ============================================================================
if (( REBUILD_SITE )); then
hdr "5. Сборка сайта-витрины"

# --- Бэкап старого ---
if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
    BK="/root/reality-dest-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$BK" -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")"
    log "Бэкап старого сайта: $BK"
fi

# Собираем рядом, чтобы при сбое не остаться с полупустым каталогом
STAGE="${WEB_ROOT}.new.$$"   # подхватывается trap cleanup при аварии
rm -rf "$STAGE"
mkdir -p "$STAGE/assets/video" "$STAGE/assets/img" "$STAGE/assets/css" \
         "$STAGE/.well-known/acme-challenge"

log "Запрашиваю каталог видео (тема: $SEARCH_QUERY, качество: $VIDEO_QUALITY)…"
HTTP_CODE=$(curl -sS --get "https://pixabay.com/api/videos/" \
    --data-urlencode "key=${PIXABAY_KEY}" \
    --data-urlencode "q=${SEARCH_QUERY}" \
    --data-urlencode "video_type=film" \
    --data-urlencode "per_page=${FETCH_POOL}" \
    --data-urlencode "safesearch=true" \
    --connect-timeout 15 --max-time 60 \
    -o "$TMP_DIR/api.json" -w '%{http_code}')

[[ "$HTTP_CODE" == "200" ]] || { err "API вернул HTTP $HTTP_CODE"; head -c 300 "$TMP_DIR/api.json"; exit 1; }
jq -e '.hits | type == "array"' "$TMP_DIR/api.json" >/dev/null \
    || { err "Неожиданная структура ответа API."; exit 1; }

# Сначала проверяем, нашёл ли API вообще что-нибудь: без этого пустая
# выдача выглядит как «слишком строгие фильтры», и пользователь начинает
# крутить пороги вместо того, чтобы исправить запрос.
TOTAL_HITS=$(jq '.hits | length' "$TMP_DIR/api.json")
if (( TOTAL_HITS == 0 )); then
    err "Pixabay не нашёл ни одного видео по запросу «$SEARCH_QUERY»."
    err "Проверьте написание (запрос должен быть на английском) и попробуйте"
    err "что-то более распространённое: architecture, city, nature, technology,"
    err "abstract, office, people, ocean, forest, traffic, workspace."
    rm -rf "$STAGE"; exit 1
fi
log "Найдено видео по запросу: $TOTAL_HITS"

# --- Отбор: длинные и тяжёлые клипы ---
# Pixabay отдаёт размер каждого варианта в байтах — фильтруем по нему,
# чтобы витрина весила достаточно и объём трафика к сайту выглядел
# естественно для видеогалереи.
MIN_SIZE_BYTES=$(( MIN_SIZE_MB * 1024 * 1024 ))

jq -c --arg q "$VIDEO_QUALITY" \
      --argjson mind "$MIN_DURATION" \
      --argjson mins "$MIN_SIZE_BYTES" '
    .hits[]
    | . as $h
    | ($h.videos[$q] // $h.videos.large // $h.videos.medium) as $v
    | select($v != null and $v.url != null)
    | select(($h.duration // 0) >= $mind)
    | select(($v.size // 0) >= $mins)
    | {url: $v.url,
       thumb: ($v.thumbnail // $h.videos.medium.thumbnail // ""),
       tags: $h.tags,
       dur: ($h.duration // 0),
       size: ($v.size // 0)}
' "$TMP_DIR/api.json" | shuf > "$TMP_DIR/pool.jsonl"

POOL_N=$(wc -l < "$TMP_DIR/pool.jsonl")
log "Подходящих клипов (от ${MIN_DURATION} с и от ${MIN_SIZE_MB} МБ): $POOL_N"

if (( POOL_N == 0 )); then
    # Показываем, какой именно порог виноват и что вообще есть в выдаче,
    # чтобы не подбирать значения вслепую.
    STATS=$(jq -r --arg q "$VIDEO_QUALITY" --argjson mind "$MIN_DURATION" \
                  --argjson mins "$MIN_SIZE_BYTES" '
        [ .hits[]
          | . as $h
          | (($h.videos[$q] // $h.videos.large // $h.videos.medium) // {}) as $v
          | select($v.url != null)
          | {d: ($h.duration // 0), s: ($v.size // 0)} ] as $all
        | { n:      ($all | length),
            bydur:  ([$all[] | select(.d >= $mind)] | length),
            bysize: ([$all[] | select(.s >= $mins)] | length),
            maxd:   ([$all[].d] | max // 0),
            maxs:   ([$all[].s] | max // 0) }
        | "\(.n) \(.bydur) \(.bysize) \(.maxd) \(.maxs)"
    ' "$TMP_DIR/api.json")
    read -r ST_N ST_DUR ST_SIZE ST_MAXD ST_MAXS <<<"$STATS"

    err "Ни один клип не прошёл фильтр."
    err "  клипов с рабочей ссылкой:      $ST_N"
    err "  из них длиннее ${MIN_DURATION} с:            $ST_DUR (самый длинный — ${ST_MAXD} с)"
    err "  из них тяжелее ${MIN_SIZE_MB} МБ:            $ST_SIZE (самый тяжёлый — $(( ST_MAXS / 1048576 )) МБ)"
    err ""
    if (( ST_MAXD < MIN_DURATION )); then
        err "Основная причина — длительность. Попробуйте:"
        err "  sudo MIN_DURATION=$(( ST_MAXD > 2 ? ST_MAXD - 2 : 1 )) $0"
    elif (( ST_MAXS < MIN_SIZE_BYTES )); then
        err "Основная причина — размер. Попробуйте:"
        err "  sudo MIN_SIZE_MB=$(( ST_MAXS / 1048576 > 1 ? ST_MAXS / 1048576 - 1 : 1 )) $0"
    else
        err "Пороги по отдельности проходимы, но вместе — нет. Попробуйте:"
        err "  sudo MIN_DURATION=8 MIN_SIZE_MB=2 $0"
    fi
    err "Либо возьмите более широкую тему: city, nature, architecture, ocean."
    rm -rf "$STAGE"; exit 1
fi
if (( POOL_N < VIDEO_COUNT )); then
    warn "Доступно только $POOL_N — витрина будет из $POOL_N клипов."
    VIDEO_COUNT="$POOL_N"
fi

declare -a V_FILE V_POSTER V_TITLE V_TAGS V_DUR V_DESC

TITLE_WORDS=(Northbound "Signal Drift" Halo "Field Notes" Interval "Quiet Machines"
             Overcast "Second Light" Longform Aperture "Slow Study" Meridian
             "Blue Hour" Threshold "Paper Cities" Kinetic Understory "Nine Frames"
             Groundwork "Late Shift" Tideline "Common Hours")
CLIENT_KIND=(Concept "Client work" "Studio test" "Spec piece" "Title sequence"
             "Brand film" "Internal R&amp;D" "Pitch reel")
DESC_TMPL=(
 "Снято на локации, смонтировано за два дня. Работали с темой «@TAG@» — искали ритм, а не сюжет."
 "Короткий этюд про @TAG@. Пробовали держать камеру статично и дать двигаться самому кадру."
 "Часть внутреннего цикла по фактурам. Здесь — @TAG@, свет естественный, грейд минимальный."
 "Материал снимался для другого проекта и не подошёл по темпу. Тема: @TAG@. Оставили как есть."
 "Тест новой оптики. Сюжет вторичен, важнее было понять, как ложится @TAG@ в широком плане."
 "Заготовка под фоновый луп. @TAG@, петля на восемь секунд, без резких склеек."
 "Из архива прошлого года. Снимали @TAG@, потом долго спорили про цвет. Вернулись к первому варианту."
 "Упражнение на монтажный ритм: @TAG@, три плана, ни одного диалога."
 "Делали для показа на конференции: @TAG@, экран 6 на 3 метра, звук отключён."
 "Один из первых материалов, снятых на новую камеру. Тема — @TAG@, всё в естественном свете."
)

ok=0; total_bytes=0
while IFS= read -r row && (( ok < VIDEO_COUNT )); do
    v_url=$(jq -r '.url'   <<<"$row")
    v_thm=$(jq -r '.thumb' <<<"$row")
    v_tag=$(jq -r '.tags'  <<<"$row")
    v_dur=$(jq -r '.dur'   <<<"$row")
    v_exp=$(jq -r '.size'  <<<"$row")

    slot=$(( ok + 1 ))
    vid_path="$STAGE/assets/video/clip-${slot}.mp4"

    printf "  [%d/%d] %s (%d с, ~%d МБ)… " \
        "$slot" "$VIDEO_COUNT" "$v_tag" "$v_dur" "$(( v_exp / 1048576 ))"

    if ! curl -fsSL --connect-timeout 15 --max-time 1800 -o "$vid_path" "$v_url"; then
        echo -e "${YELLOW}пропуск${NC}"; rm -f "$vid_path"; continue
    fi

    size=$(stat -c%s "$vid_path" 2>/dev/null || stat -f%z "$vid_path")
    if (( size < MIN_SIZE_BYTES / 2 )); then
        echo -e "${YELLOW}файл обрезан, выбрасываю${NC}"; rm -f "$vid_path"; continue
    fi
    echo -e "${GREEN}$(( size / 1048576 )) МБ${NC}"
    total_bytes=$(( total_bytes + size ))

    poster=""
    if [[ -n "$v_thm" && "$v_thm" != "null" ]]; then
        curl -fsSL --max-time 60 -o "$STAGE/assets/img/poster-${slot}.jpg" "$v_thm" \
            && poster="assets/img/poster-${slot}.jpg"
    fi

    first_tag=$(cut -d',' -f1 <<<"$v_tag" | sed 's/^ *//;s/ *$//')
    tmpl="${DESC_TMPL[RANDOM % ${#DESC_TMPL[@]}]}"
    # Склейка префикс+тег+суффикс, а не ${tmpl//@TAG@/...}: начиная с
    # bash 5.2 знак & в строке замены означает «совпавший шаблон», и тег
    # вида "steel & iron" подставился бы искажённым. Здесь подстановка
    # полностью буквальная на любой версии bash.
    tag_html=$(esc "$first_tag")
    desc="${tmpl%%@TAG@*}${tag_html}${tmpl#*@TAG@}"

    V_FILE+=("assets/video/clip-${slot}.mp4")
    V_POSTER+=("$poster")
    V_TITLE+=("${TITLE_WORDS[RANDOM % ${#TITLE_WORDS[@]}]}")
    V_TAGS+=("${CLIENT_KIND[RANDOM % ${#CLIENT_KIND[@]}]} · $(esc "$v_tag")")
    V_DUR+=("$v_dur")
    V_DESC+=("$desc")
    ok=$(( ok + 1 ))
done < "$TMP_DIR/pool.jsonl"

(( ok > 0 )) || { err "Не удалось скачать ни одного клипа."; rm -rf "$STAGE"; exit 1; }
log "Скачано клипов: $ok, суммарно $(( total_bytes / 1048576 )) МБ"

# --------------------------- CSS ---------------------------------------------
cat > "$STAGE/assets/css/site.css" <<'CSS'
:root{
  --ink:#161a1d; --ink-soft:#5b6469; --line:#dfe3e6;
  --paper:#fbfbf9; --panel:#ffffff; --accent:#2f4b7c; --measure:70ch;
}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);
  font:400 17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,
       "Helvetica Neue",Arial,sans-serif;}
img,video{display:block;max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
a:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.wrap{width:min(1080px,92vw);margin-inline:auto}
.site-head{border-bottom:1px solid var(--line);background:var(--panel)}
.site-head .wrap{display:flex;align-items:baseline;gap:2rem;padding:1.1rem 0;flex-wrap:wrap}
.brand{font-weight:700;letter-spacing:-.02em;font-size:1.05rem;color:var(--ink)}
.brand span{color:var(--ink-soft);font-weight:400}
.nav{margin-left:auto;display:flex;gap:1.4rem;font-size:.93rem}
.nav a{color:var(--ink-soft)}
.nav a[aria-current="page"]{color:var(--ink);font-weight:600}
.lede{padding:4.5rem 0 3rem;border-bottom:1px solid var(--line)}
.eyebrow{font-size:.75rem;letter-spacing:.14em;text-transform:uppercase;
  color:var(--ink-soft);margin:0 0 1rem}
.lede h1{font-size:clamp(1.9rem,4.6vw,3rem);line-height:1.12;letter-spacing:-.03em;
  margin:0 0 1rem;max-width:18ch;font-weight:700}
.lede p{margin:0;max-width:52ch;color:var(--ink-soft)}
.grid{display:grid;gap:2.5rem 2rem;padding:3rem 0;
  grid-template-columns:repeat(auto-fill,minmax(320px,1fr))}
.work{background:var(--panel);border:1px solid var(--line);border-radius:4px;
  overflow:hidden;display:flex;flex-direction:column}
.work video{width:100%;aspect-ratio:16/9;background:#0d0f10;object-fit:cover}
.work-body{padding:1.15rem 1.25rem 1.4rem}
.work-body h2{font-size:1.08rem;margin:0 0 .2rem;letter-spacing:-.01em}
.meta{font-size:.78rem;color:var(--ink-soft);margin:0 0 .7rem}
.work-body p{margin:0;font-size:.93rem;color:var(--ink-soft)}
.prose{padding:3.5rem 0;max-width:var(--measure)}
.prose h1{font-size:2rem;letter-spacing:-.025em;margin:0 0 1.2rem}
.prose h2{font-size:1.15rem;margin:2.2rem 0 .6rem}
.prose dl{display:grid;grid-template-columns:9rem 1fr;gap:.5rem 1rem;margin:1.5rem 0}
.prose dt{color:var(--ink-soft);font-size:.9rem}
.prose dd{margin:0}
.site-foot{border-top:1px solid var(--line);margin-top:2rem;padding:2.2rem 0 3rem;
  font-size:.85rem;color:var(--ink-soft)}
.site-foot p{margin:.25rem 0}
@media (prefers-reduced-motion:no-preference){
  .work{transition:border-color .2s ease}
  .work:hover{border-color:#b9c2c8}
}
@media (max-width:520px){
  .site-head .wrap{gap:.8rem}
  .nav{width:100%;margin-left:0;gap:1.1rem}
  .lede{padding:3rem 0 2.2rem}
}
CSS

# --------------------------- ФАВИКОН -----------------------------------------
cat > "$STAGE/assets/img/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="5" fill="#2f4b7c"/>
  <path d="M8 22V10h3.2l4.8 7.3L20.8 10H24v12h-3v-6.6l-4 6.1h-.6l-4-6.1V22z" fill="#fbfbf9"/>
</svg>
SVG

# Отсутствие /favicon.ico — заметная аномалия: настоящие сайты его имеют,
# а браузеры и сканеры запрашивают именно этот путь в корне.
python3 - "$STAGE/favicon.ico" <<'PY' && log "favicon.ico создан" || warn "favicon.ico не создан"
import struct, sys
W = H = 16
bg = (0x7c, 0x4b, 0x2f, 255); fg = (0xf9, 0xfb, 0xfb, 255)
glyph = [
 "................","................","..#..........#..","..##........##..",
 "..#.#......#.#..","..#..#....#..#..","..#...#..#...#..","..#....##....#..",
 "..#..........#..","..#..........#..","..#..........#..","..#..........#..",
 "................","................","................","................",
]
xor = b"".join(bytes(fg if glyph[y][x] == "#" else bg)
               for y in range(H-1, -1, -1) for x in range(W))
and_mask = b"\x00" * (H * 4)
dib = struct.pack("<IiiHHIIiiII", 40, W, H*2, 1, 32, 0, len(xor), 0, 0, 0, 0)
img = dib + xor + and_mask
ico = struct.pack("<HHH", 0, 1, 1) + \
      struct.pack("<BBBBHHII", W, H, 0, 0, 1, 32, len(img), 22) + img
open(sys.argv[1], "wb").write(ico)
PY

# --------------------------- СТРАНИЦЫ ----------------------------------------
YEAR=$(date +%Y); TODAY=$(date +%F)

emit_head() {
cat <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1 — ${STUDIO_NAME}</title>
<meta name="description" content="$2">
<link rel="canonical" href="https://${DOMAIN}$3">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/assets/img/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/css/site.css">
</head>
<body>
<header class="site-head"><div class="wrap">
  <a class="brand" href="/">${STUDIO_NAME} <span>/ студия</span></a>
  <nav class="nav">
    <a href="/"$([[ "$3" == "/" ]] && echo ' aria-current="page"')>Работы</a>
    <a href="/about.html"$([[ "$3" == "/about.html" ]] && echo ' aria-current="page"')>О студии</a>
    <a href="/contact.html"$([[ "$3" == "/contact.html" ]] && echo ' aria-current="page"')>Контакты</a>
  </nav>
</div></header>
EOF
}

emit_foot() {
cat <<EOF
<footer class="site-foot"><div class="wrap">
  <p>${STUDIO_NAME} — монтаж, съёмка, motion-графика.</p>
  <p>© ${YEAR}. Материалы витрины — по лицензии Pixabay Content License.</p>
</div></footer>
</body>
</html>
EOF
}

{
emit_head "Работы" "Избранные видеоработы: короткие формы, титры, фоновые лупы." "/"
cat <<EOF
<main>
<section class="lede"><div class="wrap">
  <p class="eyebrow">Избранное · ${YEAR}</p>
  <h1>Небольшая студия, которая снимает и монтирует короткие формы</h1>
  <p>Ниже — часть архива за последние сезоны: тесты оптики, заготовки под фон,
     несколько клиентских работ, которые разрешили показать.</p>
</div></section>
<div class="wrap"><div class="grid">
EOF
for i in "${!V_FILE[@]}"; do
    dur="${V_DUR[$i]}"; dur_txt=""
    (( dur > 0 )) && dur_txt=" · $(printf '%d:%02d' $((dur/60)) $((dur%60)))"
    poster_attr=""
    [[ -n "${V_POSTER[$i]}" ]] && poster_attr=" poster=\"/${V_POSTER[$i]}\""
cat <<EOF
  <article class="work">
    <video controls preload="metadata" playsinline$poster_attr>
      <source src="/${V_FILE[$i]}" type="video/mp4">
      Ваш браузер не умеет проигрывать это видео.
    </video>
    <div class="work-body">
      <h2>${V_TITLE[$i]}</h2>
      <p class="meta">${V_TAGS[$i]}${dur_txt}</p>
      <p>${V_DESC[$i]}</p>
    </div>
  </article>
EOF
done
echo "</div></div></main>"
emit_foot
} > "$STAGE/index.html"

{
emit_head "О студии" "Кто мы, как работаем и на чём снимаем." "/about.html"
cat <<EOF
<main class="wrap"><div class="prose">
<h1>О студии</h1>
<p>${STUDIO_NAME} — это два монтажёра и оператор. Мы делаем короткие видео:
   титры, вставки, фоновые лупы для экранов на мероприятиях, изредка —
   полноценные ролики под ключ.</p>
<h2>Как устроена работа</h2>
<p>Обычный проект занимает от недели до месяца. Начинаем с раскадровки,
   дальше съёмка или подбор материала из архива, потом монтаж и цвет.
   Правки входят в стоимость, отдельно считаем только пересъёмку.</p>
<h2>Техника</h2>
<dl>
  <dt>Камеры</dt><dd>Sony FX3, Blackmagic Pocket 6K</dd>
  <dt>Оптика</dt><dd>Sigma Art, набор винтажных Helios</dd>
  <dt>Монтаж</dt><dd>DaVinci Resolve Studio</dd>
  <dt>Графика</dt><dd>After Effects, Blender</dd>
</dl>
<h2>Что мы не делаем</h2>
<p>Не снимаем свадьбы и мероприятия «под ключ» с несколькими камерами —
   для этого есть коллеги, которым мы передаём такие запросы.</p>
</div></main>
EOF
emit_foot
} > "$STAGE/about.html"

{
emit_head "Контакты" "Как с нами связаться и что прислать в первом письме." "/contact.html"
cat <<EOF
<main class="wrap"><div class="prose">
<h1>Контакты</h1>
<p>Пишите на почту — отвечаем в течение рабочего дня.</p>
<dl>
  <dt>Почта</dt><dd><a href="mailto:studio@${DOMAIN}">studio@${DOMAIN}</a></dd>
  <dt>Часы</dt><dd>Пн–Пт, 10:00–19:00</dd>
</dl>
<h2>Что прислать в первом письме</h2>
<p>Чтобы быстрее сориентировать по срокам и бюджету, опишите задачу в двух-трёх
   абзацах: для чего ролик, где будет показан, есть ли дедлайн и референсы.
   Готовый бриф не нужен — разберёмся вместе.</p>
<h2>Стажировки</h2>
<p>Раз в полгода берём одного человека на монтаж. Набор объявляем здесь же,
   резюме заранее не собираем.</p>
</div></main>
EOF
emit_foot
} > "$STAGE/contact.html"

{
emit_head "Страница не найдена" "Такой страницы нет." "/404.html"
cat <<EOF
<main class="wrap"><div class="prose">
<h1>Страница не найдена</h1>
<p>Ссылка ведёт в никуда — возможно, работу убрали из витрины.
   Загляните в <a href="/">список работ</a> или напишите нам.</p>
</div></main>
EOF
emit_foot
} > "$STAGE/404.html"

cat > "$STAGE/robots.txt" <<EOF
User-agent: *
Allow: /
Disallow: /assets/video/

Sitemap: https://${DOMAIN}/sitemap.xml
EOF

cat > "$STAGE/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc><lastmod>${TODAY}</lastmod><priority>1.0</priority></url>
  <url><loc>https://${DOMAIN}/about.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/contact.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
</urlset>
EOF

# --- Подмена: mv на том же разделе мгновенный, сайт не «мигает» ---
if [[ -d "$WEB_ROOT" ]]; then
    # Если certbot прямо сейчас проходит валидацию, токены нужно сохранить
    if compgen -G "$WEB_ROOT/.well-known/acme-challenge/*" >/dev/null; then
        cp -a "$WEB_ROOT/.well-known/acme-challenge/." "$STAGE/.well-known/acme-challenge/"
    fi
    rm -rf "${WEB_ROOT:?}"
fi
mv "$STAGE" "$WEB_ROOT"
STAGE=""
SITE_SIZE=$(du -sh "$WEB_ROOT" | cut -f1)
log "Витрина собрана: $SITE_SIZE"

fi  # REBUILD_SITE

mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
chown -R www-data:www-data "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +
log "Права выставлены."

# ============================================================================
# 6. NGINX: ЭТАП 1 (HTTP для ACME)
# ============================================================================
# --- Зоны лимитов: только http-контекст, поэтому отдельным файлом ---
LIMITS_CONF="/etc/nginx/conf.d/00-${LOG_PREFIX}-limits.conf"
DENY_SNIPPET="/etc/nginx/snippets/${LOG_PREFIX}-deny.conf"

if (( HARDEN )); then
    mkdir -p /etc/nginx/snippets
    # Файл должен существовать до включения в конфиг, иначе nginx не стартует
    [[ -f "$DENY_SNIPPET" ]] || printf '# Управляется fail2ban. Правки будут перезаписаны.\n' > "$DENY_SNIPPET"

    cat > "$LIMITS_CONF" <<EOF
# Managed by reality-dest-setup.sh

# Лимиты на IP клиента. Работают корректно только с proxy_protocol +
# real_ip_header, иначе всё схлопнется в один адрес 127.0.0.1.
limit_req_zone  \$binary_remote_addr zone=${SAFE_PREFIX}_pages:10m rate=60r/m;
limit_req_zone  \$binary_remote_addr zone=${SAFE_PREFIX}_video:10m rate=20r/m;
limit_conn_zone \$binary_remote_addr zone=${SAFE_PREFIX}_conn:10m;

# Инструменты массового сканирования интернета. Цензорские пробер-боты
# сюда не попадут — они мимикрируют под браузер, и это нормально:
# задача списка не в маскировке, а в экономии трафика на видео.
map \$http_user_agent \$${SAFE_PREFIX}_bad_ua {
    default 0;
    ""      1;
    "~*(zgrab|masscan|nmap|nikto|sqlmap|dirbuster|gobuster|wpscan|hydra|nuclei|censys|shodan)" 1;
}
EOF
    log "Зоны лимитов: $LIMITS_CONF"
fi

hdr "6. Конфигурация nginx (этап 1: HTTP)"

# Чужие конфиги в sites-enabled — источник конфликтов по именам зон,
# default_server и server_name. Лучше увидеть их заранее.
mapfile -t OTHER_CONFS < <(find /etc/nginx/sites-enabled -mindepth 1 \
    ! -name "$(basename "$NGINX_CONF")" ! -name default -printf '%f\n' 2>/dev/null || true)
if (( ${#OTHER_CONFS[@]} )); then
    warn "В sites-enabled есть другие конфиги: ${OTHER_CONFS[*]}"
    warn "Если nginx -t упадёт на конфликте — смотрите в них."
    for f in "${OTHER_CONFS[@]}"; do
        if grep -q "listen.*127\.0\.0\.1:$SPORT" "/etc/nginx/sites-enabled/$f" 2>/dev/null; then
            err "Конфиг $f уже слушает 127.0.0.1:$SPORT — выберите другой порт."
            exit 1
        fi
        if grep -qE "server_name\s+[^;]*\b${DOMAIN//./\\.}\b" "/etc/nginx/sites-enabled/$f" 2>/dev/null; then
            warn "Конфиг $f тоже обслуживает $DOMAIN — возможен conflicting server name."
        fi
    done
fi

LISTEN80_V6=""
(( USE_IPV6 )) && LISTEN80_V6="  listen [::]:80;"

# Конфиг пишется ЦЕЛИКОМ (>), а не дописывается (>>).
# Иначе при повторном запуске добавится второй SSL-блок к существующему,
# и nginx поднимется с conflicting server name.
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

# default-конфиг убираем только при штатной установке: при параллельном
# тесте (свой NGINX_CONF) чужие симлинки трогать нельзя.
if [[ "$NGINX_CONF" == "/etc/nginx/sites-available/reality-dest.conf" ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi
ln -sf "$NGINX_CONF" "$NGINX_LINK"

if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    log "nginx перезагружен (HTTP-этап)."
else
    err "Ошибка конфигурации nginx:"; nginx -t; exit 1
fi

# ============================================================================
# 7. СЕРТИФИКАТ
# ============================================================================
hdr "7. Сертификат Let's Encrypt"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
    EXP=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)
    log "Сертификат уже существует, истекает: $EXP"
else
    CB_EXTRA=()
    if (( CERTBOT_STAGING )); then
        CB_EXTRA+=(--test-cert)
        warn "STAGING: сертификат будет нерабочим для браузеров (только тест)."
    fi
    log "Запрашиваю сертификат для $DOMAIN…"
    certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" \
        --agree-tos -m "$MAIL" --non-interactive --no-eff-email \
        ${CB_EXTRA[@]+"${CB_EXTRA[@]}"} \
        || { err "Certbot не смог выпустить сертификат. Логи: /var/log/letsencrypt/"; exit 1; }
    [[ -f "$CERT_DIR/fullchain.pem" ]] || { err "Сертификат не появился."; exit 1; }
    log "Сертификат выпущен."
fi

# --- DEPLOY HOOK: без него всё сломается на 90-й день ---
# certonly --webroot не записывает installer в renewal-конфиг. Certbot
# успешно продлит файл на диске, но nginx продолжит держать в памяти
# старый сертификат. TLS на dest сломается, а вместе с ним и Reality —
# при том, что `certbot certificates` покажет всё зелёным.
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
# 8. NGINX: ЭТАП 2 (полный конфиг с TLS)
# ============================================================================
hdr "8. Конфигурация nginx (этап 2: TLS)"

if [[ "$HTTP2_STYLE" == "new" ]]; then
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl${LISTEN_EXTRA} default_server;
  http2 on;"
else
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl http2${LISTEN_EXTRA} default_server;"
fi

# Копию текущего конфига держим до успешной проверки — на случай отката
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$NGINX_CONF.prev"

# --- Блок защиты, подставляется в server{} dest ---
HARDEN_SERVER=""
HARDEN_VIDEO=""
HARDEN_STATIC=""
if (( HARDEN )); then
    HARDEN_SERVER="  include $DENY_SNIPPET;

  # Лимиты отдают 429 — обычный ответ перегруженного сайта.
  # Возврат 444 (обрыв без ответа) здесь недопустим: нормальный
  # веб-сервер так себя не ведёт, и это выдало бы маскировку.
  limit_req_status 429;
  limit_conn_status 429;
  limit_req  zone=${SAFE_PREFIX}_pages burst=30 nodelay;
  limit_conn ${SAFE_PREFIX}_conn 16;

  if (\$${SAFE_PREFIX}_bad_ua) { return 403; }

  # Статике незачем принимать тело запроса
  client_max_body_size 1k;
  client_body_timeout 10s;
  client_header_timeout 10s;"

    HARDEN_VIDEO="    limit_req  zone=${SAFE_PREFIX}_video burst=10 nodelay;
    limit_conn ${SAFE_PREFIX}_conn 4;
    # Первые 2 МБ отдаём на полной скорости (чтобы плеер быстро стартовал),
    # дальше режем до 4 МБ/с на соединение: для просмотра 1080p с запасом,
    # для бота, качающего витрину в 20 потоков, — существенный тормоз.
    limit_rate_after 2m;
    limit_rate 4m;"

    HARDEN_STATIC="    limit_req zone=${SAFE_PREFIX}_pages burst=40 nodelay;"
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
  # Имя зоны уникальное, а не общепринятое "SSL": nginx требует, чтобы
  # одноимённая зона во ВСЕХ подключённых конфигах имела один размер,
  # и чужой сайт с shared:SSL:1m уронил бы проверку конфигурации.
  ssl_session_cache shared:reality_dest:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  # OCSP stapling намеренно отключён: Let's Encrypt сворачивает
  # поддержку OCSP, и включённый stapling даёт ошибки в логах.

  add_header Strict-Transport-Security "max-age=31536000" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

$REALIP_BLOCK
$HARDEN_SERVER

  # Отдача видео: sendfile + большие чанки, иначе на десятках мегабайт
  # nginx упирается в системные вызовы, а не в канал.
  sendfile on;
  tcp_nopush on;
  output_buffers 4 256k;

  access_log /var/log/nginx/${LOG_PREFIX}.access.log;
  error_log  /var/log/nginx/${LOG_PREFIX}.error.log warn;

  root $WEB_ROOT;
  index index.html index.htm;

  error_page 404 /404.html;

  location / {
    try_files \$uri \$uri/ \$uri.html =404;
  }

  location = /404.html {
    internal;
  }

  # ВАЖНО: add_header в location полностью отменяет унаследованные
  # заголовки из server{}, поэтому их приходится повторять здесь.
  location /assets/video/ {
$HARDEN_VIDEO
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "public, max-age=604800" always;
    # Accept-Ranges nginx выставляет сам для статики — плеер сможет перематывать.
  }

  location ~* \.(css|svg|jpg|jpeg|png|ico)$ {
$HARDEN_STATIC
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "public, max-age=86400" always;
  }

  location ~ /\.(?!well-known) {
    deny all;
  }

  # Типовые цели сканеров. Отдаём 404 — ровно то, что вернул бы обычный
  # статический сайт. Ценность не в блокировке, а в том, что эти запросы
  # попадают в лог одной приметой и по ним работает fail2ban.
  location ~* ^/(wp-admin|wp-login|wordpress|xmlrpc\.php|phpmyadmin|pma|administrator|admin\.php|\.env|\.git|config\.php|vendor/|cgi-bin/|backup\.(sql|zip|tar\.gz)) {
    return 404;
  }
}
EOF

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log "nginx перезагружен (TLS активен)."
else
    err "Ошибка в TLS-конфигурации:"
    nginx -t || true
    # Оставлять на диске конфиг, который не проходит проверку, опасно:
    # работающий nginx держит старый в памяти и всё выглядит нормально,
    # но при первом же рестарте или перезагрузке сервер не поднимется.
    if [[ -f "$NGINX_CONF.prev" ]]; then
        mv "$NGINX_CONF.prev" "$NGINX_CONF"
        err "Конфиг откачен к предыдущей рабочей версии."
    else
        rm -f "$NGINX_LINK"
        err "Конфиг отключён из sites-enabled, чтобы nginx мог стартовать."
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    err "Разберитесь с ошибкой выше и запустите скрипт заново."
    exit 1
fi
rm -f "$NGINX_CONF.prev"

# ============================================================================
# 9. ПРОВЕРКИ
# ============================================================================
# ============================================================================
# 9. FAIL2BAN
# ============================================================================
if (( HARDEN )); then
hdr "9. Настройка fail2ban"

dpkg -s fail2ban &>/dev/null || {
    log "Устанавливаю fail2ban…"
    apt-get install -y -qq fail2ban >/dev/null
}

# --- Фильтр ---
# Ловим тех, кто перебирает несуществующие пути или упирается в лимиты.
# <HOST> — первое поле combined-лога, то есть $remote_addr; благодаря
# real_ip_header там реальный IP клиента, а не 127.0.0.1 от Xray.
cat > "/etc/fail2ban/filter.d/${LOG_PREFIX}.conf" <<'F2BEOF'
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^]]+\] "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH|PROPFIND|TRACE|CONNECT)[^"]*" (403|404|429) 
            ^<HOST> \S+ \S+ \[[^]]+\] "[^"]*" 400 
ignoreregex = ^<HOST> \S+ \S+ \[[^]]+\] "GET /(favicon\.ico|robots\.txt|sitemap\.xml|apple-touch-icon[^ ]*)
datepattern = ^[^\[]*\[({DATE})
              {^LN-BEG}
F2BEOF

# --- Действие: бан средствами nginx, НЕ файрвола ---
# Через iptables банить нельзя: на :443 приходят и легитимные клиенты
# Reality, а полный обрыв TLS вместо HTTP-ответа — заметная аномалия,
# которой у настоящего сайта не бывает. Ответ 403 выглядит естественно.
cat > "/etc/fail2ban/action.d/${LOG_PREFIX}-deny.conf" <<ACTEOF
[Definition]
actionstart = if [ ! -f ${DENY_SNIPPET} ]; then printf '# Managed by fail2ban\n' > ${DENY_SNIPPET}; fi
actionstop  = printf '# Managed by fail2ban\n' > ${DENY_SNIPPET}
              nginx -t && systemctl reload nginx
actioncheck =
actionban   = printf 'deny <ip>;\n' >> ${DENY_SNIPPET}
              nginx -t && systemctl reload nginx
actionunban = sed -i "\\|^deny <ip>;\$|d" ${DENY_SNIPPET}
              nginx -t && systemctl reload nginx
ACTEOF

# --- Джейл ---
cat > "/etc/fail2ban/jail.d/${LOG_PREFIX}.conf" <<JAILEOF
[${LOG_PREFIX}]
enabled  = true
filter   = ${LOG_PREFIX}
logpath  = /var/log/nginx/${LOG_PREFIX}.access.log
action   = ${LOG_PREFIX}-deny
# Порог с запасом: у живого посетителя пара 404 набегает легко,
# у сканера — десятки за минуту.
maxretry = 20
findtime = 300
bantime  = 86400
JAILEOF

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

sleep 2
if fail2ban-client status "${LOG_PREFIX}" >/dev/null 2>&1; then
    log "Джейл ${LOG_PREFIX} активен."
else
    warn "Джейл не поднялся. Смотрите: journalctl -u fail2ban -n 30"
    warn "И проверьте фильтр: fail2ban-regex /var/log/nginx/${LOG_PREFIX}.access.log /etc/fail2ban/filter.d/${LOG_PREFIX}.conf"
fi
fi

hdr "10. Проверка работоспособности"

sleep 1
FAILED=0

curl_dest() {
    local path="$1"; shift
    local args=(-ks --max-time 15 --resolve "$DOMAIN:$SPORT:127.0.0.1")
    (( USE_PP )) && args+=(--haproxy-protocol)
    curl "${args[@]}" "$@" "https://$DOMAIN:$SPORT$path"
}

# --- главная ---
CODE=$(curl_dest "/" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
[[ -n "$CODE" ]] || CODE=000
if [[ "$CODE" == "200" ]]; then
    log "Главная отдаётся: HTTP $CODE"
else
    err "Главная вернула '$CODE' вместо 200 — маскировка НЕ работает."
    err "Смотрите: tail -20 /var/log/nginx/${LOG_PREFIX}.error.log"
    FAILED=1
fi

# --- видео и Range ---
# Без 206 плеер не перематывает — для видеогалереи это заметный дефект.
# `|| true` в конце обязателен: curl -w не печатает перевод строки, read
# упирается в EOF и возвращает 1, а при set -e это обрывает скрипт.
VID_OUT=$(curl_dest "/assets/video/clip-1.mp4" -r 0-1023 \
    -o /dev/null -w '%{http_code} %{content_type}' 2>/dev/null || true)
read -r CODE CTYPE <<<"$VID_OUT" || true
[[ -n "${CODE:-}" ]] || { CODE=000; CTYPE="-"; }
[[ -n "${CTYPE:-}" ]] || CTYPE="-"
if [[ "$CODE" == "206" && "$CTYPE" == video/mp4* ]]; then
    log "Видео отдаётся с Range: HTTP $CODE, $CTYPE"
else
    err "Видео: получено '$CODE $CTYPE', ожидалось '206 video/mp4'"
    FAILED=1
fi

# --- favicon ---
CODE=$(curl_dest "/favicon.ico" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
[[ "$CODE" == "200" ]] && log "favicon.ico отдаётся" || warn "favicon.ico вернул '$CODE'"

# --- ALPN ---
ALPN=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:$SPORT" \
        -servername "$DOMAIN" -alpn h2 2>/dev/null | grep -i 'ALPN protocol' || true)
if [[ "$ALPN" == *h2* ]]; then
    log "ALPN: h2 согласован (как у настоящего сайта)."
elif (( USE_PP )); then
    warn "ALPN не проверить при включённом proxy_protocol — это нормально."
else
    warn "ALPN h2 не согласован. Клиенты Reality шлют h2 — профиль будет отличаться."
    FAILED=1
fi

# --- снаружи по HTTP ---
EXT=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://$DOMAIN/" 2>/dev/null || true)
[[ "$EXT" =~ ^(301|302|200)$ ]] && log "Сайт доступен снаружи по HTTP: $EXT" \
    || warn "Снаружи по HTTP получен код '$EXT'."

# --- лимиты не должны мешать обычному посетителю ---
if (( HARDEN )); then
    RL_FAIL=0
    for _ in 1 2 3 4 5 6 7 8; do
        C=$(curl_dest "/" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
        [[ "$C" == "200" ]] || RL_FAIL=1
    done
    if (( RL_FAIL )); then
        err "Восемь обычных запросов подряд упёрлись в лимит — он слишком строгий."
        err "Поднимите rate в $LIMITS_CONF и перезагрузите nginx."
        FAILED=1
    else
        log "Лимиты не мешают нормальному просмотру (8 запросов подряд — 200)."
    fi
fi

# --- продление сертификата ---
if (( CERTBOT_STAGING )); then
    warn "STAGING: проверка продления пропущена (сертификат тестовый)."
else
  log "Проверяю продление сертификата (--dry-run, staging LE)…"
  if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
    log "Продление сертификата работает."
  else
    err "certbot renew --dry-run ПРОВАЛИЛСЯ. Сертификат не обновится автоматически!"
    err "Разберитесь сейчас: certbot renew --dry-run"
    FAILED=1
  fi
fi

# ============================================================================
# ИТОГ
# ============================================================================
unset PIXABAY_KEY

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
(( REBUILD_SITE )) && printf "  %-14s ${CYAN}%s (%s клипов)${NC}\n" "Витрина:" "${SITE_SIZE:-?}" "${ok:-?}"
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

if (( HARDEN )); then
printf "${BOLD}Защита от ботов:${NC}\n"
printf "  %-22s %s\n" "Зоны лимитов:"  "$LIMITS_CONF"
printf "  %-22s %s\n" "Список банов:"  "$DENY_SNIPPET"
printf "  %-22s %s\n" "Джейл:"         "/etc/fail2ban/jail.d/${LOG_PREFIX}.conf"
echo "  Кого забанили:       fail2ban-client status ${LOG_PREFIX}"
echo "  Разбанить:           fail2ban-client set ${LOG_PREFIX} unbanip <IP>"
echo "  Проверить фильтр:    fail2ban-regex /var/log/nginx/${LOG_PREFIX}.access.log \\"
echo "                         /etc/fail2ban/filter.d/${LOG_PREFIX}.conf"
echo
fi

printf "${BOLD}Полезные команды:${NC}\n"
echo "  Кто пробирует сайт:  tail -f /var/log/nginx/${LOG_PREFIX}.access.log"
echo "  Ошибки dest:         tail -f /var/log/nginx/${LOG_PREFIX}.error.log"
echo "  Срок сертификата:    certbot certificates"
echo "  Тест продления:      certbot renew --dry-run"
echo "  Обновить витрину:    $0   (ответить 'y' на вопрос о пересборке)"
echo

printf "${YELLOW}${BOLD}Дальше — вручную:${NC}\n"
echo "  1. Ключи Xray: xray x25519  и  openssl rand -hex 8"
echo "  2. Порт 80 должен остаться открытым — иначе продление не пройдёт."
echo "  3. Пробегитесь по текстам в $WEB_ROOT/about.html и contact.html:"
echo "     подставьте что-то своё, если несколько установок делят один шаблон."
echo
