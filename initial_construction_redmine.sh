#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Redmine Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# Supported DB: MariaDB, PostgreSQL (Local or RDS)
# Stack: Ruby, Bundler, Puma (systemd), Apache Reverse Proxy
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

dbname="${1:-redminedb}"
dbuser="${2:-redmineuser}"
dbpassword="${3:-redminepass}"
rdsendpoint="${4:-}"
rdsuser="${5:-}"
rdspassword="${6:-}"

echo "==> Starting Redmine initial construction (Engine: ${dbengine}, Mode: ${dbmode})..."

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
COMMON_BUILD_PKGS="ruby ruby-devel gcc gcc-c++ make patch zlib-devel openssl-devel ImageMagick ImageMagick-devel httpd tar gzip git"

if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing packages with dnf..."
    dnf update -y
    if [ "${dbengine}" = "postgres" ]; then
        dnf install -y ${COMMON_BUILD_PKGS} rubygem-bundler postgresql15-server postgresql15 libpq-devel
    else
        dnf install -y ${COMMON_BUILD_PKGS} rubygem-bundler mariadb105-server mariadb105 mariadb105-devel
    fi
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing packages with yum..."
    yum update -y
    if [ "${dbengine}" = "postgres" ]; then
        if command -v amazon-linux-extras >/dev/null 2>&1; then
            amazon-linux-extras install -y postgresql14 || true
        fi
        yum install -y ${COMMON_BUILD_PKGS} postgresql-server postgresql postgresql-devel
    else
        yum install -y ${COMMON_BUILD_PKGS} mariadb-server mariadb mariadb-devel
    fi
    gem install bundler --no-document || true
fi

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
        redmine_dbhost="localhost"
        redmine_dbport="5432"
    else
        echo "==> Setting up remote RDS PostgreSQL..."
        rdshost="${rdsendpoint%%:*}"
        rdsport="${rdsendpoint##*:}"
        [ "${rdshost}" = "${rdsport}" ] && rdsport="5432"
        export PGPASSWORD="${rdspassword}"
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE USER \"${dbuser}\" WITH ENCRYPTED PASSWORD '${dbpassword}';" 2>/dev/null || true
        psql -h "${rdshost}" -p "${rdsport}" -U "${rdsuser}" -d postgres -c "CREATE DATABASE \"${dbname}\" OWNER \"${dbuser}\" ENCODING 'UTF8';" 2>/dev/null || true
        unset PGPASSWORD
        redmine_dbhost="${rdshost}"
        redmine_dbport="${rdsport}"
    fi
    db_adapter="postgresql"

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

        TMP_SQL="$(mktemp /tmp/redmine_db.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        redmine_dbhost="localhost"
        redmine_dbport="3306"
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
        TMP_SQL="$(mktemp /tmp/redmine_rds.XXXXXX.sql)"
        cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'%';
FLUSH PRIVILEGES;
EOF
        mysql --defaults-extra-file="${RDS_CNF}" < "${TMP_SQL}"
        rm -f "${TMP_SQL}"
        redmine_dbhost="${rdshost}"
        redmine_dbport="${rdsport}"
    fi
    db_adapter="mysql2"
fi

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
  adapter: ${db_adapter}
  database: ${dbname}
  host: ${redmine_dbhost}
  port: ${redmine_dbport}
  username: ${dbuser}
  password: "${dbpassword}"
  encoding: utf8mb4
EOF

if [ "${db_adapter}" = "postgresql" ]; then
    sed -i 's/encoding: utf8mb4/encoding: utf8/g' config/database.yml
fi

# Install gems and run migrations
echo "==> Installing Ruby gems with Bundler (${db_adapter})..."
bundle config set --local without 'development test'
if [ "${db_adapter}" = "postgresql" ]; then
    bundle add pg --skip-install || true
fi
bundle install

echo "==> Generating secret token and running migrations..."
bundle exec rake generate_secret_token
RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production REDMINE_LANG=ja bundle exec rake redmine:load_default_data

bundle add puma --skip-install || true
bundle install

chown -R apache:apache "${REDMINE_DIR}"

# ------------------------------------------------------------------------------
# 5. systemd Service Setup for Puma
# ------------------------------------------------------------------------------
echo "==> Configuring systemd service for Redmine (Puma)..."
cat << EOF > /etc/systemd/system/redmine.service
[Unit]
Description=Redmine Application Server (Puma)
After=network.target

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
echo "==> Database: ${db_adapter} (${dbmode})"
echo "==> Access URL: http://${myip}/"
echo "==> Initial Admin Login : admin / admin"
