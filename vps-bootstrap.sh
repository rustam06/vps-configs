#!/usr/bin/env bash
# ============================================================================
#  Первичная настройка VPS под VLESS Reality
#  Цель: Ubuntu 22.04+ / Debian 12+ (проверено на 24.04/25.x и Debian 13)
#
#  ЗАПУСК:  wget -O bootstrap.sh <url> && chmod +x bootstrap.sh && sudo ./bootstrap.sh
#  НЕ через `curl | bash` — скрипт интерактивный, stdin будет занят пайпом.
#
#  ЗАЩИТА ОТ ЛОК-АУТА:
#  sshd слушает СРАЗУ два порта — 22 и новый. Порт 22 закрывается только
#  вручную, командой `sudo ssh-confirm`, после того как вы убедились, что
#  вход на новый порт работает. Поэтому обрыв связи посреди работы скрипта
#  ничем не грозит: в худшем случае всё останется как было.
# ============================================================================

set -Eeuo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*"; }
hdr()  { echo; echo -e "${C}${B}=== $* ===${N}"; }

trap 'err "Прервано на строке $LINENO. Порт 22 остался открытым — доступ не потерян."' ERR

# Голый `read` под `set -e` роняет скрипт при Ctrl-D: EOF возвращает 1 и
# срабатывает ERR-трап посреди диалога. Обёртки дают внятный выход.
ask()  { read -rp  "$1" "$2" || { err "Ввод прерван."; exit 1; }; }
asks() { read -rsp "$1" "$2" || { echo; err "Ввод прерван."; exit 1; }; echo; }

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-hardening.conf"
BACKUP="/root/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
CONFIRM="/usr/local/sbin/ssh-confirm"

# ============================================================================
hdr "0. Предполётные проверки"

[[ $EUID -eq 0 ]] || { err "Нужен root: sudo ./bootstrap.sh"; exit 1; }
[[ -t 0 ]] || { err "stdin не терминал. Скачайте файл и запустите локально."; exit 1; }
command -v apt-get >/dev/null || { err "Только Debian/Ubuntu."; exit 1; }

# Include появился в openssh 8.2: Ubuntu 22.04+ и Debian 12+. Если его нет —
# ОС старше, и drop-in был бы молча проигнорирован (sshd -t это не ловит).
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$SSHD_CONF" || {
    err "В sshd_config нет директивы Include — ОС старше заявленной."
    err "Нужен Ubuntu 22.04+ или Debian 12+. Прерываюсь."; exit 1; }

mkdir -p "$BACKUP" /etc/ssh/sshd_config.d
cp -a "$SSHD_CONF" "$BACKUP/sshd_config"
log "Бэкап sshd_config: $BACKUP"

export DEBIAN_FRONTEND=noninteractive
log "Обновляю индексы пакетов..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl iproute2 ufw >/dev/null

# ============================================================================
hdr "1. Синхронизация времени"

# Reality проверяет TLS-таймстемпы: расхождение больше 1-2 минут ломает
# handshake, и клиент просто "не подключается" без внятной ошибки.
timedatectl set-ntp true 2>/dev/null || {
    apt-get install -y -qq systemd-timesyncd >/dev/null
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp true 2>/dev/null || true; }
sleep 2
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    log "Время синхронизировано: $(date)"
else
    warn "NTP пока не синхронизирован. Проверьте позже: timedatectl status"
fi

# ============================================================================
hdr "2. Пользователь с sudo"

while :; do
    ask "Имя пользователя (например, admin): " USERNAME
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Только a-z, 0-9, _ и -"; continue; }
    break
done

if id "$USERNAME" &>/dev/null; then
    log "Пользователь '$USERNAME' уже существует — использую его."
else
    adduser --disabled-password --gecos "" "$USERNAME" >/dev/null
    log "Пользователь создан."
fi
usermod -aG sudo "$USERNAME"

