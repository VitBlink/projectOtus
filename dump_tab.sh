#!/bin/bash
# backup_tables.sh — потабличный дамп базы
# Запуск: sudo bash backup_tables.sh [имя_базы]

set -e

DB="${1:-testdb}"
BASE_DIR="/home/rust/Загрузки"

#TIMESTAMP=$(date +%Y%m%d_%H%M%S)
#OUT="${BASE_DIR}/${TIMESTAMP}_${DB}"
OUT="${BASE_DIR}/${DB}"

mkdir -p "$OUT"

echo "=== Дамп базы $DB ==="
echo "Папка: $OUT"
echo ""

if ! mysql -N -e "SHOW DATABASES LIKE '${DB}';" | grep -q "$DB"; then
   echo "База $DB не найдена"
   exit 1
fi

echo ">>> _schema.sql"
mysqldump --no-data --routines --triggers --events "$DB" > "$OUT/_schema.sql"

for t in $(mysql -N -e "SHOW TABLES FROM ${DB}"); do
   echo ">>> ${t}.sql"
   mysqldump --single-transaction --routines --triggers --add-drop-table "$DB" "$t" > "$OUT/${t}.sql"
done

cat > "$OUT/_meta.txt" <<EOF
DB: $DB
Date: $(date)
Hostname: $(hostname)
Tables: $(mysql -N -e "SHOW TABLES FROM ${DB}" | wc -l)
MySQL: $(mysql -V | awk '{print $5}')
EOF

echo ""
echo "=== Готово ==="
ls -lh "$OUT"
echo ""
echo "Дамп: $OUT"
