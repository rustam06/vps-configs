#!/bin/bash
#
# ============================================================================
#  Первичная настройка VPS (Debian 11+/Ubuntu 20.04+) под VLESS Reality
# ============================================================================
#
#  ЗАПУСКАТЬ ТОЛЬКО ТАК:
#      wget -O bootstrap.sh <url> && chmod +x bootstrap.sh && sudo ./bootstrap.sh
#
#  НЕ запускать через `curl ... | bash` — скрипт интерактивный, stdin будет
#  занят пайпом и read сломается посреди работы.
#
#  НАСТОЯТЕЛЬНО рекомендуется запускать внутри tmux/screen:
#      tmux new -s setup
#
#  Логика безопасности:
#   1. Сначала создаётся пользователь с ключом — до любых изменений SSH.
#   2. Новый порт добавляется РЯДОМ со старым (22), а не вместо него.
#   3. Взводится таймер автоотката: если вы не выполните ssh-confirm,
#      сервер сам вернёт рабочую конфигурацию и откроет 22 обратно.
#   4. Только после ssh-confirm порт 22 закрывается.
#
# ============================================================================

set -Eeuo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';     NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
hdr()  { echo; echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

# Понятное сообщение при падении, а не молчаливый выход
trap 'err "Скрипт прерван на строке $LINENO. Изменения могли примениться частично."' ERR

# --- Константы ---
SSHD_OVERRIDE_FILE="/etc/ssh/sshd_config.d/01-hardening.conf"
MAIN_SSHD_CONFIG="/etc/ssh/sshd_config"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/00-sshd.conf"
SYSCTL_FILE="/etc/sysctl.d/99-tuning.conf"
BACKUP_DIR="/root/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="/usr/local/sbin/ssh-rollback"
CONFIRM_SCRIPT="/usr/local/sbin/ssh-confirm"

# ============================================================================
# 0. ПРЕДПОЛЁТНЫЕ ПРОВЕРКИ
# ============================================================================
hdr "0. Предполётные проверки"

[[ $EUID -eq 0 ]] || { err "Нужны права root (sudo ./bootstrap.sh)"; exit 1; }

if [[ ! -t 0 ]]; then
    err "stdin не является терминалом. Скрипт интерактивный."
    err "Скачайте файл и запустите локально, а не через пайп."
    exit 1
fi

# Проверка tmux/screen через дерево процессов.
# Переменные TMUX/STY проверять недостаточно: sudo с env_reset их вырезает,
# su - и sudo -i тоже. Поэтому поднимаемся по родительским PID и ищем
# сам мультиплексор — это работает независимо от окружения.
in_multiplexer() {
    [[ -n "${TMUX:-}" || -n "${STY:-}" ]] && return 0

    # Матчим ТОЛЬКО по comm (имя процесса), не по args: командная строка
    # родителя может случайно содержать слово "tmux" — например при запуске
    # скрипта с таким именем — и дать ложное срабатывание.
    local pid="$PPID" comm depth=0
    while [[ -n "$pid" && "$pid" -gt 1 && "$depth" -lt 20 ]]; do
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]') || break
        [[ -z "$comm" ]] && break
        case "$comm" in
            # tmux ставит себе имя "tmux: server" / "tmux: client";
            # у screen это "screen", "SCREEN" или "screen-4.9.0"
            tmux|tmux:*|screen|SCREEN|screen-*|.screen*) return 0 ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || break
        depth=$((depth + 1))
    done
    return 1
}

if ! in_multiplexer; then
    warn "Не удалось подтвердить, что вы в tmux/screen."
    warn "При обрыве связи скрипт умрёт на середине настройки."
    echo
    echo "Если вы ТОЧНО в tmux — это ложное срабатывание, отвечайте 'y'."
    echo "Если нет — выйдите и запустите: tmux new -s setup"
    read -rp "Продолжить? (y/N): " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "Запустите: tmux new -s setup"; exit 0; }
else
    log "Сессия внутри tmux/screen — обрыв связи не прервёт настройку."
fi

command -v apt-get >/dev/null || { err "Только Debian/Ubuntu."; exit 1; }

