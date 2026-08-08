#!/usr/bin/env bash
#
# ============================================================================
#  Сайт-маскировка (dest) для VLESS Reality: видеогалерея вместо заглушки.
#  Debian 11+ / Ubuntu 20.04+
# ============================================================================
#
#  Что делает:
#    - собирает сайт студии моушн-дизайна и наполняет его видео с Pixabay
#    - ОФОРМЛЕНИЕ И ТЕКСТЫ УНИКАЛЬНЫ ДЛЯ КАЖДОГО ДОМЕНА: палитра, шрифты,
#      имена классов, имя css-файла, структура страниц и абзацы выводятся
#      из хеша домена, поэтому две установки нельзя связать по хешу файла
#    - поднимает nginx с этим сайтом на 127.0.0.1:<порт>
#    - выпускает сертификат Let's Encrypt и настраивает автоперезагрузку
#      nginx после продления (без этого TLS ломается на 90-й день)
#    - определяет версию nginx и подбирает корректный синтаксис http2
#    - настраивает лимиты и fail2ban так, чтобы они не мешали живому
#      посетителю (пороги рассчитаны на реальный профиль загрузки страницы)
#    - идемпотентен: повторный запуск не ломает конфиг, отключение защиты
#      полностью снимает все её артефакты
#
#  Ключ Pixabay спрашивается интерактивно, нигде не сохраняется и не
#  передаётся в argv (не виден в `ps`).
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
# (5 сертификатов на один набор доменов в неделю).
CERTBOT_STAGING="${CERTBOT_STAGING:-0}"
LOG_PREFIX="${LOG_PREFIX:-reality-dest}"
# Имена переменных и зон nginx допускают только [A-Za-z0-9_]: дефис из
# LOG_PREFIX превратил бы $reality-dest_bad_ua в "$reality" плюс мусор.
SAFE_PREFIX="${LOG_PREFIX//[^a-zA-Z0-9]/_}"

LIMITS_CONF="/etc/nginx/conf.d/00-${LOG_PREFIX}-limits.conf"
DENY_SNIPPET="/etc/nginx/snippets/${LOG_PREFIX}-deny.conf"
HEAD_SNIPPET="/etc/nginx/snippets/${LOG_PREFIX}-headers.conf"
RELOAD_HELPER="/usr/local/sbin/${LOG_PREFIX}-nginx-reload"
F2B_FILTER="/etc/fail2ban/filter.d/${LOG_PREFIX}.conf"
F2B_ACTION="/etc/fail2ban/action.d/${LOG_PREFIX}-deny.conf"
F2B_JAIL="/etc/fail2ban/jail.d/${LOG_PREFIX}.conf"

# --- Параметры видеогалереи (можно переопределить через окружение) ---
VIDEO_COUNT="${VIDEO_COUNT:-8}"          # сколько клипов на витрине
VIDEO_QUALITY="${VIDEO_QUALITY:-large}"  # large = 1080p
MIN_DURATION="${MIN_DURATION:-15}"       # секунд, короче — отбрасываем
MIN_SIZE_MB="${MIN_SIZE_MB:-4}"          # МБ, легче — отбрасываем
FETCH_POOL=60                            # кандидатов запросить у API
MB_PER_CLIP=120                          # оценка сверху для расчёта места

TMP_DIR=""; STAGE=""; OLD_ROOT=""
cleanup() {
    [[ -n "$TMP_DIR"  && -d "$TMP_DIR"  ]] && rm -rf "$TMP_DIR"
    [[ -n "$STAGE"    && -d "$STAGE"    ]] && rm -rf "$STAGE"
    [[ -n "$OLD_ROOT" && -d "$OLD_ROOT" ]] && rm -rf "$OLD_ROOT"
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

free_mb() {
    df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}' || df -Pm / | awk 'NR==2{print $4}'
}
FREE_MB=$(free_mb "$(dirname "$WEB_ROOT")")
log "Свободно на разделе с сайтом: ${FREE_MB} МБ"

# ============================================================================
# 1. ПАКЕТЫ
# ============================================================================
hdr "1. Установка пакетов"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# python3-certbot-nginx не нужен: выпуск идёт через --webroot, конфиг
# nginx пишем сами. Лишний плагин только добавляет поверхность обновлений.
PKGS=(dnsutils iproute2 nginx certbot jq curl wget openssl
      ca-certificates coreutils util-linux tar python3)
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

# --- Детерминированный «отпечаток» установки ---
# Всё оформление выводится из хеша домена. Один и тот же домен даёт один
# и тот же сайт (повторный запуск не меняет вид), разные домены — разные
# палитру, шрифты, имена классов, имя css-файла, набор страниц и тексты.
# Это главная защита от «все dest-сайты этого скрипта одинаковые».
SEED_BASE=$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-32)
seed_idx() { local h; h=$(printf '%s|%s' "$SEED_BASE" "$1" | sha256sum | cut -c1-6); echo $(( 16#$h )); }
pick() { local salt="$1"; shift; local -a a=("$@"); echo "${a[$(( $(seed_idx "$salt") % ${#a[@]} ))]}"; }

# --- 2.3 Ключ Pixabay ---
echo
echo -e "${BOLD}Ключ Pixabay API${NC} (нужен для наполнения витрины видео)."
echo "Взять: зарегистрируйтесь на pixabay.com, откройте https://pixabay.com/api/docs/"
echo "— ключ показан в разделе Parameters напротив параметра key."
echo "Ключ нигде не сохраняется и не передаётся в командной строке."
echo

PIXABAY_KEY="${PIXABAY_API_KEY:-}"
if [[ -n "$PIXABAY_KEY" ]]; then
    log "Ключ взят из переменной окружения PIXABAY_API_KEY."
fi

TMP_DIR=$(mktemp -d)
chmod 700 "$TMP_DIR"
KEYFILE="$TMP_DIR/curl.key"

# Ключ уходит в curl через файл конфигурации, а не через argv: аргументы
# процесса видны любому локальному пользователю в `ps auxww` и в /proc
# всё время, пока идёт скачивание витрины.
write_keyfile() {
    ( umask 077; printf 'data-urlencode = "key=%s"\n' "$PIXABAY_KEY" > "$KEYFILE" )
}

while true; do
    if [[ -z "$PIXABAY_KEY" ]]; then
        # -s: ключ не отображается и не попадёт в вывод при демонстрации экрана
        read -rsp "Ключ Pixabay API: " PIXABAY_KEY
        echo
    fi
    [[ -n "$PIXABAY_KEY" ]] || { err "Ключ не может быть пустым."; continue; }
    write_keyfile

    printf "    проверяю ключ… "
    CHECK=$(curl -sS --get -K "$KEYFILE" "https://pixabay.com/api/videos/" \
        --data-urlencode "q=test" --data-urlencode "per_page=3" \
        --connect-timeout 15 --max-time 30 \
        -o "$TMP_DIR/check.json" -w '%{http_code}' 2>/dev/null) || CHECK="000"

    case "$CHECK" in
        200)
            echo -e "${GREEN}ключ рабочий${NC}"; break ;;
        400|401|403)
            echo -e "${RED}отклонён (HTTP $CHECK)${NC}"
            head -c 200 "$TMP_DIR/check.json" 2>/dev/null; echo
            PIXABAY_KEY="" ;;
        429)
            echo -e "${RED}лимит запросов исчерпан${NC}"
            err "Pixabay разрешает 100 запросов за 60 секунд. Подождите минуту."
            PIXABAY_KEY="" ;;
        *)
            echo -e "${RED}нет ответа (HTTP $CHECK)${NC}"
            err "Проверьте, что с сервера есть доступ к pixabay.com."
            PIXABAY_KEY="" ;;
    esac
done

