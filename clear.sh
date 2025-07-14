#!/bin/bash

echo "🧹 Очистка системы в процессе..."

# Обновление списка пакетов
sudo apt update
sudo apt upgrade -y

echo -e "y\n\n0" | sudo x-ui update

# Удаление ненужных пакетов и их зависимостей
sudo apt autoremove -y
sudo apt clean -y

# Очистка логов
sudo journalctl --vacuum-time=7d

echo "✅ Очистка завершена!"

