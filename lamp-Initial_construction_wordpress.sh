#!/bin/bash
#Setting value 設定値
usedb=${1:-local} #local or RDS
dbname=${2:-wpdb} #DBname DB名
dbuser=${3:-wpuser} #DBUserName DBユーザ名
dbpassword=${4:-wppass} #DBUserPassqword DBユーザパスワード
rdsnama=$5 #RDSエンドポイントを入力
rdsuser=$6 #RDSMasterユーザ名
rdspassword=$7 #RDSMasterパスワード
myip=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`

##Package installation パッケージインストール
yum update -y
amazon-linux-extras install epel redis4.0 lamp-mariadb10.2-php7.2 -y
yum install  httpd mariadb mariadb-server php-gd php-mbstring php-intl php-pecl-apcu php-mysqlnd php-pecl-redis php-opcache php-imagick php-zip php-dom -y
yum update -y

##maria db Start mariadb起動
if [ ${usedb} = "local" ];then
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
fi
##WordPress インストール
cd /home/ec2-user/
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
chown apache:apache /var/www/html/
sudo -u apache /usr/local/bin/wp core download --locale=ja --path=/var/www/html
if [ ${usedb} = "local" ];then
sudo -u apache /usr/local/bin/wp core config --dbname=$dbname --dbuser=$dbuser --dbpass=$dbpassword --dbhost='localhost' --path=/var/www/html
else
sudo -u apache /usr/local/bin/wp core config --dbname=$dbname --dbuser=$rdsuser --dbpass=$rdspassword --dbhost=$rdsnama --path=/var/www/html
fi

##DB作成
if [ ${usedb} = "local" ];then
echo "create database ${dbname} character set utf8 collate utf8_bin; grant all privileges on ${dbname}.* to ${dbuser}@localhost identified by '${dbpassword}';" > /tmp/create.sql
mysql --defaults-extra-file=/home/ec2-user/my.cnf < /tmp/create.sql
else
echo [mysql] >> /home/ec2-user/my.cnf 
echo host = $rdsnama >> /home/ec2-user/my.cnf
echo user = $rdsuser >> /home/ec2-user/my.cnf
echo password =  $rdspassword >> /home/ec2-user/my.cnf
echo "create database ${dbname} character set utf8 collate utf8_bin; grant all privileges on ${dbname}.* to ${dbuser}@'%' identified by '${dbpassword}';" > /tmp/create.sql
mysql --defaults-extra-file=/home/ec2-user/my.cnf < /tmp/create.sql

##Wordpress 初期作成
sudo -u apache /usr/local/bin/wp db create --path=/var/www/html
sudo -u apache /usr/local/bin/wp core install --url=$myip --title='WordPress' --admin_name=$dbuser --admin_password=$dbpassword --admin_email='wordpress@example.net'  --path=/var/www/html

cat << EOS | sudo tee /etc/httpd/conf.d/wordpress.conf
<Directory "/var/www/html">
    AllowOverride All
</Directory>
EOS

##Auto start setting 自動起動設定
systemctl enable httpd.service
systemctl enable mariadb.service

##OS Reboot OS再起動
reboot