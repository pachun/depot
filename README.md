# depot

A self-hosted home media server built to run on a [nas device](https://en.wikipedia.org/wiki/Network-attached_storage), streaming a library of movies and shows which also lets us browse and download new shows that are available now, or as new episodes are released.

My nas hardware hasn't arrived yet, so these steps are being tested on a
Framework laptop until the nas arrives. Wherever the two differ, steps are tagged **(nas)**
or **(framework)**.

## 1. [Download the Arch ISO](https://archlinux.org/download/).

## 2. Create a bootable USB

### On an Arch machine

Find the USB device. It'll be something like `/dev/sda` — make sure
you've got the whole device, not a partition like `/dev/sda1`:

```
lsblk
```

Flash the ISO. Replace `/dev/sdX` with the device from above. Replace
the filename with the actual downloaded ISO name (it includes the date):

```
cd ~/downloads
sudo dd if=archlinux-VERSION-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### On macOS

Find the USB device:

```
diskutil list
```

Unmount it (replace `N` with the disk number):

```
diskutil unmountDisk /dev/diskN
```

Flash (note `rdisk` — raw access, much faster):

```
cd ~/Downloads
sudo dd if=archlinux-VERSION-x86_64.iso of=/dev/rdiskN bs=4m
```

## 3. (nas) Plug in a monitor and keyboard

The nas is normally headless, but the install needs visible output. Plug
a USB keyboard into one of the USB ports and a monitor into the HDMI
port. Both come back out after step 10 — everything from then on happens
over SSH.

## 4. (nas) Disable the vendor watchdog in BIOS

The nas ships with a watchdog service that force-reboots every 3 minutes
unless it hears from the vendor OS. Without disabling it, our install
gets killed partway through.

- Power on while spamming **Ctrl + F12** to enter BIOS
- Find and disable the Watchdog service
- Save and exit

## 5. Boot from USB

- **(nas)** Power on, spam **Ctrl + F12**, pick the USB stick from the
  boot menu.
- **(framework)** Power on, spam **F12**, select "Arch Linux install
  medium".

## 6. Connect to the network

- **(nas)** Plug the nas into the router with an ethernet cable. Wired
  ethernet auto-DHCPs. Nothing to do.
- **(framework)** WiFi:

  ```
  iwctl --passphrase "NETWORK_PASSWORD" station wlan0 connect "NETWORK_NAME"
  ```

## 7. Clone and run bootstrap

```
pacman -Sy --noconfirm git
git clone https://github.com/pachun/depot /tmp/depot
bash /tmp/depot/setup/bootstrap.sh
```

`bootstrap.sh` prompts for a username and hostname, detects the OS drive
(NVMe — SATA drives are refused so the nas's data HDDs can never be
mispicked), confirms with a `yes`, then partitions, pacstraps, configures
the new system, and reboots.

## 8. First boot

Sign in with the username and password you chose.

- **(framework)** Reconnect to WiFi:

  ```
  nmtui
  ```

- **(nas)** Wired ethernet auto-DHCPs. Nothing to do.

## 9. Run install.sh

```
cd ~/code/depot
./setup/install.sh
```

Clones orchard, sets up the CLI environment (zsh, nvim, tmux, mise,
claude, git, etc.), and enables `ufw` with SSH allowed. Idempotent —
re-run after editing configs to apply changes. When it finishes,
you're dropped into zsh and the machine is SSH-able.

Anything that needs a browser (tailscale auth, future OAuth flows)
lives in `configure.sh` (step 15) — that part runs over SSH from your
main machine so auth URLs can be copy-pasted into a real browser
instead of typed from the TTY.

## 10. SSH in from your main machine

install.sh printed the SSH command at the end of step 9 — something
like `ssh nick@192.168.1.53`. Run that from any other machine on the
same network. Type `yes` the first time to accept the host key.
Continue the remaining steps from this SSH session.

- **(nas)** Now safe to unplug the monitor and keyboard.
- **(framework)** Leave the laptop sitting open (closing the lid would
  suspend it). Continue on your main machine.

## 11. Add SSH key to GitHub

Generate a key on the new system:

```
ssh-keygen -t ed25519 -C "<username>@<hostname>"
```

Press Enter to accept the default path and skip the passphrase.

Print the public key:

```
cat ~/.ssh/id_ed25519.pub
```

Copy the output and [add it to GitHub](https://github.com/settings/ssh/new).

## 12. Switch repo remotes to SSH

depot and orchard were both cloned via HTTPS so the install would work
on a fresh box without auth. Switch them to SSH now so `git pull`
inside install.sh (and any pushes you might want) work without prompts:

```
git -C ~/code/depot   remote set-url origin git@github.com:pachun/depot.git
git -C ~/code/orchard remote set-url origin git@github.com:pachun/orchard.git
```

From here on, re-running `./setup/install.sh` pulls the latest changes
from both repos and applies them.

## 13. Get a ProtonVPN WireGuard config

qBittorrent's torrent traffic is routed through ProtonVPN (via a
gluetun container) so the ISP can't see what's being seeded. Everything
else on the box — Jellyfin streams, Sonarr/Radarr/Prowlarr/Jellyseerr
web calls, Tailscale, package updates — stays on the regular network
at LAN speed.

You need a paid ProtonVPN plan (the free tier blocks P2P). Then:

1. Sign in at https://account.protonvpn.com/downloads.
2. **WireGuard configuration**:
   - tick **NAT-PMP (Port Forwarding)** (required for inbound peers)
   - pick a P2P-capable server
   - Create → Download → you get a `.conf` file.
3. Copy it onto the NAS, e.g. from your laptop:

   ```
   scp ~/Downloads/proton.conf nick@framework-depot:/tmp/proton.conf
   ```

`configure.sh` will prompt for that path in the next step and extract
the credentials it needs. The config is persisted to
`~/library/.config/gluetun/wg.env`, so re-runs skip the prompt.

## 14. Enable Tailscale HTTPS certificates

Each service is served over HTTPS through Tailscale (no extra reverse
proxy — `tailscale serve --https=<port>` terminates TLS using a
Let's Encrypt cert tied to your tailnet FQDN, auto-renewed). For that
to work, the tailnet has to have HTTPS certificates enabled — it's a
one-time per-tailnet toggle in the admin console.

1. Open https://login.tailscale.com/admin/dns.
2. Under **HTTPS Certificates**, click **Enable HTTPS…**.

This is a no-op for tailnets created recently (it's on by default
now), but older tailnets need the toggle flipped explicitly.
configure.sh's `tailscale serve` calls will fail with a clear error
if it isn't on, so skipping this step won't silently break anything
— it just bounces back here.

## 15. Sign up for accounts before running configure.sh

`configure.sh` wires everything end-to-end via API on its own — admin
users, libraries, download clients, indexers, notifications, the
whole pipeline. The only things it can't conjure are the credentials
for third-party services. Have these handy when you run it:

1. **Frugal Usenet** (provider — ~$8/mo). Sign up at
   https://www.frugalusenet.com. Keep your newsreader username +
   password handy.
2. **NZBGeek** (indexer — ~$15/yr). Sign up at https://nzbgeek.info,
   then in your account settings → API, copy the API key.
3. **IPTorrents** (your tracker — used as a fallback when Usenet
   doesn't have a release). When you run `configure.sh` later it'll
   walk you through grabbing your browser session cookie + user-agent
   in the terminal; no need to do anything now beyond making sure
   you can log into iptorrents.com.

All credentials persist to `~/library/.config/depot/*.env` (mode
600). You enter them once during the first `configure.sh` run; every
subsequent run reads them silently. Edit those files directly to
rotate.

You can also skip any of these on a first deploy and add them later
by re-running `configure.sh` — each service skips itself gracefully
if its credentials aren't there yet.

## 16. Run configure.sh

```
cd ~/code/depot
./setup/configure.sh
```

Sets up everything. Run from this SSH session rather than the local
TTY so anything browser-based (tailscale's auth URL, the IPTorrents
cookie scrape from your laptop, etc.) is one paste into the laptop's
browser instead of a phone-typing exercise.

First run prompts for, in order:

- **Admin username** + **password** — used as the admin user across
  Jellyfin, qBittorrent, Prowlarr, Sonarr, Radarr, and Jellyseerr.
  One credential pair gets pushed to all of them.
- **Frugal Usenet** username + password.
- **NZBGeek** API key.
- **IPTorrents** browser session cookie + user-agent — the terminal
  walks you through grabbing them from your browser's DevTools.

Subsequent runs are silent — every credential file under
`~/library/.config/depot/` holds the answers.

Idempotent. Re-run any time. Each feature only does work that isn't
already done.

When the script finishes it prints a URL for every service. They are
all fully wired and ready — no web UI setup needed. What configure.sh
did automatically:

- **Jellyfin**: created admin user, Movies + Shows libraries,
  real-time monitoring on both, plus `aviary` and `sonarr` API keys
  the other services need.
- **qBittorrent**: changed default password to your admin password,
  created `tv` + `movies` categories, enabled auth-bypass for the
  docker bridge so the arrs don't have to re-authenticate every call.
- **Prowlarr**: admin user; NZBGeek (Usenet, priority 10) + IPTorrents
  (torrent, priority 25) registered as indexers; Sonarr + Radarr
  wired as Applications so the indexers propagate.
- **SABnzbd**: three Frugal servers configured (primary/secondary/
  bonus with priority 0/1/2 fallback chain); registered as a
  download client in Sonarr + Radarr.
- **Sonarr**: admin user; `/shows` root folder; qBittorrent as a
  torrent download client (SABnzbd as usenet); Jellyfin Connect
  notification; English-only language profile; custom-format ban on
  Audio Description, theater cams, descriptive narration, banned
  release groups, 2160p/4K, and HEVC/x265.
- **Radarr**: same as Sonarr but for `/movies`.
- **Jellyseerr**: admin user adopted from Jellyfin's; Jellyfin,
  Sonarr, and Radarr all wired.

Per-grab download path: Sonarr/Radarr searches all indexers in
parallel, prefers Usenet (priority 10) over torrents (priority 25) on
ties. Each grab routes to its matching download client automatically.
No ratio cost when Usenet has the release, tracker fallback when only
it does.

After this you're done. Open Aviary, sign in with your Jellyfin admin
user, watch something.

