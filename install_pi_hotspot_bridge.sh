#!/usr/bin/env bash
set -euo pipefail

########################################
# Raspberry Pi Trixie Ethernet <-> Wi-Fi Hotspot Bridge Installer
# - Uses NetworkManager to bridge Ethernet and Wi-Fi at layer 2
# - Wi-Fi clients join the same subnet as the Ethernet uplink and get
#   DHCP leases from the upstream router (no local DHCP/NAT on the Pi)
# - Prompts interactively for SSID and password (no shipped defaults)
# - Installs dependencies automatically
# - Creates a watchdog service + timer
# - Exposes /health endpoint on configurable port
# - Installs pi-hotspot-bridge-clients.sh helper
#
# NOTE: Bridging a Wi-Fi AP with a wired uplink relies on the Wi-Fi
# adapter's driver supporting 4-address-format frames. Some onboard
# Raspberry Pi Wi-Fi chips (e.g. brcmfmac on Pi 3/4/Zero W) do not
# support this reliably. If clients can associate but get no traffic,
# try a USB Wi-Fi adapter with a chipset known to support AP + bridge
# mode (e.g. rtl8188eus/rtl8812au based adapters).
########################################

# -----------------------------
# User-configurable defaults
# -----------------------------
SSID="${SSID:-}"
PASSWORD="${PASSWORD:-}"
COUNTRY="${COUNTRY:-US}"

ETH_IF="${ETH_IF:-eth0}"
WLAN_IF="${WLAN_IF:-wlan0}"
BRIDGE_IF="${BRIDGE_IF:-br0}"

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspotBridge}"
BRIDGE_CONN="${BRIDGE_CONN:-PiHotspotBridge-br0}"
ETH_SLAVE_CONN="${ETH_SLAVE_CONN:-PiHotspotBridge-eth}"

WIFI_BAND="${WIFI_BAND:-bg}"
WIFI_CHANNEL="${WIFI_CHANNEL:-6}"

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30s}"

HEALTH_HOST="${HEALTH_HOST:-0.0.0.0}"
HEALTH_PORT="${HEALTH_PORT:-8788}"

WATCHDOG_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-watchdog.sh"
BOOT_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-boot.sh"
HEALTH_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-health.py"
CLIENTS_SCRIPT="/usr/local/bin/pi-hotspot-bridge-clients.sh"

SYSTEMD_WATCHDOG_SERVICE="/etc/systemd/system/pi-hotspot-bridge-watchdog.service"
SYSTEMD_WATCHDOG_TIMER="/etc/systemd/system/pi-hotspot-bridge-watchdog.timer"
SYSTEMD_HEALTH_SERVICE="/etc/systemd/system/pi-hotspot-bridge-health.service"
SYSTEMD_BOOT_SERVICE="/etc/systemd/system/pi-hotspot-bridge-boot.service"

# -----------------------------
# Logging helpers
# -----------------------------
log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

err() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# -----------------------------
# Basic checks
# -----------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "Run this script with sudo or as root."
    fi
}

require_interactive_or_env() {
    if [[ ! -t 0 ]] && { [[ -z "${SSID}" ]] || [[ -z "${PASSWORD}" ]]; }; then
        err "No TTY detected for interactive prompts. Set SSID and PASSWORD environment variables for non-interactive installs."
    fi
}

prompt_for_ssid() {
    if [[ -z "${SSID}" ]]; then
        read -r -p "Enter hotspot SSID (network name): " SSID
    fi

    if [[ -z "${SSID}" ]]; then
        err "SSID cannot be empty."
    fi

    if [[ "${#SSID}" -gt 32 ]]; then
        err "SSID must be 32 characters or fewer."
    fi
}

