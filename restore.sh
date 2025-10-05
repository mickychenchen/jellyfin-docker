#!/bin/bash

set -euo pipefail

# ==================================
#    可配置變數 (Configuration)
# ==================================
# rclone 遠端設定
RCLONE_REMOTE="onedrive"
RCLONE_REMOTE_PATH="backups"

# 還原檔案路徑
RCLONE_MOUNT_POINT="/mnt/data"
BACKUP_DIR="$RCLONE_MOUNT_POINT/backups"

# 服務還原路徑與 docker-compose.yml 位置
RESTORE_ROOT="$RCLONE_MOUNT_POINT"
DOCKER_COMPOSE_DIR="$RESTORE_ROOT/2lemon"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/docker-compose.yml"

# 解壓縮時剝除的目錄層數
STRIP_COUNT=2

# ==================================
#       腳本開始 (Script Start)
# ==================================

echo "==== 1. 確認並安裝 Docker 環境 ===="

if ! command -v docker &>/dev/null; then
  echo "Docker 未安裝，開始安裝..."

  # 使用 Docker 官方推薦的安裝方式，確保版本最新且支援多種架構
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  sudo systemctl enable --now docker
  echo "Docker 安裝完成"
else
  echo "Docker 已安裝，版本：$(docker --version)"
fi

if ! systemctl is-active --quiet docker; then
  echo "Docker 服務未運行，嘗試啟動..."
  sudo systemctl start docker
  sleep 5
  if ! systemctl is-active --quiet docker; then
    echo "Docker 服務無法啟動，請手動檢查錯誤。"
    exit 1
  fi
fi

# 確認 Docker Compose v2 存在
if ! docker compose version &>/dev/null; then
  echo "Docker Compose v2 安裝失敗，請檢查 Docker 安裝過程。"
  exit 1
else
  echo "Docker Compose 已安裝，版本：$(docker compose version | head -n 1)"
fi



echo "==== 2. 確認 rclone 映像檔 ===="

if ! docker image inspect rclone/rclone:latest &>/dev/null; then
  echo "rclone 映像檔未找到，開始拉取..."
  docker pull rclone/rclone:latest
else
  echo "rclone 映像檔已存在"
fi



echo "==== 3. 檢查 rclone 設定 ===="
RCLONE_CONF_DIR="$HOME/.config/rclone"
RCLONE_CONF_FILE="$RCLONE_CONF_DIR/rclone.conf"

sudo mkdir -p "$RCLONE_CONF_DIR"

if [ ! -f "$RCLONE_CONF_FILE" ]; then
  echo "找不到 rclone 設定檔，將啟動互動式 rclone config 容器幫助你設定。"
  docker run --rm -it -v "$RCLONE_CONF_DIR:/config/rclone" rclone/rclone:latest config
  if [ ! -f "$RCLONE_CONF_FILE" ]; then
    echo "仍找不到 rclone.conf，請手動建立後再執行本腳本"
    exit 1
  fi
else
  echo "已找到 rclone 設定"
fi



echo "==== 4. 同步備份檔案 ===="
mkdir -p "$BACKUP_DIR"

echo "開始從 $RCLONE_REMOTE:$RCLONE_REMOTE_PATH 同步到本地 $BACKUP_DIR..."

if ! docker run --rm -v "$RCLONE_CONF_DIR:/config/rclone" -v "$BACKUP_DIR:/backups" rclone/rclone:latest sync "$RCLONE_REMOTE:$RCLONE_REMOTE_PATH" /backups; then
  echo "rclone 同步失敗，請檢查 rclone 設定和網路連線。"
  exit 1
fi
echo "同步完成！"



echo "==== 5. 還原最新備份 ===-"
LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)

if [[ -z "$LATEST_BACKUP" ]]; then
  echo "找不到備份檔，請確認遠端目錄有備份檔。"
  exit 1
fi

echo "找到最新備份檔: $LATEST_BACKUP"
read -rp "確認要還原這個備份嗎？(y/n) " yn
if [[ ! "$yn" =~ ^[Yy]$ ]]; then
  echo "取消還原"
  exit 0
fi

echo "解壓縮到 $RESTORE_ROOT 中，剝除前 $STRIP_COUNT 層目錄..."
mkdir -p "$RESTORE_ROOT"
tar -xzf "$LATEST_BACKUP" --strip-components="$STRIP_COUNT" -C "$RESTORE_ROOT"

echo "備份已成功還原！"



echo "==== 6. 啟動 Docker Compose 服務 ===="
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
  echo "啟動 docker compose 服務..."

  # 停止並移除舊服務，確保環境乾淨
  docker compose -f "$DOCKER_COMPOSE_FILE" down --remove-orphans || true

  docker compose -f "$DOCKER_COMPOSE_FILE" up -d
  echo "服務已啟動完成！"
else
  echo "找不到 $DOCKER_COMPOSE_FILE，請手動啟動服務。"
fi

echo "==== 7. 恢復 cron 任務 ===="

crontab -r 2>/dev/null || true   # 先清空舊的

cat <<EOF | crontab -
0 3 * * * /bin/bash /mnt/data/2lemon/auto_backup.sh
0 */12 * * * /mnt/data/2lemon/renew_cert.sh >> /mnt/data/2lemon/renew_cert.log 2>&1
0 0 * * 0 truncate -s 0 /mnt/data/2lemon/renew_cert.log
EOF

echo "cron 任務已恢復"

