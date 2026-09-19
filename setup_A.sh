#!/bin/bash
# setup_A.sh — Nginx (машина A)
# Запуск: sudo bash setup_A.sh IP_МАШИНЫ_B

set -e

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0 IP_МАШИНЫ_B"
   exit 1
fi

if [ -z "$1" ]; then
   echo "Использование: sudo bash setup_A.sh IP_МАШИНЫ_B"
   exit 1
fi

IP_B="$1"

apt update
apt install -y nginx ufw wget

ufw allow OpenSSH
ufw allow 80/tcp
ufw --force enable

cat > /etc/nginx/sites-available/default <<EOF
upstream apache {
   ip_hash;
   server ${IP_B}:8081;
   server ${IP_B}:8082;
}

server {
   listen 80;
   server_name _;

   location /api/ {
       proxy_pass http://${IP_B}:8080;
       proxy_set_header Host \$host;
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
   }

   location / {
       proxy_pass http://apache;
       proxy_set_header Host \$host;
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
   }
}
EOF

nginx -t
systemctl restart nginx
systemctl enable nginx

echo "✅ Машина A готова (Nginx)"
