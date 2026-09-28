/*
 * spoof-tunnel-v6
 *
 * UDP mode: AF_PACKET + TPACKET_V3 zero-copy RX ring, sendmmsg TX batch,
 *           IP source spoofing, multi-spoof rotation with health-driven failover.
 * TCP mode: standard TCP socket with 2-byte length-prefixed framing,
 *           auto-reconnect, works through firewalls that block UDP.
 *
 * Build: gcc -O2 -pthread -Wall -Wextra -Werror -o spoof-tunnel spoof_tunnel_v6.c
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* TP_FT_REQ_FILL_RXHASH may not be defined on older kernel headers */
#ifndef TP_FT_REQ_FILL_RXHASH
#define TP_FT_REQ_FILL_RXHASH 0x2
#endif

/* ── constants ─────────────────────────────────────────────────────────── */

#define VERSION          "6.3.1"
#define MAX_SPOOF        16
#define OUTER_HDR        58   /* 14 eth + 20 ip + 8 udp + 16 tun_hdr */
#define TUN_HDR_OFF      42   /* offset of tun_hdr within OUTER_HDR */
#define TUN_HDR_LEN      16
#define MAX_FRAME        1514
#define DEFAULT_MTU      1440
#define DEFAULT_PORT     2080
#define DEFAULT_BATCH    16
#define RX_BLOCK_SIZE    (1 << 20)  /* 1 MiB */
#define RX_BLOCK_NR_DEF  64
#define RX_FRAME_SIZE    2048
#define RX_RETIRE_MS     1
#define SEQ_WINDOW       65536
#define TCP_RECONNECT_MS 2000
#define METRIC_INTERVAL  5          /* seconds */
#define WATCHDOG_DIVISOR 3          /* send watchdog every interval/3 */
#define RUN_DIR          "/run/spoof-tunnel"
#define LOG_DIR          "/var/log/spoof-tunnel"
#define HEALTH_JSON      RUN_DIR "/health.json"
#define METRICS_JSONL    LOG_DIR "/metrics.jsonl"
#define MAX_NAME         16

/* Runtime paths. Without --name these hold the two defines above, which is
 * what keeps a pre-multi-tunnel install working unchanged. With --name <n>
 * they become <dir>/<n>/... so several instances can run side by side. */
static char health_path[256]  = HEALTH_JSON;
static char metrics_path[256] = METRICS_JSONL;
static char health_tmp[256]   = HEALTH_JSON ".tmp";

#define MODE_CLIENT  0
#define MODE_SERVER  1
#define OUTER_UDP    0
#define OUTER_TCP    1

/* ── wire types ─────────────────────────────────────────────────────────── */

struct __attribute__((packed)) tun_hdr {
    uint8_t  version;   /* 6 */
    uint8_t  flags;     /* bit0: has_path_id */
    uint16_t path_id;   /* spoof index, network byte order */
    uint32_t seq;       /* network byte order */
    uint64_t ts_ns;     /* nanoseconds since epoch, network byte order */
};

/* ── config ─────────────────────────────────────────────────────────────── */

struct config {
    int      mode;
    int      outer;
    char     name[MAX_NAME];        /* instance name; empty = legacy paths */
    char     iface[IFNAMSIZ];
    char     tun_name[IFNAMSIZ];
    uint32_t spoof_ips[MAX_SPOOF];  /* network byte order */
    int      spoof_count;
    uint32_t peer_ip;               /* network byte order */
    uint32_t local_tun;
    uint32_t peer_tun;
    int      listen_port;
    int      peer_port;
    int      mtu;
    int      tx_cpu;
    int      rx_cpu;
    long     rate_mbps;
    int      flow_limit;
    int      batch_size;
    int      rx_block_nr;
    float    failover_loss;         /* 0.0–1.0; rotate if loss exceeds */
    int      failover_intervals;    /* consecutive bad intervals */
    int      metric_interval;
    bool     json_metrics;
    int      watchdog_sec;
};

/* ── sequence tracker ───────────────────────────────────────────────────── */

struct seq_tracker {
    uint32_t base;
    uint32_t high;
    bool     valid;
    uint64_t seen[SEQ_WINDOW / 64];
};

static inline void seq_mark(struct seq_tracker *t, uint32_t seq)
{
    uint32_t off = seq - t->base;
    if (off < SEQ_WINDOW)
        t->seen[off / 64] |= (uint64_t)1 << (off & 63);
}

static inline bool seq_seen(const struct seq_tracker *t, uint32_t seq)
{
    uint32_t off = seq - t->base;
    if (off >= SEQ_WINDOW) return false;
    return !!(t->seen[off / 64] & ((uint64_t)1 << (off & 63)));
}

/* advance base, count losses in the vacated window */
static uint32_t seq_advance(struct seq_tracker *t, uint32_t new_base)
{
    uint32_t lost = 0;
    while ((int32_t)(new_base - t->base) > 0) {
        if (!(t->seen[0] & 1ULL))
            lost++;
        /* shift window by 1 */
        for (int i = 0; i < SEQ_WINDOW / 64 - 1; i++)
            t->seen[i] = (t->seen[i] >> 1) | (t->seen[i+1] << 63);
        t->seen[SEQ_WINDOW / 64 - 1] >>= 1;
        t->base++;
    }
    return lost;
}

/* ── global state ───────────────────────────────────────────────────────── */

struct state {
    struct config cfg;

    /* TUN */
    int tun_fd;

    /* UDP outer transport */
    int              pkt_fd;
    uint8_t          tx_tmpl[OUTER_HDR];
    void            *rx_ring;
    size_t           rx_ring_sz;
    struct tpacket_req3 rx_req;
    struct sockaddr_ll  tx_addr;

    /* TCP outer transport */
    int              tcp_fd;   /* -1 = disconnected */
    pthread_mutex_t  tcp_mu;
    pthread_cond_t   tcp_cv;   /* signalled when tcp_fd changes */

    /* multi-spoof */
    atomic_int       active_spoof;
    int              spoof_bad[MAX_SPOOF];  /* consecutive bad intervals */

    /* sequence tracking */
    struct seq_tracker rx_seq;
    pthread_mutex_t    seq_mu;

    /* counters */
    atomic_uint_fast64_t c_tx_pkts;
    atomic_uint_fast64_t c_tx_bytes;
    atomic_uint_fast64_t c_tx_retry;
    atomic_uint_fast64_t c_tx_err;
    atomic_uint_fast64_t c_rx_pkts;
    atomic_uint_fast64_t c_rx_bytes;
    atomic_uint_fast64_t c_rx_bad;
    atomic_uint_fast64_t c_seq_loss;
    atomic_uint_fast64_t c_reorder;
    atomic_uint_fast64_t c_tun_rerr;
    atomic_uint_fast64_t c_tun_werr;

    /* snapshot for deltas */
    uint64_t snap_tx_pkts, snap_tx_bytes;
    uint64_t snap_rx_pkts, snap_rx_bytes;
    uint64_t snap_seq_loss, snap_reorder, snap_tx_retry;

    volatile sig_atomic_t running;
    volatile sig_atomic_t force_rotate;
};

