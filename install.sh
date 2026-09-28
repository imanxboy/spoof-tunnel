#!/bin/bash
# spoof-tunnel-v6 install.sh
# Idempotent. Safe to re-run on an already-installed system.
#
# Usage: sudo ./install.sh [--config-only] [--no-start] [--tooling-only]
#
#   --tooling-only  Install the binary, hooks, scripts and the
#                   spoof-tunnel@.service template, and nothing else. No
#                   config.yaml is read and no service is touched.
#
# Tooling-only is also what happens when there is no ./config.yaml, which is
# the normal case: installing puts the tools on the host, and tunnels are
# created afterwards with `spoofctl create`. Nothing here invents an address
# or starts a tunnel on its own.
#
# With a ./config.yaml present the script additionally installs that single
# tunnel onto the plain spoof-tunnel.service unit. That is the original
# layout, kept so hosts which have not run `spoofctl migrate` can still be
# upgraded in place.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_YAML="${PACKAGE_DIR}/config.yaml"
INSTALL_LOG="/var/log/spoof-tunnel/install.log"
ENV_FILE="/etc/spoof-tunnel/tunnel.env"
BIN_DST="/usr/local/bin/spoof-tunnel"
LIB_DIR="/usr/local/lib/spoof-tunnel"
LIBEXEC_DIR="/usr/local/libexec"
SERVICE_FILE="/etc/systemd/system/spoof-tunnel.service"
SYSCTL_FILE="/etc/sysctl.d/99-spoof-tunnel.conf"
CRON_FILE="/etc/cron.d/spoof-tunnel"
LOGROTATE_FILE="/etc/logrotate.d/spoof-tunnel"

CONFIG_ONLY=0
NO_START=0
TOOLING_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --config-only)  CONFIG_ONLY=1 ;;
        --no-start)     NO_START=1 ;;
        --tooling-only) TOOLING_ONLY=1 ;;
    esac
done

TUNNELS_DIR="/etc/spoof-tunnel/tunnels"
TEMPLATE_UNIT_FILE="/etc/systemd/system/spoof-tunnel@.service"

# ── pre-flight ──────────────────────────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

for cmd in python3 ip tc iptables sysctl systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $cmd" >&2
        exit 1
    fi
done

# Check TUN device — required for the tunnel to create its tun0 interface
if [ ! -e /dev/net/tun ]; then
    echo "WARNING: /dev/net/tun not found — attempting modprobe tun..." >&2
    if modprobe tun 2>/dev/null && [ -e /dev/net/tun ]; then
        echo "tun" >> /etc/modules 2>/dev/null || true
        echo "  tun module loaded and persisted in /etc/modules" >&2
    else
        echo "ERROR: /dev/net/tun is unavailable and 'modprobe tun' failed." >&2
        echo "       The tunnel cannot run without a TUN device." >&2
        echo "       On VPS platforms: check your provider's virtualisation layer" >&2
        echo "       or enable TUN/TAP in the control panel." >&2
        exit 1
    fi
fi

# No config.yaml means "just install the tools" — the operator creates
# tunnels afterwards with `spoofctl create`, entering their own addresses.
if [ "${TOOLING_ONLY}" = "0" ] && [ ! -f "${CONFIG_YAML}" ]; then
    TOOLING_ONLY=1
fi

if [ "${TOOLING_ONLY}" = "0" ]; then
    # Validate config before doing anything
    python3 "${PACKAGE_DIR}/scripts/config-parse.py" --validate "${CONFIG_YAML}" 2>&1 \
        || { echo "ERROR: config.yaml validation failed" >&2; exit 1; }
fi

# ── directory setup ─────────────────────────────────────────────────────────

mkdir -p /etc/spoof-tunnel \
         /var/log/spoof-tunnel \
         "${LIB_DIR}" \
         "${LIBEXEC_DIR}" \
         /run/spoof-tunnel

# Init install log
mkdir -p "$(dirname "${INSTALL_LOG}")"
echo "=== install.sh run: $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "${INSTALL_LOG}"

log() { echo "$*"; echo "$(date -u +%T) $*" >> "${INSTALL_LOG}"; }

# ── parse config ────────────────────────────────────────────────────────────

