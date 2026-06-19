#!/usr/bin/env python3
"""
config-parse.py — translate config.yaml into /etc/spoof-tunnel/tunnel.env
and auto-detect hardware parameters.

Usage:
  config-parse.py [--validate] [--output PATH] config.yaml
"""
import sys, os, subprocess, socket, struct, fcntl, json, re

try:
    import yaml
except ImportError:
    # Minimal YAML subset parser (handles simple key: value and lists)
    class _yaml:
        @staticmethod
        def safe_load(f):
            return _yaml._parse(f.read())
        @staticmethod
        def _parse(text):
            lines = text.splitlines()
            return _yaml._parse_block(lines, 0, 0)[0]
        @staticmethod
        def _parse_block(lines, start, base_indent):
            result = {}
            i = start
            while i < len(lines):
                line = lines[i]
                stripped = line.lstrip()
                if not stripped or stripped.startswith('#'):
                    i += 1; continue
                indent = len(line) - len(stripped)
                if indent < base_indent:
                    break
                if ':' in stripped:
                    key, _, rest = stripped.partition(':')
                    key = key.strip()
                    rest = rest.strip()
                    if rest and not rest.startswith('#'):
                        rest = rest.split('#')[0].strip()
                        if rest.startswith('"') or rest.startswith("'"):
                            rest = rest.strip('"\'')
                        elif rest == 'true': rest = True
                        elif rest == 'false': rest = False
                        elif rest == 'null' or rest == '': rest = None
                        else:
                            try: rest = int(rest)
                            except ValueError:
                                try: rest = float(rest)
                                except ValueError: pass
                        result[key] = rest
                        i += 1
                    else:
                        # nested
                        sub, i = _yaml._parse_block(lines, i+1, indent+1)
                        # check if next lines are list items
                        if not sub:
                            lst = []
                            while i < len(lines):
                                l2 = lines[i]
                                s2 = l2.lstrip()
                                if not s2 or s2.startswith('#'):
                                    i += 1; continue
                                if len(l2)-len(s2) <= indent:
                                    break
                                if s2.startswith('- '):
                                    val = s2[2:].strip().split('#')[0].strip()
                                    if val == 'true': val = True
                                    elif val == 'false': val = False
                                    else:
                                        try: val = int(val)
                                        except ValueError:
                                            try: val = float(val)
                                            except ValueError: pass
                                    lst.append(val)
                                    i += 1
                                else:
                                    break
                            result[key] = lst if lst else sub
                        else:
                            result[key] = sub
                else:
                    i += 1
            return result, i
    yaml = _yaml()

# ── auto-detection helpers ──────────────────────────────────────────────────

def default_iface():
    try:
        out = subprocess.check_output(['ip', 'route', 'show', 'default'],
                                      stderr=subprocess.DEVNULL).decode()
        for tok in out.split():
            if tok == 'dev':
                return out.split()[out.split().index('dev') + 1]
    except Exception:
        pass
    return 'eth0'

def iface_mtu(iface):
    try:
        with open(f'/sys/class/net/{iface}/mtu') as f:
            return int(f.read().strip())
    except Exception:
        return 1500

def cpu_count():
    try:
        return int(subprocess.check_output(['nproc'], stderr=subprocess.DEVNULL))
    except Exception:
        return 2

def auto_cpu(n):
    if n >= 4:   return 1, 2
    if n == 2:   return 0, 1
    return 0, 0

def compute_flow_limit(rate_mbps):
    fl = max(1000, min(10000, int(rate_mbps) * 9))
    return fl

def validate_ip(s, field):
    try:
        socket.inet_aton(s)
        return s
    except Exception:
        die(f"invalid IP in {field}: {s!r}")

def get_local_ips():
    try:
        out = subprocess.check_output(['ip', '-4', 'addr', 'show'],
                                      stderr=subprocess.DEVNULL, text=True)
        addrs = []
        for line in out.splitlines():
            line = line.strip()
            if line.startswith('inet '):
                addrs.append(line.split()[1].split('/')[0])
        return addrs
    except Exception:
        return []

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

# ── main ───────────────────────────────────────────────────────────────────

