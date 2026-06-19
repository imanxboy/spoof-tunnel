# FAQ

## General

### What is spoof-tunnel?

spoof-tunnel is a UDP tunnel that carries IP packets between two Linux servers
while making the outer transport packets appear to originate from a different
IP address. It is designed to work alongside overlay proxy services such as
Xray, V2Ray, or similar tools.

### What problem does it solve?

In some network environments, traffic between two specific IP addresses is
actively monitored or blocked. By replacing the true source IP of the outer
tunnel packets with a CDN or relay IP (IP spoofing), the tunnel traffic becomes
harder to identify and block at the IP layer.

### What is it not?

- It is not a VPN that routes all your traffic. It is a point-to-point tunnel
  between two specific servers.
- It is not a privacy tool in the anonymity sense. The inner packets still
  contain real user IPs.
- It does not encrypt tunnel traffic on its own. Encryption is the
  responsibility of the overlay service (Xray, VLESS, etc.).

---

## Setup

### Do I need to run this on both servers?

Yes. You need:
- A **client** node: the server your users connect to. Must have a public IP.
- A **server** node: your foreign/back-end server running the overlay service
  (Xray, etc.). Must have a public IP.

Run the installer on both, selecting the appropriate role.

### Which role should I pick?

- **client**: The server in the country/region where your users are. Users
  connect to this server. It tunnels the traffic to the foreign server.
- **server**: The foreign/back-end server that runs Xray or your proxy service.
  It receives tunneled traffic from the client.

### What port should I use?

The default tunnel port is `2080`. Choose a port that:
- Is not already in use on either machine.
- Is not the same as your overlay service port (typically 443 or 80).
- Is allowed through any firewall between the two machines.

You must open this UDP port in your firewall/security group on both servers.

### What should I use as spoof IPs?

The spoof IP should be an IP address that is:
- Widely trusted or whitelisted by the network path you are working with.
- Preferably a well-known CDN IP (Cloudflare, Akamai, Fastly, etc.).
- Routable on the internet (the server's response packets need to reach the
  client via the real peer IP — not the spoof IP).

You can use multiple spoof IPs for automatic failover if one gets blocked.

### Does BCP38 affect me?

BCP38 (RFC 2827) is an ingress filtering standard that many ISPs and hosting
providers implement. It drops packets where the source IP cannot be routed
back through the same interface — i.e., it blocks packets with spoofed source
IPs at the provider's edge.

If your hosting provider enforces BCP38, the spoofed packets will be dropped
before they leave the data center. Not all providers do this, but if spoofing
does not work, BCP38 is the most likely cause. There is no workaround at the
software level — you need a provider that does not enforce it.

---

## Configuration

### How do I change the spoof IP after installation?

```bash
spoofctl spoof-ips
```

Or edit `/etc/spoof-tunnel/config.yaml` directly and restart:
```bash
spoofctl edit-config
```

### Can I use multiple spoof IPs?

Yes. List multiple IPs in `config.yaml`:

```yaml
spoof:
  addresses:
    - 1.2.3.4
    - 5.6.7.8
    - 9.10.11.12
  loss_threshold: 0.05
  failover_intervals: 3
```

The tunnel will automatically rotate to the next IP when loss exceeds the
threshold for `failover_intervals` consecutive metric intervals.

### What MTU should I use?

The installer auto-detects the right MTU: `physical_interface_mtu - 58`.
The 58-byte overhead is the outer frame: 14 (Ethernet) + 20 (IP) + 8 (UDP)
+ 16 (tunnel header).

For a standard 1500-byte Ethernet interface, the inner MTU is 1442.
For a 9000-byte jumbo frame interface, the inner MTU would be 8942.

Only change this if you are seeing fragmentation issues.

### Do I need to configure iptables manually?

**Tunnel rules** are handled automatically by the installer on both nodes:
- `iptables -I INPUT -p udp --dport 2080 -j DROP` (prevents the kernel from
  sending ICMP port-unreachable replies for raw tunnel frames).

**User traffic forwarding rules** are also installed automatically on CLIENT
nodes, based on the `forwarding.ports` section in `config.yaml`:
```yaml
forwarding:
  ports:
    - 443
    - 80
    - 2053
```
For each listed port N, the service installs **both TCP and UDP** rules:
```bash
iptables -t nat -A PREROUTING -p tcp --dport N -j DNAT --to-destination 10.100.100.1:N
iptables -t nat -A PREROUTING -p udp --dport N -j DNAT --to-destination 10.100.100.1:N
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
```
The FORWARD chain rules are required when ufw is active (its default FORWARD
policy is DROP). The MASQUERADE rule ensures return packets route back through
the tunnel instead of directly to the user's real IP.

All rules are automatically restored on every service start (ExecStartPost)
and removed cleanly on uninstall.

To update forwarding ports after installation:
```bash
spoofctl forward-rules
```

---

## Operations

### How do I check if the tunnel is working?

```bash
spoofctl status
```

Or ping the peer's TUN IP from the client:
```bash
ping 10.100.100.1
```

### How do I see live logs?

```bash
journalctl -u spoof-tunnel -f
```

### How do I update?

```bash
spoofctl update
```

This downloads the latest release, rebuilds, installs, restarts, and
automatically rolls back if the health check fails after restart.

### How do I roll back to the previous version?

```bash
spoofctl rollback
```

This shows available snapshots (taken before each update) and restores
the selected one.

### How do I uninstall?

```bash
spoofctl uninstall
```

This stops and disables the service, removes all installed files, and
optionally removes config and logs.

---

## Performance

### What throughput can I expect?

The tunnel overhead is primarily the 58-byte outer header and the CPU cost
of building and sending raw AF_PACKET frames. On a modern CPU:
- A single-core TX or RX thread can typically sustain 500–1000 Mbps at
  small packet sizes (64–512 bytes).
- For 10G or higher, set `tx_cpu` and `rx_cpu` to dedicated cores.

### Why is my traffic not reaching the configured rate limit?

The `rate_mbps` setting configures the fq qdisc, which provides pacing and
fairness. It does not cap throughput — the physical link capacity is the
actual limit. If your link is below `rate_mbps`, traffic will be paced to
the link speed.

If you see drops in `tc -s qdisc show dev eth0`, increase `flow_limit`
or reduce `rate_mbps` to match your actual uplink.

### Should I enable Prometheus?

If you run a Prometheus + node_exporter setup, set `prometheus_enabled: true`
in `config.yaml` and point `prometheus_dir` to your node-exporter textfile
directory. A systemd timer will export metrics every 30 seconds.

---

## Legal and Ethical

### Is this legal?

This depends entirely on your jurisdiction and how you use it. IP spoofing
is a dual-use technique: it is used legitimately in network testing, CDN
infrastructure, and DDoS mitigation, and is also sometimes used for
circumventing censorship.

This software is provided for authorized network research, privacy protection
in hostile network environments, and building censorship-resistant communication
infrastructure. You are responsible for complying with the laws of your
jurisdiction and any terms of service of networks you use.

### Does this facilitate illegal activity?

No more than a VPN does. The tunnel carries standard proxy traffic (Xray,
VLESS). The authors neither encourage nor condone using this software to
conduct illegal activities.
