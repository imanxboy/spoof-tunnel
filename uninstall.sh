#!/bin/bash
# uninstall.sh — remove spoof-tunnel cleanly.
# Config and logs are preserved unless --purge is passed.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "ERROR: must run as root"; exit 1; }

PURGE=0
for arg in "$@"; do [ "$arg" = "--purge" ] && PURGE=1; done

echo "Stopping and disabling service..."
systemctl stop spoof-tunnel 2>/dev/null || true
systemctl disable spoof-tunnel 2>/dev/null || true

# Remove iptables DROP rule if it exists
if [ -f /etc/spoof-tunnel/tunnel.env ]; then
    source /etc/spoof-tunnel/tunnel.env 2>/dev/null || true
    if [ "${OUTER:-udp}" = "udp" ] && [ -n "${LISTEN_PORT:-}" ]; then
        iptables -D INPUT -p udp --dport "${LISTEN_PORT}" -j DROP 2>/dev/null || true
    fi
fi

echo "Removing files..."
rm -f /usr/local/bin/spoof-tunnel \
      /usr/local/bin/spoof-tunnel.bak \
      /usr/local/bin/spoof-tunnel.new \
      /etc/systemd/system/spoof-tunnel.service \
      /etc/systemd/system/spoof-tunnel-prom.service \
      /etc/systemd/system/spoof-tunnel-prom.timer \
      /usr/local/libexec/spoof-tunnel-prepare \
      /usr/local/libexec/spoof-tunnel-qdisc \
      /etc/sysctl.d/99-spoof-tunnel.conf \
      /etc/cron.d/spoof-tunnel \
      /etc/logrotate.d/spoof-tunnel \
      /etc/systemd/journald.conf.d/spoof-tunnel.conf
rm -rf /usr/local/lib/spoof-tunnel \
       /run/spoof-tunnel

if [ "${PURGE}" = "1" ]; then
    echo "Purging config and logs..."
    rm -rf /etc/spoof-tunnel /var/log/spoof-tunnel
else
    echo "Config preserved at /etc/spoof-tunnel/"
    echo "Logs preserved at /var/log/spoof-tunnel/"
    echo "(use --purge to delete)"
fi

systemctl daemon-reload
echo "Uninstall complete."
