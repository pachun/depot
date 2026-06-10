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

## 15. Run configure.sh

```
cd ~/code/depot
./setup/configure.sh
```

Sets up the services this NAS exists to provide — tailscale (joins
the tailnet), and eventually jellyfin, samba, and the arr stack. Run
from this SSH session rather than the local TTY so anything browser-
based (tailscale's auth URL, future OAuth flows) is one paste into
your laptop's browser instead of a phone-typing exercise.

Idempotent — re-run any time. Each feature only does work that isn't
already done (tailscale skips `tailscale up` if you're already on
the tailnet, etc.).

When the script finishes it prints a URL for every service it brought
up. Each service needs a one-time first-run setup in its web UI; the
steps below walk through it in dependency order. Re-runs of
configure.sh don't undo any of it, so you only do this once per fresh
install.

### Jellyfin (port 8096)

1. Open the URL `configure.sh` printed for Jellyfin in your browser.
2. Setup wizard: pick a language, then create an admin user.
3. Add a library named **Movies**:
   - Content Type: Movies
   - Folder: `/media/movies`
4. Add a library named **Shows**:
   - Content Type: Shows
   - Folder: `/media/shows`
5. Open the admin dashboard (hamburger menu top-left → Dashboard).
6. **Libraries → Shows → "Manage Library"** → expand **Advanced** →
   **Enable real time monitoring** → OK.
7. **API Keys → "+"** → name it `sonarr` → OK. Copy the generated
   key; Sonarr needs it in a later step.

### qBittorrent (port 8080)

1. Sign in as `admin` + the **Temporary admin password**
   `configure.sh` printed (rotates on every container restart, so
   only valid for the current session).
2. **Tools → Options → Web UI → Authentication**: set a permanent
   Username and Password. Save → sign back in.

The listening port (the ProtonVPN NAT-PMP forwarded port) is
auto-synced by gluetun's UP_COMMAND hook — you'll see it under
`Gluetun:` in `configure.sh`'s summary and Tools → Options →
Connection → "Port used for incoming connections" already reflects
it. configure.sh pre-seeds qBittorrent.conf on first install with
**Bypass authentication for clients on localhost** = on, which is
what lets the hook talk to qBittorrent's API without credentials.
Don't turn that bypass off in WebUI → Authentication unless you're
prepared to paste port numbers in by hand on every gluetun
reconnect.

### Prowlarr (port 9696)

1. First-launch screen: choose **Forms (Login Page)** authentication
   → create a Prowlarr admin user. Use a fresh username/password
   just for Prowlarr — *not* your tracker login.
2. Add IPTorrents as an indexer:
   - **Indexers → "+"** → search **IPTorrents** → select it.
   - To get the cookie + user-agent:
     1. Open https://iptorrents.com in your browser, log in.
     2. DevTools (F12) → Network tab → reload the page.
     3. Click the first request → Headers → Request Headers.
     4. Copy the values of the `Cookie:` and `User-Agent:` lines.
   - Paste both into Prowlarr's matching fields → Test → Save.
   - Note: the cookie expires periodically. When IPTorrents searches
     start failing weeks/months later, re-grab the same way.

### Sonarr (port 8989)

1. First-launch screen: choose **Forms (Login Page)** authentication
   → create a Sonarr admin user.
2. **Settings → Media Management → Root Folders → "+"** → `/shows`.
3. **Settings → Download Clients → "+" → qBittorrent**:
   - Host: `host.docker.internal`
   - Port: `8080`
   - Username/Password: what you set in qBittorrent step 2
   - Category: `tv`
   - Test → Save.
4. **Settings → General**: toggle **Show Advanced Settings**
   (top-right), scroll to **Security**, copy the **API Key**. Prowlarr
   needs it in the next section.
5. **Settings → Profiles → Release Profiles → "+"**:
   - Must Not Contain: `Complete.Season`, `Season.Pack`,
     `Complete.Series`
   - Indexer: Any
   - Enabled: on
   - Save. Forces individual-episode grabs so Jellyfin imports each
     episode independently rather than waiting for a season pack to
     finish.
6. **Settings → Connect → "+" → Emby (Jellyfin)** (Jellyfin uses
   Emby's API):
   - Host: `host.docker.internal`
   - Port: `8096`
   - API Key: paste the Jellyfin key from the Jellyfin section
   - Send Library Updates: on
   - Notification Triggers: On Import, On Upgrade, On Rename
   - Test → Save. Every Sonarr import now triggers an immediate
     Jellyfin library scan.

### Radarr (port 7878)

Mirror of Sonarr for movies.

1. First-launch screen: choose **Forms (Login Page)** authentication
   → create a Radarr admin user.
2. **Settings → Media Management → Root Folders → "+"** → `/movies`.
3. **Settings → Download Clients → "+" → qBittorrent**:
   - Host: `host.docker.internal`
   - Port: `8080`
   - Username/Password: same as the Sonarr step
   - Category: `movies`
   - Test → Save.
4. **Settings → General**: toggle **Show Advanced Settings**, scroll
   to **Security**, copy the **API Key**. Prowlarr needs it next.
5. **Settings → Connect → "+" → Emby (Jellyfin)**:
   - Host: `host.docker.internal`
   - Port: `8096`
   - API Key: same Jellyfin key Sonarr uses (one key works for both)
   - Send Library Updates: on
   - Notification Triggers: On Import, On Upgrade, On Rename
   - Test → Save.

### Back to Prowlarr to wire Sonarr and Radarr (port 9696)

1. **Settings → Apps → "+" → Sonarr**:
   - Prowlarr Server: `http://host.docker.internal:9696`
   - Sonarr Server:   `http://host.docker.internal:8989`
   - API Key: paste the Sonarr API key
   - Sync Categories: defaults
   - Test → Save.
2. **Settings → Apps → "+" → Radarr**:
   - Prowlarr Server: `http://host.docker.internal:9696`
   - Radarr Server:   `http://host.docker.internal:7878`
   - API Key: paste the Radarr API key
   - Sync Categories: defaults
   - Test → Save.
3. Verify: in Sonarr and Radarr → **Settings → Indexers**, IPTorrents
   appears in both (marked managed by Prowlarr). Don't edit there —
   edit in Prowlarr and changes sync.

### Jellyfin: enable real-time monitoring on Movies

Same step you ran for Shows during Jellyfin setup, now repeated:

1. Admin dashboard → **Libraries → Movies → "Manage Library"** →
   expand **Advanced** → **Enable real time monitoring** → OK.

### Jellyseerr (port 5055)

The discovery and request UI. Walks you through Jellyfin + Sonarr +
Radarr connections in a single wizard at first launch.

1. **Welcome screen → Sign in to Jellyfin**:
   - Jellyfin URL: `http://host.docker.internal:8096`
   - Username + password: your Jellyfin admin user (the one you
     created during the Jellyfin wizard)
2. **Configure Jellyfin**:
   - Confirm both libraries (Movies, Shows) are detected
   - Click Start Scan → Continue
3. **Add Sonarr server**:
   - Default Server: ✓ on (4K Server: off)
   - Server Name: `Sonarr`
   - Hostname: `host.docker.internal`
   - Port: `8989`
   - API Key: paste the Sonarr key
   - Quality Profile: pick your default (e.g. `HD-1080p`)
   - Root Folder: `/shows`
   - Language Profile: defaults
   - Enable Scan: on
   - Test → Save.
4. **Add Radarr server**:
   - Same shape but Port: `7878`, API Key: Radarr key, Root Folder:
     `/movies`.
   - Test → Save.
5. **Finish setup** — Jellyseerr lands on its home page with
   trending content.

After this the stack is fully wired. From Jellyseerr you can search,
browse, and click Request on any movie or TV show; Jellyseerr hands
the request to Sonarr/Radarr, which grab it via Prowlarr/IPTorrents
and qBittorrent, and the file lands in Jellyfin within minutes of
download completion.
