# depot

A self-hosted home media server built to run on a [nas device](https://en.wikipedia.org/wiki/Network-attached_storage).

## 1. [Download the Arch ISO](https://archlinux.org/download/).

## 2. Create a bootable USB

Plug in the USB device.

Find it's name (It'll be something like `/dev/sda`, not a partition like `/dev/sda1`):

```
lsblk
```

Flash the ISO (replacing `/dev/sdX` and `filename.iso`):

```
cd ~/downloads
sudo dd if=filename.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## 3. Disable vendor watchdog in BIOS

The nas ships with a watchdog service that force-reboots every 3 minutes
unless it hears from the vendor OS. Without disabling it, our install
gets killed partway through.

- Power on while spamming **Ctrl + F12** to enter BIOS
- Find and disable the Watchdog service
- Save and exit

## 4. Boot from USB

- Plug the nas into the router with an ethernet cable
- Power on while spamming **Ctrl + F12**
- Choose the USB stick from the boot menu

## 5. Install Arch

```
pacman -Sy --noconfirm git
git clone https://github.com/pachun/depot /tmp/depot
bash /tmp/depot/setup/bootstrap.sh
```

You'll be asked some new-machine-setup-type questions.

After an automatic reboot, sign in.

## 6. Configure Arch

```
cd ~/code/depot && ./setup/install.sh
```

## 7. SSH in from your main machine

The prior step printed an ssh command at the end. Run it from another machine
to continue the installation from a more familiar machine in a more comfortable
place.

You can unplug the monitor and keyboard from the nas.

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
3. Copy it onto the NAS: `scp ~/Downloads/proton.conf nick@framework-depot:/tmp/proton.conf`

## 11. Enable Tailscale HTTPS certificates

1. Open https://login.tailscale.com/admin/dns.
2. Under **HTTPS Certificates**, click **Enable HTTPS…**.

## 12. Sign up for [Frugal Usenet](https://www.frugalusenet.com) and [NZBGeek](https://nzbgeek.info)

## 13. Sign up for [IPTorrents](https://iptorrents.com)

## 14. Install aviary and supporting services

```
cd ~/code/depot && ./setup/configure.sh
```

You'll be prompted for:

- An admin username and password
- A Frugal Usenet username and passsword
- An NZBGeek API key
- IPTorrents credentials
- The path to your wireguard config (`/tmp/proton.conf`)

You'll be shown tailscale addresses for the added services:

- Jellyfin
- qBittorrent
- Prowlarr
- SABnzbd
- Sonarr
- Radarr
- Jellyseerr
- Aviary

**`configure.sh` is idempotent**. Re-run it any time.

## 15. Open Aviary in your browser

Sign in with the admin credentials from earlier
