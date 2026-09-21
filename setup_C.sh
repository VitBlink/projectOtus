#!/bin/bash
# setup_C.sh — MySQL 8.4 реплика (машина C)
# Запуск: sudo bash setup_C.sh

set -e

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0"
   exit 1
fi

echo "===================================================="
echo "  Настройка реплики MySQL 8.4"
echo "  Нажмите Enter, чтобы оставить значение по умолчанию"
echo "===================================================="
echo ""

read -rp "IP мастера (машина B) [192.168.1.10]: "        MASTER_IP
MASTER_IP="${MASTER_IP:-192.168.1.10}"

read -rp "Пользователь репликации [repl]: "              REPL_USER
REPL_USER="${REPL_USER:-repl}"

read -rsp "Пароль пользователя репликации: "             REPL_PASS
echo ""
if [ -z "$REPL_PASS" ]; then
   echo "❌ Пароль не может быть пустым"
   exit 1
fi

read -rp "server-id реплики (уникальный, не 1) [3]: "    SERVER_ID
SERVER_ID="${SERVER_ID:-3}"

read -rp "Имя реплицируемой базы [app]: "                DB_NAME
DB_NAME="${DB_NAME:-app}"

read -rp "MASTER_LOG_FILE (binlog.000012): "             LOG_FILE
if [ -z "$LOG_FILE" ]; then
   echo "❌ LOG_FILE обязателен (см. SHOW BINARY LOG STATUS на мастере)"
   exit 1
fi

read -rp "MASTER_LOG_POS (1234567): "                    LOG_POS
if [ -z "$LOG_POS" ]; then
   echo "❌ LOG_POS обязателен"
   exit 1
fi

echo ""
echo "===================================================="
echo "  Параметры:"
echo "    Мастер      : ${MASTER_IP}"
echo "    Пользователь: ${REPL_USER}"
echo "    Server-ID   : ${SERVER_ID}"
echo "    База        : ${DB_NAME}"
echo "    Log File    : ${LOG_FILE}"
echo "    Log Pos     : ${LOG_POS}"
echo "===================================================="
echo ""

# --- убираем мёртвый cdrom-репозиторий ---
rm -f /etc/apt/sources.list.d/cdrom.sources 2>/dev/null || true
sed -i '/^deb cdrom:/s/^/#/' /etc/apt/sources.list 2>/dev/null || true

# --- установка MySQL 8.4 ---
apt update
apt install -y mysql-server mysql-client

# --- конфиг реплики ---
cat > /etc/mysql/mysql.conf.d/60-replica.cnf <<EOF
[mysqld]
server-id        = ${SERVER_ID}
log_bin          = binlog
relay_log        = relay-bin
read_only        = ON
super_read_only  = ON
EOF

systemctl enable mysql
systemctl restart mysql
sleep 5

# --- настройка репликации (синтаксис MySQL 8.4) ---
mysql <<SQL
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
   SOURCE_HOST='${MASTER_IP}',
   SOURCE_USER='${REPL_USER}',
   SOURCE_PASSWORD='${REPL_PASS}',
   SOURCE_LOG_FILE='${LOG_FILE}',
   SOURCE_LOG_POS=${LOG_POS};
START REPLICA;
SQL

sleep 3

# --- статус ---
echo ""
echo "=== Статус реплики ==="
mysql -e "SHOW REPLICA STATUS\G" | grep -E \
   "Replica_(IO|SQL)_Running|Seconds_Behind_Master|Last_(IO|SQL)_Error"
