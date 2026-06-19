#!/bin/bash
# Human-readable tunnel status. Safe to run as any user that can read
# /etc/spoof-tunnel/tunnel.env and /run/spoof-tunnel/.
set -euo pipefail

ENV_FILE="/etc/spoof-tunnel/tunnel.env"
HEALTH_JSON="/run/spoof-tunnel/health.json"
QDISC_LOG="/var/log/spoof-tunnel/qdisc.log"

[ -f "${ENV_FILE}" ] || { echo "not installed"; exit 0; }
source "${ENV_FILE}"

HR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "${HR}"
printf "  spoof-tunnel v6  [%s]\n" "${MODE:-unknown}"
echo "${HR}"

# Service state
SVC_STATE=$(systemctl is-active spoof-tunnel 2>/dev/null || echo "unknown")
SVC_COLOR=""
if [ "${SVC_STATE}" = "active" ]; then SVC_COLOR=""; else SVC_COLOR="  *** "; fi
UPTIME=""
if [ "${SVC_STATE}" = "active" ]; then
    START_TS=$(systemctl show spoof-tunnel --value -p ActiveEnterTimestamp 2>/dev/null || true)
    [ -n "${START_TS}" ] && UPTIME=" (since ${START_TS})"
fi
printf "  Service:        %s%s%s\n" "${SVC_COLOR}" "${SVC_STATE}" "${UPTIME}"
printf "  Binary:         %s\n" "$(command -v spoof-tunnel 2>/dev/null || echo '/usr/local/bin/spoof-tunnel')"
printf "  Config:         /etc/spoof-tunnel/config.yaml\n"
printf "  Outer:          %s\n" "${OUTER:-udp}"
printf "  Peer:           %s:%s\n" "${PEER_IP:-?}" "${PEER_PORT:-2080}"

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
        printf "  Queue (%s):\n" "${IFACE:-?}"
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
    if command -v iptables >/dev/null 2>&1; then
        _dnat=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "DNAT" || echo 0)
        _masq=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "MASQUERADE" || echo 0)
        _fwd=$(iptables -L FORWARD -n 2>/dev/null | grep -c "ACCEPT" || echo 0)
        printf "  NAT state:       %s DNAT, %s MASQUERADE, %s FORWARD ACCEPT\n" \
            "${_dnat}" "${_masq}" "${_fwd}"
    fi
fi

echo "${HR}"
