#!/bin/bash
# =============================================================================
# your-pi-name — Nextcloud Production Restore Script
# Use this in a real emergency when nvme0n1 (OS drive) has failed
# Prerequisites:
#   - Fresh Debian install on new nvme0n1
#   - Docker installed
#   - /mnt/ssd1 mounted (HDD with backups)
#   - /mnt/storage mounted (nvme1n1 - Nextcloud data drive)
# =============================================================================
set -uo pipefail

# --- Config ------------------------------------------------------------------
BACKUP_SOURCE="/mnt/ssd1/backups/latest"
NEXTCLOUD_CONFIG="/portainer/Files/AppData/Config/Nextcloud/Config"
NEXTCLOUD_DB="/portainer/AppData/Config/Nextcloud/DB"
NEXTCLOUD_DATA="/mnt/storage/nextcloud_data"

NEXTCLOUD_CONTAINER="nextcloud"
NEXTCLOUD_DB_CONTAINER="nextcloud_db"
NEXTCLOUD_NETWORK="nextcloud_default"

DB_NAME="nextcloud_db"
DB_USER="nextcloud"
DB_PASSWORD="your_db_password"

LOG_FILE="/var/log/nextcloud_restore.log"

# --- Functions ---------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    log "Restore failed — check the log at $LOG_FILE"
    exit 1
}

# --- Pre-flight --------------------------------------------------------------
log "=========================================="
log "Nextcloud Production Restore Started"
log "=========================================="

[[ "$EUID" -eq 0 ]] || error_exit "Must be run as root (sudo)"

mountpoint -q /mnt/ssd1 || error_exit "/mnt/ssd1 is not mounted — connect the HDD first"
mountpoint -q /mnt/storage || error_exit "/mnt/storage is not mounted — connect the NVMe first"
[[ -d "$BACKUP_SOURCE/nextcloud/db" ]] || error_exit "Backup not found at $BACKUP_SOURCE"
[[ -f "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" ]] || error_exit "Database dump not found"
[[ -d "$BACKUP_SOURCE/nextcloud/data" ]] || error_exit "Nextcloud data backup not found"
[[ -d "$BACKUP_SOURCE/system/portainer/Files/AppData/Config/Nextcloud/Config" ]] || error_exit "Nextcloud config backup not found"

systemctl is-active --quiet docker || error_exit "Docker is not running — install and start Docker first"

log "All pre-flight checks passed"
log "Backup source: $BACKUP_SOURCE"
log "Backup DB size: $(du -sh "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" | cut -f1)"
log "Backup data size: $(du -sh "$BACKUP_SOURCE/nextcloud/data" | cut -f1)"

echo ""
echo "=========================================="
echo "WARNING: This will restore Nextcloud to"
echo "the state of the latest backup."
echo "=========================================="
read -p "Are you sure you want to proceed? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { log "Restore cancelled by user."; exit 0; }

# --- Step 1: Create directory structure --------------------------------------
log "--- Step 1: Creating directory structure ---"
mkdir -p "$NEXTCLOUD_CONFIG"
mkdir -p "$NEXTCLOUD_DB"
mkdir -p "$NEXTCLOUD_DATA"
log "Directories created"

# --- Step 2: Create Docker network -------------------------------------------
log "--- Step 2: Creating Docker network ---"
docker network create "$NEXTCLOUD_NETWORK" 2>/dev/null || log "Network already exists, continuing..."
log "Network ready: $NEXTCLOUD_NETWORK"

# --- Step 3: Start MariaDB ---------------------------------------------------
log "--- Step 3: Starting MariaDB container ---"
docker run -d \
    --name "$NEXTCLOUD_DB_CONTAINER" \
    --network "$NEXTCLOUD_NETWORK" \
    -v "$NEXTCLOUD_DB:/config:rw" \
    -e PUID=1000 \
    -e PGID=100 \
    -e MYSQL_ROOT_PASSWORD="$DB_PASSWORD" \
    -e MYSQL_DATABASE="$DB_NAME" \
    -e MYSQL_USER="$DB_USER" \
    -e MYSQL_PASSWORD="$DB_PASSWORD" \
    --restart unless-stopped \
    linuxserver/mariadb || error_exit "Failed to start MariaDB"

