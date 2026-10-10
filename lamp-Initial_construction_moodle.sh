#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Moodle LMS Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数で指定可能
# ------------------------------------------------------------------------------
# DB 種別 / エンジン指定:
#   local / mariadb      : ローカル MariaDB (デフォルト)
#   postgres             : ローカル PostgreSQL
#   rds / rds-mariadb    : Amazon RDS (MariaDB / MySQL)
#   rds-postgres         : Amazon RDS (PostgreSQL)
db_selection="${1:-local}"                                 # 第1引数: DB種別 (デフォルト: local)

# データベースおよび管理者アカウント設定:
dbname="${2:-moodledb}"                                    # 第2引数: DB名 (デフォルト: moodledb)
dbuser="${3:-moodleuser}"                                  # 第3引数: DBユーザー名 兼 Moodle管理者ID (デフォルト: moodleuser)
dbpassword="${4:-moodlepass}"                              # 第4引数: DBパスワード 兼 Moodle管理者パスワード (デフォルト: moodlepass)

# Amazon RDS 接続設定 (RDS モード時のみ必須):
rdsendpoint="${5:-}"                                       # 第5引数: RDSエンドポイント (例: host または host:3306 / 5432)
rdsuser="${6:-}"                                           # 第6引数: RDSマスターユーザー名
rdspassword="${7:-}"                                       # 第7引数: RDSマスターパスワード

# アプリケーション追加設定:
admin_email="${ADMIN_EMAIL:-admin@example.net}"
fullname="${MOODLE_FULLNAME:-Moodle Learning Platform}"
shortname="${MOODLE_SHORTNAME:-Moodle}"

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
# Parse DB engine and mode
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

echo "==> Starting Moodle initial construction (Engine: ${dbengine}, Mode: ${dbmode})..."

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
COMMON_PHP_PKGS="httpd php php-cli php-common php-gd php-mbstring php-intl php-opcache php-xml php-soap php-zip php-sodium php-bcmath git tar gzip"

if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing packages with dnf..."
    dnf update -y
    if [ "${dbengine}" = "postgres" ]; then
        dnf install -y ${COMMON_PHP_PKGS} php-pgsql postgresql15-server postgresql15
    else
        dnf install -y ${COMMON_PHP_PKGS} php-mysqlnd mariadb105-server mariadb105
    fi
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing packages with yum..."
    yum update -y
    if [ "${dbengine}" = "postgres" ]; then
        if command -v amazon-linux-extras >/dev/null 2>&1; then
            amazon-linux-extras install -y lamp-mariadb10.2-php7.2 postgresql14 || true
        fi
        yum install -y ${COMMON_PHP_PKGS} php-pgsql postgresql-server postgresql
    else
        if command -v amazon-linux-extras >/dev/null 2>&1; then
            amazon-linux-extras install -y lamp-mariadb10.2-php7.2 || true
        fi
        yum install -y ${COMMON_PHP_PKGS} php-mysqlnd mariadb-server mariadb
    fi
fi

# Configure PHP settings for Moodle
cat << 'EOF' > /etc/php.d/90-moodle.ini
max_input_vars = 5000
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
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
        moodle_dbhost="localhost"
        moodle_dbport="5432"
    else
        echo "==> Setting up remote RDS PostgreSQL..."
        rdshost="${rdsendpoint%%:*}"
        rdsport="${rdsendpoint##*:}"
        [ "${rdshost}" = "${rdsport}" ] && rdsport="5432"
        export PGPASSWORD="${rdspassword}"
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE USER \"${dbuser}\" WITH ENCRYPTED PASSWORD '${dbpassword}';" 2>/dev/null || true
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE DATABASE \"${dbname}\" OWNER \"${dbuser}\" ENCODING 'UTF8';" 2>/dev/null || true
        unset PGPASSWORD
        moodle_dbhost="${rdshost}"
        moodle_dbport="${rdsport}"
    fi
    moodle_dbtype="pgsql"

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

        TMP_SQL="$(mktemp /tmp/moodle_db.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        moodle_dbhost="localhost"
        moodle_dbport="3306"
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
        TMP_SQL="$(mktemp /tmp/moodle_rds.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        moodle_dbhost="${rdshost}"
        moodle_dbport="${rdsport}"
    fi
    moodle_dbtype="mariadb"
fi

# 4. Download Moodle & Setup Directories
echo "==> Downloading Moodle..."
mkdir -p /var/www/moodledata
chown -R apache:apache /var/www/moodledata
chmod 777 /var/www/moodledata

rm -rf /var/www/html/*
git clone -b MOODLE_404_STABLE --depth 1 git://git.moodle.org/moodle.git /var/www/html/ 2>/dev/null || \
git clone -b MOODLE_404_STABLE --depth 1 https://github.com/moodle/moodle.git /var/www/html/

chown -R apache:apache /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# 5. Non-Interactive CLI Installation
echo "==> Installing Moodle via CLI (${moodle_dbtype})..."
sudo -u apache /usr/bin/php /var/www/html/admin/cli/install.php \
    --non-interactive \
    --wwwroot="http://${myip}" \
    --dataroot="/var/www/moodledata" \
    --dbtype="${moodle_dbtype}" \
    --dbhost="${moodle_dbhost}" \
    --dbport="${moodle_dbport}" \
    --dbname="${dbname}" \
    --dbuser="${dbuser}" \
    --dbpass="${dbpassword}" \
    --fullname="${fullname}" \
    --shortname="${shortname}" \
    --adminuser="${dbuser}" \
    --adminpass="${dbpassword}" \
    --adminemail="${admin_email}" \
    --agree-license

# 6. Apache Configuration & Cron Setup
echo "==> Configuring Apache & Cron for Moodle..."
cat << 'EOS' > /etc/httpd/conf.d/moodle.conf
<Directory "/var/www/html">
    AllowOverride All
    Require all granted
</Directory>
EOS

echo "* * * * * apache /usr/bin/php /var/www/html/admin/cli/cron.php >/dev/null 2>&1" > /etc/cron.d/moodle

echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

echo "==> Moodle initial construction completed successfully!"
echo "==> Database: ${moodle_dbtype} (${dbmode})"
echo "==> Access URL: http://${myip}/"
echo "==> Admin Login: ${dbuser}"
