# Lume-Pi (Raspberry Pi 4 install)

This directory contains helper scripts to install and run **Lume** on a **fresh Raspberry Pi 4** (Raspberry Pi OS Lite) via SSH.

It supports two usage scenarios:

1. **Docker-only (remote browser):** run the Lume stack on the Pi, access the dashboard/player from any browser on the LAN.
2. **Docker + local player (Cog kiosk):** run the Lume stack on the Pi and also run a fullscreen local “player” browser on the Pi via **Cog**.

## What gets installed 

The Docker stack runs these services (see `lume-pi/docker/docker-compose.pi.yml`):

- **Core API (Rails)**: exposed as `http://<hostname>.local:3011`
- **Frontend (Dashboard)**: exposed as `http://<hostname>.local:3012`
- **Player (Web UI)**: exposed as `http://<hostname>.local:3014`
- **Postgres** (internal)

Systemd units created by the scripts:

- `lume-docker.service` (created by `setup-lume.sh`) – starts/stops the Docker Compose stack on boot
- `lume-browser.service` (created by `setup-player.sh`) – starts Cog kiosk on boot (optional)
- `triggerhappy.service` (created by `setup-triggerhappy.sh`) – enables Alt+F4 to exit the kiosk (optional)

## Prerequisites

- Raspberry Pi 4
- **Raspberry Pi OS Lite** (Debian-based) with **SSH enabled**
- Internet access for `apt-get` + Docker image pulls
- (Recommended) A hostname you can resolve on your LAN via **mDNS**: `something.local`

The scripts are written for Debian-like systems (Raspberry Pi OS / apt).

## Optional — Wi‑Fi hotspot (Access Point)

If you want the Pi to provide its own Wi‑Fi network (so you can connect with a phone even without LAN/Wi‑Fi), see:

- [`wifi-ap.md`](./wifi-ap.md)

Quick start (on the Pi):

```bash
cd ~/lume-pi
sudo install -m 600 -o root -g root ./wifi-ap.env.sample /etc/lume-wifi-ap.env
sudo nano /etc/lume-wifi-ap.env
sudo ./setup-wifi.sh
```

## Start point

You have a freshly installed Raspberry Pi OS Lite and can SSH into it.
You also have this `lume-pi/` directory available on your machine.

## Optional — Remote access via Tailscale (recommended)

If you want to access the Pi (SSH + the Lume web UIs) from anywhere without
opening ports on your router, install Tailscale on the Pi:

```bash
cd ~/lume-pi

# first time only (make executable)
chmod +x ./setup-tailscale.sh

# interactive login (prints a URL)
./setup-tailscale.sh
```

After joining your tailnet, use the Pi's Tailscale name/IP instead of `*.local`:

- Dashboard: `http://<tailscale-name>:3012`
- Player: `http://<tailscale-name>:3014`
- Core API health: `http://<tailscale-name>:3011/up`

## Step 1 — Copy `lume-pi/` to the Pi

From your workstation:

```bash
# Example: copy into the pi user's home directory
scp -r ./lume-pi user@<pi-ip>:~/

# or with rsync
rsync -av --delete ./lume-pi/ pi@<pi-ip>:~/lume-pi/
```

Then SSH into the Pi:

```bash
ssh pi@<pi-ip>
cd ~/lume-pi
```

## Step 2 — Create the env files (recommended)

For easier onboarding, copy the sample env files and edit them.

### 2a) Setup-time env (optional)

`lume-pi/.env` is read by `setup-lume.sh` and can hold defaults like hostname and optional Docker registry credentials.

Note: `LUME_HOSTNAME` is expected to be the *base* hostname (e.g. `lume-player`).
The kiosk player (`setup-player.sh`) will open `http://<hostname>.local:3014` by default.

```bash
cp .env.sample .env
nano .env
```

### 2b) Runtime env (required)

`lume-pi/docker/.env` is used by Docker Compose at runtime.

```bash
cp docker/.env.sample docker/.env
nano docker/.env
```

At minimum you must set:

- `POSTGRES_PASSWORD`
- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`

And you should update all URLs/origins to match your hostname (mDNS):

- `NUXT_PUBLIC_API_URL=http://<hostname>.local:3011`
- `NUXT_PUBLIC_PLAYER_URL=http://<hostname>.local:3014`
- `CORS_ALLOWED_ORIGINS=...`
- `ACTION_CABLE_ALLOWED_ORIGINS=...`

Tip: after editing, it’s easy to accidentally leave a placeholder hostname in multiple places.
Search/replace `lume-player.local` in `docker/.env` to match your chosen hostname.

## Scenario A — Docker-only (remote browser)

This installs Docker (if needed), sets hostname (optional but recommended), and installs the `lume-docker` systemd unit.

### A1) Run bootstrap

```bash
cd ~/lume-pi

# Recommended: set a hostname so LAN clients can use <hostname>.local
./setup-lume.sh --hostname lume-player
```

If you are pulling images from a private registry, run with docker login enabled:

