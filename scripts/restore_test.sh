#!/bin/bash
# =============================================================================
# your-pi-name — Nextcloud Restore Test Script
# Tests restoring Nextcloud from backup to a temporary environment
# Test runs on /mnt/ssd1/restore_test — completely isolated from live setup
# Access test instance at: https://192.168.x.x:5444 or https://100.x.x.x:5444
# Manual run: asks before cleanup
# Cron run: auto cleanup after 30 minutes
# =============================================================================
set -uo pipefail

# --- Config ------------------------------------------------------------------
BACKUP_SOURCE="/mnt/ssd1/backups/latest"
TEST_ROOT="/mnt/ssd1/restore_test"
TEST_NEXTCLOUD_CONFIG="$TEST_ROOT/nextcloud_config"
TEST_DB_CONFIG="$TEST_ROOT/nextcloud_db"
TEST_DATA="$TEST_ROOT/nextcloud_data"

TEST_NEXTCLOUD_CONTAINER="nextcloud_test"
TEST_DB_CONTAINER="nextcloud_db_test"
TEST_NETWORK="nextcloud_test_network"
TEST_PORT="5444"

DB_NAME="nextcloud_db"
DB_USER="nextcloud"
DB_PASSWORD="your_db_password"

LOG_FILE="/mnt/ssd1/backups/logs/restore_cron.log"
ALERT_EMAIL="your@email.com"

# Detect if running from cron (no terminal attached)
if [ -t 0 ]; then
    CRON_RUN=false
else
    CRON_RUN=true
fi

# --- Functions ---------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    echo "Restore test FAILED on $(hostname) at $(date). Error: $1. Check log: $LOG_FILE" | mail -s "⚠️ your-pi-name Restore Test FAILED" "$ALERT_EMAIL"
    log "Run cleanup: sudo bash /home/pi/nextcloud_restore_test.sh --cleanup"
    exit 1
}

cleanup() {
    log "=== TEARING DOWN TEST ENVIRONMENT ==="
    docker stop "$TEST_NEXTCLOUD_CONTAINER" 2>/dev/null || true
    docker stop "$TEST_DB_CONTAINER" 2>/dev/null || true
    docker rm "$TEST_NEXTCLOUD_CONTAINER" 2>/dev/null || true
    docker rm "$TEST_DB_CONTAINER" 2>/dev/null || true
    docker network rm "$TEST_NETWORK" 2>/dev/null || true
    sudo ufw delete allow in on eth0 from 192.168.x.0/24 to any port 5444 2>/dev/null || true
    sudo ufw delete allow in on tailscale0 to any port 5444 2>/dev/null || true
    log "Containers and network removed. Firewall rules removed."

    if [ "$CRON_RUN" = true ]; then
        log "Cron run — auto deleting test data..."
        sudo rm -rf "$TEST_ROOT"
        log "Test data deleted."
    else
        read -p "Delete test data from $TEST_ROOT? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            sudo rm -rf "$TEST_ROOT"
            log "Test data deleted."
        else
            log "Test data kept at $TEST_ROOT"
        fi
    fi
}

# Handle cleanup flag
if [[ "${1:-}" == "--cleanup" ]]; then
    cleanup
    exit 0
fi

# --- Pre-flight --------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
log "=========================================="
log "Nextcloud Restore Test Started"
log "Cron run: $CRON_RUN"
log "=========================================="

[[ -d "$BACKUP_SOURCE/nextcloud/db" ]] || error_exit "Backup not found at $BACKUP_SOURCE"
[[ -f "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" ]] || error_exit "Database dump not found"
[[ -d "$BACKUP_SOURCE/nextcloud/data" ]] || error_exit "Nextcloud data backup not found"
[[ -d "$BACKUP_SOURCE/system/portainer/Files/AppData/Config/Nextcloud/Config" ]] || error_exit "Nextcloud config backup not found"