# --- 2.4 Содержание витрины ---
BRAND_DEFAULT="$(echo "${DOMAIN%%.*}" | sed 's/^./\U&/') $(pick brandword Studio Films Motion Works Picture)"
read -rp "Название студии на сайте [$BRAND_DEFAULT]: " STUDIO_NAME
STUDIO_NAME="${STUDIO_NAME:-$BRAND_DEFAULT}"
STUDIO_RAW="$STUDIO_NAME"
STUDIO_NAME="$(esc "$STUDIO_NAME")"
BRAND_INITIAL="$(printf '%s' "$STUDIO_RAW" | cut -c1 | tr '[:lower:]' '[:upper:]')"
[[ "$BRAND_INITIAL" =~ ^[A-Za-zА-Яа-я0-9]$ ]] || BRAND_INITIAL="M"

echo
echo "Язык сайта. Он не обязан совпадать с языком этого скрипта: важно, чтобы"
echo "сайт выглядел естественно для домена и его вероятных посетителей."
read -rp "Язык содержимого сайта (en/ru) [en]: " lang_in
SITE_LANG="${lang_in:-en}"
[[ "$SITE_LANG" == "ru" ]] || SITE_LANG="en"

echo "Тема видео: technology, architecture, city, nature, abstract, people…"
read -rp "Тема видео [architecture]: " SEARCH_QUERY
SEARCH_QUERY="${SEARCH_QUERY:-architecture}"

read -rp "Количество клипов [$VIDEO_COUNT]: " inp
[[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= 24 )) && VIDEO_COUNT="$inp"

# --- 2.5 PROXY protocol ---
echo
# Самая частая причина «Reality работает, но маскировка не работает».
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

# --- Место на диске: считаем после того, как известно число клипов ---
# При пересборке на разделе одновременно живут старый сайт и STAGE,
# поэтому запас нужен примерно двойной.
if (( REBUILD_SITE )); then
    NEED_MB=$(( VIDEO_COUNT * MB_PER_CLIP * 2 + 512 ))
    FREE_MB=$(free_mb "$(dirname "$WEB_ROOT")")
    if (( FREE_MB < NEED_MB )); then
        err "Свободно ${FREE_MB} МБ, для ${VIDEO_COUNT} клипов нужно ~${NEED_MB} МБ"
        err "(оценка сверху: старый сайт и новый существуют одновременно)."
        err "Уменьшите количество клипов или освободите место."
        exit 1
    fi
    log "Места достаточно: ${FREE_MB} МБ при потребности ~${NEED_MB} МБ."
fi

# ---------------------------------------------------------------------------
# ОФОРМЛЕНИЕ: всё выводится из SEED_BASE
# ---------------------------------------------------------------------------
# Палитры подобраны так, чтобы не попадать в узнаваемые «дефолтные» связки
# (кремовый фон + терракотовый акцент, чёрный фон + кислотный акцент,
# газетная вёрстка с волосяными линейками): такие сочетания сами по себе
# выглядят как след генератора.
PALETTE=$(pick palette 1 2 3 4 5 6)
case "$PALETTE" in
  1) C_INK="#1b1f24"; C_SOFT="#5d666e"; C_LINE="#dde2e7"; C_BG="#f7f8f9"; C_PANEL="#ffffff"; C_ACC="#2f4b7c" ;;
  2) C_INK="#22201d"; C_SOFT="#6b645c"; C_LINE="#e3ded6"; C_BG="#faf8f4"; C_PANEL="#ffffff"; C_ACC="#4a6b45" ;;
  3) C_INK="#151b1a"; C_SOFT="#57635f"; C_LINE="#d9e2df"; C_BG="#f4f7f6"; C_PANEL="#ffffff"; C_ACC="#1f6b6b" ;;
  4) C_INK="#1d1a22"; C_SOFT="#635d6b"; C_LINE="#e0dce5"; C_BG="#f8f6fa"; C_PANEL="#ffffff"; C_ACC="#5a3f88" ;;
  5) C_INK="#181818"; C_SOFT="#5f5f5f"; C_LINE="#e0e0e0"; C_BG="#f5f5f5"; C_PANEL="#ffffff"; C_ACC="#8a4a2a" ;;
  6) C_INK="#12181f"; C_SOFT="#556270"; C_LINE="#d7dee6"; C_BG="#f3f6f9"; C_PANEL="#ffffff"; C_ACC="#1f5f96" ;;
esac

FONT_STACK=$(pick font \
  '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif' \
  'system-ui,"Segoe UI",Roboto,Helvetica,Arial,sans-serif' \
  '"Helvetica Neue",Helvetica,Arial,"Liberation Sans",sans-serif' \
  'ui-sans-serif,system-ui,-apple-system,"Segoe UI",Arial,sans-serif' \
  'Georgia,"Times New Roman",Times,serif')
BASE_SIZE=$(pick fsize 16 16.5 17 17.5)
BASE_LH=$(pick flh 1.55 1.6 1.65)
RADIUS=$(pick radius 0 2 3 4 6)
MEASURE=$(pick measure 64 68 70 74)
CARD_MIN=$(pick cardmin 280 300 320 340)
GAP_ROW=$(pick gaprow 2 2.4 2.8 3.2)
MAXW=$(pick maxw 1000 1040 1080 1140)

# Имена классов тоже входят в хеш файла — берём их из пулов.
K_WRAP=$(pick k1 wrap container shell inner bound)
K_HEAD=$(pick k2 site-head topbar masthead header-bar page-head)
K_BRAND=$(pick k3 brand logo wordmark title-mark)
K_NAV=$(pick k4 nav menu links topnav)
K_LEDE=$(pick k5 lede intro hero-copy opening)
K_EYE=$(pick k6 eyebrow kicker label overline)
K_GRID=$(pick k7 grid works reel gallery listing)
K_CARD=$(pick k8 work item entry piece tile)
K_BODY=$(pick k9 work-body item-body caption card-text)
K_META=$(pick k10 meta credits subline detail)
K_PROSE=$(pick k11 prose text page-copy article)
K_FOOT=$(pick k12 site-foot footer page-foot colophon)
CSS_NAME=$(pick cssname site.css main.css style.css app.css layout.css base.css)

# Четвёртая страница: её наличие, адрес и заголовок тоже различаются.
P4_SLUG=$(pick p4slug process approach services studio notes)

log "Оформление: палитра $PALETTE, css /assets/css/$CSS_NAME, доп. страница /$P4_SLUG.html"

