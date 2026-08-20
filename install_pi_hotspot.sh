#!/usr/bin/env bash
set -euo pipefail

########################################
# Raspberry Pi Trixie Ethernet -> Wi-Fi Hotspot Installer
# - Uses NetworkManager shared mode
# - Shares Ethernet uplink over Wi-Fi AP
# - Prompts interactively for SSID, password, and network visibility
#   (no shipped defaults)
# - Installs dependencies automatically
# - Disables standalone dnsmasq service to avoid conflicts
# - Creates a watchdog service + timer
# - Exposes /health endpoint on configurable port
# - Installs pi-hotspot-clients.sh helper
########################################

# -----------------------------
# User-configurable defaults
# -----------------------------
SSID="${SSID:-}"
PASSWORD="${PASSWORD:-}"
HIDDEN="${HIDDEN:-}"
COUNTRY="${COUNTRY:-US}"

ETH_IF="${ETH_IF:-eth0}"
WLAN_IF="${WLAN_IF:-wlan0}"

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspot}"
HOTSPOT_IP_CIDR="${HOTSPOT_IP_CIDR:-10.42.0.1/24}"
HOTSPOT_GATEWAY_IP="${HOTSPOT_GATEWAY_IP:-10.42.0.1}"

WIFI_BAND="${WIFI_BAND:-bg}"
# "auto" scans for nearby Wi-Fi networks and picks the least congested channel
# for WIFI_BAND. Set an explicit channel number to skip scanning.
WIFI_CHANNEL="${WIFI_CHANNEL:-auto}"

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30s}"

HEALTH_HOST="${HEALTH_HOST:-0.0.0.0}"
HEALTH_PORT="${HEALTH_PORT:-8787}"

WATCHDOG_SCRIPT="/usr/local/sbin/pi-hotspot-watchdog.sh"
BOOT_SCRIPT="/usr/local/sbin/pi-hotspot-boot.sh"
HEALTH_SCRIPT="/usr/local/sbin/pi-hotspot-health.py"
CLIENTS_SCRIPT="/usr/local/bin/pi-hotspot-clients.sh"

SYSTEMD_WATCHDOG_SERVICE="/etc/systemd/system/pi-hotspot-watchdog.service"
SYSTEMD_WATCHDOG_TIMER="/etc/systemd/system/pi-hotspot-watchdog.timer"
SYSTEMD_HEALTH_SERVICE="/etc/systemd/system/pi-hotspot-health.service"
SYSTEMD_BOOT_SERVICE="/etc/systemd/system/pi-hotspot-boot.service"

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

prompt_for_hidden() {
    if [[ -z "${HIDDEN}" ]]; then
        if [[ ! -t 0 ]]; then
            HIDDEN="no"
            return
        fi

        local answer
        read -r -p "Should the network be hidden instead of visible? (y/N): " answer
        case "${answer}" in
            [Yy]*) HIDDEN="yes" ;;
            *) HIDDEN="no" ;;
        esac
        return
    fi

    case "${HIDDEN}" in
        1|yes|Yes|YES|true|True|TRUE) HIDDEN="yes" ;;
        0|no|No|NO|false|False|FALSE) HIDDEN="no" ;;
        *) err "HIDDEN must be one of: yes, no." ;;
    esac
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
        dnsmasq \
        wireless-regdb \
        iw \
        rfkill \
        python3

    log "Stopping standalone dnsmasq service so NetworkManager can manage DHCP/NAT shared mode cleanly..."
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
remove_existing_hotspot_profiles() {
    log "Removing old/conflicting hotspot-style Wi-Fi profiles..."

    local existing_names
    existing_names="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" || $2=="wifi" {print $1}')"

    while IFS= read -r conn_name; do
        [[ -z "${conn_name}" ]] && continue

        if [[ "${conn_name}" == "${HOTSPOT_CONN}" ]]; then
            log "Removing existing connection '${conn_name}'..."
            nmcli connection down "${conn_name}" 2>/dev/null || true
            nmcli connection delete "${conn_name}" 2>/dev/null || true
            continue
        fi

        local conn_ssid=""
        conn_ssid="$(nmcli -g 802-11-wireless.ssid connection show "${conn_name}" 2>/dev/null || true)"
        if [[ "${conn_ssid}" == "${SSID}" ]]; then
            log "Removing connection '${conn_name}' because it matches target SSID '${SSID}'..."
            nmcli connection down "${conn_name}" 2>/dev/null || true
            nmcli connection delete "${conn_name}" 2>/dev/null || true
        fi
    done <<< "${existing_names}"
}

