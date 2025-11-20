#!/bin/bash

set -Eeuo pipefail

# --- 0. Проверка на root ---
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт необходимо запустить с правами root (используйте sudo)." 
    exit 1
fi

echo "--- Начинаю автоматическую настройку сервера ---"

# --- Константы ---
SSHD_OVERRIDE_FILE="/etc/ssh/sshd_config.d/01-my-overrides.conf"
MAIN_SSHD_CONFIG="/etc/ssh/sshd_config"
SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_OVERRIDE_FILE="$SOCKET_OVERRIDE_DIR/custom-port.conf"

# --- 1.1 Запрос данных от пользователя ---

# Запрос нового порта
read -p "Введите новый SSH порт (например, 8516): " new_port

# Проверка, что введено число в допустимом диапазоне
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
    echo "Ошибка: Введите корректный номер порта (1024-65535)."
    exit 1
fi

# Отключение входа root
read -p "Отключить вход для root (рекомендуется)? (Y/n): " disable_root

# Отключение входа по паролю
echo
echo "ВНИМАНИЕ: Отключение входа по паролю ЗАБЛОКИРУЕТ вам доступ,"
echo "если у вас НЕ настроен вход по SSH-ключу."
read -p "Отключить вход по паролю (ТОЛЬКО если у вас есть SSH-ключ)? (Y/n): " disable_pass

# --- 1.2 Создание конфига для sshd ---
echo "Создаю файл $SSHD_OVERRIDE_FILE..."
# Начинаем файл с нового порта
cat <<EOF > "$SSHD_OVERRIDE_FILE"
# --- Персональные настройки SSH (Приоритет 01) ---
Port $new_port
EOF

# Добавляем отключение root, если выбрано
if [[ "$disable_root" != "n" && "$disable_root" != "N" ]]; then
    echo "PermitRootLogin no" >> "$SSHD_OVERRIDE_FILE"
    echo " - Добавлено: PermitRootLogin no"
else
    echo " - Вход для root оставлен (не рекомендуется)."
fi

# Добавляем "золотую триаду" для отключения пароля, если выбрано
if [[ "$disable_pass" != "n" && "$disable_pass" != "N" ]]; then
    cat <<EOF >> "$SSHD_OVERRIDE_FILE"

# Полное отключение входа по паролю
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
EOF
    echo " - Добавлено: Полное отключение входа по паролю (3 директивы)."
else
    echo " - Вход по паролю оставлен включенным."
fi

# --- 1.3 Комментирование старого порта в основном конфиге ---
echo "Комментирую активный 'Port' в $MAIN_SSHD_CONFIG (создаю бэкап .bak)..."
# -i.bak создает бэкап
# Эта команда ищет ТОЛЬКО незакомментированные строки 'Port' и комментирует их
sed -i.bak 's/^[[:space:]]*Port /#Port /' "$MAIN_SSHD_CONFIG"

# --- 2. Настройка Firewall (UFW) ---
echo
echo "--- 2. Настройка Firewall (UFW) ---"

# Проверка и установка UFW (для Debian/Ubuntu)
if ! command -v ufw &> /dev/null; then
    echo "UFW не найден. Устанавливаю..."
    apt update
    apt install ufw -y
else
    echo "UFW уже установлен."
fi

if ufw status | grep -q "Status: active"; then
    echo "UFW уже активен. Пропускаю настройку правил по умолчанию."
else
    # UFW неактивен, значит, это, скорее всего, первая настройка.
    echo "Настраиваю правила UFW по умолчанию..."
    ufw default deny incoming  # Запретить весь входящий трафик
    ufw default allow outgoing # Разрешить весь исходящий трафик
fi

# ВАЖНО: Мы *в любом случае* должны убедиться, что новый SSH-порт открыт.
echo "Открываю (или подтверждаю) новый SSH порт $new_port/tcp..."
ufw allow $new_port/tcp

# --- НОВЫЙ БЛОК: Запрос дополнительных портов ---
echo
read -p "Введите ДОПОЛНИТЕЛЬНЫЕ порты для UFW через пробел (например, 80, 443, 8080). Нажмите Enter, чтобы пропустить: " custom_ports

