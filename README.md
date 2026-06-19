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
/tmp/depot/install/arch
```

After reboot, sign in.

## 5. (Optional) Enable SSH for the rest of the install

depot doesn't depend on ssh, but it's a lot nicer to copy a ProtonVPN .conf onto the NAS and run the rest of the install from a laptop than from a single TTY.

```
sudo pacman -S --needed --noconfirm openssh
sudo systemctl enable --now sshd
ip -4 -br addr show | grep -v lo
```

That last line prints your LAN IP. From your laptop: `ssh <username>@<lan-ip>`.

## 6. Get a ProtonVPN WireGuard config

qBittorrent's torrent traffic is routed through ProtonVPN (via a gluetun container) so your ISP can't see what's being seeded.

You need a paid ProtonVPN plan (the free tier blocks P2P). Then:

1. Sign in at https://account.protonvpn.com/downloads.
2. **WireGuard configuration**:
   - tick **NAT-PMP (Port Forwarding)** (required for inbound peers)
   - pick a P2P-capable server
   - Create → Download → you get a `.conf` file.
3. Copy it onto the NAS: `scp ~/Downloads/proton.conf <username>@<lan-ip>:/tmp/proton.conf`

## 7. Enable Tailscale HTTPS certificates

1. Open https://login.tailscale.com/admin/dns.
2. Under **HTTPS Certificates**, click **Enable HTTPS…**.

## 8. Install orchard

[Orchard](https://github.com/pachun/orchard) is the dotfile setup depot uses for familiarity when SSHing into the NAS (zsh + .zshrc.d, nvim with pre-warmed plugins, tmux, mise, git config, …).

```
~/code/depot/install/orchard
```

Re-run `./update_orchard` any time to pull and re-apply.

## 9. Install depot

```
~/code/depot/install/depot
```

`install/depot` reads top-to-bottom: function defs, prompts (all up front so you can walk away), then the work in explicit order, then a summary. It's idempotent — re-run it any time. To rotate a credential, edit the relevant env file under `~/hdds/.config/depot/` and re-run.

## 10. Open Aviary in your browser

The summary printed at the end of `install/depot` lists every service's tailnet URL. Aviary is the one at `https://<hostname>.<tailnet>.ts.net` (no port suffix). Sign in with the admin credentials you set during prompts.

## Updating

- `./update_orchard` — pull and re-apply orchard dotfiles
- `./update_aviary` — pull new aviary code, rebuild the container, run migrations
- `./install/depot` — rerun the whole thing; it's idempotent
