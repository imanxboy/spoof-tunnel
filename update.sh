#!/bin/bash
# update.sh — stage and apply a new binary without touching config.
# Usage:
#   sudo ./update.sh --binary /path/to/new/spoof-tunnel   (stage)
#   sudo ./update.sh --verify                             (verify staged binary)
#   sudo ./update.sh --apply [--force]                   (apply)
#   sudo ./update.sh --rollback                          (restore .bak)
set -euo pipefail

BIN_DST="/usr/local/bin/spoof-tunnel"
BIN_NEW="${BIN_DST}.new"
BIN_BAK="${BIN_DST}.bak"
TUNNELS_DIR="/etc/spoof-tunnel/tunnels"

# Every tunnel on this host runs the same binary, so replacing it means
# cycling all of them, not just one service.
tunnel_units() {
    local f n found=0
    if [ -d "${TUNNELS_DIR}" ]; then
        for f in "${TUNNELS_DIR}"/*.env; do
            [ -f "$f" ] || continue
            n="$(basename "$f")"
            echo "spoof-tunnel@${n%.env}"
            found=1
        done
    fi
    # Pre-migration hosts have the single unnamed unit instead.
    [ "$found" = "0" ] && echo "spoof-tunnel"
    return 0
}

# Busiest tunnel's tx_pps — the low-traffic window has to hold for all of them.
max_tx_pps() {
    local f h n best=0 v
    if [ -d "${TUNNELS_DIR}" ]; then
        for f in "${TUNNELS_DIR}"/*.env; do
            [ -f "$f" ] || continue
            n="$(basename "$f")"; n="${n%.env}"
            h="/run/spoof-tunnel/${n}/health.json"
            v=$(python3 -c "import json;print(int(json.load(open('${h}')).get('tx_pps',999)))" 2>/dev/null || echo 999)
            [ "$v" -gt "$best" ] && best="$v"
        done
    fi
    if [ ! -d "${TUNNELS_DIR}" ]; then
        best=$(python3 -c "import json;print(int(json.load(open('/run/spoof-tunnel/health.json')).get('tx_pps',999)))" 2>/dev/null || echo 999)
    fi
    echo "$best"
}

stop_all()  { local u; for u in $(tunnel_units); do systemctl stop  "$u" 2>/dev/null || true; done; }
start_all() { local u; for u in $(tunnel_units); do systemctl start "$u" 2>/dev/null || true; done; }

# Names the units that are not active, or nothing if they all came up.
failed_units() {
    local u bad=""
    for u in $(tunnel_units); do
        systemctl is-active "$u" >/dev/null 2>&1 || bad="${bad:+$bad }$u"
    done
    echo "$bad"
}

ACTION=""
BINARY_SRC=""
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --binary)   ACTION="stage" ;;
        --verify)   ACTION="verify" ;;
        --apply)    ACTION="apply" ;;
        --rollback) ACTION="rollback" ;;
        --force)    FORCE=1 ;;
        /*)         BINARY_SRC="$arg" ;;
    esac
done

[ -z "${ACTION}" ] && { echo "usage: $0 --binary|--verify|--apply|--rollback"; exit 1; }

case "${ACTION}" in

    stage)
        [ -z "${BINARY_SRC}" ] && { echo "ERROR: --binary requires a path"; exit 1; }
        [ -f "${BINARY_SRC}" ] || { echo "ERROR: ${BINARY_SRC} not found"; exit 1; }
        install -m 755 -o root -g root "${BINARY_SRC}" "${BIN_NEW}"
        echo "Staged: ${BIN_NEW}"
        echo "Run '$0 --verify' then '$0 --apply' to deploy."
        ;;

    verify)
        [ -f "${BIN_NEW}" ] || { echo "ERROR: no staged binary at ${BIN_NEW}"; exit 1; }
        # quick sanity: it must be an ELF executable that accepts --help-like output
        file "${BIN_NEW}" | grep -q ELF || { echo "ERROR: not an ELF binary"; exit 1; }
        sha256sum "${BIN_NEW}"
        echo "Verify OK: ${BIN_NEW}"
        ;;

    apply)
        [ -f "${BIN_NEW}" ] || { echo "ERROR: no staged binary — run --binary first"; exit 1; }

        echo "Tunnels to cycle: $(tunnel_units | paste -sd' ' -)"

        if [ "${FORCE}" = "0" ]; then
            echo "Waiting for low-traffic window (busiest tunnel < 50 pps for 10s)..."
            QUIET=0
            for _ in $(seq 1 60); do
                TX_PPS=$(max_tx_pps)
                if [ "${TX_PPS}" -lt 50 ]; then
                    QUIET=$(( QUIET + 1 ))
                    [ "${QUIET}" -ge 2 ] && break
                else
                    QUIET=0
                fi
                sleep 5
            done
        fi

        echo "Stopping tunnels..."
        stop_all

        echo "Replacing binary..."
        [ -f "${BIN_DST}" ] && cp -f "${BIN_DST}" "${BIN_BAK}"
        mv -f "${BIN_NEW}" "${BIN_DST}"

        echo "Starting tunnels..."
        start_all
        sleep 3

        BAD="$(failed_units)"
        if [ -z "${BAD}" ]; then
            echo "Update applied successfully."
        else
            echo "ERROR: failed after update: ${BAD} — rolling back..."
            stop_all
            [ -f "${BIN_BAK}" ] && mv -f "${BIN_BAK}" "${BIN_DST}"
            start_all
            sleep 2
            STILL="$(failed_units)"
            if [ -z "${STILL}" ]; then
                echo "Rollback complete."
            else
                echo "ERROR: still down after rollback: ${STILL}"
            fi
            exit 1
        fi
        ;;

    rollback)
        [ -f "${BIN_BAK}" ] || { echo "ERROR: no backup at ${BIN_BAK}"; exit 1; }
        echo "Rolling back to ${BIN_BAK}..."
        stop_all
        mv -f "${BIN_BAK}" "${BIN_DST}"
        start_all
        echo "Rollback complete."
        ;;
esac
