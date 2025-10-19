#!/bin/bash

set -euo pipefail

# ====================================================================================
#
#          FILE:  check_and_notify.sh
#
#         USAGE:  (запускается через cron)
#
#   DESCRIPTION:  Проверяет VLESS-соединения по готовым конфигам и отправляет
#                 уведомление в Telegram в случае сбоя.
#
#  REQUIREMENTS:  xray, curl
#
# ====================================================================================

# --- НАСТРОЙКИ ---

# Токен вашего Telegram-бота (полученный от @BotFather)
TELEGRAM_BOT_TOKEN=""

# ID вашего чата или канала (полученный от @userinfobot)
TELEGRAM_CHAT_ID=""

# Директория, где лежат готовые .json файлы конфигураций.
CONFIG_DIR="/root/xray/vless_configs"

# URL для теста и таймаут.
TEST_URL="https://www.gstatic.com/generate_204"
CURL_TIMEOUT=15

# Путь к Xray.
XRAY_PATH="/usr/local/bin/xray"

# Директория для хранения файлов состояния (чтобы не спамить уведомлениями).
STATE_DIR="/tmp/vless_monitor_states"

# --- ФУНКЦИЯ УВЕДОМЛЕНИЯ ---
send_telegram_notification() {
    local message="$1"
    # URL-кодируем сообщение для безопасной передачи
    local encoded_message=$(printf %s "$message" | jq -s -R -r @uri)
    
    # Используем curl для отправки сообщения через Telegram Bot API
    curl -s -o /dev/null "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage?chat_id=$TELEGRAM_CHAT_ID&text=$encoded_message"
}

# --- ОСНОВНОЙ СКРИПТ ---

# Создаем директорию для файлов состояния, если ее нет
mkdir -p "$STATE_DIR"

# Проверяем, существуют ли вообще файлы конфигураций
if ! ls "$CONFIG_DIR"/*.json &> /dev/null; then
    echo "Ошибка: В директории $CONFIG_DIR не найдены файлы .json"
    exit 1
fi

# Перебираем все .json файлы в директории
for config_file in "$CONFIG_DIR"/*.json; do

   # --- ИЗМЕНЕНИЕ ---
    # Извлекаем "красивое" имя из самого JSON-файла с помощью jq
    display_name=$(jq -r '.MyComment.displayName' "$config_file")
    
    # Если по какой-то причине имя не нашлось, используем имя файла для подстраховки
    if [[ -z "$display_name" ]]; then
        display_name=$(basename "$config_file" .json)
    fi
 
    # Получаем чистое имя сервера из имени файла
    state_file="$STATE_DIR/$(basename "$config_file" .json).down"

    # Запускаем Xray в фоне
    $XRAY_PATH -config "$config_file" &> /dev/null &
    XRAY_PID=$!
    sleep 2

    # Проверяем, запустился ли Xray
    if ! kill -0 $XRAY_PID 2>/dev/null; then
        if [ ! -f "$state_file" ]; then
            send_telegram_notification "🚨 Тревога: Не удалось запустить Xray для сервера '$display_name'. Проверьте конфигурацию!"
            touch "$state_file" # Создаем файл состояния, чтобы не слать повторно
        fi
        continue # Переходим к следующему конфигу
    fi

    # Выполняем тест
    curl -s --proxy "socks5h://127.0.0.1:10808" -m $CURL_TIMEOUT "$TEST_URL" &> /dev/null
    CURL_EXIT_CODE=$?

    # Останавливаем Xray
    kill $XRAY_PID
    wait $XRAY_PID 2>/dev/null

    # Анализируем результат
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        # ПРОВАЛ. Проверяем, отправляли ли уже уведомление.
        if [ ! -f "$state_file" ]; then
            # Файла состояния нет, значит это первая ошибка. Отправляем уведомление.
            send_telegram_notification "🔴 СБОЙ: VLESS-сервер '$display_name' недоступен! Код ошибки curl: $CURL_EXIT_CODE."
            touch "$state_file" # Создаем файл, чтобы отметить, что сервер упал
        fi
    else
        send_telegram_notification "✔️ ТЕСТ: Сервер '$display_name' успешно проверен и доступен."
        # УСПЕХ. Проверяем, был ли сервер ранее недоступен.
        if [ -f "$state_file" ]; then
            # Файл состояния есть, значит сервер "поднялся".
            send_telegram_notification "✅ ВОССТАНОВЛЕНИЕ: VLESS-сервер '$display_name' снова в строю!"
            rm "$state_file" # Удаляем файл состояния
        fi
    fi
done
