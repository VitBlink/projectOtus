#!/bin/bash
# setup_C.sh — машина C (MySQL Slave + сторож репликации)
# Запуск: sudo bash setup_C.sh IP_МАШИНЫ_B LOG_FILE LOG_POS

set -e

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0 IP_B LOG_FILE LOG_POS"
   exit 1
fi

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
   echo "Использование: sudo bash setup_C.sh IP_МАШИНЫ_B LOG_FILE LOG_POS"
   exit 1
fi

IP_B="$1"
LOG_FILE="$2"
LOG_POS="$3"

echo "=== Установка MySQL ==="
apt update
apt install -y mysql-server ufw
systemctl enable --now mysql

ufw allow OpenSSH
ufw --force enable

echo ""
echo "=== Конфиг Slave ==="
CONF=/etc/mysql/mysql.conf.d/mysqld.cnf

grep -q "^server-id" "$CONF" && sed -i 's/^server-id.*/server-id = 2/' "$CONF" || sed -i '/^\[mysqld\]/a server-id = 2' "$CONF"
grep -q "^relay-log" "$CONF" || sed -i '/^\[mysqld\]/a relay-log = /var/log/mysql/mysql-relay-bin.log' "$CONF"
grep -q "^read_only" "$CONF" || sed -i '/^\[mysqld\]/a read_only = 1' "$CONF"

systemctl restart mysql
sleep 2

echo ""
echo "=== Подключение к Master ==="
mysql <<SQL
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
   MASTER_HOST='${IP_B}',
   MASTER_USER='replica',
   MASTER_PASSWORD='replica_pass',
   MASTER_LOG_FILE='${LOG_FILE}',
   MASTER_LOG_POS=${LOG_POS};
START SLAVE;
SQL

sleep 3

echo ""
echo "=== Статус репликации ==="
mysql -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master:|Last_IO_Error:|Last_SQL_Error:" || true

echo ""
echo "=== Сторож репликации (cron) ==="
cat > /usr/local/bin/check_replication.sh <<'EOF'
#!/bin/bash
LOG=/var/log/check_replication.log
STATUS=$(mysql -e "SHOW SLAVE STATUS\G" 2>/dev/null)
IO=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

if [ "$IO" != "Yes" ] || [ "$SQL" != "Yes" ]; then
   echo "$(date '+%Y-%m-%d %H:%M:%S'): репликация сломана (IO=$IO, SQL=$SQL) — перезапускаю" >> "$LOG"
   mysql -e "STOP SLAVE; START SLAVE;" 2>>"$LOG"
fi
EOF

chmod +x /usr/local/bin/check_replication.sh
(crontab -l 2>/dev/null | grep -v check_replication; echo "* * * * * /usr/local/bin/check_replication.sh") | crontab -

echo "✅ Сторож установлен"
echo ""
echo "✅ Машина C готова"
echo "Проверка: sudo mysql -e 'SHOW SLAVE STATUS\\G' | grep -E 'Running|Behind'"
