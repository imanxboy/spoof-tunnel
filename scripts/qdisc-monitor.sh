#!/bin/bash
# qdisc-monitor.sh — scrape fq qdisc stats and append a JSON line per
# interface. Invoked by cron every QDISC_MON_INTERVAL seconds.
#
# The fq qdisc is a property of the physical NIC, not of a tunnel: several
# tunnels can share one interface and they all see the same queue. So this
# scrapes each DISTINCT interface once and writes
# /var/log/spoof-tunnel/qdisc-<iface>.log, rather than one log per tunnel.
set -euo pipefail

TUNNELS_DIR="/etc/spoof-tunnel/tunnels"
LEGACY_ENV="/etc/spoof-tunnel/tunnel.env"
LOG_DIR="/var/log/spoof-tunnel"

env_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^${2}=//p" "$1" | tail -1
}

scrape() {
    local iface="$1"
    local ts tc_out dropped flows_plimit overlimits qlen
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tc_out=$(tc -s qdisc show dev "${iface}" 2>/dev/null) || return 0

    # Extract fq stats: "Sent X bytes Y pkts ... dropped Z, overlimits A
    # requeues B" and "  flows_plimit N"
    dropped=$(echo "${tc_out}"      | grep -oP 'dropped \K[0-9]+'      | head -1 || echo 0)
    flows_plimit=$(echo "${tc_out}" | grep -oP 'flows_plimit \K[0-9]+' | head -1 || echo 0)
    overlimits=$(echo "${tc_out}"   | grep -oP 'overlimits \K[0-9]+'   | head -1 || echo 0)
    qlen=$(echo "${tc_out}"         | grep -oP 'backlog [0-9]+b \K[0-9]+' | head -1 || echo 0)

    printf '{"ts":"%s","iface":"%s","dropped":%s,"flows_plimit":%s,"overlimits":%s,"qlen":%s}\n' \
        "${ts}" "${iface}" "${dropped:-0}" "${flows_plimit:-0}" \
        "${overlimits:-0}" "${qlen:-0}" \
        >> "${LOG_DIR}/qdisc-${iface}.log"
}

mkdir -p "${LOG_DIR}"

# Collect the distinct interfaces of every UDP-mode tunnel on this host.
SEEN=""
for env in "${TUNNELS_DIR}"/*.env "${LEGACY_ENV}"; do
    [ -f "${env}" ] || continue
    outer="$(env_get "${env}" OUTER)"
    [ "${outer:-udp}" = "udp" ] || continue
    iface="$(env_get "${env}" IFACE)"
    [ -n "${iface}" ] || continue
    case " ${SEEN} " in *" ${iface} "*) continue ;; esac
    SEEN="${SEEN} ${iface}"
    scrape "${iface}"
done