# ---------------------------------------------------------------------------
# ТЕКСТЫ
# ---------------------------------------------------------------------------
if [[ "$SITE_LANG" == "ru" ]]; then
  HTML_LANG="ru"
  T_BRAND_SUFFIX=$(pick tbs "студия" "видеостудия" "монтаж и съёмка" "motion-студия")
  T_NAV_WORKS="Работы"; T_NAV_ABOUT="О студии"; T_NAV_CONTACT="Контакты"
  case "$P4_SLUG" in
    process)  T_NAV_P4="Процесс";  T_P4_TITLE="Как мы работаем" ;;
    approach) T_NAV_P4="Подход";   T_P4_TITLE="Подход" ;;
    services) T_NAV_P4="Услуги";   T_P4_TITLE="Что мы делаем" ;;
    studio)   T_NAV_P4="Студия";   T_P4_TITLE="Студия" ;;
    *)        T_NAV_P4="Заметки";  T_P4_TITLE="Рабочие заметки" ;;
  esac
  T_EYEBROW=$(pick teye "Избранное" "Витрина" "Из архива" "Работы")
  T_H1=$(pick th1 \
    "Небольшая студия, которая снимает и монтирует короткие формы" \
    "Снимаем и монтируем короткие видео — без длинных согласований" \
    "Короткие формы: титры, вставки, фоновые лупы" \
    "Студия короткого метра и моушн-графики")
  T_LEDE=$(pick tlede \
    "Ниже — часть архива за последние сезоны: тесты оптики, заготовки под фон, несколько клиентских работ, которые разрешили показать." \
    "Здесь собрано то, что можно показывать: внутренние тесты, материал, не вошедший в проекты, и пара законченных работ." \
    "Витрина обновляется нерегулярно — выкладываем то, что самим нравится пересматривать.")
  T_VIDEO_FALLBACK="Ваш браузер не умеет проигрывать это видео."
  T_ABOUT_DESC="Кто мы, как работаем и на чём снимаем."
  T_CONTACT_DESC="Как с нами связаться и что прислать в первом письме."
  T_INDEX_DESC="Избранные видеоработы: короткие формы, титры, фоновые лупы."
  T_404_TITLE="Страница не найдена"
  T_404_DESC="Такой страницы нет."
  T_404_BODY="Ссылка ведёт в никуда — возможно, работу убрали из витрины. Загляните в <a href=\"/\">список работ</a> или напишите нам."
  T_ERR_TITLE="Сервис временно недоступен"
  T_ERR_DESC="Страница сейчас недоступна."
  T_ERR_BODY="Запрос не удалось обработать. Обновите страницу через минуту — обычно этого достаточно. Если не помогло, напишите нам, и мы посмотрим, что произошло."
  T_FOOT1="монтаж, съёмка, motion-графика."
  T_FOOT2="Материалы витрины — по лицензии Pixabay Content License."
  T_MAIL_LABEL="Почта"; T_HOURS_LABEL="Часы"; T_HOURS="Пн–Пт, 10:00–19:00"

  about_body() {
    cat <<EOF
<h1>О студии</h1>
<p>$(pick ai1 \
 "«${STUDIO_NAME}» — небольшая студия: два монтажёра и оператор. Делаем короткие видео: титры, вставки, фоновые лупы для экранов на мероприятиях, изредка — ролики под ключ." \
 "«${STUDIO_NAME}» работает шестой год. Нас трое, и мы намеренно не растём: берём столько проектов, сколько успеваем сделать руками." \
 "«${STUDIO_NAME}» начиналась как двое фрилансеров, снявших общую комнату под монтажную. С тех пор добавился оператор, а формат остался прежним.")</p>
<h2>$(pick ah2 "Как устроена работа" "Как это происходит" "Порядок работы")</h2>
<p>$(pick ai2 \
 "Обычный проект занимает от недели до месяца. Начинаем с раскадровки, дальше съёмка или подбор материала из архива, потом монтаж и цвет. Правки входят в стоимость, отдельно считаем только пересъёмку." \
 "Сроки считаем по монтажным дням, а не по календарю: неделя работы может растянуться на три, если ждём согласования. Поэтому дедлайн обсуждаем в первом же письме." \
 "Сначала короткая встреча и раскадровка, потом смета. Пока смета не подписана, к съёмке не приступаем — так честнее для обеих сторон.")</p>
<h2>Техника</h2>
<dl>
  <dt>Камеры</dt><dd>$(pick ag1 "Sony FX3, Blackmagic Pocket 6K" "Sony FX6 и FX30" "Canon C70, Blackmagic 6K Pro" "Panasonic S5 II, Sony A7S III")</dd>
  <dt>Оптика</dt><dd>$(pick ag2 "Sigma Art, набор винтажных Helios" "Canon CN-E, пара старых Takumar" "Samyang XEEN, Helios 44-2" "Sirui Nightwalker и штатные зумы")</dd>
  <dt>Монтаж</dt><dd>$(pick ag3 "DaVinci Resolve Studio" "Premiere Pro, цвет в Resolve" "Final Cut Pro и Resolve для грейда")</dd>
  <dt>Графика</dt><dd>$(pick ag4 "After Effects, Blender" "After Effects, Cinema 4D" "Blender, немного Houdini")</dd>
</dl>
<h2>$(pick ah3 "Что мы не делаем" "За что не беремся")</h2>
<p>$(pick ai3 \
 "Не снимаем свадьбы и мероприятия «под ключ» с несколькими камерами — для этого есть коллеги, которым мы передаём такие запросы." \
 "Не берём многодневные мероприятия и репортаж: у нас нет команды нужного размера, и обещать такое было бы нечестно." \
 "Не делаем рекламу лекарств, БАДов и всего, что требует медицинских согласований — слишком много юридической возни на нашем масштабе.")</p>
EOF
  }

  contact_body() {
    cat <<EOF
<h1>Контакты</h1>
<p>$(pick ci1 "Пишите на почту — отвечаем в течение рабочего дня." "Почта — самый надёжный способ. Обычно отвечаем в тот же день." "Все вопросы — письмом. Телефон включаем только на съёмках.")</p>
<dl>
  <dt>${T_MAIL_LABEL}</dt><dd><a href="mailto:studio@${DOMAIN}">studio@${DOMAIN}</a></dd>
  <dt>${T_HOURS_LABEL}</dt><dd>${T_HOURS}</dd>
</dl>
<h2>Что прислать в первом письме</h2>
<p>$(pick ci2 \
 "Чтобы быстрее сориентировать по срокам и бюджету, опишите задачу в двух-трёх абзацах: для чего ролик, где будет показан, есть ли дедлайн и референсы. Готовый бриф не нужен — разберёмся вместе." \
 "Хватит нескольких предложений: что за проект, где будет показан ролик, к какому числу нужен и есть ли примеры того, что нравится. Формальный бриф можно не готовить." \
 "Опишите задачу своими словами и приложите пару референсов. Если бюджет уже определён — назовите его сразу, это экономит всем неделю переписки.")</p>
<h2>Стажировки</h2>
<p>$(pick ci3 \
 "Раз в полгода берём одного человека на монтаж. Набор объявляем здесь же, резюме заранее не собираем." \
 "Иногда берём стажёра на монтаж — объявляем на этой странице. Заранее присланные резюме, к сожалению, теряются.")</p>
EOF
  }

  page4_body() {
    cat <<EOF
<h1>${T_P4_TITLE}</h1>
<p>$(pick p41 \
 "Мы работаем небольшими итерациями: показываем черновую сборку рано, когда ещё не жалко переделать. Так дешевле обходятся принципиальные правки." \
 "Каждый проект начинается с разговора о том, где ролик будет показан. Экран на конференции, сторис и сайт требуют разного монтажа, и это влияет на всё остальное." \
 "Стараемся не браться за несколько проектов одновременно. Один в работе, один в согласовании — дальше очередь.")</p>
<h2>$(pick p4h "Этапы" "Из чего состоит проект" "Порядок")</h2>
<dl>
  <dt>Раскадровка</dt><dd>1–3 дня, обсуждаем на созвоне</dd>
  <dt>Съёмка</dt><dd>обычно один смена, реже две</dd>
  <dt>Монтаж</dt><dd>от трёх дней, черновик показываем сразу</dd>
  <dt>Цвет и звук</dt><dd>1–2 дня после утверждения монтажа</dd>
</dl>
<p>$(pick p42 \
 "Две волны правок входят в стоимость. Всё, что меняет структуру после утверждения монтажа, считаем отдельно — не из вредности, а потому что это фактически другой проект." \
 "Файлы отдаём в том виде, в каком они нужны для показа: отдельно мастер, отдельно версии под конкретные площадки. Исходники храним год.")</p>
EOF
  }
