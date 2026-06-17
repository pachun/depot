<p align="center">
  <img src="depot.png" alt="depot" width="400" />
</p>

# depot

A self-hosted home media server built to run on a [UGreen NAS](https://www.ugreen.com/).

## 1. Create a bootable USB drive

[Download the Arch ISO](https://archlinux.org/download/)

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

## 2. Prevent recurring NAS shutdowns

UGreen's preconfigured watchdog reboots every 180 seconds unless it detects the vendored OS and we run Arch.

- Power on while spamming **Ctrl + F12** to enter GRUB
- Press `c` to open a console
- Run `fwsetup` to reboot into the BIOS
- Go to **Advanced** → **Watchdog** and disable it
- Save and exit

## 3. Boot from the USB drive

- Plug the USB drive into the NAS
- Power on while spamming **Ctrl + F12**
- Press `c` to open a console
- Go to **Boot** → **Boot Option 1** → Press **Enter** → Select bootable USB drive
- Save and exit

The machine will restart and boot into the live Arch ISO.

## 4. Install Arch

```
pacman -Sy --noconfirm git
git clone https://github.com/pachun/depot /tmp/depot
bash /tmp/depot/arch/install.sh
```

After an automatic reboot, sign in.

## 5. Configure Arch

```
cd ~/code/depot && ./arch/configure.sh
```

## 6. SSH into the NAS from your favorite machine

The prior step prints an SSH command. Run it from your favorite machine to continue from there.

## 7. SSH-authenticate with GitHub

```
ssh-keygen -t ed25519 -C "your@email.address" # leave prompts blank
cat ~/.ssh/id_ed25519.pub
```

Copy the output and [add it to GitHub](https://github.com/settings/ssh/new).

## 8. Switch repo remotes to SSH

```
git -C ~/code/depot   remote set-url origin git@github.com:pachun/depot.git
git -C ~/code/orchard remote set-url origin git@github.com:pachun/orchard.git
```

Re-running `./arch/configure.sh` now pulls and applies the latest from both repos.

## 9. Get a ProtonVPN WireGuard config

qBittorrent's torrent traffic is routed through ProtonVPN (via a
gluetun container) so your ISP can't see what's being seeded.

You need a paid ProtonVPN plan (the free tier blocks P2P). Then:

1. Sign in at https://account.protonvpn.com/downloads.
2. **WireGuard configuration**:
   - tick **NAT-PMP (Port Forwarding)** (required for inbound peers)
   - pick a P2P-capable server
   - Create → Download → you get a `.conf` file.
3. Copy it onto the NAS: `scp ~/Downloads/proton.conf <admin-username>@<tailscale-address>:/tmp/proton.conf`

## 10. Enable Tailscale HTTPS certificates

1. Open https://login.tailscale.com/admin/dns.
2. Under **HTTPS Certificates**, click **Enable HTTPS…**.

## 11. Sign up for [Frugal Usenet](https://www.frugalusenet.com) and [NZBGeek](https://nzbgeek.info)

## 12. Sign up for [IPTorrents](https://iptorrents.com)

## 13. Install depot

```
cd ~/code/depot && ./services/configure.sh
```

**`services/configure.sh` is idempotent**. Re-run it any time.

## 14. Open Aviary in your browser

Sign in with the admin credentials from earlier.
