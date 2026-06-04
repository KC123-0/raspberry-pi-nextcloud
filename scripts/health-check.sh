#!/bin/bash
# Daily health check - emails only on problems
# Runs daily via cron (see crontab)

LOG_FILE="/var/log/health-check.log"
ALERT_EMAIL="your@email.com"
FROM_EMAIL="pi@your-pi-name"
HOSTNAME=$(hostname)
DAY_OF_WEEK=$(date +%u)
RUN_ID=$(date +"%Y%m%d_%H%M%S")

# Thresholds
DISK_THRESHOLD=85
TEMP_THRESHOLD=75
AUTH_FAIL_THRESHOLD=50
MEM_AVAILABLE_MIN_MB=500
JOURNAL_ERROR_THRESHOLD=10

# Expected Docker containers
EXPECTED_CONTAINERS="nextcloud nextcloud_db portainer redis"

# Expected drives
EXPECTED_DRIVES="/dev/sda /dev/nvme0n1 /dev/nvme1n1"

ISSUES=()

check() {
    local result="$1"
    local message="$2"
    if [ "$result" = "FAIL" ]; then
        ISSUES+=("$message")
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $result: $message" >> "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"
    {
        echo "From: $FROM_EMAIL"
        echo "To: $ALERT_EMAIL"
        echo "Subject: $subject"
        echo ""
        echo "$body"
    } | msmtp "$ALERT_EMAIL"
}

echo "=== Run $RUN_ID started ===" >> "$LOG_FILE"

# 1. SMART drive health (with missing drive handling)
for drive in $EXPECTED_DRIVES; do
    if [ ! -b "$drive" ]; then
        check "FAIL" "Drive $drive missing"
        continue
    fi
    if sudo smartctl -H "$drive" 2>/dev/null | grep -qi "PASSED"; then
        check "OK" "SMART $drive: PASSED"
    else
        check "FAIL" "SMART $drive: failed or unknown"
    fi
done

# 2. Disk usage above threshold
while read -r line; do
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
        check "FAIL" "Disk usage on $mount: ${usage}% (threshold ${DISK_THRESHOLD}%)"
    else
        check "OK" "Disk usage on $mount: ${usage}%"
    fi
done < <(df -h | grep -E "^/dev" | awk '$5 ~ /%/')

