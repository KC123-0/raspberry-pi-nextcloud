# Raspberry Pi 5 - Self-Hosted Nextcloud

A hardened, self-hosted Nextcloud server on a Raspberry Pi 5 with automated backups, restore testing, health monitoring, and remote access via Tailscale. Built from scratch on bare Debian.

All IP addresses, credentials, and personal details have been replaced with placeholders.

## Hardware

| Device | Spec |
|---|---|
| Raspberry Pi 5 | 8GB RAM |
| OS Drive | NVMe 931GB |
| Data Drive | NVMe 931GB |
| Backup Drive | 3.5TB USB HDD |
| OS | Debian 12 Bookworm |

## Storage Layout

- nvme0n1 - OS, Docker, config
- nvme1n1 - /mnt/storage - Nextcloud user data
- sda - /mnt/ssd1 - Backups, 30 day retention

## Docker Stack

| Container | Image | Purpose |
|---|---|---|
| nextcloud | linuxserver/nextcloud | Self-hosted cloud storage port 5443 |
| nextcloud_db | linuxserver/mariadb | Nextcloud database |
| redis | redis:alpine | Nextcloud caching layer |
| portainer | portainer/portainer-ce | Docker management UI |

All containers bound to Tailscale IP and LAN IP only - nothing exposed publicly.

## Security

- UFW default deny - SSH and Nextcloud via LAN and Tailscale only
- SSH key-only, password auth disabled
- fail2ban monitoring sshd
- Tailscale for remote access - no open ports to the internet
- Wi-Fi and Bluetooth disabled
- Unattended upgrades enabled
- swappiness=10
- Lynis score: 76/100

## Scripts

| Script | Purpose |
|---|---|
| backup.sh | Daily full backup with pre-flight checks and integrity verification |
| monitor.sh | Shared monitoring functions, sourced by backup.sh |
| restore.sh | Production emergency restore from backup |
| restore_test.sh | Fortnightly automated restore in isolated environment |
| run_restore_check.sh | Cron wrapper, runs restore test on odd weeks only |
| health-check.sh | Nightly health check with email alerts |
| auto-update.sh | Weekly OS updates, emails if reboot needed |
| system_report.sh | Full system diagnostic report on demand |

## Cron Schedule

| Job | Frequency |
|---|---|
| Auto-update OS packages | Weekly |
| Full backup | Daily |
| Health check | Daily |
| Restore test | Fortnightly |

## Backup System

Destination: /mnt/ssd1/backups - separate physical drive from data
Retention: 30 days rolling

### Pre-flight checks before every backup

- Drives mounted - immediate alert if missing
- Disk space greater than 100GB free on backup drive
- Memory less than 90%, swap less than 80%
- All Docker containers running
- Nextcloud failed login count checked for brute force detection
- Weekly DB integrity check via mysqlcheck on Sundays

### What gets backed up

1. MariaDB SQL dump - maintenance mode enabled during dump
2. Nextcloud user data - rsync with incremental deduplication
3. Full OS system files
4. Redis and Portainer container exports
5. System info snapshot

### Post-backup integrity checks

- SQL dump size greater than 1MB
- SQL dump contains valid MariaDB header
- File count greater than 100 files
- Latest symlink points correctly
- Data size not more than 20% smaller than previous backup

## Restore Testing

Schedule: Fortnightly
Log: /mnt/ssd1/backups/logs/restore_cron.log

### What the test does

1. Verifies backup files exist and space available
2. Creates isolated Docker network - no LAN access
3. Starts fresh MariaDB, restores SQL dump
4. Patches config.php for test environment
5. Starts fresh Nextcloud on a test port
6. Restores user data via rsync
7. Polls status.php up to 12 times to verify installed
8. Cron run: auto-teardown after 30 minutes
9. Manual run: leaves instance up, prompts before cleanup

## Health Checks

Schedule: Daily
Log: /var/log/health-check.log
Email: Failure only - weekly recap on Sundays if all clean

| Check | Threshold |
|---|---|
| SMART health all drives | PASSED |
| Disk usage all mounts | Less than 85% |
| Failed systemd services | 0 |
| Docker containers | All running |
| Nextcloud HTTP response | installed:true |
| CPU temperature | Less than 75C |
| CPU throttling | None |
| Last backup age | Less than 25h |
| Reboot required | No |
| SSH auth failures 24h | Less than 50 |
| Available memory | Greater than 500MB |
| Tailscale connected | Yes |
| Journal errors 24h | Less than 10 |

## Setup

1. Clone this repo
2. Copy config/your-pi-name.conf.example to /home/pi/your-pi-name.conf
3. Fill in your values
4. Run chmod 600 /home/pi/your-pi-name.conf
5. Copy scripts to their locations and chmod +x
6. Set up cron jobs

## Recovery Procedure

For use when the OS drive fails. Recovery time approximately 35-45 minutes.

Prerequisites:
- Fresh Debian install on replacement NVMe
- Docker installed
- /mnt/ssd1 mounted
- /mnt/storage mounted

Steps:
1. Clone this repo
2. Set up config file
3. Run sudo bash scripts/restore.sh

## Lessons Learned

Boot from NVMe not SD card. SD cards fail under server write loads.

Test your restores not just your backups. Automated fortnightly restore tests have caught issues that post-backup integrity checks missed.

Tailscale before anything else. No ports exposed to the internet.

Alert only on failure. Daily success emails train you to ignore them.

Operational discipline beats hardware. Backups, restore tests, health checks, and monitoring matter more than the hardware they run on.