static struct state st;

/* ── utility ────────────────────────────────────────────────────────────── */

static void die(const char *msg)
{
    fprintf(stderr, "[FATAL] %s: %s\n", msg, strerror(errno));
    exit(1);
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static uint64_t now_ms(void)  { return now_ns() / 1000000; }

static void pin_cpu(int cpu)
{
    if (cpu < 0) return;
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET((unsigned)cpu, &s);
    pthread_setaffinity_np(pthread_self(), sizeof(s), &s);
}

/* sd_notify: send to NOTIFY_SOCKET if set; no libsystemd dependency */
static void sd_notify_str(const char *s)
{
    const char *sock = getenv("NOTIFY_SOCKET");
    if (!sock) return;
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    struct sockaddr_un un = { .sun_family = AF_UNIX };
    if (sock[0] == '@') {
        un.sun_path[0] = '\0';
        snprintf(un.sun_path + 1, sizeof(un.sun_path) - 1, "%s", sock + 1);
    } else {
        snprintf(un.sun_path, sizeof(un.sun_path), "%s", sock);
    }
    sendto(fd, s, strlen(s), MSG_NOSIGNAL,
           (struct sockaddr *)&un, sizeof(un));
    close(fd);
}

static uint16_t ip_csum(const void *buf, int len)
{
    uint32_t sum = 0;
    const uint16_t *p = buf;
    while (len > 1) { sum += *p++; len -= 2; }
    if (len) sum += *(const uint8_t *)p;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return ~sum;
}

/* ── TUN device ─────────────────────────────────────────────────────────── */

static int tun_open(const char *name, int mtu)
{
    struct ifreq ifr = {0};
    int fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (fd < 0) die("open /dev/net/tun");
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) die("TUNSETIFF");

    /* bring up with correct MTU */
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0) die("socket for tun mtu");
    ifr.ifr_mtu = mtu;
    if (ioctl(s, SIOCSIFMTU, &ifr) < 0) die("SIOCSIFMTU");
    ifr.ifr_flags = IFF_UP | IFF_RUNNING;
    if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0) die("SIOCSIFFLAGS");
    close(s);
    return fd;
}

static void tun_set_addr(const char *name, uint32_t local_be, uint32_t peer_be)
{
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0) die("socket for tun addr");
    struct ifreq ifr = {0};
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = local_be;
    if (ioctl(s, SIOCSIFADDR, &ifr) < 0) die("SIOCSIFADDR");
    sin->sin_addr.s_addr = peer_be;
    if (ioctl(s, SIOCSIFDSTADDR, &ifr) < 0) die("SIOCSIFDSTADDR");
    /* point-to-point /32 route is set automatically */
    close(s);
}

/* ── MAC / next-hop resolution ──────────────────────────────────────────── */

static void get_iface_mac(const char *iface, uint8_t *mac_out)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) die("socket for SIOCGIFHWADDR");
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", iface);
    if (ioctl(s, SIOCGIFHWADDR, &ifr) < 0) die("SIOCGIFHWADDR");
    memcpy(mac_out, ifr.ifr_hwaddr.sa_data, ETH_ALEN);
    close(s);
}

/* Return next-hop IP for peer_ip (in network byte order) by reading /proc/net/route.
 * Returns the gateway IP (or peer_ip itself if directly connected). */
static uint32_t get_nexthop_ip(uint32_t peer_ip_be)
{
    FILE *f = fopen("/proc/net/route", "r");
    if (!f) return peer_ip_be;
    char line[256];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return peer_ip_be; } /* skip header */
    uint32_t best_mask = 0, best_gw = 0;
    while (fgets(line, sizeof(line), f)) {
        char iface_buf[32];
        unsigned int dest_le, gw_le, flags, mask_le;
        if (sscanf(line, "%31s %x %x %x %*d %*d %*d %x",
                   iface_buf, &dest_le, &gw_le, &flags, &mask_le) != 5) continue;
        /* /proc/net/route stores in little-endian host byte order */
        uint32_t dest = htonl(__builtin_bswap32(dest_le));
        uint32_t mask = htonl(__builtin_bswap32(mask_le));
        uint32_t gw   = htonl(__builtin_bswap32(gw_le));
        if ((peer_ip_be & mask) != (dest & mask)) continue;
        if (mask >= best_mask) { best_mask = mask; best_gw = gw; }
    }
    fclose(f);
    return (best_gw != 0) ? best_gw : peer_ip_be;
}

/* Look up MAC for ip_be in /proc/net/arp; returns 0 on success. */
static int lookup_arp_mac(uint32_t ip_be, uint8_t *mac_out)
{
    FILE *f = fopen("/proc/net/arp", "r");
    if (!f) return -1;
    char line[256];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; } /* skip header */
    while (fgets(line, sizeof(line), f)) {
        char ip_str[32], hw[8], fl[8], mac_str[32], mask[8], dev[32];
        if (sscanf(line, "%31s %7s %7s %31s %7s %31s",
                   ip_str, hw, fl, mac_str, mask, dev) != 6) continue;
        struct in_addr a;
        if (!inet_aton(ip_str, &a)) continue;
        if (a.s_addr != ip_be) continue;
        unsigned int m[6];
        if (sscanf(mac_str, "%x:%x:%x:%x:%x:%x",
                   &m[0],&m[1],&m[2],&m[3],&m[4],&m[5]) != 6) continue;
        for (int i = 0; i < 6; i++) mac_out[i] = (uint8_t)m[i];
        fclose(f);
        return 0;
    }
    fclose(f);
    return -1;
}

/* Resolve the next-hop MAC for peer_ip via route + ARP tables.
 * Sends a dummy UDP to trigger ARP if not yet cached; retries up to 3s. */
static void resolve_nexthop_mac(uint32_t peer_ip_be, const char *iface __attribute__((unused)), uint8_t *mac_out)
{
    uint32_t nexthop = get_nexthop_ip(peer_ip_be);

    for (int attempt = 0; attempt < 30; attempt++) {
        if (lookup_arp_mac(nexthop, mac_out) == 0) return;
        if (attempt == 0) {
            /* Trigger ARP by connecting a dummy UDP socket */
            int s = socket(AF_INET, SOCK_DGRAM, 0);
            if (s >= 0) {
                struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = nexthop,
                                          .sin_port = htons(1) };
                connect(s, (struct sockaddr *)&sa, sizeof(sa));
                char c = 0; send(s, &c, 1, 0);
                close(s);
            }
        }
        struct timespec ts = { .tv_nsec = 100000000 }; /* 100 ms */
        nanosleep(&ts, NULL);
    }
    /* ARP resolution failed — do NOT fall back to broadcast MAC.
     * Sending to ff:ff:ff:ff:ff:ff floods the local L2 segment and will
     * be dropped by the switch for unicast-destined tunnel frames.
     * Fail fast so systemd can restart the service after ARP populates. */
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &nexthop, buf, sizeof(buf));
    fprintf(stderr,
        "[FATAL] ARP resolution failed for gateway %s after 3 seconds.\n"
        "        Trigger ARP with:  ping -c 1 8.8.8.8\n"
        "        Then check:        ip neigh show\n",
        buf);
    exit(1);
}