# --- Пароль для sudo ---
# adduser --disabled-password ставит '!' в поле пароля. Без пароля или
# NOPASSWD sudo не сработает вообще. На вход по SSH это не влияет — он
# в любом случае будет только по ключу.
echo
echo -e "${Y}Пароль нужен только для sudo. Вход по SSH — исключительно по ключу.${N}"
echo -e "${Y}Пустой ввод = включить NOPASSWD (компрометация юзера = сразу root).${N}"
while :; do
    asks "Пароль (Enter = NOPASSWD): " p1
    if [[ -z "$p1" ]]; then
        ask "Точно включить NOPASSWD? (y/N): " a
        [[ "$a" =~ ^[yY]$ ]] || continue
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" > /tmp/.sudo.chk
        if visudo -c -f /tmp/.sudo.chk &>/dev/null; then
            install -m 440 /tmp/.sudo.chk "/etc/sudoers.d/90-$USERNAME-nopasswd"
            log "NOPASSWD включён."
        else
            err "sudoers невалиден, правило НЕ добавлено. Задайте пароль: passwd $USERNAME"
        fi
        rm -f /tmp/.sudo.chk; break
    fi
    asks "Повторите: " p2
    [[ "$p1" == "$p2" ]] || { err "Не совпадают."; continue; }
    (( ${#p1} >= 8 )) || { err "Минимум 8 символов."; continue; }
    echo "$USERNAME:$p1" | chpasswd; unset p1 p2
    log "Пароль установлен."; break
done

# --- SSH-ключ ---
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
KEYS="$USER_HOME/.ssh/authorized_keys"
mkdir -p "$USER_HOME/.ssh"

# Проверяем самим ssh-keygen: grep '^ssh-' пропускает ecdsa-*, sk-ssh-*
# и ключи с опциями впереди.
valid_key() { [[ -s "$1" ]] && ssh-keygen -l -f "$1" &>/dev/null; }

echo
if valid_key "$KEYS"; then
    log "У '$USERNAME' уже есть валидный authorized_keys."
elif valid_key /root/.ssh/authorized_keys; then
    cat /root/.ssh/authorized_keys >> "$KEYS"
    log "Ключи скопированы от root."
else
    warn "Валидных ключей не найдено. Вставьте ваш ПУБЛИЧНЫЙ ключ (~/.ssh/id_ed25519.pub):"
    while :; do
        ask "> " PUBKEY
        printf '%s\n' "$PUBKEY" > /tmp/.pk.chk
        if valid_key /tmp/.pk.chk; then
            cat /tmp/.pk.chk >> "$KEYS"; rm -f /tmp/.pk.chk
            log "Ключ принят: $(ssh-keygen -l -f "$KEYS" | tail -1)"; break
        fi
        rm -f /tmp/.pk.chk; err "Не похоже на валидный публичный ключ."
    done
fi
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"; chmod 600 "$KEYS"

# ============================================================================
hdr "3. Конфигурация SSH"

# Верхняя граница 32767, а не 65535: выше начинается диапазон эфемерных
# портов (net.ipv4.ip_local_port_range, по умолчанию 32768-60999). Порт
# оттуда может быть занят исходящим соединением Xray, и тогда sshd при
# рестарте получит "Address already in use".
while :; do
    ask "Новый SSH-порт (1024-32767, например 8516): " PORT
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 32767 )) \
        || { err "Число от 1024 до 32767."; continue; }
    (( PORT != 443 )) || { err "443 оставьте под Reality."; continue; }
    ss -tlnH "( sport = :$PORT )" 2>/dev/null | grep -q . \
        && { err "Порт $PORT уже занят."; continue; }
    break
done

ask "Запретить вход root? (Y/n): " NO_ROOT
ask "Отключить вход по паролю? (Y/n): " NO_PASS

# Имя 01-*.conf важно: sshd берёт ПЕРВОЕ встреченное значение директивы,
# поэтому наш файл выигрывает у 50-cloud-init.conf, который на облачных
# образах любит ставить PasswordAuthentication yes.
sed -i 's/^[[:space:]]*Port[[:space:]]/#Port /' "$SSHD_CONF"

cat > "$SSHD_DROPIN" <<EOF
# Создано bootstrap-скриптом.
# Порт 22 временный — убирается командой: sudo ssh-confirm
Port 22
Port $PORT

MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60

X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

if [[ ! "$NO_ROOT" =~ ^[nN]$ ]]; then
    echo "PermitRootLogin no" >> "$SSHD_DROPIN"; log "root-вход запрещён."
else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_DROPIN"; warn "root оставлен (по ключу)."
fi

if [[ ! "$NO_PASS" =~ ^[nN]$ ]]; then
    # Проверяем ключ именно у того пользователя, под которым будем заходить.
    if valid_key "$KEYS"; then
        cat >> "$SSHD_DROPIN" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
        log "Парольный вход отключён (ключ у '$USERNAME' подтверждён)."
    else
        err "Ключ не подтверждён — парольный вход ОСТАВЛЕН."
    fi
else
    warn "Парольный вход оставлен включённым."
fi
chmod 644 "$SSHD_DROPIN"

sshd -t || { err "Ошибка конфига SSH, откатываю."; cp -a "$BACKUP/sshd_config" "$SSHD_CONF"; rm -f "$SSHD_DROPIN"; exit 1; }
log "Синтаксис конфига корректен."

# ============================================================================
hdr "4. Firewall (UFW)"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
# `limit` = не больше 6 подключений за 30 сек с одного IP. Этого достаточно
# против брутфорса, отдельный fail2ban при входе по ключу ничего не добавляет.
ufw limit 22/tcp comment 'SSH old' >/dev/null
ufw limit "$PORT/tcp" comment 'SSH new' >/dev/null
ufw allow 443/tcp comment 'Reality' >/dev/null
log "Открыты 22/tcp, $PORT/tcp (rate-limit) и 443/tcp."

ask "Дополнительные порты через пробел (Enter — пропустить): " EXTRA
for p in $EXTRA; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) \
        && { ufw allow "$p/tcp" >/dev/null; log "Открыт $p/tcp"; } \
        || err "'$p' — некорректный порт, пропускаю."
done

# ============================================================================
hdr "5. Сетевой тюнинг"

modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf

cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
# BBR + fq — главный выигрыш для прокси на длинном канале
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 32 МБ: при RTT 200 мс буфер в 4 МБ упирает окно в ~160 Мбит/с
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 2

# loose (2), а не strict (1): строгий режим ломает асимметричную
# маршрутизацию, если позже добавите WireGuard/AmneziaWG
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0

vm.swappiness = 10
EOF

sysctl --system >/dev/null 2>&1
CC=$(sysctl -n net.ipv4.tcp_congestion_control)
[[ "$CC" == bbr ]] && log "BBR активен (qdisc: $(sysctl -n net.core.default_qdisc))" \
                   || warn "BBR не активировался (текущий: $CC)"

# IPv6 намеренно НЕ отключается: многие SNI-цели для Reality резолвятся
# в AAAA, и без IPv6 получаются плавающие обрывы.
log "IPv6 оставлен включённым (нужен для SNI-целей Reality)."

# Лимит дескрипторов НЕ трогаем глобально: официальный xray.service уже
# содержит LimitNOFILE=1000000, а поднятие soft-лимита для всех юнитов
# ломает софт, который перебирает fd до RLIMIT_NOFILE.

# ============================================================================
hdr "6. Swap и автообновления"

RAM=$(free -m | awk '/^Mem:/{print $2}')
SWAP=$(free -m | awk '/^Swap:/{print $2}')
if (( SWAP > 0 )); then
    log "Swap уже есть: ${SWAP}MB"
elif (( RAM < 2048 )); then
    ask "RAM ${RAM}MB, создать swap 2GB? (Y/n): " a
    if [[ ! "$a" =~ ^[nN]$ ]]; then
        # Только dd: fallocate оставляет дырки, и swapon на XFS такой файл
        # отвергает. На BTRFS нужен ещё и NOCOW, поэтому swapon под if —
        # иначе его провал уронил бы весь скрипт через ERR-трап.
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
        chmod 600 /swapfile; mkswap /swapfile >/dev/null
        if swapon /swapfile 2>/dev/null; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            log "Swap 2GB создан."
        else
            rm -f /swapfile
            warn "swapon не сработал (вероятно BTRFS/XFS) — пропускаю, некритично."
        fi
    fi
else
    log "RAM ${RAM}MB — swap не обязателен."
fi

ask "Включить unattended-upgrades? (Y/n): " a
if [[ ! "$a" =~ ^[nN]$ ]]; then
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
hdr "7. Применение"

cat > "$CONFIRM" <<CONFIRM_EOF
#!/usr/bin/env bash
# Закрывает порт 22 после того, как вы проверили вход на новый порт.
set -e
[[ \$EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }
sed -i '/^Port 22\$/d' "$SSHD_DROPIN"
sshd -t || { echo "[x] Ошибка конфига — порт 22 оставлен."; exit 1; }
systemctl restart ssh.service
ufw delete limit 22/tcp >/dev/null 2>&1 || true
ufw delete allow 22/tcp >/dev/null 2>&1 || true
rm -f "$CONFIRM"
echo "[+] Готово. SSH только на порту $PORT."
CONFIRM_EOF
chmod 700 "$CONFIRM"

ufw --force enable >/dev/null

# Сокет-активация (Ubuntu 22.10+, Debian 13) игнорирует Port в sshd_config —
# порт задаётся юнитом сокета. Переключаемся на классический ssh.service.
systemctl daemon-reload
systemctl disable --now ssh.socket &>/dev/null || true
systemctl enable ssh.service &>/dev/null || true
systemctl restart ssh.service
sleep 2

if ss -tlnH "( sport = :$PORT )" 2>/dev/null | grep -q .; then
    log "sshd слушает порт $PORT."
else
    err "sshd НЕ слушает $PORT! Откатываю конфиг, порт 22 остаётся рабочим."
    rm -f "$SSHD_DROPIN"; cp -a "$BACKUP/sshd_config" "$SSHD_CONF"
    systemctl restart ssh.service; exit 1
fi

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

cat <<FINAL

$(echo -e "${G}${B}")=========== НАСТРОЙКА ПРИМЕНЕНА ===========$(echo -e "${N}")

Порт 22 пока ОТКРЫТ — залочить себя нельзя. Не закрывая эту сессию:

  1) $(echo -e "${C}")ssh -p $PORT $USERNAME@${IP:-<IP>}$(echo -e "${N}")
  2) $(echo -e "${C}")sudo whoami$(echo -e "${N}")
  3) $(echo -e "${C}")sudo ssh-confirm$(echo -e "${N}")   ← закроет порт 22

Если шаг 3 не выполнить, ничего страшного не произойдёт: порт 22
просто останется открытым, как и был.

  Пользователь:   $USERNAME (sudo)
  SSH:            22 (временно) + $PORT
  Пароли по SSH:  $([[ ! "$NO_PASS" =~ ^[nN]$ ]] && echo отключены || echo включены)
  Root-вход:      $([[ ! "$NO_ROOT" =~ ^[nN]$ ]] && echo запрещён || echo "только по ключу")
  BBR:            $CC
  Бэкап:          $BACKUP

Дальше — Xray (443/tcp уже открыт):
  bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

FINAL
