#!/usr/bin/env bash
set -euo pipefail

########################################
# Raspberry Pi Hotspot Dependency Reinstaller
# - Restores the apt packages either uninstaller can remove via
#   REMOVE_PACKAGES=1 (and REMOVE_NETWORK_MANAGER=1)
# - Safe to run whether or not the packages are currently missing
# - Re-enables and restarts NetworkManager
# - Re-disables the standalone dnsmasq service so it doesn't conflict
#   with NetworkManager-managed DHCP/NAT, matching the installers
########################################

# Union of packages used by install_pi_hotspot.sh (shared mode) and
# install_pi_hotspot_bridge.sh (bridge mode). Installing dnsmasq when
# only running bridge mode is harmless; it stays stopped and disabled.
PACKAGES=(network-manager dnsmasq wireless-regdb iw rfkill python3)

REINSTALL="${REINSTALL:-0}"

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

validate_inputs() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "This script expects Raspberry Pi OS / Debian with apt-get."
    fi
}

install_packages() {
    log "Updating package index..."
    apt-get update

    local install_flags=(-y)
    if [[ "${REINSTALL}" == "1" ]]; then
        log "REINSTALL=1 set; forcing reinstall of already-present packages too."
        install_flags+=(--reinstall)
    fi

    log "Installing: ${PACKAGES[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install "${install_flags[@]}" "${PACKAGES[@]}"
}

reenable_networkmanager() {
    if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        log "Enabling and restarting NetworkManager..."
        systemctl enable NetworkManager
        systemctl restart NetworkManager
        sleep 3
    else
        warn "NetworkManager.service unit not found after install; check the package install output above."
    fi
}

disable_standalone_dnsmasq() {
    log "Stopping standalone dnsmasq service so NetworkManager can manage DHCP/NAT shared mode cleanly..."
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
}

show_status() {
    echo
    log "Dependency reinstall complete."
    echo
    echo "Package status:"
    dpkg-query -W -f='  ${Package}\t${Status}\n' "${PACKAGES[@]}" 2>/dev/null || true
    echo
    echo "NetworkManager service:"
    systemctl --no-pager --full status NetworkManager 2>/dev/null || true
    echo
    echo "Next steps:"
    echo "  Re-run install_pi_hotspot.sh (or install_pi_hotspot_bridge.sh) to recreate"
    echo "  the hotspot connection and helper scripts/services if the uninstaller also"
    echo "  removed those."
    echo
}

main() {
    require_root
    validate_inputs
    install_packages
    reenable_networkmanager
    disable_standalone_dnsmasq
    show_status
}

main "$@"
