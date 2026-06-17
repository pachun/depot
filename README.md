<p align="center">
  <img src="depot.png" alt="depot" width="400" />
</p>

# depot

A self-hosted home media server with a [beautiful, no-cruft UI](https://github.com/pachun/aviary).

<p align="center">
  <img src="screenshot.png" alt="aviary home page" width="100%" />
</p>

Depot runs on a [UGreen NAS](https://www.ugreen.com/), but any x86 NAS with three or more drive bays and two or more M.2 NVMe slots works. It uses one NVMe as the OS drive and a second (bought separately) for download staging, which keeps streaming smooth while downloads are in progress. The HDDs are arranged RAIDZ1. Any one drive can fail; swap in a new one and the pool rebuilds itself.

You'll also need some accounts:

- [Tailscale](https://tailscale.com) (free)
- [ProtonVPN](https://protonvpn.com) (paid ~$5/mo)
- [Frugal Usenet](https://www.frugalusenet.com) (paid ~$60/yr)
- [NZBGeek](https://nzbgeek.info) (paid ~$15/yr)
- [IPTorrents](https://iptorrents.com) (invite only)

[Email me](mailto:nick@pachulski.me) if you want an IPTorrents invite.

## 1. Create a bootable USB drive

- [Download the Arch ISO](https://archlinux.org/download/)
- Plug the USB drive into your machine.
- Find its name: run `lsblk` and look for something like `/dev/sda`, not a partition like `/dev/sda1`
- Flash the ISO: `sudo dd if=ARCH_ISO_FILE.iso of=/dev/DRIVE_NAME bs=4M status=progress oflag=sync`

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
/tmp/depot/arch/install.sh
```

After reboot, sign in.

## 5. Configure Arch

```
~/code/depot/arch/configure.sh
```

## 6. SSH into the NAS from your favorite machine

The prior step prints an SSH command. Run it from your favorite machine and continue from there.

## 7. SSH-authenticate with GitHub

```
ssh-keygen -t ed25519 -C "your@email.address"
cat ~/.ssh/id_ed25519.pub
```

Copy the output and [add it to GitHub](https://github.com/settings/ssh/new).

## 8. Switch repo remotes to SSH

```
git -C ~/code/depot   remote set-url origin git@github.com:pachun/depot.git
git -C ~/code/orchard remote set-url origin git@github.com:pachun/orchard.git
```

[Orchard](https://github.com/pachun/orchard) is my dotfile setup. Depot installs
it for familiarity when SSHing into the NAS.

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

## 11. Install depot

```
~/code/depot/services/configure.sh
```

**`services/configure.sh` is idempotent**. Re-run it any time.

## 12. Open Aviary in your browser

Sign in with the admin credentials from earlier.