else
  HTML_LANG="en"
  T_BRAND_SUFFIX=$(pick tbs "studio" "film studio" "motion studio" "editorial")
  T_NAV_WORKS="Work"; T_NAV_ABOUT="About"; T_NAV_CONTACT="Contact"
  case "$P4_SLUG" in
    process)  T_NAV_P4="Process";  T_P4_TITLE="How we work" ;;
    approach) T_NAV_P4="Approach"; T_P4_TITLE="Approach" ;;
    services) T_NAV_P4="Services"; T_P4_TITLE="What we do" ;;
    studio)   T_NAV_P4="Studio";   T_P4_TITLE="The studio" ;;
    *)        T_NAV_P4="Notes";    T_P4_TITLE="Working notes" ;;
  esac
  T_EYEBROW=$(pick teye "Selected" "Recent work" "From the archive" "Showreel")
  T_H1=$(pick th1 \
    "A small studio shooting and cutting short-form video" \
    "Short films, titles and loops, made by three people" \
    "We shoot short pieces and cut them ourselves" \
    "A short-form studio working mostly on location")
  T_LEDE=$(pick tlede \
    "Below is part of the archive from recent seasons: lens tests, background loops, and a few client pieces we are allowed to show." \
    "What you see here is what we can publish: internal tests, footage that never made it into a project, and a couple of finished films." \
    "The reel updates irregularly. We post the pieces we still enjoy watching.")
  T_VIDEO_FALLBACK="Your browser cannot play this video."
  T_ABOUT_DESC="Who we are, how we work and what we shoot on."
  T_CONTACT_DESC="How to reach us and what to put in a first email."
  T_INDEX_DESC="Selected video work: short pieces, title sequences, background loops."
  T_404_TITLE="Page not found"
  T_404_DESC="No such page."
  T_404_BODY="This link goes nowhere — the piece may have been taken off the reel. Try the <a href=\"/\">work index</a> or send us a note."
  T_ERR_TITLE="Temporarily unavailable"
  T_ERR_DESC="This page is not available right now."
  T_ERR_BODY="The request could not be completed. Reload in a minute — that usually clears it. If it does not, email us and we will look into it."
  T_FOOT1="editing, camera, motion graphics."
  T_FOOT2="Reel footage licensed under the Pixabay Content License."
  T_MAIL_LABEL="Email"; T_HOURS_LABEL="Hours"; T_HOURS="Mon–Fri, 10:00–19:00"

  about_body() {
    cat <<EOF
<h1>About</h1>
<p>$(pick ai1 \
 "${STUDIO_NAME} is a small studio: two editors and a camera operator. We make short pieces — title sequences, inserts, background loops for event screens, and occasionally a full film." \
 "${STUDIO_NAME} has been running for six years. There are three of us and we deliberately stay that size: we take on as much as we can finish by hand." \
 "${STUDIO_NAME} started as two freelancers sharing a room for an edit suite. A camera operator joined later; the format has not changed much since.")</p>
<h2>$(pick ah2 "How the work goes" "How a project runs" "Working method")</h2>
<p>$(pick ai2 \
 "A typical project runs from one week to a month. We start with a board, then shoot or pull from the archive, then edit and grade. Revisions are included; only reshoots are quoted separately." \
 "We count edit days rather than calendar days: a week of work can stretch to three if approvals are slow. That is why we ask about deadlines in the first email." \
 "A short call and a board come first, then the quote. Nothing is shot before the quote is signed — it is fairer to both sides that way.")</p>
<h2>$(pick ah4 "Kit" "Equipment" "Gear")</h2>
<dl>
  <dt>Cameras</dt><dd>$(pick ag1 "Sony FX3, Blackmagic Pocket 6K" "Sony FX6 and FX30" "Canon C70, Blackmagic 6K Pro" "Panasonic S5 II, Sony A7S III")</dd>
  <dt>Lenses</dt><dd>$(pick ag2 "Sigma Art, a set of vintage Helios" "Canon CN-E and a pair of old Takumars" "Samyang XEEN, Helios 44-2" "Sirui Nightwalker plus kit zooms")</dd>
  <dt>Edit</dt><dd>$(pick ag3 "DaVinci Resolve Studio" "Premiere Pro, grading in Resolve" "Final Cut Pro, Resolve for the grade")</dd>
  <dt>Graphics</dt><dd>$(pick ag4 "After Effects, Blender" "After Effects, Cinema 4D" "Blender with a little Houdini")</dd>
</dl>
<h2>$(pick ah3 "What we don't take on" "Not our thing")</h2>
<p>$(pick ai3 \
 "We do not shoot weddings or multi-camera event coverage — we pass those on to colleagues who do it properly." \
 "Multi-day events and reportage are out: we do not have a crew that size, and promising otherwise would be dishonest." \
 "We stay away from pharmaceutical and supplement advertising — too much legal review for a studio our size.")</p>
EOF
  }

  contact_body() {
    cat <<EOF
<h1>Contact</h1>
<p>$(pick ci1 "Email is best — we reply within a working day." "Email reaches us fastest; we usually answer the same day." "Everything by email, please. The phone is only on during shoots.")</p>
<dl>
  <dt>${T_MAIL_LABEL}</dt><dd><a href="mailto:studio@${DOMAIN}">studio@${DOMAIN}</a></dd>
  <dt>${T_HOURS_LABEL}</dt><dd>${T_HOURS}</dd>
</dl>
<h2>$(pick ch2 "What to include" "First email")</h2>
<p>$(pick ci2 \
 "Two or three paragraphs are enough: what the piece is for, where it will be shown, whether there is a deadline, and any references. A formal brief is not needed." \
 "Tell us what the project is, where the film will play, when you need it, and what you like the look of. We can work out the rest together." \
 "Describe the job in your own words and attach a couple of references. If the budget is already set, say so early — it saves a week of email.")</p>
<h2>$(pick ch3 "Internships" "Placements")</h2>
<p>$(pick ci3 \
 "Twice a year we take on one person for editing. Openings are announced here; we do not keep unsolicited CVs." \
 "We occasionally take an editing intern and announce it on this page. CVs sent in advance tend to get lost, sorry.")</p>
EOF
  }

  page4_body() {
    cat <<EOF
<h1>${T_P4_TITLE}</h1>
<p>$(pick p41 \
 "We work in small iterations and show a rough cut early, while it is still cheap to change. Structural notes are much less painful that way." \
 "Every project starts with a conversation about where the film will play. A conference screen, a vertical story and a website all want different cutting." \
 "We try not to run projects in parallel. One in the edit, one in approval, everything else waits.")</p>
<h2>$(pick p4h "Stages" "What a project looks like" "Order of work")</h2>
<dl>
  <dt>Board</dt><dd>1–3 days, discussed on a call</dd>
  <dt>Shoot</dt><dd>usually a single day, sometimes two</dd>
  <dt>Edit</dt><dd>from three days, rough cut shown early</dd>
  <dt>Grade and sound</dt><dd>1–2 days after the cut is locked</dd>
</dl>
<p>$(pick p42 \
 "Two rounds of notes are included. Anything that changes the structure after the cut is locked is quoted separately — not out of stubbornness, but because it is effectively a new project." \
 "We deliver in the form you need for playback: a master plus versions cut for specific placements. Rushes are kept for a year.")</p>
EOF
  }
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

# --- Бэкап старого (без видео: оно скачивается заново, а гигабайты
#     mp4 в tar.gz — это минуты CPU ради нулевого выигрыша) ---
if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]]; then
    BK="/root/${LOG_PREFIX}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$BK" --exclude='assets/video' \
        -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")" 2>/dev/null || true
    log "Бэкап разметки старого сайта: $BK"
    # Ротация: держим три последних, иначе /root заполняется незаметно.
    ls -1t /root/"${LOG_PREFIX}"-backup-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
fi

# Собираем рядом, чтобы при сбое не остаться с полупустым каталогом
STAGE="${WEB_ROOT}.new.$$"   # подхватывается trap cleanup при аварии
rm -rf "$STAGE"
mkdir -p "$STAGE/assets/video" "$STAGE/assets/img" "$STAGE/assets/css" \
         "$STAGE/.well-known/acme-challenge"

log "Запрашиваю каталог видео (тема: $SEARCH_QUERY, качество: $VIDEO_QUALITY)…"
HTTP_CODE=$(curl -sS --get -K "$KEYFILE" "https://pixabay.com/api/videos/" \
    --data-urlencode "q=${SEARCH_QUERY}" \
    --data-urlencode "video_type=film" \
    --data-urlencode "per_page=${FETCH_POOL}" \
    --data-urlencode "safesearch=true" \
    --connect-timeout 15 --max-time 60 \
    -o "$TMP_DIR/api.json" -w '%{http_code}') || HTTP_CODE="000"

[[ "$HTTP_CODE" == "200" ]] || { err "API вернул HTTP $HTTP_CODE"; head -c 300 "$TMP_DIR/api.json" 2>/dev/null; exit 1; }
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
    rm -rf "$STAGE"; STAGE=""; exit 1
fi
log "Найдено видео по запросу: $TOTAL_HITS"

# --- Отбор: длинные и тяжёлые клипы ---
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
    rm -rf "$STAGE"; STAGE=""; exit 1
fi
if (( POOL_N < VIDEO_COUNT )); then
    warn "Доступно только $POOL_N — витрина будет из $POOL_N клипов."
    VIDEO_COUNT="$POOL_N"