/* ── UDP / AF_PACKET setup ──────────────────────────────────────────────── */

/* Ethernet source and destination MACs for the TX template */
static uint8_t g_src_mac[ETH_ALEN];
static uint8_t g_dst_mac[ETH_ALEN];

static void udp_setup(void)
{
    struct config *c = &st.cfg;

    /* AF_PACKET socket */
    st.pkt_fd = socket(AF_PACKET, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                       htons(ETH_P_IP));
    if (st.pkt_fd < 0) die("AF_PACKET socket");

    /* Resolve source MAC (own interface) and destination MAC (next-hop gateway) */
    get_iface_mac(c->iface, g_src_mac);
    resolve_nexthop_mac(c->peer_ip, c->iface, g_dst_mac);
    fprintf(stderr, "[INFO] TX: src_mac=%02x:%02x:%02x:%02x:%02x:%02x "
            "dst_mac=%02x:%02x:%02x:%02x:%02x:%02x\n",
            g_src_mac[0], g_src_mac[1], g_src_mac[2],
            g_src_mac[3], g_src_mac[4], g_src_mac[5],
            g_dst_mac[0], g_dst_mac[1], g_dst_mac[2],
            g_dst_mac[3], g_dst_mac[4], g_dst_mac[5]);

    /* TX address: specify interface only; Ethernet header is filled in the frame */
    int ifindex = (int)if_nametoindex(c->iface);
    if (!ifindex) die("if_nametoindex");
    st.tx_addr.sll_family   = AF_PACKET;
    st.tx_addr.sll_ifindex  = ifindex;
    st.tx_addr.sll_protocol = htons(ETH_P_IP);
    st.tx_addr.sll_halen    = 0;  /* frame contains complete Ethernet header */
    memset(st.tx_addr.sll_addr, 0, ETH_ALEN);

    /* pacing rate */
    if (c->rate_mbps > 0) {
        uint64_t rate = (uint64_t)c->rate_mbps * 1000000ULL / 8;
        setsockopt(st.pkt_fd, SOL_SOCKET, SO_MAX_PACING_RATE,
                   &rate, sizeof(rate));
    }

    /* TPACKET_V3 RX ring */
    int v = TPACKET_V3;
    if (setsockopt(st.pkt_fd, SOL_PACKET, PACKET_VERSION, &v, sizeof(v)) < 0)
        die("PACKET_VERSION");

    int nr = c->rx_block_nr > 0 ? c->rx_block_nr : RX_BLOCK_NR_DEF;
    st.rx_req.tp_block_size = RX_BLOCK_SIZE;
    st.rx_req.tp_block_nr   = (uint32_t)nr;
    st.rx_req.tp_frame_size = RX_FRAME_SIZE;
    /* FIX: derive tp_frame_nr from actual tp_block_nr, not a constant */
    st.rx_req.tp_frame_nr   = (uint32_t)nr * (RX_BLOCK_SIZE / RX_FRAME_SIZE);
    st.rx_req.tp_retire_blk_tov = RX_RETIRE_MS;
    st.rx_req.tp_feature_req_word = TP_FT_REQ_FILL_RXHASH;

    if (setsockopt(st.pkt_fd, SOL_PACKET, PACKET_RX_RING,
                   &st.rx_req, sizeof(st.rx_req)) < 0)
        die("PACKET_RX_RING");

    st.rx_ring_sz = (size_t)nr * RX_BLOCK_SIZE;
    st.rx_ring = mmap(NULL, st.rx_ring_sz,
                      PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_LOCKED,
                      st.pkt_fd, 0);
    if (st.rx_ring == MAP_FAILED) die("mmap rx ring");

    /* bind to interface */
    struct sockaddr_ll bind_addr = {
        .sll_family   = AF_PACKET,
        .sll_protocol = htons(ETH_P_IP),
        .sll_ifindex  = ifindex,
    };
    if (bind(st.pkt_fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0)
        die("bind AF_PACKET");

    /* BPF filter: accept only UDP dst=listen_port from any spoof IP */
    /* Without a BPF filter we accept all IP frames; the RX thread filters. */
    /* For now: no filter (avoids dependency on libpcap/bpf assembler). */
}

static void build_tx_template(void)
{
    struct config *c = &st.cfg;
    uint8_t *p = st.tx_tmpl;
    memset(p, 0, OUTER_HDR);

    /* Ethernet header: dst=nexthop gateway MAC, src=own interface MAC */
    memcpy(p + 0, g_dst_mac, ETH_ALEN);   /* bytes 0-5:  dst MAC */
    memcpy(p + 6, g_src_mac, ETH_ALEN);   /* bytes 6-11: src MAC */
    p[12] = 0x08; p[13] = 0x00;           /* EtherType = IPv4 */

    /* IP header at offset 14 */
    uint8_t *ip = p + 14;
    ip[0] = 0x45;           /* version=4, IHL=5 */
    ip[1] = 0x00;           /* DSCP=0 */
    /* total length filled per-frame */
    ip[6] = 0x40;           /* DF bit */
    ip[8] = 64;             /* TTL */
    ip[9] = IPPROTO_UDP;
    /* src IP = spoof (filled per-frame) */
    /* dst IP = peer (filled per-frame) */

    /* UDP header at offset 34 */
    uint8_t *udp = p + 34;
    *(uint16_t *)(udp + 0) = htons((uint16_t)c->listen_port);  /* src port */
    *(uint16_t *)(udp + 2) = htons((uint16_t)c->peer_port);    /* dst port */
    /* length and checksum filled per-frame */
}

/* fill length/checksum fields and spoof IP for one outgoing frame */
static void finalize_frame(uint8_t *frame, int inner_len, uint32_t spoof_be)
{
    struct config *c = &st.cfg;
    int udp_len  = 8 + TUN_HDR_LEN + inner_len;
    int ip_len   = 20 + udp_len;

    uint8_t *ip  = frame + 14;
    uint8_t *udp = frame + 34;

    /* IP total length */
    *(uint16_t *)(ip + 2) = htons((uint16_t)ip_len);
    /* IP identification */
    static atomic_uint ip_id;
    *(uint16_t *)(ip + 4) = htons((uint16_t)atomic_fetch_add(&ip_id, 1));
    /* src/dst IP */
    memcpy(ip + 12, &spoof_be, 4);
    memcpy(ip + 16, &c->peer_ip, 4);
    /* IP checksum */
    *(uint16_t *)(ip + 10) = 0;
    *(uint16_t *)(ip + 10) = ip_csum(ip, 20);

    /* UDP length */
    *(uint16_t *)(udp + 4) = htons((uint16_t)udp_len);
    /* UDP checksum = 0 (legal for IPv4 UDP) */
    *(uint16_t *)(udp + 6) = 0;
}

/* fill tun_hdr at fixed offset inside frame */
static void set_tun_hdr(uint8_t *frame, uint32_t seq, uint16_t path_id)
{
    struct tun_hdr *h = (struct tun_hdr *)(frame + TUN_HDR_OFF);
    h->version = 6;
    h->flags   = 0x01;  /* has_path_id */
    h->path_id = htons(path_id);
    h->seq     = htonl(seq);
    h->ts_ns   = htobe64(now_ns());
}

/* ── multi-spoof ────────────────────────────────────────────────────────── */

static uint32_t active_spoof_be(void)
{
    int idx = atomic_load(&st.active_spoof);
    return st.cfg.spoof_ips[idx];
}

static void maybe_rotate_spoof(uint64_t d_loss, uint64_t d_tx)
{
    struct config *c = &st.cfg;
    if (c->spoof_count <= 1) return;

    int idx = atomic_load(&st.active_spoof);
    float loss_rate = (d_tx > 0) ? (float)d_loss / (float)d_tx : 0.0f;

    if (loss_rate > c->failover_loss) {
        st.spoof_bad[idx]++;
        if (st.spoof_bad[idx] >= c->failover_intervals) {
            int next = (idx + 1) % c->spoof_count;
            atomic_store(&st.active_spoof, next);
            st.spoof_bad[idx] = 0;
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &c->spoof_ips[next], buf, sizeof(buf));
            fprintf(stderr, "[INFO] spoof rotation: idx=%d ip=%s (loss=%.1f%%)\n",
                    next, buf, loss_rate * 100.0f);
        }
    } else {
        st.spoof_bad[idx] = 0;
    }
}

