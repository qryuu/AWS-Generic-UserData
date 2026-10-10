#!/bin/bash
set -euo pipefail

# ==============================================================================
# AWS-Generic-UserData: Docker & Docker Compose Host Initial Construction
# Supported OS: Amazon Linux 2023 (recommended), Amazon Linux 2
# ==============================================================================

# ------------------------------------------------------------------------------
# 設定項目 (Settings) - スクリプト冒頭の編集、またはコマンド引数で指定可能
# ------------------------------------------------------------------------------
docker_user="${1:-ec2-user}"   # 第1引数: docker グループに追加するユーザー名 (デフォルト: ec2-user)

# ------------------------------------------------------------------------------
# 内部処理 (Internal Logic)
# ------------------------------------------------------------------------------
echo "==> Starting Docker & Docker Compose host construction (Target user: ${docker_user})..."

# 1. OS Detection & Package Installation
if grep -q 'Amazon Linux release 2023' /etc/system-release 2>/dev/null || ( [ -f /etc/os-release ] && grep -q 'VERSION_ID="2023"' /etc/os-release ); then
    echo "==> Detected Amazon Linux 2023. Installing Docker with dnf..."
    dnf update -y
    dnf install -y docker git tar gzip curl
else
    echo "==> Detected Amazon Linux 2 (or legacy). Installing Docker with yum..."
    yum update -y
    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y docker || true
    fi
    yum install -y docker git tar gzip curl
fi

# 2. Docker Service Startup & User Permissions
echo "==> Starting and enabling Docker daemon..."
systemctl enable --now docker.service

echo "==> Adding ${docker_user} to docker group..."
usermod -aG docker "${docker_user}"

# 3. Install Docker Compose (v2 plugin & standalone binary)
echo "==> Installing Docker Compose v2..."
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  COMPOSE_ARCH="x86_64" ;;
    aarch64) COMPOSE_ARCH="aarch64" ;;
    arm64)   COMPOSE_ARCH="aarch64" ;;
    *)       COMPOSE_ARCH="x86_64" ;;
esac

PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"
mkdir -p "${PLUGIN_DIR}"

COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
echo "==> Downloading Docker Compose from: ${COMPOSE_URL}"
curl -sSL -o "${PLUGIN_DIR}/docker-compose" "${COMPOSE_URL}"
chmod +x "${PLUGIN_DIR}/docker-compose"

# Symlink for standalone 'docker-compose' command support
ln -sf "${PLUGIN_DIR}/docker-compose" /usr/local/bin/docker-compose

# 4. Verification
docker --version
docker compose version

echo "==> Docker & Docker Compose host construction completed successfully!"
echo "==> Log in as '${docker_user}' to run 'docker' or 'docker compose' commands without sudo."