fi


# ---------------------------------------------------------------------------
# СКАЧИВАНИЕ КЛИПОВ
# ---------------------------------------------------------------------------
declare -a V_FILE V_POSTER V_TITLE V_TAGS V_DUR V_DESC

TITLE_WORDS=(Northbound "Signal Drift" Halo "Field Notes" Interval "Quiet Machines"
             Overcast "Second Light" Longform Aperture "Slow Study" Meridian
             "Blue Hour" Threshold "Paper Cities" Kinetic Understory "Nine Frames"
             Groundwork "Late Shift" Tideline "Common Hours")

if [[ "$SITE_LANG" == "ru" ]]; then
  CLIENT_KIND=(Концепт "Клиентская работа" "Тест студии" "Спек-работа" "Титры"
               "Бренд-фильм" "Внутренний R&amp;D" "Питч-рил")
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
else
  CLIENT_KIND=(Concept "Client work" "Studio test" "Spec piece" "Title sequence"
               "Brand film" "Internal R&amp;D" "Pitch reel")
  DESC_TMPL=(
   "Shot on location, cut in two days. The subject was @TAG@ — we were after rhythm rather than story."
   "A short study of @TAG@. We kept the camera locked off and let the frame do the moving."
   "Part of an internal series on texture. Here it is @TAG@, natural light, minimal grade."
   "Filmed for another project and cut for pace. Subject: @TAG@. Left as it came out of camera."
   "A lens test. The subject mattered less than seeing how @TAG@ sits in a wide frame."
   "Made as a background loop. @TAG@, eight seconds, no hard cuts."
   "From last year's archive. We shot @TAG@ and then argued about colour for a week. The first grade won."
   "An exercise in cutting rhythm: @TAG@, three setups, no dialogue."
   "Made for a conference screen: @TAG@, six metres wide, played without sound."
   "One of the first things we shot on the new body. Subject: @TAG@, all available light."
  )
fi

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
    # вида "steel & iron" подставился бы искажённым.
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

(( ok > 0 )) || { err "Не удалось скачать ни одного клипа."; rm -rf "$STAGE"; STAGE=""; exit 1; }
log "Скачано клипов: $ok, суммарно $(( total_bytes / 1048576 )) МБ"

# --------------------------- CSS ---------------------------------------------
cat > "$STAGE/assets/css/$CSS_NAME" <<CSS
:root{
  --ink:$C_INK; --ink-soft:$C_SOFT; --line:$C_LINE;
  --paper:$C_BG; --panel:$C_PANEL; --accent:$C_ACC; --measure:${MEASURE}ch;
}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);
  font:400 ${BASE_SIZE}px/${BASE_LH} $FONT_STACK;}
