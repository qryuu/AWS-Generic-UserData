#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Nextcloud Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# Supported Web: Apache (httpd), Nginx (with PHP-FPM)
# Supported DB: MariaDB, PostgreSQL (Local or RDS)
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数・環境変数で指定可能
# ------------------------------------------------------------------------------
# Web サーバー選択 (apache または nginx):
webserver="${WEBSERVER:-apache}"                           # apache (デフォルト) または nginx

# DB 種別 / エンジン指定:
#   local / mariadb      : ローカル MariaDB (デフォルト)
#   postgres             : ローカル PostgreSQL
#   rds / rds-mariadb    : Amazon RDS (MariaDB / MySQL)
#   rds-postgres         : Amazon RDS (PostgreSQL)
db_selection="${1:-local}"                                 # 第1引数: DB種別 (デフォルト: local)

# データベースおよび管理者アカウント設定:
dbname="${2:-nextclouddb}"                                 # 第2引数: DB名 (デフォルト: nextclouddb)
dbuser="${3:-ncadmin}"                                     # 第3引数: DBユーザー名 兼 Nextcloud管理者ID (デフォルト: ncadmin)
dbpassword="${4:-ncpass123}"                               # 第4引数: DBパスワード 兼 Nextcloud管理者パスワード (デフォルト: ncpass123)

# Amazon RDS 接続設定 (RDS モード時のみ必須):
rdsendpoint="${5:-}"                                       # 第5引数: RDSエンドポイント (例: host または host:3306 / 5432)
rdsuser="${6:-}"                                           # 第6引数: RDSマスターユーザー名
rdspassword="${7:-}"                                       # 第7引数: RDSマスターパスワード

# アプリケーション追加設定:
data_dir="${DATA_DIR:-/var/www/nextcloud-data}"

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
webserver="$(echo "${webserver}" | tr '[:upper:]' '[:lower:]')"

arg1="$(echo "${db_selection}" | tr '[:upper:]' '[:lower:]')"
if [ "${arg1}" = "postgres" ] || [ "${arg1}" = "postgresql" ] || [ "${arg1}" = "local-postgres" ]; then
    dbmode="local"; dbengine="postgres"
elif [ "${arg1}" = "rds-postgres" ] || [ "${arg1}" = "rds-postgresql" ]; then
    dbmode="rds"; dbengine="postgres"
elif [ "${arg1}" = "rds" ] || [ "${arg1}" = "rds-mariadb" ]; then
    dbmode="rds"; dbengine="mariadb"
else
    dbmode="local"; dbengine="mariadb"
fi

echo "==> Starting Nextcloud initial construction (Web: ${webserver}, Engine: ${dbengine}, Mode: ${dbmode})..."

# 1. Fetch Instance IP (IMDSv2 with IMDSv1 fallback)
echo "==> Fetching instance IP address via IMDS..."
TOKEN="$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)"
if [ -n "${TOKEN}" ]; then
    myip="$(curl -s -S -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    if [ -z "${myip}" ]; then
        myip="$(curl -s -S -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
    fi
else
    myip="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
fi
myip="${myip:-localhost}"
echo "==> Instance IP resolved to: ${myip}"

# 2. OS Detection & Package Installation
COMMON_PHP_PKGS="php php-cli php-common php-gd php-mbstring php-intl php-opcache php-xml php-zip php-bcmath php-gmp tar bzip2 unzip gzip"

if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing packages with dnf..."
    dnf update -y
    if [ "${webserver}" = "nginx" ]; then
        WEB_PKGS="nginx php-fpm"; web_user="nginx"
    else
        WEB_PKGS="httpd"; web_user="apache"
    fi

    if [ "${dbengine}" = "postgres" ]; then
        dnf install -y ${COMMON_PHP_PKGS} ${WEB_PKGS} php-pgsql postgresql15-server postgresql15
    else
        dnf install -y ${COMMON_PHP_PKGS} ${WEB_PKGS} php-mysqlnd mariadb105-server mariadb105
    fi
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing packages with yum..."
    yum update -y
    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y lamp-mariadb10.2-php7.2 || true
        [ "${webserver}" = "nginx" ] && amazon-linux-extras install -y nginx1 || true
        [ "${dbengine}" = "postgres" ] && amazon-linux-extras install -y postgresql14 || true
    fi

    if [ "${webserver}" = "nginx" ]; then
        WEB_PKGS="nginx php-fpm"; web_user="nginx"
    else
        WEB_PKGS="httpd"; web_user="apache"
    fi

    if [ "${dbengine}" = "postgres" ]; then
        yum install -y ${COMMON_PHP_PKGS} ${WEB_PKGS} php-pgsql postgresql-server postgresql
    else
        yum install -y ${COMMON_PHP_PKGS} ${WEB_PKGS} php-mysqlnd mariadb-server mariadb
    fi
