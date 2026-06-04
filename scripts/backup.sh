#!/bin/bash
# =============================================================================
# your-pi-name — Backup Script
# Destination: /mnt/ssd1/backups
# Schedule: daily via cron
# =============================================================================
set -uo pipefail

# --- Config ------------------------------------------------------------------
BACKUP_ROOT="/mnt/ssd1/backups"
STAGING="/tmp/backup_staging_$$"
LATEST="$BACKUP_ROOT/latest"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
DATED_BACKUP="$BACKUP_ROOT/$DATE"
LOG_FILE="$BACKUP_ROOT/logs/backup_all.log"

NEXTCLOUD_CONTAINER="nextcloud"
NEXTCLOUD_DB_CONTAINER="nextcloud_db"
NEXTCLOUD_DATA="/mnt/storage/nextcloud_data"
DB_NAME="nextcloud_db"

KEEP_DAYS=30
ALERT_EMAIL="your@email.com"
MIN_DB_SIZE=1048576
MIN_DATA_FILES=100

# --- Load monitor functions --------------------------------------------------
source /home/pi/your-pi-name_monitor.sh

# --- Functions ---------------------------------------------------------------
cleanup() {
    log "Cleaning up staging area..."
    rm -rf "$STAGING"
}

error_exit() {
    log "ERROR: $1"
    log "Attempting to disable Nextcloud maintenance mode..."
    docker exec "$NEXTCLOUD_CONTAINER" php /app/www/public/occ maintenance:mode --off 2>/dev/null || true
    echo "Backup FAILED on $(hostname) at $(date)

Error: $1

Check the log: $LOG_FILE" | mail -s "⚠️ your-pi-name Backup FAILED" "$ALERT_EMAIL"
    cleanup
    exit 1
}

# --- Pre-flight --------------------------------------------------------------
mkdir -p "$BACKUP_ROOT/logs"
log "=========================================="
log "Backup started: $DATE"
log "=========================================="

check_mount
check_space
check_memory
check_docker
check_nextcloud_logins
# Run DB integrity check weekly on Sundays
if [[ $(date +%u) -eq 7 ]]; then
    check_db_integrity
fi
mkdir -p "$STAGING"
mkdir -p "$DATED_BACKUP"
trap cleanup EXIT

# --- Step 1: Nextcloud DB dump -----------------------------------------------
log "--- Step 1: Nextcloud database backup ---"

log "Checking MySQL root password inside container..."
docker exec "$NEXTCLOUD_DB_CONTAINER" printenv MYSQL_ROOT_PASSWORD >/dev/null 2>&1 \
    || error_exit "MYSQL_ROOT_PASSWORD not found inside container"

log "Enabling Nextcloud maintenance mode..."
docker exec "$NEXTCLOUD_CONTAINER" \
    php /app/www/public/occ maintenance:mode --on 2>>"$LOG_FILE" \
    || log "WARNING: Could not enable maintenance mode, continuing anyway"

log "Dumping MariaDB database..."
mkdir -p "$STAGING/nextcloud/db"
docker exec "$NEXTCLOUD_DB_CONTAINER" \
    mariadb-dump -u root --single-transaction --quick "$DB_NAME" \
    > "$STAGING/nextcloud/db/nextcloud.sql" 2>>"$LOG_FILE" \
    || error_exit "Database dump failed"

log "Database dump complete: $(du -sh "$STAGING/nextcloud/db/nextcloud.sql" | cut -f1)"

log "Disabling Nextcloud maintenance mode..."
docker exec "$NEXTCLOUD_CONTAINER" \
    php /app/www/public/occ maintenance:mode --off 2>>"$LOG_FILE" || true

# --- Step 2: Nextcloud user data (direct to HDD — no staging) ---------------
log "--- Step 2: Nextcloud user data (direct rsync to HDD) ---"
mkdir -p "$DATED_BACKUP/nextcloud/data"

LINK_DEST_DATA=""
if [[ -d "$LATEST/nextcloud/data" ]]; then
    LINK_DEST_DATA="--link-dest=$LATEST/nextcloud/data"
fi

rsync -aAX --delete --ignore-errors $LINK_DEST_DATA \
    "$NEXTCLOUD_DATA/" "$DATED_BACKUP/nextcloud/data/" >> "$LOG_FILE" 2>&1 \
    || { [[ $? -eq 24 ]] && log "WARNING: Some files vanished during rsync (normal for live Nextcloud)" || error_exit "Nextcloud data rsync failed"; }

log "Nextcloud data copied: $(du -sh "$DATED_BACKUP/nextcloud/data" | cut -f1)"

# --- Step 3: System files ----------------------------------------------------
log "--- Step 3: System files ---"
mkdir -p "$STAGING/system"

