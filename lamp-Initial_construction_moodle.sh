#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Moodle LMS Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# Arguments / Setting values
usedb="$(echo "${1:-local}" | tr '[:upper:]' '[:lower:]')" # local or rds
dbname="${2:-moodledb}"                                    # DB name
dbuser="${3:-moodleuser}"                                  # DB user / Moodle admin user
dbpassword="${4:-moodlepass}"                              # DB password / Moodle admin password
rdsendpoint="${5:-}"                                       # RDS endpoint (e.g. host or host:3306)
rdsuser="${6:-}"                                           # RDS master user
rdspassword="${7:-}"                                       # RDS master password

echo "==> Starting Moodle LMS initial construction (DB mode: ${usedb})..."

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
        php-soap \
        php-zip \
        php-sodium \
        php-bcmath \
        git \
        tar \
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
        php-soap \
        git \
        tar \
        gzip
fi

# Configure PHP settings for Moodle
cat << 'EOF' > /etc/php.d/90-moodle.ini
max_input_vars = 5000
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
EOF

# ------------------------------------------------------------------------------
# 3. Database Preparation & User Creation
# ------------------------------------------------------------------------------
TMP_SQL="$(mktemp /tmp/moodle_init_db.XXXXXX.sql)"
trap 'rm -f "${TMP_SQL}"' EXIT

if [ "${usedb}" = "local" ]; then
    echo "==> Starting local MariaDB service..."
    systemctl enable --now mariadb.service

    # Generate secure random root password
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

    echo "==> Creating Moodle local database and user..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
    moodle_dbhost="localhost"

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

    echo "==> Creating Moodle database and user on RDS..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
    moodle_dbhost="${rdsendpoint}"
else
    echo "ERROR: Invalid DB type '${usedb}'. Specify 'local' or 'rds'." >&2
    exit 1
fi

rm -f "${TMP_SQL}"

# ------------------------------------------------------------------------------
# 4. Download Moodle & Setup Directories
# ------------------------------------------------------------------------------
echo "==> Downloading Moodle..."
mkdir -p /var/www/moodledata
chown -R apache:apache /var/www/moodledata
chmod 777 /var/www/moodledata

# Clone stable Moodle branch
rm -rf /var/www/html/*
git clone -b MOODLE_404_STABLE --depth 1 git://git.moodle.org/moodle.git /var/www/html/ 2>/dev/null || \
git clone -b MOODLE_404_STABLE --depth 1 https://github.com/moodle/moodle.git /var/www/html/

chown -R apache:apache /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# ------------------------------------------------------------------------------
# 5. Non-Interactive CLI Installation
# ------------------------------------------------------------------------------
echo "==> Installing Moodle via CLI..."
sudo -u apache /usr/bin/php /var/www/html/admin/cli/install.php \
    --non-interactive \
    --wwwroot="http://${myip}" \
    --dataroot="/var/www/moodledata" \
    --dbtype="mariadb" \
    --dbhost="${moodle_dbhost}" \
    --dbname="${dbname}" \
    --dbuser="${dbuser}" \
    --dbpass="${dbpassword}" \
    --fullname="Moodle Learning Platform" \
    --shortname="Moodle" \
    --adminuser="${dbuser}" \
    --adminpass="${dbpassword}" \
    --adminemail="admin@example.net" \
    --agree-license

# ------------------------------------------------------------------------------
# 6. Apache Configuration & Cron Setup
# ------------------------------------------------------------------------------
echo "==> Configuring Apache & Cron for Moodle..."
cat << 'EOS' > /etc/httpd/conf.d/moodle.conf
<Directory "/var/www/html">
    AllowOverride All
    Require all granted
</Directory>
EOS

# Setup Moodle Cron job
echo "* * * * * apache /usr/bin/php /var/www/html/admin/cli/cron.php >/dev/null 2>&1" > /etc/cron.d/moodle

echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

echo "==> Moodle initial construction completed successfully!"
echo "==> Access URL: http://${myip}/"
echo "==> Admin Login: ${dbuser}"
