#!/bin/bash
# setup_B.sh
# Запуск: sudo bash setup_B.sh IP_A IP_D
# Ожидает в /tmp/: server_app, index1.html, index2.html

set -e

if [ "$EUID" -ne 0 ]; then
   echo "Запустите от root: sudo bash $0 IP_A IP_C"
   exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]; then
   echo "Использование: sudo bash setup_B.sh IP_A IP_C"
   exit 1
fi

IP_A="$1"
IP_C="$2"

echo "=== Копируем файлы ==="
sudo cp /home/rust/Загрузки/server_app /tmp/server_app
sudo cp /home/rust/Загрузки/index1.html /tmp/index1.html
sudo cp /home/rust/Загрузки/index2.html /tmp/index2.html

for f in /tmp/server_app /tmp/index1.html /tmp/index2.html; do
   if [ ! -f "$f" ]; then
       echo "Не найден: $f"
       exit 1
   fi
done

echo "=== Установка пакетов ==="
apt update
apt install -y mysql-server mysql-client apache2 ufw libssl3

echo "=== Firewall ==="
ufw allow OpenSSH
ufw allow from ${IP_A} to any port 8080
ufw allow from ${IP_A} to any port 8081
ufw allow from ${IP_A} to any port 8082
ufw allow from ${IP_C} to any port 3306 proto tcp
ufw --force enable

echo "=== MySQL 8.4 мастер ==="

CONF=/etc/mysql/mysql.conf.d/mysqld.cnf
if [ -f "$CONF" ]; then
   if grep -q "^bind-address" "$CONF"; then
       sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$CONF"
   elif grep -q "^#bind-address" "$CONF"; then
       sed -i 's/^#bind-address.*/bind-address = 0.0.0.0/' "$CONF"
   else
       sed -i '/^\[mysqld\]/a bind-address = 0.0.0.0' "$CONF"
   fi
fi

cat > /etc/mysql/mysql.conf.d/60-master.cnf <<EOF
[mysqld]
server-id              = 1
log_bin                = /var/log/mysql/mysql-bin.log
binlog_format          = ROW
bind-address           = 0.0.0.0
log_replica_updates    = ON
EOF

systemctl enable mysql
systemctl restart mysql
sleep 5

if ! ss -tlnp | grep -q "0.0.0.0:3306"; then
   echo "MySQL не слушает на 0.0.0.0"
   ss -tlnp | grep 3306
fi

echo "=== Создание пользователя репликации ==="
mysql <<SQL
CREATE USER IF NOT EXISTS 'repl'@'%'
   IDENTIFIED WITH caching_sha2_password BY 'replica_pass';
ALTER USER 'repl'@'%'
   IDENTIFIED WITH caching_sha2_password BY 'replica_pass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
SQL

echo "=== Запись позиции лога ДО создания базы ==="
mysql -e "SHOW BINARY LOG STATUS\G" | tee /tmp/master_pos.txt

echo "=== Создание базы и таблицы ==="
mysql <<SQL
CREATE DATABASE IF NOT EXISTS testdb;

CREATE USER IF NOT EXISTS 'rustuser'@'localhost'
   IDENTIFIED WITH caching_sha2_password BY 'rustpass';
ALTER USER 'rustuser'@'localhost'
   IDENTIFIED WITH caching_sha2_password BY 'rustpass';
GRANT ALL PRIVILEGES ON testdb.* TO 'rustuser'@'localhost';
FLUSH PRIVILEGES;

USE testdb;
CREATE TABLE IF NOT EXISTS sub (
   id INT AUTO_INCREMENT PRIMARY KEY,
   name VARCHAR(255),
   age INT,
   message TEXT,
   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL

echo "=== Rust ==="
mkdir -p /opt/rest
cp /tmp/server_app /opt/rest/server_app
chmod +x /opt/rest/server_app

cat > /etc/systemd/system/server_app.service <<'EOF'
[Unit]
Description=Rust REST Project
After=network.target mysql.service
Requires=mysql.service

[Service]
Type=simple
WorkingDirectory=/opt/rest
ExecStart=/opt/rest/server_app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now server_app
sleep 2

echo "=== Apache ==="
grep -q "Listen 8081" /etc/apache2/ports.conf || echo "Listen 8081" >> /etc/apache2/ports.conf
grep -q "Listen 8082" /etc/apache2/ports.conf || echo "Listen 8082" >> /etc/apache2/ports.conf

mkdir -p /var/www/site_v1 /var/www/site_v2
cp /tmp/index1.html /var/www/site_v1/index.html
cp /tmp/index2.html /var/www/site_v2/index.html

cat > /etc/apache2/sites-available/site_v1.conf <<'EOF'
<VirtualHost *:8081>
   DocumentRoot /var/www/site_v1
   <Directory /var/www/site_v1>
       Require all granted
   </Directory>
</VirtualHost>
EOF

cat > /etc/apache2/sites-available/site_v2.conf <<'EOF'
<VirtualHost *:8082>
   DocumentRoot /var/www/site_v2
   <Directory /var/www/site_v2>
       Require all granted
   </Directory>
</VirtualHost>
EOF

a2ensite site_v1 site_v2 >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
systemctl restart apache2

echo "_____Запускаем DUMP__________"
sudo bash -c '(crontab -l 2>/dev/null; echo "* * * * * root /bin/bash /home/rust/Загрузки/dump_tab.sh") | crontab -'

echo ""
echo "============================================================"
echo "Машина B готова"
echo "============================================================"
echo ""
echo "File и Position для машины C:"
cat /tmp/master_pos.txt
echo ""
echo "Пользователь репликации: repl"
echo "Пароль:                  replica_pass"
echo "============================================================"

systemctl status server_app.service
systemctl status mysql
systemctl status apache2

