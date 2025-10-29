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

#Проверка UFW
if command -v ufw >/dev/null 2>&1; then
    # Проверяем статус, только если ufw существует
    ufw_status=$(ufw status verbose 2>/dev/null || true)
    
    if echo "$ufw_status" | grep -qE "^Status: active"; then
        # Если UFW активен, наше предположение меняется.
        # Теперь порт считается заблокированным, пока не найдем правило.
        port80_allowed=false
        reason="UFW активен, но правило для 80/tcp не обнаружено."
        
        if echo "$ufw_status" | grep -qE "^80/tcp\s+ALLOW"; then
            # Нашли разрешающее правило — всё снова хорошо.
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
for pkg in dnsutils iproute2 nginx certbot python3-certbot-nginx git; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "Пакет $pkg не найден. Устанавливаю..."
        apt install -y "$pkg"
    else
        echo "Пакет $pkg уже установлен."
    fi
done


# Запрос доменного имени
read -p "Введите доменное имя: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Доменное имя не может быть пустым. Завершаю работу."
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
  echo "Не удалось получить A-запись для домена $DOMAIN. Убедитесь, что домен существует, подробнее что делать вы можете ознакомиться тут: https://wiki.yukikras.net/ru/selfsni"
  exit 1
fi

echo "A-запись домена $DOMAIN указывает на: $domain_ip"

# Сравнение IP адресов
if [[ "$domain_ip" == "$external_ip" ]]; then
  echo "A-запись домена $DOMAIN соответствует внешнему IP сервера."
else
  echo "A-запись домена $DOMAIN не соответствует внешнему IP сервера, подробнее что делать вы можете ознакомиться тут: https://wiki.yukikras.net/ru/selfsni#a-запись-домена-не-соответствует-внешнему-ip-сервера-или-не-удалось-получить-a-запись-для-домена"
  exit 1
fi


# Скачивание репозитория
TEMP_DIR=$(mktemp -d)
git clone https://github.com/learning-zone/website-templates.git "$TEMP_DIR"

# Выбор случайного сайта
SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)

# Каталог назначения
DEST_DIR="/var/www/html"

# Проверяем, существует ли каталог и не пуст ли он
if [ -d "$DEST_DIR" ]; then
    echo "Каталог $DEST_DIR существует, очищаем его..."
    # Удаляем все в каталоге, включая скрытые файлы (.htaccess и т.д.)
    rm -rf "$DEST_DIR"/* "$DEST_DIR"/.* 2>/dev/null
else
    echo "Каталог $DEST_DIR не существует, создаем его..."
    mkdir -p "$DEST_DIR"
fi

cp -r "$SITE_DIR"/* /var/www/html/

# Выпуск сертификата
echo "Выпускаем сертификат обычным способом через HTTP-01..."
certbot --nginx -d "$DOMAIN" --agree-tos -m "admin@$DOMAIN" --non-interactive

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "Ошибка: сертификат не был выдан. Проверьте логи certbot."
    exit 1
fi

# Настройка конфигурации Nginx
cat > /etc/nginx/sites-available/sni.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://$server_name$request_uri;
}

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

  # === ДОБАВЛЕНО: Заголовки для маскировки (бесплатно) ===
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Логи (оставляем access_log выключенным для экономии I/O)
    error_log /var/log/nginx/site_error.log warn;
    access_log off;

    # Настройки Proxy Protocol
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root /var/www/html/;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

rm /etc/nginx/sites-available/default

# Перезапуск Nginx
if nginx -t; then
    systemctl reload nginx
    echo "Nginx успешно перезагружен."
else
    echo "Ошибка в конфигурации Nginx. Проверьте вывод nginx -t."
    exit 1
fi

# Показ путей сертификатов
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo ""
echo ""
echo ""
echo ""
echo "Сертификат и ключ расположены в следующих путях:"
echo "Сертификат: $CERT_PATH"
echo "Ключ: $KEY_PATH"
echo ""
echo "В качестве Dest укажите: 127.0.0.1:$SPORT"
echo "В качестве SNI укажите: $DOMAIN"

# Удаление временной директории
rm -rf "$TEMP_DIR"

echo "Скрипт завершён."
