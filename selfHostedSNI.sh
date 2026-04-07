#!/bin/bash

set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от root."
  exit 1
fi

# Значение порта по умолчанию
DEFAULT_PORT=8443
SPORT=$DEFAULT_PORT

# Проверка системы
if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт поддерживает только Debian или Ubuntu. Завершаю работу."
    exit 1
fi

# Проверяем, свободен ли порт по умолчанию
if ss -tuln | grep -q ":$DEFAULT_PORT "; then
    echo "⚠️ Порт $DEFAULT_PORT занят."
    read -p "Введите другой порт (например, 9443): " CUSTOM_PORT
    # Проверяем, что введено что-то
    if [[ -z "$CUSTOM_PORT" ]]; then
        echo "Порт не введён. Завершаю работу."
        exit 1
    fi
    # Проверяем, что это число
    if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]]; then
        echo "Ошибка: порт должен быть числом."
        exit 1
    fi
    # Проверяем, свободен ли выбранный порт
    if ss -tuln | grep -q ":$CUSTOM_PORT "; then
        echo "Ошибка: порт $CUSTOM_PORT также занят. Завершаю работу."
        exit 1
    fi
    SPORT=$CUSTOM_PORT
    echo "✅ Используем порт $SPORT."
else
    echo "✅ Порт $DEFAULT_PORT свободен, используем его."
fi

port80_allowed=true # По умолчанию считаем, что все ОК
reason="UFW не установлен или неактивен." 

# Проверка UFW
if command -v ufw >/dev/null 2>&1; then
    # Проверяем статус, только если ufw существует
    ufw_status=$(ufw status verbose 2>/dev/null || true)
    
    if echo "$ufw_status" | grep -qE "^Status: active"; then
        # Если UFW активен, порт считается заблокированным, пока не найдем правило.
        port80_allowed=false
        reason="UFW активен, но правило для 80/tcp не обнаружено."
        
        if echo "$ufw_status" | grep -qE "^80/tcp\s+ALLOW"; then
            # Нашли разрешающее правило
            port80_allowed=true
            reason="UFW: 80/tcp явно разрешён."
        fi
    fi
fi

# Результат проверки
if [ "$port80_allowed" = true ]; then
    echo "OK — порт 80, судя по локальным правилам фаервола, разрешён. ($reason)"
else
    echo "ВНИМАНИЕ — похоже, входящие на порт 80 локально не разрешены. ($reason)"
    exit 1
fi

# Проверка и установка нужных пакетов
apt update
# Добавлены unzip, curl и wget для работы с архивами сайтов
for pkg in dnsutils iproute2 nginx certbot python3-certbot-nginx git unzip wget curl; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "Пакет $pkg не найден. Устанавливаю..."
        apt install -y "$pkg"
    else
        echo "Пакет $pkg уже установлен."
    fi
done

# Запрос доменного имени для SNI
read -p "Введите доменное имя для SNI (маскировки): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Домен не может быть пустым."
    exit 1
fi

# Запрос почты
read -p "Введите вашу почту (для Let's Encrypt): " MAIL
if [[ -z "$MAIL" ]]; then
    echo "Почта не может быть пустой."
    exit 1
fi

