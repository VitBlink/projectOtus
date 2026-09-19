#!/bin/bash
# start.sh — базовая настройка для Ubuntu 26.04
# Запуск: sudo bash start.sh [РОЛЬ]
# РОЛЬ: A, B или C

set -e

ROLE="${1:-BASE}"

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0 [A|B|C]"
   exit 1
fi

echo "============================================================"
echo "Базовая настройка (роль: $ROLE)"
echo "============================================================"

# ============================================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ (ВСЕ МАШИНЫ)
# ============================================================
echo ""
echo "=== 1. Обновление системы ==="
apt update && apt upgrade -y

# ============================================================
# 2. БАЗОВЫЕ УТИЛИТЫ (ВСЕ МАШИНЫ)
# ============================================================
echo ""
echo "=== 2. Базовые утилиты ==="
apt install -y curl wget ufw openssh-server

# ============================================================
# 3. SSH-СЕРВЕР (ВСЕ МАШИНЫ)
# ============================================================
echo ""
echo "=== 3. SSH-сервер ==="
systemctl enable --now ssh
echo "✅ SSH запущен"

# ============================================================
# 4. FIREWALL (ВСЕ МАШИНЫ)
# ============================================================
echo ""
echo "=== 4. Firewall ==="

# Сначала разрешаем SSH — иначе можно потерять доступ к машине
ufw allow OpenSSH

case "$ROLE" in
   A)
       echo "Роль A: Nginx + мониторинг + ELK"
       ufw allow 80/tcp      # Nginx
       ufw allow 3000/tcp    # Grafana
       ufw allow 5601/tcp    # Kibana
       ;;
   B)
       echo "Роль B: Apache + Rust + MySQL Master"
       echo "⚠️  Порты 8080/8081/8082/3306 будут открыты в setup_B.sh"
       ;;
   C)
       echo "Роль D: MySQL Slave"
       # Только SSH. MySQL-порт 3306 не открываем — репликация исходящая
       ;;
   *)
       echo "Роль BASE: только базовые настройки"
       ;;
esac

ufw --force enable
echo "✅ Firewall настроен"
ufw status verbose | head -10

# ============================================================
# ИТОГ
# ============================================================
echo ""
echo "============================================================"
echo "✅ Базовая настройка завершена (роль: $ROLE)"
echo "============================================================"
echo ""
echo "Проверка:"
echo "  systemctl status ssh"
echo "  ufw status verbose"
echo "  ss -tlnp | grep :22"
echo ""
echo "Дальше:"
echo "  1. Скопируйте свой публичный SSH-ключ на этот хост (ssh-copy-id)"
echo "  2. Запустите: sudo bash setup_ssh.sh"
echo ""

case "$ROLE" in
   A)
       echo "Дальше на машине A:"
       echo "  1. Положить setup_A.sh и setup_A_monitoring_elk.sh"
       echo "  2. Положить .deb-файлы в /tmp/deb/"
       echo "  3. Запустить: sudo bash setup_A.sh IP_B"
       echo "  4. Запустить: sudo bash setup_A_monitoring_elk.sh"
       ;;
   B)
       echo "Дальше на машине B:"
       echo "  1. Положить в /tmp/: setup_B.sh, rest_project, index_v1.html, index_v2.html"
       echo "  2. Запустить: sudo bash setup_B.sh IP_A IP_"
       ;;
   C)
       echo "Дальше на машине C:"
       echo "  1. Положить setup_C.sh"
       echo "  2. Дождаться вывода setup_B.sh (File и Position)"
       echo "  3. Запустить: sudo bash setup_C.sh IP_B LOG_FILE LOG_POS"
       ;;
esac
