#!/bin/bash
set -euo pipefail

echo "==== Jellyfin Stack Restore V1 ===="

# ==================================
# 1️⃣ 互動式輸入專案名稱與 rclone
# ==================================
read -rp "請輸入專案名稱 (例如 media): " PROJECT_NAME
read -rp "請輸入 rclone 遠端名稱 (例如 onedrive): " RCLONE_REMOTE
read -rp "請輸入 rclone 備份目錄路徑 (例如 backups): " RCLONE_REMOTE_PATH

# 路徑設定
RCLONE_MOUNT_POINT="/mnt/data"
BACKUP_DIR="$RCLONE_MOUNT_POINT/backups"
RESTORE_ROOT="$RCLONE_MOUNT_POINT"
DOCKER_COMPOSE_DIR="$RESTORE_ROOT/$PROJECT_NAME"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/docker-compose.yml"

STRIP_COUNT=2

echo "專案名稱: $PROJECT_NAME"
echo "rclone 遠端: $RCLONE_REMOTE:$RCLONE_REMOTE_PATH"
echo "docker-compose 位置: $DOCKER_COMPOSE_FILE"

# ==================================
# 2️⃣ Docker / Docker Compose 安裝檢查
# ==================================
echo "==== 1. 確認 Docker ===="
if ! command -v docker &>/dev/null; then
  echo "Docker 未安裝，開始安裝..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl enable --now docker
fi
echo "Docker 版本：$(docker --version)"

if ! systemctl is-active --quiet docker; then
  echo "Docker 服務未運行，啟動中..."
  sudo systemctl start docker
  sleep 5
fi

echo "==== 2. 確認 Docker Compose ===="
if ! docker compose version &>/dev/null; then
  echo "Docker Compose v2 安裝失敗，請檢查 Docker 安裝"
  exit 1
fi
echo "Docker Compose 版本：$(docker compose version | head -n1)"

# ==================================
# 3️⃣ rclone 映像檢查
# ==================================
echo "==== 3. 確認 rclone 映像檔 ===="
if ! docker image inspect rclone/rclone:latest &>/dev/null; then
  echo "拉取 rclone 映像檔..."
  docker pull rclone/rclone:latest
fi

# ==================================
# 4️⃣ rclone 設定檢查
# ==================================
echo "==== 4. 檢查 rclone 設定 ===="
RCLONE_CONF_DIR="$HOME/.config/rclone"
RCLONE_CONF_FILE="$RCLONE_CONF_DIR/rclone.conf"
mkdir -p "$RCLONE_CONF_DIR"

if [ ! -f "$RCLONE_CONF_FILE" ]; then
  echo "找不到 rclone.conf，啟動互動式 rclone config..."
  docker run --rm -it -v "$RCLONE_CONF_DIR:/config/rclone" rclone/rclone:latest config
  if [ ! -f "$RCLONE_CONF_FILE" ]; then
    echo "仍找不到 rclone.conf，請手動建立後再執行腳本"
    exit 1
  fi
fi
echo "rclone 設定檔已存在"

# ==================================
# 5️⃣ 同步備份
# ==================================
echo "==== 5. 同步備份 ===="
mkdir -p "$BACKUP_DIR"
docker run --rm -v "$RCLONE_CONF_DIR:/config/rclone" -v "$BACKUP_DIR:/backups" rclone/rclone:latest sync "$RCLONE_REMOTE:$RCLONE_REMOTE_PATH" /backups
echo "同步完成！"

# ==================================
# 6️⃣ 還原最新備份
# ==================================
echo "==== 6. 還原最新備份 ===="
LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)
if [[ -z "$LATEST_BACKUP" ]]; then
  echo "找不到備份檔"
  exit 1
fi
echo "找到最新備份: $LATEST_BACKUP"
read -rp "確認還原這個備份嗎？(y/n): " yn
[[ "$yn" =~ ^[Yy]$ ]] || exit 0

mkdir -p "$RESTORE_ROOT"
tar -xzf "$LATEST_BACKUP" --strip-components="$STRIP_COUNT" -C "$RESTORE_ROOT"
echo "備份已還原完成！"

# ==================================
# 7️⃣ 啟動 Docker Compose
# ==================================
echo "==== 7. 啟動 Docker Compose 服務 ===="
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
  docker compose -f "$DOCKER_COMPOSE_FILE" down --remove-orphans || true
  docker compose -f "$DOCKER_COMPOSE_FILE" up -d
  echo "服務已啟動完成！"
else
  echo "找不到 docker-compose.yml，請手動啟動服務"
fi

# ==================================
# 8️⃣ 恢復 cron 任務
# ==================================
echo "==== 8. 設置 cron 任務 ===="
crontab -r 2>/dev/null || true
cat <<EOF | crontab -
0 3 * * * /bin/bash $DOCKER_COMPOSE_DIR/auto_backup.sh
0 */12 * * * /bin/bash $DOCKER_COMPOSE_DIR/renew_cert.sh >> $DOCKER_COMPOSE_DIR/renew_cert.log 2>&1
0 0 * * 0 truncate -s 0 $DOCKER_COMPOSE_DIR/renew_cert.log
EOF
echo "cron 任務已恢復"

echo "==== 全部完成，Jellyfin Stack 已還原並啟動 ===="
