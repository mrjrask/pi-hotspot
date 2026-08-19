#!/usr/bin/env bash
set -euo pipefail

########################################
# Uninstaller safety model
# -------------------------------------
# - Removing systemd units/scripts/NetworkManager connections created by
#   this project's installer is always safe and always happens.
# - Removing packages is opt-in (REMOVE_PACKAGES=1) and never touches
#   `python3` — it's a base system dependency (used by apt/dpkg triggers,
#   raspi-config, etc.) and removing it can cascade into removing
#   unrelated parts of the OS via `apt-get autoremove`.
# - Removing `network-manager` is a *separate*, extra opt-in
#   (REMOVE_NETWORK_MANAGER=1) on top of REMOVE_PACKAGES=1, because it is
#   the Pi's active network stack: removing it can immediately drop your
#   SSH session and leave the Pi with no way to reach the network at all
#   until someone reconfigures networking from a physical console.
# - Any actual package removal requires interactive confirmation (type
#   REMOVE) or FORCE=1 for non-interactive/scripted use.
# - `apt-get autoremove` is never run automatically; it's a separate
#   opt-in (AUTOREMOVE=1) because it can remove unrelated packages that
#   merely happen to no longer be "required" by anything else.
#
# If a removed package breaks something you still need, run
# reinstall_pi_hotspot_dependencies.sh to put the packages back.
########################################

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
REMOVE_NETWORK_MANAGER="${REMOVE_NETWORK_MANAGER:-0}"
AUTOREMOVE="${AUTOREMOVE:-0}"
FORCE="${FORCE:-0}"

# Packages that are safe to offer for removal: they were installed by
# install_pi_hotspot_bridge.sh and aren't core system dependencies.
# Deliberately excludes `python3` (base system dependency) and
# `network-manager` (the active network stack; gated separately behind
# REMOVE_NETWORK_MANAGER).
REMOVABLE_PACKAGES=(wireless-regdb iw rfkill)

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

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "Run this script with sudo or as root."
    fi
}

confirm_removal() {
    local prompt="$1"

    if [[ "${FORCE}" == "1" ]]; then
        log "FORCE=1 set; skipping confirmation prompt."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        err "No TTY detected for confirmation prompt. Re-run with FORCE=1 to skip it non-interactively."
    fi

    local reply
    read -r -p "${prompt} Type REMOVE to continue: " reply
    if [[ "${reply}" != "REMOVE" ]]; then
        log "Confirmation not received; skipping package removal."
        return 1
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
    if [[ "${REMOVE_PACKAGES}" != "1" ]]; then
        log "Leaving installed packages in place."
        log "To remove them too, run:"
        log "  sudo REMOVE_PACKAGES=1 bash uninstall_pi_hotspot_bridge.sh"
        return
    fi

    local packages=("${REMOVABLE_PACKAGES[@]}")

    if [[ "${REMOVE_NETWORK_MANAGER}" == "1" ]]; then
        warn "REMOVE_NETWORK_MANAGER=1 set: this will remove 'network-manager', the Pi's"
        warn "active network stack. If this session is connected over an interface"
        warn "NetworkManager manages (e.g. SSH over the bridge or a NetworkManager-managed"
        warn "Ethernet link), you can lose connectivity immediately and need physical/console"
        warn "access to recover."
        packages+=(network-manager)
    fi

    log "Packages to remove: ${packages[*]}"
    log "(python3 is never removed; it is a base system dependency.)"

    if ! confirm_removal "About to run: apt-get remove -y ${packages[*]}"; then
        return
    fi

    log "Removing hotspot-bridge-related packages..."
    apt-get remove -y "${packages[@]}" || true

    if [[ "${AUTOREMOVE}" == "1" ]]; then
        warn "AUTOREMOVE=1 set: running apt-get autoremove, which can remove other"
        warn "packages unrelated to this project if nothing else depends on them."
        apt-get autoremove -y || true
    else
        log "Skipping 'apt-get autoremove' (set AUTOREMOVE=1 to run it)."
    fi

    log "If removing these packages broke something you still need, run:"
    log "  sudo bash reinstall_pi_hotspot_dependencies.sh"
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