disconnect_wlan_if_needed() {
    log "Disconnecting ${WLAN_IF} before hotspot creation..."
    nmcli device disconnect "${WLAN_IF}" 2>/dev/null || true
    sleep 2
}

# -----------------------------
# Wi-Fi channel scanning
# -----------------------------
# Picks the least congested channel for WIFI_BAND by scanning nearby networks
# with nmcli and scoring each candidate channel by how many nearby networks
# are on it (or, for 2.4GHz, within 2 channels of it, since 20MHz channels
# overlap with their neighbors).
select_best_wifi_channel() {
    if [[ "${WIFI_CHANNEL}" != "auto" ]]; then
        log "Using manually specified Wi-Fi channel ${WIFI_CHANNEL}."
        return
    fi

    log "Scanning nearby Wi-Fi networks on ${WLAN_IF} to pick the least congested channel..."

    local candidates=()
    if [[ "${WIFI_BAND}" == "a" ]]; then
        candidates=(36 40 44 48 149 153 157 161 165)
    else
        candidates=(1 6 11)
    fi

    local scan_output
    scan_output="$(nmcli -t -f CHAN device wifi list ifname "${WLAN_IF}" --rescan yes 2>/dev/null | grep -E '^[0-9]+$' || true)"

    if [[ -z "${scan_output}" ]]; then
        WIFI_CHANNEL="${candidates[0]}"
        warn "Wi-Fi scan found no nearby networks; defaulting to channel ${WIFI_CHANNEL}."
        return
    fi

    local detected_channels=()
    local ch
    while IFS= read -r ch; do
        [[ -n "${ch}" ]] && detected_channels+=("${ch}")
    done <<< "${scan_output}"

    local best_channel="" best_score="" candidate score diff
    for candidate in "${candidates[@]}"; do
        score=0
        for ch in "${detected_channels[@]}"; do
            if [[ "${WIFI_BAND}" == "a" ]]; then
                (( ch == candidate )) && score=$((score + 1))
            else
                diff=$(( ch - candidate ))
                (( diff < 0 )) && diff=$(( -diff ))
                (( diff <= 2 )) && score=$((score + 1))
            fi
        done

        if [[ -z "${best_score}" ]] || (( score < best_score )); then
            best_score="${score}"
            best_channel="${candidate}"
        fi
    done

    WIFI_CHANNEL="${best_channel}"
    log "Selected Wi-Fi channel ${WIFI_CHANNEL} for band '${WIFI_BAND}' (nearby-network score ${best_score}; candidates: ${candidates[*]})."
}

# -----------------------------
# Hotspot creation
# -----------------------------
create_hotspot_profile() {
    log "Creating hotspot connection '${HOTSPOT_CONN}' on ${WLAN_IF}..."

    nmcli connection add \
        type wifi \
        ifname "${WLAN_IF}" \
        con-name "${HOTSPOT_CONN}" \
        ssid "${SSID}" \
        autoconnect yes

    nmcli connection modify "${HOTSPOT_CONN}" \
        802-11-wireless.mode ap \
        802-11-wireless.band "${WIFI_BAND}" \
        802-11-wireless.channel "${WIFI_CHANNEL}" \
        802-11-wireless.hidden "${HIDDEN}" \
        802-11-wireless.powersave 2 \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.proto rsn \
        wifi-sec.pairwise ccmp \
        wifi-sec.group ccmp \
        wifi-sec.psk "${PASSWORD}" \
        ipv4.method shared \
        ipv4.addresses "${HOTSPOT_IP_CIDR}" \
        ipv4.never-default yes \
        ipv6.method disabled \
        connection.interface-name "${WLAN_IF}" \
        connection.autoconnect yes \
        connection.autoconnect-retries -1 \
        connection.autoconnect-priority 50

    if nmcli -t -f NAME connection show | grep -qx "Wired connection 1"; then
        nmcli connection modify "Wired connection 1" connection.autoconnect yes || true
        nmcli connection modify "Wired connection 1" connection.autoconnect-priority 100 || true
    fi
}

bring_up_hotspot() {
    log "Bringing up hotspot..."
    nmcli connection up "${HOTSPOT_CONN}" || err "Failed to activate hotspot '${HOTSPOT_CONN}'."
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

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspot}"
WLAN_IF="${WLAN_IF:-wlan0}"
ETH_IF="${ETH_IF:-eth0}"
LOG_TAG="pi-hotspot-watchdog"