log "Waiting for MariaDB to initialise (60 seconds)..."
sleep 60

# --- Step 4: Restore database ------------------------------------------------
log "--- Step 4: Restoring database ---"
log "Importing $(du -sh "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" | cut -f1) SQL dump..."

docker exec -i "$NEXTCLOUD_DB_CONTAINER" \
    mariadb -u root "$DB_NAME" \
    < "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" \
    || error_exit "Database restore failed"

log "Database restored successfully"

# --- Step 5: Restore Nextcloud config ----------------------------------------
log "--- Step 5: Restoring Nextcloud config ---"
cp -r "$BACKUP_SOURCE/system/portainer/Files/AppData/Config/Nextcloud/Config/." \
    "$NEXTCLOUD_CONFIG/" \
    || error_exit "Failed to restore Nextcloud config"

log "Config restored successfully"

# --- Step 6: Restore Nextcloud data ------------------------------------------
log "--- Step 6: Restoring Nextcloud data (this will take a while)..."
log "Data size: $(du -sh "$BACKUP_SOURCE/nextcloud/data" | cut -f1)"

rsync -aAX --delete \
    "$BACKUP_SOURCE/nextcloud/data/" "$NEXTCLOUD_DATA/" \
    || error_exit "Failed to restore Nextcloud data"

chown -R 1000:100 "$NEXTCLOUD_DATA"
log "Data restored: $(du -sh "$NEXTCLOUD_DATA" | cut -f1)"

# --- Step 7: Start Nextcloud -------------------------------------------------
log "--- Step 7: Starting Nextcloud container ---"
docker run -d \
    --name "$NEXTCLOUD_CONTAINER" \
    --network "$NEXTCLOUD_NETWORK" \
    -v "$NEXTCLOUD_CONFIG:/config:rw" \
    -v "$NEXTCLOUD_DATA:/data:rw" \
    -e PUID=1000 \
    -e PGID=100 \
    -e TZ=Europe/London \
    -p 5443:443 \
    --restart unless-stopped \
    linuxserver/nextcloud || error_exit "Failed to start Nextcloud"

log "Waiting for Nextcloud to initialise (30 seconds)..."
sleep 30

# --- Step 8: Fix permissions -------------------------------------------------
log "--- Step 8: Fixing permissions ---"
docker exec "$NEXTCLOUD_CONTAINER" \
    chown -R abc:abc /data 2>/dev/null || true

docker exec "$NEXTCLOUD_CONTAINER" \
    bash -c 'test -f /data/.ncdata || echo "# Nextcloud data directory" > /data/.ncdata'

log "Permissions fixed"

# --- Step 9: Restart Nextcloud -----------------------------------------------
log "--- Step 9: Restarting Nextcloud to apply config ---"
docker restart "$NEXTCLOUD_CONTAINER"
sleep 30

# --- Step 10: Start Redis ----------------------------------------------------
log "--- Step 10: Starting Redis container ---"
docker run -d \
    --name redis \
    --network "$NEXTCLOUD_NETWORK" \
    --restart unless-stopped \
    redis:alpine || log "WARNING: Failed to start Redis, Nextcloud will still work without it"

# --- Step 11: Verify ---------------------------------------------------------
RESULT=$(docker exec "$NEXTCLOUD_CONTAINER" \
    curl -sk https://localhost/status.php 2>/dev/null || echo "failed")

if echo "$RESULT" | grep -q '"installed":true'; then
    log "=========================================="
    log "Restore completed successfully!"
    log "=========================================="
    log ""
    log "Nextcloud is running at:"
    log "  https://192.168.x.x:5443"
    log "  https://100.x.x.x:5443 (via Tailscale)"
    log ""
    log "Next steps:"
    log "  1. Log in and verify your files"
    log "  2. Reinstall Portainer via Docker"
    log "  3. Check UFW firewall rules are correct"
    log "  4. Restore cron jobs from backup:"
    log "     $BACKUP_SOURCE/system/var/spool/cron/crontabs/"
    log "=========================================="
else
    log "WARNING: Nextcloud may not be responding correctly"
    log "Check: docker logs $NEXTCLOUD_CONTAINER"
    log "Status response: $RESULT"
fi