```bash
./setup-lume.sh --hostname lume-player --docker-login
```

Notes:

- If the script adds your user to the `docker` group, you must **log out/in** (or reboot) before you can run `docker` without `sudo`.
- If you changed the hostname, reconnect SSH (or reboot) for it to fully propagate.

### A2) Check service status

```bash
sudo systemctl status lume-docker --no-pager

# Logs
journalctl -u lume-docker -f
```

### A3) Open in your browser (from another device)

- Dashboard: `http://lume-player.local:3012`
- Player: `http://lume-player.local:3014`
- Core API (health): `http://lume-player.local:3011/up`

## Scenario B — Docker + local player (Cog kiosk on the Pi)

Do Scenario A first (Docker stack running), then install the kiosk browser.

### B1) Install and enable Cog kiosk

```bash
cd ~/lume-pi
./setup-player.sh
```

This will:

- install `cog` and graphics/DRM dependencies
- enable full KMS (`dtoverlay=vc4-kms-v3d`)
- write `/etc/lume-browser.conf`
- install and enable `lume-browser.service`

Reboot is recommended after KMS changes:

```bash
sudo reboot
```

### B2) Troubleshooting Cog / video output

The kiosk config is here:

- `/etc/lume-browser.conf`

If the browser does not appear after reboot, try switching DRM device:

```bash
sudo nano /etc/lume-browser.conf
# change
#   DRM_DEVICE=/dev/dri/card1
# to
#   DRM_DEVICE=/dev/dri/card0

sudo systemctl restart lume-browser
```

Logs:

```bash
journalctl -u lume-browser -f
```

## Optional — Screen control (DDC/CI)

If you want to control monitor power/brightness (DDC/CI), run:

```bash
cd ~/lume-pi
./setup-screen-control.sh
```

If a DDC/CI capable display is detected, it installs:

- `/usr/local/bin/lume-display-control`

Usage:

```bash
lume-display-control bright 50
lume-display-control off
lume-display-control on
```

## Optional — Alt+F4 to exit the kiosk (Triggerhappy)

If the Pi is running the local kiosk (`lume-browser.service`) and you want a way to **quit it locally**,
you can install a small hotkey daemon that listens to keyboard events.

This adds:

- **Alt+F4** → `systemctl stop lume-browser.service` and `systemctl start getty@tty1.service`

Install (on the Pi):

```bash
cd ~/lume-pi
./setup-triggerhappy.sh
```

Rollback:

```bash
sudo rm -f /etc/triggerhappy/triggers.d/lume.conf
sudo rm -f /etc/sudoers.d/lume-quit-kiosk
sudo systemctl restart triggerhappy
```

## Updating an existing install

On the Pi:

```bash
cd ~/lume-pi
./update-lume.sh
```

Optional flags:

- `--docker-login` (does `docker login` before pulling)
- `--no-systemd` (run docker compose directly even if the systemd unit exists)

## Useful commands

```bash
# Service control
sudo systemctl restart lume-docker
sudo systemctl restart lume-browser

# Compose status (uses your runtime env)
cd ~/lume-pi/docker
docker compose --env-file .env -f docker-compose.pi.yml ps
```

## Optional — Send a screenshot/image via Telegram

This repo does not auto-configure Telegram, but it includes a helper script:

```bash
cd ~/lume-pi

# Add credentials (recommended: keep secrets in file, not on CLI)
nano .env

# Send any image
./send-image.sh ./screen.png

# If you prefer / need to force POSIX sh:
sh ./send-image.sh ./screen.png
```

### If you want a screenshot of the current Pi display

If you installed `kmsgrab` (see `install_kmsgrab.sh`):

```bash
sudo kmsgrab /tmp/screen.png
./send-image.sh /tmp/screen.png
```

## Troubleshooting: docker.sock permission denied

If you see:

```
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

your user is not in the `docker` group.

Fix (on the Pi):

```bash
sudo usermod -aG docker "$USER"
# then log out/in (or reboot) so the new group membership is applied
```

Workaround (no group change):

```bash
sudo docker compose --env-file "$HOME/lume-pi/docker/.env" -f "$HOME/lume-pi/docker/docker-compose.pi.yml" logs
```

## Security notes

- `lume-pi/docker/.env` contains secrets. Keep permissions tight.
- Avoid putting secrets on the command line (shell history). Prefer `.env` files.

## Optional — BorgBase backups (SSH)

If you use BorgBase (or any SSH-backed Borg repo), run:

```bash
cd ~/lume-pi
sudo ./setup-backup.sh
```

The script will create (if missing) and print the SSH public key:

```bash
~/.ssh/id_ed25519.pub
```

Add that key in BorgBase, then configure `/etc/backup-secrets` with your `BORG_REPO` and `BORG_PASSPHRASE`.

### Storage backup format

Backups include:

- `db_backup.sql.gz`
- `storage.tar` (tar of the Rails storage docker volume)


# Network

sudo nmcli connection
sudo nmcli connection down lume-eth-static