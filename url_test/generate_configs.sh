#!/bin/bash

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
    "vless://5618716e-951b-4253-bdb3-fc7e4c00c19f@64.188.71.51:443?type=tcp&encryption=none&security=reality&pbk=zAHc03ycVZU7Xgh3KyryfTBtoPnY3cOfbBzhIuO8ozw&fp=chrome&sni=mysenko.maximejo.ru&sid=fca89025313b&spx=%2F&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Senko"
    "vless://7eaef568-2059-4cdb-8cb2-565dc3ef8420@216.173.70.200:443?type=tcp&encryption=none&security=reality&pbk=xhAWNelqReUkIK-d7wcRfha8PtOul0Zj1RomYp3dtRg&fp=chrome&sni=myveesp.maximejo.ru&sid=74&spx=%2F&flow=xtls-rprx-vision#%F0%9F%87%B1%F0%9F%87%BB%20Veesp"
    "vless://b968c6bc-6f58-4bcd-a903-6c92e9c8f85b@62.60.149.57:443?type=tcp&encryption=none&security=reality&pbk=YtXaPCNSOJKTxJf-phXA3ANHPy9zFkoVuA9pzlp14Es&fp=chrome&sni=myaeza.maximejo.ru&sid=7acff8cd1a9a&spx=%2F&flow=xtls-rprx-vision#%F0%9F%87%B8%F0%9F%87%AA%20aeza%20-%20rustam"
    "vless://6e06bfb3-019f-4e75-9b92-40f69a619477@95.182.120.76:443?type=tcp&encryption=none&security=reality&pbk=FmZkNpTMLWd4CsRUATADlxSYfxhXBgn_7ehZrmbRXhk&fp=chrome&sni=myhostrus.maximejo.ru&sid=446c41e6&spx=%2F&flow=xtls-rprx-vision#%F0%9F%87%B7%F0%9F%87%BA%20hosting%20-%20russia"
    "vless://2cea6fda-a3d5-4e61-947b-0a68bd1b2367@94.232.40.117:443?type=tcp&encryption=none&security=reality&pbk=nvRuL--gbb_mlsfh9SW_6b7x1HBLiG-QnOQbex5RQDE&fp=chrome&sni=myrocket.maximejo.ru&sid=d43a609f74&spx=%2F&flow=xtls-rprx-vision#%F0%9F%87%B7%F0%9F%87%BA%20Rocketcloud"
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

    SERVER_NAME=$(echo "${stripped_url}" | cut -d'#' -f2 | sed 's/[^a-zA-Z0-9_-]//g')
    if [[ -z "$SERVER_NAME" ]]; then
        SERVER_NAME=$(echo "${stripped_url}" | cut -d'@' -f2 | cut -d':' -f1)
    fi

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
