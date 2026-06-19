#!/bin/bash
# prometheus-export.sh — write Prometheus textfile from journal + qdisc.log.
# Called by systemd timer every 30s.
# Usage: prometheus-export.sh [/path/to/node-exporter/textfile-dir]
set -euo pipefail

PROM_DIR="${1:-/var/lib/prometheus/node-exporter}"
OUT="${PROM_DIR}/spoof-tunnel.prom"
TMP="${OUT}.tmp"

source /etc/spoof-tunnel/tunnel.env 2>/dev/null || exit 0

# ── service up ──────────────────────────────────────────────────────────────
UP=0
systemctl is-active spoof-tunnel >/dev/null 2>&1 && UP=1

# ── latest metric line from journal ─────────────────────────────────────────
METRIC_LINE=$(journalctl -u spoof-tunnel -n 200 --output=cat 2>/dev/null \
              | grep '^metric ' | tail -1)

tx_pkts=0; rx_pkts=0; tx_mbps=0; rx_mbps=0
seq_loss=0; reorder=0; tx_retry=0; tx_err=0; tun_werr=0; active_spoof=0

if [ -n "${METRIC_LINE}" ]; then
    for kv in ${METRIC_LINE}; do
        [ "${kv}" = "metric" ] && continue
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
            tx_pkts)     tx_pkts="$v" ;;
            rx_pkts)     rx_pkts="$v" ;;
            tx_mbps)     tx_mbps="$v" ;;
            rx_mbps)     rx_mbps="$v" ;;
            seq_loss)    seq_loss="$v" ;;
            reorder)     reorder="$v" ;;
            tx_retry)    tx_retry="$v" ;;
            tx_err)      tx_err="$v" ;;
            tun_werr)    tun_werr="$v" ;;
            active_spoof) active_spoof="$v" ;;
        esac
    done
fi

# ── latest qdisc stats ───────────────────────────────────────────────────────
QDISC_LINE=$(tail -1 /var/log/spoof-tunnel/qdisc.log 2>/dev/null || true)
qdisc_dropped=0; qdisc_flows_plimit=0

if [ -n "${QDISC_LINE}" ]; then
    qdisc_dropped=$(echo "${QDISC_LINE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dropped',0))" 2>/dev/null || echo 0)
    qdisc_flows_plimit=$(echo "${QDISC_LINE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('flows_plimit',0))" 2>/dev/null || echo 0)
fi

# ── health.json ─────────────────────────────────────────────────────────────
LOSS_PCT=0
if [ -f /run/spoof-tunnel/health.json ]; then
    LOSS_PCT=$(python3 -c "import json; d=json.load(open('/run/spoof-tunnel/health.json')); print(d.get('loss_pct',0))" 2>/dev/null || echo 0)
fi

ROLE="${MODE:-unknown}"
VERSION_LABEL=$(cat /etc/spoof-tunnel/VERSION 2>/dev/null || echo "unknown")

# ── write textfile ───────────────────────────────────────────────────────────
{
cat << EOF
# HELP spoof_tunnel_up Service is running (1=yes, 0=no)
# TYPE spoof_tunnel_up gauge
spoof_tunnel_up{role="${ROLE}"} ${UP}

# HELP spoof_tunnel_tx_mbps Current TX throughput Mbps
# TYPE spoof_tunnel_tx_mbps gauge
spoof_tunnel_tx_mbps{role="${ROLE}"} ${tx_mbps}

# HELP spoof_tunnel_rx_mbps Current RX throughput Mbps
# TYPE spoof_tunnel_rx_mbps gauge
spoof_tunnel_rx_mbps{role="${ROLE}"} ${rx_mbps}

# HELP spoof_tunnel_seq_loss_total Cumulative sequence gaps
# TYPE spoof_tunnel_seq_loss_total counter
spoof_tunnel_seq_loss_total{role="${ROLE}"} ${seq_loss}

# HELP spoof_tunnel_reorder_total Cumulative reordered packets
# TYPE spoof_tunnel_reorder_total counter
spoof_tunnel_reorder_total{role="${ROLE}"} ${reorder}

# HELP spoof_tunnel_tx_retries_total Cumulative TX retries
# TYPE spoof_tunnel_tx_retries_total counter
spoof_tunnel_tx_retries_total{role="${ROLE}"} ${tx_retry}

# HELP spoof_tunnel_tx_errors_total Cumulative TX hard errors
# TYPE spoof_tunnel_tx_errors_total counter
spoof_tunnel_tx_errors_total{role="${ROLE}"} ${tx_err}

# HELP spoof_tunnel_tun_write_errors_total TUN write errors
# TYPE spoof_tunnel_tun_write_errors_total counter
spoof_tunnel_tun_write_errors_total{role="${ROLE}"} ${tun_werr}

# HELP spoof_tunnel_qdisc_dropped_total fq total drop counter
# TYPE spoof_tunnel_qdisc_dropped_total counter
spoof_tunnel_qdisc_dropped_total{role="${ROLE}",iface="${IFACE:-unknown}"} ${qdisc_dropped}

# HELP spoof_tunnel_qdisc_flows_plimit_total fq per-flow limit drops
# TYPE spoof_tunnel_qdisc_flows_plimit_total counter
spoof_tunnel_qdisc_flows_plimit_total{role="${ROLE}",iface="${IFACE:-unknown}"} ${qdisc_flows_plimit}

# HELP spoof_tunnel_loss_pct Rolling 5-minute packet loss percentage
# TYPE spoof_tunnel_loss_pct gauge
spoof_tunnel_loss_pct{role="${ROLE}"} ${LOSS_PCT}

# HELP spoof_tunnel_active_spoof_index Currently active spoof IP index
# TYPE spoof_tunnel_active_spoof_index gauge
spoof_tunnel_active_spoof_index{role="${ROLE}"} ${active_spoof}
EOF
} > "${TMP}"

mv "${TMP}" "${OUT}"
