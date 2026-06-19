#!/bin/bash
# qdisc-monitor.sh — scrape fq qdisc stats and append a JSON line.
# Invoked by cron every QDISC_MON_INTERVAL seconds.
set -euo pipefail

source /etc/spoof-tunnel/tunnel.env 2>/dev/null || exit 0
[ "${OUTER:-udp}" = "udp" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TC_OUT=$(tc -s qdisc show dev "${IFACE}" 2>/dev/null) || exit 0

# Extract fq stats: "Sent X bytes Y pkts ... dropped Z, overlimits A requeues B"
# and "  flows_plimit N"
DROPPED=$(echo "${TC_OUT}" | grep -oP 'dropped \K[0-9]+' | head -1 || echo 0)
FLOWS_PLIMIT=$(echo "${TC_OUT}" | grep -oP 'flows_plimit \K[0-9]+' | head -1 || echo 0)
OVERLIMITS=$(echo "${TC_OUT}" | grep -oP 'overlimits \K[0-9]+' | head -1 || echo 0)
QLEN=$(echo "${TC_OUT}" | grep -oP 'backlog [0-9]+b \K[0-9]+' | head -1 || echo 0)

printf '{"ts":"%s","iface":"%s","dropped":%s,"flows_plimit":%s,"overlimits":%s,"qlen":%s}\n' \
    "${TS}" "${IFACE}" "${DROPPED}" "${FLOWS_PLIMIT}" "${OVERLIMITS}" "${QLEN}"