log() {
    logger -t "${LOG_TAG}" "$*"
    printf '[WATCHDOG] %s\n' "$*"
}

nm_ok() {
    systemctl is-active --quiet NetworkManager
}

wifi_present() {
    ip link show "${WLAN_IF}" >/dev/null 2>&1
}

hotspot_active() {
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${HOTSPOT_CONN}:${WLAN_IF}$"
}

wifi_connected_as_client() {
    local state connection
    state="$(nmcli -t -f GENERAL.STATE device show "${WLAN_IF}" 2>/dev/null | sed 's/^GENERAL.STATE://')"
    connection="$(nmcli -t -f GENERAL.CONNECTION device show "${WLAN_IF}" 2>/dev/null | sed 's/^GENERAL.CONNECTION://')"

    [[ "${state}" == "100 (connected)" && "${connection}" != "${HOTSPOT_CONN}" ]]
}

ensure_dnsmasq_not_conflicting() {
    systemctl stop dnsmasq >/dev/null 2>&1 || true
    systemctl disable dnsmasq >/dev/null 2>&1 || true
}

recover_hotspot() {
    log "Hotspot '${HOTSPOT_CONN}' is not active on ${WLAN_IF}. Attempting recovery."

    nmcli device disconnect "${WLAN_IF}" >/dev/null 2>&1 || true
    sleep 2

    nmcli connection down "${HOTSPOT_CONN}" >/dev/null 2>&1 || true
    sleep 2

    nmcli connection up "${HOTSPOT_CONN}" >/dev/null 2>&1 || {
        log "Recovery failed for hotspot '${HOTSPOT_CONN}'."
        exit 1
    }

    sleep 4

    if hotspot_active; then
        log "Hotspot '${HOTSPOT_CONN}' recovered."
    else
        log "Recovery command completed but hotspot '${HOTSPOT_CONN}' is still not active on ${WLAN_IF}."
        exit 1
    fi
}

