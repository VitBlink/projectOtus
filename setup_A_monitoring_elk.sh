#!/bin/bash
# setup_A_monitoring_elk.sh
# Запуск: sudo bash setup_A_monitoring_elk.sh
# .deb-файлы (или .tar.gz с ними) должны быть в /tmp/deb/

set -e

if [ "$EUID" -ne 0 ]; then
   echo "Запустите от root: sudo bash $0"
   exit 1
fi

DEB_DIR="/tmp/deb"

if [ ! -d "$DEB_DIR" ]; then
   echo "Папка $DEB_DIR не найдена"
   exit 1
fi

# ============================================================
# РАСПАКОВКА АРХИВОВ
# ============================================================
echo "=== Распаковка архивов в $DEB_DIR ==="

# Ищем все .tar.gz, .tgz, .tar в /tmp/deb и распаковываем
shopt -s nullglob
for archive in "$DEB_DIR"/*.tar.gz "$DEB_DIR"/*.tgz "$DEB_DIR"/*.tar; do
   if [ -f "$archive" ]; then
       echo ">>> Распаковка: $(basename "$archive")"
       tar -xzf "$archive" -C "$DEB_DIR" 2>/dev/null || tar -xf "$archive" -C "$DEB_DIR"
   fi
done
shopt -u nullglob

# Если внутри были вложенные папки — переносим .deb из них в корень /tmp/deb
echo "=== Поиск .deb файлов рекурсивно ==="
find "$DEB_DIR" -type f -name "*.deb" ! -path "$DEB_DIR/*.deb" -exec mv {} "$DEB_DIR/" \; 2>/dev/null || true

# Удаляем распакованные папки (если остались), чтобы не мешали
find "$DEB_DIR" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true

# Показываем, что нашли
echo ""
echo "=== Найдены .deb файлы ==="
ls -1 "$DEB_DIR"/*.deb 2>/dev/null || {
   echo "Не найдено ни одного .deb в $DEB_DIR"
   echo "Положите туда .deb-файлы или .tar.gz с ними."
   exit 1
}

# ============================================================
# УСТАНОВКА .DEB
# ============================================================
echo ""
echo "=== Установка .deb ==="
for deb in "$DEB_DIR"/*.deb; do
   if [ -f "$deb" ]; then
       echo ">>> $(basename "$deb")"
       apt install -y "$deb"
   fi
done

# ============================================================
# PROMETHEUS
# ============================================================
echo ""
echo "=== Prometheus ==="
systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus

if ! grep -q "job_name: 'nginx'" /etc/prometheus/prometheus.yml; then
   cat >> /etc/prometheus/prometheus.yml <<'EOF'

 - job_name: 'nginx'
   static_configs:
     - targets: ['localhost:9113']
EOF
   systemctl restart prometheus
fi

# ============================================================
# GRAFANA
# ============================================================
echo ""
echo "=== Grafana ==="
systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server

# ============================================================
# NGINX EXPORTER
# ============================================================
echo ""
echo "=== Nginx Exporter ==="

if ! grep -q "stub_status" /etc/nginx/sites-available/default; then
   sed -i '/^}/i\
   location /nginx_status {\
       stub_status on;\
       access_log off;\
       allow 127.0.0.1;\
       deny all;\
   }' /etc/nginx/sites-available/default
   nginx -t && systemctl reload nginx
fi

EXPORTER_BIN="/usr/local/bin/nginx-prometheus-exporter"
EXPORTER_VER="1.4.2"

if [ ! -f "$EXPORTER_BIN" ]; then
   ARCH=$(uname -m)
   case "$ARCH" in
       x86_64)  DEB_ARCH="amd64" ;;
       aarch64) DEB_ARCH="arm64" ;;
       armv7l)  DEB_ARCH="armv7" ;;
       *) echo "Архитектура $ARCH не поддерживается"; exit 1 ;;
   esac

   TARBALL="nginx-prometheus-exporter_${EXPORTER_VER}_linux_${DEB_ARCH}.tar.gz"
   URL="https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v${EXPORTER_VER}/${TARBALL}"
   TMP_DIR=$(mktemp -d)

   if command -v wget &>/dev/null; then
       wget -q -O "${TMP_DIR}/${TARBALL}" "$URL"
   else
       curl -fL -o "${TMP_DIR}/${TARBALL}" "$URL"
   fi

   tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
   BIN_FOUND=$(find "$TMP_DIR" -type f -name "nginx-prometheus-exporter" | head -n1)
   mv "$BIN_FOUND" "$EXPORTER_BIN"
   chmod +x "$EXPORTER_BIN"
   rm -rf "$TMP_DIR"
fi

cat > /etc/systemd/system/nginx-exporter.service <<'EOF'
[Unit]
Description=Nginx Prometheus Exporter
After=network.target nginx.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nginx-prometheus-exporter --nginx.scrape-uri=http://127.0.0.1/nginx_status
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nginx-exporter

# ============================================================
# ELASTICSEARCH
# ============================================================
echo ""
echo "=== Elasticsearch ==="
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: test-cluster
node.name: node-1
network.host: localhost
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
EOF

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch
sleep 5

# ============================================================
# LOGSTASH
# ============================================================
echo ""
echo "=== Logstash ==="
cat > /etc/logstash/conf.d/nginx.conf <<'EOF'
input {
 beats {
   port => 5044
 }
}

filter {
 grok {
   match => { "message" => "%{IPORHOST:client_ip} - - \[%{HTTPDATE:timestamp}\] \"%{WORD:method} %{URIPATHPARAM:request} HTTP/%{NUMBER:http_version}\" %{NUMBER:status:int} %{NUMBER:bytes:int}" }
 }
}

output {
 elasticsearch {
   hosts => ["localhost:9200"]
   index => "nginx-access-%{+YYYY.MM.dd}"
 }
}
EOF

systemctl daemon-reload
systemctl enable logstash
systemctl start logstash
sleep 3

# ============================================================
# KIBANA
# ============================================================
echo ""
echo "=== Kibana ==="
cat > /etc/kibana/kibana.yml <<'EOF'
server.host: "0.0.0.0"
server.port: 5601
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl daemon-reload
systemctl enable kibana
systemctl start kibana
sleep 3

# ============================================================
# FILEBEAT
# ============================================================
echo ""
echo "=== Filebeat ==="
cat > /etc/filebeat/filebeat.yml <<'EOF'
filebeat.inputs:
 - type: log
   enabled: true
   paths:
     - /var/log/nginx/access.log
     - /var/log/nginx/error.log

output.logstash:
 hosts: ["localhost:5044"]
EOF

systemctl daemon-reload
systemctl enable filebeat
systemctl start filebeat

# ============================================================
# FIREWALL
# ============================================================
echo ""
echo "=== Firewall ==="
ufw allow 3000/tcp
ufw allow 5601/tcp
ufw --force enable

# ============================================================
# ИТОГ
# ============================================================
echo ""
echo "=== Статусы ==="
for s in prometheus grafana-server elasticsearch logstash kibana filebeat nginx-exporter; do
   if systemctl is-active --quiet "$s" 2>/dev/null; then
       echo "OK  $s"
   else
       echo "FAIL $s"
   fi
done
