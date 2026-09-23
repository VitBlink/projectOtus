#!/bin/bash
# cleanup_monitoring_elk.sh
# Полная очистка машины A от всех компонентов мониторинга и ELK
# Запуск: sudo bash cleanup_monitoring_elk.sh

set -e

if [ "$EUID" -ne 0 ]; then
   echo "Запустите от root: sudo bash $0"
   exit 1
fi

echo "============================================================"
echo "  Очистка системы от мониторинга и ELK"
echo "============================================================"
echo ""
read -rp "Продолжить? Всё будет удалено (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
   echo "Отменено."
   exit 0
fi

# ============================================================
# 1. ОСТАНОВКА ВСЕХ СЕРВИСОВ
# ============================================================
echo ""
echo "=== 1. Остановка сервисов ==="

for svc in prometheus grafana-server elasticsearch logstash kibana filebeat nginx-exporter; do
   systemctl stop "$svc" 2>/dev/null || true
   systemctl disable "$svc" 2>/dev/null || true
   echo "  остановлен: $svc"
done

# ============================================================
# 2. УДАЛЕНИЕ ПАКЕТОВ
# ============================================================
echo ""
echo "=== 2. Удаление пакетов ==="

for pkg in elasticsearch kibana logstash filebeat grafana prometheus nginx-prometheus-exporter; do
   if dpkg -l 2>/dev/null | grep -q "^ii  $pkg"; then
       echo ">>> purge $pkg"
       dpkg --purge --force-all "$pkg" 2>/dev/null || apt-get purge -y "$pkg" 2>/dev/null || true
   fi
done

# Автозависимости
echo ""
echo ">>> Удаление осиротевших зависимостей"
apt-get autoremove -y 2>/dev/null || true

# ============================================================
# 3. УДАЛЕНИЕ ДИРЕКТОРИЙ ДАННЫХ
# ============================================================
echo ""
echo "=== 3. Удаление директорий ==="

DIRS=(
   /etc/elasticsearch
   /var/lib/elasticsearch
   /var/log/elasticsearch
   /usr/share/elasticsearch

   /etc/kibana
   /var/lib/kibana
   /var/log/kibana
   /usr/share/kibana

   /etc/logstash
   /var/lib/logstash
   /var/log/logstash
   /usr/share/logstash

   /etc/filebeat
   /var/lib/filebeat
   /var/log/filebeat
   /usr/share/filebeat

   /etc/grafana
   /var/lib/grafana
   /var/log/grafana
   /usr/share/grafana

   /etc/prometheus
   /var/lib/prometheus
   /var/log/prometheus
   /usr/local/bin/prometheus
   /usr/local/bin/promtool

   /usr/local/bin/nginx-prometheus-exporter
)

for d in "${DIRS[@]}"; do
   if [ -e "$d" ]; then
       rm -rf "$d"
       echo "  удалено: $d"
   fi
done

# ============================================================
# 4. УДАЛЕНИЕ SYSTEMD-ЮНИТОВ
# ============================================================
echo ""
echo "=== 4. Удаление systemd-юнитов ==="

UNITS=(
   /etc|/systemd/system/prometheus.service
**Ди    /etc/systemd/system/nginx-exporter.service
   /etc/systemd/system/elasticsearch.service
)

for u in "${UNITS[@]}"; do
   if [ -f "$u" ]; then
       rm -f "$u"
       echo "  удалён: $u"
   fi
done

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ============================================================
# 5. УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЕЙ
# ============================================================
echo ""
echo "=== 5. Удаление пользователей ==="

for u in elasticsearch logstash kibana prometheus; do
   if id "$u" &>/dev/null; then
       userdel "$u" 2>/dev/null || true
       echo "  удалён пользователь: $u"
   fi
done

# ============================================================
# 6. ЧИСТКА APT
# ============================================================
echo ""
echo "=== 6. Чистка apt ==="
apt-get clean
apt-get autoclean -y 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# ============================================================
# 7. ПРОВЕРКА
# ============================================================
echo ""
echo "=== 7. Проверка ==="

echo ""
echo "Остались ли пакеты:"
dpkg -l 2>/dev/null | grep -E "elasticsearch|kibana|logstash|filebeat|grafana|prometheus" | grep "^ii" || echo "  ничего не осталось"

echo ""
echo "Остались ли директории:"
for d in /etc/elasticsearch /var/lib/elasticsearch /etc/kibana /etc/logstash /etc/filebeat /etc/grafana /etc/prometheus; do
   [ -e "$d" ] && echo "  ещё есть: $d"
done

echo ""
echo "Остались ли сервисы:"
systemctl list-unit-files 2>/dev/null | grep -E "elasticsearch|kibana|logstash|filebeat|grafana|prometheus|nginx-exporter" || echo "  ничего не осталось"

# ============================================================
# ИТОГ
# ============================================================
echo ""
echo "============================================================"
echo "✅ Очистка завершена"
echo "============================================================"
echo ""
echo "Теперь можно заново запустить:"
echo "  sudo bash setup_A_monitoring_elk.sh"
echo ""
