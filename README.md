# pi-hotspot

A simple Raspberry Pi hotspot setup for **Ethernet ➜ Wi‑Fi sharing** using NetworkManager.

This project provides two scripts:

- `install_pi_hotspot.sh` — installs dependencies and configures a Wi‑Fi AP in shared mode.
- `uninstall_pi_hotspot.sh` — removes the hotspot connection, helper scripts, and systemd units.

## What it sets up

The installer configures a Raspberry Pi to:

- Share an Ethernet uplink (`eth0` by default) over Wi‑Fi (`wlan0` by default).
- Create a WPA2 hotspot connection (default SSID `PiHotspot`).
- Use NetworkManager shared IPv4 mode with a default gateway of `10.42.0.1`.
- Persist hotspot profile settings in NetworkManager and auto-connect at boot.
- Install a boot-start service that re-activates the hotspot during startup.
- Install a watchdog service/timer that auto-recovers the hotspot.
- Install a local health endpoint at `/health` (default `http://0.0.0.0:8787/health`).
- Install a client-inspection helper script at `/usr/local/bin/pi-hotspot-clients.sh`.

## Requirements

- Raspberry Pi OS / Debian-style system with `apt-get`.
- Root privileges (`sudo` or root shell).
- Existing Ethernet and Wi‑Fi interfaces (defaults: `eth0`, `wlan0`).

## Quick start

1. Make scripts executable:

```bash
chmod +x install_pi_hotspot.sh uninstall_pi_hotspot.sh
```

2. Run installer with defaults:

```bash
sudo bash install_pi_hotspot.sh
```

3. Connect a device to SSID `PiHotspot` using password `ChangeMe123!` (change this in production).

## Configuration

You can override installer defaults via environment variables:

```bash
sudo \
  SSID="MyPiAP" \
  PASSWORD="StrongPass123!" \
  COUNTRY="US" \
  ETH_IF="eth0" \
  WLAN_IF="wlan0" \
  HOTSPOT_CONN="PiHotspot" \
  HOTSPOT_IP_CIDR="10.42.0.1/24" \
  HOTSPOT_GATEWAY_IP="10.42.0.1" \
  WIFI_BAND="bg" \
  WIFI_CHANNEL="6" \
  WATCHDOG_INTERVAL="30s" \
  HEALTH_HOST="0.0.0.0" \
  HEALTH_PORT="8787" \
  bash install_pi_hotspot.sh
```

### Key variables

- `SSID` (default: `PiHotspot`)
- `PASSWORD` (default: `ChangeMe123!`, must be at least 8 chars)
- `COUNTRY` (default: `US`)
- `ETH_IF` / `WLAN_IF` (defaults: `eth0` / `wlan0`)
- `HOTSPOT_CONN` (default: `PiHotspot`)
- `HOTSPOT_IP_CIDR` (default: `10.42.0.1/24`)
- `WIFI_BAND` (default: `bg`)
- `WIFI_CHANNEL` (default: `6`)
- `WATCHDOG_INTERVAL` (default: `30s`)
- `HEALTH_HOST` / `HEALTH_PORT` (defaults: `0.0.0.0` / `8787`)

## Health and operations

Check health JSON:

```bash
curl http://127.0.0.1:8787/health
```

List active NetworkManager connections:

```bash
nmcli connection show --active
```

See connected hotspot clients:

```bash
/usr/local/bin/pi-hotspot-clients.sh
```

> Note: On some Raspberry Pi OS / NetworkManager versions, DHCP leases may be stored in
> different locations (including `/var/lib/NetworkManager/*.leases` and
> `/run/NetworkManager/*.leases`). The generated client script checks common lease paths
> automatically, and it falls back to `ip neigh` (ARP/neighbor table) to recover client IPs
> even when no lease file is present.

Watch clients continuously:

```bash
watch -n 2 /usr/local/bin/pi-hotspot-clients.sh
```

Inspect logs:

```bash
sudo journalctl -u NetworkManager -n 100 --no-pager
sudo journalctl -u pi-hotspot-boot.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-watchdog.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-health.service -n 50 --no-pager
```

## Uninstall

Basic uninstall (keeps packages installed):

```bash
sudo bash uninstall_pi_hotspot.sh
```

Uninstall and remove installed packages too:

```bash
sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot.sh
```

## Notes

- The installer disables the standalone `dnsmasq` service so NetworkManager can manage DHCP/NAT shared mode cleanly.
- If your interface names differ (e.g., `end0`/`wlp...`), set `ETH_IF` and `WLAN_IF` explicitly.
- For security, always change the default password before exposing the hotspot.