mkdir -p "$BACKUP_DIR"
cp -a "$MAIN_SSHD_CONFIG" "$BACKUP_DIR/sshd_config"
[[ -d /etc/ssh/sshd_config.d ]] && cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/sshd_config.d" || true
log "Бэкап SSH-конфигов: $BACKUP_DIR"

export DEBIAN_FRONTEND=noninteractive
log "Обновляю индексы пакетов..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates iproute2 >/dev/null

# ============================================================================
# 1. СИНХРОНИЗАЦИЯ ВРЕМЕНИ  (критично для Reality!)
# ============================================================================
hdr "1. Синхронизация времени"

# Reality проверяет TLS-таймстемпы. Расхождение больше ~1-2 минут ломает
# handshake, а диагностируется это крайне неприятно: клиент просто
# "не подключается" без внятной ошибки.
if ! timedatectl set-ntp true 2>/dev/null; then
    log "Устанавливаю systemd-timesyncd..."
    apt-get install -y -qq systemd-timesyncd >/dev/null
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp true 2>/dev/null || true
fi

sleep 2
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    log "Время синхронизировано: $(date)"
else
    warn "NTP ещё не синхронизировался. Проверьте позже: timedatectl status"
fi

# ============================================================================
# 2. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
# ============================================================================
hdr "2. Создание пользователя с sudo"

while true; do
    read -rp "Имя нового пользователя (например, admin): " USERNAME
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "Некорректное имя. Только строчные латинские буквы, цифры, _ и -"
        continue
    fi
    if id "$USERNAME" &>/dev/null; then
        warn "Пользователь '$USERNAME' уже существует."
        read -rp "Использовать его? (Y/n): " ans
        [[ "$ans" =~ ^[nN]$ ]] && continue
        USER_EXISTED=1
    else
        USER_EXISTED=0
    fi
    break
done

if [[ "$USER_EXISTED" -eq 0 ]]; then
    adduser --disabled-password --gecos "" "$USERNAME" >/dev/null
    log "Пользователь '$USERNAME' создан."
fi

usermod -aG sudo "$USERNAME"
log "Добавлен в группу sudo."

# --- Пароль для sudo ---
# ВАЖНО: --disabled-password ставит '!' в поле пароля. Если оставить так
# и не включить NOPASSWD, то sudo просто не сработает — вводить будет
# нечего. Пароль здесь нужен ТОЛЬКО для sudo: вход по паролю через SSH
# всё равно будет отключён.
echo
echo -e "${YELLOW}Задайте пароль для '$USERNAME'. Он нужен только для sudo —${NC}"
echo -e "${YELLOW}вход по SSH будет исключительно по ключу.${NC}"
echo -e "${YELLOW}Оставьте пустым, чтобы вместо пароля включить NOPASSWD.${NC}"