# 3. Failed systemd services
failed=$(systemctl --failed --no-legend | wc -l)
if [ "$failed" -gt 0 ]; then
    failed_list=$(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')
    check "FAIL" "$failed failed systemd service(s): $failed_list"
else
    check "OK" "No failed systemd services"
fi

# 4. Expected Docker containers running
for container in $EXPECTED_CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        check "OK" "Container $container running"
    else
        check "FAIL" "Container $container NOT running"
    fi
done

# 4b. Nextcloud responding
nc_status=$(curl -sk https://192.168.x.x:5443/status.php)
if echo "$nc_status" | grep -q '"installed":true'; then
    check "OK" "Nextcloud responding and installed"
else
    check "FAIL" "Nextcloud not responding or unhealthy"
fi

# 5. CPU temp and throttling
temp=$(vcgencmd measure_temp | grep -oE '[0-9]+\.[0-9]+')
temp_int=${temp%.*}
if [ "$temp_int" -ge "$TEMP_THRESHOLD" ]; then
    check "FAIL" "CPU temp: ${temp}C (threshold ${TEMP_THRESHOLD}C)"
else
    check "OK" "CPU temp: ${temp}C"
fi
throttled=$(vcgencmd get_throttled | grep -oE '0x[0-9a-f]+')
if [ "$throttled" != "0x0" ]; then
    check "FAIL" "Throttling detected: $throttled"
else
    check "OK" "No throttling"
fi

# 6. Backup ran in last 25 hours
backup_log="/mnt/ssd1/backups/logs/backup_all.log"
if [ -f "$backup_log" ]; then
    last_backup=$(grep "Backup completed successfully" "$backup_log" | tail -1 | grep -oE '\[[0-9-]+ [0-9:]+\]' | tr -d '[]')
    if [ -n "$last_backup" ]; then
        last_epoch=$(date -d "$last_backup" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        age_hours=$(( (now_epoch - last_epoch) / 3600 ))
        if [ "$age_hours" -gt 25 ]; then
            check "FAIL" "Last successful backup was ${age_hours}h ago"
        else
            check "OK" "Last backup ${age_hours}h ago"
        fi
    else
        check "FAIL" "No successful backup found in log"
    fi
else
    check "FAIL" "Backup log not found: $backup_log"
fi

# 7. Reboot required
if [ -f /var/run/reboot-required ]; then
    check "FAIL" "Reboot required"
else
    check "OK" "No reboot required"
fi

# 8. Auth failures spiked
auth_fails=$(sudo journalctl _SYSTEMD_UNIT=ssh.service --since "24 hours ago" 2>/dev/null | grep -iE "fail|invalid" | wc -l)
if [ "$auth_fails" -gt "$AUTH_FAIL_THRESHOLD" ]; then
    check "FAIL" "SSH auth failures in 24h: $auth_fails (threshold $AUTH_FAIL_THRESHOLD)"
else
    check "OK" "SSH auth failures in 24h: $auth_fails"
fi

# 9. Low available memory
mem_avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
if [ "$mem_avail_mb" -lt "$MEM_AVAILABLE_MIN_MB" ]; then
    check "FAIL" "Available memory low: ${mem_avail_mb}MB (threshold ${MEM_AVAILABLE_MIN_MB}MB)"
else
    check "OK" "Available memory: ${mem_avail_mb}MB"
fi

# 10. Tailscale state (not just daemon running)
ts_status=$(tailscale status --json 2>/dev/null)
if echo "$ts_status" | grep -q '"BackendState": *"Running"'; then
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
    if [ -n "$ts_ip" ]; then
        check "OK" "Tailscale connected: $ts_ip"
    else
        check "FAIL" "Tailscale running but no IP"
    fi
else
    check "FAIL" "Tailscale disconnected"
fi

# 11. Journal errors in last 24h
journal_errors=$(sudo journalctl -p err..crit --since "24 hours ago" --no-pager 2>/dev/null | wc -l)
if [ "$journal_errors" -gt "$JOURNAL_ERROR_THRESHOLD" ]; then
    check "FAIL" "Journal errors in 24h: $journal_errors (threshold $JOURNAL_ERROR_THRESHOLD)"
else
    check "OK" "Journal errors in 24h: $journal_errors"
fi

# Build summary for THIS run only
SUMMARY=$(awk "/Run $RUN_ID started/,/Run $RUN_ID completed/" "$LOG_FILE")

# Email on issues
if [ ${#ISSUES[@]} -gt 0 ]; then
    SUBJECT="[$HOSTNAME] ${#ISSUES[@]} health check issue(s)"
    BODY=$(
        echo "Health check found ${#ISSUES[@]} issue(s) on $HOSTNAME:"
        echo ""
        for i in "${ISSUES[@]}"; do
            echo "  - $i"
        done
        echo ""
        echo "Full check results:"
        echo "$SUMMARY"
    )
    send_email "$SUBJECT" "$BODY"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Email sent: ${#ISSUES[@]} issue(s)" >> "$LOG_FILE"

# Weekly recap on Sunday if no issues
elif [ "$DAY_OF_WEEK" = "7" ]; then
    SUBJECT="[$HOSTNAME] weekly health recap (all clean)"
    BODY=$(
        echo "Weekly health summary for $HOSTNAME"
        echo "All checks passing."
        echo ""
        echo "Today's check results:"
        echo "$SUMMARY"
    )
    send_email "$SUBJECT" "$BODY"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Weekly recap sent" >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] All checks passed, no email sent" >> "$LOG_FILE"
fi

echo "=== Run $RUN_ID completed ===" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
