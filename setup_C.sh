#!/bin/bash
# setup_D_replica.sh
# Запуск: sudo bash setup_C.sh IP_B LOG_FILE LOG_POS

set -e

if [ "$EUID" -ne 0 ]; then
   echo "Запустите от root: sudo bash $0 IP_B LOG_FILE LOG_POS"
   exit 1
fi

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
   echo "Использование: sudo bash setup_D_replica.sh IP_B LOG_FILE LOG_POS"
   exit 1
fi

MASTER_IP="$1"
LOG_FILE="$2"
LOG_POS="$3"

echo "Мастер: ${MASTER_IP}"
echo "Log File: ${LOG_FILE}"
echo "Log Pos:  ${LOG_POS}"

rm -f /etc/apt/sources.list.d/cdrom.sources 2>/dev/null || true
sed -i '/^deb cdrom:/s/^/#/' /etc/apt/sources.list 2>/dev/null || true

apt update
apt install -y mysql-server mysql-client ufw

cat > /etc/mysql/mysql.conf.d/60-replica.cnf <<EOF
[mysqld]
server-id              = 2
relay-log              = /var/log/mysql/mysql-relay-bin.log
read_only              = 1
log_replica_updates    = ON
EOF

systemctl enable mysql
systemctl restart mysql
sleep 5

ufw allow 22/tcp
ufw --force enable

echo "=== Подключение к мастеру ==="
mysql <<SQL
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
   SOURCE_HOST='${MASTER_IP}',
   SOURCE_USER='repl',
   SOURCE_PASSWORD='replica_pass',
   SOURCE_LOG_FILE='${LOG_FILE}',
   SOURCE_LOG_POS=${LOG_POS},
   GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

sleep 8

echo ""
echo "=== Статус репликации ==="
mysql -e "SHOW REPLICA STATUS\G" | grep -E \
   "Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:" || true

echo ""
echo "=== Проверка базы ==="
for i in $(seq 1 30); do
	if mysql -e "SHOW DATABASES;" | grep -q testdb; then
		echo "testdb OK ( $((i*2)) sec)" break
	fi
	sleep 2
done
if mysql -e "SHOW DATABASES;" | grep -q testdb; then
	echo " Ok databases in replica;"
	echo "Машина C готова"
else
	echo "ERROR time out"
	mysql -e "SHOW REPLICA STATUS\G" | grep -E "Running|Error"
fi
