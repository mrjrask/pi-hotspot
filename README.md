# pi-hotspot

A simple Raspberry Pi hotspot setup for **Ethernet ➜ Wi‑Fi sharing** using NetworkManager.

This project provides two hotspot variants, each with its own installer/uninstaller pair:

- `install_pi_hotspot.sh` / `uninstall_pi_hotspot.sh` — NAT/shared-mode hotspot. The Pi
  runs its own DHCP server and routes/NATs Wi‑Fi clients onto the Ethernet uplink.
- `install_pi_hotspot_bridge.sh` / `uninstall_pi_hotspot_bridge.sh` — bridged hotspot. The
  Pi bridges Wi‑Fi and Ethernet at layer 2, so Wi‑Fi clients join the same subnet as the
  Ethernet uplink and get their DHCP lease from the upstream router.
- `reinstall_pi_hotspot_dependencies.sh` — restores the apt packages either uninstaller can
  remove (see [Uninstall](#uninstall)). Useful for recovering from a `REMOVE_PACKAGES=1`
  uninstall that took out something you still needed.

Both installers prompt interactively for the hotspot SSID and password — there is no
shipped default network name or password.

## What the shared-mode installer sets up

`install_pi_hotspot.sh` configures a Raspberry Pi to:

- Share an Ethernet uplink (`eth0` by default) over Wi‑Fi (`wlan0` by default).
- Create a WPA2 hotspot connection.
- Use NetworkManager shared IPv4 mode with a default gateway of `10.42.0.1`.
- Persist hotspot profile settings in NetworkManager and auto-connect at boot.
- Install a boot-start service that re-activates the hotspot during startup.
- Install a watchdog service/timer that auto-recovers the hotspot.
- Install a local health endpoint at `/health` (default `http://0.0.0.0:8787/health`).
- Install a client-inspection helper script at `/usr/local/bin/pi-hotspot-clients.sh`.

## What the bridge installer sets up

`install_pi_hotspot_bridge.sh` configures a Raspberry Pi to:

- Create a Linux bridge (`br0` by default) joining the Ethernet uplink (`eth0`) and a
  Wi‑Fi access point (`wlan0`) at layer 2 — no NAT, no local DHCP server on the Pi.
- Create a WPA2 hotspot connection bridged onto that Ethernet segment. Clients get an IP
  directly from the router upstream of the Pi's Ethernet port, on the same subnet as the
  wired network.
- Persist bridge/hotspot profile settings in NetworkManager and auto-connect at boot.
- Install a boot-start service that re-activates the bridge and hotspot during startup.
- Install a watchdog service/timer that auto-recovers the bridge and hotspot.
- Install a local health endpoint at `/health` (default `http://0.0.0.0:8788/health`).
- Install a client-inspection helper at `/usr/local/bin/pi-hotspot-bridge-clients.sh`.

> **Wi‑Fi adapter caveat:** bridging an AP with a wired uplink requires the Wi‑Fi driver to
> support 4-address-format frames. Some onboard Raspberry Pi Wi‑Fi chips (e.g. `brcmfmac`
> on the Pi 3/4/Zero W) don't support this reliably — clients may associate but pass no
> traffic. If that happens, try a USB Wi‑Fi adapter with a chipset known to support AP +
> bridge mode (e.g. `rtl8188eus`/`rtl8812au`-based adapters), or use the shared-mode
> installer instead.

## Requirements

- Raspberry Pi OS / Debian-style system with `apt-get`.
- Root privileges (`sudo` or root shell).
- Existing Ethernet and Wi‑Fi interfaces (defaults: `eth0`, `wlan0`).

## Quick start

### Shared mode (NAT)

1. Make scripts executable:

```bash
chmod +x install_pi_hotspot.sh uninstall_pi_hotspot.sh
```

2. Run the installer and answer the SSID/password prompts:

```bash
sudo bash install_pi_hotspot.sh
```

### Bridge mode

1. Make scripts executable:

```bash
chmod +x install_pi_hotspot_bridge.sh uninstall_pi_hotspot_bridge.sh
```

2. Run the installer and answer the SSID/password prompts:

```bash
sudo bash install_pi_hotspot_bridge.sh
```

Both installers can also be run non-interactively by pre-setting `SSID` and `PASSWORD`
environment variables (see [Configuration](#configuration)).

## Configuration

`SSID` and `PASSWORD` are prompted for interactively if not set. You can override these
and other installer defaults via environment variables, which also allows non-interactive
installs (e.g. from a provisioning script):

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

The bridge installer accepts the same override style:

```bash
sudo \
  SSID="MyPiAP" \
  PASSWORD="StrongPass123!" \
  COUNTRY="US" \
  ETH_IF="eth0" \
  WLAN_IF="wlan0" \
  BRIDGE_IF="br0" \
  HOTSPOT_CONN="PiHotspotBridge" \
  BRIDGE_CONN="PiHotspotBridge-br0" \
  ETH_SLAVE_CONN="PiHotspotBridge-eth" \
  WIFI_BAND="bg" \
  WIFI_CHANNEL="6" \
  WATCHDOG_INTERVAL="30s" \
  HEALTH_HOST="0.0.0.0" \
  HEALTH_PORT="8788" \
  bash install_pi_hotspot_bridge.sh
```

### Key variables

- `SSID` — prompted interactively if unset (no default). Max 32 characters.
- `PASSWORD` — prompted interactively (with confirmation) if unset (no default). Must be
  at least 8 characters.
- `COUNTRY` (default: `US`)
- `ETH_IF` / `WLAN_IF` (defaults: `eth0` / `wlan0`)
- `WIFI_BAND` (default: `bg`)
- `WIFI_CHANNEL` (default: `6`)
- `WATCHDOG_INTERVAL` (default: `30s`)
- `HEALTH_HOST` (default: `0.0.0.0`)
- `HEALTH_PORT` — shared-mode default `8787`, bridge-mode default `8788`
- Shared mode only: `HOTSPOT_CONN` (default: `PiHotspot`), `HOTSPOT_IP_CIDR`
  (default: `10.42.0.1/24`)
- Bridge mode only: `BRIDGE_IF` (default: `br0`), `HOTSPOT_CONN`
  (default: `PiHotspotBridge`), `BRIDGE_CONN` (default: `PiHotspotBridge-br0`),
  `ETH_SLAVE_CONN` (default: `PiHotspotBridge-eth`)

## Health and operations

Check health JSON:

```bash
curl http://127.0.0.1:8787/health   # shared mode
curl http://127.0.0.1:8788/health   # bridge mode
```

List active NetworkManager connections:

```bash
nmcli connection show --active
```

See connected hotspot clients:

```bash
/usr/local/bin/pi-hotspot-clients.sh          # shared mode
/usr/local/bin/pi-hotspot-bridge-clients.sh   # bridge mode
```

> Note (shared mode): On some Raspberry Pi OS / NetworkManager versions, DHCP leases may
> be stored in different locations (including `/var/lib/NetworkManager/*.leases` and
> `/run/NetworkManager/*.leases`). The generated client script checks common lease paths
> automatically, and it falls back to `ip neigh` (ARP/neighbor table) to recover client IPs
> even when no lease file is present.

> Note (bridge mode): the Pi does not run DHCP in bridge mode — clients lease from the
> upstream router — so the bridge client script relies entirely on `ip neigh`
> (ARP/neighbor table) and may show `unknown` for a client's IP until it has sent traffic.

Watch clients continuously:

```bash
watch -n 2 /usr/local/bin/pi-hotspot-clients.sh          # shared mode
watch -n 2 /usr/local/bin/pi-hotspot-bridge-clients.sh   # bridge mode
```

Inspect logs:

```bash
sudo journalctl -u NetworkManager -n 100 --no-pager

# shared mode
sudo journalctl -u pi-hotspot-boot.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-watchdog.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-health.service -n 50 --no-pager

# bridge mode
sudo journalctl -u pi-hotspot-bridge-boot.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-bridge-watchdog.service -n 50 --no-pager
sudo journalctl -u pi-hotspot-bridge-health.service -n 50 --no-pager
```

## Uninstall

Basic uninstall (keeps packages installed) — always safe, no confirmation needed:

```bash
sudo bash uninstall_pi_hotspot.sh          # shared mode
sudo bash uninstall_pi_hotspot_bridge.sh   # bridge mode
```

This removes only what the installer created: the hotspot NetworkManager connection(s),
the watchdog/boot/health systemd units, and the helper scripts under `/usr/local/`.

### Removing packages too

Package removal is opt-in, requires typed confirmation (`REMOVE`) unless `FORCE=1` is
set, and is split into two tiers so one flag can't take down more than you asked for:

```bash
# Removes dnsmasq (shared mode only), wireless-regdb, iw, rfkill
sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot.sh          # shared mode
sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot_bridge.sh   # bridge mode

# Also removes network-manager — the Pi's active network stack. Only do this if
# you understand you may lose SSH/network access immediately and need physical
# console access to recover.
sudo REMOVE_PACKAGES=1 REMOVE_NETWORK_MANAGER=1 bash uninstall_pi_hotspot.sh

# Non-interactive/scripted removal (skips the typed REMOVE confirmation):
sudo REMOVE_PACKAGES=1 FORCE=1 bash uninstall_pi_hotspot.sh
```

`python3` is never removed by either uninstaller — it's a base system dependency (used by
apt/dpkg triggers, `raspi-config`, etc.) and removing it can cascade into removing unrelated
parts of the OS. `apt-get autoremove` is also never run automatically, since it can remove
other packages that merely stop being "required" once these are gone; opt in with
`AUTOREMOVE=1` if you specifically want that cleanup.

### Recovering removed dependencies

If package removal (or anything else) leaves the Pi missing packages this project needs,
reinstall them with:

```bash
sudo bash reinstall_pi_hotspot_dependencies.sh
```

This reinstalls `network-manager`, `dnsmasq`, `wireless-regdb`, `iw`, `rfkill`, and `python3`,
re-enables and restarts NetworkManager, and re-disables the standalone `dnsmasq` service so it
doesn't conflict with NetworkManager-managed DHCP/NAT. It's safe to run whether the packages
are currently missing or already installed. Afterwards, re-run `install_pi_hotspot.sh` (or
`install_pi_hotspot_bridge.sh`) to recreate the hotspot connection and helper scripts/services
if the uninstaller removed those too.

## Notes

- The shared-mode installer disables the standalone `dnsmasq` service so NetworkManager can
  manage DHCP/NAT shared mode cleanly. The bridge installer doesn't need `dnsmasq` at all —
  it still stops/disables it defensively if present, so it can't hand out conflicting leases
  on the bridge.
- If your interface names differ (e.g., `end0`/`wlp...`), set `ETH_IF` and `WLAN_IF` explicitly.
- Both installers prompt for SSID and password at install time; there is no shipped default
  network name or password.
- Bridge mode depends on the Wi‑Fi driver supporting AP + 4-address bridging — see the
  caveat above if clients associate but can't pass traffic.
