#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: LAMP Initial Construction Script
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数で指定可能
# ------------------------------------------------------------------------------
dbname="${1:-lampdb}"          # 第1引数: 作成する DB 名 (デフォルト: lampdb)
dbuser="${2:-lampuser}"        # 第2引数: 作成する DB ユーザー名 (デフォルト: lampuser)
dbpassword="${3:-lamppass}"    # 第3引数: 作成する DB ユーザーパスワード (デフォルト: lamppass)

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
echo "==> Starting LAMP stack initial construction..."

# 1. OS Detection & Package Installation
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
        tar \
        gzip
fi

# 2. MariaDB Service Startup & Initialization
echo "==> Starting MariaDB service..."
systemctl enable --now mariadb.service

vMySQLRootPasswd="$(cat /dev/urandom | tr -dc '[:alnum:]' | head -c 24)"
SECRET_FILE="/home/ec2-user/.mysql.secrets"
echo "${vMySQLRootPasswd}" > "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"
chown ec2-user:ec2-user "${SECRET_FILE}" 2>/dev/null || true

echo "==> Securing MariaDB installation..."
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

# 3. Create Database & Application User
echo "==> Creating initial database '${dbname}' and user '${dbuser}'..."
TMP_SQL="$(mktemp /tmp/create_db.XXXXXX.sql)"
trap 'rm -f "${TMP_SQL}"' EXIT

cat << EOF > "${TMP_SQL}"
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpassword}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF

mysql --defaults-extra-file="${CNF_FILE}" < "${TMP_SQL}"
rm -f "${TMP_SQL}"

# 4. Apache Startup & Verification
echo "==> Starting Apache HTTP Server..."
systemctl enable --now httpd.service

if [ ! -f /var/www/html/index.php ] && [ ! -f /var/www/html/index.html ]; then
    cat << 'EOF' > /var/www/html/index.php
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>LAMP Server Ready</title>
</head>
<body>
    <h1>LAMP Server is running!</h1>
    <p>PHP Version: <?php echo phpversion(); ?></p>
</body>
</html>
EOF
    chown apache:apache /var/www/html/index.php
fi

echo "==> LAMP construction completed successfully!"
