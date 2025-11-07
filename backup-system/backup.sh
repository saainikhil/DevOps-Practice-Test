#!/bin/bash

# Author: Petnikoti Sai Nikhil
# Backup Automation System – Full Feature Version
# Includes: Dry-run, retention (daily/weekly/monthly), restore, list, exclusions, logging, checksum, lockfile, email simulation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

# Verify config
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[ERROR] Config file not found: $CONFIG_FILE"
  exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# Defaults (if any missing from config)
: "${BACKUP_DIR:="$HOME/backups"}"
: "${EXCLUDE_PATTERNS:=".git,node_modules,.cache"}"
: "${DAILY_KEEP:=7}"
: "${WEEKLY_KEEP:=4}"
: "${MONTHLY_KEEP:=3}"
: "${CHECKSUM_ALGO:="sha256"}"
: "${LOG_FILE:="backup.log"}"
: "${ALERT_LOG:="alert.log"}"
: "${NOTIFY_EMAIL:=""}"

mkdir -p "$BACKUP_DIR" || { echo "[ERROR] Cannot create backup dir $BACKUP_DIR"; exit 1; }

LOG_PATH="$BACKUP_DIR/$LOG_FILE"
ALERT_PATH="$BACKUP_DIR/$ALERT_LOG"
EMAIL_FILE="$BACKUP_DIR/email.txt"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_PATH"
}

alert() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $1" | tee -a "$ALERT_PATH"
}

send_email() {
  [[ -z "$NOTIFY_EMAIL" ]] && return
  {
    echo "To: $NOTIFY_EMAIL"
    echo "Subject: $1"
    echo "Date: $(date -R)"
    echo ""
    echo "$2"
    echo "-----"
  } >> "$EMAIL_FILE"
}

LOCKFILE="/tmp/backup.lock"

cleanup() {
  local code=$1
  if [[ -f "$LOCKFILE" ]]; then
    owner=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    [[ "$owner" == "$$" ]] && rm -f "$LOCKFILE"
  fi
  exit "$code"
}

trap 'log "INFO: Interrupted"; cleanup 2' INT TERM

checksum_cmd() {
  case "$CHECKSUM_ALGO" in
    sha256)
      command -v sha256sum >/dev/null && echo "sha256sum" && return
      command -v shasum >/dev/null && echo "shasum -a 256" && return
      ;;
    md5)
      command -v md5sum >/dev/null && echo "md5sum" && return
      ;;
  esac
  command -v sha256sum >/dev/null && echo "sha256sum" && return
  command -v md5sum >/dev/null && echo "md5sum" && return
  command -v shasum >/dev/null && echo "shasum -a 256" && return
  log "ERROR: No checksum tool available"; cleanup 1
}

# Parse arguments
MODE="backup"
SRC=""
RESTORE_FILE=""
RESTORE_TO=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --list) MODE="list"; shift ;;
    --restore) MODE="restore"; RESTORE_FILE="$2"; shift 2 ;;
    --to) RESTORE_TO="$2"; shift 2 ;;
    --help|-h)
      echo "Usage:"
      echo "  $0 [--dry-run] /path/to/source"
      echo "  $0 --list"
      echo "  $0 --restore backup-file.tar.gz --to /path/restore"
      exit 0
      ;;
    *)
      SRC="$1"; shift ;;
  esac
done

#####################################
# LIST MODE
#####################################
if [[ "$MODE" == "list" ]]; then
  echo "Backups in $BACKUP_DIR:"
  printf "%-35s %-20s %-10s\n" "FILE" "DATE" "SIZE"
  for f in "$BACKUP_DIR"/backup-*.tar.gz; do
    [[ ! -f "$f" ]] && continue
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
    name=$(basename "$f")
    datepart="${name#backup-}"; datepart="${datepart%.tar.gz}"
    printf "%-35s %-20s %-10s\n" "$name" "$datepart" "$size"
  done
  exit 0
fi

