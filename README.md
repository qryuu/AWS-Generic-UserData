# AWS-Generic-UserData

A collection of AWS UserData for general use

## Overview お品書き

### lamp-Initial_construction.sh

Install Apache, php, mariaDB, redis for Amazon Linux2.
Initialize mariaDB and create an empty DB with the name specified in “Setting value”.

Amazon Linux2 に対してApache,php,mariaDB,redisをインストールします。
mariaDBの初期化を行い、”設定値” で指定された名前の空DBを作成します。

### lamp-Initial_construction_wordpress.sh

Install Wordpress for Amazon Linux2.
Initialize mariaDB and create an Wordpress DB with the name specified in “Setting value”.
  
argument "DBtype Local or RDS" "Wordpress db name" "wordpress db user name" "wordpress db password" "rds endpoint" "rds root user" "rds root password"  

Amazon Linux2 に対してWordpressをインストールします。
mariaDBの初期化を行い、”設定値” で指定された名前のWordpressDBを作成します。  
  
引数 "DBtype Local or RDS" "Wordpress db name" "wordpress db user name" "wordpress db password" "rds endpoint" "rds root user" "rds root password"  

```sh UserData
#!/bin/bash  
  
curl -L https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/WordPress/lamp-Initial_construction_wordpress.sh | bash -s "arguments"
```
  