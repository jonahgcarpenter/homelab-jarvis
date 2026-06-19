#!/bin/bash

# -----------------------------------------------------------------------------
# Frigate Custom Backup Script
# Mounts a drive, syncs Frigate recordings, unmounts, and alerts on failure/disk usage.
# -----------------------------------------------------------------------------

# -- Configuration --

DEVICE="/dev/sdb1"                        # Backup drive partition
MOUNT_POINT="/mnt/frigate_backups"        # Mount destination
FRIGATE_SOURCE_DIR="/mnt/frigate/recordings/" # Source (requires trailing slash)
RSYNC_DEST_SUBDIR="recordings"            # Subdirectory in mount point
CAMERAS_TO_INCLUDE=("living_room" "hallway" "kitchen")

LOG_FILE="/var/log/frigate_custom_backup.log"
SCRIPT_NAME="Frigate Backup"
EMAIL_RECIPIENT="root@pam"                # Proxmox admin recipient
DISK_THRESHOLD=80                         # Alert if disk usage % exceeds this

# -- Helpers --

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
}

# -- Execution --

# Reset log file for the new run
if sudo truncate -s 0 "$LOG_FILE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Log file truncated." | sudo tee "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Failed to truncate $LOG_FILE." | sudo tee -a "$LOG_FILE" >&2
fi

log_message "======= Starting $SCRIPT_NAME ======="

# 1. Verify/Create Mount Point
if [ ! -d "$MOUNT_POINT" ]; then
    log_message "Mount point $MOUNT_POINT missing. Creating..."
    if ! sudo mkdir -p "$MOUNT_POINT"; then
        log_message "ERROR: Failed to create $MOUNT_POINT."
        echo -e "Subject: [$SCRIPT_NAME] CRITICAL FAILURE\n\nFailed to create $MOUNT_POINT. Check $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null
        exit 1
    fi
fi

# 2. Mount Backup Drive
IS_CORRECTLY_MOUNTED=false
CRITICAL_ERROR_MESSAGE=""

if mountpoint -q "$MOUNT_POINT"; then
    CURRENTLY_MOUNTED_DEVICE=$(findmnt -n -o SOURCE --target "$MOUNT_POINT")
    if [ "$CURRENTLY_MOUNTED_DEVICE" == "$DEVICE" ]; then
        log_message "$DEVICE already mounted at $MOUNT_POINT."
        IS_CORRECTLY_MOUNTED=true
    else
        CRITICAL_ERROR_MESSAGE="Wrong device mounted at $MOUNT_POINT: $CURRENTLY_MOUNTED_DEVICE. Expected $DEVICE."
    fi
else
    log_message "Attempting to mount $DEVICE..."
    if sudo mount "$DEVICE" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
        log_message "$DEVICE mounted successfully."
        IS_CORRECTLY_MOUNTED=true
    else
        CRITICAL_ERROR_MESSAGE="Failed to mount $DEVICE (Code: $?)."
    fi
fi

if ! $IS_CORRECTLY_MOUNTED; then
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE Exiting."
    echo -e "Subject: [$SCRIPT_NAME] CRITICAL FAILURE\n\n$CRITICAL_ERROR_MESSAGE Check $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null
    exit 1
fi

# 3. Verify Rsync Destination
FULL_RSYNC_DEST="$MOUNT_POINT/$RSYNC_DEST_SUBDIR"
if ! sudo mkdir -p "$FULL_RSYNC_DEST"; then
    CRITICAL_ERROR_MESSAGE="Failed to create destination $FULL_RSYNC_DEST."
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE"
    echo -e "Subject: [$SCRIPT_NAME] CRITICAL FAILURE\n\n$CRITICAL_ERROR_MESSAGE Check $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null
    sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
    exit 1
fi

# 4. Configure Rsync Includes
RSYNC_INCLUDE_OPTS=(--include='*/')
for CAM_NAME in "${CAMERAS_TO_INCLUDE[@]}"; do
    RSYNC_INCLUDE_OPTS+=(--include="*/$CAM_NAME/**")
done

# 5. Execute Rsync
log_message "Starting rsync to $FULL_RSYNC_DEST..."
sudo rsync -avz --no-owner --no-group \
  "${RSYNC_INCLUDE_OPTS[@]}" \
  --exclude='*' \
  "$FRIGATE_SOURCE_DIR" \
  "$FULL_RSYNC_DEST" >> "$LOG_FILE" 2>&1
