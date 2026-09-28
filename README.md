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
spoofctl forward list        # configured ports + live DNAT/MASQUERADE state
spoofctl forward add 8443    # add a port, keeping the existing ones
spoofctl forward del 8443    # remove one port ('all' removes every rule)
spoofctl forward replace 443,80   # replace the whole list at once
spoofctl forward apply       # re-install rules after a manual iptables flush
```

`add` and `del` take a comma-separated list (`forward add 8443,2053`) and
change iptables immediately — no service restart. Every change is written to
both `tunnel.env` and `config.yaml`, so it survives a reinstall. Run any
subcommand with no argument to be prompted for the ports.

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
| `list` | Show every configured tunnel, numbered |
| `spoof-ips` | Update the spoof IP list and restart |
| `forward list\|add\|del\|replace\|apply` | Manage forwarded ports (client only) |
| `create [NAME]` | Set up a new tunnel with the wizard |
| `delete [NAME]` | Remove one tunnel, keeping the tooling and the others |
| `migrate [NAME]` | Convert a single-tunnel host to the named layout |
| `update` | Download and install the latest release (auto-rollback on failure) |
| `rollback` | Restore a previous snapshot |
| `uninstall` | Remove everything from this system |

`forward-rules` is kept as an alias for `forward replace`.

## Multiple tunnels on one host

One host can terminate several tunnels at once — an Iran box linked to several
different foreign servers over the same NIC. Each tunnel is a named instance
with its own config, systemd unit, TUN device and forwarding rules:

| | |
|---|---|
| config | `/etc/spoof-tunnel/tunnels/<name>.yaml` |
| env | `/etc/spoof-tunnel/tunnels/<name>.env` |
| unit | `spoof-tunnel@<name>.service` |
| runtime | `/run/spoof-tunnel/<name>/health.json` |
| metrics | `/var/log/spoof-tunnel/<name>/metrics.jsonl` |

```bash
spoofctl create de1            # add a tunnel
spoofctl list                  # numbered table of all of them
spoofctl status de1            # or: spoofctl status -t de1
spoofctl forward add 8443 -t de1
spoofctl delete de1            # only de1; the others keep running
```

Commands that act on one tunnel take its name positionally or as `-t NAME`.
With a single tunnel configured the name is optional. With several, leaving it
out opens a numbered picker:

```
  Which tunnel?
   #  NAME         ROLE    PEER                     TUN     SERVICE  FORWARDED
   1  de1          client  198.51.100.7:2081        tun1    active   8443
   2  main         client  203.0.113.9:2080         tun0    active   443,80
  Choice [1-2]:
```

### What each tunnel must not share

The installer rejects a config that reuses another tunnel's `tun_name`,
`listen_port`, TUN IP pair, or a forwarded port. That guarantee is what keeps
the tunnels independent: DNAT rules are keyed by port and FORWARD/MASQUERADE
rules by TUN device, so deleting one tunnel cannot disturb another. The wizard
offers free values by default, so you can accept every default and get a config
that installs.

### The one thing they do share

`fq` is a property of the physical NIC, not of a tunnel. When several tunnels
run over the same interface, the qdisc hook applies the **highest**
`flow_limit` among them rather than whichever tunnel started last, so the
result does not depend on start order. `spoofctl status` labels the queue
figures accordingly, and the qdisc log is per interface
(`/var/log/spoof-tunnel/qdisc-<iface>.log`), not per tunnel.

### Migrating an existing single-tunnel host

Hosts installed before multi-tunnel support keep working untouched —
`spoofctl update` does not convert them, and the tunnel stays on the plain
`spoof-tunnel.service`. Convert it when you choose:

```bash
spoofctl migrate        # names it 'main' by default
```

`migrate` snapshots the config, env and unit first, then switches to
`spoof-tunnel@<name>`. The tunnel restarts once. If it does not come back up,
everything is restored and the original unit is started again, so a failed
migration leaves the tunnel running. The old unit is kept as
`spoof-tunnel.service.pre-migrate`.

`spoofctl create` refuses to run on an unmigrated host and points here, so the
two layouts never coexist.

### Deleting a tunnel

`spoofctl delete` tears down the tunnel configured on this host without
uninstalling anything:

- stops and disables the service (and the Prometheus timer, if enabled)
- removes every iptables rule the tunnel owns — the port-forwarding DNAT,
  FORWARD and MASQUERADE rules, and the `INPUT ... -j DROP` rule that
  `spoof-tunnel-prepare` installs on the outer UDP port
- deletes the TUN device
- backs up `config.yaml` and `tunnel.env` to
  `/var/backups/spoof-tunnel/deleted-<timestamp>/`, then removes them

The binary, `spoofctl`, the libexec hooks and the logs stay in place, so
`spoofctl create` can build a new tunnel straight away. Use
`spoofctl uninstall` to remove the tooling itself.

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