fi

# Configure PHP-FPM user when Nginx is selected
if [ "${webserver}" = "nginx" ] && [ -f /etc/php-fpm.d/www.conf ]; then
    sed -i 's/^user = apache/user = nginx/' /etc/php-fpm.d/www.conf 2>/dev/null || true
    sed -i 's/^group = apache/group = nginx/' /etc/php-fpm.d/www.conf 2>/dev/null || true
fi

# Configure PHP settings recommended for Nextcloud
cat << 'EOF' > /etc/php.d/90-nextcloud.ini
memory_limit = 512M
upload_max_filesize = 500M
post_max_size = 500M
max_execution_time = 300
opcache.enable = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
EOF

# 3. Database Preparation
if [ "${dbengine}" = "postgres" ]; then
    if [ "${dbmode}" = "local" ]; then
        echo "==> Setting up local PostgreSQL..."
        if [ ! -s /var/lib/pgsql/data/PG_VERSION ]; then
            postgresql-setup --initdb
        fi
        systemctl enable --now postgresql.service

        sudo -u postgres psql -c "DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${dbuser}') THEN
                CREATE USER \"${dbuser}\" WITH ENCRYPTED PASSWORD '${dbpassword}';
            ELSE
                ALTER USER \"${dbuser}\" WITH ENCRYPTED PASSWORD '${dbpassword}';
            END IF;
        END
        \$\$;"

        sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '${dbname}'" | grep -q 1 || \
        sudo -u postgres psql -c "CREATE DATABASE \"${dbname}\" OWNER \"${dbuser}\" ENCODING 'UTF8';"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${dbname}\" TO \"${dbuser}\";"

        PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
        if [ -f "${PG_HBA}" ]; then
            sed -i 's/host    all             all             127.0.0.1\/32            ident/host    all             all             127.0.0.1\/32            md5/g' "${PG_HBA}"
            sed -i 's/host    all             all             ::1\/128                 ident/host    all             all             ::1\/128                 md5/g' "${PG_HBA}"
            systemctl reload postgresql.service
        fi
        nc_dbhost="localhost"
    else
        echo "==> Setting up remote RDS PostgreSQL..."
        rdshost="${rdsendpoint%%:*}"
        rdsport="${rdsendpoint##*:}"
        [ "${rdshost}" = "${rdsport}" ] && rdsport="5432"
        export PGPASSWORD="${rdspassword}"
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE USER \"${dbuser}\" WITH ENCRYPTED PASSWORD '${dbpassword}';" 2>/dev/null || true
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE DATABASE \"${dbname}\" OWNER \"${dbuser}\" ENCODING 'UTF8';" 2>/dev/null || true
        unset PGPASSWORD
        nc_dbhost="${rdsendpoint}"
    fi
    nc_dbtype="pgsql"

else
    # MariaDB
    if [ "${dbmode}" = "local" ]; then
        echo "==> Setting up local MariaDB..."
        systemctl enable --now mariadb.service
        vMySQLRootPasswd="$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)"
        SECRET_FILE="/home/ec2-user/.mysql.secrets"
        echo "${vMySQLRootPasswd}" > "${SECRET_FILE}"
        chmod 600 "${SECRET_FILE}"

        mysql -u root -e "
            ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${vMySQLRootPasswd}');
            DELETE FROM mysql.user WHERE User='';
            DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
            DROP DATABASE IF EXISTS test;
            DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
            FLUSH PRIVILEGES;" 2>/dev/null || mysql -u root -e "
            SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${vMySQLRootPasswd}');
            DELETE FROM mysql.user WHERE User='';
            DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
            DROP DATABASE IF EXISTS test;
            DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
            FLUSH PRIVILEGES;"

        CNF_FILE="/home/ec2-user/.my.cnf"
        cat << EOF > "${CNF_FILE}"
