# Setup

## You need this setting within proxmox hardware for the VM

```
# In the host shell
nano /etc/pve/qemu-server/<VMID>.conf

# Add this line under cores:
cpu: host,hidden=1,-hypervisor
```

## Install FFmpeg

```
sudo apt-get ffmpeg
```

## Setup system service

```
# Create service file
sudo nano /etc/systemd/system/puppy_stream.service

# Paste contents
[Unit]
Description=Puppy Stream Service
After=network-online.target

[Service]
User=carpenters
Group=carpenters
WorkingDirectory=/home/carpenters/puppy_stream
ExecStart=/bin/bash /home/carpenters/puppy_stream/start_stream.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
```

```
sudo systemctl enable puppy_stream.service
```
