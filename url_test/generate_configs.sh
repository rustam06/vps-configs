#!/bin/bash

set -euo pipefail

# ====================================================================================
#
#          FILE:  generate_configs.sh
#
#         USAGE:  ./generate_configs.sh
#
#   DESCRIPTION:  Парсит VLESS-ссылки и создает постоянные файлы конфигурации
#                 для Xray в указанной директории.
#
#  REQUIREMENTS:  jq
#
# ====================================================================================

# --- НАСТРОЙКИ ---

# Массив с вашими VLESS REALITY ссылками для парсинга.
declare -a VLESS_CONFIGS=(
    # Добавьте больше ссылок сюда...
)

# Директория, куда будут сохранены готовые .json файлы.
# Убедитесь, что у скрипта есть права на запись в эту директорию.
# Рекомендуется использовать абсолютный путь.
CONFIG_DIR="/root/xray/vless_configs"

# Локальный SOCKS порт, который будет прописан в каждую конфигурацию.
LOCAL_SOCKS_PORT=10808

# --- ЦВЕТА ДЛЯ ВЫВОДА ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- ФУНКЦИИ (взяты из предыдущего скрипта) ---

# URL-декодер
url_decode() {
    # Используем встроенную возможность printf для декодирования
    printf '%b' "${1//%/\\x}"
}

# Функция для парсинга VLESS URL.
parse_vless_url() {
    local url=$1
    local stripped_url=${url#"vless://"}

# --- ИЗМЕНЕНИЕ ---
    # 1. Извлекаем закодированное имя
    local encoded_name=$(echo "${stripped_url}" | cut -d'#' -f2)
    # 2. Декодируем его в "красивое" имя
    PRETTY_NAME=$(url_decode "$encoded_name")
    # 3. Создаем "безопасное" имя для файла
    SAFE_FILENAME=$(echo "$PRETTY_NAME" | sed -e 's/[^a-zA-Z0-9_-]/-/g' -e 's/--\+/-/g' -e 's/^-//' -e 's/-$//')

    local creds_and_server=$(echo "${stripped_url}" | cut -d'?' -f1 | cut -d'#' -f1)
    UUID=$(echo "${creds_and_server}" | cut -d'@' -f1)
    SERVER_ADDRESS=$(echo "${creds_and_server}" | cut -d'@' -f2 | cut -d':' -f1)
    SERVER_PORT=$(echo "${creds_and_server}" | cut -d'@' -f2 | cut -d':' -f2)

    local query_string=$(echo "${stripped_url}" | cut -d'?' -f2 | cut -d'#' -f1)

    SNI=$(echo "$query_string" | grep -oP 'sni=\K[^&]+')
    PUBLIC_KEY=$(echo "$query_string" | grep -oP 'pbk=\K[^&]+')
    SHORT_ID=$(echo "$query_string" | grep -oP 'sid=\K[^&]+')
    FINGERPRINT=$(echo "$query_string" | grep -oP 'fp=\K[^&]+')
    FLOW=$(echo "$query_string" | grep -oP 'flow=\K[^&]+')
}

# Функция для генерации JSON конфигурации.
generate_xray_config() {
    local output_file="$1"
    # Используем jq для корректной генерации JSON и лучшей читаемости
    jq -n \
      --arg listen "127.0.0.1" --argjson port "$LOCAL_SOCKS_PORT" \
      --arg address "$SERVER_ADDRESS" --argjson server_port "$SERVER_PORT" \
      --arg uuid "$UUID" --arg flow "$FLOW" \
      --arg sni "$SNI" --arg fp "$FINGERPRINT" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" \
      --arg pretty_name "$PRETTY_NAME" \
      '{
          "inbounds": [
              {
                  "listen": $listen,
                  "port": $port,
                  "protocol": "socks",
                  "settings": { "auth": "noauth", "udp": true }
              }
          ],
          "outbounds": [
              {
                  "protocol": "vless",
                  "settings": {
                      "vnext": [
                          {
                              "address": $address,
                              "port": $server_port,
                              "users": [ { "id": $uuid, "flow": $flow, "encryption": "none" } ]
                          }
                      ]
                  },
                  "streamSettings": {
                      "network": "tcp",
                      "security": "reality",
                      "realitySettings": {
                          "serverName": $sni,
                          "fingerprint": $fp,
                          "publicKey": $pbk,
                          "shortId": $sid
                      }
                  }
              }
          ],
	  "MyComment": {
              "displayName": $pretty_name
          }
      }' > "$output_file"
}

# --- ОСНОВНОЙ СКРИПТ ---

echo "--- Запуск генератора конфигураций VLESS ---"

# Проверяем наличие jq
if ! command -v jq &> /dev/null; then
    echo "Ошибка: Утилита 'jq' не найдена. Пожалуйста, установите ее (sudo apt install jq)."
    exit 1
fi

# Создаем директорию для конфигов, если она не существует
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Создаем директорию для конфигураций: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
fi

# Перебираем все ссылки
for config_url in "${VLESS_CONFIGS[@]}"; do
    echo -e "\n${YELLOW}Обработка ссылки...${NC}"
    parse_vless_url "$config_url"

    if [[ -z "$SAFE_FILENAME" ]]; then
        echo "Не удалось определить имя сервера. Пропускаем."
        continue
    fi
    
    OUTPUT_JSON_PATH="$CONFIG_DIR/$SAFE_FILENAME.json"
    echo "  -> Красивое имя: $PRETTY_NAME"
    echo "  -> Имя сервера: $SAFE_FILENAME"
    echo "  -> Создание файла: $OUTPUT_JSON_PATH"
    
    generate_xray_config "$OUTPUT_JSON_PATH"
done

echo -e "\n${GREEN}--- Генерация конфигураций успешно завершена! ---${NC}"
echo "Файлы сохранены в директории: $CONFIG_DIR"
