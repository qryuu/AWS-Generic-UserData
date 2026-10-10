#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: PostgreSQL Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数で指定可能
# ------------------------------------------------------------------------------
dbname="${1:-mydb}"            # 第1引数: 作成する DB 名 (デフォルト: mydb)
dbuser="${2:-myuser}"          # 第2引数: 作成する DB ユーザー名 (デフォルト: myuser)
dbpassword="${3:-mypassword}"  # 第3引数: 作成する DB ユーザーパスワード (デフォルト: mypassword)

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
echo "==> Starting PostgreSQL initial construction..."

# 1. OS Detection & Package Installation
if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing PostgreSQL 15 with dnf..."
    dnf update -y
    dnf install -y postgresql15-server postgresql15 tar gzip
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing PostgreSQL with yum..."
    yum update -y
    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y postgresql14 || true
    fi
    yum install -y postgresql-server postgresql tar gzip
fi

# 2. Database Cluster Initialization & Service Startup
echo "==> Initializing PostgreSQL database cluster..."
if [ ! -s /var/lib/pgsql/data/PG_VERSION ]; then
    postgresql-setup --initdb
fi

echo "==> Starting and enabling PostgreSQL service..."
systemctl enable --now postgresql.service

# 3. Create User & Database
echo "==> Creating database user '${dbuser}' and database '${dbname}'..."
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

# 4. Authentication Configuration (pg_hba.conf)
echo "==> Configuring client authentication (pg_hba.conf)..."
PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
if [ -f "${PG_HBA}" ]; then
    sed -i 's/host    all             all             127.0.0.1\/32            ident/host    all             all             127.0.0.1\/32            md5/g' "${PG_HBA}"
    sed -i 's/host    all             all             ::1\/128                 ident/host    all             all             ::1\/128                 md5/g' "${PG_HBA}"
    systemctl reload postgresql.service
fi

PGPASS_FILE="/home/ec2-user/.pgpass"
echo "localhost:5432:${dbname}:${dbuser}:${dbpassword}" > "${PGPASS_FILE}"
echo "127.0.0.1:5432:${dbname}:${dbuser}:${dbpassword}" >> "${PGPASS_FILE}"
chmod 600 "${PGPASS_FILE}"
chown ec2-user:ec2-user "${PGPASS_FILE}" 2>/dev/null || true

echo "==> PostgreSQL construction completed successfully!"
echo "==> Database: ${dbname}"
echo "==> User    : ${dbuser}"
