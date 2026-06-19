# spoof-tunnel

A high-performance IP-spoofing UDP tunnel that carries overlay proxy traffic
(Xray, VLESS, VMess, etc.) between a front-end node and a back-end node while
making the outer packets appear to originate from a different IP address.

Built in C using Linux `AF_PACKET` raw sockets, zero-copy `TPACKET_V3` ring
buffers, and a kernel TUN device. Manages itself with `systemd` (sd_notify,
watchdog, journald) and ships with a full management CLI (`spoofctl`).

---

## Architecture

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                          spoof-tunnel                                │
  │                                                                      │
  │  Users (e.g. Iran)          CLIENT node              SERVER node     │
  │  ─────────────────          ──────────────           ────────────    │
  │  browser / app              tun0: 10.x.x.2           tun0: 10.x.x.1 │
  │      │                       │                         │             │
  │      │ TLS/TCP:443  ─────►  iptables DNAT             │             │
  │      │                       │ → tun0                  │             │
  │      │                       │                         │             │
  │      │               ┌───────┴───────────────┐         │             │
  │      │               │  spoof-tunnel process  │         │             │
  │      │               │  TUN → AF_PACKET TX    │──────►  │             │
  │      │               │  outer src: spoof IP   │         │             │
  │      │               │  outer dst: peer IP    │  UDP    │             │
  │      │               │  AF_PACKET RX → TUN    │◄────────┤             │
  │      │               └───────────────────────-┘         │             │
  │      │                                         spoof-tunnel process   │
  │      │                                         TUN → Xray:443         │
  │      └──────────────────────────────────────────────────►             │
  │                                               Xray/VLESS → internet   │
  └──────────────────────────────────────────────────────────────────────┘
```

**How it works:**

1. Users connect to the CLIENT node on the overlay port (e.g. 443).
2. An `iptables` DNAT rule redirects that traffic into the `tun0` interface.
3. `spoof-tunnel` reads packets from `tun0`, wraps them in a raw UDP frame with
   a **spoofed source IP**, and sends them via `AF_PACKET` directly on the wire.
4. The SERVER node receives the raw frame via its own `AF_PACKET` socket, strips
   the outer header, writes the inner packet to its `tun0`, and the overlay
   service (Xray) picks it up as if the user were connecting locally.
5. Return traffic follows the same path in reverse.

The spoofed source IP makes the outer UDP traffic appear to come from a CDN,
relay, or any other IP — obscuring the true tunnel endpoint.

---

## Requirements

- Linux kernel ≥ 4.14 (for `TPACKET_V3`)
- `gcc`, `python3`, `iproute2`, `iptables`, `systemd`
- Root access on both nodes
- UDP traffic open between the two nodes on the tunnel port (default: 2080)

---

## Quick Start

### One-command install (both nodes)

```bash
curl -fsSL https://raw.githubusercontent.com/imanxboy/spoof-tunnel/main/scripts/install.sh \
    | sudo bash
```

The installer:
1. Detects your OS and installs dependencies (`gcc`, `python3`, etc.)
2. Downloads and compiles the latest release
3. Launches the **interactive setup wizard** if no config exists
4. Installs the service and starts it

Run on the **server** first, then on the **client**.

### Manual install

```bash
git clone https://github.com/imanxboy/spoof-tunnel
cd spoof-tunnel
sudo bash scripts/setup-wizard.sh   # creates config.yaml
sudo bash install.sh                # builds, installs, starts service
```

---

## Configuration

The wizard writes `config.yaml`. The key fields:

```yaml
tunnel:
  role: client        # "client" or "server"
  peer_address: 1.2.3.4

spoof:
  addresses:
    - ip-spoof-example   # IPs to spoof as outer source (client mode)

network:
  interface: eth0
  tun_name: tun0
  local_tun_ip: 10.100.100.2
  peer_tun_ip:  10.100.100.1

performance:
  rate_mbps: 1000

# CLIENT only — ports to forward through the tunnel to the server
forwarding:
  ports:
    - 443
    # - 80
    # - 2053
