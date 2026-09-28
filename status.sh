#!/bin/bash
# Human-readable tunnel status.
#
# Usage: status.sh [instance]
#
# With an instance name it reports on /etc/spoof-tunnel/tunnels/<name>.env and
# the spoof-tunnel@<name> unit. With none it falls back to the single-tunnel
# layout, so a host that has not been migrated behaves exactly as before.
#
# Safe to run as any user that can read the env file and /run/spoof-tunnel/.
set -euo pipefail

INSTANCE="${1:-}"
LOG_DIR="/var/log/spoof-tunnel"

if [ -n "${INSTANCE}" ]; then
    ENV_FILE="/etc/spoof-tunnel/tunnels/${INSTANCE}.env"
    CONF_FILE="/etc/spoof-tunnel/tunnels/${INSTANCE}.yaml"
    HEALTH_JSON="/run/spoof-tunnel/${INSTANCE}/health.json"
    UNIT="spoof-tunnel@${INSTANCE}"
    LABEL="${INSTANCE}"
else
    ENV_FILE="/etc/spoof-tunnel/tunnel.env"
    CONF_FILE="/etc/spoof-tunnel/config.yaml"
    HEALTH_JSON="/run/spoof-tunnel/health.json"
    UNIT="spoof-tunnel"
    LABEL="single tunnel"
fi

[ -f "${ENV_FILE}" ] || { echo "not installed"; exit 0; }
source "${ENV_FILE}"

# qdisc stats are a property of the physical interface, not of a tunnel, so
# they are logged per interface. Fall back to the pre-migration filename.
QDISC_LOG="${LOG_DIR}/qdisc-${IFACE:-unknown}.log"
[ -f "${QDISC_LOG}" ] || QDISC_LOG="${LOG_DIR}/qdisc.log"

HR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "${HR}"
printf "  spoof-tunnel v6  [%s]  %s\n" "${MODE:-unknown}" "${LABEL}"
echo "${HR}"

# Service state
SVC_STATE=$(systemctl is-active "${UNIT}" 2>/dev/null || echo "unknown")
SVC_COLOR=""
if [ "${SVC_STATE}" = "active" ]; then SVC_COLOR=""; else SVC_COLOR="  *** "; fi
UPTIME=""
if [ "${SVC_STATE}" = "active" ]; then
    START_TS=$(systemctl show "${UNIT}" --value -p ActiveEnterTimestamp 2>/dev/null || true)
    [ -n "${START_TS}" ] && UPTIME=" (since ${START_TS})"
fi
printf "  Service:        %s%s%s\n" "${SVC_COLOR}" "${SVC_STATE}" "${UPTIME}"
printf "  Unit:           %s\n" "${UNIT}"
printf "  Binary:         %s\n" "$(command -v spoof-tunnel 2>/dev/null || echo '/usr/local/bin/spoof-tunnel')"
printf "  Config:         %s\n" "${CONF_FILE}"
printf "  Outer:          %s\n" "${OUTER:-udp}"
printf "  Peer:           %s:%s\n" "${PEER_IP:-?}" "${PEER_PORT:-2080}"
printf "  TUN:            %s  (%s ↔ %s)\n" \
    "${TUN_NAME:-?}" "${LOCAL_TUN:-?}" "${PEER_TUN:-?}"

echo ""

# Traffic (from health.json — written by binary every metric_interval seconds)
if [ -f "${HEALTH_JSON}" ]; then
    TX_PPS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('tx_pps',0))" 2>/dev/null || echo 0)
    RX_PPS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('rx_pps',0))" 2>/dev/null || echo 0)
    LOSS_PCT=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('loss_pct',0))" 2>/dev/null || echo 0)
    TS_MS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('ts',0))" 2>/dev/null || echo 0)
    NOW_MS=$(( $(date +%s) * 1000 ))
    AGE=$(( (NOW_MS - TS_MS) / 1000 ))
    printf "  TX:             %s pps\n" "${TX_PPS}"
    printf "  RX:             %s pps\n" "${RX_PPS}"
    printf "  Seq loss:       %s%%  (upper bound)\n" "${LOSS_PCT}"
    printf "  Last metric:    %ds ago\n" "${AGE}"
else
    printf "  Traffic:        no health.json yet\n"
fi

echo ""

# qdisc (UDP mode only)
if [ "${OUTER:-udp}" = "udp" ] && [ -f "${QDISC_LOG}" ]; then
    LAST_QDISC=$(tail -1 "${QDISC_LOG}" 2>/dev/null || true)
    if [ -n "${LAST_QDISC}" ]; then
        FP=$(echo "${LAST_QDISC}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('flows_plimit',0))" 2>/dev/null || echo 0)
        QDROP=$(echo "${LAST_QDISC}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dropped',0))" 2>/dev/null || echo 0)
        FP_STATUS="✓"; [ "${FP}" -gt 0 ] && FP_STATUS="⚠ DROPPING"
        printf "  Queue (%s, shared by every tunnel on this NIC):\n" "${IFACE:-?}"
        printf "    fq dropped:   %s\n" "${QDROP}"
        printf "    flows_plimit: %s  %s\n" "${FP}" "${FP_STATUS}"
    fi
fi

# Multi-spoof state
if [ -n "${SPOOF_IPS:-}" ]; then
    echo ""
    printf "  Spoof IPs:      %s\n" "${SPOOF_IPS}"
fi

# Port forwarding (client only)
if [ "${MODE:-}" = "client" ] && [ -n "${FORWARD_PORTS:-}" ]; then
    echo ""
    printf "  Forwarded ports  → %s (TCP+UDP each):\n" "${PEER_TUN:-?}"
    IFS=',' read -ra _FPS <<< "${FORWARD_PORTS}"
    for _fp in "${_FPS[@]}"; do
        printf "    :%s → %s:%s\n" "${_fp}" "${PEER_TUN:-?}" "${_fp}"
    done
    # Count only the rules belonging to THIS tunnel. A plain grep over the
    # whole table would also count every other tunnel's rules.
    if command -v iptables >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
        _dnat=0
        for _fp in "${_FPS[@]}"; do
            for _proto in tcp udp; do
                iptables -t nat -C PREROUTING -p "${_proto}" --dport "${_fp}" \
                    -j DNAT --to-destination "${PEER_TUN}:${_fp}" 2>/dev/null \
                    && _dnat=$(( _dnat + 1 ))
            done
        done
        _masq=0
        iptables -t nat -C POSTROUTING -o "${TUN_NAME}" -j MASQUERADE 2>/dev/null \
            && _masq=1
        _fwd=0
        iptables -C FORWARD -i "${IFACE}" -o "${TUN_NAME}" -j ACCEPT 2>/dev/null \
            && _fwd=$(( _fwd + 1 ))
        iptables -C FORWARD -i "${TUN_NAME}" -o "${IFACE}" -j ACCEPT 2>/dev/null \
            && _fwd=$(( _fwd + 1 ))
        printf "  NAT state:       %s DNAT, %s MASQUERADE, %s FORWARD ACCEPT\n" \
            "${_dnat}" "${_masq}" "${_fwd}"
    fi
fi

echo "${HR}"