/* ── sequence tracker accounting ───────────────────────────────────────── */

static void account_rx_seq(uint32_t seq)
{
    pthread_mutex_lock(&st.seq_mu);
    struct seq_tracker *t = &st.rx_seq;

    if (!t->valid) {
        t->base  = seq;
        t->high  = seq;
        t->valid = true;
        seq_mark(t, seq);
        pthread_mutex_unlock(&st.seq_mu);
        return;
    }

    int32_t diff = (int32_t)(seq - t->high);
    if (diff > 0) {
        /* new high — advance window, count vacated-but-unseen as lost */
        if (diff > (int32_t)SEQ_WINDOW) {
            /* large jump: count entire window as lost */
            atomic_fetch_add(&st.c_seq_loss, (uint32_t)(diff - 1));
            /* reset window */
            memset(t->seen, 0, sizeof(t->seen));
            t->base = seq - SEQ_WINDOW / 2;
            t->high = seq;
            seq_mark(t, seq);
        } else {
            /* Advance base toward seq - SEQ_WINDOW/2, but never backward.
             * Use signed diff to correctly handle uint32 wraparound. */
            uint32_t target = seq - (uint32_t)(SEQ_WINDOW / 2);
            uint32_t advance_to = ((int32_t)(target - t->base) > 0)
                                  ? target : t->base;
            uint32_t lost = seq_advance(t, advance_to);
            atomic_fetch_add(&st.c_seq_loss, lost);
            t->high = seq;
            seq_mark(t, seq);
        }
    } else if (diff == 0) {
        /* duplicate */
        pthread_mutex_unlock(&st.seq_mu);
        return;
    } else {
        /* reorder or late duplicate */
        if (seq_seen(t, seq)) {
            pthread_mutex_unlock(&st.seq_mu);
            return; /* duplicate */
        }
        seq_mark(t, seq);
        atomic_fetch_add(&st.c_reorder, 1);
    }
    pthread_mutex_unlock(&st.seq_mu);
}

/* ── TCP connection management ──────────────────────────────────────────── */

static int tcp_wait_connected(void)
{
    pthread_mutex_lock(&st.tcp_mu);
    while (st.running && st.tcp_fd < 0)
        pthread_cond_wait(&st.tcp_cv, &st.tcp_mu);
    int fd = st.tcp_fd;
    pthread_mutex_unlock(&st.tcp_mu);
    return fd;
}

static void tcp_close_conn(void)
{
    pthread_mutex_lock(&st.tcp_mu);
    if (st.tcp_fd >= 0) {
        close(st.tcp_fd);
        st.tcp_fd = -1;
    }
    pthread_mutex_unlock(&st.tcp_mu);
}

/* Close only if we're holding the fd we expect — prevents the TX thread from
 * closing a newly-reconnected fd that the RX thread just established. */
static void tcp_close_conn_if(int fd)
{
    pthread_mutex_lock(&st.tcp_mu);
    if (st.tcp_fd == fd) {
        close(st.tcp_fd);
        st.tcp_fd = -1;
    }
    pthread_mutex_unlock(&st.tcp_mu);
}

/* called by RX TCP thread to establish/re-establish connection */
static void tcp_connect_loop(void)
{
    struct config *c = &st.cfg;

    while (st.running) {
        /* declare ts before any goto so we never jump over its initialization */
        struct timespec ts = { .tv_nsec = TCP_RECONNECT_MS * 1000000L };
        int fd = -1;
        int one;
        if (c->mode == MODE_CLIENT) {
            fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
            if (fd < 0) { perror("tcp socket"); goto retry; }
            one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            struct sockaddr_in peer = {
                .sin_family      = AF_INET,
                .sin_addr.s_addr = c->peer_ip,
                .sin_port        = htons((uint16_t)c->peer_port),
            };
            if (connect(fd, (struct sockaddr *)&peer, sizeof(peer)) < 0) {
                close(fd); fd = -1;
                goto retry;
            }
            fprintf(stderr, "[INFO] TCP connected to peer\n");
        } else {
            /* server: listen + accept */
            int lfd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
            if (lfd < 0) { perror("tcp listen socket"); goto retry; }
            one = 1;
            setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            struct sockaddr_in local = {
                .sin_family      = AF_INET,
                .sin_addr.s_addr = INADDR_ANY,
                .sin_port        = htons((uint16_t)c->listen_port),
            };
            if (bind(lfd, (struct sockaddr *)&local, sizeof(local)) < 0 ||
                listen(lfd, 1) < 0) {
                close(lfd); goto retry;
            }
            fd = accept(lfd, NULL, NULL);
            close(lfd);
            if (fd < 0) goto retry;
            one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            fprintf(stderr, "[INFO] TCP client accepted\n");
        }

        pthread_mutex_lock(&st.tcp_mu);
        if (st.tcp_fd >= 0) close(st.tcp_fd);
        st.tcp_fd = fd;
        pthread_cond_broadcast(&st.tcp_cv);
        pthread_mutex_unlock(&st.tcp_mu);
        return;

retry:
        nanosleep(&ts, NULL);
    }
}

/* ── TX thread — UDP mode ───────────────────────────────────────────────── */

