#!/usr/bin/env bash
set -euo pipefail

########################################
# Re-scans nearby Wi-Fi networks and switches an existing pi-hotspot
# NetworkManager connection to the least congested channel for its band.
#
# For use on installs already set up by install_pi_hotspot.sh. Briefly
# takes the hotspot down to scan, then brings it back up on the new
# channel.
########################################

HOTSPOT_CONN="${HOTSPOT_CONN:-PiHotspot}"
WLAN_IF="${WLAN_IF:-wlan0}"
WIFI_BAND="${WIFI_BAND:-}"

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

require_connection() {
    if ! nmcli -t -f NAME connection show | grep -qx "${HOTSPOT_CONN}"; then
        err "NetworkManager connection '${HOTSPOT_CONN}' was not found. Run install_pi_hotspot.sh first, or set HOTSPOT_CONN to the right profile name."
    fi
}

resolve_band() {
    if [[ -z "${WIFI_BAND}" ]]; then
        WIFI_BAND="$(nmcli -g 802-11-wireless.band connection show "${HOTSPOT_CONN}" 2>/dev/null || true)"
        if [[ -z "${WIFI_BAND}" ]]; then
            WIFI_BAND="bg"
        fi
    fi
}

# -----------------------------
# Wi-Fi channel scanning (same scoring approach as install_pi_hotspot.sh)
# -----------------------------
select_best_wifi_channel() {
    log "Scanning nearby Wi-Fi networks on ${WLAN_IF} to pick the least congested channel for band '${WIFI_BAND}'..."

    local candidates=()
    if [[ "${WIFI_BAND}" == "a" ]]; then
        candidates=(36 40 44 48 149 153 157 161 165)
    else
        candidates=(1 6 11)
    fi

    log "Networks seen during scan:"
    nmcli -f SSID,CHAN,SIGNAL,BSSID device wifi list ifname "${WLAN_IF}" --rescan yes 2>/dev/null | sed 's/^/    /' || true

    local scan_output
    scan_output="$(nmcli -t -f CHAN device wifi list ifname "${WLAN_IF}" 2>/dev/null | grep -E '^[0-9]+$' || true)"

    if [[ -z "${scan_output}" ]]; then
        BEST_CHANNEL="${candidates[0]}"
        warn "Wi-Fi scan found no nearby networks; defaulting to channel ${BEST_CHANNEL}."
        return
    fi

    local detected_channels=()
    local ch
    while IFS= read -r ch; do
        [[ -n "${ch}" ]] && detected_channels+=("${ch}")
    done <<< "${scan_output}"

    log "Detected ${#detected_channels[@]} network(s), on channels: ${detected_channels[*]}"

    local best_channel="" best_score="" candidate score diff
    log "Congestion analysis (candidate channel : interfering networks):"
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

        printf '    channel %-3s : %s\n' "${candidate}" "${score}"

        if [[ -z "${best_score}" ]] || (( score < best_score )); then
            best_score="${score}"
            best_channel="${candidate}"
        fi
    done

    BEST_CHANNEL="${best_channel}"
    log "Selected Wi-Fi channel ${BEST_CHANNEL} for band '${WIFI_BAND}' (nearby-network score ${best_score}; candidates: ${candidates[*]})."
}

apply_channel() {
    local current_channel
    current_channel="$(nmcli -g 802-11-wireless.channel connection show "${HOTSPOT_CONN}" 2>/dev/null || true)"

    if [[ "${current_channel}" == "${BEST_CHANNEL}" ]]; then
        log "Hotspot '${HOTSPOT_CONN}' is already on the best available channel (${BEST_CHANNEL}). No change needed."
    else
        log "Switching '${HOTSPOT_CONN}' from channel ${current_channel:-unknown} to channel ${BEST_CHANNEL}..."
        nmcli connection modify "${HOTSPOT_CONN}" \
            802-11-wireless.band "${WIFI_BAND}" \
            802-11-wireless.channel "${BEST_CHANNEL}"
    fi

    log "Bringing hotspot back up on channel ${BEST_CHANNEL}..."
    nmcli connection up "${HOTSPOT_CONN}" || err "Failed to reactivate hotspot '${HOTSPOT_CONN}' on channel ${BEST_CHANNEL}."

    log "Summary: '${HOTSPOT_CONN}' band '${WIFI_BAND}' channel ${current_channel:-unknown} -> ${BEST_CHANNEL}."
}

main() {
    require_root
    require_connection
    resolve_band

    log "Taking '${HOTSPOT_CONN}' down temporarily to scan for nearby networks..."
    nmcli connection down "${HOTSPOT_CONN}" 2>/dev/null || true
    sleep 2

    select_best_wifi_channel
    apply_channel
}

main "$@"
