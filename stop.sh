#!/usr/bin/env bash
# ============================================================================
# stop.sh - cleanly tear down the prank hotspot and restore normal networking.
#
#   sudo ./stop.sh
#
# It is safe to run even if setup.sh only got halfway: every step tolerates
# things already being stopped/absent. What it undoes:
#   1. Kills the joke server (server.py) started by setup.sh
#   2. Stops hostapd and dnsmasq
#   3. Removes every iptables rule tagged 'prankportal' by setup.sh
#   4. Flushes the hotspot IP off the WiFi interface
#   5. Hands the interface back to NetworkManager and restarts it
#
# It does NOT touch any other firewall rules, and it does NOT touch
# networking on interfaces this project never used (e.g. ethernet).
# ============================================================================
set -uo pipefail   # deliberately NOT -e: teardown keeps going past errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
RUN_DIR="$SCRIPT_DIR/run"
STATE_FILE="$RUN_DIR/state.env"

info() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "[ERROR] Run as root: sudo ./stop.sh" >&2; exit 1; }

# Load what setup.sh recorded (IFACE, PORT, ...). Tolerate it being absent.
IFACE="" PORT=""
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    info "Loaded state: interface=${IFACE:-?} port=${PORT:-?}"
else
    warn "No state file ($STATE_FILE) - cleaning up whatever we can find."
fi

# ------------------------- 1. Kill the joke server ----------------------
if [ -f "$RUN_DIR/server.pid" ]; then
    PID="$(cat "$RUN_DIR/server.pid" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        info "Stopping portal server (pid $PID)..."
        kill "$PID" 2>/dev/null || true
        # give it a moment, then force
        for _ in 1 2 3 4 5; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.4
        done
        kill -9 "$PID" 2>/dev/null || true
    else
        info "Portal server not running."
    fi
    rm -f "$RUN_DIR/server.pid"
else
    info "No server pid file; skipping."
fi

# ------------------------- 2. Stop hostapd + dnsmasq --------------------
if [ -f "$RUN_DIR/dnsmasq.pid" ]; then
    DNSPID="$(cat "$RUN_DIR/dnsmasq.pid" 2>/dev/null || true)"
    [ -n "$DNSPID" ] && kill "$DNSPID" 2>/dev/null || true
fi
if pgrep -x dnsmasq >/dev/null 2>&1; then
    info "Stopping dnsmasq..."
    pkill -x dnsmasq 2>/dev/null || true
    sleep 0.5
    pkill -9 -x dnsmasq 2>/dev/null || true
fi
if pgrep -x hostapd >/dev/null 2>&1; then
    info "Stopping hostapd..."
    pkill -x hostapd 2>/dev/null || true
    sleep 0.5
    pkill -9 -x hostapd 2>/dev/null || true
fi
rm -f "$RUN_DIR/dnsmasq.pid" "$RUN_DIR/hostapd.conf" "$RUN_DIR/dnsmasq.conf"

# ------------------------- 3. Remove our iptables rules -----------------
# setup.sh tags every rule it adds with the comment 'prankportal', so we
# can strip exactly our rules and nothing else by filtering the saved
# ruleset and restoring it.
if command -v iptables-save >/dev/null 2>&1; then
    if iptables-save 2>/dev/null | grep -q 'prankportal'; then
        info "Removing iptables rules tagged 'prankportal'..."
        iptables-save | sed '/prankportal/d' | iptables-restore
    else
        info "No prank iptables rules found."
    fi
else
    warn "iptables-save not found; removing the known rules individually."
    for dport in 80 443; do
        while iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport "$dport" \
              -m comment --comment prankportal -j REDIRECT --to-ports "$PORT" 2>/dev/null; do :; done
    done
fi

# ------------------------- 4/5. Restore the interface + NetworkManager --
if [ -n "$IFACE" ]; then
    info "Flushing hotspot IP from $IFACE..."
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" up 2>/dev/null || true

    if command -v nmcli >/dev/null 2>&1; then
        info "Handing $IFACE back to NetworkManager..."
        nmcli device set "$IFACE" managed yes 2>/dev/null || true
    fi
fi

if systemctl is-active --quiet NetworkManager 2>/dev/null \
   || systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
    info "Restarting NetworkManager..."
    systemctl restart NetworkManager 2>/dev/null \
        || warn "Could not restart NetworkManager automatically - reboot or start it manually."
elif command -v nmcli >/dev/null 2>&1; then
    # NetworkManager present but not as a systemd unit name we recognized
    nmcli networking off 2>/dev/null && nmcli networking on 2>/dev/null || true
fi

rm -f "$STATE_FILE"

echo
echo "[*] Done. Hotspot stopped, firewall rules removed, networking restored."
echo "[*] (server.log kept in $RUN_DIR/ for debugging)"