main() {
    if ! nm_ok; then
        log "NetworkManager is not active; restarting it."
        systemctl restart NetworkManager || exit 1
        sleep 4
    fi

    if ! wifi_present; then
        log "Wi-Fi interface '${WLAN_IF}' not found."
        exit 1
    fi

    ensure_dnsmasq_not_conflicting

    if wifi_connected_as_client; then
        log "Wi-Fi interface '${WLAN_IF}' appears to be connected as a client; leaving it alone."
        exit 0
    fi

    if hotspot_active; then
        exit 0
    fi

    recover_hotspot
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

HOTSPOT_CONN = os.environ.get("HOTSPOT_CONN", "PiHotspot")
WLAN_IF = os.environ.get("WLAN_IF", "wlan0")
ETH_IF = os.environ.get("ETH_IF", "eth0")
HEALTH_HOST = os.environ.get("HEALTH_HOST", "0.0.0.0")
HEALTH_PORT = int(os.environ.get("HEALTH_PORT", "8787"))

def run_cmd(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except Exception as exc:
        return 1, "", str(exc)

def is_systemd_active(unit_name):
    rc, _, _ = run_cmd(["systemctl", "is-active", "--quiet", unit_name])
    return rc == 0

def ethernet_connected():
    rc, stdout, _ = run_cmd(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"])
    if rc != 0:
        return False
    for line in stdout.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[0] == ETH_IF and parts[1] == "ethernet" and parts[2] == "connected":
            return True
    return False

def wifi_present():
    return os.path.exists(f"/sys/class/net/{WLAN_IF}")

def hotspot_active():
    rc, stdout, _ = run_cmd(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"])
    if rc != 0:
        return False
    target = f"{HOTSPOT_CONN}:{WLAN_IF}"
    return any(line.strip() == target for line in stdout.splitlines())

def get_station_count():
    rc, stdout, _ = run_cmd(["iw", "dev", WLAN_IF, "station", "dump"])
    if rc != 0 or not stdout.strip():
        return 0
    return sum(1 for line in stdout.splitlines() if line.startswith("Station "))

def get_payload():
    nm_ok = is_systemd_active("NetworkManager.service")
    eth_ok = ethernet_connected()
    wlan_ok = wifi_present()
    hotspot_ok = hotspot_active()
    watchdog_ok = is_systemd_active("pi-hotspot-watchdog.timer")
    station_count = get_station_count()

    overall_ok = nm_ok and wlan_ok and hotspot_ok

    payload = {
        "status": "ok" if overall_ok else "degraded",
        "networkmanager": nm_ok,
        "ethernet_connected": eth_ok,
        "wifi_present": wlan_ok,
        "hotspot_active": hotspot_ok,
        "watchdog_timer_active": watchdog_ok,
        "client_count": station_count,
        "hotspot_connection": HOTSPOT_CONN,
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
LEASE_FILE_DEFAULT="/var/lib/NetworkManager/dnsmasq-${WLAN_IF}.leases"

ingest_lease_file() {
    local lease_file="$1"
    while read -r expiry mac ip host _; do
        [[ -z "${mac}" || -z "${ip}" ]] && continue
        mac="$(echo "${mac}" | tr 'A-Z' 'a-z')"
        IPS["${mac}"]="${ip}"
        if [[ -n "${host:-}" && "${host}" != "*" ]]; then
            HOSTS["${mac}"]="${host}"
        fi
    done < "${lease_file}"
}

ingest_ip_neigh() {
    while read -r ip _ mac_addr _ state _; do
        [[ -z "${ip}" || -z "${mac_addr}" ]] && continue
        [[ "${mac_addr}" == "00:00:00:00:00:00" ]] && continue
        [[ ! "${mac_addr}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] && continue

        local mac_lc
        mac_lc="$(echo "${mac_addr}" | tr 'A-Z' 'a-z')"
        if [[ -z "${IPS[${mac_lc}]:-}" ]]; then
            IPS["${mac_lc}"]="${ip}"
        fi
    done < <(ip neigh show dev "${WLAN_IF}" 2>/dev/null || true)
}

resolve_lease_file() {
    local candidates=(
        "${LEASE_FILE_DEFAULT}"
        "/var/lib/NetworkManager/dnsmasq-shared-${WLAN_IF}.leases"
        "/var/lib/NetworkManager/internal-dnsmasq-${WLAN_IF}.leases"
        "/var/lib/misc/dnsmasq.leases"
    )
    local glob_candidates=(
        "/var/lib/NetworkManager/*.leases"
        "/run/NetworkManager/*.leases"
        "/run/NetworkManager/dnsmasq*.leases"
        "/run/NetworkManager/*dnsmasq*.lease*"
        "/var/lib/misc/*.leases"
        "/tmp/dnsmasq*.leases"
    )

    local lease_file
    for lease_file in "${candidates[@]}"; do
        if [[ -f "${lease_file}" ]]; then
            printf '%s\n' "${lease_file}"
            return 0
        fi
    done

    local pattern
    for pattern in "${glob_candidates[@]}"; do
        for lease_file in $pattern; do
            [[ "${lease_file}" == "$pattern" ]] && continue
            [[ ! -f "${lease_file}" ]] && continue
            printf '%s\n' "${lease_file}"
            return 0
        done
    done

    return 1
}

echo "=============================="
echo " Hotspot Clients (${WLAN_IF})"
echo "=============================="
echo

declare -A IPS
declare -A HOSTS

if LEASE_FILE="$(resolve_lease_file)"; then
    echo "Using lease file: $LEASE_FILE"
    ingest_lease_file "$LEASE_FILE"
else
    echo "[WARN] Lease file not found. Checked:"
    echo "  - $LEASE_FILE_DEFAULT"
    echo "  - /var/lib/NetworkManager/dnsmasq-shared-${WLAN_IF}.leases"
    echo "  - /var/lib/NetworkManager/internal-dnsmasq-${WLAN_IF}.leases"
    echo "  - /var/lib/misc/dnsmasq.leases"
    echo "  - /var/lib/NetworkManager/*.leases"
    echo "  - /run/NetworkManager/*.leases"
    echo "  - /run/NetworkManager/dnsmasq*.leases"
    echo "  - /run/NetworkManager/*dnsmasq*.lease*"
    echo "  - /var/lib/misc/*.leases"
    echo "  - /tmp/dnsmasq*.leases"
    echo "[INFO] Falling back to ARP/neighbor table for IP lookup."
fi

ingest_ip_neigh

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
        host="${HOSTS[$mac_lc]:-unknown}"

        printf "Device: %s\n" "$mac"
        printf "  IP: %s\n" "$ip"
        printf "  Host: %s\n" "$host"
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
Description=Raspberry Pi hotspot health endpoint
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
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
    systemctl enable --now pi-hotspot-health.service
}

write_boot_script() {
    log "Writing boot-start script to ${BOOT_SCRIPT}..."

    cat > "${BOOT_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspot}"
WLAN_IF="${WLAN_IF:-wlan0}"
LOG_TAG="pi-hotspot-boot"
MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SECONDS="${SLEEP_SECONDS:-3}"

log() {
    logger -t "${LOG_TAG}" "$*"
    printf '[BOOT] %s\n' "$*"
}

hotspot_active() {
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^${HOTSPOT_CONN}:${WLAN_IF}$"
}

main() {
    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if hotspot_active; then
            log "Hotspot '${HOTSPOT_CONN}' is already active on ${WLAN_IF}."
            exit 0
        fi

        log "Attempt ${attempt}/${MAX_RETRIES}: activating hotspot '${HOTSPOT_CONN}' on ${WLAN_IF}..."
        nmcli connection up "${HOTSPOT_CONN}" >/dev/null 2>&1 || true
        sleep "${SLEEP_SECONDS}"

        if hotspot_active; then
            log "Hotspot '${HOTSPOT_CONN}' is active after boot."
            exit 0
        fi

        attempt=$((attempt + 1))
    done

    log "Failed to activate hotspot '${HOTSPOT_CONN}' after ${MAX_RETRIES} attempts."
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
Description=Ensure Raspberry Pi hotspot is active after boot
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
Environment=WLAN_IF=${WLAN_IF}
ExecStart=${BOOT_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-hotspot-boot.service
}

write_systemd_units() {
    log "Writing systemd watchdog service and timer..."

    cat > "${SYSTEMD_WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=Raspberry Pi hotspot watchdog
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
Environment=HOTSPOT_CONN=${HOTSPOT_CONN}
Environment=WLAN_IF=${WLAN_IF}
Environment=ETH_IF=${ETH_IF}
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > "${SYSTEMD_WATCHDOG_TIMER}" <<EOF
[Unit]
Description=Run Raspberry Pi hotspot watchdog every ${WATCHDOG_INTERVAL}

[Timer]
OnBootSec=20s
OnUnitActiveSec=${WATCHDOG_INTERVAL}
Unit=pi-hotspot-watchdog.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-hotspot-watchdog.timer
}

# -----------------------------
# Validation / output
# -----------------------------
show_status() {
    echo
    log "Hotspot setup complete."
    echo
    echo "SSID:          ${SSID}"
    echo "Password:      ${PASSWORD}"
    echo "Visibility:    $([[ "${HIDDEN}" == "yes" ]] && echo "hidden" || echo "visible")"
    echo "Wi-Fi IF:      ${WLAN_IF}"
    echo "Wi-Fi band:    ${WIFI_BAND}"
    echo "Wi-Fi channel: ${WIFI_CHANNEL}"
    echo "Uplink IF:     ${ETH_IF}"
    echo "Gateway:       ${HOTSPOT_GATEWAY_IP}"
    echo "Health URL:    http://${HEALTH_HOST}:${HEALTH_PORT}/health"
    echo "Clients tool:  ${CLIENTS_SCRIPT}"
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
    systemctl --no-pager --full status pi-hotspot-watchdog.timer || true
    echo
    echo "Boot-start service:"
    systemctl --no-pager --full status pi-hotspot-boot.service || true
    echo
    echo "Health service:"
    systemctl --no-pager --full status pi-hotspot-health.service || true
    echo
    echo "Useful commands:"
    echo "  nmcli connection show"
    echo "  nmcli connection show --active"
    echo "  nmcli device status"
    echo "  curl http://127.0.0.1:${HEALTH_PORT}/health"
    echo "  ${CLIENTS_SCRIPT}"
    echo "  watch -n 2 ${CLIENTS_SCRIPT}"
    echo "  sudo journalctl -u NetworkManager -n 100 --no-pager"
    echo "  sudo journalctl -u pi-hotspot-watchdog.service -n 50 --no-pager"
    echo "  sudo journalctl -u pi-hotspot-health.service -n 50 --no-pager"
    echo
}

post_check() {
    local active_line
    active_line="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep "^${HOTSPOT_CONN}:${WLAN_IF}$" || true)"

    if [[ -n "${active_line}" ]]; then
        log "Verified: hotspot '${HOTSPOT_CONN}' is active on ${WLAN_IF}."
    else
        warn "Hotspot '${HOTSPOT_CONN}' is not currently shown as active on ${WLAN_IF}."
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
    prompt_for_hidden
    validate_inputs
    check_interfaces
    install_dependencies
    enable_networkmanager
    set_wifi_country
    ensure_nm_manages_interfaces
    remove_existing_hotspot_profiles
    disconnect_wlan_if_needed
    select_best_wifi_channel
    create_hotspot_profile
    bring_up_hotspot
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
