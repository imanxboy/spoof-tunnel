#!/bin/bash
# setup-wizard.sh — interactive configuration wizard for spoof-tunnel v6
# Writes config.yaml to the current directory (or --output PATH)
# Usage: bash setup-wizard.sh [--output /path/to/config.yaml]
set -euo pipefail

# ── argument parsing ────────────────────────────────────────────────────────

OUTPUT="config.yaml"
NONINTERACTIVE=0
for i in "$@"; do
    case "$i" in
        --output=*) OUTPUT="${i#--output=}" ;;
        --output)   shift; OUTPUT="${1:-config.yaml}" ;;
        --non-interactive) NONINTERACTIVE=1 ;;
    esac
done

# ── interactive-mode guard ──────────────────────────────────────────────────
# When launched via "curl | bash", bash's stdin is the pipe (already at EOF).
# Redirect from /dev/tty so read() gets keystrokes from the real terminal.
# If /dev/tty is unavailable (headless container, CI), abort with instructions.
if [ ! -t 0 ]; then
    if exec </dev/tty 2>/dev/null; then
        : # successfully reopened from controlling terminal
    else
        echo "" >&2
        echo "  ERROR: setup-wizard requires an interactive terminal." >&2
        echo "" >&2
        echo "  stdin is not a tty and /dev/tty is not available." >&2
        echo "  To configure manually:" >&2
        echo "    cp config.yaml.example config.yaml" >&2
        echo "    nano config.yaml          # edit peer_address, role, spoof IPs" >&2
        echo "    sudo bash install.sh" >&2
        echo "" >&2
        exit 1
    fi
fi

# ── helpers ─────────────────────────────────────────────────────────────────

ask() {
    # ask VARNAME "prompt" default_value
    local varname="$1" prompt="$2" default="${3:-}"
    local answer
    if [ -n "$default" ]; then
        read -rp "  ${prompt} [${default}]: " answer || true
        answer="${answer:-$default}"
    else
        while true; do
            read -rp "  ${prompt}: " answer || true
            [ -n "$answer" ] && break
            echo "  (required — cannot be empty)"
        done
    fi
    printf -v "$varname" '%s' "$answer"
}

valid_ip() {
    python3 -c "import socket, sys; socket.inet_aton(sys.argv[1])" "$1" 2>/dev/null
}

# Returns 0 if the IP is assigned to a local network interface on this machine
is_local_ip() {
    python3 -c "
import subprocess, sys
ip = sys.argv[1]
try:
    out = subprocess.check_output(['ip', '-4', 'addr', 'show'],
                                  stderr=subprocess.DEVNULL, text=True)
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('inet '):
            addr = line.split()[1].split('/')[0]
            if addr == ip:
                sys.exit(0)
except Exception:
    pass
sys.exit(1)
" "$1" 2>/dev/null
}

hr() { echo "  ────────────────────────────────────────────────────"; }

# ── sibling tunnels ──────────────────────────────────────────────────────────
#
# spoofctl exports ST_TUNNELS_DIR and ST_INSTANCE when it runs the wizard to
# add a tunnel to a host that already has some. Reading what those tunnels
# already own lets every default we offer be free, so the operator can hold
# Enter through the wizard and still get a config that installs.

TUNNELS_DIR="${ST_TUNNELS_DIR:-/etc/spoof-tunnel/tunnels}"
INSTANCE="${ST_INSTANCE:-}"

TAKEN_TUNS=""
TAKEN_PORTS=""
TAKEN_TUN_IPS=""

