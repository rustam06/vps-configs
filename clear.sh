#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
  echo "❌ Требуются права root (sudo)." >&2
  exit 1
fi

LOG="/var/log/vps-maintenance.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND"' ERR

echo "=== $(date "+%F %T") Начало обслуживания ==="

APT_OPTS=(
  -y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o DPkg::Lock::Timeout=300
)

echo "📦 Обновление списка пакетов..."
apt-get update -o DPkg::Lock::Timeout=300

echo "⬆️ Обновление пакетов..."
apt-get full-upgrade "${APT_OPTS[@]}"

echo "🧹 Удаление ненужных пакетов..."
apt-get autoremove --purge "${APT_OPTS[@]}"

echo "🗑 Очистка кэша..."
apt-get clean

if command -v journalctl >/dev/null 2>&1; then
  echo "📜 Очистка журналов..."
  journalctl --vacuum-time=7d --vacuum-size=200M || true
fi

echo "📄 Удаление старых ротированных логов..."
find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) \
  -mtime +14 -delete 2>/dev/null || true

echo "💾 Свободное место:"
df -h /
echo "📁 Раздел /boot:"
df -h /boot 2>/dev/null || true

if [ -f /var/run/reboot-required ]; then
  echo "⚠️  ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА:"
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
else
  echo "✅ Перезагрузка не требуется."
fi

if command -v needrestart >/dev/null 2>&1; then
  echo "🔄 Сервисы, использующие устаревшие библиотеки:"
  needrestart -b -r l || true
fi

echo "=== $(date "+%F %T") Обслуживание завершено ==="
