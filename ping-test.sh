#!/bin/bash

# Массив с доменами для пинга
DOMAINS=(
    "gemini.google.com"
    "youtube.com"
    "chatgpt.com"
    "github.com"
    "perplexity.ai"
    "apple.com"
    "disneyplus.com"
    "kinopoisk.ru"
    "ya.ru"
    "vk.ru"
    "browserleaks.com"
    "linkedin.com"
)

TOTAL_PING_SUM=0
PING_COUNT=0

echo "Начинаем пинг-тест для определения средней задержки..."
echo "------------------------------------------------------"

# Цикл по каждому домену
for DOMAIN in "${DOMAINS[@]}"; do
    echo "Пингуем $DOMAIN..."
    # Выполняем ping и извлекаем среднее значение RTT
    # -q: тихий режим (подавляет вывод для каждого пакета)
    # -c 3: 3 пакета
    # grep 'avg' | awk '{print $4}' | cut -d '/' -f 2:
    #   - grep 'avg': ищем строку со статистикой
    #   - awk '{print $4}': выбираем 4-е поле (которое содержит min/avg/max/mdev)
    #   - cut -d '/' -f 2: разделяем по '/' и берем второе поле (avg)
    PING_RESULT=$(ping -c 3 -q "$DOMAIN" | grep 'avg' | awk '{print $4}' | cut -d '/' -f 2)

    # Проверяем, удалось ли получить числовое значение
    if [[ -n "$PING_RESULT" && "$PING_RESULT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "  Средний пинг для $DOMAIN: ${PING_RESULT} мс"
        TOTAL_PING_SUM=$(echo "$TOTAL_PING_SUM + $PING_RESULT" | bc -l)
        PING_COUNT=$((PING_COUNT + 1))
    else
        echo "  Не удалось получить средний пинг для $DOMAIN. Возможно, сервис недоступен или формат вывода изменился."
    fi
    echo "" # Пустая строка для читаемости
done

echo "------------------------------------------------------"

# Вычисление общего среднего пинга
if [ "$PING_COUNT" -gt 0 ]; then
    AVERAGE_PING=$(echo "scale=2; $TOTAL_PING_SUM / $PING_COUNT" | bc -l)
    echo "Общее среднее значение пинга по всем ${PING_COUNT} сервисам: ${AVERAGE_PING} мс"
else
    echo "Не удалось получить данные пинга ни для одного сервиса."
fi

echo "Тест завершен."
