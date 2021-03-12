#!/bin/bash
#Setting value 設定値
rdsnama= #RDSエンドポイントを入力
rdsuser= #RDSMasterユーザ名
rdspassword= #RDSMasterパスワード
dbname= #DBname DB名
dbuser= #DBUserName DBユーザ名
dbpassword= #DBUserPassqword DBユーザパスワード

##Package installation パッケージインストール
yum update -y
amazon-linux-extras install epel redis4.0 lamp-mariadb10.2-php7.2 -y
yum install  httpd mariadb mariadb-server php-gd php-mbstring php-intl php-pecl-apcu php-mysqlnd php-pecl-redis php-opcache php-imagick php-zip php-dom -y
yum update -y

##maria db Start mariadb起動
systemctl start mariadb.service

##maria root Random password generation ランダムパスワード生成
vMySQLRootPasswd="$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 16 | tee -a /home/ec2-user/.mysql.secrets)"

##MySql_secure_installation mariaDB 初期化
mysql -u root --password= -e "
    UPDATE mysql.user SET Password=PASSWORD('${vMySQLRootPasswd}') WHERE User='root';
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;"

##Create empty database 初期DB作成
echo [mysql] >> /home/ec2-user/my.cnf 
echo host = localhost >> /home/ec2-user/my.cnf
echo user = root >> /home/ec2-user/my.cnf
dbrootpass() {
cat /home/ec2-user/.mysql.secrets
}
dbrootpass=`dbrootpass`
echo password = ${dbrootpass} >> /home/ec2-user/my.cnf
echo "create database ${dbname} character set utf8 collate utf8_bin; grant all privileges on ${dbname}.* to ${dbuser}@localhost identified by '${dbpassword}';" > /tmp/create.sql
mysql --defaults-extra-file=/home/ec2-user/my.cnf < /tmp/create.sql

##WordPress ダウンロード
wget https://ja.wordpress.org/latest-ja.tar.gz -p /var/www/



##Auto start setting 自動起動設定
systemctl enable httpd.service
systemctl enable mariadb.service
systemctl enable redis.service

##OS Reboot OS再起動
reboot