#!/bin/bash
# =============================================================================
# your-pi-name — System Monitor & Health Check Functions
# Sourced by backup_ssd1.sh
# Can also be run standalone for manual health checks
# =============================================================================

# --- Logging -----------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Mount check -------------------------------------------------------------
check_mount() {
    if ! mountpoint -q /mnt/ssd1; then
        log "ERROR: /mnt/ssd1 is not mounted. Aborting."
        echo "Drive failure detected on $(hostname) at $(date)

Device: /dev/sda (3.5TB HDD - backup drive)
Status: Not mounted - drive may have failed or disconnected

Check /dev/sda immediately." | mail -s "⚠️ your-pi-name Drive Failure: /dev/sda" "$ALERT_EMAIL"
        exit 1
    fi
    if ! mountpoint -q /mnt/storage; then
        log "ERROR: /mnt/storage is not mounted. Aborting."
        echo "Drive failure detected on $(hostname) at $(date)

Device: /dev/nvme1n1 (931G NVMe - Nextcloud data drive)
Status: Not mounted - drive may have failed or disconnected

Check /dev/nvme1n1 immediately." | mail -s "⚠️ your-pi-name Drive Failure: /dev/nvme1n1" "$ALERT_EMAIL"
        exit 1
    fi
}

# --- Disk space check --------------------------------------------------------
check_space() {
    local available
    available=$(df -BG /mnt/ssd1 | awk 'NR==2 {print $4}' | tr -d 'G')
    log "Available space on /mnt/ssd1: ${available}GB"
    if [[ "$available" -lt 100 ]]; then
        log "WARNING: Less than 100GB free on /mnt/ssd1 (${available}GB available)"
        echo "Low disk space warning on $(hostname) at $(date)

Available space on /mnt/ssd1: ${available}GB
Less than 100GB remaining." | mail -s "⚠️ your-pi-name Low Disk Space" "$ALERT_EMAIL"
    fi
}

# --- Memory/swap check -------------------------------------------------------
check_memory() {
    local mem_total mem_available mem_used_pct swap_total swap_used swap_used_pct
    mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    mem_available=$(free -m | awk '/^Mem:/ {print $7}')
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
    swap_total=$(free -m | awk '/^Swap:/ {print $2}')
    swap_used=$(free -m | awk '/^Swap:/ {print $3}')
    if [[ "$swap_total" -gt 0 ]]; then
        swap_used_pct=$(( swap_used * 100 / swap_total ))
    else
        swap_used_pct=0
    fi
    log "Memory usage: ${mem_used_pct}% | Swap usage: ${swap_used_pct}% (${swap_used}MB/${swap_total}MB)"
    if [[ "$mem_used_pct" -gt 90 ]]; then
        log "WARNING: Memory usage is ${mem_used_pct}%"
        echo "High memory usage warning on $(hostname) at $(date)
Memory usage: ${mem_used_pct}%
Available: ${mem_available}MB of ${mem_total}MB
Swap used: ${swap_used}MB of ${swap_total}MB
Nextcloud may be at risk." | mail -s "⚠️ your-pi-name High Memory Usage" "$ALERT_EMAIL"
    fi
    if [[ "$swap_used_pct" -gt 80 ]]; then
        log "WARNING: Swap usage is ${swap_used_pct}%"
        echo "High swap usage warning on $(hostname) at $(date)
Swap usage: ${swap_used_pct}% (${swap_used}MB of ${swap_total}MB)
Memory usage: ${mem_used_pct}%
System may become unstable." | mail -s "⚠️ your-pi-name High Swap Usage" "$ALERT_EMAIL"
    fi
}

# --- Docker container check --------------------------------------------------
check_docker() {
    local failed=0
    local report=""
    for container in nextcloud nextcloud_db redis portainer; do
        status=$(docker inspect --format="{{.State.Status}}" "$container" 2>/dev/null || echo "not found")
        if [[ "$status" != "running" ]]; then
            log "WARNING: Container $container is $status"
            report+="- $container: $status\n"
            ((failed++))
        else
            log "Container $container: running ✓"
        fi
    done
    if [[ "$failed" -gt 0 ]]; then
        echo "Docker container health check failed on $(hostname) at $(date)

$failed container(s) not running:

$report
Check your containers immediately." | mail -s "⚠️ your-pi-name Docker Container Down" "$ALERT_EMAIL"
    fi
}

# --- Database integrity check ------------------------------------------------
check_db_integrity() {
    log "--- Database Integrity Check ---"
    local result
    result=$(docker exec "$NEXTCLOUD_DB_CONTAINER" \
        mysqlcheck -u root --password="$(docker exec "$NEXTCLOUD_DB_CONTAINER" printenv MYSQL_ROOT_PASSWORD)" \
        --all-databases --silent 2>/dev/null)
    if [[ -z "$result" ]]; then
        log "DB INTEGRITY OK: All tables passed ✓"
    else
        log "DB INTEGRITY WARNING: Issues found:"
        log "$result"
        echo "Database integrity check failed on $(hostname) at $(date)

Issues found:
$result

Run mysqlcheck manually to investigate." | mail -s "⚠️ your-pi-name Database Integrity Failed" "$ALERT_EMAIL"
    fi
}