USE_NOPASSWD=0
while true; do
    read -rsp "Пароль (Enter = NOPASSWD): " p1; echo
    if [[ -z "$p1" ]]; then
        warn "Пароль не задан → будет включён NOPASSWD для этого пользователя."
        warn "Это значит: компрометация пользователя = мгновенный root."
        read -rp "Точно? (y/N): " ans
        if [[ "$ans" =~ ^[yY]$ ]]; then USE_NOPASSWD=1; break; else continue; fi
    fi
    read -rsp "Повторите: " p2; echo
    if [[ "$p1" != "$p2" ]]; then err "Пароли не совпадают."; continue; fi
    if [[ ${#p1} -lt 8 ]]; then err "Минимум 8 символов."; continue; fi
    echo "$USERNAME:$p1" | chpasswd
    log "Пароль установлен."
    unset p1 p2
    break
done

# --- SSH-ключ ---
echo
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
USER_KEYS="$USER_HOME/.ssh/authorized_keys"
mkdir -p "$USER_HOME/.ssh"

key_is_valid() {
    # Единственно надёжный способ проверки — сам ssh-keygen.
    # grep '^ssh-' пропускает ecdsa-*, sk-ssh-*, и ключи с опциями впереди.
    [[ -s "$1" ]] && ssh-keygen -l -f "$1" &>/dev/null
}

if key_is_valid "$USER_KEYS"; then
    log "У пользователя уже есть валидный authorized_keys."
elif key_is_valid /root/.ssh/authorized_keys; then
    cat /root/.ssh/authorized_keys >> "$USER_KEYS"
    log "Ключи скопированы от root ($(ssh-keygen -l -f "$USER_KEYS" | wc -l) шт.)"
else
    warn "Валидных SSH-ключей не найдено ни у root, ни у '$USERNAME'."
    echo "Вставьте ваш ПУБЛИЧНЫЙ ключ (содержимое ~/.ssh/id_ed25519.pub):"
    while true; do
        read -rp "> " PUBKEY
        echo "$PUBKEY" > /tmp/.pubkey.check
        if key_is_valid /tmp/.pubkey.check; then
            cat /tmp/.pubkey.check >> "$USER_KEYS"
            rm -f /tmp/.pubkey.check
            log "Ключ принят: $(ssh-keygen -l -f "$USER_KEYS" | tail -1)"
            break
        fi
        rm -f /tmp/.pubkey.check
        err "Это не похоже на валидный публичный ключ. Попробуйте снова."
    done
fi

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_KEYS"
log "Права на ~/.ssh выставлены."

# --- sudo NOPASSWD (если выбран) ---
if [[ "$USE_NOPASSWD" -eq 1 ]]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /tmp/.sudoers-check
    if visudo -c -f /tmp/.sudoers-check &>/dev/null; then
        install -m 440 /tmp/.sudoers-check "/etc/sudoers.d/90-$USERNAME-nopasswd"
        log "NOPASSWD включён для '$USERNAME'."
    else
        err "Синтаксис sudoers невалиден — правило НЕ добавлено."
        err "Задайте пользователю пароль вручную: passwd $USERNAME"
    fi
    rm -f /tmp/.sudoers-check
fi

# ============================================================================
# 3. КОНФИГУРАЦИЯ SSH
# ============================================================================
hdr "3. Конфигурация SSH"

# --- Порт ---
while true; do
    read -rp "Новый SSH-порт (1024-65535, например 8516): " NEW_PORT
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1024 || NEW_PORT > 65535 )); then
        err "Введите число от 1024 до 65535."; continue
    fi
    if (( NEW_PORT == 22 )); then
        err "22 — это текущий порт, выберите другой."; continue
    fi
    if ss -tlnH "( sport = :$NEW_PORT )" 2>/dev/null | grep -q .; then
        err "Порт $NEW_PORT уже занят:"; ss -tlnp "( sport = :$NEW_PORT )"; continue
    fi
    break
done
log "Выбран порт $NEW_PORT."

# --- КРИТИЧНО: проверка директивы Include ---
# В Ubuntu 20.04 и Debian 11 директивы Include в sshd_config НЕТ.
# Без неё файл в sshd_config.d/ будет молча проигнорирован: SSH останется
# на 22, UFW откроет только новый порт — и вы отрезаны от сервера.
# sshd -t этого не поймает, потому что синтаксис при этом корректный.
mkdir -p /etc/ssh/sshd_config.d
if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$MAIN_SSHD_CONFIG"; then
    log "Директива Include найдена — drop-in файлы работают."
else
    warn "Директива Include ОТСУТСТВУЕТ (типично для Ubuntu 20.04 / Debian 11)."
    warn "Добавляю её первой строкой, иначе настройки будут проигнорированы."
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n%s' \
        "$(cat "$MAIN_SSHD_CONFIG")" > /tmp/.sshd_new
    mv /tmp/.sshd_new "$MAIN_SSHD_CONFIG"
    chmod 644 "$MAIN_SSHD_CONFIG"
    log "Include добавлен."
fi

# --- Комментируем Port в основном конфиге, чтобы не конфликтовал ---
sed -i 's/^[[:space:]]*Port[[:space:]]/#Port /' "$MAIN_SSHD_CONFIG"

# --- Опции хардненинга ---
read -rp "Отключить вход для root? (Y/n): " DISABLE_ROOT
read -rp "Отключить вход по паролю (у вас уже есть ключ)? (Y/n): " DISABLE_PASS

# ВАЖНО: пишем ОБА порта. Порт 22 останется рабочим до тех пор, пока вы
# не подтвердите успешный вход на новый порт командой ssh-confirm.
cat > "$SSHD_OVERRIDE_FILE" <<EOF
# --- Настройки, созданные bootstrap-скриптом ---

# ВРЕМЕННО слушаем оба порта. Порт 22 будет убран командой ssh-confirm
# после того, как вы проверите вход на новый порт.
Port 22
Port $NEW_PORT

# Антибрутфорс на уровне самого sshd
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 10
MaxStartups 10:30:60

# Прочее
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

if [[ ! "$DISABLE_ROOT" =~ ^[nN]$ ]]; then
    echo "PermitRootLogin no" >> "$SSHD_OVERRIDE_FILE"
    log "PermitRootLogin no"
else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_OVERRIDE_FILE"
    warn "root оставлен (только по ключу)."
fi

if [[ ! "$DISABLE_PASS" =~ ^[nN]$ ]]; then
    # Проверяем ключ именно у ТОГО пользователя, под которым будем заходить.
    # Исходная логика "ключ есть у root ИЛИ у кого-то в /home" пропускала
    # случай: ключ только у root + root отключён = входить некем.
    if key_is_valid "$USER_KEYS"; then
        cat >> "$SSHD_OVERRIDE_FILE" <<'EOF'

# Полное отключение парольной аутентификации
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF
        log "Парольный вход отключён (ключ у '$USERNAME' подтверждён)."
    else
        err "Ключ у '$USERNAME' не подтверждён — парольный вход ОСТАВЛЕН."
    fi
else
    warn "Парольный вход оставлен включённым."
fi

chmod 644 "$SSHD_OVERRIDE_FILE"

if sshd -t; then
    log "Синтаксис SSH-конфига корректен."
else
    err "Ошибка в конфиге SSH! Откатываю и выхожу."
    cp -a "$BACKUP_DIR/sshd_config" "$MAIN_SSHD_CONFIG"
    rm -f "$SSHD_OVERRIDE_FILE"
    exit 1
fi

# ============================================================================
# 4. FIREWALL (UFW)
# ============================================================================
hdr "4. Firewall (UFW)"

command -v ufw >/dev/null || { log "Устанавливаю UFW..."; apt-get install -y -qq ufw >/dev/null; }

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Оба порта открыты на время переходного периода
ufw limit 22/tcp comment 'SSH old - closed by ssh-confirm' >/dev/null
ufw limit "$NEW_PORT/tcp" comment 'SSH new' >/dev/null
log "Открыты 22/tcp и $NEW_PORT/tcp (оба с rate-limit)."

echo
echo "Порты для VLESS Reality — обычно 443/tcp."
read -rp "Дополнительные порты через пробел (Enter — пропустить): " EXTRA_PORTS
for p in $EXTRA_PORTS; do
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
        ufw allow "$p/tcp" >/dev/null
        log "Открыт $p/tcp"
    else
        err "'$p' — некорректный порт, пропускаю."
    fi
done

# ============================================================================
# 5. FAIL2BAN
# ============================================================================
hdr "5. Fail2Ban"

apt-get install -y -qq fail2ban >/dev/null

cat > "$FAIL2BAN_JAIL" <<EOF
[DEFAULT]
bantime  = 1w
findtime = 24h
maxretry = 3

# Рецидивистам — растущий бан: 1w -> 2w -> 4w
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 4w

ignoreip = 127.0.0.1/8 ::1

# Баним средствами UFW, а не отдельной цепочкой iptables —
# иначе правила живут в двух местах и путают при отладке.
banaction         = ufw
banaction_allports = ufw

[sshd]
enabled = true
port    = 22,$NEW_PORT
filter  = sshd
backend = systemd
EOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
if fail2ban-client status sshd &>/dev/null; then
    log "Fail2Ban работает, jail sshd активен."
else
    warn "Jail sshd не поднялся. Проверьте: journalctl -u fail2ban -n 50"
    warn "Частая причина — отсутствует python3-systemd для backend=systemd."
fi

# ============================================================================
# 6. SYSCTL (тюнинг под прокси)
# ============================================================================
hdr "6. Сетевой тюнинг (sysctl)"

modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat > "$SYSCTL_FILE" <<'EOF'
# --- Congestion control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Буферы ---
# 32 МБ: при RTT 200 мс (трансконтинентальный канал) 4 МБ упираются
# в окно на ~160 Мбит/с. Для прокси это главное узкое место.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432
net.ipv4.tcp_mem  = 786432 1048576 26777216

# --- Очереди ---
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 65536

# --- Поведение TCP ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535

# --- Безопасность ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
# rp_filter=2 (loose), а не 1: строгий режим ломает асимметричную
# маршрутизацию, если позже добавите WireGuard/AmneziaWG-туннель.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# --- Файловые дескрипторы (Xray открывает много сокетов) ---
fs.file-max = 1000000

# --- Память ---
vm.swappiness = 10
EOF

sysctl --system >/dev/null 2>&1
CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$CC" == "bbr" ]]; then
    log "BBR активен, qdisc: $(sysctl -n net.core.default_qdisc)"
else
    warn "BBR не активировался (текущий: $CC). Возможно, старое ядро."
fi

# IPv6 намеренно НЕ отключается: многие SNI-цели для Reality
# (www.microsoft.com и прочие CDN) резолвятся в AAAA, и отключённый
# IPv6 даёт плавающие обрывы, которые сложно диагностировать.
log "IPv6 оставлен включённым (нужен для многих SNI-целей Reality)."

# --- Лимиты для systemd-сервисов ---
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

# ============================================================================
# 7. SWAP
# ============================================================================
hdr "7. Swap"

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')

if (( SWAP_MB > 0 )); then
    log "Swap уже есть: ${SWAP_MB}MB"
elif (( RAM_MB < 2048 )); then
    warn "RAM ${RAM_MB}MB, swap отсутствует — apt upgrade может уйти в OOM."
    read -rp "Создать swap-файл 2GB? (Y/n): " ans
    if [[ ! "$ans" =~ ^[nN]$ ]]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "Swap 2GB создан и добавлен в fstab."
    fi
else
    log "RAM ${RAM_MB}MB — swap не обязателен."
fi

# ============================================================================
# 8. АВТООБНОВЛЕНИЯ БЕЗОПАСНОСТИ
# ============================================================================
hdr "8. Автоматические обновления безопасности"

read -rp "Включить unattended-upgrades? (Y/n): " ans
if [[ ! "$ans" =~ ^[nN]$ ]]; then
    apt-get install -y -qq unattended-upgrades >/dev/null
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    log "Автообновления безопасности включены."
fi

# ============================================================================
# 9. ПОДГОТОВКА ОТКАТА И ПРИМЕНЕНИЕ
# ============================================================================
hdr "9. Применение с защитой от лок-аута"

read -rp "Через сколько минут откатить, если не подтвердите вход? [10]: " RB_MIN
RB_MIN="${RB_MIN:-10}"
[[ "$RB_MIN" =~ ^[0-9]+$ ]] && (( RB_MIN >= 2 )) || RB_MIN=10

# --- Скрипт отката ---
cat > "$ROLLBACK_SCRIPT" <<ROLLBACK
#!/bin/bash
# Автооткат SSH: срабатывает, если ssh-confirm не был выполнен вовремя.
logger -t ssh-rollback "Таймер сработал — откатываю конфигурацию SSH"
cp -a "$BACKUP_DIR/sshd_config" "$MAIN_SSHD_CONFIG"
rm -f "$SSHD_OVERRIDE_FILE"
if [[ -d "$BACKUP_DIR/sshd_config.d" ]]; then
    rm -rf /etc/ssh/sshd_config.d
    cp -a "$BACKUP_DIR/sshd_config.d" /etc/ssh/sshd_config.d
fi
ufw allow 22/tcp >/dev/null 2>&1
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
logger -t ssh-rollback "Откат завершён, порт 22 восстановлен"
ROLLBACK
chmod 700 "$ROLLBACK_SCRIPT"

# --- Скрипт подтверждения ---
cat > "$CONFIRM_SCRIPT" <<CONFIRM
#!/bin/bash
set -e
[[ \$EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

systemctl stop ssh-rollback.timer 2>/dev/null || true
systemctl reset-failed ssh-rollback.service 2>/dev/null || true
echo "[+] Таймер автоотката отключён."

sed -i '/^Port 22\$/d' "$SSHD_OVERRIDE_FILE"
if sshd -t; then
    systemctl restart ssh.service
    echo "[+] Порт 22 убран из конфига SSH."
else
    echo "[✗] Ошибка конфига — порт 22 оставлен."; exit 1
fi

ufw delete limit 22/tcp >/dev/null 2>&1 || true
ufw delete allow 22/tcp  >/dev/null 2>&1 || true
echo "[+] Порт 22 закрыт в firewall."

sed -i "s/^port    = 22,$NEW_PORT\$/port    = $NEW_PORT/" "$FAIL2BAN_JAIL"
systemctl restart fail2ban
echo "[+] Fail2Ban обновлён."

rm -f "$ROLLBACK_SCRIPT" "$CONFIRM_SCRIPT"
echo
echo "=== Настройка окончательно зафиксирована. SSH только на порту $NEW_PORT ==="
CONFIRM
chmod 700 "$CONFIRM_SCRIPT"

echo
echo -e "${YELLOW}${BOLD}Сейчас применятся все настройки. Текущая сессия НЕ прервётся —${NC}"
echo -e "${YELLOW}${BOLD}порт 22 остаётся открытым до вашего подтверждения.${NC}"
read -rp "Применить? (Y/n): " ans
if [[ "$ans" =~ ^[nN]$ ]]; then
    warn "Отменено. SSH-конфиг создан, но не применён."
    echo "Применить вручную: systemctl restart ssh.service && ufw --force enable"
    exit 0
fi

systemctl daemon-reload
ufw --force enable >/dev/null
log "UFW включён."

# Сокет-активация (Ubuntu 22.10+, Debian 12+) игнорирует директиву Port
# в sshd_config — порт задаётся юнитом сокета. Переходим на ssh.service.
systemctl disable --now ssh.socket &>/dev/null || true
systemctl enable ssh.service &>/dev/null || true
systemctl restart ssh.service

sleep 2
if ss -tlnH "( sport = :$NEW_PORT )" 2>/dev/null | grep -q .; then
    log "Подтверждено: sshd слушает порт $NEW_PORT."
else
    err "sshd НЕ слушает порт $NEW_PORT! Откатываю немедленно."
    "$ROLLBACK_SCRIPT"
    exit 1
fi

# Взводим таймер отката
systemd-run --unit=ssh-rollback --on-active="${RB_MIN}min" \
    "$ROLLBACK_SCRIPT" >/dev/null 2>&1
log "Таймер автоотката взведён на $RB_MIN минут."

# ============================================================================
# ИТОГ
# ============================================================================
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

cat <<FINAL

$(echo -e "${GREEN}${BOLD}")============================================================
  НАСТРОЙКА ПРИМЕНЕНА — ТРЕБУЕТСЯ ПОДТВЕРЖДЕНИЕ
============================================================$(echo -e "${NC}")

$(echo -e "${RED}${BOLD}НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ.$(echo -e "${NC}")")

Шаг 1. Откройте НОВЫЙ терминал и выполните:

    $(echo -e "${CYAN}")ssh -p $NEW_PORT $USERNAME@${SERVER_IP:-<IP>}$(echo -e "${NC}")

Шаг 2. Убедитесь, что вход прошёл и sudo работает:

    $(echo -e "${CYAN}")sudo whoami$(echo -e "${NC}")

Шаг 3. ТОЛЬКО ПОСЛЕ ЭТОГО зафиксируйте настройки:

    $(echo -e "${CYAN}")sudo $CONFIRM_SCRIPT$(echo -e "${NC}")

$(echo -e "${YELLOW}")Если вы НЕ выполните шаг 3 в течение $RB_MIN минут, сервер
автоматически вернёт старую конфигурацию и откроет порт 22.$(echo -e "${NC}")

------------------------------------------------------------
Что сделано:
  • Пользователь:        $USERNAME (группа sudo)
  • SSH-порт:            22 (временно) + $NEW_PORT
  • Парольный вход:      $([[ ! "$DISABLE_PASS" =~ ^[nN]$ ]] && echo "отключён" || echo "включён")
  • Root-вход:           $([[ ! "$DISABLE_ROOT" =~ ^[nN]$ ]] && echo "запрещён" || echo "только по ключу")
  • UFW:                 активен
  • Fail2Ban:            bantime 1w, инкрементальный
  • BBR + fq:            $CC
  • Бэкапы:              $BACKUP_DIR

Дальше — установка Xray:
  bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  Откройте 443/tcp в UFW, если ещё не открыли.

FINAL
