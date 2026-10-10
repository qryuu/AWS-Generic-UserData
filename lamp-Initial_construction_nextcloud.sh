#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Nextcloud Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# Arguments / Setting values
usedb="$(echo "${1:-local}" | tr '[:upper:]' '[:lower:]')" # local or rds
dbname="${2:-nextclouddb}"                                 # DB name
dbuser="${3:-ncadmin}"                                     # DB user / Nextcloud admin user
dbpassword="${4:-ncpass123}"                               # DB password / Nextcloud admin password
rdsendpoint="${5:-}"                                       # RDS endpoint (e.g. host or host:3306)
rdsuser="${6:-}"                                           # RDS master user
rdspassword="${7:-}"                                       # RDS master password

echo "==> Starting Nextcloud initial construction (DB mode: ${usedb})..."

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
if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing packages with dnf..."
    dnf update -y
    dnf install -y \
        httpd \
        mariadb105-server \
        mariadb105 \
        php \
        php-cli \
        php-common \
        php-gd \
        php-mbstring \
        php-intl \
        php-mysqlnd \
        php-opcache \
        php-xml \
        php-zip \
        php-bcmath \
        php-gmp \
        tar \
        bzip2 \
        unzip \
        gzip
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing packages with yum / amazon-linux-extras..."
    yum update -y
    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y lamp-mariadb10.2-php7.2 || true
    fi
    yum install -y \
        httpd \
        mariadb \
        mariadb-server \
        php \
        php-gd \
        php-mbstring \
        php-intl \
        php-mysqlnd \
        php-opcache \
        php-dom \
        php-xml \
        tar \
        bzip2 \
        unzip \
        gzip
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
# 3. Database Preparation & User Creation
# ------------------------------------------------------------------------------
TMP_SQL="$(mktemp /tmp/nc_init_db.XXXXXX.sql)"
trap 'rm -f "${TMP_SQL}"' EXIT

if [ "${usedb}" = "local" ]; then
    echo "==> Starting local MariaDB service..."
    systemctl enable --now mariadb.service

    vMySQLRootPasswd="$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)"
    SECRET_FILE="/home/ec2-user/.mysql.secrets"
    echo "${vMySQLRootPasswd}" > "${SECRET_FILE}"
    chmod 600 "${SECRET_FILE}"
    chown ec2-user:ec2-user "${SECRET_FILE}" 2>/dev/null || true

    echo "==> Securing local MariaDB installation..."
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
    chown ec2-user:ec2-user "${CNF_FILE}" 2>/dev/null || true

    echo "==> Creating Nextcloud local database and user..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
    nc_dbhost="localhost"

elif [ "${usedb}" = "rds" ]; then
    if [ -z "${rdsendpoint}" ] || [ -z "${rdsuser}" ] || [ -z "${rdspassword}" ]; then
        echo "ERROR: RDS mode requires endpoint, rdsuser, and rdspassword arguments." >&2
        exit 1
    fi
    echo "==> Configuring remote RDS database connection..."
    rdshost="${rdsendpoint%%:*}"
    rdsport="${rdsendpoint##*:}"
    if [ "${rdshost}" = "${rdsport}" ]; then
        rdsport="3306"
    fi

    RDS_CNF="/home/ec2-user/.rdsmy.cnf"
    cat << EOF > "${RDS_CNF}"
[client]
host = ${rdshost}
port = ${rdsport}
user = ${rdsuser}
password = "${rdspassword}"
EOF
    chmod 600 "${RDS_CNF}"
    chown ec2-user:ec2-user "${RDS_CNF}" 2>/dev/null || true

    echo "==> Creating Nextcloud database and user on RDS..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
    nc_dbhost="${rdsendpoint}"
else
    echo "ERROR: Invalid DB type '${usedb}'. Specify 'local' or 'rds'." >&2
    exit 1
fi

rm -f "${TMP_SQL}"

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
echo "==> Running Nextcloud CLI installation..."
sudo -u apache /usr/bin/php /var/www/html/occ maintenance:install \
    --database="mysql" \
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

# Background jobs via system cron
echo "*/5 * * * * apache /usr/bin/php -f /var/www/html/cron.php >/dev/null 2>&1" > /etc/cron.d/nextcloud
sudo -u apache /usr/bin/php /var/www/html/occ background:cron

echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

echo "==> Nextcloud initial construction completed successfully!"
echo "==> Access URL: http://${myip}/"
echo "==> Admin User: ${dbuser}"
