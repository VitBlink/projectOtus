#!/bin/bash

echo "BEGIN"

#mysql -u root -e "STOP REPLICA SQL_THREAD;"

MYSQL="root"
DUMP="dupm_DB"
PWD=""
mkdir -p "$DUMP"

options="--single-transaction --master-data=2 --routines --triggers --skip-lock-tables --source-data"
#pos =$(mysql -u root -e "SHOW SLAVE STATUS\G" | awk '/Master+Log_File/{print $2} / Exec_Master_Log_Pos/{print $2}' | paste -d',' - -)

DBs=$(mysql -u "$MYSQL" $PWD -e "SHOW DATABASES;" | grep -vE "(Database|information_schema|performance_schema|mysql|sys)")

for db in $DBs; do
	echo "Сканируем базу: $db"
	mkdir -p "$DUMP/$db"
	tables=$(mysql -u "$MYSQL" $PWD  -D "$db" -e "SHOW TABLES;" | tail -n +2)

	for table in $tables; do
		echo "Сканирем таблицу: $table"
		safe_table=$(echo "$table" | sed '/ _/g')
		#echo "$db.$table: MASTER_LOG_FILE = '$(echo $pos | cut -d',' -f1)', MASTER_LOG_POS=$(echo $pos | cut -d',' -f2) $(date)" > "$DUMP/$db/$table.sql"
		
		mysqldump -u "$MYSQL" $options $PWD  "$db" "$table" > "$DUMP/$db/$table.sql"
	
	done
done

#mysql -u root -e "START REPLICA;"

echo "ALL DONE"
