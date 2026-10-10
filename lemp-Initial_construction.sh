#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: LEMP Initial Construction Script (Nginx + PHP-FPM + MariaDB)
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数で指定可能
# ------------------------------------------------------------------------------
dbname="${1:-lempdb}"          # 第1引数: 作成する DB 名 (デフォルト: lempdb)
dbuser="${2:-lempuser}"        # 第2引数: 作成する DB ユーザー名 (デフォルト: lempuser)
dbpassword="${3:-lemppass}"    # 第3引数: 作成する DB ユーザーパスワード (デフォルト: lemppass)

# アプリケーション追加設定:
web_root="${WEB_ROOT:-/usr/share/nginx/html}"

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
echo "==> Starting LEMP stack initial construction..."

# 1. OS Detection & Package Installation
if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing LEMP with dnf..."
    dnf update -y
    dnf install -y \
        nginx \
        mariadb105-server \
        mariadb105 \
        php \
        php-fpm \
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
    echo "==> Detected Amazon Linux 2 (or legacy). Installing LEMP with yum..."
    yum update -y
    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y nginx1 lamp-mariadb10.2-php7.2 || true
    fi
    yum install -y \
        nginx \
        mariadb \
        mariadb-server \
        php \
        php-fpm \
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

# 3. Create Initial Database & Application User
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

# 4. Configure Nginx & PHP-FPM
echo "==> Configuring Nginx and PHP-FPM..."
mkdir -p "${web_root}"

cat << EOF > /etc/nginx/conf.d/default.conf
server {
    listen       80;
    listen       [::]:80;
    server_name  _;
    root         ${web_root};
    index        index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass   unix:/run/php-fpm/www.sock;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
        include        fastcgi_params;
    }

    location ~ /\.ht {
        deny  all;
    }
}
EOF

cat << 'EOF' > "${web_root}/index.php"
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>LEMP Server Ready</title>
</head>
<body>
    <h1>LEMP Server (Nginx + PHP-FPM + MariaDB) is running!</h1>
    <p>PHP Version: <?php echo phpversion(); ?></p>
</body>
</html>
EOF
chown -R nginx:nginx "${web_root}" 2>/dev/null || chown -R apache:apache "${web_root}"

# 5. Service Startup
echo "==> Starting PHP-FPM and Nginx services..."
systemctl enable --now php-fpm.service
systemctl enable --now nginx.service

echo "==> LEMP construction completed successfully!"
