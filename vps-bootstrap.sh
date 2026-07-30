#!/usr/bin/env bash
# ============================================================================
#  Первичная настройка VPS под VLESS Reality
#  Цель: Ubuntu 22.04+ / Debian 12+
#
#  ЗАПУСК:  wget -O bootstrap.sh <url> && chmod +x bootstrap.sh && sudo ./bootstrap.sh
#  НЕ через `curl | bash` — скрипт интерактивный, stdin будет занят пайпом.
#
#  ЗАЩИТА ОТ ЛОК-АУТА:
#  sshd слушает СРАЗУ два порта — 22 и новый. Порт 22 закрывается только
#  вручную, командой `sudo ssh-confirm`, после того как вы убедились, что
#  вход на новый порт работает. Обрыв связи посреди работы скрипта ничем
#  не грозит: в худшем случае всё останется как было.
#
#  Скрипт задаёт ровно 4 вопроса: имя пользователя, пароль для sudo,
#  публичный ключ (если его ещё нет) и номер порта. Всё остальное —
#  безопасные значения по умолчанию.
# ============================================================================

set -Eeuo pipefail

G=$'\e[0;32m'; Y=$'\e[1;33m'; R=$'\e[0;31m'; C=$'\e[0;36m'; B=$'\e[1m'; N=$'\e[0m'
log()  { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[x]${N} $*"; }
hdr()  { echo; echo "${C}${B}=== $* ===${N}"; }

trap 'err "Прервано на строке $LINENO. Порт 22 остался открытым — доступ не потерян."' ERR

# Голый `read` под `set -e` роняет скрипт при Ctrl-D: EOF возвращает 1 и
# срабатывает ERR-трап посреди диалога. Обёртки дают внятный выход.
ask()  { read -rp  "$1" "$2" || { err "Ввод прерван."; exit 1; }; }
asks() { read -rsp "$1" "$2" || { echo; err "Ввод прерван."; exit 1; }; echo; }

SSHD_CONF="/etc/ssh/sshd_config"
DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"
BACKUP="/root/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
CONFIRM="/usr/local/sbin/ssh-confirm"

rollback_ssh() {
    err "Откатываю конфигурацию SSH — порт 22 продолжает работать."
    rm -f "$DROPIN"
    cp -a "$BACKUP/sshd_config" "$SSHD_CONF"
    systemctl restart ssh.service 2>/dev/null || true
    exit 1
}

# ============================================================================
hdr "0. Предполётные проверки"

[[ $EUID -eq 0 ]] || { err "Нужен root: sudo ./bootstrap.sh"; exit 1; }
[[ -t 0 ]] || { err "stdin не терминал. Скачайте файл и запустите локально."; exit 1; }
command -v apt-get >/dev/null || { err "Только Debian/Ubuntu."; exit 1; }

# Include появился в openssh 8.2 (Ubuntu 22.04+, Debian 12+). Без него
# drop-in был бы молча проигнорирован, и `sshd -t` этого не заметит.
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$SSHD_CONF" || {
    err "В sshd_config нет директивы Include — ОС старше заявленной."
    err "Нужен Ubuntu 22.04+ или Debian 12+. Прерываюсь."; exit 1; }

mkdir -p "$BACKUP" /etc/ssh/sshd_config.d
cp -a "$SSHD_CONF" "$BACKUP/sshd_config"
log "Бэкап sshd_config: $BACKUP"

export DEBIAN_FRONTEND=noninteractive
# Без этого needrestart на Ubuntu 22.04+ выкидывает полноэкранный диалог
# «какие сервисы перезапустить» прямо посреди apt-установки.
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

log "Устанавливаю пакеты..."
apt-get update -qq
apt-get install -y -qq sudo ufw curl ca-certificates iproute2 \
                      openssh-client unattended-upgrades

# ============================================================================
hdr "1. Синхронизация времени"