prompt_for_password() {
    if [[ -n "${PASSWORD}" ]]; then
        if [[ "${#PASSWORD}" -lt 8 ]]; then
            err "PASSWORD must be at least 8 characters long."
        fi
        return
    fi

    local pass1 pass2
    while true; do
        read -rs -p "Enter hotspot password (min 8 characters): " pass1
        echo
        if [[ "${#pass1}" -lt 8 ]]; then
            warn "Password must be at least 8 characters. Try again."
            continue
        fi

        read -rs -p "Confirm hotspot password: " pass2
        echo
        if [[ "${pass1}" != "${pass2}" ]]; then
            warn "Passwords do not match. Try again."
            continue
        fi

        PASSWORD="${pass1}"
        break
    done
}

validate_inputs() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "This installer expects Raspberry Pi OS / Debian with apt-get."
    fi
}

check_interfaces() {
    ip link show "${ETH_IF}" >/dev/null 2>&1 || err "Ethernet interface '${ETH_IF}' was not found."
    ip link show "${WLAN_IF}" >/dev/null 2>&1 || err "Wi-Fi interface '${WLAN_IF}' was not found."
}

# -----------------------------
# Package install / setup
# -----------------------------
install_dependencies() {
    log "Updating package index..."
    apt-get update

    log "Installing required dependencies..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        network-manager \
        wireless-regdb \
        iw \
        rfkill \
        python3

    log "Stopping standalone dnsmasq service (if present) so it can't hand out leases on the bridge..."
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
}

enable_networkmanager() {
    log "Enabling and restarting NetworkManager..."
    systemctl enable NetworkManager
    systemctl restart NetworkManager
    sleep 3
}

set_wifi_country() {
    if command -v raspi-config >/dev/null 2>&1; then
        log "Setting Wi-Fi country to ${COUNTRY}..."
        raspi-config nonint do_wifi_country "${COUNTRY}" || warn "Could not set Wi-Fi country via raspi-config."
    else
        warn "raspi-config not found; skipping Wi-Fi country setup."
    fi

    rfkill unblock wifi || true
}

ensure_nm_manages_interfaces() {
    log "Ensuring NetworkManager manages ${ETH_IF} and ${WLAN_IF}..."
    nmcli device set "${ETH_IF}" managed yes || true
    nmcli device set "${WLAN_IF}" managed yes || true
}

# -----------------------------
# Clean up old/conflicting profiles
# -----------------------------
remove_existing_profiles() {
    log "Removing old/conflicting NetworkManager profiles..."

    local name
    for name in "${BRIDGE_CONN}" "${ETH_SLAVE_CONN}" "${HOTSPOT_CONN}"; do
        if nmcli -t -f NAME connection show | grep -qx "${name}"; then
            log "Removing existing connection '${name}'..."
            nmcli connection down "${name}" 2>/dev/null || true
            nmcli connection delete "${name}" 2>/dev/null || true
        fi
    done

    local existing_wifi_names
    existing_wifi_names="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" || $2=="wifi" {print $1}')"

    while IFS= read -r conn_name; do
        [[ -z "${conn_name}" ]] && continue

        local conn_ssid=""
        conn_ssid="$(nmcli -g 802-11-wireless.ssid connection show "${conn_name}" 2>/dev/null || true)"
        if [[ "${conn_ssid}" == "${SSID}" ]]; then
            log "Removing connection '${conn_name}' because it matches target SSID '${SSID}'..."
            nmcli connection down "${conn_name}" 2>/dev/null || true
            nmcli connection delete "${conn_name}" 2>/dev/null || true
        fi
    done <<< "${existing_wifi_names}"
}

disable_conflicting_ethernet_profiles() {
    log "Disabling autoconnect on other Ethernet profiles bound to ${ETH_IF} so they don't compete with the bridge port..."

    local existing_names
    existing_names="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-3-ethernet" || $2=="ethernet" {print $1}')"

    while IFS= read -r conn_name; do
        [[ -z "${conn_name}" ]] && continue
        [[ "${conn_name}" == "${ETH_SLAVE_CONN}" ]] && continue

        log "Disabling autoconnect on '${conn_name}'..."
        nmcli connection modify "${conn_name}" connection.autoconnect no || true
        nmcli connection down "${conn_name}" 2>/dev/null || true
    done <<< "${existing_names}"
}

