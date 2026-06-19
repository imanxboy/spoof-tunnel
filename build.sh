#!/bin/bash
# Build spoof-tunnel-v6 binary from source.
# Output: bin/spoof-tunnel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/src/spoof_tunnel_v6.c"
OUT="${SCRIPT_DIR}/bin/spoof-tunnel"

mkdir -p "${SCRIPT_DIR}/bin"

CC="${CC:-gcc}"
CFLAGS="${CFLAGS:--O2 -mtune=generic}"

echo "Building ${OUT}..."
"${CC}" ${CFLAGS} \
    -pthread \
    -Wall -Wextra -Werror \
    -o "${OUT}" "${SRC}"

sha256sum "${OUT}"
echo "Build OK: ${OUT}"
