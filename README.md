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
re-run after editing configs to apply changes. When it finishes, you're
dropped into zsh.

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