disconnect_wlan_if_needed() {
    log "Disconnecting ${WLAN_IF} before hotspot creation..."
    nmcli device disconnect "${WLAN_IF}" 2>/dev/null || true
    sleep 2
}

# -----------------------------
# Bridge + hotspot creation
# -----------------------------
create_bridge_profile() {
    log "Creating bridge connection '${BRIDGE_CONN}' on ${BRIDGE_IF}..."

    nmcli connection add \
        type bridge \
        ifname "${BRIDGE_IF}" \
        con-name "${BRIDGE_CONN}"

    nmcli connection modify "${BRIDGE_CONN}" \
        bridge.stp no \
        ipv4.method auto \
        ipv6.method disabled \
        connection.autoconnect yes \
        connection.autoconnect-priority 100
}

create_eth_slave_profile() {
    log "Adding ${ETH_IF} to the bridge as '${ETH_SLAVE_CONN}'..."

    nmcli connection add \
        type ethernet \
        ifname "${ETH_IF}" \
        con-name "${ETH_SLAVE_CONN}" \
        master "${BRIDGE_CONN}" \
        slave-type bridge

    nmcli connection modify "${ETH_SLAVE_CONN}" connection.autoconnect yes
}

create_wifi_ap_slave_profile() {
    log "Creating Wi-Fi access point '${HOTSPOT_CONN}' on ${WLAN_IF}, bridged into ${BRIDGE_IF}..."

    nmcli connection add \
        type wifi \
        ifname "${WLAN_IF}" \
        con-name "${HOTSPOT_CONN}" \
        ssid "${SSID}" \
        master "${BRIDGE_CONN}" \
        slave-type bridge

    nmcli connection modify "${HOTSPOT_CONN}" \
        802-11-wireless.mode ap \
        802-11-wireless.band "${WIFI_BAND}" \
        802-11-wireless.channel "${WIFI_CHANNEL}" \
        802-11-wireless.powersave 2 \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.proto rsn \
        wifi-sec.pairwise ccmp \
        wifi-sec.group ccmp \
        wifi-sec.psk "${PASSWORD}" \
        connection.autoconnect yes \
        connection.autoconnect-retries -1
}

bring_up_bridge() {
    log "Bringing up bridge '${BRIDGE_CONN}'..."
    nmcli connection up "${BRIDGE_CONN}" || err "Failed to activate bridge '${BRIDGE_CONN}'."
    sleep 2

    log "Bringing up Ethernet bridge port '${ETH_SLAVE_CONN}'..."
    nmcli connection up "${ETH_SLAVE_CONN}" || err "Failed to activate Ethernet bridge port '${ETH_SLAVE_CONN}'."
    sleep 2

    log "Bringing up Wi-Fi access point '${HOTSPOT_CONN}'..."
    nmcli connection up "${HOTSPOT_CONN}" || err "Failed to activate Wi-Fi access point '${HOTSPOT_CONN}'."
    sleep 5
}

# -----------------------------
# Watchdog
# -----------------------------
write_watchdog_script() {
    log "Writing watchdog script to ${WATCHDOG_SCRIPT}..."

    cat > "${WATCHDOG_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE_CONN="${BRIDGE_CONN:-PiHotspotBridge-br0}"
ETH_SLAVE_CONN="${ETH_SLAVE_CONN:-PiHotspotBridge-eth}"
HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspotBridge}"
BRIDGE_IF="${BRIDGE_IF:-br0}"
WLAN_IF="${WLAN_IF:-wlan0}"
ETH_IF="${ETH_IF:-eth0}"
LOG_TAG="pi-hotspot-bridge-watchdog"

log() {
    logger -t "${LOG_TAG}" "$*"
    printf '[WATCHDOG] %s\n' "$*"
}

nm_ok() {
    systemctl is-active --quiet NetworkManager
}

conn_active() {
    local conn_name="$1" dev="$2"
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${conn_name}:${dev}$"
}

