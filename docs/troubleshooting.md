# Troubleshooting

## Quick Diagnostics

```bash
spoofctl status                        # service state + metrics
journalctl -u spoof-tunnel -n 50       # recent logs
cat /run/spoof-tunnel/health.json      # JSON metrics
ping <peer-tun-ip>                     # test tunnel IP reachability
```

---

## Service Won't Start

### Check the logs first

```bash
journalctl -u spoof-tunnel -n 30 --no-pager
systemctl status spoof-tunnel
```

### Common causes

**`CAP_NET_RAW` / `CAP_NET_ADMIN` denied**
```
sendmsg: Operation not permitted
```
The process needs `CAP_NET_RAW` and `CAP_NET_ADMIN`. The service unit grants
these via `AmbientCapabilities`. Verify the unit is the one from this package:
```bash
grep AmbientCapabilities /etc/systemd/system/spoof-tunnel.service
```

**`tun` module not loaded**
```
open /dev/net/tun: No such file or directory
```
```bash
modprobe tun
echo tun >> /etc/modules
```

**Config parse error**
```
config-parse.py: ERROR: ...
```
```bash
python3 /usr/local/lib/spoof-tunnel/config-parse.py --validate /etc/spoof-tunnel/config.yaml
```

**Binary not found or not executable**
```bash
ls -la /usr/local/bin/spoof-tunnel
file /usr/local/bin/spoof-tunnel
```
If `file` reports `glibc 2.XX` and your system has an older version, rebuild
from source:
```bash
make build && sudo make install
```

---

## Tunnel Is Up But No Traffic Flows

### Ping test

From the client, ping the server's TUN IP:
```bash
ping 10.100.100.1
```
If this fails, the tunnel itself is not passing traffic.

### Check TX/RX counters

```bash
cat /run/spoof-tunnel/health.json
```
Look at `tx_pkts` and `rx_pkts`. If `tx_pkts` is rising but `rx_pkts` is not,
the server is not receiving or not sending back.

### Verify packets reach the server

On the server, run:
```bash
tcpdump -i eth0 -n udp port 2080
```
If no packets appear, the client is not sending (or the packets are being
dropped in transit).

### Check iptables on the server

The server's `iptables -I INPUT -p udp --dport 2080 -j DROP` rule is required
for AF_PACKET to intercept packets without the kernel generating ICMP errors.
Verify it's installed:
```bash
iptables -L INPUT -n | grep 2080
```

### Check rp_filter

```bash
sysctl net.ipv4.conf.eth0.rp_filter
sysctl net.ipv4.conf.all.rp_filter
```
Both must be `0`. If not:
```bash
sysctl -w net.ipv4.conf.eth0.rp_filter=0
sysctl -w net.ipv4.conf.all.rp_filter=0
```

### BCP38 blocking spoofed packets

If your hosting provider enforces BCP38 / uRPF ingress filtering, spoofed
source packets are dropped before leaving their network. Signs:
- `tcpdump -i eth0 udp port 2080` on the server shows nothing.
- `tcpdump -i eth0 udp port 2080` on the client shows outgoing packets.

Contact your VPS provider or choose a provider that does not enforce BCP38.

---

## TX Thread Blocking (Sparse Traffic)

**Symptom**: tunnel works for bulk transfers but hangs during idle periods or
with low-frequency connections. `wchan` shows the TX thread stuck in
`tun_do_read`.

**Cause**: The TX thread was accumulating `batch_size` packets before calling
`sendmmsg`. With sparse traffic (< 16 packets in a burst), the batch never
filled and the thread blocked indefinitely.

**Fix**: Applied in v6 — the TX thread uses `poll(timeout=0)` before each
additional read and sends partial batches immediately. If you see this on
v5 or earlier, upgrade.

**Check version**:
```bash
spoof-tunnel --version
# or
cat /etc/spoof-tunnel/VERSION
```

---

## Double Ethernet Header / Malformed Frames

**Symptom**: frames leave the client but are dropped immediately. `tcpdump` on
the client shows outgoing frames but the server sees nothing or sees malformed
packets.

**Cause**: If `sll_halen=ETH_ALEN` (6) is set in `sockaddr_ll`, the kernel
calls `eth_header()` which prepends an additional 14-byte Ethernet header.
The IP header lands at offset 28 instead of 14, making all frames malformed.

**Fix**: Applied in v6 — `sll_halen=0` and MAC addresses are filled directly
in the TX template. Upgrade from v5 fixes this.

---

## High Loss / Frequent Spoof IP Rotation

**Symptom**: `health.json` shows `loss_pct > 5` frequently. `active_spoof`
keeps changing.

**Checks**:
1. Is the network path genuinely lossy?
   ```bash
   ping -c 100 <peer-public-ip>
   mtr <peer-public-ip>
   ```
2. Is the fq qdisc dropping flows?
   ```bash
   tc -s qdisc show dev eth0
   ```
   Look for `drops` and `flows_plimit`. If nonzero, reduce `flow_limit` or
   increase `rate_mbps` in config to match actual capacity.

3. Are spoof IPs reachable from the server's perspective?
   The server receives frames with the spoof IP as source. Its ARP/routing
   tables are not involved, but the return path (server → client) uses the
   real peer IP. If the client's real IP is blocked, all traffic fails.

---

## Xray / Overlay Not Working

