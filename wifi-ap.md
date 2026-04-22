# Wi‑Fi Access Point (Hotspot) on Raspberry Pi 4 (Raspberry Pi OS Lite / Bookworm)

This guide configures a **Raspberry Pi 4** as a **Wi‑Fi Access Point** so you can connect with a mobile phone and open the Lume dashboard/player even when there’s no LAN.

It uses the “classic / portable” stack:

- **hostapd** (Wi‑Fi AP)
- **dnsmasq** (DHCP + DNS for AP clients)
- **IP forwarding + NAT** (so if `eth0` has internet, AP clients can also reach the internet)

No secrets are hard-coded in this repo: you’ll store SSID/PSK in a local env file on the Pi.

## Network plan (fixed)

- AP interface: `wlan0`
- Pi AP IP: `192.168.4.1/24`
- DHCP range: `192.168.4.50–192.168.4.150`

From your phone (after joining the Wi‑Fi):

- Dashboard: `http://192.168.4.1:3012`
- Player: `http://192.168.4.1:3014`
- Core health: `http://192.168.4.1:3011/up`

If mDNS works on your phone, you may also be able to use `http://<hostname>.local:3012`, but **the IP is the “always works” path**.

## Prereqs / warnings

- AP mode takes over **`wlan0`**. You generally can’t use `wlan0` as both “Wi‑Fi client” and “AP” at the same time.
- If you want AP clients to have internet, the Pi needs internet on **`eth0`**.
- If you’re running the Lume stack via Docker, pull images while you still have internet.

## Setup (scripted)

On the Pi:

```bash
cd ~/lume-pi

# Create /etc/lume-wifi-ap.env from the repo sample
sudo install -m 600 -o root -g root ./wifi-ap.env.sample /etc/lume-wifi-ap.env
sudo nano /etc/lume-wifi-ap.env

# Configure hotspot services + NAT (wlan0 -> eth0)
sudo ./setup-wifi.sh
```

What the script configures:

- Installs: `hostapd`, `dnsmasq`, `iptables-persistent` (plus `envsubst`)
- `wlan0` static IP: `192.168.4.1/24` via `lume-wifi-ap-ip.service`
- DHCP: `/etc/dnsmasq.d/lume-ap.conf`
- hostapd: `/etc/hostapd/hostapd.conf` (generated from env)
- Routing/NAT (optional): `wlan0 -> eth0` (use `--no-nat` to skip)

## Connect from phone

1. On the phone, join the Wi‑Fi SSID you configured.
2. If the phone warns “No internet” or “Connected without internet”, that’s normal (unless you also plugged `eth0` into the internet).
3. Open:
   - `http://192.168.4.1:3012` (dashboard)
   - `http://192.168.4.1:3014` (player)

iOS tip: if Safari doesn’t load immediately, turn Wi‑Fi off/on once after joining; iOS sometimes needs a moment to accept a “no internet” network.

## Troubleshooting / debugging

### Status/logs

```bash
sudo systemctl status hostapd --no-pager
sudo systemctl status dnsmasq --no-pager
sudo systemctl status lume-wifi-ap-ip --no-pager

sudo journalctl -u hostapd -n 200 --no-pager
sudo journalctl -u dnsmasq -n 200 --no-pager
sudo journalctl -u lume-wifi-ap-ip -n 200 --no-pager
```

### Verify wlan0 IP and AP mode

```bash
ip a show wlan0
iw dev
sudo rfkill list
```

### DHCP leases

```bash
sudo cat /var/lib/misc/dnsmasq.leases
```

### Common failure modes

- **`hostapd` fails with “nl80211: Driver does not support AP”**: double-check you’re on a Pi 4 with the built-in Wi‑Fi and that `interface=wlan0` is correct.
- **`dnsmasq` won’t start**: check for conflicting DNS/DHCP services or an existing `dnsmasq` config that binds to all interfaces.
- **Clients can join but have no internet**: confirm `eth0` has internet, IPv4 forwarding is on, and NAT rules exist:

  ```bash
  sysctl net.ipv4.ip_forward
  sudo iptables -t nat -S
  sudo iptables -S FORWARD
  ```

### Re-run the script safely

The script is intended to be re-runnable. If you change `/etc/lume-wifi-ap.env`, re-run:

```bash
cd ~/lume-pi
sudo ./setup-wifi.sh
```
