sudo mysql -e "
DROP DATABASE IF EXISTS ;
DROP DATABASE IF EXISTS vip_db;
DROP USER IF EXISTS 'r_us'@'localhost';
DROP USER IF EXISTS 'replica'@'%';
DROP USER IF EXISTS 'replica'@'localhost';
DROP USER IF EXISTS 'replica'@'192.168.58.107';
FLUSH PRIVILEGES;
"