# --- Nextcloud failed login check --------------------------------------------
check_nextcloud_logins() {
    local log_file="/mnt/storage/nextcloud_data/nextcloud.log"
    local threshold=10
    local failed_count

    if [[ ! -f "$log_file" ]]; then
        log "WARNING: Nextcloud log not found at $log_file"
        return
    fi

    failed_count=$(grep "Invalid credentials" "$log_file" |         awk -v date="$(date -d '24 hours ago' '+%Y-%m-%dT%H')" '$0 > date' |         wc -l)

    log "Nextcloud failed logins (last 24h): ${failed_count}"

    if [[ "$failed_count" -gt "$threshold" ]]; then
        log "WARNING: High number of failed Nextcloud logins: ${failed_count}"
        echo "High number of failed Nextcloud login attempts on $(hostname) at $(date)

Failed login attempts in last 24 hours: ${failed_count}
Threshold: ${threshold}

Check your Nextcloud logs for details:
/mnt/storage/nextcloud_data/nextcloud.log" | mail -s "⚠️ your-pi-name Nextcloud Brute Force Detected" "$ALERT_EMAIL"
    fi
}
# --- Backup health check -----------------------------------------------------
health_check() {
    log "--- Health Check ---"
    local issues=0
    local report=""

    local db_size
    db_size=$(stat -c%s "$DATED_BACKUP/nextcloud/db/nextcloud.sql" 2>/dev/null || echo 0)
    if [[ "$db_size" -lt "$MIN_DB_SIZE" ]]; then
        log "HEALTH CHECK FAILED: SQL dump too small (${db_size} bytes, expected > ${MIN_DB_SIZE})"
        report+="- SQL dump too small: ${db_size} bytes\n"
        ((issues++))
    else
        log "HEALTH CHECK OK: SQL dump size ${db_size} bytes"
    fi

    local sql_header
    sql_header=$(head -c 50 "$DATED_BACKUP/nextcloud/db/nextcloud.sql" 2>/dev/null || echo "")
    if ! echo "$sql_header" | grep -qE "MariaDB dump|mysqldump|enable the sandbox"; then
        log "HEALTH CHECK FAILED: SQL dump does not appear to be valid SQL"
        report+="- SQL dump invalid format\n"
        ((issues++))
    else
        log "HEALTH CHECK OK: SQL dump format valid"
    fi

    local file_count
    file_count=$(find "$DATED_BACKUP/nextcloud/data" -type f 2>/dev/null | wc -l)
    if [[ "$file_count" -lt "$MIN_DATA_FILES" ]]; then
        log "HEALTH CHECK FAILED: Too few files in data backup ($file_count, expected > $MIN_DATA_FILES)"
        report+="- Too few files backed up: $file_count\n"
        ((issues++))
    else
        log "HEALTH CHECK OK: $file_count files in data backup"
    fi

    local symlink_target
    symlink_target=$(readlink "$LATEST" 2>/dev/null || echo "")
    if [[ "$symlink_target" != "$DATED_BACKUP" ]]; then
        log "HEALTH CHECK FAILED: Latest symlink does not point to today's backup"
        report+="- Latest symlink incorrect\n"
        ((issues++))
    else
        log "HEALTH CHECK OK: Latest symlink correct"
    fi

    local prev_backup
    prev_backup=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*-*" ! -path "$DATED_BACKUP" | sort | tail -1)
    if [[ -n "$prev_backup" ]]; then
        local prev_size current_size
        prev_size=$(du -sb "$prev_backup/nextcloud/data" 2>/dev/null | cut -f1 || echo 0)
        current_size=$(du -sb "$DATED_BACKUP/nextcloud/data" 2>/dev/null | cut -f1 || echo 0)
        if [[ "$prev_size" -gt 0 ]]; then
            local diff_percent
            diff_percent=$(( (prev_size - current_size) * 100 / prev_size ))
            if [[ "$diff_percent" -gt 20 ]]; then
                log "HEALTH CHECK WARNING: Data backup is ${diff_percent}% smaller than previous backup"
                report+="- Data backup ${diff_percent}% smaller than previous\n"
                ((issues++))
            else
                log "HEALTH CHECK OK: Data size within normal range"
            fi
        fi
    fi

    if [[ "$issues" -gt 0 ]]; then
        log "HEALTH CHECK: $issues issue(s) found"
        echo "Backup health check failed on $(hostname) at $(date)

$issues issue(s) detected in backup $DATED_BACKUP:

$report
Check the log: $LOG_FILE" | mail -s "⚠️ your-pi-name Backup Health Check Failed" "$ALERT_EMAIL"
    else
        log "HEALTH CHECK: All checks passed ✓"
    fi
}