static void *tx_thread_udp(void *arg)
{
    (void)arg;
    pin_cpu(st.cfg.tx_cpu);

    int batch = st.cfg.batch_size;
    uint8_t **bufs = malloc((size_t)batch * sizeof(uint8_t *));
    struct mmsghdr *msgs = calloc((size_t)batch, sizeof(*msgs));
    struct iovec *iovs = calloc((size_t)batch * 2, sizeof(*iovs));
    if (!bufs || !msgs || !iovs) die("tx_thread_udp malloc");

    for (int i = 0; i < batch; i++) {
        bufs[i] = malloc(MAX_FRAME);
        if (!bufs[i]) die("tx buf malloc");
        memcpy(bufs[i], st.tx_tmpl, OUTER_HDR);
        /* iov[0]: outer header; iov[1]: inner packet */
        iovs[i*2+0].iov_base = bufs[i];
        iovs[i*2+0].iov_len  = OUTER_HDR;
        iovs[i*2+1].iov_base = bufs[i] + OUTER_HDR;
        /* iov[1].iov_len set per packet */
        msgs[i].msg_hdr.msg_iov    = &iovs[i*2];
        msgs[i].msg_hdr.msg_iovlen = 2;
        msgs[i].msg_hdr.msg_name   = &st.tx_addr;
        msgs[i].msg_hdr.msg_namelen = sizeof(st.tx_addr);
    }

    static atomic_uint tx_seq;
    int retry_backoff_ns = 1000000; /* 1 ms */

    while (st.running) {
        int n = 0;
        while (n < batch && st.running) {
            uint8_t *inner = bufs[n] + OUTER_HDR;
            if (n > 0) {
                /* try to coalesce more packets without blocking */
                struct pollfd pfd = { .fd = st.tun_fd, .events = POLLIN };
                if (poll(&pfd, 1, 0) <= 0)
                    break;  /* nothing ready: send partial batch now */
            }
            ssize_t r = read(st.tun_fd, inner, (size_t)(st.cfg.mtu));
            if (r <= 0) {
                if (errno == EINTR) continue;
                atomic_fetch_add(&st.c_tun_rerr, 1);
                continue;
            }
            uint32_t seq = atomic_fetch_add(&tx_seq, 1);
            uint16_t pid = (uint16_t)atomic_load(&st.active_spoof);
            uint32_t spoof = active_spoof_be();
            memcpy(bufs[n], st.tx_tmpl, OUTER_HDR);
            set_tun_hdr(bufs[n], seq, pid);
            finalize_frame(bufs[n], (int)r, spoof);
            iovs[n*2+0].iov_len = OUTER_HDR;
            iovs[n*2+1].iov_base = inner;
            iovs[n*2+1].iov_len = (size_t)r;
            n++;
        }
        if (n == 0) continue;

        int sent = 0;
        while (sent < n && st.running) {
            int ret = sendmmsg(st.pkt_fd, msgs + sent, (unsigned)(n - sent), 0);
            if (ret < 0) {
                if (errno == EAGAIN || errno == ENOBUFS) {
                    atomic_fetch_add(&st.c_tx_retry, 1);
                    struct timespec ts = { .tv_nsec = retry_backoff_ns };
                    nanosleep(&ts, NULL);
                    retry_backoff_ns = retry_backoff_ns < 8000000
                                       ? retry_backoff_ns * 2 : 8000000;
                } else {
                    atomic_fetch_add(&st.c_tx_err, 1);
                    break;
                }
            } else {
                retry_backoff_ns = 1000000; /* reset on success */
                for (int i = sent; i < sent + ret; i++) {
                    atomic_fetch_add(&st.c_tx_pkts, 1);
                    atomic_fetch_add(&st.c_tx_bytes,
                                     iovs[i*2+0].iov_len + iovs[i*2+1].iov_len);
                }
                sent += ret;
            }
        }
    }
    return NULL;
}

/* ── TX thread — TCP mode ───────────────────────────────────────────────── */

static void *tx_thread_tcp(void *arg)
{
    (void)arg;
    pin_cpu(st.cfg.tx_cpu);

    uint8_t *buf = malloc((size_t)(2 + TUN_HDR_LEN + st.cfg.mtu + 64));
    if (!buf) die("tx_thread_tcp malloc");

    static atomic_uint tx_seq_tcp;

    while (st.running) {
        uint8_t *inner = buf + 2 + TUN_HDR_LEN;
        ssize_t r = read(st.tun_fd, inner, (size_t)st.cfg.mtu);
        if (r <= 0) {
            if (errno == EINTR) continue;
            atomic_fetch_add(&st.c_tun_rerr, 1);
            continue;
        }

        uint32_t seq = atomic_fetch_add(&tx_seq_tcp, 1);
        uint16_t pid = (uint16_t)atomic_load(&st.active_spoof);
        struct tun_hdr *h = (struct tun_hdr *)(buf + 2);
        h->version = 6;
        h->flags   = 0x01;
        h->path_id = htons(pid);
        h->seq     = htonl(seq);
        h->ts_ns   = htobe64(now_ns());

        uint16_t frame_len = (uint16_t)(TUN_HDR_LEN + r);
        buf[0] = (uint8_t)(frame_len >> 8);
        buf[1] = (uint8_t)(frame_len & 0xff);

        int fd = tcp_wait_connected();
        if (fd < 0) continue;

        ssize_t total = 2 + frame_len;
        ssize_t w = send(fd, buf, (size_t)total, MSG_NOSIGNAL);
        if (w != total) {
            tcp_close_conn_if(fd);  /* only close if still our fd */
            atomic_fetch_add(&st.c_tx_err, 1);
        } else {
            atomic_fetch_add(&st.c_tx_pkts, 1);
            atomic_fetch_add(&st.c_tx_bytes, (uint64_t)total);
        }
    }
    return NULL;
}

/* ── RX thread — UDP mode ───────────────────────────────────────────────── */

static void *rx_thread_udp(void *arg)
{
    (void)arg;
    pin_cpu(st.cfg.rx_cpu);

    uint8_t   *ring    = st.rx_ring;
    uint32_t   nr      = st.rx_req.tp_block_nr;
    uint32_t   blk_sz  = st.rx_req.tp_block_size;
    uint32_t   cur_blk = 0;
    struct timespec spin_ts = { .tv_nsec = 100000 }; /* 100 µs */

    while (st.running) {
        struct tpacket_block_desc *bd =
            (struct tpacket_block_desc *)(ring + (size_t)cur_blk * (size_t)blk_sz);

        /* spin-wait for block to be ready */
        while (!(bd->hdr.bh1.block_status & TP_STATUS_USER)) {
            if (!st.running) return NULL;
            nanosleep(&spin_ts, NULL);
        }

        uint32_t  nframes   = bd->hdr.bh1.num_pkts;
        uint8_t  *frame_ptr = (uint8_t *)bd + bd->hdr.bh1.offset_to_first_pkt;

        for (uint32_t i = 0; i < nframes; i++) {
            /* Declare ALL locals before any goto to avoid -Wjump-misses-init */
            struct tpacket3_hdr *th;
            struct tun_hdr       h_val;
            uint8_t *pkt, *ip, *udp, *payload, *inner;
            uint32_t src_ip, seq;
            int      pkt_len, pay_len, inner_len;
            bool     known;
            ssize_t  w;
            int      j;

            th      = (struct tpacket3_hdr *)frame_ptr;
            pkt     = frame_ptr + th->tp_mac;
            pkt_len = (int)th->tp_snaplen;

            if (pkt_len < 14 + 20 + 8 + TUN_HDR_LEN + 1) goto next_frame;
            if (pkt[12] != 0x08 || pkt[13] != 0x00) goto next_frame;

            ip = pkt + 14;
            if (ip[9] != IPPROTO_UDP) goto next_frame;

            udp = ip + (ip[0] & 0x0f) * 4;
            if (ntohs(*(const uint16_t *)(udp + 2)) != (uint16_t)st.cfg.listen_port)
                goto next_frame;

            memcpy(&src_ip, ip + 12, 4);
            known = false;
            for (j = 0; j < st.cfg.spoof_count; j++) {
                if (st.cfg.spoof_ips[j] == src_ip) { known = true; break; }
            }
            if (!known) {
                atomic_fetch_add(&st.c_rx_bad, 1);
                goto next_frame;
            }

            payload = udp + 8;
            pay_len = pkt_len - (int)(payload - pkt);
            if (pay_len < TUN_HDR_LEN + 1) goto next_frame;

            /* memcpy avoids unaligned pointer cast to packed struct */
            memcpy(&h_val, payload, sizeof(h_val));
            if (h_val.version != 6) goto next_frame;

            seq = ntohl(h_val.seq);
            account_rx_seq(seq);

            inner     = payload + TUN_HDR_LEN;
            inner_len = pay_len - TUN_HDR_LEN;

            w = write(st.tun_fd, inner, (size_t)inner_len);
            if (w < 0) atomic_fetch_add(&st.c_tun_werr, 1);
            else {
                atomic_fetch_add(&st.c_rx_pkts, 1);
                atomic_fetch_add(&st.c_rx_bytes, (uint64_t)inner_len);
            }

next_frame:
            frame_ptr += th->tp_next_offset ? th->tp_next_offset
                                            : RX_FRAME_SIZE;
        }

        /* return block to kernel */
        bd->hdr.bh1.block_status = TP_STATUS_KERNEL;
        cur_blk = (cur_blk + 1) % nr;
    }
    return NULL;
}