RSYNC_STATUS=$?

if [ $RSYNC_STATUS -eq 0 ]; then
    log_message "Rsync successful."
    RSYNC_MESSAGE_DETAIL="Success."
elif [ $RSYNC_STATUS -eq 24 ]; then
    log_message "Rsync warning (Code 24: Vanished source files)."
    RSYNC_MESSAGE_DETAIL="Warning (Code 24)."
else
    log_message "ERROR: Rsync failed (Code $RSYNC_STATUS)."
    RSYNC_MESSAGE_DETAIL="FAILED (Code $RSYNC_STATUS)."
fi

FINAL_EXIT_CODE=0
EMAIL_SUBJECT_STATUS="SUCCESS"

if [ $RSYNC_STATUS -ne 0 ] && [ $RSYNC_STATUS -ne 24 ]; then
    FINAL_EXIT_CODE=$RSYNC_STATUS
    EMAIL_SUBJECT_STATUS="FAILED (Rsync Error)"
fi

# 6. Check Disk Usage
DISK_USAGE_PERCENT=$(df "$MOUNT_POINT" | tail -n 1 | awk '{print $5}')
DISK_USAGE_NUM=0

if [ -n "$DISK_USAGE_PERCENT" ]; then
    DISK_USAGE_LOG_MESSAGE="Disk usage: $DISK_USAGE_PERCENT."
    log_message "$DISK_USAGE_LOG_MESSAGE"
    DISK_USAGE_NUM=$(echo "$DISK_USAGE_PERCENT" | tr -d '%')
else
    DISK_USAGE_LOG_MESSAGE="Could not determine disk usage."
    log_message "WARNING: $DISK_USAGE_LOG_MESSAGE"
fi

# 7. Unmount Drive
UMOUNT_MESSAGE_DETAIL=""
log_message "Unmounting $MOUNT_POINT..."
if ! sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
    log_message "ERROR: Failed to unmount $MOUNT_POINT (Code: $?)."
    UMOUNT_MESSAGE_DETAIL="Unmount failed (Code: $?)."
    if [ "$EMAIL_SUBJECT_STATUS" == "SUCCESS" ]; then
        EMAIL_SUBJECT_STATUS="COMPLETED WITH UNMOUNT ISSUE"
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=100; fi
    fi
else
    log_message "$MOUNT_POINT unmounted."
    UMOUNT_MESSAGE_DETAIL="Unmounted successfully."
fi

# 8. Email Notification Logic
SEND_EMAIL=false

if [ "$FINAL_EXIT_CODE" -ne 0 ]; then
    SEND_EMAIL=true
fi

if [[ "$DISK_USAGE_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_USAGE_NUM" -ge "$DISK_THRESHOLD" ]; then
    SEND_EMAIL=true
    EMAIL_SUBJECT_STATUS="WARNING: Disk Usage at ${DISK_USAGE_PERCENT}" 
fi

if $SEND_EMAIL; then
    log_message "Preparing email notification..."
    EMAIL_SUBJECT="[$SCRIPT_NAME]: $EMAIL_SUBJECT_STATUS"
    
    EMAIL_BODY="Script execution finished.\n"
    EMAIL_BODY+="Rsync Status: $RSYNC_MESSAGE_DETAIL\n"
    [ -n "$DISK_USAGE_LOG_MESSAGE" ] && EMAIL_BODY+="$DISK_USAGE_LOG_MESSAGE\n"
    [ -n "$UMOUNT_MESSAGE_DETAIL" ] && EMAIL_BODY+="Unmount Status: $UMOUNT_MESSAGE_DETAIL\n"

    PROXMOX_MAILER="/usr/bin/proxmox-mail-forward"
    if [ -x "$PROXMOX_MAILER" ]; then
        printf "Subject: %s\n\n%s" "$EMAIL_SUBJECT" "$EMAIL_BODY" | sudo "$PROXMOX_MAILER" "$EMAIL_RECIPIENT"
        if [ $? -eq 0 ]; then
            log_message "Email sent successfully."
        else
            log_message "ERROR: Failed to send email (Code: $?)."
            if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=102; fi
        fi
    else
        log_message "ERROR: $PROXMOX_MAILER not found/executable."
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=103; fi
    fi
else
    log_message "Success. Disk usage below ${DISK_THRESHOLD}%. Skipping email."
fi

log_message "======= Finished ======="
echo "" >> "$LOG_FILE"

exit $FINAL_EXIT_CODE