# Values may be quoted (EXTRA_ARGS always is), so strip a surrounding pair.
env_get() {
    local v
    [ -f "$1" ] || return 0
    v="$(sed -n "s/^${2}=//p" "$1" | tail -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

scan_siblings() {
    local f n
    [ -d "$TUNNELS_DIR" ] || return 0
    for f in "${TUNNELS_DIR}"/*.env; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"; n="${n%.env}"
        [ "$n" = "$INSTANCE" ] && continue
        TAKEN_TUNS="${TAKEN_TUNS} $(env_get "$f" TUN_NAME)"
        TAKEN_PORTS="${TAKEN_PORTS} $(env_get "$f" LISTEN_PORT)"
        TAKEN_PORTS="${TAKEN_PORTS} $(env_get "$f" FORWARD_PORTS | tr ',' ' ')"
        TAKEN_TUN_IPS="${TAKEN_TUN_IPS} $(env_get "$f" LOCAL_TUN) $(env_get "$f" PEER_TUN)"
    done
}
scan_siblings

is_taken() {  # is_taken <value> <list>
    case " ${2} " in *" ${1} "*) return 0 ;; esac
    return 1
}

sibling_count() {
    local c=0 f
    [ -d "$TUNNELS_DIR" ] || { echo 0; return; }
    for f in "${TUNNELS_DIR}"/*.env; do [ -f "$f" ] && c=$(( c + 1 )); done
    echo "$c"
}

# First tunN not already used by another tunnel, and not already a live device.
free_tun_name() {
    local i=0
    while [ "$i" -lt 64 ]; do
        if ! is_taken "tun${i}" "$TAKEN_TUNS" && \
           ! ip link show "tun${i}" >/dev/null 2>&1; then
            echo "tun${i}"; return
        fi
        i=$(( i + 1 ))
    done
    echo "tun0"
}

# First 10.100.N.0/30 pair whose addresses nobody else holds.
free_tun_subnet() {
    local n=100
    while [ "$n" -lt 250 ]; do
        if ! is_taken "10.100.${n}.1" "$TAKEN_TUN_IPS" && \
           ! is_taken "10.100.${n}.2" "$TAKEN_TUN_IPS"; then
            echo "$n"; return
        fi
        n=$(( n + 1 ))
    done
    echo 100
}

free_listen_port() {
    local p=2080
    while [ "$p" -lt 2200 ]; do
        is_taken "$p" "$TAKEN_PORTS" || { echo "$p"; return; }
        p=$(( p + 1 ))
    done
    echo 2080
}

# ── check existing config ────────────────────────────────────────────────────

if [ -f "$OUTPUT" ]; then
    echo ""
    echo "  WARNING: $OUTPUT already exists."
    read -rp "  Overwrite it? [y/N] " yn || true
    case "$yn" in
        [Yy]*) ;;
        *) echo "  Aborted. Existing config preserved."; exit 0 ;;
    esac
fi

# ── banner ───────────────────────────────────────────────────────────────────

clear 2>/dev/null || true
echo ""
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │         spoof-tunnel v6 — Setup Wizard           │"
echo "  └──────────────────────────────────────────────────┘"
echo ""
if [ -n "${INSTANCE}" ]; then
    echo "  This wizard creates the config for tunnel '${INSTANCE}'."
    _SIBS="$(sibling_count)"
    if [ "${_SIBS}" -gt 0 ]; then
        echo ""
        echo "  This host already runs ${_SIBS} other tunnel(s). The defaults"
        echo "  below skip every TUN device, port and TUN IP they already use."
    fi
else
    echo "  This wizard creates config.yaml for your tunnel node."
fi
echo "  Press Enter to accept the default shown in [brackets]."
echo ""

# ── detect defaults ──────────────────────────────────────────────────────────

DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/^default/{print $5}' | head -1 || true)
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"

# ── step 1: role ─────────────────────────────────────────────────────────────

hr
echo ""
echo "  Step 1 of 9 — Node Role"
echo ""
echo "    client  Your front-end server (users connect here, e.g. Iran)."
echo "            Receives users, tunnels traffic to the foreign server."
echo ""
echo "    server  Your back-end server (foreign VPN/proxy, e.g. Germany)."
echo "            Receives tunnel traffic, sends it to Xray/VLESS/etc."
echo ""

ROLE=""
while [ "$ROLE" != "client" ] && [ "$ROLE" != "server" ]; do
    read -rp "  Role [client/server]: " ROLE || true
    ROLE="${ROLE,,}"
    if [ "$ROLE" != "client" ] && [ "$ROLE" != "server" ]; then
        echo "  Please type 'client' or 'server'."
    fi
done

# ── step 2: interface ─────────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 2 of 9 — Public Network Interface"
echo ""
echo "  Your internet-facing network adapter. Available interfaces:"
ip -o link show 2>/dev/null \
    | awk -F': ' '{print "    " $2}' \
    | grep -v lo \
    | head -20 || true
echo ""
ask IFACE "Interface" "${DEFAULT_IFACE}"

# ── step 3: peer IP ──────────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 3 of 9 — Peer IP Address"
echo ""
if [ "$ROLE" = "client" ]; then
    echo "  The public IP of your foreign (server) machine."
else
    echo "  The public IP of your front-end (client) machine."
fi
echo ""

PEER_IP=""
while true; do
    read -rp "  Peer IP: " PEER_IP || true
    if ! valid_ip "${PEER_IP:-}"; then
        echo "  Invalid IP address. Example: 1.2.3.4"
        continue
    fi
    if is_local_ip "${PEER_IP}"; then
        echo ""
        echo "  ERROR: ${PEER_IP} is assigned to THIS machine."
        echo "         peer_address must be the OTHER server's public IP,"
        echo "         not a local interface address."
        echo ""
        PEER_IP=""
        continue
    fi
    break
done

# ── step 4: spoof IPs ────────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 4 of 9 — IP Spoofing Addresses"
echo ""
if [ "$ROLE" = "client" ]; then
    echo "  Tunnel packets will be sent with these as the source IP,"
    echo "  making them appear to come from a CDN or relay rather than"
    echo "  your actual server IP."
    echo ""
    echo "  Enter one or more IPv4 addresses, comma-separated."
    echo "  Example: ip-spoof-example,ip-spoof-example-2"
    echo ""
    SPOOF_RAW=""
    while [ -z "$SPOOF_RAW" ]; do
        read -rp "  Spoof IP(s): " SPOOF_RAW || true
        if [ -z "$SPOOF_RAW" ]; then
            echo "  At least one spoof IP is required for client mode."
        fi
    done

    SPOOF_VALID=""
    IFS=',' read -ra _SARR <<< "$SPOOF_RAW"
    for _ip in "${_SARR[@]}"; do
        _ip="${_ip// /}"
        [ -z "$_ip" ] && continue
        if valid_ip "$_ip"; then
            SPOOF_VALID="${SPOOF_VALID:+$SPOOF_VALID,}${_ip}"
        else
            echo "  WARNING: '${_ip}' is not a valid IP — skipping."
        fi
    done
    if [ -z "$SPOOF_VALID" ]; then
        echo "  No valid IPs entered. Using peer IP as spoof target."
        SPOOF_VALID="$PEER_IP"
    fi
else
    echo "  On the SERVER node, spoof.addresses must list the source IPs"
    echo "  that the CLIENT node will use when sending tunnel packets."
    echo "  These are the CDN or relay IPs configured on the client."
    echo ""
    echo "  The server accepts incoming tunnel frames ONLY from these IPs."
    echo "  If you haven't configured the client yet, press Enter to use"
    echo "  the client's real IP (${PEER_IP}) as a placeholder."
    echo "  Update later with:  spoofctl spoof-ips"
    echo ""
    read -rp "  Client spoof IP(s) [${PEER_IP}]: " SPOOF_RAW || true
    SPOOF_RAW="${SPOOF_RAW:-${PEER_IP}}"
    SPOOF_VALID=""
    IFS=',' read -ra _SARR <<< "$SPOOF_RAW"
    for _ip in "${_SARR[@]}"; do
        _ip="${_ip// /}"
        [ -z "$_ip" ] && continue
        if valid_ip "$_ip"; then
            SPOOF_VALID="${SPOOF_VALID:+$SPOOF_VALID,}${_ip}"
        else
            echo "  WARNING: '$_ip' is not a valid IP — skipping."
        fi
    done
    [ -z "$SPOOF_VALID" ] && SPOOF_VALID="$PEER_IP"
fi

# ── step 5: tunnel port ──────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 5 of 9 — Tunnel Port"
echo ""
echo "  UDP port for the outer tunnel. Must be open between both machines."
echo "  Avoid 443/80 (those are for the overlay service, e.g. Xray)."
echo ""

DEFAULT_PORT="$(free_listen_port)"
PORT=""
while true; do
    read -rp "  Port [${DEFAULT_PORT}]: " PORT || true
    PORT="${PORT:-$DEFAULT_PORT}"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "  Invalid port. Must be 1–65535."
        continue
    fi
    if is_taken "$PORT" "$TAKEN_PORTS"; then
        echo "  Port ${PORT} is already used by another tunnel on this host."
        continue
    fi
    break
done

# ── step 6: rate limit ───────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 6 of 9 — Bandwidth Rate Limit"
echo ""
echo "  Maximum aggregate tunnel throughput in Mbps."
echo "  Match your server's uplink capacity (check with your VPS provider)."
echo ""
echo "    100   — Small VPS / residential"
echo "    1000  — 1 Gbps datacenter (common)"
echo "    10000 — 10 Gbps datacenter"
echo ""

RATE=""
while true; do
    read -rp "  Rate in Mbps [1000]: " RATE || true
    RATE="${RATE:-1000}"
    if [[ "$RATE" =~ ^[0-9]+$ ]] && [ "$RATE" -ge 1 ]; then
        break
    fi
    echo "  Must be a positive integer."
done

# ── step 7: TUN IP addresses ─────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 7 of 9 — Virtual Tunnel IP Addresses"
echo ""
echo "  Each end of the tunnel gets a private IP on the TUN interface."
echo "  Use any RFC 1918 /30 pair that doesn't conflict with your routing."
echo ""

SUBNET="$(free_tun_subnet)"
if [ "$ROLE" = "server" ]; then
    DEFAULT_LOCAL_TUN="10.100.${SUBNET}.1"
    DEFAULT_PEER_TUN="10.100.${SUBNET}.2"
else
    DEFAULT_LOCAL_TUN="10.100.${SUBNET}.2"
    DEFAULT_PEER_TUN="10.100.${SUBNET}.1"
fi
echo "  NOTE: both ends of THIS tunnel must use the same pair, mirrored."
echo ""

LOCAL_TUN=""
PEER_TUN=""
while [ -z "${LOCAL_TUN}" ]; do
    read -rp "  Local TUN IP [${DEFAULT_LOCAL_TUN}]: " LOCAL_TUN || true
    LOCAL_TUN="${LOCAL_TUN:-$DEFAULT_LOCAL_TUN}"
    if ! valid_ip "$LOCAL_TUN"; then echo "  Invalid IP."; LOCAL_TUN=""; continue; fi
    if is_taken "$LOCAL_TUN" "$TAKEN_TUN_IPS"; then
        echo "  ${LOCAL_TUN} is already used by another tunnel on this host."
        LOCAL_TUN=""
    fi
done
while [ -z "${PEER_TUN}" ]; do
    read -rp "  Peer  TUN IP [${DEFAULT_PEER_TUN}]: " PEER_TUN || true
    PEER_TUN="${PEER_TUN:-$DEFAULT_PEER_TUN}"
    if ! valid_ip "$PEER_TUN"; then echo "  Invalid IP."; PEER_TUN=""; continue; fi
    if is_taken "$PEER_TUN" "$TAKEN_TUN_IPS"; then
        echo "  ${PEER_TUN} is already used by another tunnel on this host."
        PEER_TUN=""
    fi
done

# ── step 8: TUN interface name ───────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Step 8 of 9 — TUN Interface Name"
echo ""
echo "  Name for the kernel TUN device. Each tunnel needs its own."
echo ""
DEFAULT_TUN_NAME="$(free_tun_name)"
TUN_NAME=""
while [ -z "${TUN_NAME}" ]; do
    read -rp "  TUN name [${DEFAULT_TUN_NAME}]: " TUN_NAME || true
    TUN_NAME="${TUN_NAME:-$DEFAULT_TUN_NAME}"
    if is_taken "$TUN_NAME" "$TAKEN_TUNS"; then
        echo "  ${TUN_NAME} is already used by another tunnel on this host."
        TUN_NAME=""
    fi
done

# ── step 9: port forwarding (client only) ────────────────────────────────────

FWD_PORTS_YAML=""    # lines for config.yaml  (  - 443\n  - 80\n...)
FWD_PORTS_LIST=""    # comma-separated         (443,80,2053)

if [ "$ROLE" = "client" ]; then
    echo ""
    hr
    echo ""
    echo "  Step 9 of 9 — Port Forwarding"
    echo ""
    echo "  As the CLIENT node, you can forward incoming connections on one or"
    echo "  more ports through the tunnel to your proxy service on the SERVER."
    echo ""
    echo "  Both TCP and UDP are forwarded for each port you specify."
    echo ""
    echo "  Example — Xray/VLESS on port 443:"
    echo "    Enter: 443"
    echo ""
    echo "  Example — Multiple ports:"
    echo "    Enter: 443,80,2053"
    echo ""
    echo "  Leave empty to skip (configure later with: spoofctl forward-rules)"
    echo ""
    read -rp "  Enable port forwarding? [Y/n]: " _FWD_EN || true
    case "${_FWD_EN,,}" in
        n|no) ;;
        *)
            read -rp "  Ports to forward [443]: " _FWD_RAW || true
            _FWD_RAW="${_FWD_RAW:-443}"

            IFS=',' read -ra _FPARR <<< "$_FWD_RAW"
            for _p in "${_FPARR[@]}"; do
                _p="${_p// /}"
                [ -z "$_p" ] && continue
                if [[ "$_p" =~ ^[0-9]+$ ]] \
                   && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                    FWD_PORTS_YAML="${FWD_PORTS_YAML}  - ${_p}"$'\n'
                    FWD_PORTS_LIST="${FWD_PORTS_LIST:+$FWD_PORTS_LIST,}${_p}"
                else
                    echo "  WARNING: '${_p}' is not a valid port (1–65535) — skipping."
                fi
            done
            ;;
    esac
fi

# ── compute derived values ────────────────────────────────────────────────────

if ! FLOW_LIMIT=$(python3 -c "print(max(1000,min(10000,int(${RATE})*9)))" 2>/dev/null); then
    _fl=$(( RATE * 9 ))
    [ "${_fl}" -lt 1000  ] && _fl=1000
    [ "${_fl}" -gt 10000 ] && _fl=10000
    FLOW_LIMIT="${_fl}"
fi

# ── write config.yaml ────────────────────────────────────────────────────────

echo ""
hr
echo ""
echo "  Writing configuration to: ${OUTPUT}"
echo ""

SPOOF_YAML=""
IFS=',' read -ra _SARR2 <<< "$SPOOF_VALID"
for _ip in "${_SARR2[@]}"; do
    SPOOF_YAML="${SPOOF_YAML}  - ${_ip}"$'\n'
done
# trim trailing newline for the heredoc
SPOOF_YAML="${SPOOF_YAML%$'\n'}"

# Build optional forwarding section (client only, only when ports were entered)
FWD_SECTION=""
if [ "$ROLE" = "client" ] && [ -n "$FWD_PORTS_YAML" ]; then
    FWD_SECTION="
forwarding:
  ports:
${FWD_PORTS_YAML}"
fi

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" << EOF
# spoof-tunnel v6 configuration
# Generated by setup-wizard on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Edit manually or re-run:  sudo bash scripts/setup-wizard.sh

tunnel:
  role: ${ROLE}
  outer: udp
  peer_address: ${PEER_IP}
  listen_port: ${PORT}
  peer_port: ${PORT}

spoof:
  addresses:
${SPOOF_YAML}
  # Trigger failover to next spoof IP when loss exceeds this fraction (0.05 = 5%)
  loss_threshold: 0.05
  # Number of metric intervals above threshold before switching
  failover_intervals: 3

network:
  interface: ${IFACE}
  tun_name: ${TUN_NAME}
  local_tun_ip: ${LOCAL_TUN}
  peer_tun_ip: ${PEER_TUN}
  # mtu: 0 means auto-compute from interface MTU (iface_mtu - 58)
  mtu: 0

performance:
  rate_mbps: ${RATE}
  # flow_limit: max packets per flow for fq qdisc (0 = auto-compute from rate)
  flow_limit: ${FLOW_LIMIT}
  # batch_size: max packets per sendmmsg call
  batch_size: 16
  # rx_ring_blocks: TPACKET_V3 ring blocks (each 1 MB)
  rx_ring_blocks: 64
  # tx_cpu/rx_cpu: CPU affinity for TX/RX threads (-1 = auto)
  tx_cpu: -1
  rx_cpu: -1

monitoring:
  metric_interval: 5
  json_metrics: true
  prometheus_enabled: false
  prometheus_dir: /var/lib/prometheus/node-exporter
  qdisc_monitor_interval: 60
  log_retention_days: 30

advanced:
  # Apply kernel network tuning (rmem_max, wmem_max, netdev_max_backlog, etc.)
  sysctl_tune: true
  # Systemd watchdog timeout in seconds (0 = disabled)
  watchdog_sec: 30
${FWD_SECTION}
EOF

echo "  Config written to: ${OUTPUT}"
echo ""
echo "  Summary:"
printf "    Role     : %s\n" "$ROLE"
printf "    Interface: %s\n" "$IFACE"
printf "    Peer IP  : %s\n" "$PEER_IP"
printf "    Spoof IPs: %s\n" "$SPOOF_VALID"
printf "    Port     : %s\n" "$PORT"
printf "    Rate     : %s Mbps\n" "$RATE"
printf "    TUN      : %s  (%s ↔ %s)\n" "$TUN_NAME" "$LOCAL_TUN" "$PEER_TUN"
if [ -n "$FWD_PORTS_LIST" ]; then
    printf "    Forwarding : ports %s (TCP+UDP)\n" "$FWD_PORTS_LIST"
fi
echo ""
echo "  Next step:"
echo "    sudo bash install.sh"
echo ""