def main():
    validate_only = '--validate' in sys.argv
    output_path = None
    args = [a for a in sys.argv[1:] if not a.startswith('--')]

    for i, a in enumerate(sys.argv[1:]):
        if a == '--output' and i+2 < len(sys.argv):
            output_path = sys.argv[i+2]

    if not args:
        print(f"usage: {sys.argv[0]} [--validate] [--output PATH] config.yaml",
              file=sys.stderr)
        sys.exit(1)

    cfg_path = args[-1]
    try:
        with open(cfg_path) as f:
            cfg = yaml.safe_load(f)
    except Exception as e:
        die(f"cannot read {cfg_path}: {e}")

    # ── section extraction ──────────────────────────────────────────────────
    tun  = cfg.get('tunnel', {}) or {}
    spf  = cfg.get('spoof',  {}) or {}
    net  = cfg.get('network',{}) or {}
    perf = cfg.get('performance', {}) or {}
    mon  = cfg.get('monitoring', {}) or {}
    adv  = cfg.get('advanced', {}) or {}
    fwd  = cfg.get('forwarding', {}) or {}

    # ── required fields ─────────────────────────────────────────────────────
    role = tun.get('role', '')
    if role not in ('server', 'client'):
        die("tunnel.role must be 'server' or 'client'")

    outer = tun.get('outer', 'udp')
    if outer not in ('udp', 'tcp'):
        die("tunnel.outer must be 'udp' or 'tcp'")

    peer_address = str(tun.get('peer_address', ''))
    if not peer_address:
        die("tunnel.peer_address is required")
    validate_ip(peer_address, 'tunnel.peer_address')
    local_ips = get_local_ips()
    if peer_address in local_ips:
        die(f"tunnel.peer_address ({peer_address}) is a local interface IP on this machine. "
            f"Set it to the OTHER server's public IP address.")

    listen_port = int(tun.get('listen_port', 2080))
    peer_port   = int(tun.get('peer_port',   2080))

    # ── spoof IPs ───────────────────────────────────────────────────────────
    spoof_list = spf.get('addresses', []) or []
    if outer == 'udp' and not spoof_list:
        die("spoof.addresses is required for UDP mode")
    for ip in spoof_list:
        validate_ip(str(ip), 'spoof.addresses')
    spoof_str = ','.join(str(x) for x in spoof_list)

    failover_loss = float(spf.get('loss_threshold', 0.05))
    failover_ivs  = int(spf.get('failover_intervals', 3))

    # ── network auto-detect ─────────────────────────────────────────────────
    iface = str(net.get('interface', '') or '')
    if not iface:
        iface = default_iface()
        print(f"# auto-detected interface: {iface}", file=sys.stderr)

    tun_name = str(net.get('tun_name', 'tun0') or 'tun0')

    local_tun = str(net.get('local_tun_ip', '') or '')
    peer_tun  = str(net.get('peer_tun_ip',  '') or '')
    if not local_tun or not peer_tun:
        if role == 'server':
            local_tun = '10.100.100.1'
            peer_tun  = '10.100.100.2'
        else:
            local_tun = '10.100.100.2'
            peer_tun  = '10.100.100.1'
        print(f"# auto-assigned TUN IPs: local={local_tun} peer={peer_tun}",
              file=sys.stderr)

    mtu_raw = net.get('mtu', 0) or 0
    if mtu_raw:
        mtu = int(mtu_raw)
    else:
        phys_mtu = iface_mtu(iface)
        mtu = min(1440, phys_mtu - 58)
        print(f"# auto-computed MTU: {mtu} (iface MTU {phys_mtu} - 58)",
              file=sys.stderr)

    # ── performance auto-detect ─────────────────────────────────────────────
    rate_mbps = int(perf.get('rate_mbps', 0) or 0)
    if outer == 'udp' and not rate_mbps:
        die("performance.rate_mbps is required for UDP mode")

    flow_limit_raw = perf.get('flow_limit', 0) or 0
    if flow_limit_raw:
        flow_limit = int(flow_limit_raw)
    else:
        flow_limit = compute_flow_limit(rate_mbps) if rate_mbps else 1000
        print(f"# auto-computed flow_limit: {flow_limit}", file=sys.stderr)

    batch_size    = int(perf.get('batch_size', 16) or 16)
    rx_ring_blk   = int(perf.get('rx_ring_blocks', 64) or 64)

    tx_cpu_raw = perf.get('tx_cpu', -1)
    rx_cpu_raw = perf.get('rx_cpu', -1)
    if tx_cpu_raw is None or int(tx_cpu_raw) < 0 or \
       rx_cpu_raw is None or int(rx_cpu_raw) < 0:
        ncpu = cpu_count()
        tx_cpu, rx_cpu = auto_cpu(ncpu)
        print(f"# auto-assigned CPUs: tx={tx_cpu} rx={rx_cpu} (nproc={ncpu})",
              file=sys.stderr)
    else:
        tx_cpu = int(tx_cpu_raw)
        rx_cpu = int(rx_cpu_raw)

    # ── monitoring ──────────────────────────────────────────────────────────
    metric_interval  = int(mon.get('metric_interval', 5) or 5)
    json_metrics     = bool(mon.get('json_metrics', True))
    prom_enabled     = bool(mon.get('prometheus_enabled', False))
    prom_dir         = str(mon.get('prometheus_dir',
                                   '/var/lib/prometheus/node-exporter') or '')
    qdisc_mon_int    = int(mon.get('qdisc_monitor_interval', 60) or 60)
    log_retention    = int(mon.get('log_retention_days', 30) or 30)

    # ── advanced ────────────────────────────────────────────────────────────
    sysctl_tune  = bool(adv.get('sysctl_tune', True))
    watchdog_sec = int(adv.get('watchdog_sec', 30) or 30)

    # ── forwarding ports (client only) ──────────────────────────────────────
    # Accepts a list of port numbers. Both TCP and UDP are forwarded for each.
    fwd_ports_raw = fwd.get('ports', []) or []
    fwd_ports = []
    for p in fwd_ports_raw:
        try:
            port = int(p)
        except (TypeError, ValueError):
            die(f"forwarding.ports: '{p}' is not a valid port number")
        if not (1 <= port <= 65535):
            die(f"forwarding.ports: port {port} out of range (1–65535)")
        if port == listen_port:
            print(f"# WARNING: forwarding port {port} conflicts with"
                  f" tunnel listen_port {listen_port}", file=sys.stderr)
        fwd_ports.append(str(port))
    fwd_str = ','.join(fwd_ports)

    if validate_only:
        print("config OK")
        return

    # ── emit EnvironmentFile ────────────────────────────────────────────────
    lines = [
        f'MODE={role}',
        f'OUTER={outer}',
        f'IFACE={iface}',
        f'TUN_NAME={tun_name}',
        f'PEER_IP={peer_address}',
        f'LOCAL_TUN={local_tun}',
        f'PEER_TUN={peer_tun}',
        f'LISTEN_PORT={listen_port}',
        f'PEER_PORT={peer_port}',
        f'MTU={mtu}',
        f'TX_CPU={tx_cpu}',
        f'RX_CPU={rx_cpu}',
        f'RATE_MBPS={rate_mbps}',
        f'FLOW_LIMIT={flow_limit}',
        f'BATCH_SIZE={batch_size}',
        f'RX_BLOCK_NR={rx_ring_blk}',
        f'FAILOVER_LOSS={failover_loss}',
        f'FAILOVER_INTERVALS={failover_ivs}',
        f'METRIC_INTERVAL={metric_interval}',
        f'JSON_METRICS={"true" if json_metrics else "false"}',
        f'WATCHDOG_SEC={watchdog_sec}',
        f'SYSCTL_TUNE={"true" if sysctl_tune else "false"}',
        f'PROM_ENABLED={"true" if prom_enabled else "false"}',
        f'PROM_DIR={prom_dir}',
        f'QDISC_MON_INTERVAL={qdisc_mon_int}',
        f'LOG_RETENTION_DAYS={log_retention}',
    ]
    if spoof_str:
        lines.append(f'SPOOF_IPS={spoof_str}')
    lines.append(f'FORWARD_PORTS={fwd_str}')

    output = '\n'.join(lines) + '\n'

    if output_path:
        with open(output_path, 'w') as f:
            f.write(output)
    else:
        print(output, end='')

if __name__ == '__main__':
    main()