if [ "${TOOLING_ONLY}" = "0" ]; then
    log "Parsing config.yaml..."
    python3 "${PACKAGE_DIR}/scripts/config-parse.py" \
        --output "${ENV_FILE}" "${CONFIG_YAML}" 2>&1 | tee -a "${INSTALL_LOG}"
    chmod 640 "${ENV_FILE}"

    # Source the generated env file
    set -a; source "${ENV_FILE}"; set +a

    if [ "${CONFIG_ONLY}" = "1" ]; then
        log "Config-only mode: regenerated ${ENV_FILE}"
        exit 0
    fi
else
    log "Installing tools only — no tunnel is created or started."
    # Switch the host to the named-instance layout, unless it is still on the
    # original single-tunnel one, which `spoofctl migrate` converts on request.
    if [ ! -f /etc/spoof-tunnel/config.yaml ]; then
        mkdir -p "${TUNNELS_DIR}"
    fi
fi

# ── verify full-install prerequisites ────────────────────────────────────────

for hook in libexec/spoof-tunnel-prepare libexec/spoof-tunnel-qdisc libexec/spoof-tunnel-forward; do
    if [ ! -f "${PACKAGE_DIR}/${hook}" ]; then
        echo "ERROR: required hook missing: ${PACKAGE_DIR}/${hook}" >&2
        exit 1
    fi
done

# ── install binary ──────────────────────────────────────────────────────────

if [ ! -f "${PACKAGE_DIR}/bin/spoof-tunnel" ]; then
    log "Binary not found; building from source..."
    if [ ! -f "${PACKAGE_DIR}/src/spoof_tunnel_v6.c" ]; then
        echo "ERROR: neither bin/spoof-tunnel nor src/spoof_tunnel_v6.c found" >&2
        exit 1
    fi
    "${PACKAGE_DIR}/build.sh" 2>&1 | tee -a "${INSTALL_LOG}"
fi

log "Installing binary..."
if [ -f "${BIN_DST}" ]; then
    cp -f "${BIN_DST}" "${BIN_DST}.bak"
fi
install -m 755 -o root -g root "${PACKAGE_DIR}/bin/spoof-tunnel" "${BIN_DST}"

# ── install scripts ─────────────────────────────────────────────────────────

log "Installing scripts..."
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/scripts/config-parse.py" \
    "${LIB_DIR}/config-parse.py"
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/scripts/qdisc-monitor.sh" \
    "${LIB_DIR}/qdisc-monitor.sh"
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/scripts/prometheus-export.sh" \
    "${LIB_DIR}/prometheus-export.sh"
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/status.sh" \
    "${LIB_DIR}/status.sh"
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/healthcheck.sh" \
    "${LIB_DIR}/healthcheck.sh"
# Kept on the host so 'spoofctl create' can build a new tunnel after
# 'spoofctl delete' without re-downloading the release.
install -m 755 -o root -g root \
    "${PACKAGE_DIR}/scripts/setup-wizard.sh" \
    "${LIB_DIR}/setup-wizard.sh"

# ── config.yaml (never overwrite existing) ──────────────────────────────────

if [ ! -f /etc/spoof-tunnel/config.yaml ]; then
    install -m 640 -o root -g root "${CONFIG_YAML}" /etc/spoof-tunnel/config.yaml
    log "Installed config.yaml to /etc/spoof-tunnel/config.yaml"
else
    log "config.yaml already exists — not overwriting"
fi

# ── ExecStartPre hook ────────────────────────────────────────────────────────

log "Installing prepare hook..."
install -m 750 -o root -g root \
    "${PACKAGE_DIR}/libexec/spoof-tunnel-prepare" \
    "${LIBEXEC_DIR}/spoof-tunnel-prepare"

# ── ExecStartPost qdisc hook ────────────────────────────────────────────────

log "Installing qdisc hook..."
install -m 750 -o root -g root \
    "${PACKAGE_DIR}/libexec/spoof-tunnel-qdisc" \
    "${LIBEXEC_DIR}/spoof-tunnel-qdisc"

# ── ExecStartPost forwarding hook ────────────────────────────────────────────

log "Installing forwarding hook..."
install -m 750 -o root -g root \
    "${PACKAGE_DIR}/libexec/spoof-tunnel-forward" \
    "${LIBEXEC_DIR}/spoof-tunnel-forward"

# ── systemd units ────────────────────────────────────────────────────────────
#
# Two units are written:
#
#   spoof-tunnel@.service   the template every named tunnel runs on. Because
#                           one file serves every instance it cannot bake in
#                           per-tunnel ExecStart flags, so it expands
#                           $EXTRA_ARGS (unbraced, so systemd splits it into
#                           words) from the instance's env file. WatchdogSec
#                           cannot be an environment expansion at all, so each
#                           instance carries it in a drop-in written by
#                           spoofctl.
#
#   spoof-tunnel.service    the original single-tunnel unit, written only when
#                           this run is installing a config.yaml. A host that
#                           has migrated never gets it back.
#
# KEEP IN SYNC with write_template_unit() in scripts/spoofctl — the two must
# produce byte-identical files.