rsync -aAX \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
    --exclude="/swap*" \
    --exclude="/var/cache/*" \
    --exclude="/var/tmp/*" \
    --exclude="/var/log/journal/*" \
    --exclude="/home/*/.cache/*" \
    --exclude="/root/.cache/*" \
    --exclude="/var/lib/docker/overlay2/*" \
    --exclude="/var/lib/docker/image/*" \
    --exclude="/var/lib/docker/containers/*" \
    --exclude="/var/lib/docker/network/*" \
    / "$STAGING/system/" >> "$LOG_FILE" 2>&1 \
    || error_exit "System files rsync failed"

log "System files copied: $(du -sh "$STAGING/system" | cut -f1)"

# --- Step 4: Small container exports -----------------------------------------
log "--- Step 4: Small container exports (redis, portainer) ---"
mkdir -p "$STAGING/containers"

for container in redis portainer; do
    if docker inspect "$container" &>/dev/null; then
        log "Exporting container: $container"
        docker export "$container" > "$STAGING/containers/${container}.tar" 2>>"$LOG_FILE" \
            || log "WARNING: Failed to export $container, continuing..."
        log "Container $container size: $(du -sh "$STAGING/containers/${container}.tar" | cut -f1)"
    else
        log "WARNING: Container $container not found, skipping"
    fi
done

# --- Step 5: System info snapshot --------------------------------------------
log "--- Step 5: System info snapshot ---"
{
    echo "=== BACKUP INFO ==="
    echo "Backup Date: $DATE"
    echo "Backup Location: $DATED_BACKUP"
    echo ""
    echo "=== SYSTEM INFO ==="
    uname -a
    echo ""
    echo "=== DISK USAGE ==="
    df -h
    echo ""
    echo "=== DOCKER CONTAINERS ==="
    docker ps -a 2>/dev/null || echo "Docker not available"
    echo ""
    echo "=== DOCKER IMAGES ==="
    docker images 2>/dev/null || echo "Docker not available"
    echo ""
    echo "=== INSTALLED PACKAGES ==="
    dpkg -l
    echo ""
    echo "=== SYSTEMD SERVICES ==="
    systemctl list-units --type=service --no-pager
} > "$STAGING/system_info.txt" 2>>"$LOG_FILE"

# --- Step 6: Snapshot remaining staging files with deduplication -------------
log "--- Step 6: Syncing remaining files to snapshot ---"

LINK_DEST_ARG=""
if [[ -d "$LATEST/nextcloud/db" ]]; then
    LINK_DEST_ARG="--link-dest=$LATEST"
fi

rsync -a $LINK_DEST_ARG \
    "$STAGING/" "$DATED_BACKUP/" >> "$LOG_FILE" 2>&1 \
    || error_exit "Final rsync snapshot failed"

log "Snapshot complete: $(du -sh "$DATED_BACKUP" | cut -f1)"

# --- Step 7: Update latest symlink -------------------------------------------
log "--- Step 7: Updating latest symlink ---"
ln -sfn "$DATED_BACKUP" "$LATEST"

# --- Step 8: Rotate old backups ----------------------------------------------
log "--- Step 8: Rotating backups older than ${KEEP_DAYS} days ---"
for dir in $(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*-*" | sort); do
    dir_date=$(basename "$dir" | cut -c1-10)
    dir_epoch=$(date -d "$dir_date" +%s 2>/dev/null)
    cutoff_epoch=$(date -d "-${KEEP_DAYS} days" +%s)
    if [ "$dir_epoch" -lt "$cutoff_epoch" ]; then
        log "Deleting old backup: $(basename $dir)"
        rm -rf "$dir"
    fi
done

# --- Step 9: Health check ----------------------------------------------------
log "--- Step 9: Backup health check ---"
health_check

# --- Summary -----------------------------------------------------------------
TOTAL_SIZE=$(du -sh "$DATED_BACKUP" | cut -f1)
BACKUP_COUNT=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*-*" | wc -l)

log "=========================================="
log "Backup completed successfully"
log "  Nextcloud DB:   $(du -sh "$DATED_BACKUP/nextcloud/db" 2>/dev/null | cut -f1)"
log "  Nextcloud data: $(du -sh "$DATED_BACKUP/nextcloud/data" 2>/dev/null | cut -f1)"
log "  System files:   $(du -sh "$DATED_BACKUP/system" 2>/dev/null | cut -f1)"
log "  Containers:     $(du -sh "$DATED_BACKUP/containers" 2>/dev/null | cut -f1)"
log "  Total size:     $TOTAL_SIZE"
log "  Backups kept:   $BACKUP_COUNT"
log "  Location:       $DATED_BACKUP"
log "  CPU load:       $(uptime | awk -F'load average:' '{print $2}')"
log "  Memory:         $(free -h | awk '/^Mem:/ {print $3 " used of " $2}')"
log "  HDD I/O:        $(iostat -d /dev/sda 1 1 2>/dev/null | awk '/sda/ {print "read=" $3 "kB/s write=" $4 "kB/s"}' || echo "unavailable")"
log "=========================================="