#####################################
# RESTORE MODE
#####################################
if [[ "$MODE" == "restore" ]]; then
  [[ -z "$RESTORE_FILE" || -z "$RESTORE_TO" ]] && { echo "Missing --restore or --to"; exit 1; }

  arch="$RESTORE_FILE"
  [[ ! -f "$arch" && -f "$BACKUP_DIR/$arch" ]] && arch="$BACKUP_DIR/$arch"
  [[ ! -f "$arch" ]] && { log "ERROR: Restore file not found"; exit 1; }

  mkdir -p "$RESTORE_TO" || { log "ERROR: Cannot create restore dir"; exit 1; }

  if [[ $DRY_RUN -eq 1 ]]; then
    log "INFO: DRY RUN: Would restore $arch to $RESTORE_TO"
    exit 0
  fi

  log "INFO: Restoring $arch to $RESTORE_TO"
  if tar -xzf "$arch" -C "$RESTORE_TO"; then
    log "SUCCESS: Restore complete"
    send_email "Restore successful" "Restored to $RESTORE_TO"
  else
    log "ERROR: Restore failed"
    send_email "Restore failed" "Could not extract $arch"
  fi

  exit 0
fi

#####################################
# BACKUP MODE
#####################################
[[ -z "$SRC" ]] && { echo "Error: Source folder missing"; exit 1; }
[[ ! -d "$SRC" ]] && { alert "Source directory missing: $SRC"; log "ERROR: Source not found"; exit 1; }

# Lock check
if [[ -f "$LOCKFILE" ]]; then
  pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
    log "ERROR: Another backup is running (PID $pid)"
    exit 1
  fi
  rm -f "$LOCKFILE"
fi
echo "$$" > "$LOCKFILE"

trap 'cleanup $?' EXIT

TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
ARCHIVE="$BACKUP_DIR/backup-$TIMESTAMP.tar.gz"
CHECKSUM_FILE="$ARCHIVE.md5"

# Exclusions
IFS=',' read -ra ex <<< "$EXCLUDE_PATTERNS"
EXCLUDE_ARGS=()
for e in "${ex[@]}"; do EXCLUDE_ARGS+=(--exclude="$e"); done

if [[ $DRY_RUN -eq 1 ]]; then
  log "INFO: DRY RUN: Would backup $SRC to $ARCHIVE"
  exit 0
fi

log "INFO: Starting backup of $SRC"

if ! tar -czf "$ARCHIVE" "${EXCLUDE_ARGS[@]}" -C "$(dirname "$SRC")" "$(basename "$SRC")"; then
  alert "Backup failed"
  log "ERROR: Tar creation failed"
  cleanup 1
fi

log "SUCCESS: Backup created: $(basename "$ARCHIVE")"

# checksum
CHKSUM=$(checksum_cmd)
$CHKSUM "$ARCHIVE" > "$CHECKSUM_FILE"
log "INFO: Checksum created: $(basename "$CHECKSUM_FILE")"

# verify tar
if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  log "INFO: Archive integrity OK"
else
  alert "Corrupted archive: $ARCHIVE"
  cleanup 1
fi

# Retention: daily/weekly/monthly
log "INFO: Applying retention policy"
mapfile -t backups < <(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null || true)

declare -A days weeks months
d=0; w=0; m=0

for b in "${backups[@]}"; do
  bn=$(basename "$b")
  datepart="${bn#backup-}"; datepart="${datepart%.tar.gz}"
  day="${datepart:0:10}"

  # derive week & month
  week=$(date -d "$day" +%G-%V 2>/dev/null || echo "$day")
  month="${day:0:7}"

  keep=0
  if [[ -z "${days[$day]}" && $d -lt $DAILY_KEEP ]]; then
    days[$day]=1; d=$((d+1)); keep=1
  elif [[ -z "${weeks[$week]}" && $w -lt $WEEKLY_KEEP ]]; then
    weeks[$week]=1; w=$((w+1)); keep=1
  elif [[ -z "${months[$month]}" && $m -lt $MONTHLY_KEEP ]]; then
    months[$month]=1; m=$((m+1)); keep=1
  fi

  if [[ $keep -eq 1 ]]; then
    log "INFO: Keeping $bn"
  else
    log "INFO: Deleting $bn"
    rm -f "$b" "$b.md5"
  fi
done

log "SUCCESS: Backup job completed for $SRC"
send_email "Backup successful" "Backup completed for $SRC"
cleanup 0