bridge_active() {
    conn_active "${BRIDGE_CONN}" "${BRIDGE_IF}"
}

eth_slave_active() {
    conn_active "${ETH_SLAVE_CONN}" "${ETH_IF}"
}

hotspot_active() {
    conn_active "${HOTSPOT_CONN}" "${WLAN_IF}"
}

fully_active() {
    bridge_active && eth_slave_active && hotspot_active
}

recover() {
    log "Bridge hotspot is not fully active. Attempting recovery."

    nmcli connection up "${BRIDGE_CONN}" >/dev/null 2>&1 || true
    sleep 2
    nmcli connection up "${ETH_SLAVE_CONN}" >/dev/null 2>&1 || true
    sleep 2
    nmcli connection up "${HOTSPOT_CONN}" >/dev/null 2>&1 || {
        log "Recovery failed for Wi-Fi access point '${HOTSPOT_CONN}'."
        exit 1
    }

    sleep 4

    if fully_active; then
        log "Bridge hotspot recovered."
    else
        log "Recovery command completed but bridge hotspot is still not fully active."
        exit 1
    fi
}

main() {
    if ! nm_ok; then
        log "NetworkManager is not active; restarting it."
        systemctl restart NetworkManager || exit 1
        sleep 4
    fi

    if ! ip link show "${WLAN_IF}" >/dev/null 2>&1; then
        log "Wi-Fi interface '${WLAN_IF}' not found."
        exit 1
    fi

    if fully_active; then
        exit 0
    fi

    recover
}

main "$@"
EOF

    chmod 755 "${WATCHDOG_SCRIPT}"
}

