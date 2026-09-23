#!/bin/bash
# setup_A_monitoring_elk.sh
# Запуск: sudo bash setup_A_monitoring_elk.sh
# .deb (и/или .tar.gz с ними) для Grafana и ELK должны быть в /tmp/deb/

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

# vm.max_map_count — нужен для Elasticsearch
CURRENT_MAP=$(sysctl -n vm.max_map_count)
if [ "$CURRENT_MAP" -lt 262144 ]; then
   sysctl -w vm.max_map_count=262144
   grep -q "^vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf
   echo "vm.max_map_count = 262144"
else
   echo "vm.max_map_count уже $CURRENT_MAP"
fi

# file descriptors для elasticsearch
if ! grep -q "^elasticsearch" /etc/security/limits.conf; then
   echo "elasticsearch  -  nofile  65535" >> /etc/security/limits.conf
   echo "elasticsearch  -  memlock unlimited" >> /etc/security/limits.conf
fi

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
# УСТАНОВКА .DEB (все, КРОМЕ elasticsearch)
# ============================================================
echo ""
echo "=== Установка .deb (кроме elasticsearch) ==="
for deb in "$DEB_DIR"/*.deb; do
   name=$(basename "$deb")
   if [[ "$name" == elasticsearch-* ]]; then
       echo ">>> Пропуск: $name (установим отдельно)"
       continue
   fi
   echo ">>> $(basename "$deb")"
   apt install -y "$deb"
done

# ============================================================
# ELASTICSEARCH — безопасная установка (без зависания)
# ============================================================
echo ""
echo "=== Elasticsearch — безопасная установка ==="

ES_DEB=$(ls "$DEB_DIR"/elasticsearch-*.deb 2>/dev/null | head -n1)

if [ -z "$ES_DEB" ]; then
   echo "Elasticsearch .deb не найден — пропускаем"
else
   # Уже установлен?
   if dpkg -l | grep -q "^ii  elasticsearch"; then
       echo "Elasticsearch уже установлен"
   else
       echo ">>> Распаковка без post-install: $(basename "$ES_DEB")"
       dpkg --unpack "$ES_DEB"

       # Удаляем проблемный postinst, который пытается запустить сервис и виснет
       rm -f /var/lib/dpkg/info/elasticsearch.postinst

       echo ">>> Конфигурация пакета"
       dpkg --configure elasticsearch

       echo ">>> Доустановка зависимостей"
       apt-get install -yf

       echo "Elasticsearch установлен"
   fi
fi

# ============================================================
# НАСТРОЙКА ELASTICSEARCH (до первого запуска)
# ============================================================
if dpkg -l | grep -q "^ii  elasticsearch"; then
   echo ""
   echo "=== Настройка Elasticsearch ==="

   # 1. Уменьшаем heap
   mkdir -p /etc/elasticsearch/jvm.options.d
   cat > /etc/elasticsearch/jvm.options.d/heap.options <<'EOF'
-Xms256m
-Xmx256m
EOF
   echo "Heap: 256m"

   # 2. Основной конфиг
   cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: test-cluster
node.name: node-1
network.host: localhost
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
bootstrap.memory_lock: false
EOF
   echo "elasticsearch.yml настроен"

   # 3. Права
   if id elasticsearch &>/dev/null; then
       chown -R elasticsearch:elasticsearch /etc/elasticsearch
       chown -R elasticsearch:elasticsearch /var/lib/elasticsearch 2>/dev/null || true
       chown -R elasticsearch:elasticsearch /var/log/elasticsearch 2>/dev/null || true
       echo "Права выставлены"
   fi

   # 4. systemd unit (если не создан пакетом)
   if [ ! -f /etc/systemd/system/elasticsearch.service ] && \
      [ ! -f /lib/systemd/system/elasticsearch.service ]; then
       cat > /etc/systemd/system/elasticsearch.service <<'EOF'
[Unit]
Description=Elasticsearch
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=elasticsearch
Group=elasticsearch
ExecStart=/usr/share/elasticsearch/bin/elasticsearch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
   fi

   systemctl daemon-reload
   systemctl enable elasticsearch
   systemctl start elasticsearch
   sleep 8

   if systemctl is-active --quiet elasticsearch; then
       echo "Elasticsearch запущен"
   else
       echo "Elasticsearch не запустился. Логи:"
       journalctl -u elasticsearch -n 20 --no-pager
   fi
fi

# ============================================================
# PROMETHEUS — скачивание с GitHub
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

# Конфиг Prometheus
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
 }
}
EOF

systemctl daemon-reload
systemctl enable logstash
systemctl restart logstash
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
systemctl restart kibana
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
