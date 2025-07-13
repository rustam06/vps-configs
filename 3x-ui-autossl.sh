#!/bin/bash

# Выходить немедленно, если команда завершается с ненулевым статусом.
set -e

# --- Переменные ---
DB_PATH="/etc/x-ui/x-ui.db"
CERT_PATH="/etc/ssl/certs/3x-ui-public.key"
KEY_PATH="/etc/ssl/private/3x-ui-private.key"

# --- Функции ---

# Проверка, запущен ли скрипт от имени root
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "Ошибка: Этот скрипт должен быть запущен от имени пользователя root или с использованием sudo." 
       exit 1
    fi
}

# Установка пакетов в зависимости от менеджера пакетов
install_package() {
    local package_name=$1
    if ! command -v "$package_name" &> /dev/null; then
        echo "Пакет '$package_name' не найден, начинаю установку..."
        if [ -x "$(command -v apt-get)" ]; then
            sudo apt-get update -y && sudo apt-get install -y "$package_name"
        elif [ -x "$(command -v yum)" ]; then
            sudo yum install -y "$package_name"
        elif [ -x "$(command -v dnf)" ]; then
            sudo dnf install -y "$package_name"
        elif [ -x "$(command -v pacman)" ]; then
            sudo pacman -S --noconfirm "$package_name"
        else
            echo "Менеджер пакетов не обнаружен. Пожалуйста, установите '$package_name' вручную."
            exit 1
        fi
    else
        echo "Пакет '$package_name' уже установлен."
    fi
}

# Проверка, добавлен ли уже сертификат в базу данных
check_if_ssl_present() {
    # Использование sqlite3 для прямого запроса к базе данных более надежно, чем grep
    local ssl_setting_count
    ssl_setting_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM settings WHERE key = 'webCertFile';")
    if [ "$ssl_setting_count" -gt 0 ]; then
        echo "Настройки SSL сертификата уже присутствуют в базе данных. Выход."
        exit 0
    fi
}

# Генерация самоподписанного SSL-сертификата
gen_ssl_cert() {
    echo "Генерация нового самоподписанного SSL-сертификата..."
    mkdir -p "$(dirname "$KEY_PATH")"
    openssl req -x509 -newkey rsa:4096 -nodes -sha256 \
            -keyout "$KEY_PATH" \
            -out "$CERT_PATH" \
            -days 3650 -subj "/CN=3x-ui"
    echo "Сертификат успешно создан."
}

# Добавление путей к сертификату в базу данных
update_db_settings() {
    echo "Обновление базы данных с путями к сертификатам..."
    local last_id
    last_id=$(sqlite3 "$DB_PATH" "SELECT IFNULL(MAX(id), 0) FROM settings;")
    
    local next_id=$((last_id + 1))
    local second_id=$((next_id + 1))

    # Использование "here document" для большей читаемости
    sqlite3 "$DB_PATH" <<-EOF
INSERT INTO settings (id, key, value) VALUES ($next_id, 'webCertFile', '$CERT_PATH');
INSERT INTO settings (id, key, value) VALUES ($second_id, 'webKeyFile', '$KEY_PATH');
EOF

    echo "База данных успешно обновлена. ID записей: $next_id, $second_id."
}

# --- Основной блок выполнения ---

echo "--- Запуск скрипта настройки SSL для 3x-ui ---"
check_root
install_package "sqlite3"
install_package "openssl"

check_if_ssl_present
gen_ssl_cert
update_db_settings

echo "--- Настройка SSL успешно завершена! ---"
