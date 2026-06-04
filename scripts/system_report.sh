#!/bin/bash

# Comprehensive System Report Generator
# Creates a detailed report of system status, performance, and configuration

set -euo pipefail

REPORT_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_DIR="/tmp/system_reports"
REPORT_FILE="$REPORT_DIR/system_report_$REPORT_DATE.txt"

# Create report directory first
mkdir -p "$REPORT_DIR"

# Clean up old reports
echo "Cleaning up reports older than 2 weeks..."
find "$REPORT_DIR" -name "system_report_*.txt" -type f -mtime +14 -delete 2>/dev/null || true

# Function to add section headers
add_section() {
    echo "" | tee -a "$REPORT_FILE"
    echo "=============================================" | tee -a "$REPORT_FILE"
    echo "$1" | tee -a "$REPORT_FILE"
    echo "=============================================" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
}

# Function to run command and add to report
run_command() {
    local cmd="$1"
    local description="$2"

    echo "--- $description ---" | tee -a "$REPORT_FILE"
    echo "Command: $cmd" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"

    if eval "$cmd" >> "$REPORT_FILE" 2>&1; then
        echo "" | tee -a "$REPORT_FILE"
    else
        echo "Error running command: $cmd" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi
}

echo "Generating comprehensive system report..."
echo "Report will be saved to: $REPORT_FILE"

# Initialize report
{
    echo "SYSTEM REPORT"
    echo "Generated: $(date)"
    echo "Hostname: $(hostname)"
    echo "User: $(whoami)"
} > "$REPORT_FILE"

# SYSTEM INFORMATION
add_section "SYSTEM INFORMATION"
run_command "uname -a" "Kernel Information"
run_command "lsb_release -a" "Distribution Information"
run_command "hostnamectl" "System Hostname Details"
run_command "uptime" "System Uptime"
run_command "who" "Currently Logged In Users"
run_command "last -10" "Recent Login History"

# HARDWARE INFORMATION
add_section "HARDWARE INFORMATION"
run_command "lscpu" "CPU Information"
run_command "free -h" "Memory Usage"
run_command "lsblk" "Block Devices"
run_command "lspci" "PCI Devices"
run_command "lsusb" "USB Devices"
run_command "dmidecode -t system" "System DMI Information"

# DISK AND FILESYSTEM
add_section "DISK AND FILESYSTEM INFORMATION"
run_command "df -h" "Disk Space Usage"
run_command "du -sh /home/* 2>/dev/null || true" "Home Directory Sizes"
run_command "mount | grep -E '^/dev'" "Mounted Filesystems"
run_command "lsof +D /mnt 2>/dev/null | head -20 || true" "Open Files on Mounted Drives"
run_command "findmnt" "Mount Tree"

# NETWORK INFORMATION
add_section "NETWORK INFORMATION"
run_command "ip addr show" "Network Interfaces"
run_command "ip route show" "Routing Table"
run_command "ss -tuln" "Listening Ports"
run_command "sudo iptables -L -n" "Firewall Rules"
run_command "systemctl status NetworkManager 2>/dev/null || systemctl status systemd-networkd 2>/dev/null || echo 'No network manager found'" "Network Service Status"

# SERVICES AND PROCESSES
add_section "SERVICES AND PROCESSES"
run_command "systemctl list-units --type=service --state=running" "Running Services"
run_command "systemctl list-units --type=service --state=failed" "Failed Services"
run_command "ps aux --sort=-%cpu | head -20" "Top CPU Processes"
run_command "ps aux --sort=-%mem | head -20" "Top Memory Processes"
run_command "systemctl list-timers" "System Timers"

# DOCKER INFORMATION (if available)
if command -v docker &> /dev/null; then
    add_section "DOCKER INFORMATION"
    run_command "docker --version" "Docker Version"
    run_command "docker info" "Docker System Info"
    run_command "docker ps -a" "Docker Containers"
    run_command "docker images" "Docker Images"
    run_command "docker volume ls" "Docker Volumes"
    run_command "docker network ls" "Docker Networks"
    run_command "docker system df" "Docker Disk Usage"
fi

