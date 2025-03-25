#!/bin/bash

# Enable strict mode for better error handling
set -euo pipefail

# Configuration
LOGFILE="/var/log/system_cleanup.log"
MAX_LOG_SIZE_MB=10
MIN_DISK_SPACE_MB=1024  # Abort if less than 1GB free
DRY_RUN=false

# Identify the distribution
DISTRO=$(lsb_release -is 2>/dev/null || echo "unknown")
DISTRO=${DISTRO,,}  # Convert to lowercase

# Function to display usage information
usage() {
    echo "Usage: $0 [-n] (dry-run)"
    echo "Options:"
    echo "  -n    Enable dry run mode (no changes will be made)"
    exit 1
}

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
            *) usage ;;
        esac
    done
}

# Function to clean package cache
clean_package_cache() {
    log "Cleaning package cache..."
    case "$DISTRO" in
        centos|rhel|fedora)
            run_command "yum clean all -y"
            ;;
        debian|ubuntu)
            run_command "apt-get clean"
            ;;
        *)
            log_error "Unsupported distribution: $DISTRO"
            ;;
    esac
}

# Function to run a command with error handling
run_command() {
    local cmd="$1"
    if $DRY_RUN; then
        log "DRY RUN: Would run '$cmd'"
    else
        eval "$cmd" >> "$LOGFILE" 2>&1 || log_error "Failed to run command: $cmd"
    fi
}

# Function to remove orphaned packages
remove_orphaned_packages() {
    log "Removing orphaned packages..."
    case "$DISTRO" in
        centos|rhel|fedora)
            if command -v package-cleanup >/dev/null 2>&1; then
                run_command "package-cleanup --quiet --leaves --exclude-bin | xargs -r yum -y remove"
            else
                log "package-cleanup not found, skipping orphaned package removal"
            fi
            ;;
        debian|ubuntu)
            run_command "apt-get autoremove -y"
            ;;
        *)
            log_error "Unsupported distribution: $DISTRO"
            ;;
    esac
}

# Function to clean journal logs
clean_journal_logs() {
    log "Vacuuming journal logs to 500M..."
    run_command "journalctl --vacuum-size=500M"
}

# Function to clean log files
clean_log_files() {
    log "Removing rotated/compressed log files..."
    run_command "find /var/log -type f \\( -name '*.gz' -o -name '*.1' -o -name '*.old' \\) -exec rm -f {} \\;"

    log "Truncating active log files..."
    for logfile in /var/log/{messages,secure,maillog,cron,dmesg} /var/log/audit/audit.log; do
        if [ -f "$logfile" ]; then
            run_command ": > $logfile"
        fi
    done
}

# Function to clean MySQL logs
clean_mysql_logs() {
    log "Clearing MySQL slow query log..."
    if [ -f "/var/lib/mysql/slow-query.log" ]; then
        run_command ": > /var/lib/mysql/slow-query.log"
    fi
}

# Function to clean temp directories
clean_temp_dirs() {
    log "Cleaning /tmp and /var/tmp..."
    run_command "find /tmp /var/tmp -type f \\( -name '*.tmp' -o -name '*.temp' \\) -exec shred -u {} \\;"
    run_command "rm -rf /tmp/* /var/tmp/*"
}

# Function to remove core dumps
remove_core_dumps() {
    log "Removing core dump files..."
    run_command "rm -f /core*"
}

# Function to clean old mail
clean_old_mail() {
    if [ -d "/root/Maildir/new" ]; then
        log "Removing unread root mail older than 7 days..."
        run_command "find /root/Maildir/new -type f -mtime +7 -exec rm -f {} \\;"
    fi
}

# Function to clean lost+found
clean_lost_found() {
    if [ -d "/lost+found" ]; then
        log "Cleaning /lost+found..."
        run_command "rm -rf /lost+found/*"
    fi
}

# Function to log large files
log_large_files() {
    log "Logging large files (>100MB) under / ..."
    run_command "find / -xdev -type f -size +100M -exec ls -lh {} \\; | sort -k 5 -rh | head -n 20 >> $LOGFILE"
}

# Function to clean old kernels
clean_old_kernels() {
    log "Checking for old kernels..."
    case "$DISTRO" in
        centos|rhel|fedora)
            if [ -f /etc/redhat-release ]; then
                run_command "yum remove -y $(rpm -q kernel | grep -v $(uname -r))"
            fi
            ;;
        debian|ubuntu)
            run_command "apt-get remove --purge -y $(dpkg -l 'linux-image*' | grep '^ii' | grep -v $(uname -r) | awk '{print $2}')"
            ;;
        *)
            log_error "Unsupported distribution: $DISTRO"
            ;;
    esac
}

# Function to clean Docker
clean_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Cleaning up Docker..."
        run_command "docker system prune -f"
    fi
}

# Function to generate a report
generate_report() {
    log "========== Disk Space Report =========="
    log "Free space at start: ${START_SPACE} MB"
    log "Free space at end: ${END_SPACE} MB"
    log "Total space freed: $((END_SPACE - START_SPACE)) MB"
    
    log "========== Detailed Disk Usage =========="
    run_command "df -h >> $LOGFILE"
    
    log "========== Inode Usage =========="
    run_command "df -i / >> $LOGFILE"
}

# Main cleanup function
main_cleanup() {
    log "========== Starting System Cleanup =========="
    
    START_SPACE=$(get_free_space_mb)
    log "Initial free space: ${START_SPACE} MB"
    
    clean_package_cache
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
