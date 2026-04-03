#!/usr/bin/env bash
set -euo pipefail

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspot}"

WATCHDOG_SCRIPT="/usr/local/sbin/pi-hotspot-watchdog.sh"
HEALTH_SCRIPT="/usr/local/sbin/pi-hotspot-health.py"

SYSTEMD_WATCHDOG_SERVICE="/etc/systemd/system/pi-hotspot-watchdog.service"
SYSTEMD_WATCHDOG_TIMER="/etc/systemd/system/pi-hotspot-watchdog.timer"
SYSTEMD_HEALTH_SERVICE="/etc/systemd/system/pi-hotspot-health.service"

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
    log "Stopping and disabling hotspot watchdog and health service if present..."
    systemctl stop pi-hotspot-watchdog.timer 2>/dev/null || true
    systemctl disable pi-hotspot-watchdog.timer 2>/dev/null || true
    systemctl stop pi-hotspot-watchdog.service 2>/dev/null || true
    systemctl disable pi-hotspot-watchdog.service 2>/dev/null || true

    systemctl stop pi-hotspot-health.service 2>/dev/null || true
    systemctl disable pi-hotspot-health.service 2>/dev/null || true
}

remove_systemd_units() {
    log "Removing systemd unit files..."
    rm -f "${SYSTEMD_WATCHDOG_SERVICE}"
    rm -f "${SYSTEMD_WATCHDOG_TIMER}"
    rm -f "${SYSTEMD_HEALTH_SERVICE}"
    systemctl daemon-reload
    systemctl reset-failed || true
}

remove_scripts() {
    log "Removing helper scripts..."
    rm -f "${WATCHDOG_SCRIPT}"
    rm -f "${HEALTH_SCRIPT}"
}

remove_hotspot_connection() {
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f NAME connection show | grep -qx "${HOTSPOT_CONN}"; then
            log "Bringing down hotspot connection '${HOTSPOT_CONN}'..."
            nmcli connection down "${HOTSPOT_CONN}" 2>/dev/null || true

            log "Deleting hotspot connection '${HOTSPOT_CONN}'..."
            nmcli connection delete "${HOTSPOT_CONN}" || true
        fi
    fi
}

restart_networkmanager() {
    if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        log "Restarting NetworkManager..."
        systemctl restart NetworkManager || true
    fi
}

optionally_remove_packages() {
    if [[ "${REMOVE_PACKAGES}" == "1" ]]; then
        log "Removing hotspot-related packages..."
        apt-get remove -y network-manager dnsmasq wireless-regdb iw rfkill python3 || true
        apt-get autoremove -y || true
    else
        log "Leaving installed packages in place."
        log "To remove them too, run:"
        log "  sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot.sh"
    fi
}

main() {
    require_root
    stop_and_disable_services
    remove_systemd_units
    remove_scripts
    remove_hotspot_connection
    restart_networkmanager
    optionally_remove_packages
    log "Uninstall complete."
}

main "$@"