img,video{display:block;max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
a:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.$K_WRAP{width:min(${MAXW}px,92vw);margin-inline:auto}
.$K_HEAD{border-bottom:1px solid var(--line);background:var(--panel)}
.$K_HEAD .$K_WRAP{display:flex;align-items:baseline;gap:2rem;padding:1.1rem 0;flex-wrap:wrap}
.$K_BRAND{font-weight:700;letter-spacing:-.02em;font-size:1.05rem;color:var(--ink)}
.$K_BRAND span{color:var(--ink-soft);font-weight:400}
.$K_NAV{margin-left:auto;display:flex;gap:1.4rem;font-size:.93rem}
.$K_NAV a{color:var(--ink-soft)}
.$K_NAV a[aria-current="page"]{color:var(--ink);font-weight:600}
.$K_LEDE{padding:4.5rem 0 3rem;border-bottom:1px solid var(--line)}
.$K_EYE{font-size:.75rem;letter-spacing:.14em;text-transform:uppercase;
  color:var(--ink-soft);margin:0 0 1rem}
.$K_LEDE h1{font-size:clamp(1.9rem,4.6vw,3rem);line-height:1.12;letter-spacing:-.03em;
  margin:0 0 1rem;max-width:20ch;font-weight:700}
.$K_LEDE p{margin:0;max-width:54ch;color:var(--ink-soft)}
.$K_GRID{display:grid;gap:${GAP_ROW}rem 2rem;padding:3rem 0;
  grid-template-columns:repeat(auto-fill,minmax(${CARD_MIN}px,1fr))}
.$K_CARD{background:var(--panel);border:1px solid var(--line);border-radius:${RADIUS}px;
  overflow:hidden;display:flex;flex-direction:column}
.$K_CARD video{width:100%;aspect-ratio:16/9;background:#0d0f10;object-fit:cover}
.$K_BODY{padding:1.15rem 1.25rem 1.4rem}
.$K_BODY h2{font-size:1.08rem;margin:0 0 .2rem;letter-spacing:-.01em}
.$K_META{font-size:.78rem;color:var(--ink-soft);margin:0 0 .7rem}
.$K_BODY p{margin:0;font-size:.93rem;color:var(--ink-soft)}
.$K_PROSE{padding:3.5rem 0;max-width:var(--measure)}
.$K_PROSE h1{font-size:2rem;letter-spacing:-.025em;margin:0 0 1.2rem}
.$K_PROSE h2{font-size:1.15rem;margin:2.2rem 0 .6rem}
.$K_PROSE dl{display:grid;grid-template-columns:9rem 1fr;gap:.5rem 1rem;margin:1.5rem 0}
.$K_PROSE dt{color:var(--ink-soft);font-size:.9rem}
.$K_PROSE dd{margin:0}
.$K_FOOT{border-top:1px solid var(--line);margin-top:2rem;padding:2.2rem 0 3rem;
  font-size:.85rem;color:var(--ink-soft)}
.$K_FOOT p{margin:.25rem 0}
@media (prefers-reduced-motion:no-preference){
  .$K_CARD{transition:border-color .2s ease}
  .$K_CARD:hover{border-color:var(--ink-soft)}
}
@media (max-width:520px){
  .$K_HEAD .$K_WRAP{gap:.8rem}
  .$K_NAV{width:100%;margin-left:0;gap:1.1rem}
  .$K_LEDE{padding:3rem 0 2.2rem}
  .$K_PROSE dl{grid-template-columns:1fr;gap:.15rem}
}
CSS

# --------------------------- ФАВИКОН -----------------------------------------
ACC_R=$(( 16#${C_ACC:1:2} )); ACC_G=$(( 16#${C_ACC:3:2} )); ACC_B=$(( 16#${C_ACC:5:2} ))
GLYPH_ID=$(( $(seed_idx glyph) % 4 ))
SVG_RADIUS=$(pick svgr 0 3 5 8)

cat > "$STAGE/assets/img/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="$SVG_RADIUS" fill="$C_ACC"/>
  <text x="16" y="23" font-family="Helvetica,Arial,sans-serif" font-size="20"
        font-weight="700" text-anchor="middle" fill="$C_BG">$BRAND_INITIAL</text>
</svg>
SVG

# Отсутствие /favicon.ico — заметная аномалия: настоящие сайты его имеют,
# а браузеры и сканеры запрашивают именно этот путь в корне.
python3 - "$STAGE/favicon.ico" "$ACC_R" "$ACC_G" "$ACC_B" "$GLYPH_ID" <<'PY' \
    && log "favicon.ico создан" || warn "favicon.ico не создан"
import struct, sys
path = sys.argv[1]
r, g, b, gid = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
W = H = 16
bg = (b, g, r, 255)            # BMP хранит цвет как BGRA
fg = (0xF7, 0xF7, 0xF5, 255)
GLYPHS = [
 # M
 ["................","................","..#..........#..","..##........##..",
  "..#.#......#.#..","..#..#....#..#..","..#...#..#...#..","..#....##....#..",
  "..#..........#..","..#..........#..","..#..........#..","..#..........#..",
  "................","................","................","................"],
 # шеврон
 ["................","................","................",".....##.........",
  "......##........",".......##.......","........##......",".........##.....",
  "........##......",".......##.......","......##........",".....##.........",
  "................","................","................","................"],
 # кольцо
 ["................","................",".....####.......","...##....##.....",
  "..##......##....","..#........#....","..#........#....","..#........#....",
  "..#........#....","..##......##....","...##....##.....",".....####.......",
  "................","................","................","................"],
 # рамка кадра
 ["................","................","..##########....","..#........#....",
  "..#........#....","..#........#....","..#........#....","..#........#....",
  "..#........#....","..#........#....","..##########....","................",
  "................","................","................","................"],
]
glyph = GLYPHS[gid % len(GLYPHS)]
xor = b"".join(bytes(fg if glyph[y][x] == "#" else bg)
               for y in range(H - 1, -1, -1) for x in range(W))
and_mask = b"\x00" * (H * 4)
dib = struct.pack("<IiiHHIIiiII", 40, W, H * 2, 1, 32, 0, len(xor), 0, 0, 0, 0)
img = dib + xor + and_mask
ico = struct.pack("<HHH", 0, 1, 1) + \
      struct.pack("<BBBBHHII", W, H, 0, 0, 1, 32, len(img), 22) + img
open(path, "wb").write(ico)
PY

# --------------------------- СТРАНИЦЫ ----------------------------------------
YEAR=$(date +%Y); TODAY=$(date +%F)

emit_head() {
cat <<EOF
<!DOCTYPE html>
<html lang="$HTML_LANG">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1 — ${STUDIO_NAME}</title>
<meta name="description" content="$2">
<link rel="canonical" href="https://${DOMAIN}$3">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/assets/img/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/css/${CSS_NAME}">
</head>
<body>
<header class="$K_HEAD"><div class="$K_WRAP">
  <a class="$K_BRAND" href="/">${STUDIO_NAME} <span>/ ${T_BRAND_SUFFIX}</span></a>
  <nav class="$K_NAV">
    <a href="/"$([[ "$3" == "/" ]] && echo ' aria-current="page"')>${T_NAV_WORKS}</a>
    <a href="/${P4_SLUG}.html"$([[ "$3" == "/${P4_SLUG}.html" ]] && echo ' aria-current="page"')>${T_NAV_P4}</a>
    <a href="/about.html"$([[ "$3" == "/about.html" ]] && echo ' aria-current="page"')>${T_NAV_ABOUT}</a>
    <a href="/contact.html"$([[ "$3" == "/contact.html" ]] && echo ' aria-current="page"')>${T_NAV_CONTACT}</a>
  </nav>
</div></header>
EOF
}

emit_foot() {
cat <<EOF
<footer class="$K_FOOT"><div class="$K_WRAP">
  <p>${STUDIO_NAME} — ${T_FOOT1}</p>
  <p>© ${YEAR}. ${T_FOOT2}</p>
</div></footer>
</body>
</html>
EOF
}

{
emit_head "${T_NAV_WORKS}" "$T_INDEX_DESC" "/"
cat <<EOF
<main>
<section class="$K_LEDE"><div class="$K_WRAP">
  <p class="$K_EYE">${T_EYEBROW} · ${YEAR}</p>
  <h1>${T_H1}</h1>
  <p>${T_LEDE}</p>
</div></section>
<div class="$K_WRAP"><div class="$K_GRID">
EOF
for i in "${!V_FILE[@]}"; do
    dur="${V_DUR[$i]}"; dur_txt=""
    (( dur > 0 )) && dur_txt=" · $(printf '%d:%02d' $((dur/60)) $((dur%60)))"
    poster_attr=""
    [[ -n "${V_POSTER[$i]}" ]] && poster_attr=" poster=\"/${V_POSTER[$i]}\""
    # preload="none" принципиально: с "metadata" одна загрузка главной
    # порождает по запросу на каждый клип, и лимиты на видео срабатывают
    # на обычном посетителе. Постер даёт ту же картинку без запроса к mp4.
cat <<EOF
  <article class="$K_CARD">
    <video controls preload="none" playsinline$poster_attr>
      <source src="/${V_FILE[$i]}" type="video/mp4">
      ${T_VIDEO_FALLBACK}
    </video>
    <div class="$K_BODY">
      <h2>${V_TITLE[$i]}</h2>
      <p class="$K_META">${V_TAGS[$i]}${dur_txt}</p>
      <p>${V_DESC[$i]}</p>
    </div>
  </article>
EOF
done
echo "</div></div></main>"
emit_foot
} > "$STAGE/index.html"

{
emit_head "$T_NAV_ABOUT" "$T_ABOUT_DESC" "/about.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
about_body
echo "</div></main>"
emit_foot
} > "$STAGE/about.html"

{
emit_head "$T_NAV_CONTACT" "$T_CONTACT_DESC" "/contact.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
contact_body
echo "</div></main>"
emit_foot
} > "$STAGE/contact.html"

{
emit_head "$T_NAV_P4" "$T_P4_TITLE" "/${P4_SLUG}.html"
echo "<main class=\"$K_WRAP\"><div class=\"$K_PROSE\">"
page4_body
echo "</div></main>"
emit_foot
} > "$STAGE/${P4_SLUG}.html"

{
emit_head "$T_404_TITLE" "$T_404_DESC" "/404.html"
cat <<EOF
<main class="$K_WRAP"><div class="$K_PROSE">
<h1>${T_404_TITLE}</h1>
<p>${T_404_BODY}</p>
</div></main>
EOF
emit_foot
} > "$STAGE/404.html"

# Отдельная страница для 403/429/5xx: возвращать «страница не найдена»
# в ответ на превышение лимита — рассогласование, заметное при просмотре
# логов и при ручной проверке.
{
emit_head "$T_ERR_TITLE" "$T_ERR_DESC" "/error.html"
cat <<EOF
<main class="$K_WRAP"><div class="$K_PROSE">
<h1>${T_ERR_TITLE}</h1>
<p>${T_ERR_BODY}</p>
</div></main>
EOF
emit_foot
} > "$STAGE/error.html"

# Видео не закрываем от индексации: видеостудия, прячущая свои работы от
# поисковиков, — сама по себе странность. Закрываем только служебное.
cat > "$STAGE/robots.txt" <<EOF
User-agent: *
Allow: /
Disallow: /error.html

Sitemap: https://${DOMAIN}/sitemap.xml
EOF

cat > "$STAGE/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc><lastmod>${TODAY}</lastmod><priority>1.0</priority></url>
  <url><loc>https://${DOMAIN}/${P4_SLUG}.html</loc><lastmod>${TODAY}</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/about.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/contact.html</loc><lastmod>${TODAY}</lastmod><priority>0.6</priority></url>
</urlset>
EOF

# --- Подмена каталога ---
# Сначала уводим старый в сторону, потом ставим новый, и только затем
# удаляем: `rm -rf` по сотням мегабайт видео занимает заметное время, и
# делать его между удалением и установкой означает окно, когда сайт
# физически отсутствует.
if [[ -d "$WEB_ROOT" ]]; then
    # Если certbot прямо сейчас проходит валидацию, токены нужно сохранить
    if compgen -G "$WEB_ROOT/.well-known/acme-challenge/*" >/dev/null; then
        cp -a "$WEB_ROOT/.well-known/acme-challenge/." "$STAGE/.well-known/acme-challenge/"
    fi
    OLD_ROOT="${WEB_ROOT}.old.$$"
    mv "$WEB_ROOT" "$OLD_ROOT"
fi
mv "$STAGE" "$WEB_ROOT"
STAGE=""
if [[ -n "$OLD_ROOT" ]]; then rm -rf "$OLD_ROOT"; OLD_ROOT=""; fi
SITE_SIZE=$(du -sh "$WEB_ROOT" | cut -f1)
log "Витрина собрана: $SITE_SIZE"

fi  # REBUILD_SITE

mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
# Владелец root, а не www-data: воркеру nginx достаточно права на чтение,
# а запись в собственный docroot — лишняя возможность при любой ошибке.
chown -R root:root "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} +
find "$WEB_ROOT" -type f -exec chmod 644 {} +
log "Права выставлены (root:root, 755/644)."

# ============================================================================
# 6. ВСПОМОГАТЕЛЬНЫЕ ФАЙЛЫ NGINX
# ============================================================================
hdr "6. Сниппеты и зоны лимитов"

mkdir -p /etc/nginx/snippets

# Заголовки вынесены в сниппет: add_header в location полностью отменяет
# унаследованные из server{}, поэтому их приходится подключать в каждом
# блоке, где есть свой add_header. Держать четыре копии руками — верный
# способ однажды потерять половину.
cat > "$HEAD_SNIPPET" <<'EOF'
# Managed by reality-dest-setup.sh
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF

disable_hardening() {
    local changed=0 f
    for f in "$LIMITS_CONF" "$DENY_SNIPPET" "$F2B_JAIL" "$F2B_FILTER" \
             "$F2B_ACTION" "$RELOAD_HELPER"; do
        if [[ -e "$f" ]]; then rm -f "$f"; changed=1; fi
    done
    if (( changed )); then
        warn "Найдены артефакты защиты от прошлого запуска — удалены."
        if systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban'; then
            systemctl restart fail2ban >/dev/null 2>&1 || true
        fi
    fi
}

if (( HARDEN )); then
    # Файл должен существовать до включения в конфиг, иначе nginx не стартует
    [[ -f "$DENY_SNIPPET" ]] || printf '# Управляется fail2ban. Правки будут перезаписаны.\n' > "$DENY_SNIPPET"

    # ------------------------------------------------------------------
    # Пороги подобраны по реальному профилю загрузки страницы, а не «на
    # глаз». Одно открытие главной = 1 html + 1 css + 1 favicon + N
    # постеров, то есть при 8 клипах около 12 запросов в зону pages.
    # Живой человек, кликающий по сайту, легко даёт 40-60 запросов в
    # минуту. Прежние 60r/m упирались бы в лимит на третьей странице,
    # а fail2ban превращал бы это в суточный бан.
    # ------------------------------------------------------------------
    cat > "$LIMITS_CONF" <<EOF
# Managed by reality-dest-setup.sh

# Лимиты на IP клиента. Работают корректно только с proxy_protocol +
# real_ip_header, иначе всё схлопнется в один адрес 127.0.0.1.
limit_req_zone  \$binary_remote_addr zone=${SAFE_PREFIX}_pages:10m rate=300r/m;
limit_req_zone  \$binary_remote_addr zone=${SAFE_PREFIX}_video:10m rate=120r/m;
limit_conn_zone \$binary_remote_addr zone=${SAFE_PREFIX}_conn:10m;

# Инструменты массового сканирования интернета. Цензорские пробер-боты
# сюда не попадут — они мимикрируют под браузер, и это нормально:
# задача списка не в маскировке, а в экономии трафика на видео.
# Пустой User-Agent намеренно НЕ блокируется: такой запрос шлют и
# curl-проверки, и часть мониторингов, а 403 на пустой UA — поведение,
# которого у обычного статического сайта не бывает.
map \$http_user_agent \$${SAFE_PREFIX}_bad_ua {
    default 0;
    "~*(zgrab|masscan|nmap|nikto|sqlmap|dirbuster|gobuster|wpscan|hydra|nuclei|censys|shodan)" 1;
}
EOF
    log "Зоны лимитов: $LIMITS_CONF"
else
    disable_hardening
fi

# ============================================================================
# 7. NGINX: ЭТАП 1 (HTTP для ACME)
# ============================================================================
hdr "7. Конфигурация nginx (этап 1: HTTP)"

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
  server_tokens off;

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
# 8. СЕРТИФИКАТ
# ============================================================================
hdr "8. Сертификат Let's Encrypt"

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
# 9. NGINX: ЭТАП 2 (полный конфиг с TLS)
# ============================================================================
hdr "9. Конфигурация nginx (этап 2: TLS)"

if [[ "$HTTP2_STYLE" == "new" ]]; then
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl${LISTEN_EXTRA} default_server;
  http2 on;"
else
    LISTEN_SSL="  listen 127.0.0.1:$SPORT ssl http2${LISTEN_EXTRA} default_server;"
fi

# Копию текущего конфига держим до успешной проверки — на случай отката
[[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "$NGINX_CONF.prev"

HARDEN_SERVER=""
HARDEN_VIDEO=""
HARDEN_STATIC=""
HARDEN_ERRPAGE=""
if (( HARDEN )); then
    HARDEN_SERVER="  include $DENY_SNIPPET;

  # Лимиты отдают 429 — обычный ответ перегруженного сайта.
  # Возврат 444 (обрыв без ответа) здесь недопустим: нормальный
  # веб-сервер так себя не ведёт, и это выдало бы маскировку.
  limit_req_status 429;
  limit_conn_status 429;
  limit_req  zone=${SAFE_PREFIX}_pages burst=100 nodelay;
  limit_conn ${SAFE_PREFIX}_conn 32;

  if (\$${SAFE_PREFIX}_bad_ua) { return 403; }

  # Статике незачем принимать тело запроса
  client_max_body_size 1k;
  client_body_timeout 10s;
  client_header_timeout 10s;"

    HARDEN_VIDEO="    limit_req  zone=${SAFE_PREFIX}_video burst=60 nodelay;
    limit_conn ${SAFE_PREFIX}_conn 16;
    # Первые 4 МБ отдаём на полной скорости (чтобы плеер быстро стартовал),
    # дальше режем до 6 МБ/с на соединение: для просмотра 1080p с запасом,
    # для бота, качающего витрину в 20 потоков, — существенный тормоз.
    limit_rate_after 4m;
    limit_rate 6m;"

    HARDEN_STATIC="    limit_req zone=${SAFE_PREFIX}_pages burst=100 nodelay;"

    # Страницы ошибок отдаются через внутренний редирект, а он заново
    # проходит фазу preaccess — то есть повторно списывает токен лимита
    # у клиента, который в лимит уже упёрся. Щедрый burst здесь это
    # обнуляет, иначе один 429 лавинообразно порождает следующие.
    HARDEN_ERRPAGE="    limit_req zone=${SAFE_PREFIX}_pages burst=200 nodelay;"
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
  server_tokens off;

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

  # Без этого 403/429/50x отдают дефолтную страницу nginx с номером
  # версии, а кастомная 404 — нет. Рассогласование внутри одного сайта
  # заметнее, чем любая из страниц по отдельности.
  server_tokens off;

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

  include $HEAD_SNIPPET;

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

  error_page 404 405 /404.html;
  error_page 400 403 429 500 502 503 504 /error.html;

  location / {
    try_files \$uri \$uri/ \$uri.html =404;
  }

  location = /404.html {
$HARDEN_ERRPAGE
    include $HEAD_SNIPPET;
    internal;
  }

  location = /error.html {
$HARDEN_ERRPAGE
    include $HEAD_SNIPPET;
    internal;
  }

  location /assets/video/ {
$HARDEN_VIDEO
    include $HEAD_SNIPPET;
    add_header Cache-Control "public, max-age=604800" always;
    # Accept-Ranges nginx выставляет сам для статики — плеер сможет перематывать.
  }

  location ~* \.(css|svg|jpg|jpeg|png|ico)\$ {
$HARDEN_STATIC
    include $HEAD_SNIPPET;
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
# 10. FAIL2BAN
# ============================================================================
if (( HARDEN )); then
hdr "10. Настройка fail2ban"

dpkg -s fail2ban &>/dev/null || {
    log "Устанавливаю fail2ban…"
    apt-get install -y -qq fail2ban >/dev/null
}

# --- Отложенная перезагрузка nginx ---
# Без неё каждый бан = отдельный `nginx -t` + reload. Распределённый
# сканер с полусотней адресов превращает защиту в самостоятельную
# нагрузку: полсотни reload'ов подряд рвут keepalive-соединения живых
# клиентов. Здесь reload коалесцируется в один раз в 5 секунд.
cat > "$RELOAD_HELPER" <<EOF
#!/bin/sh
# Managed by reality-dest-setup.sh
# Отложенная и объединённая перезагрузка nginx для fail2ban.
LOCK=/run/${LOG_PREFIX}-reload.lock
exec 9>"\$LOCK" 2>/dev/null || exit 0
# Блокировка удерживается фоновым потомком: если он уже ждёт, перезагрузка
# для этого бана не нужна — она произойдёт вместе с предыдущими.
if flock -n 9; then
    (
        sleep 5
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    ) >/dev/null 2>&1 &
fi
exit 0
EOF
chmod 700 "$RELOAD_HELPER"

# --- Фильтр ---
# Ловим тех, кто перебирает несуществующие пути. Кода 429 здесь НЕТ и
# быть не должно: 429 — это ответ НАШИХ лимитов, в том числе легитимному
# клиенту с быстрым интернетом. Включив его в failregex, мы получаем
# петлю «лимит сработал → бан на сутки» для обычного посетителя.
# <HOST> — первое поле combined-лога, то есть $remote_addr; благодаря
# real_ip_header там реальный IP клиента, а не 127.0.0.1 от Xray.
cat > "$F2B_FILTER" <<'F2BEOF'
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^]]+\] "(GET|POST|HEAD|PUT|DELETE|OPTIONS|PATCH|PROPFIND|TRACE|CONNECT)[^"]*" (403|404) 
            ^<HOST> \S+ \S+ \[[^]]+\] "[^"]*" 400 
ignoreregex = ^<HOST> \S+ \S+ \[[^]]+\] "GET /(favicon\.ico|robots\.txt|sitemap\.xml|apple-touch-icon[^ ]*|\.well-known/[^ ]*)
datepattern = ^[^\[]*\[({DATE})
              {^LN-BEG}
F2BEOF

# --- Действие: бан средствами nginx, НЕ файрвола ---
# Через iptables банить нельзя: на :443 приходят и легитимные клиенты
# Reality, а полный обрыв TLS вместо HTTP-ответа — заметная аномалия,
# которой у настоящего сайта не бывает. Ответ 403 выглядит естественно.
cat > "$F2B_ACTION" <<ACTEOF
[Definition]
actionstart = if [ ! -f ${DENY_SNIPPET} ]; then printf '# Managed by fail2ban\n' > ${DENY_SNIPPET}; fi
actionstop  = printf '# Managed by fail2ban\n' > ${DENY_SNIPPET}
              ${RELOAD_HELPER}
actioncheck =
# grep -qxF: при рестарте fail2ban восстанавливает активные баны и
# повторно вызывает actionban, а дубли deny заваливают лог nginx
# предупреждениями и раздувают сниппет.
actionban   = grep -qxF 'deny <ip>;' ${DENY_SNIPPET} || printf 'deny <ip>;\n' >> ${DENY_SNIPPET}
              ${RELOAD_HELPER}
actionunban = sed -i "\\|^deny <ip>;\$|d" ${DENY_SNIPPET}
              ${RELOAD_HELPER}
ACTEOF

# --- Джейл ---
cat > "$F2B_JAIL" <<JAILEOF
[${LOG_PREFIX}]
enabled  = true
filter   = ${LOG_PREFIX}
logpath  = /var/log/nginx/${LOG_PREFIX}.access.log
action   = ${LOG_PREFIX}-deny
# Порог с запасом: у живого посетителя пара 404 набегает легко,
# у сканера — десятки за минуту.
maxretry = 25
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
    warn "И проверьте фильтр: fail2ban-regex /var/log/nginx/${LOG_PREFIX}.access.log $F2B_FILTER"
fi
fi

# ============================================================================
# 11. ПРОВЕРКИ
# ============================================================================
hdr "11. Проверка работоспособности"

sleep 1
FAILED=0

curl_dest() {
    local path="$1"; shift
    local args=(-ks --max-time 20 --resolve "$DOMAIN:$SPORT:127.0.0.1")
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

# --- статика и служебные страницы ---
CODE=$(curl_dest "/favicon.ico" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
[[ "$CODE" == "200" ]] && log "favicon.ico отдаётся" || warn "favicon.ico вернул '$CODE'"

# Имя css-файла берём с диска, а не из переменной: при ответе «не
# пересобирать» на диске может лежать витрина, собранная другой версией
# скрипта, с другим именем файла.
CSS_REL=$(cd "$WEB_ROOT" && ls assets/css/*.css 2>/dev/null | head -1 || true)
if [[ -n "$CSS_REL" ]]; then
    CODE=$(curl_dest "/$CSS_REL" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    [[ "$CODE" == "200" ]] && log "CSS отдаётся (/$CSS_REL)" || { err "CSS вернул '$CODE'"; FAILED=1; }
else
    warn "В $WEB_ROOT/assets/css нет css-файла."
fi

# Кастомная 404 должна возвращаться именно с кодом 404, а не 200:
# страница-заглушка с кодом 200 на несуществующем пути — известная примета.
NF=$(curl_dest "/no-such-page-$RANDOM" -o "$TMP_DIR/404.html" -w '%{http_code}' 2>/dev/null || true)
if [[ "$NF" == "404" ]] && grep -qi '</html>' "$TMP_DIR/404.html" 2>/dev/null; then
    log "404 отдаёт кастомную страницу с кодом 404."
else
    warn "404: получен код '$NF' или отдана не наша страница."
fi

# Проверяем, что баннер версии nginx не светится на страницах ошибок
if grep -qi 'nginx/[0-9]' "$TMP_DIR/404.html" 2>/dev/null; then
    warn "На странице ошибки видна версия nginx — проверьте server_tokens."
fi

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
# Воспроизводим реальный профиль: открытие главной тянет html, css,
# favicon и по постеру на каждый клип. Проверяем две такие загрузки
# подряд — именно на этом прежние пороги и ломались.
if (( HARDEN )); then
    RL_FAIL=0; RL_TOTAL=0
    for _round in 1 2; do
        for p in "/" "/${CSS_REL:-assets/css/site.css}" "/favicon.ico" "/about.html" "/contact.html"; do
            C=$(curl_dest "$p" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
            RL_TOTAL=$(( RL_TOTAL + 1 ))
            [[ "$C" == "200" ]] || RL_FAIL=$(( RL_FAIL + 1 ))
        done
        for n in $(seq 1 "${ok:-4}"); do
            [[ -f "$WEB_ROOT/assets/img/poster-${n}.jpg" ]] || continue
            C=$(curl_dest "/assets/img/poster-${n}.jpg" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
            RL_TOTAL=$(( RL_TOTAL + 1 ))
            [[ "$C" == "200" ]] || RL_FAIL=$(( RL_FAIL + 1 ))
        done
    done
    if (( RL_FAIL )); then
        err "Из $RL_TOTAL запросов обычного просмотра $RL_FAIL упёрлись в лимит."
        err "Поднимите rate в $LIMITS_CONF и перезагрузите nginx."
        FAILED=1
    else
        log "Лимиты не мешают нормальному просмотру ($RL_TOTAL запросов — все 200)."
    fi

    # И обратная проверка: сканерский User-Agent должен получить 403.
    C=$(curl_dest "/" -A "Mozilla/5.0 zgrab/0.x" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    [[ "$C" == "403" ]] && log "Сканерский User-Agent получает 403." \
        || warn "Сканерский UA получил '$C' вместо 403 — проверьте map в $LIMITS_CONF."
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
rm -f "$KEYFILE"

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
(( REBUILD_SITE )) && printf "  %-14s ${CYAN}%s (%s клипов, язык %s)${NC}\n" \
    "Витрина:" "${SITE_SIZE:-?}" "${ok:-?}" "${SITE_LANG}"
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
printf "  %-22s %s\n" "Джейл:"         "$F2B_JAIL"
echo "  Кого забанили:       fail2ban-client status ${LOG_PREFIX}"
echo "  Разбанить:           fail2ban-client set ${LOG_PREFIX} unbanip <IP>"
echo "  Проверить фильтр:    fail2ban-regex /var/log/nginx/${LOG_PREFIX}.access.log \\"
echo "                         $F2B_FILTER"
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
echo "  3. Оформление и тексты выведены из имени домена, поэтому на другом"
echo "     домене сайт будет выглядеть иначе. Если хочется большей"
echo "     непохожести — отредактируйте $WEB_ROOT/about.html вручную."
echo
