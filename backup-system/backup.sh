#!/bin/bash

# Author: Petnikoti Sai Nikhil
# Backup Automation System - Version 6
# With Config File, Free Space Check, Alerts & Dry-Run Support

CONFIG_FILE="./backup.conf"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Config file not found: $CONFIG_FILE"
  exit 1
fi
source "$CONFIG_FILE"

TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.tar.gz"
LOCK_FILE="/tmp/backup.lock"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

alert() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ALERT: $1" | tee -a "$ALERT_LOG"
}

# Check if dry-run mode
DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
  DRY_RUN=true
fi

# Prevent concurrent backups (skip lock in dry-run)
if [ "$DRY_RUN" = false ]; then
  if [ -e "$LOCK_FILE" ]; then
    log "ERROR: Another backup process is already running (lock: $LOCK_FILE)"
    exit 1
  fi
  touch "$LOCK_FILE"
fi

# Free space check
AVAILABLE_MB=$(df "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
if [ "$AVAILABLE_MB" -lt "$MIN_FREE_SPACE" ]; then
  alert "Insufficient disk space! Only ${AVAILABLE_MB}MB available."
  log "ERROR: Not enough free space. Required: ${MIN_FREE_SPACE}MB"
  [ "$DRY_RUN" = false ] && rm -f "$LOCK_FILE"
  exit 1
fi

# Check if source folder exists
if [ ! -d "$SOURCE_DIR" ]; then
  alert "Source directory missing: $SOURCE_DIR"
  log "ERROR: Source folder not found!"
  [ "$DRY_RUN" = false ] && rm -f "$LOCK_FILE"
  exit 1
fi

log "INFO: Starting backup of $SOURCE_DIR (dry-run=$DRY_RUN)"

if [ "$DRY_RUN" = true ]; then
  log "INFO: [DRY-RUN] Would create archive: $BACKUP_FILE"
  log "INFO: [DRY-RUN] Would create checksum file: $BACKUP_FILE.sha256"
  log "INFO: [DRY-RUN] Would verify checksum and extraction"
  log "INFO: [DRY-RUN] Would delete backups older than $RETENTION_DAYS days"
  log "INFO: Dry-run completed successfully. No files changed."
  exit 0
fi

# Real backup process
tar -czf "$BACKUP_FILE" "$SOURCE_DIR" 2>>"$LOG_FILE"

if [ $? -ne 0 ]; then
  alert "Backup failed during compression stage!"
  log "ERROR: Backup creation failed."
  rm -f "$LOCK_FILE"
  exit 1
fi

# Verify checksum
sha256sum "$BACKUP_FILE" > "$BACKUP_FILE.sha256"
log "INFO: Checksum file created."

sha256sum -c "$BACKUP_FILE.sha256" &>/dev/null
if [ $? -eq 0 ]; then
  log "SUCCESS: Checksum verified successfully."
else
  alert "Checksum verification failed for $BACKUP_FILE"
  log "ERROR: Checksum verification failed."
fi

# Retention cleanup
log "INFO: Starting cleanup of old backups..."
find "$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +$RETENTION_DAYS -exec rm -v {} \; >>"$LOG_FILE" 2>&1
log "INFO: Cleanup completed. Retention policy applied."

log "SUCCESS: Backup process completed."
rm -f "$LOCK_FILE"
