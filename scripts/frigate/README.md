## Frigate LXC Wait

This service is aimed to fix the smb mount timing startup errors, Instead of adding a startup delay to the container I want a more robust way to autostart the container only after the TrueNAS VM is up and running

Be sure to create the service file using and edit the ExecStart line for the path of the script

```
# Proxmox shell
nano /etc/systemd/system/frigate-lxc-wait.service

# Paste contents
[Unit]
Description=Wait for SMB Mount and Start Frigate LXC
After=network-online.target local-fs.target remote-fs.target

[Service]
Type=simple
User=root
ExecStart=/home/jonah/homelab-jarvis/scripts/frigate/frigate_lxc_wait.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Frigate Backups

Backs up frigate recordings to a unmounted drive

```
# Open Crontab as root user
crontab -e

# Paste contents
# Frigate backups, runs every day at 1am
0 1 * * * /home/jonah/homelab-jarvis/scripts/frigate/frigate_backup.sh
```