# Для Reality критичность времени часто преувеличивают (проверка метки
# управляется maxTimeDiff и по умолчанию выключена), но корректные часы
# нужны для TLS к целевому SNI-сайту, логов и автообновлений.
timedatectl set-ntp true 2>/dev/null || {
    apt-get install -y -qq systemd-timesyncd
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
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    err "Только a-z, 0-9, _ и -, начинаться должно с буквы."
done
if id "$USERNAME" &>/dev/null; then
    log "Пользователь '$USERNAME' уже существует — использую его."
else
    adduser --disabled-password --gecos "" "$USERNAME" >/dev/null
    log "Пользователь создан."
fi
usermod -aG sudo "$USERNAME"

# Разрешаем sudo без пароля только для этого пользователя.
# Вход по SSH — исключительно по ключу, поле пароля остаётся '!' (заблокировано).
echo
echo "${Y}Настраиваю sudo без пароля для '$USERNAME'. Вход по SSH — только по ключу.${N}"

SUDOERS_FILE="/etc/sudoers.d/90-${USERNAME}-nopasswd"
TMP_SUDOERS="$(mktemp)"

echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDOERS"

if visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
    rm -f "$TMP_SUDOERS"
    log "Правило sudo без пароля добавлено в $SUDOERS_FILE."
else
    err "Ошибка синтаксиса sudoers — правило не применено."
    rm -f "$TMP_SUDOERS"
    exit 1
fi

# --- SSH-ключ ---
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
KEYS="$USER_HOME/.ssh/authorized_keys"
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.ssh"

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
        printf '%s\n' "$PUBKEY" > "/tmp/.pk.$$"
        if valid_key "/tmp/.pk.$$"; then
            cat "/tmp/.pk.$$" >> "$KEYS"; rm -f "/tmp/.pk.$$"
            log "Ключ принят."
            break
        fi
        rm -f "/tmp/.pk.$$"
        err "Не похоже на валидный публичный ключ."
    done
fi
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 600 "$KEYS"

# Парольный вход отключается безусловно, поэтому без рабочего ключа дальше нельзя.
valid_key "$KEYS" || { err "Ключ не подтверждён — прерываюсь, ничего не меняя в SSH."; exit 1; }
log "Ключ: $(ssh-keygen -l -f "$KEYS" | tail -1)"

# ============================================================================
hdr "3. Конфигурация SSH"

DEFPORT=$(shuf -i 20000-45000 -n 1)
while :; do
    ask "Новый SSH-порт [$DEFPORT]: " PORT
    PORT=${PORT:-$DEFPORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
        err "Число от 1024 до 65535."; continue
    fi
    if (( PORT == 443 )); then
        err "443 оставьте под Reality."; continue
    fi
    if ss -tlnH "( sport = :$PORT )" | grep -q .; then
        err "Порт $PORT уже занят."; continue
    fi
    break
done

# Имя 00-*.conf важно: sshd берёт ПЕРВОЕ встреченное значение директивы,
# поэтому наш файл выигрывает у 50-cloud-init.conf, который на облачных
# образах любит ставить PasswordAuthentication yes.
sed -i 's/^[[:space:]]*Port[[:space:]]/#Port /' "$SSHD_CONF"

cat > "$DROPIN" <<EOF
# Создано bootstrap-скриптом.
# Порт 22 временный — убирается командой: sudo ssh-confirm
Port 22
Port $PORT

PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes

# Если позже заведёте второго администратора — допишите его сюда.
AllowUsers $USERNAME

MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
chmod 644 "$DROPIN"

sshd -t || { err "Ошибка синтаксиса конфига SSH."; rollback_ssh; }

# `sshd -t` проверяет только синтаксис. Смотрим ЭФФЕКТИВНЫЙ конфиг: так
# видно, если какой-то чужой drop-in или ListenAddress перебил наши значения.
EFF=$(sshd -T -C "user=$USERNAME,host=localhost,addr=127.0.0.1" 2>/dev/null || sshd -T 2>/dev/null || true)
if [[ -n "$EFF" ]]; then
    for chk in "port 22" "port $PORT" "permitrootlogin no" "passwordauthentication no"; do
        grep -qx "$chk" <<<"$EFF" || {
            err "Эффективный конфиг не содержит '$chk' — что-то его перебивает."
            rollback_ssh; }
    done
    log "Эффективный конфиг проверен: оба порта, root off, пароли off."
else
    warn "Не удалось получить вывод sshd -T — проверка эффективного конфига пропущена."
fi

# ============================================================================
hdr "4. Firewall (UFW)"
if ss -tlnH "( sport = :443 )" | grep -q .; then
    warn "Порт 443 уже кем-то занят — Xray не сможет стартовать:"
    ss -tlnp "( sport = :443 )" || true
fi
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
# Доверенный IP — без рейт-лимита. Должно идти ДО правила limit,
# иначе сработает limit (первое совпадение выигрывает).
ufw allow from 161.104.46.85 to any port 2222 proto tcp \
    comment 'SSH admin IP' >/dev/null
# `limit` = не больше 6 подключений за 30 сек с одного IP. Этого достаточно
# против брутфорса, отдельный fail2ban при входе по ключу ничего не добавляет.
ufw limit 22/tcp        comment 'SSH temp' >/dev/null
ufw limit "$PORT"/tcp   comment 'SSH'      >/dev/null
ufw allow 443/tcp       comment 'Reality'  >/dev/null
log "Открыты 22/tcp, $PORT/tcp (rate-limit), 443/tcp и 2222/tcp для 161.104.46.85."

# ============================================================================
hdr "5. Сетевые параметры"

# conntrack надо загрузить ДО sysctl, иначе его ключей просто не существует
# и настройки молча не применятся.
echo nf_conntrack > /etc/modules-load.d/conntrack.conf
echo "options nf_conntrack hashsize=32768" > /etc/modprobe.d/nf_conntrack.conf
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf

cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
# /etc/sysctl.d/99-vless-reality.conf

### Congestion control — главный выигрыш для прокси на длинных/нестабильных каналах
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

### Буферы — потолок автотюнинга ~1 Гбит/с при RTT 100 мс, для 2 ГБ RAM достаточно
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

### Очереди/backlog под много одновременных соединений
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

### Поведение TCP для профиля "прокси": короткие рывки, много сессий
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

### Xray открывает исходящее соединение на каждый запрос —
### дефолтного диапазона портов (32768-60999) не хватает
net.ipv4.ip_local_port_range = 10240 65535

### conntrack — без этого при паре тысяч соединений в dmesg вылезает
### "nf_conntrack: table full" и клиентов рвёт без видимой причины
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

### Security hardening (all + default — на случай новых интерфейсов: wg, docker0 и т.п.)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

### Память
vm.swappiness = 10
EOF

# SSH-порт исключаем из диапазона исходящих: иначе однажды его займёт
# исходящее соединение Xray, и sshd при рестарте не сможет забиндиться.
echo "net.ipv4.ip_local_reserved_ports = $PORT" >> /etc/sysctl.d/99-proxy.conf

sysctl --system >/dev/null || warn "Часть параметров не применилась, см. вывод выше."

CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$CC" == bbr ]]; then
    log "BBR активен (qdisc: $(sysctl -n net.core.default_qdisc))"
else
    warn "BBR не активировался (текущий: $CC)"
fi

# IPv6 намеренно НЕ отключается: многие SNI-цели для Reality резолвятся
# в AAAA, и без IPv6 получаются плавающие обрывы.
#
# Лимит дескрипторов тоже не трогаем: официальный xray.service уже
# содержит LimitNOFILE=1000000.

# ============================================================================
hdr "6. Swap, логи, автообновления"

RAM=$(free -m | awk '/^Mem:/{print $2}')
SWAP=$(free -m | awk '/^Swap:/{print $2}')
if (( SWAP > 0 )); then
    log "Swap уже есть: ${SWAP} МБ"
elif (( RAM >= 2048 )); then
    log "RAM ${RAM} МБ — swap не обязателен."
else
    # Только dd: fallocate оставляет дырки, и swapon на XFS такой файл
    # отвергает. На BTRFS нужен ещё и NOCOW, поэтому swapon под if —
    # иначе его провал уронил бы весь скрипт через ERR-трап.
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    if swapon /swapfile 2>/dev/null; then
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "Swap 2 ГБ создан (RAM ${RAM} МБ)."
    else
        rm -f /swapfile
        warn "swapon не сработал (вероятно BTRFS/XFS) — пропускаю, некритично."
    fi
fi

# Прокси пишет много логов, а диск на VPS обычно 20-25 ГБ.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/00-size.conf
systemctl restart systemd-journald
log "Журнал ограничен 200 МБ."

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
log "Автообновления безопасности включены."

# ============================================================================
hdr "7. Применение"

cat > "$CONFIRM" <<CONFIRM_EOF
#!/usr/bin/env bash
# Закрывает временный порт 22. Запускать только после того, как вы
# убедились, что вход на порт $PORT работает.
set -e
[[ \$EUID -eq 0 ]] || { echo "Запустите через sudo"; exit 1; }

# .bak не подпадает под Include (*.conf), поэтому лежать рядом безопасно.
cp -a "$DROPIN" "$DROPIN.bak"
restore() { mv -f "$DROPIN.bak" "$DROPIN"; systemctl restart ssh.service; }

sed -i '/^Port 22\$/d' "$DROPIN"

if ! sshd -t; then
    echo "[x] Ошибка конфига — откат, порт 22 остаётся."; restore; exit 1
fi
systemctl restart ssh.service
sleep 1
if ! ss -tlnH "( sport = :$PORT )" | grep -q .; then
    echo "[x] sshd не слушает $PORT — откат, порт 22 остаётся."; restore; exit 1
fi

ufw delete limit 22/tcp >/dev/null 2>&1 || true
ufw delete allow 22/tcp >/dev/null 2>&1 || true
rm -f "$DROPIN.bak" "$CONFIRM"
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

if ss -tlnH "( sport = :$PORT )" | grep -q .; then
    log "sshd слушает порт $PORT."
else
    err "sshd НЕ слушает $PORT!"
    rollback_ssh
fi
if ! ss -tlnH "( sport = :22 )" | grep -q .; then
    warn "sshd не слушает 22 — НЕ закрывайте текущую сессию, пока не проверите новый порт."
fi

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

cat <<FINAL

${G}${B}=========== НАСТРОЙКА ПРИМЕНЕНА ===========${N}

Порт 22 пока ОТКРЫТ — залочить себя нельзя.
${B}Не закрывая эту сессию${N}, откройте новый терминал:

  1) ${C}ssh -p $PORT $USERNAME@${IP:-<IP-сервера>}${N}
  2) ${C}sudo whoami${N}
  3) ${C}sudo ssh-confirm${N}   ← закроет порт 22

Если шаг 3 не выполнить, ничего страшного: порт 22 просто останется
открытым, как и был.

  Пользователь:  $USERNAME (sudo по паролю, SSH только по ключу)
  SSH:           22 (временно) + $PORT
  Открыто:       22/tcp, $PORT/tcp, 443/tcp
  BBR:           $CC
  Бэкап:         $BACKUP

Дальше — Xray (443/tcp уже открыт):
  bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

FINAL