# Получение внешнего IP сервера
external_ip=$(curl -s --max-time 3 https://api.ipify.org)

# Проверка, что curl успешно получил IP
if [[ -z "$external_ip" ]]; then
  echo "Не удалось определить внешний IP сервера. Проверьте подключение к интернету."
  exit 1
fi

echo "Внешний IP сервера: $external_ip"

# Получение A-записи домена
domain_ip=$(dig +short A "$DOMAIN")

# Проверка, что A-запись существует
if [[ -z "$domain_ip" ]]; then
  echo "Не удалось получить A-запись для домена $DOMAIN. Убедитесь, что домен существует."
  exit 1
fi

echo "A-запись домена $DOMAIN указывает на: $domain_ip"

# Сравнение IP адресов
if [[ "$domain_ip" == "$external_ip" ]]; then
  echo "A-запись домена $DOMAIN соответствует внешнему IP сервера."
else
  echo "A-запись домена $DOMAIN не соответствует внешнему IP сервера."
  exit 1
fi

# Каталог назначения
DEST_DIR="/var/www/html"

echo "Подготовка каталога $DEST_DIR..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# --- ЗАГРУЗКА ПОЛНОЦЕННОГО САЙТА (МАСКИРОВКИ) ---
echo "Загрузка и установка полноценного сайта для маскировки..."

# Список архивов с качественными шаблонами сайтов-визиток, блогов и агентств
TEMPLATES=(
    "https://github.com/StartBootstrap/startbootstrap-clean-blog/archive/refs/heads/master.zip"
    "https://github.com/StartBootstrap/startbootstrap-agency/archive/refs/heads/master.zip"
    "https://github.com/StartBootstrap/startbootstrap-freelancer/archive/refs/heads/master.zip"
    "https://github.com/StartBootstrap/startbootstrap-resume/archive/refs/heads/master.zip"
    "https://github.com/StartBootstrap/startbootstrap-business-casual/archive/refs/heads/master.zip"
)

# Случайный выбор шаблона
RANDOM_TEMPLATE=${TEMPLATES[$RANDOM % ${#TEMPLATES[@]}]}

echo "Выбран шаблон: $RANDOM_TEMPLATE"

# Скачиваем во временную папку
if ! wget -q -O /tmp/template.zip "$RANDOM_TEMPLATE"; then
    echo "Ошибка при скачивании шаблона. Проверьте интернет-соединение."
    exit 1
fi

# Распаковываем и перемещаем
unzip -q /tmp/template.zip -d /tmp/template_extracted
# GitHub архивы имеют корневую папку (например, startbootstrap-agency-master), 
# поэтому берем содержимое ВНУТРИ этой папки
mv /tmp/template_extracted/*/* "$DEST_DIR"/

# Убираем временные файлы
rm -rf /tmp/template.zip /tmp/template_extracted

# Назначаем права для веб-сервера
chown -R www-data:www-data "$DEST_DIR"
find "$DEST_DIR" -type d -exec chmod 755 {} \;
find "$DEST_DIR" -type f -exec chmod 644 {} \;

echo "Сайт-маскировка успешно установлен!"

# Настройка конфигурации Nginx
# --- ЭТАП 1: Создаем конфиг Nginx ТОЛЬКО для webroot-проверки ---

cat > /etc/nginx/sites-available/sni.conf <<EOF
server {
  listen 80;
  server_name $DOMAIN;

  # Папка, куда Certbot будет класть файлы (и где лежит наш фейковый сайт)
  root /var/www/html;

  # ИСКЛЮЧЕНИЕ: Разрешаем Certbot'у проходить проверку
  location /.well-known/acme-challenge/ {
    try_files \$uri =404;
  }

  # ВСЕ ОСТАЛЬНОЕ: Редиректим на HTTPS
  location / {
    return 301 https://\$host\$request_uri;
  }
}
EOF

# --- Активация Nginx и перезапуск ---
rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/sni.conf /etc/nginx/sites-enabled/sni.conf

if nginx -t; then
  systemctl reload nginx
  echo "Nginx успешно перезагружен (конфиг для webroot готов)."
else
  echo "Ошибка в конфигурации Nginx. Проверьте вывод nginx -t."
  exit 1
fi

# --- ЭТАП 2: Получаем сертификаты ---
echo "Получаем сертификат для SNI ($DOMAIN)..."
sudo certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --agree-tos -m "$MAIL" --non-interactive

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  echo "Ошибка: сертификат для $DOMAIN не был выдан. Проверьте логи certbot."
  exit 1
fi
echo "Сертификат для SNI ($DOMAIN) успешно получен."

# --- ЭТАП 3: Дописываем SSL-блок в конфиг Nginx ---
echo "Сертификаты получены. Добавляем SSL-блок в Nginx..."

cat >> /etc/nginx/sites-available/sni.conf <<EOF

server {
  listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;
  server_name $DOMAIN;

  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
  ssl_session_cache shared:SSL:1m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  add_header X-Frame-Options "DENY" always;
  add_header X-Content-Type-Options "nosniff" always;

  error_log /var/log/nginx/site_error.log warn;
  access_log off;

  real_ip_header proxy_protocol;
  set_real_ip_from 127.0.0.1;
  set_real_ip_from ::1;

  root /var/www/html;
  index index.html;

  location / {
    try_files \$uri \$uri/ =404;
  }
}
EOF

# --- Финальная перезагрузка Nginx ---
if nginx -t; then
  systemctl reload nginx
  echo "Nginx успешно перезагружен (SSL-конфиг активирован)."
else
  echo "КРИТИЧЕСКАЯ ОШИБКА: Не удалось применить SSL-конфиг. Проверьте nginx -t."
  exit 1
fi

# --- Вывод результатов ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo ""
printf "${GREEN}${BOLD}======================================================${NC}\n"
printf "${GREEN}${BOLD}      🚀 Скрипт успешно завершён! 🚀 \n${NC}"
printf "${GREEN}${BOLD}======================================================${NC}\n\n"

printf "${BOLD}Конфигурация для SNI (Reality):\n${NC}"
printf "  %-10s ${YELLOW}%s${NC}\n" "Домен:" "$DOMAIN"
printf "  %-10s ${CYAN}%s${NC}\n" "Cert:" "$CERT_PATH"
printf "  %-10s ${CYAN}%s${NC}\n" "Key:" "$KEY_PATH"
echo ""

printf "${BOLD}Настройки для вашего клиента (Reality/Xray):\n${NC}"
printf "  %-10s ${YELLOW}%s${NC}\n" "Dest:" "127.0.0.1:$SPORT"
printf "  %-10s ${YELLOW}%s${NC}\n" "SNI:" "$DOMAIN"
echo ""
printf "${GREEN}${BOLD}======================================================${NC}\n"