log "Writing systemd template unit..."
cat > "${TEMPLATE_UNIT_FILE}" << EOF
[Unit]
Description=spoof-tunnel-v6 IP tunnel (%i)
After=network.target
Wants=network.target

[Service]
Type=notify
EnvironmentFile=${TUNNELS_DIR}/%i.env
ExecStartPre=${LIBEXEC_DIR}/spoof-tunnel-prepare %i
ExecStart=${BIN_DST} \\
    --name %i \\
    --mode \${MODE} \\
    --outer \${OUTER} \\
    --iface \${IFACE} \\
    --tun \${TUN_NAME} \\
    --peer-ip \${PEER_IP} \\
    --local-tun \${LOCAL_TUN} \\
    --peer-tun \${PEER_TUN} \\
    --listen-port \${LISTEN_PORT} \\
    --peer-port \${PEER_PORT} \\
    --mtu \${MTU} \\
    --tx-cpu \${TX_CPU} \\
    --rx-cpu \${RX_CPU} \\
    --rate-mbps \${RATE_MBPS} \\
    --flow-limit \${FLOW_LIMIT} \\
    --batch-size \${BATCH_SIZE} \\
    --rx-block-nr \${RX_BLOCK_NR} \\
    --failover-loss \${FAILOVER_LOSS} \\
    --failover-intervals \${FAILOVER_INTERVALS} \\
    --metric-interval \${METRIC_INTERVAL} \\
    --watchdog-sec \${WATCHDOG_SEC} \$EXTRA_ARGS
ExecStartPost=${LIBEXEC_DIR}/spoof-tunnel-qdisc %i
ExecStartPost=${LIBEXEC_DIR}/spoof-tunnel-forward %i
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_IPC_LOCK
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

if [ "${TOOLING_ONLY}" = "0" ]; then
log "Writing single-tunnel service unit..."
WATCHDOG_LINE=""
[ "${WATCHDOG_SEC:-0}" -gt 0 ] && WATCHDOG_LINE="WatchdogSec=${WATCHDOG_SEC}"

cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=spoof-tunnel-v6 IP tunnel
After=network.target
Wants=network.target

[Service]
Type=notify
EnvironmentFile=/etc/spoof-tunnel/tunnel.env
ExecStartPre=${LIBEXEC_DIR}/spoof-tunnel-prepare
ExecStart=${BIN_DST} \\
    --mode \${MODE} \\
    --outer \${OUTER} \\
    --iface \${IFACE} \\
    --tun \${TUN_NAME} \\
    --peer-ip \${PEER_IP} \\
    --local-tun \${LOCAL_TUN} \\
    --peer-tun \${PEER_TUN} \\
    --listen-port \${LISTEN_PORT} \\
    --peer-port \${PEER_PORT} \\
    --mtu \${MTU} \\
    --tx-cpu \${TX_CPU} \\
    --rx-cpu \${RX_CPU} \\
    --rate-mbps \${RATE_MBPS} \\
    --flow-limit \${FLOW_LIMIT} \\
    --batch-size \${BATCH_SIZE} \\
    --rx-block-nr \${RX_BLOCK_NR} \\
    --failover-loss \${FAILOVER_LOSS} \\
    --failover-intervals \${FAILOVER_INTERVALS} \\
    --metric-interval \${METRIC_INTERVAL} \\
    --watchdog-sec \${WATCHDOG_SEC} \$EXTRA_ARGS
ExecStartPost=${LIBEXEC_DIR}/spoof-tunnel-qdisc
ExecStartPost=${LIBEXEC_DIR}/spoof-tunnel-forward
Restart=always
RestartSec=2
${WATCHDOG_LINE}
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_IPC_LOCK
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
fi

# ── sysctl tuning ────────────────────────────────────────────────────────────

# Host-wide kernel tuning: shared by every tunnel, applied once. Skipped in
# tooling-only mode only because there is no config to read the flag from —
# the file already on disk stays in force.
if [ "${TOOLING_ONLY}" = "0" ] && [ "${SYSCTL_TUNE:-true}" = "true" ]; then
    log "Applying sysctl tuning..."
    cat > "${SYSCTL_FILE}" << EOF
