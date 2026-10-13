#!/bin/bash
# Installs a script that re-resolves WireGuard peer endpoint hostnames and
# schedules it (systemd timer, or crontab fallback) for the given interface.
#
# Usage: sudo ./add-wireguard-cron.sh <interface>

set -euo pipefail

RERESOLVE_DNS_SCRIPT_PATH="/usr/local/bin/wg-reresolve-dns.sh"
RERUN_IN_MINUTE=1
SCHEDULE_SERVICE=

if [ "$EUID" -ne 0 ]; then
    printf "Error: Please run with sudo or as root.\n"
    exit 1
fi

if [ $# -ne 1 ]; then
    printf "Usage: %s <interface>\n" "$0"
    exit 1
fi

INTERFACE=$1
INTERFACE_CONFIG_PATH="/etc/wireguard/$INTERFACE.conf"

if [ ! -f "$INTERFACE_CONFIG_PATH" ]; then
    printf "Cannot find %s.\n" "$INTERFACE_CONFIG_PATH"
    exit 1
fi

if ! command -v wg >/dev/null 2>&1; then
    printf "Cannot find 'wg'. Please install wireguard-tools.\n"
    exit 1
fi

if ! wg show "$INTERFACE" >/dev/null 2>&1; then
    printf "Interface %s is not running.\n" "$INTERFACE"
    printf "Bring it up first (e.g. 'wg-quick up %s' or 'systemctl start wg-quick@%s'), then retry.\n" "$INTERFACE" "$INTERFACE"
    exit 1
fi

if [ -d /run/systemd/system ]; then
    echo "Using systemd."
    SCHEDULE_SERVICE=systemd
elif command -v crontab >/dev/null 2>&1; then
    echo "Using crontab."
    SCHEDULE_SERVICE=crontab
else
    echo "Cannot find systemd or crontab in this machine."
    echo "Please install either of them then re-run this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# Embedded re-resolve script.
# ---------------------------------------------------------------------------
cat >"$RERESOLVE_DNS_SCRIPT_PATH" <<'EOF'
#!/bin/bash
# Re-applies each peer's configured Endpoint so its hostname is resolved
# again, but only for peers whose last handshake is older than the threshold.
#
# Usage: wg-reresolve-dns.sh <interface | /path/to/interface.conf>
# Env:   STALE_AFTER  seconds since last handshake before re-resolving (default 135)

set -uo pipefail

STALE_AFTER="${STALE_AFTER:-135}"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <interface | /path/to/interface.conf>" >&2
    exit 2
fi

case "$1" in
    */* | *.conf) CONF="$1" ;;
    *)            CONF="/etc/wireguard/$1.conf" ;;
esac
IFACE="$(basename "$CONF" .conf)"

[ -r "$CONF" ] || { echo "Cannot read $CONF" >&2; exit 1; }

# Interface down: nothing to do.
if ! HANDSHAKES="$(wg show "$IFACE" latest-handshakes 2>/dev/null)"; then
    echo "Interface $IFACE is not up, skipping."
    exit 0
fi

# Last handshake time (unix seconds) per public key, from the running interface.
declare -A LAST_SEEN=()
while read -r key ts; do
    [ -n "$key" ] && LAST_SEEN["$key"]="$ts"
done <<<"$HANDSHAKES"

# Emit "<publickey> <endpoint>" for every [Peer] that has both, from the config.
peer_endpoints() {
    awk '
        function emit() { if (pk != "" && ep != "") print pk, ep; pk = ""; ep = "" }
        {
            sub(/#.*/, "")
            gsub(/^[ \t\r]+|[ \t\r]+$/, "")
            if ($0 == "") next
        }
        /^\[/ { emit(); peer = (tolower($0) == "[peer]"); next }
        peer {
            eq = index($0, "=")
            if (!eq) next
            name = tolower(substr($0, 1, eq - 1)); gsub(/[ \t]/, "", name)
            val  = substr($0, eq + 1);             gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (name == "publickey") pk = val
            else if (name == "endpoint") ep = val
        }
        END { emit() }
    ' "$1"
}

# True if the endpoint host is already an IP literal (nothing to resolve).
is_ip_literal() {
    local host="${1%:*}"
    [[ $host == \[*\] ]] && return 0                          # [IPv6]:port
    [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0  # IPv4:port
    return 1
}

NOW="$(date +%s)"
RC=0

while read -r key endpoint; do
    [ -n "$key" ] || continue
    is_ip_literal "$endpoint" && continue

    # Peer missing from the running interface (config changed since wg-quick up).
    [ -n "${LAST_SEEN[$key]+x}" ] || continue

    age=$(( NOW - ${LAST_SEEN[$key]} ))
    (( age > STALE_AFTER )) || continue

    if [ "${LAST_SEEN[$key]}" -eq 0 ]; then seen="never"; else seen="${age}s ago"; fi

    if wg set "$IFACE" peer "$key" endpoint "$endpoint"; then
        echo "$IFACE: re-resolved $endpoint for peer ${key:0:8}... (last handshake: $seen)"
    else
        echo "$IFACE: failed to re-resolve $endpoint for peer ${key:0:8}..." >&2
        RC=1
    fi
done < <(peer_endpoints "$CONF")

exit "$RC"
EOF
chmod 755 "$RERESOLVE_DNS_SCRIPT_PATH"
printf "Installed %s\n" "$RERESOLVE_DNS_SCRIPT_PATH"

if [[ $SCHEDULE_SERVICE == "systemd" ]]; then
    cat >"/etc/systemd/system/${INTERFACE}_dns.service" <<EOF
[Unit]
Description=Re-resolve WireGuard endpoint DNS for ${INTERFACE}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RERESOLVE_DNS_SCRIPT_PATH $INTERFACE_CONFIG_PATH
EOF

    cat >"/etc/systemd/system/${INTERFACE}_dns.timer" <<EOF
[Unit]
Description=${INTERFACE} re-resolve DNS timer

[Timer]
Unit=${INTERFACE}_dns.service
OnCalendar=*:0/$RERUN_IN_MINUTE
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${INTERFACE}_dns.timer"
    printf "Created timer for %s successfully!\n" "$INTERFACE"

elif [[ $SCHEDULE_SERVICE == "crontab" ]]; then
    line="*/$RERUN_IN_MINUTE * * * * $RERESOLVE_DNS_SCRIPT_PATH $INTERFACE_CONFIG_PATH"
    # Drop any existing entry for this interface, then add it (idempotent).
    { crontab -l 2>/dev/null | grep -vF "$RERESOLVE_DNS_SCRIPT_PATH $INTERFACE_CONFIG_PATH" || true; echo "$line"; } | crontab -
    printf "Created cron job for %s successfully!\n" "$INTERFACE"
fi