/* ── RX thread — TCP mode ───────────────────────────────────────────────── */

static bool tcp_read_exact(int fd, uint8_t *buf, int len)
{
    int off = 0;
    while (off < len) {
        ssize_t r = recv(fd, buf + off, (size_t)(len - off), 0);
        if (r <= 0) return false;
        off += (int)r;
    }
    return true;
}

static void *rx_thread_tcp(void *arg)
{
    (void)arg;
    pin_cpu(st.cfg.rx_cpu);

    uint8_t hdr[2 + TUN_HDR_LEN];
    uint8_t *payload = malloc((size_t)(st.cfg.mtu + 64));
    if (!payload) die("rx_thread_tcp malloc");

    while (st.running) {
        tcp_connect_loop();  /* blocks until connected */
        int fd = st.tcp_fd;
        if (fd < 0) continue;

        while (st.running) {
            struct tun_hdr h_val;
            uint16_t frame_len;
            int      inner_len;

            /* read 2-byte length */
            if (!tcp_read_exact(fd, hdr, 2)) break;
            frame_len = (uint16_t)((hdr[0] << 8) | hdr[1]);
            if (frame_len < TUN_HDR_LEN + 1 ||
                frame_len > (uint16_t)(TUN_HDR_LEN + st.cfg.mtu + 64)) break;

            /* read tun_hdr via memcpy to avoid unaligned packed-struct cast */
            if (!tcp_read_exact(fd, hdr + 2, TUN_HDR_LEN)) break;
            memcpy(&h_val, hdr + 2, sizeof(h_val));
            if (h_val.version != 6) break;

            inner_len = frame_len - TUN_HDR_LEN;
            if (!tcp_read_exact(fd, payload, inner_len)) break;

            uint32_t seq = ntohl(h_val.seq);
            account_rx_seq(seq);

            ssize_t w = write(st.tun_fd, payload, (size_t)inner_len);
            if (w < 0) atomic_fetch_add(&st.c_tun_werr, 1);
            else {
                atomic_fetch_add(&st.c_rx_pkts, 1);
                atomic_fetch_add(&st.c_rx_bytes, (uint64_t)inner_len);
            }
        }
        tcp_close_conn();
    }
    return NULL;
}

/* ── metrics thread ─────────────────────────────────────────────────────── */

static void write_health_json(uint64_t tx_pps, uint64_t rx_pps,
                               float loss_pct, bool qdisc_ok)
{
    FILE *f = fopen(health_tmp, "we");
    if (!f) return;
    fprintf(f, "{"
            "\"ts\":%llu,"
            "\"up\":1,"
            "\"tx_pps\":%llu,"
            "\"rx_pps\":%llu,"
            "\"loss_pct\":%.3f,"
            "\"qdisc_ok\":%s,"
            "\"version\":\"%s\""
            "}\n",
            (unsigned long long)now_ms(),
            (unsigned long long)tx_pps,
            (unsigned long long)rx_pps,
            (double)loss_pct,
            qdisc_ok ? "true" : "false",
            VERSION);
    fclose(f);
    rename(health_tmp, health_path);
}

static void append_metrics_jsonl(uint64_t d_tx, uint64_t d_rx,
                                  uint64_t d_tx_b, uint64_t d_rx_b,
                                  uint64_t d_loss, uint64_t d_reorder,
                                  uint64_t d_retry, int interval_s)
{
    FILE *f = fopen(metrics_path, "ae");
    if (!f) return;
    fprintf(f, "{"
            "\"ts\":%llu,"
            "\"tx_pkts\":%llu,\"rx_pkts\":%llu,"
            "\"tx_mbps\":%.2f,\"rx_mbps\":%.2f,"
            "\"seq_loss\":%llu,\"reorder\":%llu,"
            "\"tx_retry\":%llu,"
            "\"tx_err\":%llu,\"tun_werr\":%llu"
            "}\n",
            (unsigned long long)now_ms(),
            (unsigned long long)d_tx,
            (unsigned long long)d_rx,
            (double)(d_tx_b * 8) / (1e6 * interval_s),
            (double)(d_rx_b * 8) / (1e6 * interval_s),
            (unsigned long long)d_loss,
            (unsigned long long)d_reorder,
            (unsigned long long)d_retry,
            (unsigned long long)atomic_load(&st.c_tx_err),
            (unsigned long long)atomic_load(&st.c_tun_werr));
    fclose(f);
}

