#!/bin/bash
# setup_A_monitoring_elk.sh
# Запуск: sudo bash setup_A_monitoring_elk.sh
# .deb (и/или .tar.gz с ними) для Grafana и ELK должны быть в /tmp/deb/
# Prometheus и Nginx Exporter скачиваются автоматически с GitHub

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
# СИСТЕМНЫЕ ЛИМИТЫ (для Elasticsearch)
# ============================================================
echo "=== Системные лимиты ==="

CURRENT_MAP=$(sysctl -n vm.max_map_count)
if [ "$CURRENT_MAP" -lt 262144 ]; then
   sysctl -w vm.max_map_count=262144
   grep -q "^vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
   echo "vm.max_map_count = 262144"
else
   echo "vm.max_map_count уже $CURRENT_MAP"
fi

if ! grep -q "^elasticsearch" /etc/security/limits.conf; then
   echo "elasticsearch  -  nofile  65535" >> /etc/security/limits.conf
   echo "elasticsearch  -  memlock unlimited" >> /etc/security/limits.conf
fi

# ============================================================
# JAVA (нужна для Logstash)
# ============================================================
echo ""
echo "=== Java ==="

if ! command -v java &>/dev/null; then
   echo "Java не найдена — устанавливаем default-jre-headless"
   apt update
   apt install -y default-jre-headless
fi

if command -v java &>/dev/null; then
   echo "Java: $(java -version 2>&1 | head -1)"
else
   echo "Java не установилась — Logstash может не запуститься"
fi

# ============================================================
# ПОДГОТОВКА ELASTICSEARCH (ДО УСТАНОВКИ)
# ============================================================
echo ""
echo "=== Подготовка Elasticsearch (до установки) ==="

#mkdir -p /var/lib/elasticsearch
#mkdir -p /var/log/elasticsearch
#mkdir -p /etc/elasticsearch
#mkdir -p /etc/elasticsearch/jvm.options.d

# Heap 1 ГБ
#cat > /etc/elasticsearch/jvm.options.d/jvm.options <<'EOF'
#-Xms1g
#-Xmx1g
#EOF
#echo "Heap: 1g"

#if id elasticsearch &>/dev/null; then
#   chown -R elasticsearch:elasticsearch /etc/elasticsearch
#   chown -R elasticsearch:elasticsearch /var/lib/elasticsearch
#   chown -R elasticsearch:elasticsearch /var/log/elasticsearch
#fi

# ============================================================
# РАСПАКОВКА АРХИВОВ
# ============================================================
echo ""
echo "=== Распаковка архивов в $DEB_DIR ==="

shopt -s nullglob
for archive in "$DEB_DIR"/*.tar.gz "$DEB_DIR"/*.tgz "$DEB_DIR"/*.tar; do
   if [ -f "$archive" ]; then
       echo ">>> Распаковка: $(basename "$archive")"
       tar -xzf "$archive" -C "$DEB_DIR" 2>/dev/null || tar -xf "$archive" -C "$DEB_DIR"
   fi
done
shopt -u nullglob

echo "=== Поиск .deb рекурсивно ==="
find "$DEB_DIR" -type f -name "*.deb" ! -path "$DEB_DIR/*.deb" -exec mv {} "$DEB_DIR/" \; 2>/dev/null || true
find "$DEB_DIR" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true

echo ""
echo "=== Найдены .deb ==="
ls -1 "$DEB_DIR"/*.deb 2>/dev/null || {
   echo "Не найдено .deb в $DEB_DIR"
   exit 1
}

# ============================================================
# УСТАНОВКА .DEB через dpkg -i
# ============================================================
echo ""
echo "=== Установка .deb через dpkg -i ==="

for deb in "$DEB_DIR"/*.deb; do
   if [ -f "$deb" ]; then
       echo ">>> dpkg -i $(basename "$deb")"
       dpkg -i "$deb" || true
   fi
done

echo ""
#echo "=== Доустановка зависимостей ==="
#apt-get install -yf || true

cat > /etc/elasticsearch/jvm.options.d/jvm.options <<'EOF'
-Xms1g
-Xmx1g
EOF

sleep 1

# ============================================================
# НАСТРОЙКА ELASTICSEARCH (точечно, после установки)
# ============================================================
sudo cp /home/ng/Загрузки/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml

echo "End config"
sleep 2
sudo systemctl daemon-reload
sleep 2
sudo systemctl enable --now elasticsearch.service

sleep 10

curl http://localhost:9200
# ============================================================
# PROMETHEUS
# ============================================================
echo ""
echo "=== Prometheus ==="

PROM_BIN="/usr/local/bin/prometheus"
PROM_VER="2.55.0"

if [ -f "$PROM_BIN" ]; then
   echo "Prometheus уже установлен"
else
   ARCH=$(uname -m)
   case "$ARCH" in
       x86_64)  GO_ARCH="amd64" ;;
       aarch64) GO_ARCH="arm64" ;;
       armv7l)  GO_ARCH="armv7" ;;
       *) echo "Архитектура $ARCH не поддерживается"; exit 1 ;;
   esac

   TARBALL="prometheus-${PROM_VER}.linux-${GO_ARCH}.tar.gz"
   URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/${TARBALL}"
   TMP_DIR=$(mktemp -d)

   echo "Скачиваем: $URL"
   if command -v wget &>/dev/null; then
       wget -q --show-progress -O "${TMP_DIR}/${TARBALL}" "$URL"
   else
       curl -fL --progress-bar -o "${TMP_DIR}/${TARBALL}" "$URL"
   fi

   tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
   SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "prometheus-*" | head -n1)

   mv "$SRC_DIR/prometheus"  /usr/local/bin/prometheus
   mv "$SRC_DIR/promtool"    /usr/local/bin/promtool
   chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool

   id -u prometheus &>/dev/null || useradd --no-create-home --shell /bin/false prometheus

   mkdir -p /etc/prometheus /var/lib/prometheus

   [ -d "$SRC_DIR/consoles" ] && cp -r "$SRC_DIR/consoles" /etc/prometheus/
   [ -d "$SRC_DIR/console_libraries" ] && cp -r "$SRC_DIR/console_libraries" /etc/prometheus/

   chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

   rm -rf "$TMP_DIR"
   echo "Prometheus установлен"
fi

cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
 scrape_interval: 15s
 evaluation_interval: 15s

scrape_configs:
 - job_name: 'prometheus'
   static_configs:
     - targets: ['localhost:9090']

 - job_name: 'nginx'
   static_configs:
     - targets: ['localhost:9113']
EOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml

cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
   --config.file=/etc/prometheus/prometheus.yml \
   --storage.tsdb.path=/var/lib/prometheus/ \
   --web.console.templates=/etc/prometheus/consoles \
   --web.console.libraries=/etc/prometheus/console_libraries
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus
sleep 2

# ============================================================
# GRAFANA
# ============================================================
echo ""
echo "=== Grafana ==="
systemctl daemon-reload
systemctl enable --now grafana-server

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
systemctl restart kibana
sleep 3

# ============================================================
# LOGSTASH
# ============================================================
echo ""
echo "=== Logstash ==="
mkdir -p /etc/logstash/conf.d
chown -R logstash:logstash /var/log/logstash 2>/dev/null || true
chown -R logstash:logstash /usr/share/logstash/data 2>/dev/null || true

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
   document_type => "nginx_logs"
 }
}
EOF

systemctl daemon-reload
systemctl enable logstash
systemctl restart logstash
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
systemctl restart filebeat

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
       echo "OK   $s"
   else
       echo "FAIL $s"
   fi
done