[client]
host = localhost
user = root
password = "${vMySQLRootPasswd}"
EOF
        chmod 600 "${CNF_FILE}"

        TMP_SQL="$(mktemp /tmp/nc_db.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        nc_dbhost="localhost"
    else
        echo "==> Setting up remote RDS MariaDB..."
        rdshost="${rdsendpoint%%:*}"
        rdsport="${rdsendpoint##*:}"
        [ "${rdshost}" = "${rdsport}" ] && rdsport="3306"
        RDS_CNF="/home/ec2-user/.rdsmy.cnf"
        cat << EOF > "${RDS_CNF}"
[client]
host = ${rdshost}
port = ${rdsport}
user = ${rdsuser}
password = "${rdspassword}"
EOF
        chmod 600 "${RDS_CNF}"
        TMP_SQL="$(mktemp /tmp/nc_rds.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        nc_dbhost="${rdsendpoint}"
    fi
    nc_dbtype="mysql"
fi

# 4. Download & Extract Nextcloud
echo "==> Downloading Nextcloud archive..."
mkdir -p "${data_dir}"
chown -R "${web_user}:${web_user}" "${data_dir}"
chmod 770 "${data_dir}"

cd /tmp
curl -fsSL -o nextcloud-latest.tar.bz2 https://download.nextcloud.com/server/releases/latest.tar.bz2
tar -xjf nextcloud-latest.tar.bz2
rm -rf /var/www/html/*
cp -r nextcloud/* /var/www/html/
rm -rf nextcloud nextcloud-latest.tar.bz2

chown -R "${web_user}:${web_user}" /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# 5. CLI Installation (occ maintenance:install)
echo "==> Running Nextcloud CLI installation (${nc_dbtype})..."
sudo -u "${web_user}" /usr/bin/php /var/www/html/occ maintenance:install \
    --database="${nc_dbtype}" \
    --database-name="${dbname}" \
    --database-user="${dbuser}" \
    --database-pass="${dbpassword}" \
    --database-host="${nc_dbhost}" \
    --admin-user="${dbuser}" \
    --admin-pass="${dbpassword}" \
    --data-dir="${data_dir}"

# Add instance IP to trusted_domains
echo "==> Registering trusted domains..."
sudo -u "${web_user}" /usr/bin/php /var/www/html/occ config:system:set trusted_domains 1 --value="${myip}"

# 6. Web Server Configuration & Cron Setup
echo "==> Configuring Web Server (${webserver}) & Cron for Nextcloud..."
if [ "${webserver}" = "nginx" ]; then
    cat << 'EOS' > /etc/nginx/conf.d/nextcloud.conf
server {
    listen       80;
    listen       [::]:80;
    server_name  _;
    root         /var/www/html;
    index        index.php index.html index.htm;

    client_max_body_size 512M;

    location / {
        rewrite ^ /index.php;
    }

    location ~ ^\/(?:build|tests|config|lib|3rdparty|templates|data)\/ {
        deny all;
    }
    location ~ ^\/(?:\.|autotest|occ|issue|indie|db_|console) {
        deny all;
    }

    location ~ \.php(?:$|\/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include        fastcgi_params;
        fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param  PATH_INFO        $path_info;
        fastcgi_param  HTTPS            off;
        fastcgi_pass   unix:/run/php-fpm/www.sock;
    }
}
EOS
    systemctl enable --now php-fpm.service
    systemctl enable --now nginx.service
else
    cat << 'EOS' > /etc/httpd/conf.d/nextcloud.conf
<Directory "/var/www/html">
    AllowOverride All
    Require all granted
    Options -Indexes
</Directory>
EOS
    systemctl enable --now httpd.service
fi

echo "*/5 * * * * ${web_user} /usr/bin/php -f /var/www/html/cron.php >/dev/null 2>&1" > /etc/cron.d/nextcloud
sudo -u "${web_user}" /usr/bin/php /var/www/html/occ background:cron

echo "==> Nextcloud initial construction completed successfully!"
echo "==> Web Server: ${webserver}"
echo "==> Database  : ${nc_dbtype} (${dbmode})"
echo "==> Access URL: http://${myip}/"
echo "==> Admin User: ${dbuser}"
