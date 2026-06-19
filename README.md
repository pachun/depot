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

[Orchard](https://github.com/pachun/orchard) is the dotfile setup depot uses for familiarity when SSHing into the NAS (zsh + .zshrc.d, nvim with pre-warmed plugins, tmux, **mise — which provides the Ruby that `depot` runs on**, claude, git config, …).

```
~/code/depot/install/orchard
```

Re-run any time to pull and re-apply.

## 9. Make `depot` runnable from anywhere

```
~/code/depot/install/depot-cli
```

This symlinks `/usr/local/bin/depot` to the script in this repo so every subsequent `depot install` / `depot update` / `depot aviary` invocation works from any directory and any SSH session — no full path needed.

## 10. Install depot

```
depot install
```

`depot install` reads top-to-bottom: collects every service's prompts up front (so you can walk away), then brings each service up in dependency order, then prints a summary of tailnet URLs. Idempotent — re-run any time.

## 11. Open Aviary in your browser

The summary at the end of `depot install` lists every service's tailnet URL. Aviary is the one at `https://<hostname>.<tailnet>.ts.net` (no port suffix). Sign in with the admin credentials you set during prompts.

## Updating

- `./install/orchard` — pull and re-apply orchard dotfiles
- `depot update` — bring every service to current desired state (re-pulls aviary, rebuilds it, runs migrations; restarts every container)
- `depot <service>` — update just that service. E.g. `depot aviary` from anywhere on the box to pull a new aviary build without touching the others.

## File layout

```
depot/
├── depot                 ruby, the CLI tool — `depot install`/`update`/<service>
├── install/
│   ├── arch              bash, run once from the live Arch ISO
│   ├── orchard           bash, run after reboot to bring up the shell
│   └── depot-cli         bash, symlinks `depot` into /usr/local/bin
└── services/
    ├── helpers.rb        shared utilities (HTTP, prompts, shell, arr API)
    └── <name>/
        ├── <name>.rb     module with .install_prompt/.install/.update/.summary
        └── docker-compose.yml   (for services that run as containers)
```

Each service module is the spec for that service. The `depot` script's `SERVICES` array is the install order. Reading the bottom of `depot` tells you exactly what runs and in what order; reading any module tells you what installing that one service does.
