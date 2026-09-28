#!/bin/bash
# spoof-tunnel public installer
# Usage: curl -fsSL https://raw.githubusercontent.com/imanxboy/spoof-tunnel/main/scripts/install.sh | sudo bash
#
# Environment overrides:
#   REPO_OWNER   GitHub org/user (default: imanxboy)
#   REPO_NAME    Repository name (default: spoof-tunnel)
#   INSTALL_TAG  Pin a specific release tag (default: latest)
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-imanxboy}"
REPO_NAME="${REPO_NAME:-spoof-tunnel}"
INSTALL_TAG="${INSTALL_TAG:-latest}"

GITHUB="https://github.com/${REPO_OWNER}/${REPO_NAME}"
API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
WORK_DIR="$(mktemp -d)"
CONF_DIR="/etc/spoof-tunnel"
CONF_YAML="${CONF_DIR}/config.yaml"

# ── cleanup on exit ──────────────────────────────────────────────────────────
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "  [spoof-tunnel] $*"; }
die()  { echo "  [ERROR] $*" >&2; exit 1; }
http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "Neither curl nor wget found. Install one and retry."
    fi
}

# ── pre-flight ───────────────────────────────────────────────────────────────
echo ""
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │          spoof-tunnel v6 Installer               │"
echo "  └──────────────────────────────────────────────────┘"
echo ""

if [ "$(id -u)" != "0" ]; then
    die "Must run as root. Try: curl ... | sudo bash"
fi

# OS detection
if   [ -f /etc/os-release ]; then source /etc/os-release; DISTRO="${ID:-unknown}"
elif [ -f /etc/debian_version ]; then DISTRO="debian"
elif [ -f /etc/redhat-release ]; then DISTRO="rhel"
else DISTRO="unknown"
fi

case "$DISTRO" in
    ubuntu|debian) PKG_MGR="apt" ;;
    centos|rhel|fedora|rocky|alma) PKG_MGR="yum" ;;
    *)
        log "Unknown distro '${DISTRO}'. Will attempt apt-based install."
        PKG_MGR="apt"
        ;;
esac

# ── install OS dependencies ──────────────────────────────────────────────────

log "Checking dependencies..."

install_deps_apt() {
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        gcc python3 iproute2 iptables \
        curl ca-certificates tar gzip 2>&1 | grep -v "^$" || true
}

install_deps_yum() {
    yum install -y -q \
        gcc python3 iproute iptables \
        curl ca-certificates tar gzip 2>&1 | grep -v "^$" || true
}

NEED_DEPS=0
for tool in gcc python3 ip iptables tc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        NEED_DEPS=1
        log "Missing: $tool"
    fi
done

if [ "${NEED_DEPS}" = "1" ]; then
    log "Installing missing packages..."
    if [ "${PKG_MGR}" = "apt" ]; then
        install_deps_apt
    else
        install_deps_yum
    fi
fi

for tool in gcc python3 ip iptables tc; do
    command -v "$tool" >/dev/null 2>&1 || die "Still missing: $tool — install it manually."
done

# ── download release ─────────────────────────────────────────────────────────

log "Fetching release info..."

if [ "${INSTALL_TAG}" = "latest" ]; then
    RELEASE_JSON=$(http_get "${API_BASE}/releases/latest")
    # Use python3 for JSON parsing (available after dep install above; avoids grep -P)
    TAG=$(echo "$RELEASE_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" \
        2>/dev/null || true)
    TARBALL_URL=$(echo "$RELEASE_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('tarball_url',''))" \
        2>/dev/null || true)
else
    TAG="${INSTALL_TAG}"
    TARBALL_URL="${GITHUB}/archive/refs/tags/${TAG}.tar.gz"
fi

if [ -z "$TAG" ]; then
    die "Could not determine release tag. Ensure a release has been published at:
       ${API_BASE}/releases/latest
  If no releases exist yet, create one via: git tag v6.3.1 && git push --tags"
fi
log "Installing version: ${TAG}"

log "Downloading source..."
http_get "${TARBALL_URL}" | tar xz -C "${WORK_DIR}" --strip-components=1

PKG_DIR="${WORK_DIR}"
[ -f "${PKG_DIR}/src/spoof_tunnel_v6.c" ] || \
    die "Source not found in release — unexpected archive layout."
[ -f "${PKG_DIR}/libexec/spoof-tunnel-prepare" ] || \
    die "libexec/spoof-tunnel-prepare not found in release — unexpected archive layout."
[ -f "${PKG_DIR}/libexec/spoof-tunnel-qdisc" ] || \
    die "libexec/spoof-tunnel-qdisc not found in release — unexpected archive layout."
[ -f "${PKG_DIR}/libexec/spoof-tunnel-forward" ] || \
    die "libexec/spoof-tunnel-forward not found in release — unexpected archive layout."

# ── build binary ─────────────────────────────────────────────────────────────

log "Compiling spoof-tunnel..."
bash "${PKG_DIR}/build.sh"

[ -f "${PKG_DIR}/bin/spoof-tunnel" ] || die "Build failed — no binary produced."
log "Build complete."

# ── run package installer ─────────────────────────────────────────────────────
#
# Installing only puts the tools on the host. It does not ask for addresses,
# write a tunnel config, or start anything — a freshly installed host has no
# tunnel at all. Tunnels are created afterwards with `spoofctl create`, which
# is where the operator enters the peer address and spoof IPs.
#
# A host that already has a tunnel from an earlier version keeps it: install.sh
# installs the single-tunnel layout only when /etc/spoof-tunnel/config.yaml
# already exists, and leaves the service alone here.

mkdir -p "${CONF_DIR}"

if [ -f "${CONF_YAML}" ]; then
    log "Existing tunnel found at ${CONF_YAML} — upgrading it in place."
    cp -f "${CONF_YAML}" "${PKG_DIR}/config.yaml"
    bash "${PKG_DIR}/install.sh" --no-start
    HAD_CONFIG=1
else
    log "Installing tools..."
    bash "${PKG_DIR}/install.sh" --tooling-only
    HAD_CONFIG=0
fi

# ── store version + update config ────────────────────────────────────────────

echo "${TAG}" > "${CONF_DIR}/VERSION"
cat > "${CONF_DIR}/update.conf" << EOF
REPO_URL=${GITHUB}
EOF

# ── install spoofctl ─────────────────────────────────────────────────────────

if [ -f "${PKG_DIR}/scripts/spoofctl" ]; then
    install -m 755 -o root -g root \
        "${PKG_DIR}/scripts/spoofctl" /usr/local/bin/spoofctl
    log "Installed: /usr/local/bin/spoofctl"
fi

# ── done ─────────────────────────────────────────────────────────────────────

echo ""
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │          Installation complete!                  │"
echo "  └──────────────────────────────────────────────────┘"
echo ""
echo "  Version:   ${TAG}"
if [ "${HAD_CONFIG}" = "1" ]; then
    echo "  Config:    ${CONF_YAML}"
    echo "  Service:   systemctl status spoof-tunnel"
    echo "  Logs:      journalctl -u spoof-tunnel -f"
    echo "  Manage:    spoofctl"
    echo ""
else
    echo ""
    echo "  No tunnel exists yet. Create one — it will ask for the peer"
    echo "  address, the spoof IPs and the ports:"
    echo ""
    echo "      spoofctl create <name>"
    echo ""
    echo "  Run this on BOTH machines. One end is the client (the front-end,"
    echo "  where users connect), the other is the server."
    echo ""
    echo "  Then:  spoofctl list     spoofctl status <name>"
    echo ""
fi
