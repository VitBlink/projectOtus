sudo systemctl stop mysql
sudo systemctl disable mysql
sudo apt purge -y mysql-server mysql-client mysql-common 'mysql-server-core-*' 'mysql-client-core-*'
sudo apt autoremove -y
sudo apt autoclean
sudo rm -rf /var/lib/mysql
sudo rm -rf /var/lib/mysql-files
sudo rm -rf /var/lib/mysql-keyring
sudo rm -rf /etc/mysql
sudo rm -rf /var/log/mysql
sudo deluser mysql
sudo delgroup mysql
sudo rm -f /etc/apt/sources.list.d/mysql.list
sudo rm -f /etc/apt/trusted.gpg.d/mysql.gpg
sudo apt update
