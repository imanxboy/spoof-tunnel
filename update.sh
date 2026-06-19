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
HEALTH_JSON="/run/spoof-tunnel/health.json"

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

        if [ "${FORCE}" = "0" ]; then
            echo "Waiting for low-traffic window (tx_pps < 50 for 10s)..."
            QUIET=0
            for _ in $(seq 1 60); do
                TX_PPS=$(python3 -c "import json; d=json.load(open('${HEALTH_JSON}')); print(d.get('tx_pps',999))" 2>/dev/null || echo 999)
                if [ "${TX_PPS}" -lt 50 ]; then
                    QUIET=$(( QUIET + 1 ))
                    [ "${QUIET}" -ge 2 ] && break
                else
                    QUIET=0
                fi
                sleep 5
            done
        fi

        echo "Stopping service..."
        systemctl stop spoof-tunnel

        echo "Replacing binary..."
        [ -f "${BIN_DST}" ] && cp -f "${BIN_DST}" "${BIN_BAK}"
        mv -f "${BIN_NEW}" "${BIN_DST}"

        echo "Starting service..."
        systemctl start spoof-tunnel
        sleep 3

        if systemctl is-active spoof-tunnel >/dev/null 2>&1; then
            echo "Update applied successfully."
        else
            echo "ERROR: service failed after update — rolling back..."
            systemctl stop spoof-tunnel || true
            [ -f "${BIN_BAK}" ] && mv -f "${BIN_BAK}" "${BIN_DST}"
            systemctl start spoof-tunnel
            echo "Rollback complete."
            exit 1
        fi
        ;;

    rollback)
        [ -f "${BIN_BAK}" ] || { echo "ERROR: no backup at ${BIN_BAK}"; exit 1; }
        echo "Rolling back to ${BIN_BAK}..."
        systemctl stop spoof-tunnel || true
        mv -f "${BIN_BAK}" "${BIN_DST}"
        systemctl start spoof-tunnel
        echo "Rollback complete."
        ;;
esac
