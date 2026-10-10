#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Redmine Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# Stack: Ruby, Bundler, Puma (systemd), Apache Reverse Proxy, MariaDB
# ==============================================================================

# Arguments / Setting values
usedb="$(echo "${1:-local}" | tr '[:upper:]' '[:lower:]')" # local or rds
dbname="${2:-redminedb}"                                   # DB name
dbuser="${3:-redmineuser}"                                 # DB user
dbpassword="${4:-redminepass}"                             # DB password
rdsendpoint="${5:-}"                                       # RDS endpoint (e.g. host or host:3306)
rdsuser="${6:-}"                                           # RDS master user
rdspassword="${7:-}"                                       # RDS master password

echo "==> Starting Redmine initial construction (DB mode: ${usedb})..."

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
        ruby \
        ruby-devel \
        rubygem-bundler \
        gcc \
        gcc-c++ \
        make \
        patch \
        zlib-devel \
        openssl-devel \
        mariadb105-server \
        mariadb105 \
        mariadb105-devel \
        ImageMagick \
        ImageMagick-devel \
        httpd \
        tar \
        gzip \
        git
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing packages with yum..."
    yum update -y
    yum install -y \
        ruby \
        ruby-devel \
        gcc \
        gcc-c++ \
        make \
        patch \
        zlib-devel \
        openssl-devel \
        mariadb-server \
        mariadb \
        mariadb-devel \
        ImageMagick \
        ImageMagick-devel \
        httpd \
        tar \
        gzip \
        git
    gem install bundler --no-document || true
fi

# ------------------------------------------------------------------------------
# 3. Database Preparation & User Creation
# ------------------------------------------------------------------------------
TMP_SQL="$(mktemp /tmp/redmine_init_db.XXXXXX.sql)"
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

    echo "==> Creating Redmine local database and user..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
    redmine_dbhost="localhost"

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

    echo "==> Creating Redmine database and user on RDS..."
    cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
    mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
    redmine_dbhost="${rdsendpoint}"
else
    echo "ERROR: Invalid DB type '${usedb}'. Specify 'local' or 'rds'." >&2
    exit 1
fi

rm -f "${TMP_SQL}"

# ------------------------------------------------------------------------------
# 4. Download & Setup Redmine
# ------------------------------------------------------------------------------
echo "==> Downloading Redmine..."
REDMINE_DIR="/var/www/redmine"
mkdir -p "${REDMINE_DIR}"
cd /tmp
curl -fsSL -o redmine-latest.tar.gz https://www.redmine.org/releases/redmine-5.1.3.tar.gz
tar -xzf redmine-latest.tar.gz -C "${REDMINE_DIR}" --strip-components 1
rm -f redmine-latest.tar.gz

cd "${REDMINE_DIR}"

# Create database configuration
cat << EOF > config/database.yml
production:
  adapter: mysql2
  database: ${dbname}
  host: ${redmine_dbhost%%:*}
  port: 3306
  username: ${dbuser}
  password: "${dbpassword}"
  encoding: utf8mb4
EOF

# Install gems and run migrations
echo "==> Installing Ruby gems with Bundler..."
bundle config set --local without 'development test'
bundle install

echo "==> Generating secret token and running migrations..."
bundle exec rake generate_secret_token
RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production REDMINE_LANG=ja bundle exec rake redmine:load_default_data

# Ensure puma gem is available
bundle add puma --skip-install || true
bundle install

# Set permissions
chown -R apache:apache "${REDMINE_DIR}"

# ------------------------------------------------------------------------------
# 5. systemd Service Setup for Puma
# ------------------------------------------------------------------------------
echo "==> Configuring systemd service for Redmine (Puma)..."
cat << EOF > /etc/systemd/system/redmine.service
[Unit]
Description=Redmine Application Server (Puma)
After=network.target mariadb.service

[Service]
Type=simple
User=apache
Group=apache
WorkingDirectory=${REDMINE_DIR}
Environment=RAILS_ENV=production
ExecStart=/usr/local/bin/bundle exec puma -b tcp://127.0.0.1:3000 -e production
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Fallback for bundle path if in /usr/bin
if [ ! -f /usr/local/bin/bundle ] && [ -f /usr/bin/bundle ]; then
    sed -i 's|/usr/local/bin/bundle|/usr/bin/bundle|g' /etc/systemd/system/redmine.service
fi

systemctl daemon-reload
systemctl enable --now redmine.service

# ------------------------------------------------------------------------------
# 6. Apache Reverse Proxy Configuration
# ------------------------------------------------------------------------------
echo "==> Configuring Apache reverse proxy for Redmine..."
cat << 'EOS' > /etc/httpd/conf.d/redmine.conf
<VirtualHost *:80>
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/

    <Proxy *>
        Require all granted
    </Proxy>
</VirtualHost>
EOS

echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

echo "==> Redmine initial construction completed successfully!"
echo "==> Access URL: http://${myip}/"
echo "==> Initial Admin Login : admin / admin"
