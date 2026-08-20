# pi-hotspot

A simple Raspberry Pi hotspot setup for **Ethernet ➜ Wi‑Fi sharing** using NetworkManager.

- `install_pi_hotspot.sh` / `uninstall_pi_hotspot.sh` — NAT/shared-mode hotspot. The Pi
  runs its own DHCP server and routes/NATs Wi‑Fi clients onto the Ethernet uplink.
- `pi-hotspot-set-best-channel.sh` — re-scans and switches an already-installed hotspot
  to the least congested Wi‑Fi channel (see [Choosing a Wi‑Fi channel](#choosing-a-wi-fi-channel)).

The installer prompts interactively for the hotspot SSID, password, and whether the
network should be visible or hidden — there is no shipped default network name or
password.

## What the installer sets up

`install_pi_hotspot.sh` configures a Raspberry Pi to:

- Share an Ethernet uplink (`eth0` by default) over Wi‑Fi (`wlan0` by default).
- Scan nearby Wi‑Fi networks and automatically pick the least congested channel
  (unless `WIFI_CHANNEL` is set explicitly).
- Create a WPA2 hotspot connection, visible or hidden as chosen at install time.
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

2. Run the installer and answer the SSID/password/visibility prompts:

```bash
sudo bash install_pi_hotspot.sh
```

The installer can also be run non-interactively by pre-setting the `SSID`, `PASSWORD`,
and `HIDDEN` environment variables (see [Configuration](#configuration)).

## Configuration

`SSID`, `PASSWORD`, and `HIDDEN` are prompted for interactively if not set. You can
override these and other installer defaults via environment variables, which also
allows non-interactive installs (e.g. from a provisioning script):

```bash
sudo \
  SSID="MyPiAP" \
  PASSWORD="StrongPass123!" \
  HIDDEN="no" \
  COUNTRY="US" \
  ETH_IF="eth0" \
  WLAN_IF="wlan0" \
  HOTSPOT_CONN="PiHotspot" \
  HOTSPOT_IP_CIDR="10.42.0.1/24" \
  HOTSPOT_GATEWAY_IP="10.42.0.1" \
  WIFI_BAND="bg" \
  WIFI_CHANNEL="auto" \
  WATCHDOG_INTERVAL="30s" \
  HEALTH_HOST="0.0.0.0" \
  HEALTH_PORT="8787" \
  bash install_pi_hotspot.sh
```

### Key variables

- `SSID` — prompted interactively if unset (no default). Max 32 characters.
- `PASSWORD` — prompted interactively (with confirmation) if unset (no default). Must be
  at least 8 characters.
- `HIDDEN` — prompted interactively if unset (no default). Set to `yes` to hide the
  network from Wi‑Fi scans, or `no` to keep it visible/broadcast.
- `COUNTRY` (default: `US`)
- `ETH_IF` / `WLAN_IF` (defaults: `eth0` / `wlan0`)
- `HOTSPOT_CONN` (default: `PiHotspot`)
- `HOTSPOT_IP_CIDR` (default: `10.42.0.1/24`)
- `WIFI_BAND` (default: `bg`)
- `WIFI_CHANNEL` (default: `auto` — scans and picks the least congested channel;
  set an explicit channel number to disable scanning)
- `WATCHDOG_INTERVAL` (default: `30s`)
- `HEALTH_HOST` (default: `0.0.0.0`)
- `HEALTH_PORT` (default: `8787`)

## Choosing a Wi‑Fi channel

By default (`WIFI_CHANNEL=auto`), the installer scans nearby Wi‑Fi networks with
`nmcli` and picks the least congested non-overlapping channel for `WIFI_BAND`:
`1`, `6`, or `11` for `bg` (2.4GHz), or one of `36`, `40`, `44`, `48`, `149`, `153`,
`157`, `161`, `165` for `a` (5GHz). Each candidate is scored by how many nearby
networks are on it (or, on 2.4GHz, within 2 channels of it, since 20MHz channels
overlap with their neighbors); the lowest-scoring channel is used. If the scan
finds no nearby networks, it falls back to the first candidate (`1` for `bg`,
`36` for `a`). Set `WIFI_CHANNEL` to a specific number to skip scanning entirely.

To re-scan and switch an **already-installed** hotspot to the current best
channel (e.g. after new neighboring networks appear), run:

```bash
sudo bash pi-hotspot-set-best-channel.sh
```

This briefly takes the hotspot down to scan, then brings it back up on the best
channel it found (or leaves it as-is if it's already on the best channel). It
reads `HOTSPOT_CONN` and `WLAN_IF` the same way the installer does, and infers
`WIFI_BAND` from the existing connection unless overridden:

```bash
sudo HOTSPOT_CONN="PiHotspot" WLAN_IF="wlan0" WIFI_BAND="bg" bash pi-hotspot-set-best-channel.sh
```

Consider running it periodically (e.g. via cron) if the RF environment changes often.

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

> On some Raspberry Pi OS / NetworkManager versions, DHCP leases may be stored in
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

`REMOVE_PACKAGES=1` removes `network-manager`, `dnsmasq`, `wireless-regdb`, and
`iw`/`rfkill`. It intentionally leaves `python3` installed, since it's a base system
dependency on Raspberry Pi OS and removing it can drag down unrelated tooling via apt's
dependency resolution.

## Notes

- The installer disables the standalone `dnsmasq` service so NetworkManager can manage
  DHCP/NAT shared mode cleanly.
- If your interface names differ (e.g., `end0`/`wlp...`), set `ETH_IF` and `WLAN_IF` explicitly.
- The installer prompts for SSID, password, and network visibility at install time; there
  is no shipped default network name, password, or visibility setting.
