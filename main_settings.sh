#!/bin/bash

set -Eeuo pipefail

# --- 0. Проверка на root ---
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт необходимо запустить с правами root (используйте sudo)."
    exit 1
fi

# Определяем цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}--- Начинаю автоматическую настройку сервера ---${NC}"

# --- Константы ---
SSHD_OVERRIDE_FILE="/etc/ssh/sshd_config.d/01-my-overrides.conf"
MAIN_SSHD_CONFIG="/etc/ssh/sshd_config"

# --- 1.1 Запрос данных от пользователя ---

# Запрос нового порта
read -p "Введите новый SSH порт (например, 8516): " new_port

# Проверка, что введено число в допустимом диапазоне
if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
    echo -e "${RED}Ошибка: Введите корректный номер порта (1024-65535).${NC}"
    exit 1
fi

# Отключение входа root
read -p "Отключить вход для root (рекомендуется)? (Y/n): " disable_root

# Отключение входа по паролю
echo
echo -e "${YELLOW}ВНИМАНИЕ: Отключение входа по паролю ЗАБЛОКИРУЕТ вам доступ,${NC}"
echo -e "${YELLOW}если у вас НЕ настроен вход по SSH-ключу.${NC}"
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
    echo -e "${GREEN} - Добавлено: PermitRootLogin no${NC}"
else
    echo -e "${YELLOW} - Вход для root оставлен (не рекомендуется).${NC}"
fi

