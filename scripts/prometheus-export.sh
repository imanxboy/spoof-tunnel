#!/bin/bash
# prometheus-export.sh — write Prometheus textfile from journal + qdisc logs.
# Called by systemd timer every 30s.
# Usage: prometheus-export.sh [/path/to/node-exporter/textfile-dir]
#
# Emits one series per tunnel, distinguished by an instance="<name>" label.
# A host that has not been migrated to the multi-tunnel layout reports its
# single tunnel as instance="default".
set -euo pipefail

PROM_DIR="${1:-/var/lib/prometheus/node-exporter}"
OUT="${PROM_DIR}/spoof-tunnel.prom"
TMP="${OUT}.tmp"

TUNNELS_DIR="/etc/spoof-tunnel/tunnels"
LEGACY_ENV="/etc/spoof-tunnel/tunnel.env"
LOG_DIR="/var/log/spoof-tunnel"

VERSION_LABEL=$(cat /etc/spoof-tunnel/VERSION 2>/dev/null || echo "unknown")

# Values may be quoted (EXTRA_ARGS always is), so strip a surrounding pair.
env_get() {
    local v
    [ -f "$1" ] || return 0
    v="$(sed -n "s/^${2}=//p" "$1" | tail -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# ── metric help/type headers, emitted once ──────────────────────────────────

emit_headers() {
cat << 'EOF'
# HELP spoof_tunnel_up Service is running (1=yes, 0=no)
# TYPE spoof_tunnel_up gauge
# HELP spoof_tunnel_tx_mbps Current TX throughput Mbps
# TYPE spoof_tunnel_tx_mbps gauge
# HELP spoof_tunnel_rx_mbps Current RX throughput Mbps
# TYPE spoof_tunnel_rx_mbps gauge
# HELP spoof_tunnel_seq_loss_total Cumulative sequence gaps
# TYPE spoof_tunnel_seq_loss_total counter
# HELP spoof_tunnel_reorder_total Cumulative reordered packets
# TYPE spoof_tunnel_reorder_total counter
# HELP spoof_tunnel_tx_retries_total Cumulative TX retries
# TYPE spoof_tunnel_tx_retries_total counter
# HELP spoof_tunnel_tx_errors_total Cumulative TX hard errors
# TYPE spoof_tunnel_tx_errors_total counter
# HELP spoof_tunnel_tun_write_errors_total TUN write errors
# TYPE spoof_tunnel_tun_write_errors_total counter
# HELP spoof_tunnel_qdisc_dropped_total fq total drop counter
# TYPE spoof_tunnel_qdisc_dropped_total counter
# HELP spoof_tunnel_qdisc_flows_plimit_total fq per-flow limit drops
# TYPE spoof_tunnel_qdisc_flows_plimit_total counter
# HELP spoof_tunnel_loss_pct Rolling 5-minute packet loss percentage
# TYPE spoof_tunnel_loss_pct gauge
# HELP spoof_tunnel_active_spoof_index Currently active spoof IP index
# TYPE spoof_tunnel_active_spoof_index gauge
EOF
}

# ── one tunnel's series ─────────────────────────────────────────────────────
# emit_tunnel <instance-label> <env-file> <unit> <health.json>

emit_tunnel() {
    local inst="$1" env_file="$2" unit="$3" health="$4"

    local iface role
    iface="$(env_get "${env_file}" IFACE)"
    role="$(env_get "${env_file}" MODE)"
    role="${role:-unknown}"

    local up=0
    systemctl is-active "${unit}" >/dev/null 2>&1 && up=1

    local metric_line
    metric_line=$(journalctl -u "${unit}" -n 200 --output=cat 2>/dev/null \
                  | grep '^metric ' | tail -1 || true)

    local tx_pkts=0 rx_pkts=0 tx_mbps=0 rx_mbps=0
    local seq_loss=0 reorder=0 tx_retry=0 tx_err=0 tun_werr=0 active_spoof=0

    if [ -n "${metric_line}" ]; then
        local kv k v
        for kv in ${metric_line}; do
            [ "${kv}" = "metric" ] && continue
            k="${kv%%=*}"; v="${kv#*=}"
            case "$k" in
                tx_pkts)      tx_pkts="$v" ;;
                rx_pkts)      rx_pkts="$v" ;;
                tx_mbps)      tx_mbps="$v" ;;
                rx_mbps)      rx_mbps="$v" ;;
                seq_loss)     seq_loss="$v" ;;
                reorder)      reorder="$v" ;;
                tx_retry)     tx_retry="$v" ;;
                tx_err)       tx_err="$v" ;;
                tun_werr)     tun_werr="$v" ;;
                active_spoof) active_spoof="$v" ;;
            esac
        done
    fi

    # qdisc stats belong to the interface, so tunnels sharing a NIC report the
    # same numbers. The iface label makes that explicit.
    local qdisc_log="${LOG_DIR}/qdisc-${iface}.log"
    [ -f "${qdisc_log}" ] || qdisc_log="${LOG_DIR}/qdisc.log"
    local qdisc_line qdisc_dropped=0 qdisc_flows_plimit=0
    qdisc_line=$(tail -1 "${qdisc_log}" 2>/dev/null || true)
    if [ -n "${qdisc_line}" ]; then
        qdisc_dropped=$(echo "${qdisc_line}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('dropped',0))" 2>/dev/null || echo 0)
        qdisc_flows_plimit=$(echo "${qdisc_line}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('flows_plimit',0))" 2>/dev/null || echo 0)
    fi

    local loss_pct=0
    if [ -f "${health}" ]; then
        loss_pct=$(python3 -c "import json; print(json.load(open('${health}')).get('loss_pct',0))" 2>/dev/null || echo 0)
    fi

    local L="instance=\"${inst}\",role=\"${role}\",version=\"${VERSION_LABEL}\""
    local LQ="instance=\"${inst}\",role=\"${role}\",iface=\"${iface:-unknown}\""

    echo "spoof_tunnel_up{${L}} ${up}"
    echo "spoof_tunnel_tx_mbps{${L}} ${tx_mbps}"
    echo "spoof_tunnel_rx_mbps{${L}} ${rx_mbps}"
    echo "spoof_tunnel_seq_loss_total{${L}} ${seq_loss}"
    echo "spoof_tunnel_reorder_total{${L}} ${reorder}"
    echo "spoof_tunnel_tx_retries_total{${L}} ${tx_retry}"
    echo "spoof_tunnel_tx_errors_total{${L}} ${tx_err}"
    echo "spoof_tunnel_tun_write_errors_total{${L}} ${tun_werr}"
    echo "spoof_tunnel_qdisc_dropped_total{${LQ}} ${qdisc_dropped}"
    echo "spoof_tunnel_qdisc_flows_plimit_total{${LQ}} ${qdisc_flows_plimit}"
    echo "spoof_tunnel_loss_pct{${L}} ${loss_pct}"
    echo "spoof_tunnel_active_spoof_index{${L}} ${active_spoof}"
}

# ── walk every configured tunnel ────────────────────────────────────────────

{
    emit_headers

    found=0
    if [ -d "${TUNNELS_DIR}" ]; then
        for env_file in "${TUNNELS_DIR}"/*.env; do
            [ -f "${env_file}" ] || continue
            name="$(basename "${env_file}")"; name="${name%.env}"
            emit_tunnel "${name}" "${env_file}" "spoof-tunnel@${name}" \
                        "/run/spoof-tunnel/${name}/health.json"
            found=1
        done
    fi

    if [ "${found}" = "0" ] && [ -f "${LEGACY_ENV}" ]; then
        emit_tunnel "default" "${LEGACY_ENV}" "spoof-tunnel" \
                    "/run/spoof-tunnel/health.json"
    fi
} > "${TMP}"

mv "${TMP}" "${OUT}"
