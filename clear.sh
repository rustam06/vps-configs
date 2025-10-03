#!/bin/bash
set -e

echo "🧹 Очистка системы в процессе..."

# Обновление списка пакетов без upgrade
sudo apt update

# Удаление ненужных пакетов с полной очисткой
sudo apt autoremove --purge -y
sudo apt autoclean -y

# Очистка логов (7 дней разумно)
sudo journalctl --vacuum-time=7d

echo "✅ Очистка завершена!"
