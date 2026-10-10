#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Redmine Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# Stack: Ruby, Bundler, Puma (systemd), Apache Reverse Proxy
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
dbname="${2:-redminedb}"                                   # 第2引数: DB名 (デフォルト: redminedb)
dbuser="${3:-redmineuser}"                                 # 第3引数: DBユーザー名 (デフォルト: redmineuser)
dbpassword="${4:-redminepass}"                             # 第4引数: DBパスワード (デフォルト: redminepass)

# Amazon RDS 接続設定 (RDS モード時のみ必須):
rdsendpoint="${5:-}"                                       # 第5引数: RDSエンドポイント (例: host または host:3306 / 5432)
rdsuser="${6:-}"                                           # 第6引数: RDSマスターユーザー名
rdspassword="${7:-}"                                       # 第7引数: RDSマスターパスワード

# アプリケーション追加設定:
redmine_dir="${REDMINE_DIR:-/var/www/redmine}"
redmine_port="${REDMINE_PORT:-3000}"

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

echo "==> Starting Redmine initial construction (Engine: ${dbengine}, Mode: ${dbmode})..."

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

# 4. Download & Setup Redmine
echo "==> Downloading Redmine..."
mkdir -p "${redmine_dir}"
cd /tmp
curl -fsSL -o redmine-latest.tar.gz https://www.redmine.org/releases/redmine-5.1.3.tar.gz
tar -xzf redmine-latest.tar.gz -C "${redmine_dir}" --strip-components 1
rm -f redmine-latest.tar.gz

cd "${redmine_dir}"

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

chown -R apache:apache "${redmine_dir}"

# 5. systemd Service Setup for Puma
echo "==> Configuring systemd service for Redmine (Puma)..."
cat << EOF > /etc/systemd/system/redmine.service
[Unit]
Description=Redmine Application Server (Puma)
After=network.target

[Service]
Type=simple
User=apache
Group=apache
WorkingDirectory=${redmine_dir}
Environment=RAILS_ENV=production
ExecStart=/usr/local/bin/bundle exec puma -b tcp://127.0.0.1:${redmine_port} -e production
Restart=always

[Install]
WantedBy=multi-user.target
EOF

if [ ! -f /usr/local/bin/bundle ] && [ -f /usr/bin/bundle ]; then
    sed -i 's|/usr/local/bin/bundle|/usr/bin/bundle|g' /etc/systemd/system/redmine.service
fi

systemctl daemon-reload
systemctl enable --now redmine.service

# 6. Apache Reverse Proxy Configuration
echo "==> Configuring Apache reverse proxy for Redmine..."
cat << EOS > /etc/httpd/conf.d/redmine.conf
<VirtualHost *:80>
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${redmine_port}/
    ProxyPassReverse / http://127.0.0.1:${redmine_port}/

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
