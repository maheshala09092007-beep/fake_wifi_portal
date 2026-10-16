#!/usr/bin/env bash
# ============================================================================
# setup.sh - one-shot starter for the captive-portal PRANK hotspot.
#
#   sudo ./setup.sh      -> broadcast an open WiFi network that pops a joke
#                           page on any device that joins it
#   sudo ./stop.sh       -> tear everything down and restore normal networking
#
# WHAT THIS DOES (and what it deliberately does NOT do)
# -----------------------------------------------------
# * Broadcasts an OPEN (no password) WiFi network with hostapd.
# * Runs dnsmasq as a DHCP + DNS server for the hotspot's subnet:
#     - DHCP option 114 (RFC 8910) advertises the captive-portal URI so
#       Android / iOS / Chrome auto-detect the portal and pop it up.
#     - EVERY DNS query resolves to this laptop, so any URL lands here.
# * Redirects all HTTP (80) and HTTPS (443) traffic from the hotspot
#   interface to the joke server with iptables NAT rules.
#     - NOTE: HTTPS traffic CANNOT actually be intercepted - there is no
#       fake certificate here, so TLS handshakes just fail. That is
#       expected and fine: modern phones almost always reach the portal
#       through their plain-HTTP connectivity checks (/generate_204 etc).
# * Serves the joke page from server.py (see config.json -> active_page).
#
#   *** THIS IS A JOKE-ONLY HOTSPOT. NO INTERNET IS SHARED. ***
#   There is no uplink, no forwarding, no relay. Devices that join get a
#   joke page and zero connectivity. Run it only on hardware you own, on a
#   network you own, as a prank among people who are in on the joke.
#
# No credentials are collected: there is no login form, and nothing about
# connecting devices is written to disk (the visit counter lives in RAM).
# ============================================================================
set -euo pipefail

# ========================== USER SETTINGS ================================
# Edit these (or export them before running, e.g. IFACE=wlan1 sudo -E ./setup.sh)

SSID="College_Free_WiFi"   # WiFi network name the laptop will broadcast
CHANNEL="6"                 # WiFi channel (1-11 most countries; 36+ for 5 GHz cards)
COUNTRY_CODE="US"           # regulatory domain - MUST match your country's laws
IFACE=""                    # WiFi interface; leave empty to auto-detect
SUBNET="10.0.0.1"           # this laptop's IP address on the hotspot
DHCP_START="10.0.0.10"      # first IP handed to joining devices
DHCP_END="10.0.0.100"       # last IP handed to joining devices
DHCP_LEASE="12h"            # DHCP lease time

# ========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
RUN_DIR="$SCRIPT_DIR/run"
STATE_FILE="$RUN_DIR/state.env"      # remembers IFACE/PORT for stop.sh
TAG="prankportal"                    # iptables comment tag used for cleanup
PORT=""

info()  { printf '[*] %s\n' "$*"; }
warn()  { printf '[!] %s\n' "$*" >&2; }
die()   { printf '[ERROR] %s\n' "$*" >&2; printf '[!] Partial setup. Run: sudo ./stop.sh\n' >&2; exit 1; }

# ------------------------- 0. Sanity checks -----------------------------
[ "$(id -u)" -eq 0 ] || die "This script must run as root: sudo ./setup.sh"

[ -f "$SCRIPT_DIR/server.py" ] || die "server.py not found next to setup.sh"
[ -f "$SCRIPT_DIR/config.json" ] || warn "config.json missing - server will use defaults (page 6g-joke.html, port 8080)"

# Read the server port from config.json (single source of truth).
PORT="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["port"]))' \
        "$SCRIPT_DIR/config.json" 2>/dev/null || echo 8080)"

echo "=========================================================="
echo " Captive Portal PRANK setup  (SSID: $SSID, port: $PORT)"
echo " *** NO INTERNET will be shared. This is a joke hotspot. ***"
echo "=========================================================="

# ------------------------- 1. Dependencies ------------------------------
missing=()
for cmd in hostapd dnsmasq iptables iw ip python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
# map command names to package names
pkgs=()
for c in "${missing[@]+"${missing[@]}"}"; do
    case "$c" in
        ip)        pkgs+=("iproute2") ;;
        python3)   pkgs+=("python3") ;;
        *)         pkgs+=("$c") ;;
    esac
done
if [ "${#pkgs[@]}" -gt 0 ]; then
    info "Installing missing packages: ${pkgs[*]}"
    command -v apt-get >/dev/null 2>&1 || die "Please install manually: ${pkgs[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
