#!/bin/bash
# Auto-update script - updates but does NOT reboot
LOG_FILE="/var/log/auto-update.log"
ALERT_EMAIL="your@email.com"
echo "=== Update started: $(date) ===" >> $LOG_FILE
# Update package lists
apt update >> $LOG_FILE 2>&1
# Upgrade packages (non-interactive)
DEBIAN_FRONTEND=noninteractive apt upgrade -y >> $LOG_FILE 2>&1
# Remove orphaned packages including old kernels
DEBIAN_FRONTEND=noninteractive apt autoremove --purge -y >> $LOG_FILE 2>&1
# Log if reboot needed
if [ -f /var/run/reboot-required ]; then
    echo "REBOOT REQUIRED - please reboot manually" >> $LOG_FILE
    echo "Packages requiring reboot:" >> $LOG_FILE
    cat /var/run/reboot-required.pkgs >> $LOG_FILE 2>&1
    echo "Reboot required on your-pi-name after apt upgrade. Check /var/run/reboot-required.pkgs for details." | mail -s "⚠️ your-pi-name Reboot Required" "$ALERT_EMAIL"
fi
echo "=== Update completed: $(date) ===" >> $LOG_FILE
echo "" >> $LOG_FILE