mountpoint -q /mnt/ssd1 || error_exit "/mnt/ssd1 is not mounted"

available=$(df -BG /mnt/ssd1 | awk 'NR==2 {print $4}' | tr -d 'G')
log "Available space on /mnt/ssd1: ${available}GB"
[[ "$available" -gt 150 ]] || error_exit "Not enough space on /mnt/ssd1 (need 150G, have ${available}G)"

mkdir -p "$TEST_NEXTCLOUD_CONFIG"
mkdir -p "$TEST_DB_CONFIG"
mkdir -p "$TEST_DATA"

# --- Step 1: Create test network ---------------------------------------------
log "--- Step 1: Creating isolated test network ---"
docker network create "$TEST_NETWORK" || error_exit "Failed to create test network"
log "Test network created: $TEST_NETWORK"

# --- Step 2: Start test MariaDB ----------------------------------------------
log "--- Step 2: Starting test MariaDB container ---"
docker run -d \
    --name "$TEST_DB_CONTAINER" \
    --network "$TEST_NETWORK" \
    -v "$TEST_DB_CONFIG:/config:rw" \
    -e PUID=1000 \
    -e PGID=100 \
    -e MYSQL_ROOT_PASSWORD="$DB_PASSWORD" \
    -e MYSQL_DATABASE="$DB_NAME" \
    -e MYSQL_USER="$DB_USER" \
    -e MYSQL_PASSWORD="$DB_PASSWORD" \
    --restart no \
    linuxserver/mariadb || error_exit "Failed to start test MariaDB"

log "Waiting for MariaDB to initialise (60 seconds)..."
sleep 60

# --- Step 3: Restore database ------------------------------------------------
log "--- Step 3: Restoring database from backup ---"
log "Importing $(du -sh "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" | cut -f1) SQL dump..."

docker exec -i "$TEST_DB_CONTAINER" \
    mariadb -u root "$DB_NAME" \
    < "$BACKUP_SOURCE/nextcloud/db/nextcloud.sql" \
    || error_exit "Database restore failed"

log "Database restored successfully"

# --- Step 4: Prepare Nextcloud config ----------------------------------------
log "--- Step 4: Preparing Nextcloud config ---"

sudo cp -r "$BACKUP_SOURCE/system/portainer/Files/AppData/Config/Nextcloud/Config/." \
    "$TEST_NEXTCLOUD_CONFIG/"

CONFIG_FILE="$TEST_NEXTCLOUD_CONFIG/www/nextcloud/config/config.php"

NC_VERSION=$(docker exec nextcloud php /app/www/public/occ config:system:get version 2>/dev/null)
log "Detected Nextcloud version: $NC_VERSION"

sudo tee "$CONFIG_FILE" > /dev/null << 'PHPEOF'
<?php
$CONFIG = array (
  'datadirectory' => '/data',
  'instanceid' => 'ocmeag388jol',
  'passwordsalt' => '9WjBM9JcKLn7JZ1PgvI86Va384X6ls',
  'secret' => 'rS5dxNjrto6XSV4OSy463gJqzg1AyXHzFB0yFxKpvv5/juwx',
  'trusted_domains' =>
  array (
    0 => '192.168.x.x:5444',
    1 => '100.x.x.x:5444',
  ),
  'dbtype' => 'mysql',
  'version' => 'NC_VERSION_PLACEHOLDER',
  'overwrite.cli.url' => 'https://192.168.x.x:5444',
  'dbname' => 'nextcloud_db',
  'dbhost' => 'nextcloud_db_test:3306',
  'dbport' => '',
  'dbtableprefix' => 'oc_',
  'mysql.utf8mb4' => true,
  'dbuser' => 'nextcloud',
  'dbpassword' => 'your_db_password',
  'installed' => true,
  'maintenance' => false,
  'overwriteprotocol' => 'https',
  'htaccess.IgnoreFrontController' => true,
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'filelocking.enabled' => false,
  'loglevel' => '1',
);
PHPEOF

