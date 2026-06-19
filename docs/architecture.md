# Architecture

## Overview

spoof-tunnel is a point-to-point Layer 3 IP tunnel that wraps inner IP packets
inside raw UDP frames with a spoofed source IP address. It consists of one
process running on each node (client and server), each operating at the Linux
`AF_PACKET` layer to bypass the kernel network stack for the outer transport.

---

## Packet Flow (client → server)

```
  User application (TLS/TCP)
       │
       ▼
  [CLIENT node — public IP: 1.2.3.4]
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  NIC (eth0) ──► iptables DNAT                               │
  │                    :443 → 10.100.100.1:443                  │
  │                             │                               │
  │                             ▼                               │
  │                         tun0 device                         │
  │                             │                               │
  │                      spoof-tunnel TX thread                 │
  │                             │                               │
  │  read(tun_fd) ─────────────►│                               │
  │                             │  inner IP packet              │
  │                    build outer frame:                       │
  │                      Eth: src=client_mac, dst=gw_mac        │
  │                      IP:  src=SPOOF_IP, dst=server_pub_IP   │
  │                      UDP: dport=2080                        │
  │                      tun_hdr: {ver=6, seq, ts_ns}           │
  │                             │                               │
  │  sendmmsg(AF_PACKET) ───────►│  raw frame on wire           │
  │                                                             │
  └──────────────────────────────────────────────────────────────┘
       │
       │ UDP frame, outer src IP = SPOOF_IP (not 1.2.3.4)
       ▼
  [SERVER node — public IP: 5.6.7.8]
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  NIC (ens3) ──► AF_PACKET TPACKET_V3 RX ring               │
  │                    (iptables DROP on :2080 blocks kernel)   │
  │                             │                               │
  │                      spoof-tunnel RX thread                 │
  │                             │                               │
  │                    strip outer 58 bytes                     │
  │                    validate tun_hdr version                 │
  │                    seq-number loss tracking                 │
  │                             │                               │
  │  write(tun_fd) ─────────────►                               │
  │                             │                               │
  │                         tun0 device                         │
  │                             │                               │
  │                    Xray / VLESS (port 443)                  │
  │                    terminates user TLS                      │
  │                             │                               │
  │                    internet ◄──────────────────             │
  │                                                             │
  └──────────────────────────────────────────────────────────────┘
```

Return traffic (server → client) follows the same path in reverse, with the
server's TX thread spoofing the source IP so the client receives packets that
appear to come from the expected overlay address.

---

## Wire Format

Each outer frame is:

```
  [Ethernet header  — 14 bytes]  dst_mac, src_mac, ethertype=0x0800
  [IPv4 header      — 20 bytes]  src=SPOOF_IP, dst=PEER_IP, proto=UDP
  [UDP header       —  8 bytes]  sport=LISTEN_PORT, dport=PEER_PORT
  [Tunnel header    — 16 bytes]  version(1), flags(1), path_id(2),
                                  seq(4), ts_ns(8)
  [Inner IP packet  — variable]  the original user packet
```

Total outer overhead: **58 bytes** (OUTER_HDR constant in the source).

---

## Components

### spoof-tunnel binary (`/usr/local/bin/spoof-tunnel`)

Written in C. Two threads per process:

**TX thread** (`tx_thread_udp`):
- Calls `read(tun_fd)` to receive inner packets from the TUN device.
- Uses `poll(timeout=0)` on reads after the first packet to allow partial
  batch sends. This prevents a blocking deadlock when traffic is sparse.
- Builds complete Ethernet+IP+UDP+tun_hdr frames from a pre-computed template.
- Sends up to `batch_size` (default: 16) frames per `sendmmsg` call on the
  `AF_PACKET` socket.
- Tracks the active spoof IP and rotates on loss threshold.

**RX thread** (`rx_thread_udp`):
- Uses `TPACKET_V3` zero-copy ring buffer for kernel-to-userspace packet delivery.
- Spin-waits on ring blocks with 100µs nanosleep between checks.
- Validates the tunnel header version byte.
- Tracks sequence numbers to compute loss percentage.
- Writes inner packets to `tun_fd`.

**Metric thread**:
- Writes `/run/spoof-tunnel/health.json` every `metric_interval` seconds.
- Sends `sd_notify(WATCHDOG=1)` to systemd.

### TUN device (`tun0`)

A kernel TUN interface bridging the user-space tunnel process and the Linux
IP stack. The overlay service (Xray) binds to the TUN IP; iptables DNAT
redirects incoming user traffic into it.

### AF_PACKET socket

A raw socket at the Ethernet layer, bypassing the kernel TCP/IP stack entirely.
This allows:
- Sending frames with arbitrary source MAC and source IP (spoofing).
- Receiving frames without the kernel consuming them first (combined with an
  iptables DROP rule on the tunnel UDP port).

### iptables DNAT (client node)

```
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to 10.100.100.1:443
iptables -t nat -A POSTROUTING -s 10.100.100.0/30 -j MASQUERADE
```

Redirects incoming user connections to the server's TUN IP. The MASQUERADE
rule ensures return packets are routed back through the tunnel.

### MAC Resolution

The TX thread resolves the next-hop gateway MAC address at startup:
1. Read `/proc/net/route` to find the default gateway IP.
2. Read `/proc/net/arp` to find the gateway's MAC.
3. Get the local interface MAC via `SIOCGIFHWADDR`.

These MACs are embedded in the TX frame template. Without correct MACs the
frame is dropped at Layer 2 before it reaches the remote node.

### fq qdisc

After startup, `spoof-tunnel-qdisc` installs an `fq` (Fair Queue) qdisc on
the outer interface:

```bash
tc qdisc replace dev eth0 root fq limit 50000 flow_limit 9000
```

`fq` provides per-flow pacing and prevents head-of-line blocking when many
flows share the interface. The `flow_limit` parameter (auto-computed from
`rate_mbps`) caps per-flow queue depth.

---

## Systemd Integration

- **Type=notify**: process signals ready via `sd_notify("READY=1")`.
- **WatchdogSec=30**: process must call `sd_notify("WATCHDOG=1")` every 30s or
  systemd kills and restarts it.
- **AmbientCapabilities**: `CAP_NET_ADMIN CAP_NET_RAW CAP_IPC_LOCK` (for
  AF_PACKET, TUN, and `mlockall`). Runs as root but with `NoNewPrivileges`.
- **Restart=always, RestartSec=2**: automatic restart on any exit.

---

## Multi-Spoof IP Rotation

The client can be configured with multiple spoof IPs. The TX thread tracks
packet loss per metric interval. If loss exceeds `loss_threshold` for
`failover_intervals` consecutive intervals, it atomically switches to the
next spoof IP in the list. This provides transparent failover if one CDN
or relay IP becomes blocked.

---

## Build Notes

- Written in C11, single file (`src/spoof_tunnel_v6.c`).
- Requires: `gcc`, `-pthread`, `-lm` (implicit via glibc).
- No external library dependencies (sd_notify is implemented inline).
- Built on Ubuntu 22.04 (glibc 2.35) for widest compatibility.
  Binaries will not run on systems with older glibc (e.g. Ubuntu 20.04 / glibc 2.31).
  Build from source on older systems.