static void *metrics_thread(void *arg)
{
    (void)arg;
    struct config *c = &st.cfg;
    int interval = c->metric_interval > 0 ? c->metric_interval : METRIC_INTERVAL;
    int watchdog_every = (c->watchdog_sec > 0)
                         ? (c->watchdog_sec / WATCHDOG_DIVISOR) : interval;

    int tick = 0;
    while (st.running) {
        struct timespec ts = { .tv_sec = interval };
        nanosleep(&ts, NULL);

        uint64_t tx_pkts = atomic_load(&st.c_tx_pkts);
        uint64_t rx_pkts = atomic_load(&st.c_rx_pkts);
        uint64_t tx_b    = atomic_load(&st.c_tx_bytes);
        uint64_t rx_b    = atomic_load(&st.c_rx_bytes);
        uint64_t loss    = atomic_load(&st.c_seq_loss);
        uint64_t reorder = atomic_load(&st.c_reorder);
        uint64_t retry   = atomic_load(&st.c_tx_retry);

        uint64_t d_tx    = tx_pkts - st.snap_tx_pkts;
        uint64_t d_rx    = rx_pkts - st.snap_rx_pkts;
        uint64_t d_tx_b  = tx_b    - st.snap_tx_bytes;
        uint64_t d_rx_b  = rx_b    - st.snap_rx_bytes;
        uint64_t d_loss  = loss    - st.snap_seq_loss;
        uint64_t d_ror   = reorder - st.snap_reorder;
        uint64_t d_retry = retry   - st.snap_tx_retry;

        st.snap_tx_pkts  = tx_pkts;
        st.snap_rx_pkts  = rx_pkts;
        st.snap_tx_bytes = tx_b;
        st.snap_rx_bytes = rx_b;
        st.snap_seq_loss = loss;
        st.snap_reorder  = reorder;
        st.snap_tx_retry = retry;

        float loss_pct = (d_rx + d_loss > 0)
                         ? (float)d_loss / (float)(d_rx + d_loss) * 100.0f : 0.0f;

        /* plain metric line (compatible with v5 monitoring scripts) */
        printf("metric tx_pkts=%llu rx_pkts=%llu "
               "tx_mbps=%.2f rx_mbps=%.2f "
               "seq_loss=%llu reorder=%llu "
               "tx_retry=%llu tx_err=%llu "
               "tun_werr=%llu active_spoof=%d\n",
               (unsigned long long)d_tx, (unsigned long long)d_rx,
               (double)(d_tx_b * 8) / (1e6 * interval),
               (double)(d_rx_b * 8) / (1e6 * interval),
               (unsigned long long)d_loss, (unsigned long long)d_ror,
               (unsigned long long)d_retry,
               (unsigned long long)atomic_load(&st.c_tx_err),
               (unsigned long long)atomic_load(&st.c_tun_werr),
               atomic_load(&st.active_spoof));
        fflush(stdout);

        /* JSON metrics line */
        if (c->json_metrics) {
            append_metrics_jsonl(d_tx, d_rx, d_tx_b, d_rx_b,
                                 d_loss, d_ror, d_retry, interval);
        }

        /* health.json */
        uint64_t tx_pps = d_tx / (uint64_t)interval;
        uint64_t rx_pps = d_rx / (uint64_t)interval;
        write_health_json(tx_pps, rx_pps, loss_pct, true);

        /* multi-spoof failover check */
        maybe_rotate_spoof(d_loss, d_tx);

        /* forced rotate via SIGUSR2 */
        if (st.force_rotate && c->spoof_count > 1) {
            int idx = (atomic_load(&st.active_spoof) + 1) % c->spoof_count;
            atomic_store(&st.active_spoof, idx);
            st.force_rotate = 0;
            fprintf(stderr, "[INFO] manual spoof rotate → idx=%d\n", idx);
        }

        /* watchdog */
        tick++;
        if (tick * interval >= watchdog_every) {
            sd_notify_str("WATCHDOG=1");
            tick = 0;
        }
    }
    return NULL;
}

/* ── signal handling ────────────────────────────────────────────────────── */

static void sig_stop(int s) { (void)s; st.running = 0; }
static void sig_usr1(int s) { (void)s; /* dump: nothing extra needed */ }
static void sig_usr2(int s) { (void)s; st.force_rotate = 1; }

/* ── argument parsing ───────────────────────────────────────────────────── */

static void usage(const char *name)
{
    fprintf(stderr,
        "usage: %s [options]\n"
        "  --mode client|server\n"
        "  --name NAME          instance name; puts health.json and\n"
        "                       metrics.jsonl under a per-instance dir\n"
        "  --outer udp|tcp\n"
        "  --iface NAME         physical interface (UDP mode)\n"
        "  --tun NAME           TUN device name (default: tun0)\n"
        "  --spoof-ips IP[,...] spoof source IP(s), comma-separated\n"
        "  --peer-ip IP         peer's real IP address\n"
        "  --local-tun IP       local TUN IP\n"
        "  --peer-tun IP        peer TUN IP\n"
        "  --listen-port PORT   (default: %d)\n"
        "  --peer-port PORT     (default: %d)\n"
        "  --mtu N              inner MTU (default: %d)\n"
        "  --tx-cpu N           TX thread CPU pin (-1 = no pin)\n"
        "  --rx-cpu N           RX thread CPU pin (-1 = no pin)\n"
        "  --rate-mbps N        TX pacing rate in Mbps (UDP mode)\n"
        "  --flow-limit N       fq per-flow queue limit\n"
        "  --batch-size N       TX batch size (default: %d, UDP mode)\n"
        "  --rx-block-nr N      TPACKET_V3 block count (default: %d)\n"
        "  --failover-loss F    loss fraction to trigger spoof rotation (0.0-1.0)\n"
        "  --failover-intervals N  consecutive bad intervals before rotation\n"
        "  --metric-interval N  metrics output interval in seconds (default: %d)\n"
        "  --json-metrics       append JSON lines to " METRICS_JSONL "\n"
        "  --watchdog-sec N     systemd WatchdogSec value\n",
        name,
        DEFAULT_PORT, DEFAULT_PORT, DEFAULT_MTU, DEFAULT_BATCH,
        RX_BLOCK_NR_DEF, METRIC_INTERVAL);
    exit(1);
}

static uint32_t parse_ip(const char *s, const char *field)
{
    struct in_addr a;
    if (!inet_aton(s, &a)) {
        fprintf(stderr, "invalid IP for %s: %s\n", field, s);
        exit(1);
    }
    return a.s_addr; /* network byte order */
}