sudo sed -i "s/NC_VERSION_PLACEHOLDER/$NC_VERSION/" "$CONFIG_FILE"
sudo chown -R 1000:100 "$TEST_NEXTCLOUD_CONFIG"
sudo chmod -R 755 "$TEST_NEXTCLOUD_CONFIG"

log "Config patched for test environment"

# --- Step 5: Start test Nextcloud --------------------------------------------
log "--- Step 5: Starting test Nextcloud container ---"
docker run -d \
    --name "$TEST_NEXTCLOUD_CONTAINER" \
    --network "$TEST_NETWORK" \
    -v "$TEST_NEXTCLOUD_CONFIG:/config:rw" \
    -v "$TEST_DATA:/data:rw" \
    -e PUID=1000 \
    -e PGID=100 \
    -e TZ=Europe/London \
    -p "$TEST_PORT:443" \
    --restart no \
    linuxserver/nextcloud || error_exit "Failed to start test Nextcloud"

log "Waiting for Nextcloud to initialise (90 seconds)..."
sleep 90

# --- Step 6: Restore Nextcloud data ------------------------------------------
log "--- Step 6: Restoring Nextcloud data (this will take a while)..."
rsync -aAX --delete \
    "$BACKUP_SOURCE/nextcloud/data/" "$TEST_DATA/" \
    || error_exit "Failed to restore Nextcloud data"

chown -R 1000:100 "$TEST_DATA"
log "Data restored: $(du -sh "$TEST_DATA" | cut -f1)"

# --- Step 7: Fix permissions -------------------------------------------------
log "--- Step 7: Fixing permissions ---"
docker exec "$TEST_NEXTCLOUD_CONTAINER" \
    chown -R abc:abc /data 2>/dev/null || true
log "Permissions fixed"

# --- Step 8: Open firewall for test ------------------------------------------
log "--- Step 8: Opening firewall for test port ---"
sudo ufw allow in on eth0 from 192.168.x.0/24 to any port 5444 2>/dev/null || true
sudo ufw allow in on tailscale0 to any port 5444 2>/dev/null || true
log "Firewall opened for port 5444"

# --- Step 9: Verify ----------------------------------------------------------
log "--- Step 9: Verifying restore ---"
VERIFIED=false
for i in $(seq 1 12); do
    log "Verification attempt $i/12..."
    RESULT=$(docker exec "$TEST_NEXTCLOUD_CONTAINER" \
        curl -sk https://localhost/status.php 2>/dev/null || echo "failed")
    if echo "$RESULT" | grep -q '"installed":true'; then
        log "Nextcloud restore verified successfully"
        VERIFIED=true
        break
    fi
    sleep 10
done

if [ "$VERIFIED" = false ]; then
    log "WARNING: Nextcloud verification failed — check manually"
    log "Status response: $RESULT"
    echo "Restore verification FAILED on $(hostname) at $(date). Check log: $LOG_FILE" | \
        mail -s "⚠️ your-pi-name Restore Verification FAILED" "$ALERT_EMAIL"
fi

# --- Summary -----------------------------------------------------------------
log "=========================================="
log "Restore test complete!"
log "=========================================="

if [ "$CRON_RUN" = true ]; then
    log "Cron run — waiting 30 minutes before auto cleanup..."
    sleep 1800
    log "Auto cleanup starting..."
    cleanup
else
    log ""
    log "Access your test Nextcloud at:"
    log "  https://192.168.x.x:5444 (local)"
    log "  https://100.x.x.x:5444 (Tailscale)"
    log ""
    log "Log in with your normal Nextcloud credentials."
    log "Verify:"
    log "  - You can log in successfully"
    log "  - Your files are visible"
    log "  - File count looks correct"
    log ""
    log "When done, run cleanup:"
    log "  sudo bash /home/pi/nextcloud_restore_test.sh --cleanup"
    log "=========================================="
fi
