#!/usr/bin/env bash
set -euo pipefail

BRIDGE_CONN="${BRIDGE_CONN:-PiHotspotBridge-br0}"
ETH_SLAVE_CONN="${ETH_SLAVE_CONN:-PiHotspotBridge-eth}"
HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspotBridge}"

WATCHDOG_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-watchdog.sh"
BOOT_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-boot.sh"
HEALTH_SCRIPT="/usr/local/sbin/pi-hotspot-bridge-health.py"
CLIENTS_SCRIPT="/usr/local/bin/pi-hotspot-bridge-clients.sh"

SYSTEMD_WATCHDOG_SERVICE="/etc/systemd/system/pi-hotspot-bridge-watchdog.service"
SYSTEMD_WATCHDOG_TIMER="/etc/systemd/system/pi-hotspot-bridge-watchdog.timer"
SYSTEMD_HEALTH_SERVICE="/etc/systemd/system/pi-hotspot-bridge-health.service"
SYSTEMD_BOOT_SERVICE="/etc/systemd/system/pi-hotspot-bridge-boot.service"

REMOVE_PACKAGES="${REMOVE_PACKAGES:-0}"

log() {
    printf '[INFO] %s\n' "$*"
}

err() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "Run this script with sudo or as root."
    fi
}

stop_and_disable_services() {
    log "Stopping and disabling hotspot bridge watchdog, boot, and health services if present..."
    systemctl stop pi-hotspot-bridge-watchdog.timer 2>/dev/null || true
    systemctl disable pi-hotspot-bridge-watchdog.timer 2>/dev/null || true
    systemctl stop pi-hotspot-bridge-watchdog.service 2>/dev/null || true
    systemctl disable pi-hotspot-bridge-watchdog.service 2>/dev/null || true

    systemctl stop pi-hotspot-bridge-boot.service 2>/dev/null || true
    systemctl disable pi-hotspot-bridge-boot.service 2>/dev/null || true

    systemctl stop pi-hotspot-bridge-health.service 2>/dev/null || true
    systemctl disable pi-hotspot-bridge-health.service 2>/dev/null || true
}

remove_systemd_units() {
    log "Removing systemd unit files..."
    rm -f "${SYSTEMD_WATCHDOG_SERVICE}"
    rm -f "${SYSTEMD_WATCHDOG_TIMER}"
    rm -f "${SYSTEMD_HEALTH_SERVICE}"
    rm -f "${SYSTEMD_BOOT_SERVICE}"
    systemctl daemon-reload
    systemctl reset-failed || true
}

remove_scripts() {
    log "Removing helper scripts..."
    rm -f "${WATCHDOG_SCRIPT}"
    rm -f "${BOOT_SCRIPT}"
    rm -f "${HEALTH_SCRIPT}"
    rm -f "${CLIENTS_SCRIPT}"
}

remove_bridge_connections() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return
    fi

    local name
    for name in "${HOTSPOT_CONN}" "${ETH_SLAVE_CONN}" "${BRIDGE_CONN}"; do
        if nmcli -t -f NAME connection show | grep -qx "${name}"; then
            log "Bringing down connection '${name}'..."
            nmcli connection down "${name}" 2>/dev/null || true

            log "Deleting connection '${name}'..."
            nmcli connection delete "${name}" || true
        fi
    done
}

restart_networkmanager() {
    if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        log "Restarting NetworkManager..."
        systemctl restart NetworkManager || true
    fi
}

optionally_remove_packages() {
    if [[ "${REMOVE_PACKAGES}" == "1" ]]; then
        log "Removing hotspot-bridge-related packages..."
        apt-get remove -y network-manager wireless-regdb iw rfkill || true
        apt-get autoremove -y || true
    else
        log "Leaving installed packages in place."
        log "To remove them too, run:"
        log "  sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot_bridge.sh"
    fi
}

main() {
    require_root
    stop_and_disable_services
    remove_systemd_units
    remove_scripts
    remove_bridge_connections
    restart_networkmanager
    optionally_remove_packages
    log "Uninstall complete."
}

main "$@"