# BACKUP INFORMATION
add_section "BACKUP INFORMATION"
run_command "sudo du -sh /mnt/ssd1/backups/20*/ 2>/dev/null || echo 'No timestamped backups found'" "Recent Backups"
run_command "ls -la /mnt/ssd1/backups/latest 2>/dev/null || echo 'No latest symlink found'" "Latest Backup"
run_command "crontab -l" "User Cron Jobs"
run_command "sudo crontab -l" "Root Cron Jobs"
run_command "tail -20 /mnt/ssd1/backups/logs/backup_all.log 2>/dev/null || echo 'No backup log found'" "Recent Backup Log"

# STORAGE INFORMATION
add_section "NEXTCLOUD STORAGE"
run_command "df -h /mnt/storage" "Nextcloud Data Drive Usage"
run_command "du -sh /mnt/storage/nextcloud_data 2>/dev/null || echo 'No Nextcloud data found'" "Nextcloud Data Size"

# SECURITY INFORMATION
add_section "SECURITY INFORMATION"
run_command "sudo ufw status verbose" "UFW Firewall Status"
run_command "sudo fail2ban-client status 2>/dev/null || echo 'Fail2ban not installed'" "Fail2ban Status"
run_command "last -20" "Login History"
run_command "sudo journalctl --since='24 hours ago' --grep='sudo' --no-pager | tail -10 || true" "Recent Sudo Usage"

# PACKAGE INFORMATION
add_section "PACKAGE INFORMATION"
run_command "apt list --upgradable 2>/dev/null | head -20" "Available Updates"
run_command "dpkg -l | wc -l" "Total Installed Packages"
run_command "apt-cache policy" "APT Repository Information"
run_command "snap list 2>/dev/null || echo 'Snap not available'" "Snap Packages"

# PERFORMANCE METRICS
add_section "PERFORMANCE METRICS"
run_command "iostat -x 1 3 2>/dev/null || echo 'iostat not available'" "I/O Statistics"
run_command "vmstat 1 3" "Virtual Memory Statistics"
run_command "sar -u 1 3 2>/dev/null || echo 'sar not available'" "CPU Usage Statistics"
run_command "dmesg | tail -20" "Recent Kernel Messages"

# LOG ANALYSIS
add_section "RECENT LOG ENTRIES"
run_command "sudo journalctl --since='24 hours ago' --priority=err --no-pager | tail -10 || true" "Recent Error Messages"
run_command "sudo journalctl --since='24 hours ago' --grep='systemd' --no-pager | tail -10 || true" "Recent Systemd Messages"

# SUMMARY
add_section "SYSTEM SUMMARY"
{
    echo "Report Generation Completed: $(date)"
    echo "System: $(hostname) ($(uname -r))"
    echo "Uptime: $(uptime -p)"
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
    echo "Memory Usage: $(free | awk '/^Mem:/ {printf "%.1f%%", $3/$2 * 100.0}')"
    echo "Disk Usage (root): $(df / | awk 'NR==2 {print $5}')"
    echo "Nextcloud Storage: $(df /mnt/storage | awk 'NR==2 {print $5}') used"
    echo "Running Services: $(systemctl list-units --type=service --state=running --no-legend | wc -l)"
    echo "Docker Containers: $(docker ps -q 2>/dev/null | wc -l || echo '0')"
    echo "Backup Directories: $(ls -d /mnt/ssd1/backups/20*/ 2>/dev/null | wc -l || echo '0')"
    echo ""
    echo "Report saved to: $REPORT_FILE"
    echo "Report size: $(du -sh "$REPORT_FILE" | cut -f1)"
} | tee -a "$REPORT_FILE"

# Display completion message
echo ""
echo "System report generated successfully!"
echo "Location: $REPORT_FILE"
echo "Size: $(du -sh "$REPORT_FILE" | cut -f1)"
echo ""
echo "To view the report:"
echo "  less $REPORT_FILE"
echo "  cat $REPORT_FILE"
echo "  nano $REPORT_FILE"
echo ""
echo "To copy the report:"
echo "  cp $REPORT_FILE ~/system_report.txt"