fi
# The QR code at the end needs the 'qrcode' python package (optional).
if ! python3 -c 'import qrcode' >/dev/null 2>&1; then
    info "Installing python3 'qrcode' package (for the fallback QR code)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-qrcode \
        || pip3 install --break-system-packages qrcode \
        || warn "Could not install qrcode - setup continues without the QR code."
fi

# ------------------------- 2. Find a WiFi card with AP support ----------
ap_supported() {
    # $1 = interface name. Checks its phy's supported modes for '* AP'.
    local phy
    phy="$(iw dev "$1" info 2>/dev/null | awk '/wiphy/ {print "phy"$2}')"
    [ -n "$phy" ] || return 1
    iw phy "$phy" info 2>/dev/null | grep -qE '^[[:space:]]*\*[[:space:]]+AP[[:space:]]*$'
}

if [ -z "$IFACE" ]; then
    info "Scanning WiFi interfaces for AP-mode support (iw)..."
    for dev in $(iw dev 2>/dev/null | awk '/Interface/ {print $2}'); do
        if ap_supported "$dev"; then
            info "  $dev: supports AP mode  <- using this one"
            IFACE="$dev"
        else
            info "  $dev: no AP mode support"
        fi
    done
fi

if [ -z "$IFACE" ]; then
    warn "No AP-capable WiFi interface found."
    warn "Your card/driver must support AP mode (works on most Intel/Atheros cards)."
    warn "You can force one with:  IFACE=wlan0 sudo ./setup.sh"
    exit 1
elif ! ap_supported "$IFACE"; then
    warn "Interface $IFACE does not report AP-mode support; trying anyway."
fi

# Unblock the radio if soft-blocked (airplane mode etc).
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi >/dev/null 2>&1 || true
info "Using WiFi interface: $IFACE"

# ------------------------- 3. Hand the interface to us ------------------
# Stop NetworkManager from fighting hostapd for the card. The laptop's own
# internet (ethernet / a second WiFi card) is unaffected; if this card was
# your only uplink, the laptop goes offline while the prank runs.
if command -v nmcli >/dev/null 2>&1; then
    info "Telling NetworkManager to release $IFACE..."
    nmcli device set "$IFACE" managed no || warn "nmcli failed; falling back to stopping NetworkManager."
else
    systemctl stop NetworkManager 2>/dev/null || true
fi

# Make sure nothing else holds the interface.
pkill -x hostapd 2>/dev/null || true
pkill -x dnsmasq 2>/dev/null || true
sleep 1

# ------------------------- 4. Configure the hotspot IP ------------------
mkdir -p "$RUN_DIR"
info "Assigning $SUBNET/24 to $IFACE..."
ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up
ip addr add "$SUBNET/24" dev "$IFACE"

# ------------------------- 5. hostapd: broadcast the open network -------
cat > "$RUN_DIR/hostapd.conf" <<EOF
# Generated by setup.sh - open (no password) prank hotspot.
# NOTE: hostapd takes everything after '=' literally - no inline comments.
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
country_code=$COUNTRY_CODE
ieee80211d=1
# Open authentication, WPA disabled ON PURPOSE: devices must join freely.
auth_algs=1
wpa=0
# Broadcast the SSID so it is visible to everyone.
ignore_broadcast_ssid=0
EOF

info "Starting hostapd (SSID: $SSID, channel: $CHANNEL)..."
hostapd -B "$RUN_DIR/hostapd.conf" || die "hostapd failed to start - check antenna/driver support"
sleep 2
iw dev "$IFACE" info 2>/dev/null | grep -q 'type AP' \
    || die "$IFACE did not enter AP mode - card/driver limitation"

# ------------------------- 6. dnsmasq: DHCP + DNS + portal hint ---------
cat > "$RUN_DIR/dnsmasq.conf" <<EOF
# Generated by setup.sh - DHCP/DNS for the prank hotspot.
# NOTE: comments only on their own lines - dnsmasq parses inline tokens.
# Only serve the hotspot interface:
interface=$IFACE
# Follow the interface even if it flaps:
bind-dynamic
dhcp-range=$DHCP_START,$DHCP_END,$DHCP_LEASE
# Hand out leases fast; kick stale clients:
dhcp-authoritative
dhcp-option=option:router,$SUBNET
dhcp-option=option:dns-server,$SUBNET
# DHCP option 114 = Captive-Portal URI (RFC 8910). This is what makes
# Android/iOS/Chrome ask the OS to auto-open the portal page:
dhcp-option=114,http://$SUBNET:$PORT/generate_204
# Answer EVERY DNS A-record query with this laptop. Any URL a client
# types (google.com, anything) resolves straight to the joke server:
address=/#/$SUBNET
pid-file=$RUN_DIR/dnsmasq.pid
log-facility=$RUN_DIR/dnsmasq.log
EOF

