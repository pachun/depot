<p align="center">
  <img src="depot.png" alt="depot" width="400" />
</p>

# depot

A self-hosted home media server built to run on a [UGreen NAS](https://www.ugreen.com/).

## 1. [Download the Arch ISO](https://archlinux.org/download/)

## 2. Create a bootable USB drive

Plug the USB drive into your machine.

Find its name (Something like `/dev/sda`, not a partition like `/dev/sda1`):

```
lsblk
```

Flash the ISO (replacing `/dev/sdX` and `filename.iso`):

```
cd ~/downloads
sudo dd if=filename.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## 3. Prevent recurring shutdowns

UGreen's preconfigured watchdog reboots every 180 seconds unless it detects the vendored OS and we run Arch.

- Power on while spamming **Ctrl + F12** to enter GRUB
- Press `c` to open a console
- Run `fwsetup` to reboot into the BIOS
- Go to **Advanced** → **Watchdog** and disable it
- Save and exit

## 4. Boot from USB drive

- Plug the USB drive into the NAS
- Power on while spamming **Ctrl + F12**
- Press `c` to open a console
- Go to **Boot** → **Boot Option 1** → Press **Enter** → Select bootable USB drive
- Save and exit

The machine will restart and boot into the live Arch ISO.

## 5. Install Arch

```
pacman -Sy --noconfirm git
git clone https://github.com/pachun/depot /tmp/depot
bash /tmp/depot/setup/bootstrap.sh
```

After an automatic reboot, sign in.

## 6. Configure Arch

```
cd ~/code/depot && ./setup/install.sh
```

## 7. SSH into the NAS from your favorite machine

The prior step prints an SSH command. Run it from your favorite machine to continue from there.

## 8. SSH-authenticate with GitHub

```
ssh-keygen -t ed25519 -C "your@email.address" # leave prompts blank
cat ~/.ssh/id_ed25519.pub
```

Copy the output and [add it to GitHub](https://github.com/settings/ssh/new).

## 9. Switch repo remotes to SSH

```
git -C ~/code/depot   remote set-url origin git@github.com:pachun/depot.git
git -C ~/code/orchard remote set-url origin git@github.com:pachun/orchard.git
```

From here on, re-running `./setup/install.sh` pulls the latest changes
from both repos and applies them.

## 10. Get a ProtonVPN WireGuard config

qBittorrent's torrent traffic is routed through ProtonVPN (via a
gluetun container) so your ISP can't see what's being seeded.

You need a paid ProtonVPN plan (the free tier blocks P2P). Then:

1. Sign in at https://account.protonvpn.com/downloads.
2. **WireGuard configuration**:
   - tick **NAT-PMP (Port Forwarding)** (required for inbound peers)
   - pick a P2P-capable server
   - Create → Download → you get a `.conf` file.
3. Copy it onto the NAS: `scp ~/Downloads/proton.conf <admin-username>@<tailscale-address>:/tmp/proton.conf`

## 11. Enable Tailscale HTTPS certificates

1. Open https://login.tailscale.com/admin/dns.
2. Under **HTTPS Certificates**, click **Enable HTTPS…**.

## 12. Sign up for [Frugal Usenet](https://www.frugalusenet.com) and [NZBGeek](https://nzbgeek.info)

## 13. Sign up for [IPTorrents](https://iptorrents.com)

## 14. Install aviary and supporting services

```
cd ~/code/depot && ./setup/configure.sh
```

**`configure.sh` is idempotent**. Re-run it any time.

## 15. Open Aviary in your browser

Sign in with the admin credentials from earlier.
