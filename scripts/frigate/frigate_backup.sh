#!/bin/bash

# === Configuration ===
# --- Drive and Mount Configuration ---
DEVICE="/dev/sdc1"                        # The backup drive partition
MOUNT_POINT="/mnt/frigate_backups"        # Where the backup drive will be mounted

# --- Rsync Configuration ---
FRIGATE_SOURCE_DIR="/mnt/frigate/recordings/" # Source of Frigate recordings (ensure trailing slash)
RSYNC_DEST_SUBDIR="recordings"                # Subdirectory within MOUNT_POINT for rsync data

# --- Cameras to Include ---
CAMERAS_TO_INCLUDE=(
    "living_room"
    "hallway"
    "kitchen"
)

# --- Logging & Notification ---
LOG_FILE="/var/log/frigate_custom_backup.log" # Centralized log file for this script
SCRIPT_NAME="Frigate Custom Backup"           # Name for notifications/emails
EMAIL_RECIPIENT="root@pam"                    # Default Proxmox admin recipient; uses system mail settings.
                                              # Ensure this user has a valid forward email configured in PVE User Management if needed.

# === Helper Function for Logging ===
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
}

# === Main Script ===

# --- Override Log File at the Start of Each Run ---
# Using truncate command as an alternative.
# This command truncates the log file to 0 bytes if it exists, or creates it.
# It requires sudo privileges as it's modifying a file in /var/log/.
if sudo truncate -s 0 "$LOG_FILE"; then
    # Optionally log that truncation was attempted, this will be the first line
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Log file truncated." | sudo tee "$LOG_FILE" # Use tee (no -a) to overwrite with this first line
else
    # If truncate fails, still try to proceed but log the failure to standard error
    # and attempt to write a warning to the log using append (as truncate failed)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Failed to truncate log file $LOG_FILE. Logs will append." | sudo tee -a "$LOG_FILE" >&2
fi

log_message "======= Starting $SCRIPT_NAME Script ======="

# 1. Ensure mount point directory exists (same as previous version)
if [ ! -d "$MOUNT_POINT" ]; then
    log_message "Mount point directory $MOUNT_POINT does not exist. Creating it..."
    if ! sudo mkdir -p "$MOUNT_POINT"; then
        log_message "ERROR: Failed to create mount point directory $MOUNT_POINT. Exiting."
        # Attempt to send email for critical failure before exiting
        echo -e "Subject: $SCRIPT_NAME: CRITICAL FAILURE\n\nFailed to create mount point $MOUNT_POINT. See log $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null || log_message "Also failed to send critical failure email."
        exit 1
    fi
fi

# 2. Mount the backup drive (same as previous version, with email on critical failure)
IS_CORRECTLY_MOUNTED=false
CRITICAL_ERROR_MESSAGE=""
if mountpoint -q "$MOUNT_POINT"; then
    CURRENTLY_MOUNTED_DEVICE=$(findmnt -n -o SOURCE --target "$MOUNT_POINT")
    if [ "$CURRENTLY_MOUNTED_DEVICE" == "$DEVICE" ]; then
        log_message "$DEVICE is already mounted at $MOUNT_POINT."
        IS_CORRECTLY_MOUNTED=true
    else
        CRITICAL_ERROR_MESSAGE="$MOUNT_POINT mounted by wrong device: $CURRENTLY_MOUNTED_DEVICE. Expected $DEVICE."
    fi
else
    log_message "$MOUNT_POINT is not mounted. Attempting to mount $DEVICE..."
    if sudo mount "$DEVICE" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
        log_message "$DEVICE mounted successfully at $MOUNT_POINT."
        IS_CORRECTLY_MOUNTED=true
    else
        MOUNT_STATUS=$?
        CRITICAL_ERROR_MESSAGE="Failed to mount $DEVICE at $MOUNT_POINT (Code: $MOUNT_STATUS)."
    fi
fi

if ! $IS_CORRECTLY_MOUNTED; then
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE Please investigate. Exiting."
    echo -e "Subject: $SCRIPT_NAME: CRITICAL FAILURE\n\n$CRITICAL_ERROR_MESSAGE See log $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null || log_message "Also failed to send critical failure email for mount issue."
    exit 1
fi


# 3. Define the full rsync destination path and ensure it exists (same as previous, with email on critical failure)
FULL_RSYNC_DEST="$MOUNT_POINT/$RSYNC_DEST_SUBDIR"
log_message "Ensuring rsync destination directory '$FULL_RSYNC_DEST' exists..."
if ! sudo mkdir -p "$FULL_RSYNC_DEST"; then
    CRITICAL_ERROR_MESSAGE="Failed to create rsync destination $FULL_RSYNC_DEST."
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE Exiting."
    echo -e "Subject: $SCRIPT_NAME: CRITICAL FAILURE\n\n$CRITICAL_ERROR_MESSAGE See log $LOG_FILE." | sudo /usr/sbin/proxmox-mail-forward "$EMAIL_RECIPIENT" 2>/dev/null || log_message "Also failed to send critical failure email for rsync dest."
    log_message "Attempting to unmount $MOUNT_POINT before exiting..."
    sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
    exit 1
fi

# 4. Build rsync include options (same as previous version)
RSYNC_INCLUDE_OPTS=()
RSYNC_INCLUDE_OPTS+=(--include='*/')
for CAM_NAME in "${CAMERAS_TO_INCLUDE[@]}"; do
    RSYNC_INCLUDE_OPTS+=(--include="*/$CAM_NAME/**")
done

