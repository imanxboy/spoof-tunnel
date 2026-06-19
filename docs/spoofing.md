# IP Spoofing in spoof-tunnel

## What is Being Spoofed

In spoof-tunnel, **the source IP of the outer UDP packet** is spoofed.

When the client node sends tunnel packets to the server, it does not use its
real public IP as the source. Instead, it uses a configured "spoof IP" — an
address that belongs to a CDN, a legitimate content provider, or any other
IP that is trusted by the network path.

The **inner packets** (user traffic) are not modified. Only the outer tunnel
wrapper is affected.

---

## Why This Is Done

In some network environments, traffic is filtered based on the IP addresses
that packets appear to come from. A tunnel between two servers in different
countries may be easy to detect and block if the outer packets show the real
IPs of both servers.

By spoofing the source IP to match a CDN or a widely-whitelisted service,
the outer packets become indistinguishable from legitimate traffic to/from that
service at the IP layer.

This technique is known as **domain fronting at the IP layer** (as opposed to
the more common domain fronting at the TLS SNI layer). It is used to maintain
tunnel connectivity when specific server IPs are targeted for blocking.

---

## How Spoofing Works at the Technical Level

Normal UDP sending goes through the kernel TCP/IP stack:

```
  application → socket() → bind(local_ip) → sendto(dst_ip) → kernel fills Ethernet header
```

The kernel controls the source IP (it must match a configured interface) and
the Ethernet header (it resolves the MAC via ARP).

spoof-tunnel bypasses the kernel stack entirely using `AF_PACKET SOCK_RAW`:

```
  application → socket(AF_PACKET, SOCK_RAW, ...) → sendmsg(complete_frame)
```

The application sends a **complete Ethernet frame**, including the Ethernet
header, the IP header, the UDP header, and the payload. The kernel forwards
the frame directly onto the wire without examining or modifying any field.

This allows setting any source IP address in the IP header — including IPs
that do not belong to any local interface.

### Frame Construction

At startup, the TX thread:
1. Resolves the local interface MAC via `SIOCGIFHWADDR`.
2. Reads `/proc/net/route` to find the default gateway IP.
3. Reads `/proc/net/arp` to find the gateway's MAC address.

It then builds a **TX template** — a pre-filled 58-byte outer header:
```
  dst_mac  = gateway_mac      (frames go to the gateway, not the peer directly)
  src_mac  = local_iface_mac
  ethertype = 0x0800 (IPv4)
  IP src   = SPOOF_IP         (the spoofed address)
  IP dst   = PEER_IP          (the server's real public IP)
  IP proto = UDP (17)
  UDP sport = LISTEN_PORT
  UDP dport = PEER_PORT
```

For each packet, the template is copied into the send buffer, the inner
payload is appended, the IP total length and UDP length are set, and the
IP checksum is computed. The frame is sent via `sendmmsg`.

### Why the Gateway MAC

Ethernet frames are addressed to the **next hop** at Layer 2, not the final
destination. If both nodes are in different data centers, packets travel
through multiple routers. The Layer 2 destination is always the local
gateway's MAC. The gateway forwards the packet based on the Layer 3 IP
destination. spoof-tunnel resolves the gateway MAC so frames are delivered
correctly even though the source IP is spoofed.

---

## rp_filter and iptables DROP

Two kernel-level adjustments are required for spoofed receiving to work:

### rp_filter = 0

Linux's reverse path filter (`rp_filter`) drops incoming packets whose source
IP does not match any route that would be used to reach that source. For the
**server** receiving spoofed packets from the client (where source IP is the
spoof IP, not the client's real IP), rp_filter would drop the frame if the
spoof IP is not routable via the same interface.

`spoof-tunnel-prepare` disables rp_filter on the outer interface:
```bash
sysctl -qw net.ipv4.conf.eth0.rp_filter=0
```

### iptables DROP on the tunnel port

The AF_PACKET socket receives all frames matching the BPF filter before the
kernel processes them. However, the kernel also tries to deliver the UDP
packet to a normal socket. Since no process is listening on that UDP port,
the kernel sends an ICMP `Port Unreachable` reply to the (spoofed) source IP.

This generates spurious ICMP traffic and may alert monitoring systems. The
`iptables -I INPUT -p udp --dport 2080 -j DROP` rule prevents the kernel
from processing the packet after AF_PACKET has received it.

---

## Spoof IP Rotation (Failover)

The client can be configured with multiple spoof IPs. The `spoof.addresses`
list in `config.yaml` defines the rotation pool.

The metric thread measures per-interval packet loss (based on sequence number
gaps). If loss exceeds `loss_threshold` for `failover_intervals` consecutive
intervals, the TX thread atomically switches to the next spoof IP.

This is useful when:
- One IP gets temporarily blocked or rate-limited.
- Network paths have different loss characteristics.
- A CDN rotates its address pool.

The active spoof IP is visible in `health.json` and `spoofctl status`.

---

## Limitations

- Spoofing works at the **outer transport layer only**. The inner packets
  contain the real IP addresses of users and the overlay service.
- The server can see the **real source IP** of the client in the ARP/routing
  tables and in tcpdump, since the Ethernet frame arrives from the client's
  real MAC/IP path. Spoofing only affects what the outer IP header shows
  to IP-layer observers (firewalls, DPI) on the path between client and server.
- Some networks implement **BCP38 / uRPF ingress filtering** which drops
  packets with source IPs that cannot be routed back through the same interface.
  If the upstream provider of the client's data center enforces BCP38, spoofed
  packets will be dropped before they leave the data center. Contact your
  provider or use a network path that does not enforce BCP38.
