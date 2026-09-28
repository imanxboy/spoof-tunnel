#!/bin/bash
# uninstall.sh — remove spoof-tunnel cleanly, including every configured tunnel.
# Config and logs are preserved unless --purge is passed.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "ERROR: must run as root"; exit 1; }

PURGE=0
for arg in "$@"; do [ "$arg" = "--purge" ] && PURGE=1; done

TUNNELS_DIR="/etc/spoof-tunnel/tunnels"
LEGACY_ENV="/etc/spoof-tunnel/tunnel.env"
LIBEXEC_DIR="/usr/local/libexec"
FORWARD_HOOK="${LIBEXEC_DIR}/spoof-tunnel-forward"

# Values may be quoted (EXTRA_ARGS always is), so strip a surrounding pair.
env_get() {
    local v
    [ -f "$1" ] || return 0
    v="$(sed -n "s/^${2}=//p" "$1" | tail -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# Tear one tunnel down completely: stop it, then remove every rule and device
# it owns. This has to happen before the env files are deleted, because that
# is where the port and TUN device names come from.
teardown() {
    local unit="$1" env_file="$2" inst="$3" port tun

    echo "  Stopping ${unit}..."
    systemctl stop    "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true

    [ -f "$env_file" ] || return 0

    if [ -x "$FORWARD_HOOK" ]; then
        "$FORWARD_HOOK" --remove $inst 2>/dev/null || true
    fi

    # The INPUT DROP rule installed by spoof-tunnel-prepare for the outer UDP
    # port. Nothing else removes it, so the port would stay black-holed.
    port="$(env_get "$env_file" LISTEN_PORT)"
    if [ "$(env_get "$env_file" OUTER)" != "tcp" ] && [ -n "$port" ]; then
        while iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do
            iptables -D INPUT -p udp --dport "$port" -j DROP
        done
    fi

    # A killed process leaves its TUN device behind.
    tun="$(env_get "$env_file" TUN_NAME)"
    if [ -n "$tun" ] && ip link show "$tun" >/dev/null 2>&1; then
        ip link set "$tun" down 2>/dev/null || true
        ip link delete "$tun" 2>/dev/null || true
        echo "    removed TUN device ${tun}"
    fi
}

# Every named tunnel
if [ -d "$TUNNELS_DIR" ]; then
    for env_file in "${TUNNELS_DIR}"/*.env; do
        [ -f "$env_file" ] || continue
        name="$(basename "$env_file")"; name="${name%.env}"
        teardown "spoof-tunnel@${name}" "$env_file" "$name"
        rm -rf "/etc/systemd/system/spoof-tunnel@${name}.service.d"
    done
fi

# The pre-migration single tunnel, if this host still has one
if [ -f "$LEGACY_ENV" ] || [ -f /etc/systemd/system/spoof-tunnel.service ]; then
    teardown "spoof-tunnel" "$LEGACY_ENV" ""
fi

systemctl stop    spoof-tunnel-prom.timer 2>/dev/null || true
systemctl disable spoof-tunnel-prom.timer 2>/dev/null || true

echo "Removing files..."
rm -f /usr/local/bin/spoof-tunnel \
      /usr/local/bin/spoof-tunnel.bak \
      /usr/local/bin/spoof-tunnel.new \
      /usr/local/bin/spoofctl \
      /etc/systemd/system/spoof-tunnel.service \
      /etc/systemd/system/spoof-tunnel.service.pre-migrate \
      /etc/systemd/system/spoof-tunnel@.service \
      /etc/systemd/system/spoof-tunnel-prom.service \
      /etc/systemd/system/spoof-tunnel-prom.timer \
      "${LIBEXEC_DIR}/spoof-tunnel-prepare" \
      "${LIBEXEC_DIR}/spoof-tunnel-qdisc" \
      "${FORWARD_HOOK}" \
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
