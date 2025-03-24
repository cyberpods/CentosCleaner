#!/bin/bash

# Enable strict mode for better error handling
set -euo pipefail

# Configuration
LOGFILE="/var/log/system_cleanup.log"
MAX_LOG_SIZE_MB=10
MIN_DISK_SPACE_MB=1024  # Abort if less than 1GB free
DRY_RUN=false

# Initialize logging
init_logging() {
    # Rotate log if too large
    if [ -f "$LOGFILE" ] && [ $(stat -c %s "$LOGFILE") -gt $((MAX_LOG_SIZE_MB*1024*1024)) ]; then
        mv "$LOGFILE" "${LOGFILE}.old"
    fi
}

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log_error() {
    log "ERROR: $1"
    exit 1
}

# Check available disk space in MB
get_free_space_mb() {
    df --output=avail -m / | tail -1 | awk '{print $1}'
}

# Check prerequisites
check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi

    local current_space=$(get_free_space_mb)
    if [ "$current_space" -lt "$MIN_DISK_SPACE_MB" ]; then
        log_error "Insufficient disk space ($current_space MB free), aborting"
    fi
}

# Parse command line options
parse_options() {
    while getopts "n" opt; do
        case $opt in
            n) DRY_RUN=true; log "Dry run mode enabled - no changes will be made" ;;
            *) echo "Usage: $0 [-n] (dry-run)" >&2; exit 1 ;;
        esac
    done
}

# Clean YUM cache
clean_yum_cache() {
    log "Cleaning YUM cache..."
    if $DRY_RUN; then
        log "DRY RUN: Would run 'yum clean all -y'"
    else
        yum clean all -y >> "$LOGFILE" 2>&1 || log_error "Failed to clean YUM cache"
    fi
}

# Remove orphaned packages
remove_orphaned_packages() {
    if command -v package-cleanup >/dev/null 2>&1; then
        log "Removing orphaned packages..."
        if $DRY_RUN; then
            log "DRY RUN: Would run 'package-cleanup --quiet --leaves --exclude-bin | xargs -r yum -y remove'"
        else
            package-cleanup --quiet --leaves --exclude-bin | xargs -r yum -y remove >> "$LOGFILE" 2>&1 || log "Failed to remove some orphaned packages (non-critical)"
        fi
    else
        log "package-cleanup not found, skipping orphaned package removal"
    fi
}

# Clean journal logs
clean_journal_logs() {
    log "Vacuuming journal logs to 500M..."
    if $DRY_RUN; then
        log "DRY RUN: Would run 'journalctl --vacuum-size=500M'"
    else
        journalctl --vacuum-size=500M >> "$LOGFILE" 2>&1 || log "Failed to vacuum journal logs (non-critical)"
    fi
}

# Clean log files
clean_log_files() {
    log "Removing rotated/compressed log files..."
    if $DRY_RUN; then
        log "DRY RUN: Would remove files matching /var/log/*.{gz,1,old}"
    else
        find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -exec rm -f {} \; || log "Failed to remove some log files (non-critical)"
    fi

    log "Truncating active log files..."
    for logfile in /var/log/{messages,secure,maillog,cron,dmesg} /var/log/audit/audit.log; do
        if [ -f "$logfile" ]; then
            if $DRY_RUN; then
                log "DRY RUN: Would truncate $logfile"
            else
                : > "$logfile" || log "Failed to truncate $logfile (non-critical)"
            fi
        fi
    done
}

# Clean MySQL logs
clean_mysql_logs() {
    log "Clearing MySQL slow query log..."
    if [ -f "/var/lib/mysql/slow-query.log" ]; then
        if $DRY_RUN; then
            log "DRY RUN: Would truncate /var/lib/mysql/slow-query.log"
        else
            : > /var/lib/mysql/slow-query.log 2>/dev/null || log "Failed to clear MySQL slow query log (non-critical)"
        fi
    fi
}

