#!/bin/bash

# --- Настройки ---
# Путь к V2Ray/Xray. 'v2ray' или 'xray', если они в PATH, или /usr/local/bin/xray
V2RAY_BIN="xray" 

# Директория с вашими .json конфигами (созданными Скриптом 1)
CONFIG_DIR="." 

# URL для теста. Он должен быть легковесным и возвращать 'success'.
TEST_URL="https://www.gstatic.com/generate_204" 
# Альтернатива: http://www.msftconnecttest.com/connecttest.txt

# Локальный SOCKS-порт, который будет запускать V2Ray
LOCAL_PORT=10808 

# Таймауты для curl (в секундах)
CONNECT_TIMEOUT=5 # Таймаут на подключение
MAX_TIME=10       # Максимальное общее время на запрос

# --- Конец Настроек ---

# Убедимся, что V2Ray и jq установлены
command -v $V2RAY_BIN >/dev/null 2>&1 || { echo >&2 "Ошибка: '$V2RAY_BIN' не найден. Установите V2Ray/Xray Core."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "Ошибка: 'jq' не найден. Установите 'jq'."; exit 1; }

echo "Запуск теста VLESS конфигураций..."

# Временный файл для полного клиентского конфига
TEMP_CLIENT_CONFIG="temp_client_config.json"

# Функция очистки: будет вызвана при выходе из скрипта
cleanup() {
    # Убиваем процесс V2Ray, если он еще запущен
    if [ ! -z "$V2RAY_PID" ]; then
        kill $V2RAY_PID >/dev/null 2>&1
    fi
    # Удаляем временный конфиг
    rm -f $TEMP_CLIENT_CONFIG
}
# Устанавливаем "ловушку" для вызова cleanup() при выходе (EXIT) или прерывании (INT, TERM)
trap cleanup EXIT INT TERM


# Перебираем все .json файлы в директории
for config_file in $(find "$CONFIG_DIR" -maxdepth 1 -name "*.json" -not -name "$TEMP_CLIENT_CONFIG"); do
    
    echo "------------------------------------"
    printf "Тестируем: %s\n" "$config_file"
    
    # 1. Создаем полный клиентский конфиг, используя 'jq'
    # Он объединяет наш 'inbound' (SOCKS) с 'outbound' (VLESS из файла)
    jq -n --slurpfile outbound "$config_file" '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "port": '$LOCAL_PORT',
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": true, "ip": "127.0.0.1"}
        }],
        "outbounds": $outbound
    }' > $TEMP_CLIENT_CONFIG

    
    # 2. Запускаем V2Ray в фоновом режиме
    $V2RAY_BIN -c $TEMP_CLIENT_CONFIG &
    V2RAY_PID=$! # Сохраняем ID процесса
    
    # Даем V2Ray секунду на запуск
    sleep 1

    # 3. Запускаем тест через curl
    # -s: тихий режим (нет прогресс-бара)
    # -o /dev/null: не выводить результат (тело страницы)
    # -w: формат вывода. %{http_code} - код ответа, %{time_total} - общее время
    # --socks5-hostname: использовать SOCKS5-прокси с DNS-резолвингом на стороне прокси
    CURL_RESULT=$(curl -s -o /dev/null -w "%{http_code}:%{time_total}" \
                    --socks5-hostname 127.0.0.1:$LOCAL_PORT \
                    --connect-timeout $CONNECT_TIMEOUT \
                    -m $MAX_TIME \
                    "$TEST_URL")
    
    CURL_EXIT_CODE=$? # Код завершения самой программы curl

    # 4. Убиваем V2Ray
    kill $V2RAY_PID >/dev/null 2>&1
    V2RAY_PID="" # Сбрасываем PID

    # 5. Анализируем результат
    if [ $CURL_EXIT_CODE -eq 0 ]; then
        HTTP_CODE=$(echo $CURL_RESULT | cut -d: -f1)
        TIME_TOTAL=$(echo $CURL_RESULT | cut -d: -f2)
        
        if [ "$HTTP_CODE" == "204" ]; then
            printf "✅ УСПЕХ   (Код: %s, Время: %s с)\n" "$HTTP_CODE" "$TIME_TOTAL"
        else
            printf "❌ ОШИБКА (HTTP Код: %s, Время: %s с)\n" "$HTTP_CODE" "$TIME_TOTAL"
        fi
    else
        # Curl завершился с ошибкой (например, таймаут)
        printf "❌ ОШИБКА (curl код: %s, таймаут или не удалось подключиться)\n" "$CURL_EXIT_CODE"
    fi
done

echo "------------------------------------"
echo "Тестирование завершено."