# 5. Run the rsync command (same as previous version)
log_message "Starting rsync operation from $FRIGATE_SOURCE_DIR to $FULL_RSYNC_DEST for cameras: ${CAMERAS_TO_INCLUDE[*]}..."
sudo rsync -avz --no-owner --no-group \
  "${RSYNC_INCLUDE_OPTS[@]}" \
  --exclude='*' \
  "$FRIGATE_SOURCE_DIR" \
  "$FULL_RSYNC_DEST" >> "$LOG_FILE" 2>&1
RSYNC_STATUS=$?

RSYNC_MESSAGE_DETAIL="" # Renamed to avoid conflict with any system $MESSAGE var
if [ $RSYNC_STATUS -eq 0 ]; then
    log_message "Rsync operation completed successfully."
    RSYNC_MESSAGE_DETAIL="Rsync completed successfully."
elif [ $RSYNC_STATUS -eq 24 ]; then
    log_message "Rsync operation completed with warnings (Exit code 24: Partial transfer due to vanished source files)."
    RSYNC_MESSAGE_DETAIL="Rsync completed with warnings (vanished source files - code 24)."
else
    log_message "ERROR: Rsync operation failed with exit code $RSYNC_STATUS."
    RSYNC_MESSAGE_DETAIL="Rsync FAILED with exit code $RSYNC_STATUS."
fi

# Determine overall script success for notification and exit code
FINAL_EXIT_CODE=0
EMAIL_SUBJECT_STATUS="SUCCESS"

if [ $RSYNC_STATUS -ne 0 ] && [ $RSYNC_STATUS -ne 24 ]; then
    FINAL_EXIT_CODE=$RSYNC_STATUS
    EMAIL_SUBJECT_STATUS="FAILED (Rsync Error)"
fi

# 6. *** NEW *** Check disk usage before unmounting
DISK_USAGE_LOG_MESSAGE=""
log_message "Checking disk usage for $MOUNT_POINT before unmounting..."
# Use df and grab the last line to avoid the header, then awk to get the 5th column (Use%)
DISK_USAGE_PERCENT=$(df "$MOUNT_POINT" | tail -n 1 | awk '{print $5}')
if [ -n "$DISK_USAGE_PERCENT" ]; then
    DISK_USAGE_LOG_MESSAGE="Disk usage on $MOUNT_POINT is $DISK_USAGE_PERCENT."
    log_message "$DISK_USAGE_LOG_MESSAGE"
else
    DISK_USAGE_LOG_MESSAGE="Could not determine disk usage for $MOUNT_POINT."
    log_message "WARNING: $DISK_USAGE_LOG_MESSAGE"
fi

# 7. Unmount the drive at the end of the script (same as previous version)
UMOUNT_MESSAGE_DETAIL=""
log_message "Attempting to unmount $MOUNT_POINT..."
if ! sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
    UMOUNT_STATUS=$?
    log_message "ERROR: Failed to unmount $MOUNT_POINT (Exit code: $UMOUNT_STATUS). It might be in use."
    UMOUNT_MESSAGE_DETAIL="Additionally, failed to unmount $MOUNT_POINT (Code: $UMOUNT_STATUS)."
    if [ "$EMAIL_SUBJECT_STATUS" == "SUCCESS" ]; then # If rsync was OK but unmount failed
        EMAIL_SUBJECT_STATUS="COMPLETED WITH UNMOUNT ISSUE"
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=100; fi # Custom exit code for unmount error
    fi
else
    log_message "$MOUNT_POINT unmounted successfully."
    UMOUNT_MESSAGE_DETAIL="Backup drive unmounted successfully."
fi


# 8. Send Email Notification via Proxmox Mail Forwarder
log_message "Preparing email notification..."

EMAIL_SUBJECT_PREFIX="[$SCRIPT_NAME]"
EMAIL_SUBJECT="$EMAIL_SUBJECT_PREFIX: $EMAIL_SUBJECT_STATUS"

# Construct email body
EMAIL_BODY="Script execution finished.\n"
EMAIL_BODY+="Rsync Status: $RSYNC_MESSAGE_DETAIL\n"
# *** NEW *** Add disk usage info to the email body
if [ -n "$DISK_USAGE_LOG_MESSAGE" ]; then
    EMAIL_BODY+="$DISK_USAGE_LOG_MESSAGE\n"
fi
if [ -n "$UMOUNT_MESSAGE_DETAIL" ]; then # Add unmount status if it's set
    EMAIL_BODY+="Unmount Status: $UMOUNT_MESSAGE_DETAIL\n"
fi

# Ensure proxmox-mail-forward exists and is executable
PROXMOX_MAILER="/usr/bin/proxmox-mail-forward"
if [ -x "$PROXMOX_MAILER" ]; then
    log_message "Sending email notification to $EMAIL_RECIPIENT..."
    # Use printf for safer body construction, especially if variables could contain special characters for echo -e
    printf "Subject: %s\n\n%s" "$EMAIL_SUBJECT" "$EMAIL_BODY" | sudo "$PROXMOX_MAILER" "$EMAIL_RECIPIENT"
    if [ $? -eq 0 ]; then
        log_message "Email notification initiated successfully via $PROXMOX_MAILER."
    else
        MAIL_SEND_STATUS=$?
        log_message "ERROR: Failed to send email notification using $PROXMOX_MAILER (Exit code: $MAIL_SEND_STATUS)."
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=102; fi
    fi
else
    log_message "ERROR: $PROXMOX_MAILER not found or not executable. Cannot send email notification."
    if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=103; fi
fi


log_message "======= $SCRIPT_NAME Script Finished ======="
echo "" >> "$LOG_FILE"

exit $FINAL_EXIT_CODE