# Добавляем "золотую триаду" для отключения пароля, если выбрано
if [[ "$disable_pass" != "n" && "$disable_pass" != "N" ]]; then
    # Проверка наличия SSH-ключей перед отключением пароля
    if ! grep -q "^ssh-" /root/.ssh/authorized_keys 2>/dev/null && ! grep -q "^ssh-" /home/*/.ssh/authorized_keys 2>/dev/null; then
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: SSH-ключи не найдены ни у root, ни у пользователей!${NC}"
        echo -e "${YELLOW}Отключение входа по паролю отменено для вашей безопасности.${NC}"
    else
        cat <<EOF >> "$SSHD_OVERRIDE_FILE"

# Полное отключение входа по паролю
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
        echo -e "${GREEN} - Добавлено: Полное отключение входа по паролю (2 директивы + UsePAM).${NC}"
    fi
else
    echo " - Вход по паролю оставлен включенным."
fi

# --- 1.3 Комментирование старого порта в основном конфиге ---
echo "Комментирую активный 'Port' в $MAIN_SSHD_CONFIG (создаю бэкап .bak)..."
sed -i.bak 's/^[[:space:]]*Port /#Port /' "$MAIN_SSHD_CONFIG"

# --- 2. Настройка Firewall (UFW) ---
echo
echo -e "${CYAN}--- 2. Настройка Firewall (UFW) ---${NC}"

# Проверка и установка UFW
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
    echo "Настраиваю правила UFW по умолчанию..."
    ufw default deny incoming
    ufw default allow outgoing
fi

echo "Открываю новый SSH порт $new_port/tcp..."
ufw allow $new_port/tcp

echo
read -p "Введите ДОПОЛНИТЕЛЬНЫЕ порты для UFW через пробел (например, 80 443 8444). Нажмите Enter, чтобы пропустить: " custom_ports

if [ -n "$custom_ports" ]; then
    echo "Открываю дополнительные порты..."
    for port in $custom_ports; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "Открываю порт $port/tcp..."
            ufw allow $port/tcp
        else
            echo -e "${RED}Ошибка: '$port' - некорректный номер порта. Пропускаю.${NC}"
        fi
    done
else
    echo "Дополнительные порты не указаны."
fi

# --- 3. Установка и настройка Fail2Ban ---
echo
echo -e "${CYAN}--- 3. Установка Fail2Ban ---${NC}"
apt install fail2ban -y

echo "Создаю локальный конфиг /etc/fail2ban/jail.local..."
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1w
findtime = 24h
maxretry = 3
# Игнорировать локальный адрес (IPv4 и IPv6)
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $new_port
filter = sshd
backend = systemd
EOF

echo "Запускаю Fail2Ban..."
systemctl enable fail2ban
systemctl start fail2ban

# --- 4. Настройка sysctl.conf ---
echo
echo -e "${CYAN}--- 4. Добавление настроек в /etc/sysctl.d/99-custom-tuning.conf ---${NC}"
echo "Выберите вариант настройки sysctl:"
echo "  1) Включить ТОЛЬКО BBR + FQ (Рекомендуется для VPN / AmneziaWG)"
echo "  2) Полная оптимизация (BBR, буферы, безопасность, отключение IPv6)"
echo "  3) Ничего не менять (Пропустить)"
read -p "Ваш выбор [1/2/3, по умолчанию 1]: " sysctl_choice

# Если пользователь просто нажал Enter, выбираем 1
if [[ -z "$sysctl_choice" ]]; then
    sysctl_choice="1"
fi

case "$sysctl_choice" in
    1)
        echo "Применяю только BBR и FQ..."
        modprobe tcp_bbr || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

        cat << EOF > /etc/sysctl.d/99-custom-tuning.conf
# Performance
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Отключение ipv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Memory
vm.swappiness = 10

EOF
        sysctl -p /etc/sysctl.d/99-custom-tuning.conf
        ;;
        
    2)
        echo "Применяю полную оптимизацию sysctl..."
        modprobe tcp_bbr || true
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

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
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn = 0
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
        sysctl -p /etc/sysctl.d/99-custom-tuning.conf
        ;;
        
    3)
        echo "Пропуск настройки sysctl."
        ;;
        
    *)
        # Обработка ошибки, если ввели какую-то букву или цифру, отличную от 1, 2, 3
        echo "Неверный выбор. Никакие изменения не применены."
        ;;
esac

# --- 5. Настройка Sudo NOPASSWD ---
echo
echo -e "${CYAN}--- 5. Настройка Sudo NOPASSWD ---${NC}"

echo -e "${YELLOW}ВНИМАНИЕ: Это действие (NOPASSWD) снижает безопасность.${NC}"
echo "Оно позволяет пользователям из группы 'sudo' выполнять команды без ввода пароля."

read -p "Вы уверены, что хотите включить NOPASSWD для группы sudo? (Y/n): " sudo_nopasswd
if [[ "$sudo_nopasswd" != "n" && "$sudo_nopasswd" != "N" ]]; then
    echo "Проверяю и добавляю правило NOPASSWD для группы sudo..."
    echo "%sudo   ALL=(ALL) NOPASSWD: ALL" > /tmp/90-custom-sudo-nopasswd
    
    # Безопасная проверка синтаксиса перед применением
    if visudo -c -f /tmp/90-custom-sudo-nopasswd &>/dev/null; then
        mv /tmp/90-custom-sudo-nopasswd /etc/sudoers.d/
        chmod 440 /etc/sudoers.d/90-custom-sudo-nopasswd
        echo -e "${GREEN}Правило NOPASSWD успешно добавлено.${NC}"
    else
        echo -e "${RED}ОШИБКА: Неверный синтаксис sudoers! Действие отменено для безопасности.${NC}"
        rm -f /tmp/90-custom-sudo-nopasswd
    fi
else
    echo "Настройки Sudo не изменены."
fi

# --- 6. Финальное применение ---
echo
echo -e "${GREEN}--- ✅ Настройка сервера почти завершена! ---${NC}"
echo
echo -e "${YELLOW}Остался последний шаг: ${RED}применить все изменения.${NC}"
echo

read -p "Вы готовы применить изменения и перезапустить сервисы? (Y/n): " confirm_apply

if [[ "$confirm_apply" == "n" || "$confirm_apply" == "N" ]]; then
    echo -e "${YELLOW}Отменено. Настройки не применены.${NC}"
    echo "Вы можете применить их вручную:"
    echo "systemctl daemon-reload && ufw --force enable && systemctl disable --now ssh.socket && systemctl enable --now ssh.service && systemctl restart ssh.service"
    exit 0
fi

echo
echo "Проверяю корректность конфигурации SSH..."
if sshd -t; then
    echo -e "${GREEN}Конфигурация SSH корректна.${NC}"
else
    echo -e "${RED}ОШИБКА: Конфигурация SSH содержит ошибки! Отмена рестарта.${NC}"
    sshd -t
    exit 1
fi

echo
echo -e "${GREEN}Применяю настройки... Сессия сейчас прервется.${NC}"
echo "Не забудьте открыть НОВЫЙ терминал и подключиться к порту $new_port"
sleep 3

# Применение настроек
systemctl daemon-reload
ufw --force enable

# Отключаем сокет-активацию (актуально для Ubuntu 22.10+ и Debian 12+) и рестартуем сам сервис
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable --now ssh.service
systemctl restart ssh.service