info "Starting dnsmasq (DHCP $DHCP_START-$DHCP_END, DNS -> $SUBNET)..."
dnsmasq --conf-file="$RUN_DIR/dnsmasq.conf" || die "dnsmasq failed to start (is something else on port 53?)"

# ------------------------- 7. iptables: land all web traffic here -------
# NAT redirect: every HTTP/HTTPS connection from the hotspot interface is
# rerouted to the joke server's port, so ANY URL opens the portal page.
#
# About the 443 rule: there is no TLS interception here (no fake certs),
# so HTTPS requests get an HTTP answer they cannot decrypt and simply
# fail to load. That is EXPECTED and fine - the phone's portal detection
# uses plain HTTP probes, which do work. Do not "fix" this.
info "Adding iptables redirect rules (ports 80/443 -> $PORT, tagged '$TAG')..."
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80  -m comment --comment "$TAG" -j REDIRECT --to-ports "$PORT"
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -m comment --comment "$TAG" -j REDIRECT --to-ports "$PORT"

# Make sure the hotspot's own services answer through any default-reject
# firewall rules (harmless if the policy is already ACCEPT).
iptables -A INPUT -i "$IFACE" -p udp --dport 53   -m comment --comment "$TAG" -j ACCEPT  # DNS
iptables -A INPUT -i "$IFACE" -p tcp --dport 53   -m comment --comment "$TAG" -j ACCEPT  # DNS (TCP)
iptables -A INPUT -i "$IFACE" -p udp --dport 67   -m comment --comment "$TAG" -j ACCEPT  # DHCP
iptables -A INPUT -i "$IFACE" -p tcp --dport "$PORT" -m comment --comment "$TAG" -j ACCEPT  # joke server
iptables -A INPUT -i "$IFACE" -p icmp -m comment --comment "$TAG" -j ACCEPT  # ping, looks legit

# ------------------------- 8. Start the joke server ---------------------
info "Starting portal server (server.py on port $PORT)..."
# nohup + background: survives setup.sh exiting. PID saved for stop.sh.
nohup python3 "$SCRIPT_DIR/server.py" > "$RUN_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$RUN_DIR/server.pid"
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || { tail -n 20 "$RUN_DIR/server.log" >&2 || true; die "server.py died on startup"; }

# Remember what we did so stop.sh can undo it precisely.
cat > "$STATE_FILE" <<EOF
IFACE=$IFACE
PORT=$PORT
SUBNET=$SUBNET
TAG=$TAG
EOF

# ------------------------- 9. Summary + QR fallback ---------------------
IP="$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -n "$IP" ] || IP="$SUBNET"
URL="http://$IP:$PORT"

echo
echo "=========================================================="
echo " PRANK HOTSPOT IS LIVE"
echo "=========================================================="
echo "  SSID        : $SSID   (open network, no password)"
echo "  Interface   : $IFACE"
echo "  Laptop IP   : $IP"
echo "  Portal URL  : $URL"
echo "  Joke page   : $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("active_page","?"))' "$SCRIPT_DIR/config.json" 2>/dev/null || echo "6g-joke.html")"
echo "  Logs        : $RUN_DIR/server.log"
echo
echo "  *** NO INTERNET is shared. Joined devices get the joke and"
echo "      zero connectivity. HTTPS sites will fail to load - normal. ***"
echo
echo "  Most phones pop the portal automatically. If one doesn't,"
echo "  have the person scan this QR code (or open the URL manually):"
echo "=========================================================="
echo
python3 - "$URL" <<'PYEOF' || echo "  (QR code unavailable - install python3-qrcode for next time)"
import sys
try:
    import qrcode
    qr = qrcode.QRCode(border=1, box_size=1)
    qr.add_data(sys.argv[1])
    qr.make(fit=True)
    try:
        qr.print_ascii(invert=True)   # easier to scan on dark terminals
    except TypeError:
        qr.print_ascii()
    print(f"\n  -> {sys.argv[1]}")
except Exception as exc:  # noqa: BLE001 - never fail setup over a QR code
    print(f"  (QR code unavailable: {exc})")
    sys.exit(1)
PYEOF
echo
echo "  When you're done: sudo ./stop.sh"
echo "=========================================================="
