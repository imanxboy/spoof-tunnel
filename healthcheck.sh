#!/bin/bash
# healthcheck.sh — Nagios-compatible exit codes.
# 0=OK  1=WARNING  2=CRITICAL  3=UNKNOWN
#
# Usage: healthcheck.sh [instance]
#
# With an instance name it checks that tunnel's health.json and
# spoof-tunnel@<name> unit; with none it checks the single-tunnel layout, so a
# host that has not been migrated behaves exactly as before.
set -euo pipefail

INSTANCE="${1:-}"
LOG_DIR="/var/log/spoof-tunnel"

if [ -n "${INSTANCE}" ]; then
    ENV_FILE="/etc/spoof-tunnel/tunnels/${INSTANCE}.env"
    HEALTH_JSON="/run/spoof-tunnel/${INSTANCE}/health.json"
    UNIT="spoof-tunnel@${INSTANCE}"
else
    ENV_FILE="/etc/spoof-tunnel/tunnel.env"
    HEALTH_JSON="/run/spoof-tunnel/health.json"
    UNIT="spoof-tunnel"
fi

WARN_LOSS=2.0
CRIT_LOSS=5.0
MAX_METRIC_AGE=15   # seconds

rc=0
msg=""

# 1. Service active?
if ! systemctl is-active "${UNIT}" >/dev/null 2>&1; then
    echo "CRITICAL: service=inactive (${UNIT})"
    exit 2
fi

# 2. health.json fresh?
if [ ! -f "${HEALTH_JSON}" ]; then
    echo "UNKNOWN: health.json not found (service may be starting)"
    exit 3
fi

TS_MS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('ts',0))" 2>/dev/null || echo 0)
NOW_MS=$(( $(date +%s) * 1000 ))
AGE=$(( (NOW_MS - TS_MS) / 1000 ))
if [ "${AGE}" -gt "${MAX_METRIC_AGE}" ]; then
    echo "UNKNOWN: health.json is ${AGE}s old (metric thread stalled?)"
    exit 3
fi

# 3. Loss rate
LOSS_PCT=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('loss_pct',0))" 2>/dev/null || echo 0)
LOSS_INT=$(echo "${LOSS_PCT}" | awk '{printf "%d", $1*10}')  # tenths, integer compare
WARN_INT=$(echo "${WARN_LOSS}" | awk '{printf "%d", $1*10}')
CRIT_INT=$(echo "${CRIT_LOSS}" | awk '{printf "%d", $1*10}')

if [ "${LOSS_INT}" -ge "${CRIT_INT}" ]; then
    msg="loss=${LOSS_PCT}% (>=${CRIT_LOSS}%)"
    rc=2
elif [ "${LOSS_INT}" -ge "${WARN_INT}" ]; then
    msg="loss=${LOSS_PCT}% (>=${WARN_LOSS}%)"
    [ "${rc}" -lt 1 ] && rc=1
fi

# 4. qdisc drops (UDP mode). The qdisc belongs to the physical interface, so
#    its log is per interface rather than per tunnel.
source "${ENV_FILE}" 2>/dev/null || true
QDISC_LOG="${LOG_DIR}/qdisc-${IFACE:-unknown}.log"
[ -f "${QDISC_LOG}" ] || QDISC_LOG="${LOG_DIR}/qdisc.log"
if [ "${OUTER:-udp}" = "udp" ] && [ -f "${QDISC_LOG}" ]; then
    LAST=$(tail -1 "${QDISC_LOG}" 2>/dev/null || true)
    FP=$(echo "${LAST}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('flows_plimit',0))" 2>/dev/null || echo 0)
    if [ "${FP:-0}" -gt 0 ]; then
        msg="${msg:+$msg; }qdisc flows_plimit=${FP}"
        [ "${rc}" -lt 1 ] && rc=1
    fi
fi

TX_PPS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('tx_pps',0))" 2>/dev/null || echo 0)
RX_PPS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('rx_pps',0))" 2>/dev/null || echo 0)

STATUS_LINE="service=active tx=${TX_PPS}pps rx=${RX_PPS}pps loss=${LOSS_PCT}%"
[ -n "${msg}" ] && STATUS_LINE="${STATUS_LINE} (${msg})"

case "${rc}" in
    0) echo "OK: ${STATUS_LINE}" ;;
    1) echo "WARNING: ${STATUS_LINE}" ;;
    2) echo "CRITICAL: ${STATUS_LINE}" ;;
esac

exit "${rc}"