After verifying the tunnel is passing traffic (ping 10.100.100.1 works), check
the overlay service:

```bash
# Client
systemctl status xray     # or x-ui if using a panel
# or
pgrep -a xray

# Server
pgrep -a xray
ss -tlnp | grep :443
```

If Xray is not listening, the tunnel is working but the overlay is down. This
is not a spoof-tunnel problem.

### DNAT / Forwarding rules missing or not working

Forwarding rules are installed automatically by the service (via ExecStartPost)
based on `forwarding.ports` in your `config.yaml`. Run a full check:

**1. Verify the config has ports set:**
```bash
grep -A5 'forwarding' /etc/spoof-tunnel/config.yaml
# Should show:
# forwarding:
#   ports:
#     - 443
```
Also check the environment file:
```bash
grep FORWARD_PORTS /etc/spoof-tunnel/tunnel.env
# FORWARD_PORTS=443
```

**2. Check PREROUTING DNAT rules:**
```bash
iptables -t nat -L PREROUTING -n --line-numbers
```
Look for `DNAT` entries pointing to `10.100.100.1:443` (for each port, both
TCP and UDP):
```
Chain PREROUTING (policy ACCEPT)
num  target  prot  ...  dpt:443  to:10.100.100.1:443
```
If missing, the forward hook did not run. Re-apply without a restart:
```bash
/usr/local/libexec/spoof-tunnel-forward
```

**3. Check POSTROUTING MASQUERADE:**
```bash
iptables -t nat -L POSTROUTING -n
```
Look for `MASQUERADE` on interface `tun0`. Without this rule, packets are
DNAT'd to the server but the source IP remains the user's real IP — the server
routes replies directly to the internet instead of back through the tunnel, and
the connection is never established.

**4. Check the FORWARD chain:**
```bash
iptables -L FORWARD -n
```
Look for `ACCEPT` rules for `eth0 → tun0` and `tun0 → eth0`. When ufw is
active, the default FORWARD policy is DROP. Without these rules, DNAT'd packets
are silently dropped in the FORWARD chain before reaching tun0.

If FORWARD rules are missing but DNAT is present, user traffic is being dropped
silently. Re-apply the forward hook:
```bash
/usr/local/libexec/spoof-tunnel-forward
```

**5. Verify ip_forward is enabled:**
```bash
sysctl net.ipv4.ip_forward
# Must be: net.ipv4.ip_forward = 1
```
If 0, enable it:
```bash
sysctl -w net.ipv4.ip_forward=1
```
spoof-tunnel-prepare sets this on every service start, but check manually if
you suspect it was reset.

**6. Complete packet path trace:**

User → client eth0 → PREROUTING DNAT → FORWARD chain → POSTROUTING MASQUERADE
→ tun0 → spoof-tunnel TX → (spoofed UDP) → server eth0 → spoof-tunnel RX →
server tun0 → Xray:443

Return path: Xray → server tun0 → spoof-tunnel TX → (spoofed UDP) → client
eth0 → spoof-tunnel RX → client tun0 → conntrack (reverses DNAT+MASQUERADE)
→ FORWARD chain → eth0 → user

If ping 10.100.100.1 works but user connections fail, the problem is almost
always: missing FORWARD chain rules, missing MASQUERADE, or Xray not listening
on the TUN IP (10.100.100.1) on the server.

**Re-apply all forwarding rules without a service restart:**
```bash
spoofctl forward-rules
# or:
/usr/local/libexec/spoof-tunnel-forward --remove && /usr/local/libexec/spoof-tunnel-forward
```

**Check current forwarding configuration and NAT state:**
```bash
spoofctl status   # shows forwarded ports and live DNAT/MASQUERADE/FORWARD counts
```

---

## qdisc flows_plimit Drops (Warning, Usually Non-Critical)

```
tc -s qdisc show dev eth0
# ... flows_plimit 12345678 ...
```

`flows_plimit` is the **cumulative total** since the qdisc was installed. A
large historical number does not mean current dropping. Check current traffic:

```bash
cat /run/spoof-tunnel/health.json
```
If `tx_pps` and `rx_pps` are nonzero and `loss_pct` is near 0, the qdisc is
not currently dropping and this counter is historical noise.

---

## MAC Address Not Resolved

**Symptom**: binary exits immediately with:
```
[FATAL] ARP resolution failed for gateway X.X.X.X after 3 seconds.
```

**Cause**: The gateway's MAC address is not in the kernel ARP cache. The
binary retries for 3 seconds, then exits rather than using a broadcast MAC
(which would flood the local network segment).

**Fix**: Populate the ARP cache by sending a packet through the normal stack:
```bash
ping -c 1 8.8.8.8
```

Then verify:
```bash
ip neigh show          # should show the gateway IP with a MAC and "REACHABLE"
cat /proc/net/arp      # lower-level view
cat /proc/net/route    # verify default route gateway IP
```

With systemd `Restart=always`, the service will automatically retry after
a 2-second delay. The ARP cache is typically populated within the first retry.

---

## Building on Systems Without GCC

On Ubuntu 24.04 and later, GCC may not be installed:
```bash
apt-get install -y gcc
```

On systems with glibc 2.31 (Ubuntu 20.04), the pre-built binary will fail
with `version GLIBC_2.35 not found`. Build from source on the target system:
```bash
make build
sudo make install
```
