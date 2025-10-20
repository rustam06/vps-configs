#!/usr/bin/env bash
set -Eeuo pipefail

# --- НАСТРОЙКИ СКРИПТА ---
V2RAY_BIN="${V2RAY_BIN:-xray}"
CONFIG_DIR="${CONFIG_DIR:-.}"
TEST_URL="${TEST_URL:-https://www.gstatic.com/generate_204}"
LOCAL_PORT="${LOCAL_PORT:-10808}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"

# --- НАСТРОЙКИ ДЛЯ TELEGRAM ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# --- НОВЫЕ ПЕРЕМЕННЫЕ ---
# Файл для хранения последнего известного состояния конфигураций
STATE_FILE="${CONFIG_DIR}/.vless_test_status"

send_telegram_notification() {
  local message="$1"
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: Токен или ID чата Telegram не заданы. Уведомление не отправлено."
    return
  fi
  local encoded_message
  encoded_message=$(printf %s "$message" | jq -sRr @uri)
  
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${encoded_message}" \
    --max-time 10 > /dev/null
}

for dep in "$V2RAY_BIN" jq curl; do
  command -v "$dep" >/dev/null 2>&1 || {
    error_msg="Ошибка: зависимость '$dep' не найдена."
    echo "$error_msg"
    send_telegram_notification "$error_msg"
    exit 1
  }
done

config_files_found=$(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.json" | wc -l)
if [[ "$config_files_found" -eq 0 ]]; then
  error_msg="Ошибка: В директории '$CONFIG_DIR' не найдено конфигурационных файлов .json."
  echo "$error_msg"
  send_telegram_notification "$error_msg"
  exit 1
fi

# --- НОВЫЙ БЛОК: ЗАГРУЗКА ПРЕДЫДУЩИХ СОСТОЯНИЙ ---
# Используем ассоциативный массив для хранения статусов (ключ - имя, значение - статус)
declare -A previous_states
if [[ -f "$STATE_FILE" ]]; then
  while IFS= read -r line; do
    # Читаем строку формата "СТАТУС Имя конфигурации"
    status="${line%% *}"
    name="${line#* }"
    previous_states["$name"]="$status"
  done < "$STATE_FILE"
fi
# Массив для хранения текущих состояний, которые запишем в конце
declare -A current_states
# --- КОНЕЦ НОВОГО БЛОКА ---

echo "Запуск теста VLESS конфигураций..."

TEMP_CLIENT_CONFIG="$(mktemp -t xraytest.XXXXXX.json)"

cleanup() {
  # --- НОВЫЙ БЛОК: СОХРАНЕНИЕ ТЕКУЩИХ СОСТОЯНИЙ ПЕРЕД ВЫХОДОМ ---
  # Записываем новые статусы в файл для следующего запуска
  # Это гарантирует, что состояния сохранятся даже при прерывании скрипта
  temp_state_file=$(mktemp)
  for name in "${!current_states[@]}"; do
    echo "${current_states[$name]} $name" >> "$temp_state_file"
  done
  # Атомарно заменяем старый файл новым, чтобы избежать повреждений
  mv "$temp_state_file" "$STATE_FILE"
  # --- КОНЕЦ НОВОГО БЛОКА ---

  if [[ -n "${V2RAY_PID:-}" ]] && kill -0 "$V2RAY_PID" 2>/dev/null; then
    kill "$V2RAY_PID" >/dev/null 2>&1 || true
    wait "$V2RAY_PID" 2>/dev/null || true
  fi
  rm -f "$TEMP_CLIENT_CONFIG"
}
trap cleanup EXIT INT TERM

if "$V2RAY_BIN" -h 2>&1 | grep -q "run -c"; then
  RUN_CMD=("$V2RAY_BIN" run -c)
else
  RUN_CMD=("$V2RAY_BIN" -c)
fi

while IFS= read -r -d '' config_file; do
  echo "------------------------------------"
  tag="$(jq -r '.tag // empty' "$config_file" 2>/dev/null || true)"
  display_name="${tag:-$config_file}"
  printf "Тестируем: %s (файл: %s)\n" "$display_name" "$config_file"

  if ! jq -e 'select(.protocol=="vless")' "$config_file" >/dev/null 2>&1; then
    echo "Пропуск: не VLESS outbound"
    continue
  fi

  jq -e -n --argjson port "$LOCAL_PORT" --slurpfile outbound "$config_file" '{log:{loglevel:"warning"},inbounds:[{port:$port,listen:"127.0.0.1",protocol:"socks",settings:{auth:"noauth",udp:true}}],outbounds:$outbound}' > "$TEMP_CLIENT_CONFIG"

  "${RUN_CMD[@]}" "$TEMP_CLIENT_CONFIG" >/dev/null 2>&1 &
  V2RAY_PID=$!
  sleep 0.8

  CURL_RESULT="$(curl -sS -o /dev/null -w "%{http_code}:%{time_total}" --socks5-hostname "127.0.0.1:$LOCAL_PORT" --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" "$TEST_URL" || true)"
  CURL_EXIT_CODE=$?

  kill "$V2RAY_PID" >/dev/null 2>&1 || true
  wait "$V2RAY_PID" 2>/dev/null || true
  V2RAY_PID=""

  # --- ОБНОВЛЕННАЯ ЛОГИКА ПРОВЕРКИ И УВЕДОМЛЕНИЙ ---
  current_status="DOWN" # По умолчанию считаем, что тест провален
  time_total=""

  if [[ $CURL_EXIT_CODE -eq 0 ]]; then
    IFS=: read -r http_code time_total <<<"$CURL_RESULT"
    if [[ "$http_code" == "204" ]]; then
      current_status="UP" # Если все хорошо, меняем статус на UP
      printf "✅ УСПЕХ   (Код: %s, Время: %ss)\n" "$http_code" "$time_total"
    fi
  fi
  
  # Получаем предыдущий статус. Если его не было, считаем, что был UP, чтобы не слать ложных уведомлений
  previous_status="${previous_states[$display_name]:-UP}"
  
  # Сравниваем статусы и отправляем уведомления только при изменении
  if [[ "$current_status" == "UP" && "$previous_status" == "DOWN" ]]; then
    # Восстановление!
    restore_msg="✅ УРА: $display_name снова в строю."
    printf "%s\n" "$restore_msg"
    send_telegram_notification "$restore_msg"
  elif [[ "$current_status" == "DOWN" && "$previous_status" == "UP" ]]; then
    # Первая ошибка!
    if [[ $CURL_EXIT_CODE -ne 0 ]]; then
      error_msg="❌ $display_name: curl код $CURL_EXIT_CODE (таймаут/подключение)"
      printf "%s\n" "$error_msg"
      send_telegram_notification "$error_msg"
    else
      error_msg="❌ $display_name упал"
      printf "%s (Время: %ss)\n" "$error_msg" "$time_total"
      send_telegram_notification "$error_msg"
    fi
  elif [[ "$current_status" == "DOWN" ]]; then
      # Ошибка все еще актуальна, просто выводим в консоль
      error_msg="❌ $display_name все еще не работает"
      printf "$error_msg"
      send_telegram_notification "$error_msg"
  fi

  # Сохраняем текущий статус для записи в файл в конце
  current_states["$display_name"]="$current_status"
  # --- КОНЕЦ ОБНОВЛЕННОЙ ЛОГИКИ ---

done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.json" -print0)

echo "------------------------------------"
echo "Тестирование завершено."