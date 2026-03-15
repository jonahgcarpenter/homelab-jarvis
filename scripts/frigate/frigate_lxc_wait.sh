#!/bin/bash

# --- Configuration ---
CT_ID="101"
REQUIRED_MOUNT="/mnt/frigate"
DELAY_SECONDS=120 # The delay in seconds between each check.

echo "--- Starting LXC startup wait script for CT ${CT_ID} ---"

# First, check if the container is already running. If it is, we don't need to do anything.
if pct status ${CT_ID} >/dev/null 2>&1 && pct status ${CT_ID} | grep -q "status: running"; then
    echo "Container ${CT_ID} is already running. Exiting."
    exit 0
fi

echo "Waiting indefinitely for mount point '${REQUIRED_MOUNT}' to become available..."

# Loop forever until the mount point is found.
while true; do
    # Use the 'mountpoint' command to check if the directory is a mount point.
    # The '-q' flag makes it quiet, and it returns an exit code of 0 on success.
    if mountpoint -q "${REQUIRED_MOUNT}"; then
        echo "Success! Mount point '${REQUIRED_MOUNT}' is active."
        echo "Proceeding to start container ${CT_ID}..."

        # Try to start the container.
        if pct start ${CT_ID}; then
            echo "Container ${CT_ID} started successfully. Script will now terminate."
            exit 0 # Exit the script with a success code.
        else
            echo "Error: Failed to start container ${CT_ID} even though mount point was ready."
            exit 1 # Exit with a failure code.
        fi
    fi

    # If the script reaches here, the mount was not ready.
    # It will wait and then the loop will run again.
    sleep ${DELAY_SECONDS}
done