static void parse_args(int argc, char **argv)
{
    struct config *c = &st.cfg;
    /* defaults */
    c->outer              = OUTER_UDP;
    c->listen_port        = DEFAULT_PORT;
    c->peer_port          = DEFAULT_PORT;
    c->mtu                = DEFAULT_MTU;
    c->tx_cpu             = -1;
    c->rx_cpu             = -1;
    c->batch_size         = DEFAULT_BATCH;
    c->rx_block_nr        = RX_BLOCK_NR_DEF;
    c->failover_loss      = 0.05f;
    c->failover_intervals = 3;
    c->metric_interval    = METRIC_INTERVAL;
    c->json_metrics       = false;
    c->watchdog_sec       = 0;
    snprintf(c->tun_name, IFNAMSIZ, "%s", "tun0");
    c->name[0] = 0;

    for (int i = 1; i < argc; i++) {
#define NEED_ARG() if (i+1 >= argc) { fprintf(stderr, "%s requires arg\n", argv[i]); exit(1); }
        if (!strcmp(argv[i], "--mode")) {
            NEED_ARG(); i++;
            c->mode = !strcmp(argv[i], "server") ? MODE_SERVER : MODE_CLIENT;
        } else if (!strcmp(argv[i], "--outer")) {
            NEED_ARG(); i++;
            c->outer = !strcmp(argv[i], "tcp") ? OUTER_TCP : OUTER_UDP;
        } else if (!strcmp(argv[i], "--iface")) {
            NEED_ARG(); i++;
            snprintf(c->iface, IFNAMSIZ, "%s", argv[i]);
        } else if (!strcmp(argv[i], "--tun")) {
            NEED_ARG(); i++;
            snprintf(c->tun_name, IFNAMSIZ, "%s", argv[i]);
        } else if (!strcmp(argv[i], "--name")) {
            NEED_ARG(); i++;
            snprintf(c->name, MAX_NAME, "%s", argv[i]);
        } else if (!strcmp(argv[i], "--spoof-ips")) {
            NEED_ARG(); i++;
            char *tok = strtok(argv[i], ",");
            while (tok && c->spoof_count < MAX_SPOOF) {
                c->spoof_ips[c->spoof_count++] = parse_ip(tok, "--spoof-ips");
                tok = strtok(NULL, ",");
            }
        } else if (!strcmp(argv[i], "--peer-ip")) {
            NEED_ARG(); i++;
            c->peer_ip = parse_ip(argv[i], "--peer-ip");
        } else if (!strcmp(argv[i], "--local-tun")) {
            NEED_ARG(); i++;
            c->local_tun = parse_ip(argv[i], "--local-tun");
        } else if (!strcmp(argv[i], "--peer-tun")) {
            NEED_ARG(); i++;
            c->peer_tun = parse_ip(argv[i], "--peer-tun");
        } else if (!strcmp(argv[i], "--listen-port")) {
            NEED_ARG(); i++;
            c->listen_port = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--peer-port")) {
            NEED_ARG(); i++;
            c->peer_port = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--mtu")) {
            NEED_ARG(); i++;
            c->mtu = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--tx-cpu")) {
            NEED_ARG(); i++;
            c->tx_cpu = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--rx-cpu")) {
            NEED_ARG(); i++;
            c->rx_cpu = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--rate-mbps")) {
            NEED_ARG(); i++;
            c->rate_mbps = atol(argv[i]);
        } else if (!strcmp(argv[i], "--flow-limit")) {
            NEED_ARG(); i++;
            c->flow_limit = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--batch-size")) {
            NEED_ARG(); i++;
            c->batch_size = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--rx-block-nr")) {
            NEED_ARG(); i++;
            c->rx_block_nr = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--failover-loss")) {
            NEED_ARG(); i++;
            c->failover_loss = strtof(argv[i], NULL);
        } else if (!strcmp(argv[i], "--failover-intervals")) {
            NEED_ARG(); i++;
            c->failover_intervals = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--metric-interval")) {
            NEED_ARG(); i++;
            c->metric_interval = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--json-metrics")) {
            c->json_metrics = true;
        } else if (!strcmp(argv[i], "--watchdog-sec")) {
            NEED_ARG(); i++;
            c->watchdog_sec = atoi(argv[i]);
        } else if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-V")) {
            printf("spoof-tunnel %s\n", VERSION);
            exit(0);
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(argv[0]);
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            usage(argv[0]);
        }
#undef NEED_ARG
    }

    /* validate required fields */
    if (!c->spoof_count && c->outer == OUTER_UDP) {
        fprintf(stderr, "--spoof-ips required for UDP mode\n"); exit(1);
    }
    if (!c->peer_ip) {
        fprintf(stderr, "--peer-ip required\n"); exit(1);
    }
    if (!c->local_tun || !c->peer_tun) {
        fprintf(stderr, "--local-tun and --peer-tun required\n"); exit(1);
    }
    if (c->outer == OUTER_UDP && !c->iface[0]) {
        fprintf(stderr, "--iface required for UDP mode\n"); exit(1);
    }
    if (c->batch_size < 1) c->batch_size = DEFAULT_BATCH;
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
    parse_args(argc, argv);

    /* Runtime paths. An instance name gives each tunnel its own directory;
     * without one the flat legacy paths are kept. */
    mkdir(RUN_DIR, 0755);
    mkdir(LOG_DIR, 0755);
    if (st.cfg.name[0]) {
        snprintf(health_path,  sizeof health_path,
                 RUN_DIR "/%s/health.json", st.cfg.name);
        snprintf(health_tmp,   sizeof health_tmp,
                 RUN_DIR "/%s/health.json.tmp", st.cfg.name);
        snprintf(metrics_path, sizeof metrics_path,
                 LOG_DIR "/%s/metrics.jsonl", st.cfg.name);
        char dir[256];
        snprintf(dir, sizeof dir, RUN_DIR "/%s", st.cfg.name);
        mkdir(dir, 0755);
        snprintf(dir, sizeof dir, LOG_DIR "/%s", st.cfg.name);
        mkdir(dir, 0755);
    }

    /* signals */
    st.running = 1;
    signal(SIGTERM, sig_stop);
    signal(SIGINT,  sig_stop);
    signal(SIGUSR1, sig_usr1);
    signal(SIGUSR2, sig_usr2);
    signal(SIGPIPE, SIG_IGN);

    pthread_mutex_init(&st.seq_mu, NULL);
    pthread_mutex_init(&st.tcp_mu, NULL);
    pthread_cond_init(&st.tcp_cv, NULL);
    st.tcp_fd = -1;

    /* TUN device */
    st.tun_fd = tun_open(st.cfg.tun_name, st.cfg.mtu);
    tun_set_addr(st.cfg.tun_name, st.cfg.local_tun, st.cfg.peer_tun);

    /* transport-specific setup */
    if (st.cfg.outer == OUTER_UDP) {
        udp_setup();
        build_tx_template();
    }

    /* announce ready to systemd */
    sd_notify_str("READY=1\nSTATUS=tunnel running\n");
    if (st.cfg.watchdog_sec > 0) {
        char msg[64];
        snprintf(msg, sizeof(msg), "WATCHDOG_USEC=%lld\n",
                 (long long)st.cfg.watchdog_sec * 1000000LL);
        sd_notify_str(msg);
    }

    fprintf(stderr, "[INFO] spoof-tunnel-v6 starting: outer=%s mode=%s spoof_count=%d\n",
            st.cfg.outer == OUTER_UDP ? "udp" : "tcp",
            st.cfg.mode == MODE_SERVER ? "server" : "client",
            st.cfg.spoof_count);

    /* launch threads */
    pthread_t tx_tid, rx_tid, met_tid;
    void *(*tx_fn)(void *) = (st.cfg.outer == OUTER_UDP)
                             ? tx_thread_udp : tx_thread_tcp;
    void *(*rx_fn)(void *) = (st.cfg.outer == OUTER_UDP)
                             ? rx_thread_udp : rx_thread_tcp;

    if (pthread_create(&tx_tid,  NULL, tx_fn,        NULL) ||
        pthread_create(&rx_tid,  NULL, rx_fn,        NULL) ||
        pthread_create(&met_tid, NULL, metrics_thread, NULL))
        die("pthread_create");

    pthread_join(tx_tid,  NULL);
    pthread_join(rx_tid,  NULL);
    pthread_join(met_tid, NULL);

    /* update health.json to reflect clean shutdown */
    FILE *f = fopen(health_path, "we");
    if (f) { fprintf(f, "{\"up\":0,\"ts\":%llu}\n",
                     (unsigned long long)now_ms()); fclose(f); }

    sd_notify_str("STOPPING=1\n");
    return 0;
}
