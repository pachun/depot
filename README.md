# depot

A self-hosted home media server built to run on a [nas device](https://en.wikipedia.org/wiki/Network-attached_storage), streaming a library of movies and shows which also lets us browse and download new shows that are available now, or as new episodes are released.

My nas hardware hasn't arrived yet, so these steps are being tested on a
Framework laptop until the nas arrives. Wherever the two differ, steps are tagged **(nas)**
or **(framework)**.

## 1. [Download the Arch ISO](https://archlinux.org/download/).

## 2. Create a bootable USB

### On an Arch Machine

Find the USB device. It'll be something like `/dev/sda` — make sure
you've got the whole device, not a partition like `/dev/sda1`:

```
lsblk
```

Flash the ISO. Replace `/dev/sdX` with the device from above — the
wrong path wipes the wrong disk. Replace the filename with the actual
downloaded ISO name (it includes the date):

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

Flash (note `rdisk` — raw access, much faster). Replace the filename with
the actual downloaded ISO name:

```
cd ~/Downloads
sudo dd if=archlinux-VERSION-x86_64.iso of=/dev/rdiskN bs=4m
```

## 3. (nas) Plug in a monitor and keyboard

The nas is normally headless, but the install needs visible output. Plug
a USB keyboard into one of the USB ports and a monitor into the HDMI
port.

## 4. (nas) Disable the vendor watchdog in BIOS

The nas ships with a watchdog service that force-reboots every 3 minutes
unless it hears from the vendor OS. Without disabling it, our install
gets killed partway through.

- Power on while spamming **Ctrl + F12** to enter BIOS
- Find and disable the Watchdog service
- Save and exit

## 5. Boot from USB

Plug the USB drive into the device.

- **(nas)** Power on, spam **Ctrl + F12**, pick the USB stick from the
  boot menu.
- **(framework)** Power on, spam **F12**, select "Arch Linux install
  medium".

## 6. Connect to the network

- **(nas)** Plug the nas into the router with an ethernet cable. Wired ethernet auto-DHCPs. Nothing to do.
- **(framework)** WiFi:

  ```
  iwctl --passphrase "NETWORK_PASSWORD" station wlan0 connect "NETWORK_NAME"
  ```

## 7. Run archinstall

```
archinstall
```

Work through the menu top to bottom. Anything not listed below, take the
default:

- **Mirrors and Repositories** → United States
- **Disk Configuration** → Use best-effort → Select the OS drive only
  → ext4 → No separate /home. If asked about encryption: skip.
  - **(nas)** the OS drive is the M.2 NVMe. **Do not** select any of
    the 4 HDDs — they become the data pool later.
  - **(framework)** the OS drive is the built-in SSD.
- **Hostname**:
  - **(nas)** `depot`
  - **(framework)** `depot-fw`
- **Authentication** → set a root password, create user
  `whatever-username` with sudo
- **Profile** → Minimal
- **Network Configuration** → NetworkManager
- **Timezone** → your timezone

Install and reboot.

## 8. First boot

Sign in as `whatever-username`.

- **(framework)** Reconnect to WiFi:

  ```
  nmtui
  ```

## 9. Set up SSH access

```
sudo pacman -S openssh
sudo systemctl enable --now sshd
```

Find the IP address. Look for the active network interface — wired is
probably `eno1` or `enp...`, WiFi is probably `wlan0` or `wlp...`, not
`lo`:

```
ip -4 addr show
```

From any other machine on the same network:

```
ssh whatever-username@<ip-address>
```

Type `yes` the first time to accept the host key. Continue the rest of
the steps from this SSH session.

- **(nas)** Unplug the monitor and keyboard.
- **(framework)** Leave the laptop sitting open and continue on the other machine.

## 10. Add SSH key to GitHub

Generate a key:

```
ssh-keygen -t ed25519 -C "your@email.address"
```

Press Enter to accept the default path and skip the passphrase.

Print the public key:

```
cat ~/.ssh/id_ed25519.pub
```

Copy the output and [add it to GitHub](https://github.com/settings/ssh/new).

## 11. Clone and install

```
sudo pacman -S git
git clone git@github.com:pachun/depot.git ~/code/depot
cd ~/code/depot
./install.sh
```

`install.sh` is idempotent — re-run after editing configs to apply
changes.