```

See [`config.yaml.example`](config.yaml.example) for all options with comments.

After editing config.yaml, apply with:

```bash
sudo bash install.sh --config-only   # regenerate tunnel.env (does NOT restart)
sudo systemctl restart spoof-tunnel  # then restart manually
# or use the combined edit+restart:
spoofctl edit-config
```

---

## Port Forwarding (Client Node)

On the **client** node, incoming user connections must be forwarded through the
tunnel to the proxy service running on the server. The setup wizard configures
this automatically. You can also set it in `config.yaml`:

```yaml
forwarding:
  ports:
    - 443    # Xray/VLESS
    - 80     # optional
    - 2053   # DNS-over-HTTPS alternative
```

For each listed port N, the installer creates **both TCP and UDP** rules:

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.100.100.1:443
iptables -t nat -A PREROUTING -p udp --dport 443 -j DNAT --to-destination 10.100.100.1:443
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
```

**Packet path:**
```
User → client eth0 → PREROUTING DNAT → FORWARD chain → POSTROUTING MASQUERADE
     → tun0 → spoof-tunnel → server tun0 → Xray:443
```

The MASQUERADE rule is critical: it replaces the user's real source IP with the
client's TUN IP (`10.100.100.2`) so the server routes replies back through the
tunnel, not directly to the user via the internet. `conntrack` automatically
reverses both DNAT and MASQUERADE for reply packets.

Rules are installed by `ExecStartPost` on every service start and survive
reboots. They are removed cleanly during uninstall.

**Setup wizard prompt (client nodes):**
```
  Step 9 of 9 — Port Forwarding

  Enable port forwarding? [Y/n]: y
  Ports to forward [443]: 443,80
```

**Manage after install:**
```bash
spoofctl forward-rules   # interactive: update port list and re-apply rules
spoofctl status          # shows forwarded ports + live DNAT/MASQUERADE counts
```

**spoofctl status output (client):**
```
  Forwarded ports  → 10.100.100.1 (TCP+UDP each):
    :443 → 10.100.100.1:443
    :80  → 10.100.100.1:80
  NAT state:       2 DNAT, 1 MASQUERADE, 2 FORWARD ACCEPT
```

**Server node:** no forwarding configuration needed. Xray listens directly
on the server's TUN IP (`10.100.100.1`). The `forwarding` section has no
effect on server nodes.

---

## Management (`spoofctl`)

```
spoofctl [command]
```

| Command | Description |
|---------|-------------|
| `status` | Show service state, traffic counters, forwarded ports, NAT state |
| `start` | Start the service |
| `stop` | Stop the service |
| `restart` | Restart the service |
| `edit-config` | Open `config.yaml` in `$EDITOR` and optionally restart |
| `spoof-ips` | Update the spoof IP list and restart |
| `forward-rules` | Update forwarded port list and re-apply iptables rules (client only) |
| `update` | Download and install the latest release (auto-rollback on failure) |
| `rollback` | Restore a previous snapshot |
| `uninstall` | Remove everything from this system |

With no arguments, `spoofctl` opens an interactive numbered menu.

---

## Upgrade

```bash
spoofctl update
```

or:

```bash
sudo INSTALL_TAG=v6.1.0 bash scripts/install.sh
```

---

## Monitoring

```bash
journalctl -u spoof-tunnel -f          # live logs
cat /run/spoof-tunnel/health.json      # JSON metrics (tx_pps, rx_pps, loss_pct)
/usr/local/lib/spoof-tunnel/status.sh  # human-readable status
```

Health JSON is written every `metric_interval` seconds (default: 5s). The
service watchdog uses it to detect stalls (default: 30s).

---

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for common issues.

Quick checks:

```bash
spoofctl status                        # service state + metrics
journalctl -u spoof-tunnel -n 50       # recent logs
ping <peer-tun-ip>                     # test tunnel connectivity
```

---

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — packet flow, wire protocol, and component design
- [`docs/spoofing.md`](docs/spoofing.md) — how IP spoofing works in this context
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — common issues and solutions
- [`docs/faq.md`](docs/faq.md) — frequently asked questions

---

## License

MIT — see [LICENSE](LICENSE).
