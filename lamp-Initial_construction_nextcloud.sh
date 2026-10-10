#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Nextcloud Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# Supported DB: MariaDB, PostgreSQL (Local or RDS)
# ==============================================================================

# Parse DB engine and mode flexibly
arg1="$(echo "${1:-local}" | tr '[:upper:]' '[:lower:]')"
arg2="$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')"

if [ "${arg1}" = "postgres" ] || [ "${arg1}" = "postgresql" ] || [ "${arg1}" = "local-postgres" ]; then
    dbmode="local"; dbengine="postgres"; shift 1
elif [ "${arg1}" = "rds-postgres" ] || [ "${arg1}" = "rds-postgresql" ]; then
    dbmode="rds"; dbengine="postgres"; shift 1
elif [ "${arg1}" = "rds" ] || [ "${arg1}" = "rds-mariadb" ]; then
    if [ "${arg2}" = "postgres" ] || [ "${arg2}" = "postgresql" ]; then
        dbmode="rds"; dbengine="postgres"; shift 2
    else
        dbmode="rds"; dbengine="mariadb"; shift 1
    fi
elif [ "${arg1}" = "local" ]; then
    if [ "${arg2}" = "postgres" ] || [ "${arg2}" = "postgresql" ]; then
        dbmode="local"; dbengine="postgres"; shift 2
    else
        dbmode="local"; dbengine="mariadb"; shift 1
    fi
else
    dbmode="local"; dbengine="mariadb"
fi

dbname="${1:-nextclouddb}"
dbuser="${2:-ncadmin}"
dbpassword="${3:-ncpass123}"
rdsendpoint="${4:-}"
rdsuser="${5:-}"
rdspassword="${6:-}"

echo "==> Starting Nextcloud initial construction (Engine: ${dbengine}, Mode: ${dbmode})..."

# ------------------------------------------------------------------------------
# 1. Fetch Instance IP (IMDSv2 with IMDSv1 fallback)
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 2. OS Detection & Package Installation
# ------------------------------------------------------------------------------
COMMON_PHP_PKGS="httpd php php-cli php-common php-gd php-mbstring php-intl php-opcache php-xml php-zip php-bcmath php-gmp tar bzip2 unzip gzip"

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

# ------------------------------------------------------------------------------
# 3. Database Preparation
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 4. Download & Extract Nextcloud
# ------------------------------------------------------------------------------
echo "==> Downloading Nextcloud archive..."
mkdir -p /var/www/nextcloud-data
chown -R apache:apache /var/www/nextcloud-data
chmod 770 /var/www/nextcloud-data

cd /tmp
curl -fsSL -o nextcloud-latest.tar.bz2 https://download.nextcloud.com/server/releases/latest.tar.bz2
tar -xjf nextcloud-latest.tar.bz2
rm -rf /var/www/html/*
cp -r nextcloud/* /var/www/html/
rm -rf nextcloud nextcloud-latest.tar.bz2

chown -R apache:apache /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# ------------------------------------------------------------------------------
# 5. CLI Installation (occ maintenance:install)
# ------------------------------------------------------------------------------
echo "==> Running Nextcloud CLI installation (${nc_dbtype})..."
sudo -u apache /usr/bin/php /var/www/html/occ maintenance:install \
    --database="${nc_dbtype}" \
    --database-name="${dbname}" \
    --database-user="${dbuser}" \
    --database-pass="${dbpassword}" \
    --database-host="${nc_dbhost}" \
    --admin-user="${dbuser}" \
    --admin-pass="${dbpassword}" \
    --data-dir="/var/www/nextcloud-data"

# Add instance IP to trusted_domains
echo "==> Registering trusted domains..."
sudo -u apache /usr/bin/php /var/www/html/occ config:system:set trusted_domains 1 --value="${myip}"

# ------------------------------------------------------------------------------
# 6. Apache Configuration & Cron Setup
# ------------------------------------------------------------------------------
echo "==> Configuring Apache & Cron for Nextcloud..."
cat << 'EOS' > /etc/httpd/conf.d/nextcloud.conf
<Directory "/var/www/html">
    AllowOverride All
    Require all granted
    Options -Indexes
</Directory>
EOS

echo "*/5 * * * * apache /usr/bin/php -f /var/www/html/cron.php >/dev/null 2>&1" > /etc/cron.d/nextcloud
sudo -u apache /usr/bin/php /var/www/html/occ background:cron

echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

echo "==> Nextcloud initial construction completed successfully!"
echo "==> Database: ${nc_dbtype} (${dbmode})"
echo "==> Access URL: http://${myip}/"
echo "==> Admin User: ${dbuser}"
