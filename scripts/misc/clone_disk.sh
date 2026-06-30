#!/bin/bash

# =================================================================
#  Multi-Drive Disk Offload Script with Capacity & State Tracking
# =================================================================
#  Syntax: sudo ./clone_disk.sh <source_dir>
#  Example: sudo ./clone_disk.sh /mnt/frigate_backups/recordings
# =================================================================

# --- Configuration ---
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEST_DIRS=("/mnt/backup-0" "/mnt/backup-1")
EMAIL_RECIPIENT="your-email@gmail.com"
LOG_FILE="/var/log/clone_disk.log"

send_email() {
    local subject="$1"
    local body="$2"

    printf '%b\n' "$body" | mail -s "$subject" "$EMAIL_RECIPIENT"
}

# Send all output to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Argument & Pre-run Checks ---
if [ "$#" -ne 1 ]; then
  echo "Error: Incorrect number of arguments supplied."
  echo "Usage: $0 <source_directory>"
  exit 1
fi

# Remove trailing slash if present
SOURCE_MNT="${1%/}" 

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root. Please use sudo."
   exit 1
fi

if [ ! -d "$SOURCE_MNT" ]; then
    echo "Error: Source directory $SOURCE_MNT does not exist."
    exit 1
fi

# Extract the base directory name (e.g., 'recordings' from '/mnt/frigate_backups/recordings')
BASE_DIR_NAME=$(basename "$SOURCE_MNT")

# --- Main Script Logic ---
echo "Starting multi-drive offload process from $SOURCE_MNT..."

# Set up tracking file on the source drive
TRACKING_FILE="$SOURCE_MNT/.offload_tracking.log"
touch "$TRACKING_FILE"

# 10GB safety buffer (in KB)
BUFFER_KB=10485760 

# Track which destination drive we are currently using
DEST_INDEX=0
CURRENT_DEST="${DEST_DIRS[$DEST_INDEX]}"

echo "Initial destination set to: $CURRENT_DEST"

for DIR in "$SOURCE_MNT"/*; do
    
    # Skip standard files or lost+found; we only want directories
    if [ ! -d "$DIR" ] || [[ "$DIR" == *"lost+found"* ]]; then
        continue
    fi
    
    DIR_NAME=$(basename "$DIR")
    
    # Check if already offloaded
    if grep -q "^${DIR_NAME}$" "$TRACKING_FILE"; then
        echo "Skipping $DIR_NAME - Already offloaded."
        continue
    fi

    echo "---"
    echo "Evaluating $DIR_NAME..."

    # Get directory size in KB
    DIR_SIZE_KB=$(du -sk "$DIR" | cut -f1)
    REQUIRED_SPACE_KB=$((DIR_SIZE_KB + BUFFER_KB))
    
    # Loop to find a destination drive with enough space
    while true; do
        if [ ! -d "$CURRENT_DEST" ]; then
            echo "Error: Destination $CURRENT_DEST is not accessible."
            exit 1
        fi

        AVAIL_SPACE_KB=$(df -k "$CURRENT_DEST" | awk 'NR==2 {print $4}')
        
        if [ "$REQUIRED_SPACE_KB" -lt "$AVAIL_SPACE_KB" ]; then
            echo "Space check passed on $CURRENT_DEST."
            echo "Directory Size: $((DIR_SIZE_KB / 1024 / 1024)) GB | Available Space: $((AVAIL_SPACE_KB / 1024 / 1024)) GB"
            break 
        else
            echo "Destination $CURRENT_DEST is full or cannot fit $DIR_NAME."
            echo "Required: $((REQUIRED_SPACE_KB / 1024 / 1024)) GB | Available: $((AVAIL_SPACE_KB / 1024 / 1024)) GB"
            
            DEST_INDEX=$((DEST_INDEX + 1))
            
            if [ "$DEST_INDEX" -ge "${#DEST_DIRS[@]}" ]; then
                SUBJECT="Action Required: All Destination Drives Full"
                BODY="The offload process has filled all available destination drives.\nIt paused before copying $DIR_NAME.\n\nPlease mount new drives and update the script."
                
                send_email "$SUBJECT" "$BODY"
                echo "Out of destination drives. Exiting gracefully."
                exit 0
            fi
            
            CURRENT_DEST="${DEST_DIRS[$DEST_INDEX]}"
            echo "Switching to next destination drive: $CURRENT_DEST..."
        fi
    done

    # Create the base directory on the destination (e.g., /mnt/backup-0/recordings)
    TARGET_DEST="$CURRENT_DEST/$BASE_DIR_NAME"
    mkdir -p "$TARGET_DEST"

    # Run rsync to the selected target directory
    echo "Starting rsync for $DIR_NAME to $TARGET_DEST..."
    if rsync -ah --info=progress2 "$DIR" "$TARGET_DEST/"; then
        echo "Successfully copied $DIR_NAME."
        echo "$DIR_NAME" >> "$TRACKING_FILE"
    else
        echo "Rsync failed for $DIR_NAME. Check $LOG_FILE for details."
        send_email "Error: Offload Failed" "Rsync failed for $DIR_NAME"
        exit 1
    fi

done

# If the loop finishes naturally, everything has been synced
SUBJECT="Success: Full Offload Complete"
BODY="All directories from the 8TB drive have been successfully offloaded to your backup drives. The tracking file shows no directories left to sync."
send_email "$SUBJECT" "$BODY"

echo "Offload complete for all directories."
exit 0
