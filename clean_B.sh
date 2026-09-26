#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
   echo "Запустите от root: sudo bash $0"
   exit 1
fi

read -rp "Очистить машину B? (y/N): " C
[[ "$C" =~ ^[Yy]$ ]] || exit 0

systemctl stop rest_project apache2 mysql 2>/dev/null || true
systemctl disable rest_project apache2 mysql 2>/dev/null || true

rm -f /etc/systemd/system/rest_project.service /lib/systemd/system/rest_project.service
rm -rf /opt/rest

DEBIAN_FRONTEND=noninteractive apt-get purge -y \
   apache2 apache2-bin apache2-data apache2-utils \
   mysql-server mysql-server-8.0 mysql-server-core-8.0 \
   mysql-client mysql-client-8.0 mysql-client-core-8.0 mysql-common \
   2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true

rm -rf /etc/apache2 /var/www/site_v1 /var/www/site_v2 /var/log/apache2 /var/lib/apache2
rm -rf /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring
rm -rf /etc/mysql /var/log/mysql /usr/share/mysql /usr/share/mysql-8.0

userdel mysql 2>/dev/null || true
groupdel mysql 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

ufw --force reset
ufw allow OpenSSH
ufw --force enable

apt-get autoremove -y 2>/dev/null || true
apt-get clean

echo ""
echo "=== Проверка ==="
dpkg -l 2>/dev/null | grep -E "apache2|mysql-server|mysql-client" | grep "^ii" || echo "пакетов нет"
ss -tlnp 2>/dev/null | grep -E ":8080|:8081|:8082|:3306|:80" || echo "порты свободны"
echo "Готово."