if [ -n "$custom_ports" ]; then
    echo "Открываю дополнительные порты..."
    # Мы используем 'for port in $custom_ports' без кавычек.
    # Это намеренно, чтобы bash "разбил" строку по пробелам на отдельные слова (порты).
    for port in $custom_ports; do
        # Валидация каждого порта
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "Открываю порт $port/tcp..."
            ufw allow $port/tcp
        else
            echo "Ошибка: '$port' - некорректный номер порта. Пропускаю."
        fi
    done
else
    echo "Дополнительные порты не указаны."
fi
# --- КОНЕЦ НОВОГО БЛОКА ---

# --- 3. Установка и настройка Fail2Ban ---
echo
echo "--- 3. Установка Fail2Ban ---"
apt install fail2ban -y

echo "Скачиваю jail.local..."
# Проверка и установка curl, если его нет
if ! command -v curl &> /dev/null; then
    apt install curl -y
fi
curl -Lo /etc/fail2ban/jail.local "https://raw.githubusercontent.com/rustam06/vps-configs/refs/heads/main/jail.local"
    
if [ $? -eq 0 ]; then
    echo "Файл jail.local успешно скачан."
else
    echo "Ошибка: не удалось скачать файл с https://raw.githubusercontent.com/rustam06/vps-configs/refs/heads/main/jail.local"
fi

echo "Запускаю Fail2Ban..."

sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# --- 4. Настройка sysctl.conf ---
# --- ИЗМЕНЕНО: Используем /etc/sysctl.d/ для безопасности ---
echo
echo "--- 4. Добавление настроек в /etc/sysctl.d/99-custom-tuning.conf ---"

# Добавляем каркас в отдельный файл, а не перезаписываем /etc/sysctl.conf
cat << EOF > /etc/sysctl.d/99-custom-tuning.conf
# Performance
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Backlogs/queues
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_max_syn_backlog = 4096

# Buffers 
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304

# Timeouts & features
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn = 2
net.ipv4.ip_local_port_range = 10240 65535

# Security (IPv4)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Отключение ipv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Memory
vm.swappiness = 10
EOF

echo "Каркас настроек добавлен. Применяю изменения sysctl..."
sysctl -p /etc/sysctl.d/99-custom-tuning.conf

# --- 5. Настройка Sudo NOPASSWD ---
echo
echo "--- 5. Настройка Sudo NOPASSWD ---"

echo "ВНИМАНИЕ: Это действие (NOPASSWD) снижает безопасность."
echo "Оно позволяет пользователям из группы 'sudo' выполнять команды"
echo "без ввода пароля."

# ПРАВИЛЬНО
read -p "Вы уверены, что хотите включить NOPASSWD для группы sudo? (Y/n): " sudo_nopasswd
if [[ "$sudo_nopasswd" != "n" && "$sudo_nopasswd" != "N" ]]; then
    echo "Добавляю правило NOPASSWD для группы sudo..."
    echo "%sudo   ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-custom-sudo-nopasswd
    # Устанавливаем правильные права
    chmod 440 /etc/sudoers.d/90-custom-sudo-nopasswd
else
    echo "Настройки Sudo не изменены."
fi


# --- 6. Финальное применение ---

# Определяем цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo
echo -e "${GREEN}--- ✅ Настройка сервера почти завершена! ---${NC}"
echo
echo -e "${YELLOW}Остался последний шаг: ${RED}применить все изменения.${NC}"
echo

read -p "Вы готовы применить изменения и разорвать сессию? (Y/n): " confirm_apply

if [[ "$confirm_apply" == "n" || "$confirm_apply" == "N" ]]; then
    echo -e "${YELLOW}Отменено. Настройки не применены.${NC}"
    echo "Вы можете применить их вручную:"
    echo "systemctl daemon-reload && yes | ufw enable && systemctl restart ssh && systemctl restart ssh.socket && ufw status"
    exit 0
fi

echo
echo -e "${GREEN}Применяю настройки... Сессия сейчас прервется.${NC}"
echo "Не забудьте открыть НОВЫЙ терминал и подключиться к порту $new_port"
sleep 2 # Даем пользователю секунду прочитать

# --- ЭТО ПОСЛЕДНИЕ КОМАНДЫ СКРИПТА ---
# Они разорвут соединение
systemctl daemon-reload
systemctl restart ssh
systemctl restart ssh.socket
yes | ufw enable
ufw status
