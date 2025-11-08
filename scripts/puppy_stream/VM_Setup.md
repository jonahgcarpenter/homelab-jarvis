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
sudo systemctl daemon-reload
```

```
sudo systemctl enable puppy_stream.service
```
