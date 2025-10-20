#!/usr/bin/env bash
set -Eeuo pipefail

V2RAY_BIN="${V2RAY_BIN:-xray}"
CONFIG_DIR="${CONFIG_DIR:-.}"
TEST_URL="${TEST_URL:-https://www.gstatic.com/generate_204}"
LOCAL_PORT="${LOCAL_PORT:-10808}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"

# --- НОВЫЕ НАСТРОЙКИ ДЛЯ TELEGRAM ---
# Задайте их через переменные окружения перед запуском
# Пример: export TELEGRAM_BOT_TOKEN="ваш_токен"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

send_telegram_notification() {
  local message="$1"
  # Проверяем, заданы ли токен и ID чата. Если нет, ничего не делаем.
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    return
  fi

  # Отправляем сообщение через API Telegram, используя curl
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    --max-time 10 > /dev/null
}

for dep in "$V2RAY_BIN" jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Ошибка: '$dep' не найден."; exit 1; }
done

# 2. НОВАЯ ПРОВЕРКА: ищем файлы .json
config_files_found=$(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.json" | wc -l)

if [[ "$config_files_found" -eq 0 ]]; then
  echo "Ошибка: В директории '$CONFIG_DIR' не найдено конфигурационных файлов .json."
  exit 1
fi
# --- Конец новой проверки ---

echo "Запуск теста VLESS конфигураций..."

TEMP_CLIENT_CONFIG="$(mktemp -t xraytest.XXXXXX.json)"

cleanup() {
  if [[ -n "${V2RAY_PID:-}" ]] && kill -0 "$V2RAY_PID" 2>/dev/null; then
    kill "$V2RAY_PID" >/dev/null 2>&1 || true
    wait "$V2RAY_PID" 2>/dev/null || true
  fi
  rm -f "$TEMP_CLIENT_CONFIG"
}
trap cleanup EXIT INT TERM

# Определяем команду запуска для Xray/V2Ray
if "$V2RAY_BIN" -h 2>&1 | grep -q "run -c"; then
  RUN_CMD=("$V2RAY_BIN" run -c)
else
  RUN_CMD=("$V2RAY_BIN" -c)  # на старых бинарях
fi

while IFS= read -r -d '' config_file; do
  echo "------------------------------------"
  tag="$(jq -r '.tag // empty' "$config_file" 2>/dev/null || true)"
# <-- НОВАЯ СТРОКА: Определяем имя для вывода: тег или имя файла
  display_name="${tag:-$config_file}"

  # <-- ИЗМЕНЕНО: Используем display_name для более понятного вывода
  printf "Тестируем: %s (файл: %s)\n" "$display_name" "$config_file"

  # Пропускаем всё, что не похоже на outbound VLESS
  if ! jq -e 'select(.protocol=="vless")' "$config_file" >/dev/null 2>&1; then
    echo "Пропуск: не VLESS outbound"
    continue
  fi

  # Собираем клиентский конфиг
  jq -e -n --argjson port "$LOCAL_PORT" --slurpfile outbound "$config_file" '{
    log: { loglevel: "warning" },
    inbounds: [{
      port: $port, listen: "127.0.0.1",
      protocol: "socks",
      settings: { auth: "noauth", udp: true }
    }],
    outbounds: $outbound
  }' > "$TEMP_CLIENT_CONFIG"

  # Запуск ядра
  "${RUN_CMD[@]}" "$TEMP_CLIENT_CONFIG" >/dev/null 2>&1 &
  V2RAY_PID=$!
  sleep 0.8

  # Тест
  CURL_RESULT="$(curl -sS -o /dev/null -w "%{http_code}:%{time_total}" \
                    --socks5-hostname "127.0.0.1:$LOCAL_PORT" \
                    --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" \
                    "$TEST_URL" || true)"
  CURL_EXIT_CODE=$?

  # Остановка
  kill "$V2RAY_PID" >/dev/null 2>&1 || true
  wait "$V2RAY_PID" 2>/dev/null || true
  V2RAY_PID=""

  # Разбор результата
  if [[ $CURL_EXIT_CODE -eq 0 ]]; then
    IFS=: read -r HTTP_CODE TIME_TOTAL <<<"$CURL_RESULT"
    if [[ "$HTTP_CODE" == "204" ]]; then
      printf "✅ УСПЕХ   (Код: %s, Время: %ss)\n" "$HTTP_CODE" "$TIME_TOTAL"
    else
      error_msg="❌ $display_name не в порядке"
      printf "%s (Время: %ss)\n" "$error_msg" "$TIME_TOTAL"
      send_telegram_notification "$error_msg" # <-- УВЕДОМЛЕНИЕ
    fi
  else
    error_msg="❌ $display_name упал: curl код $CURL_EXIT_CODE (таймаут/подключение)"
    printf "%s\n" "$error_msg"
    send_telegram_notification "$error_msg" # <-- УВЕДОМЛЕНИЕ
  fi
done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.json" -print0)

echo "------------------------------------"
echo "Тестирование завершено."