# -----------------------------
# Health endpoint
# -----------------------------
write_health_script() {
    log "Writing health endpoint script to ${HEALTH_SCRIPT}..."

    cat > "${HEALTH_SCRIPT}" <<'EOF'
#!/usr/bin/env python3
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

BRIDGE_CONN = os.environ.get("BRIDGE_CONN", "PiHotspotBridge-br0")
ETH_SLAVE_CONN = os.environ.get("ETH_SLAVE_CONN", "PiHotspotBridge-eth")
HOTSPOT_CONN = os.environ.get("HOTSPOT_CONN", "PiHotspotBridge")
BRIDGE_IF = os.environ.get("BRIDGE_IF", "br0")
WLAN_IF = os.environ.get("WLAN_IF", "wlan0")
ETH_IF = os.environ.get("ETH_IF", "eth0")
HEALTH_HOST = os.environ.get("HEALTH_HOST", "0.0.0.0")
HEALTH_PORT = int(os.environ.get("HEALTH_PORT", "8788"))

def run_cmd(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except Exception as exc:
        return 1, "", str(exc)

def is_systemd_active(unit_name):
    rc, _, _ = run_cmd(["systemctl", "is-active", "--quiet", unit_name])
    return rc == 0

def conn_active(conn_name, dev):
    rc, stdout, _ = run_cmd(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"])
    if rc != 0:
        return False
    target = f"{conn_name}:{dev}"
    return any(line.strip() == target for line in stdout.splitlines())

def wifi_present():
    return os.path.exists(f"/sys/class/net/{WLAN_IF}")

def bridge_ip():
    rc, stdout, _ = run_cmd(["ip", "-4", "-o", "addr", "show", "dev", BRIDGE_IF])
    if rc != 0:
        return None
    for line in stdout.splitlines():
        parts = line.split()
        if "inet" in parts:
            return parts[parts.index("inet") + 1].split("/")[0]
    return None

def get_station_count():
    rc, stdout, _ = run_cmd(["iw", "dev", WLAN_IF, "station", "dump"])
    if rc != 0 or not stdout.strip():
        return 0
    return sum(1 for line in stdout.splitlines() if line.startswith("Station "))

def get_payload():
    nm_ok = is_systemd_active("NetworkManager.service")
    wlan_ok = wifi_present()
    bridge_ok = conn_active(BRIDGE_CONN, BRIDGE_IF)
    eth_slave_ok = conn_active(ETH_SLAVE_CONN, ETH_IF)
    hotspot_ok = conn_active(HOTSPOT_CONN, WLAN_IF)
    watchdog_ok = is_systemd_active("pi-hotspot-bridge-watchdog.timer")
    station_count = get_station_count()

    overall_ok = nm_ok and wlan_ok and bridge_ok and eth_slave_ok and hotspot_ok

    payload = {
        "status": "ok" if overall_ok else "degraded",
        "networkmanager": nm_ok,
        "wifi_present": wlan_ok,
        "bridge_active": bridge_ok,
        "ethernet_bridged": eth_slave_ok,
        "hotspot_active": hotspot_ok,
        "watchdog_timer_active": watchdog_ok,
        "client_count": station_count,
        "bridge_ip": bridge_ip(),
        "hotspot_connection": HOTSPOT_CONN,
        "bridge_if": BRIDGE_IF,
        "wlan_if": WLAN_IF,
        "eth_if": ETH_IF,
    }
    return payload, overall_ok

class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            payload, overall_ok = get_payload()
            self._send_json(200 if overall_ok else 503, payload)
            return

        if self.path == "/":
            self._send_json(200, {"message": "use /health"})
            return

        self._send_json(404, {"error": "not found"})

    def log_message(self, format_string, *args):
        return

def main():
    server = HTTPServer((HEALTH_HOST, HEALTH_PORT), Handler)
    server.serve_forever()

if __name__ == "__main__":
    main()
EOF

    chmod 755 "${HEALTH_SCRIPT}"
}

# -----------------------------
# Client viewer helper
# -----------------------------
write_clients_script() {
    log "Writing hotspot client viewer to ${CLIENTS_SCRIPT}..."

    cat > "${CLIENTS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash

WLAN_IF="${WLAN_IF:-wlan0}"
BRIDGE_IF="${BRIDGE_IF:-br0}"

declare -A IPS

ingest_ip_neigh() {
    local dev="$1"
    while read -r ip _ mac_addr _ state _; do
        [[ -z "${ip}" || -z "${mac_addr}" ]] && continue
        [[ "${mac_addr}" == "00:00:00:00:00:00" ]] && continue
        [[ ! "${mac_addr}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] && continue

        local mac_lc
        mac_lc="$(echo "${mac_addr}" | tr 'A-Z' 'a-z')"
        if [[ -z "${IPS[${mac_lc}]:-}" ]]; then
            IPS["${mac_lc}"]="${ip}"
        fi
    done < <(ip neigh show dev "${dev}" 2>/dev/null || true)
}

echo "=============================="
echo " Hotspot Bridge Clients (${WLAN_IF})"
echo "=============================="
echo
echo "[INFO] Bridge mode has no local DHCP server; IPs are resolved from the"
echo "       ARP/neighbor table and may show as 'unknown' until a client"
echo "       has sent at least one packet."
echo

# Clients get their IP from the upstream router across the bridge, so
# neighbor entries may be recorded against either the bridge or the
# wireless interface depending on kernel/driver behavior.
ingest_ip_neigh "${BRIDGE_IF}"
ingest_ip_neigh "${WLAN_IF}"

if iw dev "$WLAN_IF" station dump >/dev/null 2>&1; then
    station_output="$(iw dev "$WLAN_IF" station dump)"
    if [[ -z "$station_output" ]]; then
        echo "No connected Wi-Fi clients found."
        exit 0
    fi

    printf '%s\n' "$station_output" | awk '
        /^Station/ {mac=$2}
        /signal:/ {signal=$2}
        /connected time:/ {time=$3}
        /^$/ {
            printf "%s|%s|%s\n", mac, signal, time
        }
        END {
            if (mac != "" && signal != "" && time != "") {
                printf "%s|%s|%s\n", mac, signal, time
            }
        }
    ' | while IFS='|' read -r mac signal time; do
        [[ -z "$mac" ]] && continue
        mac_lc=$(echo "$mac" | tr 'A-Z' 'a-z')
        ip="${IPS[$mac_lc]:-unknown}"

        printf "Device: %s\n" "$mac"
        printf "  IP: %s\n" "$ip"
        printf "  Signal: %s dBm\n" "$signal"
        printf "  Connected: %s sec\n" "$time"
        echo
    done
else
    echo "[ERROR] Could not read station data from $WLAN_IF"
    exit 1
fi
EOF

    chmod 755 "${CLIENTS_SCRIPT}"
}

write_health_service() {
    log "Writing systemd health service..."

    cat > "${SYSTEMD_HEALTH_SERVICE}" <<EOF
[Unit]
Description=Raspberry Pi hotspot bridge health endpoint
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
Environment=BRIDGE_CONN=${BRIDGE_CONN}
Environment=ETH_SLAVE_CONN=${ETH_SLAVE_CONN}
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
Environment=BRIDGE_IF=${BRIDGE_IF}
Environment=WLAN_IF=${WLAN_IF}
Environment=ETH_IF=${ETH_IF}
Environment=HEALTH_HOST=${HEALTH_HOST}
Environment=HEALTH_PORT=${HEALTH_PORT}
ExecStart=/usr/bin/python3 ${HEALTH_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-hotspot-bridge-health.service
}

write_boot_script() {
    log "Writing boot-start script to ${BOOT_SCRIPT}..."

    cat > "${BOOT_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE_CONN="${BRIDGE_CONN:-PiHotspotBridge-br0}"
ETH_SLAVE_CONN="${ETH_SLAVE_CONN:-PiHotspotBridge-eth}"
HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspotBridge}"
BRIDGE_IF="${BRIDGE_IF:-br0}"
WLAN_IF="${WLAN_IF:-wlan0}"
ETH_IF="${ETH_IF:-eth0}"
LOG_TAG="pi-hotspot-bridge-boot"
MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-3}"

log() {
    logger -t "${LOG_TAG}" "$*"
    printf '[BOOT] %s\n' "$*"
}

conn_active() {
    local conn_name="$1" dev="$2"
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${conn_name}:${dev}$"
}

fully_active() {
    conn_active "${BRIDGE_CONN}" "${BRIDGE_IF}" \
        && conn_active "${ETH_SLAVE_CONN}" "${ETH_IF}" \
        && conn_active "${HOTSPOT_CONN}" "${WLAN_IF}"
}

main() {
    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if fully_active; then
            log "Bridge hotspot is already active."
            exit 0
        fi

        log "Attempt ${attempt}/${MAX_RETRIES}: activating bridge hotspot..."
        nmcli connection up "${BRIDGE_CONN}" >/dev/null 2>&1 || true
        nmcli connection up "${ETH_SLAVE_CONN}" >/dev/null 2>&1 || true
        nmcli connection up "${HOTSPOT_CONN}" >/dev/null 2>&1 || true
        sleep "${SLEEP_SECONDS}"

        if fully_active; then
            log "Bridge hotspot is active after boot."
            exit 0
        fi

        attempt=$((attempt + 1))
    done

    log "Failed to activate bridge hotspot after ${MAX_RETRIES} attempts."
    exit 1
}

main "$@"
EOF

    chmod 755 "${BOOT_SCRIPT}"
}

write_boot_service() {
    log "Writing systemd boot-start service..."

    cat > "${SYSTEMD_BOOT_SERVICE}" <<EOF
[Unit]
Description=Ensure Raspberry Pi hotspot bridge is active after boot
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
Environment=BRIDGE_CONN=${BRIDGE_CONN}
Environment=ETH_SLAVE_CONN=${ETH_SLAVE_CONN}
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
Environment=BRIDGE_IF=${BRIDGE_IF}
Environment=WLAN_IF=${WLAN_IF}
Environment=ETH_IF=${ETH_IF}
ExecStart=${BOOT_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-hotspot-bridge-boot.service
}

write_systemd_units() {
    log "Writing systemd watchdog service and timer..."

    cat > "${SYSTEMD_WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=Raspberry Pi hotspot bridge watchdog
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
Environment=BRIDGE_CONN=${BRIDGE_CONN}
Environment=ETH_SLAVE_CONN=${ETH_SLAVE_CONN}
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
Environment=BRIDGE_IF=${BRIDGE_IF}
Environment=WLAN_IF=${WLAN_IF}
Environment=ETH_IF=${ETH_IF}
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > "${SYSTEMD_WATCHDOG_TIMER}" <<EOF
[Unit]
Description=Run Raspberry Pi hotspot bridge watchdog every ${WATCHDOG_INTERVAL}

[Timer]
OnBootSec=20s
OnUnitActiveSec=${WATCHDOG_INTERVAL}
Unit=pi-hotspot-bridge-watchdog.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-hotspot-bridge-watchdog.timer
}

# -----------------------------
# Validation / output
# -----------------------------
show_status() {
    echo
    log "Hotspot bridge setup complete."
    echo
    echo "SSID:            ${SSID}"
    echo "Password:        ${PASSWORD}"
    echo "Wi-Fi IF:        ${WLAN_IF}"
    echo "Ethernet IF:     ${ETH_IF}"
    echo "Bridge IF:       ${BRIDGE_IF}"
    echo "Health URL:      http://${HEALTH_HOST}:${HEALTH_PORT}/health"
    echo "Clients tool:    ${CLIENTS_SCRIPT}"
    echo
    echo "Saved NetworkManager connections:"
    nmcli connection show || true
    echo
    echo "Active connections:"
    nmcli connection show --active || true
    echo
    echo "Device status:"
    nmcli device status || true
    echo
    echo "Watchdog timer:"
    systemctl --no-pager --full status pi-hotspot-bridge-watchdog.timer || true
    echo
    echo "Boot-start service:"
    systemctl --no-pager --full status pi-hotspot-bridge-boot.service || true
    echo
    echo "Health service:"
    systemctl --no-pager --full status pi-hotspot-bridge-health.service || true
    echo
    echo "Useful commands:"
    echo "  nmcli connection show"
    echo "  nmcli connection show --active"
    echo "  nmcli device status"
    echo "  curl http://127.0.0.1:${HEALTH_PORT}/health"
    echo "  ${CLIENTS_SCRIPT}"
    echo "  watch -n 2 ${CLIENTS_SCRIPT}"
    echo "  sudo journalctl -u NetworkManager -n 100 --no-pager"
    echo "  sudo journalctl -u pi-hotspot-bridge-watchdog.service -n 50 --no-pager"
    echo "  sudo journalctl -u pi-hotspot-bridge-health.service -n 50 --no-pager"
    echo
}

post_check() {
    if nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${HOTSPOT_CONN}:${WLAN_IF}$" \
        && nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${ETH_SLAVE_CONN}:${ETH_IF}$"; then
        log "Verified: bridge hotspot '${HOTSPOT_CONN}' is active on ${WLAN_IF}, bridged with ${ETH_IF}."
    else
        warn "Bridge hotspot is not fully active yet."
        warn "Try these commands next:"
        warn "  nmcli connection show --active"
        warn "  nmcli device status"
        warn "  sudo journalctl -u NetworkManager -n 100 --no-pager"
    fi
}

main() {
    require_root
    require_interactive_or_env
    prompt_for_ssid
    prompt_for_password
    validate_inputs
    check_interfaces
    install_dependencies
    enable_networkmanager
    set_wifi_country
    ensure_nm_manages_interfaces
    remove_existing_profiles
    disable_conflicting_ethernet_profiles
    disconnect_wlan_if_needed
    create_bridge_profile
    create_eth_slave_profile
    create_wifi_ap_slave_profile
    bring_up_bridge
    write_watchdog_script
    write_boot_script
    write_health_script
    write_clients_script
    write_systemd_units
    write_boot_service
    write_health_service
    post_check
    show_status
}

main "$@"