# spoof-tunnel kernel tuning
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.netdev_max_backlog = 250000
net.core.optmem_max = 65536
net.ipv4.udp_rmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
vm.swappiness = 10
EOF
    sysctl -p "${SYSCTL_FILE}" >> "${INSTALL_LOG}" 2>&1 || true
fi

# ── qdisc monitoring cron ────────────────────────────────────────────────────

log "Installing qdisc monitor cron (every minute)..."
# The monitor scrapes every interface in use and writes
# /var/log/spoof-tunnel/qdisc-<iface>.log itself, so nothing is redirected
# here any more.
cat > "${CRON_FILE}" << EOF
# spoof-tunnel qdisc monitor — runs every minute, one log per interface
* * * * * root ${LIB_DIR}/qdisc-monitor.sh >/dev/null 2>&1
EOF

# ── Prometheus export ────────────────────────────────────────────────────────

if [ "${TOOLING_ONLY}" = "0" ] && [ "${PROM_ENABLED:-false}" = "true" ]; then
    log "Installing Prometheus export timer..."
    cat > /etc/systemd/system/spoof-tunnel-prom.service << EOF
[Unit]
Description=spoof-tunnel Prometheus textfile export
After=spoof-tunnel.service

[Service]
Type=oneshot
ExecStart=${LIB_DIR}/prometheus-export.sh ${PROM_DIR:-/var/lib/prometheus/node-exporter}
EOF
    cat > /etc/systemd/system/spoof-tunnel-prom.timer << EOF
[Unit]
Description=spoof-tunnel Prometheus export timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Unit=spoof-tunnel-prom.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now spoof-tunnel-prom.timer
fi

# ── log rotation ─────────────────────────────────────────────────────────────

RETAIN="${LOG_RETENTION_DAYS:-30}"
# Globs, so a tunnel added later is covered without touching this file:
#   qdisc-<iface>.log   one per physical interface
#   <instance>/metrics.jsonl  one per tunnel
# The bare qdisc.log and metrics.jsonl are the pre-migration names.
cat > "${LOGROTATE_FILE}" << EOF
/var/log/spoof-tunnel/qdisc.log /var/log/spoof-tunnel/qdisc-*.log {
    daily
    rotate ${RETAIN}
    compress
    missingok
    notifempty
    copytruncate
}
/var/log/spoof-tunnel/metrics.jsonl /var/log/spoof-tunnel/*/metrics.jsonl {
    daily
    rotate ${RETAIN}
    compress
    missingok
    notifempty
    copytruncate
}
/var/log/spoof-tunnel/install.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
}
EOF

# ── journal tuning ───────────────────────────────────────────────────────────

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/spoof-tunnel.conf << EOF
[Journal]
SystemMaxUse=500M
MaxRetentionSec=30day
EOF

# ── enable and start ─────────────────────────────────────────────────────────

log "Reloading systemd..."
systemctl daemon-reload

if [ "${TOOLING_ONLY}" = "1" ]; then
    log "Tooling installed. No tunnel was created."
    echo ""
    echo "  Binary:   ${BIN_DST}"
    echo "  Template: ${TEMPLATE_UNIT_FILE}"
    echo ""
    echo "  Create a tunnel:  spoofctl create <name>"
    echo "  List tunnels:     spoofctl list"
    exit 0
fi

systemctl enable spoof-tunnel

if [ "${NO_START}" = "0" ]; then
    if systemctl is-active spoof-tunnel >/dev/null 2>&1; then
        log "Restarting spoof-tunnel..."
        systemctl restart spoof-tunnel
    else
        log "Starting spoof-tunnel..."
        systemctl start spoof-tunnel
    fi

    # Post-start health check
    sleep 3
    if systemctl is-active spoof-tunnel >/dev/null 2>&1; then
        log "Service started successfully."
        systemctl status spoof-tunnel --no-pager -l | tail -5
    else
        log "ERROR: service failed to start."
        journalctl -u spoof-tunnel -n 30 --no-pager >&2
        exit 1
    fi
else
    log "Service installed but not started (--no-start)."
fi

log "Installation complete."
echo ""
echo "  Binary:  ${BIN_DST}"
echo "  Config:  /etc/spoof-tunnel/config.yaml"
echo "  Service: systemctl status spoof-tunnel"
echo "  Logs:    journalctl -u spoof-tunnel -f"
echo "  Status:  ${LIB_DIR}/status.sh"