# Clean temp directories
clean_temp_dirs() {
    log "Cleaning /tmp and /var/tmp..."
    if $DRY_RUN; then
        log "DRY RUN: Would clean /tmp/* and /var/tmp/*"
    else
        # Secure deletion of sensitive temp files first
        find /tmp /var/tmp -type f \( -name "*.tmp" -o -name "*.temp" \) -exec shred -u {} \; 2>/dev/null || true
        
        # Regular cleanup
        rm -rf /tmp/* /var/tmp/* || log "Failed to clean some temp files (non-critical)"
    fi
}

# Remove core dumps
remove_core_dumps() {
    log "Removing core dump files..."
    if $DRY_RUN; then
        log "DRY RUN: Would remove /core* files"
    else
        rm -f /core* >> "$LOGFILE" 2>&1 || log "No core dump files found"
    fi
}

# Clean old mail
clean_old_mail() {
    if [ -d "/root/Maildir/new" ]; then
        log "Removing unread root mail older than 7 days..."
        if $DRY_RUN; then
            log "DRY RUN: Would remove old mail from /root/Maildir/new"
        else
            find /root/Maildir/new -type f -mtime +7 -exec rm -f {} \; >> "$LOGFILE" 2>&1 || log "Failed to clean some mail (non-critical)"
        fi
    fi
}

# Clean lost+found
clean_lost_found() {
    if [ -d "/lost+found" ]; then
        log "Cleaning /lost+found..."
        if $DRY_RUN; then
            log "DRY RUN: Would clean /lost+found/*"
        else
            rm -rf /lost+found/* || log "Failed to clean /lost+found (non-critical)"
        fi
    fi
}

# Log large files
log_large_files() {
    log "Logging large files (>100MB) under / ..."
    find / -xdev -type f -size +100M -exec ls -lh {} \; 2>/dev/null | sort -k 5 -rh | head -n 20 >> "$LOGFILE" || log "Failed to find large files (non-critical)"
}

# Clean old kernels
clean_old_kernels() {
    if [ -f /etc/redhat-release ]; then
        log "Checking for old kernels..."
        if $DRY_RUN; then
            log "DRY RUN: Would remove old kernels"
            rpm -q kernel | grep -v $(uname -r) >> "$LOGFILE" 2>&1 || log "No old kernels found"
        else
            yum remove -y $(rpm -q kernel | grep -v $(uname -r)) >> "$LOGFILE" 2>&1 || log "No old kernels to remove"
        fi
    fi
}

# Docker cleanup
clean_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Cleaning up Docker..."
        if $DRY_RUN; then
            log "DRY RUN: Would run 'docker system prune -f'"
        else
            docker system prune -f >> "$LOGFILE" 2>&1 || log "Docker cleanup failed (non-critical)"
        fi
    fi
}

# Generate report
generate_report() {
    log "========== Disk Space Report =========="
    log "Free space at start: ${START_SPACE} MB"
    log "Free space at end: ${END_SPACE} MB"
    log "Total space freed: $((END_SPACE - START_SPACE)) MB"
    
    log "========== Detailed Disk Usage =========="
    df -h >> "$LOGFILE"
    
    log "========== Inode Usage =========="
    df -i / >> "$LOGFILE"
}

# Main cleanup function
main_cleanup() {
    log "========== Starting System Cleanup =========="
    
    START_SPACE=$(get_free_space_mb)
    log "Initial free space: ${START_SPACE} MB"
    
    clean_yum_cache
    remove_orphaned_packages
    clean_journal_logs
    clean_log_files
    clean_mysql_logs
    clean_temp_dirs
    remove_core_dumps
    clean_old_mail
    clean_lost_found
    log_large_files
    clean_old_kernels
    clean_docker
    
    END_SPACE=$(get_free_space_mb)
    
    generate_report
    log "========== Cleanup Finished =========="
}

# Main execution
parse_options "$@"
init_logging
check_prerequisites
main_cleanup

exit 0
