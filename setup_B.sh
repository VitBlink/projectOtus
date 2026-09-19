#!/bin/bash
# setup_B.sh — машина B (Apache + Rust + MySQL Master + репликация)
# Запуск: sudo bash setup_B.sh IP_МАШИНЫ_A IP_МАШИНЫ_C
# Ожидает в /tmp/: rest_project, index_v1.html, index_v2.html

set -e

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0 IP_A IP_D"
   exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]; then
   echo "Использование: sudo bash setup_B.sh IP_МАШИНЫ_A IP_МАШИНЫ_D"
   exit 1
fi

IP_A="$1"
IP_C="$2"

echo "=== Проверка файлов в /tmp ==="
for f in /tmp/rest_project /tmp/index_v1.html /tmp/index_v2.html; do
   if [ ! -f "$f" ]; then
       echo "❌ Не найден: $f"
       exit 1
   fi
done
echo "✅ Все файлы на месте"

echo ""
echo "=== Установка пакетов ==="
apt update
apt install -y mysql-server apache2 ufw libssl3

echo ""
echo "=== Firewall ==="
ufw allow OpenSSH
ufw allow from ${IP_A} to any port 8080
ufw allow from ${IP_A} to any port 8081
ufw allow from ${IP_A} to any port 8082
ufw allow from ${IP_C} to any port 3306
ufw --force enable

echo ""
echo "=== MySQL Master ==="
CONF=/etc/mysql/mysql.conf.d/mysqld.cnf

grep -q "^server-id" "$CONF" && sed -i 's/^server-id.*/server-id = 1/' "$CONF" || sed -i '/^\[mysqld\]/a server-id = 1' "$CONF"
grep -q "^log_bin" "$CONF" && sed -i 's|^log_bin.*|log_bin = /var/log/mysql/mysql-bin.log|' "$CONF" || sed -i '/^\[mysqld\]/a log_bin = /var/log/mysql/mysql-bin.log' "$CONF"
grep -q "^binlog_format" "$CONF" || sed -i '/^\[mysqld\]/a binlog_format = ROW' "$CONF"
grep -q "^bind-address" "$CONF" && sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$CONF" || sed -i '/^\[mysqld\]/a bind-address = 0.0.0.0' "$CONF"

systemctl restart mysql
sleep 2

mysql <<SQL
CREATE DATABASE IF NOT EXISTS vip_db;
CREATE USER IF NOT EXISTS 'r_us'@'localhost' IDENTIFIED BY 'rustpass';
GRANT ALL PRIVILEGES ON vip_db.* TO 'r_us'@'localhost';
CREATE USER IF NOT EXISTS 'replica'@'${IP_C}' IDENTIFIED BY 'replica_pass';
GRANT REPLICATION SLAVE ON *.* TO 'replica'@'${IP_C}';
FLUSH PRIVILEGES;
USE vip_vb;
CREATE TABLE IF NOT EXISTS submissions (
   id INT AUTO_INCREMENT PRIMARY KEY,
   name VARCHAR(255),
   age INT,
   message TEXT,
   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL
echo "✅ БД готова"

echo ""
echo "=== Rust ==="
mkdir -p /opt/rest
cp /tmp/rest_project /opt/rest/server_app
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
sleep 1

echo ""
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

echo ""
echo "============================================================"
echo "✅ Машина B готова"
echo "============================================================"
echo ""
echo "⚠️  ДЛЯ SLAVE (машины D) ЗАПИШИТЕ:"
mysql -e "SHOW MASTER STATUS\G"
