#!/bin/bash

echo "--- Initializing Setup: Installing Dependencies ---"
apt update && apt install -y \
    build-essential \
    ffmpeg \
    wireguard \
    openresolv

DRIVER_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/580.159.03/NVIDIA-Linux-x86_64-580.159.03.run"
DRIVER_FILE="NVIDIA-driver.run"

echo "--- Checking for existing NVIDIA Drivers ---"
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA Drivers are already installed. Current status:"
    nvidia-smi -L
else
    echo "Drivers not found. Proceeding with installation..."
    
    echo "--- Downloading NVIDIA Driver ---"
    wget -O "$DRIVER_FILE" "$DRIVER_URL"
    chmod +x "$DRIVER_FILE"

    echo "--- Installing NVIDIA Driver (No-Kernel Mode) ---"
    ./"$DRIVER_FILE" --no-kernel-module --ui=none --no-questions --accept-license
    
    # Cleanup installer to save space
    rm "$DRIVER_FILE"
fi

echo ""
echo "--- Checking WireGuard Status ---"

# Check if the interface is already up
if ip link show wg0 &> /dev/null; then
    echo "WireGuard interface (wg0) is already active. Skipping setup."
else
    # Check if a config exists but isn't active
    if [ -f "/etc/wireguard/wg0.conf" ]; then
        echo "Found existing config at /etc/wireguard/wg0.conf but interface is down."
        echo "Attempting to bring up existing tunnel..."
    else
        echo "No active tunnel or configuration found."
        echo "Please paste the ENTIRE contents of your wg0.conf below."
        echo "After pasting, press ENTER then CTRL+D to save."
        echo "----------------------------------------------------"
        mkdir -p /etc/wireguard
        cat > /etc/wireguard/wg0.conf
        chmod 600 /etc/wireguard/wg0.conf
    fi

    echo "--- Bringing up WireGuard ---"
    wg-quick up wg0
    systemctl enable wg-quick@wg0
fi

# --- 4. Generating Stream Execution Script ---
echo "--- Checking for Stream Execution Script ---"

if [ -f "/root/stream.sh" ]; then
    echo "Found existing /root/stream.sh. Skipping creation to preserve changes."
else
    echo "Generating new /root/stream.sh..."
    cat << 'EOF' > /root/stream.sh
#!/bin/bash

if [ -z "$RTSP_URL" ] || [ -z "$RTMP_URL" ]; then
    echo "ERROR: RTSP_URL or RTMP_URL is not set by the service!"
    exit 1
fi

echo "Starting stream at $(date)..."

exec ffmpeg \
  -hide_banner \
  -loglevel error \
  -rtsp_transport tcp \
  -hwaccel cuvid \
  -hwaccel_output_format cuda \
  -c:v h264_cuvid \
  -i "$RTSP_URL" \
  -an \
  -c:v h264_nvenc \
  -preset p5 \
  -tune ll \
  -bf 0 \
  -g 60 \
  -keyint_min 60 \
  -b:v 4M \
  -maxrate 4M \
  -bufsize 8M \
  -f flv "$RTMP_URL"
EOF
    chmod +x /root/stream.sh
    echo "Script created successfully."
fi

echo ""
echo "--- Checking for Stream Service ---"

SERVICE_PATH="/etc/systemd/system/puppy-stream.service"

if [ -f "$SERVICE_PATH" ]; then
    echo "Found existing service at $SERVICE_PATH. Skipping configuration."
    echo "To update URLs, edit the service file manually or delete it and re-run this script."
else
    echo "Service not found. Configuring new Puppy Stream service..."
    
    read -p "Enter RTSP Source URL: " USER_RTSP
    read -p "Enter RTMP Destination URL: " USER_RTMP

    cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Puppy Stream
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="RTSP_URL=$USER_RTSP"
Environment="RTMP_URL=$USER_RTMP"
ExecStart=/root/stream.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    echo "--- Initializing Puppy Stream Service ---"
    systemctl daemon-reload
    systemctl enable --now puppy-stream.service
    echo "Service created and started."
fi

echo ""
echo "--- Final System Status ---"
systemctl is-active --quiet puppy-stream.service && echo "Puppy Stream: [ACTIVE]" || echo "Puppy Stream: [FAILED/INACTIVE]"
echo "Setup complete! Monitor your stream with: journalctl -fu puppy-stream.service"
