#!/bin/bash
# Removes the re-resolve DNS timer / cron job created by add-wireguard-cron.sh
# for the given interface. The reresolve script itself
# (/usr/local/bin/wg-reresolve-dns.sh) is left in place.
#
# Usage: sudo ./remove-wireguard-cron.sh <interface>

set -euo pipefail

RERESOLVE_DNS_SCRIPT_PATH="/usr/local/bin/wg-reresolve-dns.sh"

if [ "$EUID" -ne 0 ]; then
    printf "Error: Please run with sudo or as root.\n"
    exit 1
fi

if [ $# -ne 1 ]; then
    printf "Usage: %s <interface>\n" "$0"
    exit 1
fi

INTERFACE=$1
SERVICE_NAME="${INTERFACE}_dns.service"
TIMER_NAME="${INTERFACE}_dns.timer"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"
REMOVED=0

# --- systemd -----------------------------------------------------------------
if [ -d /run/systemd/system ]; then
    if [ -f "$TIMER_FILE" ] || [ -f "$SERVICE_FILE" ]; then
        systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$TIMER_FILE" "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl reset-failed "$TIMER_NAME" "$SERVICE_NAME" 2>/dev/null || true
        printf "Removed systemd timer %s.\n" "$TIMER_NAME"
        REMOVED=1
    fi
fi

# --- crontab -----------------------------------------------------------------
if command -v crontab >/dev/null 2>&1; then
    CRON_MATCH="$RERESOLVE_DNS_SCRIPT_PATH /etc/wireguard/$INTERFACE.conf"
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    if grep -qF "$CRON_MATCH" <<<"$CURRENT_CRON"; then
        grep -vF "$CRON_MATCH" <<<"$CURRENT_CRON" | crontab - || true
        printf "Removed cron job for %s.\n" "$INTERFACE"
        REMOVED=1
    fi
fi

if [ "$REMOVED" -eq 0 ]; then
    printf "No timer or cron job found for %s.\n" "$INTERFACE"
fi