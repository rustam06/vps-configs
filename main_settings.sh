#!/bin/bash

set -Eeuo pipefail

# --- 0. Проверка на root ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запустить с правами root (используйте sudo)." 
   exit 1
fi

echo "--- Начинаю автоматическую настройку сервера ---"

# --- 1. Настройка SSH ---
echo
echo "--- 1. Настройка /etc/ssh/sshd_config ---"

# Запрос нового порта
read -p "Введите новый SSH порт (например, 2222): " new_port

# Простая проверка, что введено число
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
    echo "Ошибка: Введите корректный номер порта (1024-65535)."
    exit 1
fi

echo "Меняю порт SSH на $new_port..."
# Находим строку Port или #Port и заменяем ее.
sed -i "s/^#\?Port .*/Port $new_port/" /etc/ssh/sshd_config

# Отключение входа root
read -p "Отключить вход для root (рекомендуется)? (Y/n): " disable_root
if [[ "$disable_root" != "n" && "$disable_root" != "N" ]]; then
    echo "Отключаю вход для root..."
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
else
    echo "Вход для root оставлен без изменений."
fi

# Отключение входа по паролю
echo
echo "ВНИМАНИЕ: Отключение входа по паролю ЗАБЛОКИРУЕТ вам доступ,"
echo "если у вас НЕ настроен вход по SSH-ключу."
read -p "Отключить вход по паролю (ТОЛЬКО если у вас есть SSH-ключ)? (Y/n): " disable_pass
if [[ "$disable_pass" != "n" && "$disable_pass" != "N" ]]; then
    echo "Отключаю вход по паролю..."
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
else
    echo "Вход по паролю оставлен без изменений."
fi

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

echo "Настраиваю правила UFW по умолчанию..."
ufw default deny incoming  # Запретить весь входящий трафик
ufw default allow outgoing # Разрешить весь исходящий трафик

echo "Открываю новый SSH порт $new_port/tcp..."
ufw allow $new_port/tcp

# Открываем стандартные порты, если нужно (можно закомментировать)
# ufw allow 80/tcp  # HTTP
# ufw allow 443/tcp # HTTPS

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
echo
echo "--- 4. Добавление настроек в /etc/sysctl.conf ---"

# Добавляем каркас в конец файла
cat << EOF > /etc/sysctl.conf
# Performance
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Backlogs/queues
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# Buffers (Скорректировано для 1GB RAM)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

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
sysctl -p

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
# (Лучше вставить это в самое начало скрипта)
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

# --- Блок с предупреждением ---
echo -e "${RED}╭────────────────────────────────────────────────────────────────╮"
echo -e "│ ${RED}ВНИМАНИЕ! СЛЕДУЮЩИЙ ШАГ РАЗОРВЕТ ЭТУ SSH-СЕССИЮ!${NC}          │"
echo -e "│                                                                      │"
echo -e "│ Будут выполнены следующие команды:                                   │"
echo -e "│   - ${CYAN}Перезапуск SSH с новым портом ${GREEN}$new_port${NC}      │"
echo -e "│   - ${CYAN}Включение файрвола (ufw enable)${NC}                      │"
echo -e "│                                                                      │"
echo -e "│ ${YELLOW}План действий:${NC}                                         │"
echo -e "│ 1. Вы нажимаете 'Y' и Enter.                                         │"
echo -e "│ 2. Эта сессия ${RED}ЗАВИСНЕТ${NC}. Не закрывайте ее сразу.           │"
echo -e "│ 3. Откройте ${GREEN}НОВОЕ${NC} окно терминала.                       │"
echo -e "│ 4. Подключитесь к серверу через ${GREEN}НОВЫЙ ПОРТ: $new_port${NC}   │"
echo -e "╰────────────────────────────────────────────────────────────────╯${NC}"
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
