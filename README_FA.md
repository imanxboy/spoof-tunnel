# spoof-tunnel

یک تونل UDP با کارایی بالا که ترافیک پراکسی اوورلی (Xray، VLESS، VMess و غیره)
را بین دو سرور منتقل می‌کند و در عین حال پکت‌های خارجی را طوری نشان می‌دهد
که انگار از یک IP دیگر (مثل CDN) فرستاده شده‌اند.

---

## معماری

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                          spoof-tunnel                                │
  │                                                                      │
  │  کاربران (ایران)          سرور کلاینت (داخلی)    سرور سرور (خارجی) │
  │  ────────────────          ─────────────────────  ──────────────────  │
  │  مرورگر / اپلیکیشن         tun0: 10.x.x.2         tun0: 10.x.x.1   │
  │      │                       │                         │             │
  │      │ TCP:443  ───────────► iptables DNAT             │             │
  │      │                       │ → tun0                  │             │
  │      │               ┌───────┴───────────────┐         │             │
  │      │               │   spoof-tunnel         │         │             │
  │      │               │   TUN → AF_PACKET TX   │────────►│             │
  │      │               │   src IP: آدرس جعلی   │  UDP    │             │
  │      │               │   AF_PACKET RX → TUN   │◄────────┤             │
  │      │               └───────────────────────-┘         │             │
  │      │                                         Xray/VLESS → اینترنت  │
  └──────────────────────────────────────────────────────────────────────┘
```

**نحوه عملکرد:**

۱. کاربران به سرور کلاینت (ایران) روی پورت اوورلی (مثلاً ۴۴۳) وصل می‌شوند.
۲. قانون iptables DNAT ترافیک را به رابط `tun0` هدایت می‌کند.
۳. `spoof-tunnel` پکت‌ها را از `tun0` می‌خواند، آن‌ها را در یک فریم UDP خام
   با **IP منبع جعلی** می‌پیچد و از طریق `AF_PACKET` روی سیم ارسال می‌کند.
۴. سرور خارجی فریم را دریافت می‌کند، هدر خارجی را حذف می‌کند، و پکت داخلی
   را به `tun0` می‌نویسد تا Xray آن را پردازش کند.
۵. ترافیک برگشتی همین مسیر را به صورت معکوس طی می‌کند.

---

## پیش‌نیازها

- لینوکس کرنل ≥ ۴.۱۴
- `gcc`، `python3`، `iproute2`، `iptables`، `systemd`
- دسترسی root روی هر دو سرور
- پورت UDP باز بین دو سرور (پیش‌فرض: ۲۰۸۰)

---

## نصب سریع

### نصب با یک دستور (هر دو سرور)

```bash
curl -fsSL https://raw.githubusercontent.com/imanxboy/spoof-tunnel/main/scripts/install.sh \
    | sudo bash
```

نصب‌کننده:
۱. وابستگی‌های سیستم را نصب می‌کند (`gcc`، `python3` و غیره)
۲. آخرین نسخه را دانلود و کامپایل می‌کند
۳. اگر config وجود نداشته باشد، **ویزارد تنظیمات** را اجرا می‌کند
۴. سرویس را نصب و راه‌اندازی می‌کند

**ابتدا روی سرور خارجی نصب کنید، سپس روی کلاینت داخلی.**

### نصب دستی

```bash
git clone https://github.com/imanxboy/spoof-tunnel
cd spoof-tunnel
sudo bash scripts/setup-wizard.sh   # ایجاد config.yaml
sudo bash install.sh                # ساخت، نصب، و راه‌اندازی سرویس
```

---

## پیکربندی

ویزارد فایل `config.yaml` را می‌نویسد. فیلدهای اصلی:

```yaml
tunnel:
  role: client        # "client" (سرور داخلی) یا "server" (سرور خارجی)
  peer_address: 1.2.3.4  # IP عمومی سرور مقابل

spoof:
  addresses:
    - ip-spoof-example   # IP‌های جعلی برای پکت‌های خارجی (حالت کلاینت)

network:
  interface: eth0
  tun_name: tun0
  local_tun_ip: 10.100.100.2
  peer_tun_ip:  10.100.100.1

performance:
  rate_mbps: 1000

# فقط برای کلاینت — پورت‌هایی که از طریق تونل به سرور فوروارد می‌شوند
forwarding:
  ports:
    - 443
    # - 80
    # - 2053
```

فایل [`config.yaml.example`](config.yaml.example) همه گزینه‌ها با توضیحات را دارد.

پس از ویرایش config.yaml:

```bash
sudo bash install.sh --config-only   # اعمال بدون راه‌اندازی مجدد کامل
# یا:
spoofctl edit-config
```

---

## فوروارد پورت (سرور کلاینت)

روی سرور **کلاینت** (داخلی)، اتصال‌های ورودی کاربران باید از طریق تونل به
سرویس پراکسی روی سرور خارجی هدایت شوند. ویزارد نصب این را به صورت خودکار
تنظیم می‌کند. همچنین می‌توانید مستقیماً در `config.yaml` تنظیم کنید:

```yaml
forwarding:
  ports:
    - 443    # Xray/VLESS
    - 80     # اختیاری
    - 2053   # DNS-over-HTTPS
```

برای هر پورت N، نصب‌کننده هم TCP و هم UDP را فوروارد می‌کند:

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.100.100.1:443
iptables -t nat -A PREROUTING -p udp --dport 443 -j DNAT --to-destination 10.100.100.1:443
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
```

**مسیر پکت:**
```
کاربر → eth0 کلاینت → DNAT → FORWARD → MASQUERADE → tun0 → تونل → tun0 سرور → Xray
```

قانون MASQUERADE ضروری است: IP واقعی کاربر را با IP TUN کلاینت (`10.100.100.2`)
جایگزین می‌کند تا سرور پاسخ‌ها را از طریق تونل برگرداند، نه مستقیم به اینترنت.

قوانین در هر بار شروع سرویس نصب می‌شوند و پس از ریبوت باقی می‌مانند.
در هنگام حذف نصب، پاک‌سازی کامل انجام می‌شود.

**پرامپت ویزارد (سرورهای کلاینت):**
```
  Step 9 of 9 — Port Forwarding

  Enable port forwarding? [Y/n]: y
  Ports to forward [443]: 443,80
```

**مدیریت پس از نصب:**
```bash
spoofctl forward-rules   # به‌روزرسانی لیست پورت‌ها و اعمال مجدد قوانین
spoofctl status          # نمایش پورت‌های فوروارد شده و وضعیت NAT
```

**خروجی `spoofctl status` (کلاینت):**
```
  Forwarded ports  → 10.100.100.1 (TCP+UDP each):
    :443 → 10.100.100.1:443
    :80  → 10.100.100.1:80
  NAT state:       2 DNAT, 1 MASQUERADE, 2 FORWARD ACCEPT
```

**سرور خارجی:** نیازی به تنظیم فوروارد ندارد. Xray مستقیماً روی IP TUN سرور
(`10.100.100.1`) گوش می‌دهد. بخش `forwarding` روی سرورها بی‌تأثیر است.

---

## مدیریت با `spoofctl`

```
spoofctl [دستور]
```

| دستور | توضیح |
|-------|-------|
| `status` | نمایش وضعیت سرویس، آمار ترافیک، پورت‌های فوروارد، وضعیت NAT |
| `start` | شروع سرویس |
| `stop` | توقف سرویس |
| `restart` | راه‌اندازی مجدد |
| `edit-config` | باز کردن `config.yaml` در ویرایشگر |
| `spoof-ips` | به‌روزرسانی لیست IP‌های جعلی |
| `forward-rules` | به‌روزرسانی پورت‌های فوروارد و اعمال مجدد قوانین (فقط کلاینت) |
| `update` | دانلود و نصب آخرین نسخه (با rollback خودکار در صورت خطا) |
| `rollback` | بازگشت به نسخه قبلی |
| `uninstall` | حذف کامل از سیستم |

اگر بدون آرگومان اجرا شود، منوی تعاملی نمایش می‌دهد:

```
  ─────────────────────────────────────────────────────
  spoofctl — service: active
  ─────────────────────────────────────────────────────
   1) Status
   2) Start
   3) Stop
   4) Restart
   5) Edit Config
   6) Change Spoof IPs
   7) Forwarding Rules
   8) Update
   9) Rollback
  10) Uninstall
  11) Exit
```

---

## آپدیت

```bash
spoofctl update
```

یا با نسخه مشخص:

```bash
sudo INSTALL_TAG=v6.1.0 bash scripts/install.sh
```

---

## مانیتورینگ

```bash
journalctl -u spoof-tunnel -f          # لاگ زنده
cat /run/spoof-tunnel/health.json      # متریک‌های JSON
/usr/local/lib/spoof-tunnel/status.sh  # وضعیت قابل خواندن
```

متریک‌های `health.json`:
- `tx_pps` / `rx_pps`: پکت در ثانیه
- `loss_pct`: درصد از دست رفتن پکت (بر اساس شماره سکوانس)
- `active_spoof`: IP جعلی فعال
- `up`: ۱ اگر سالم، ۰ اگر مشکل دارد

---

## عیب‌یابی سریع

```bash
# وضعیت کلی
spoofctl status

# لاگ اخیر
journalctl -u spoof-tunnel -n 50

# آزمایش اتصال تونل
ping 10.100.100.1    # از سمت کلاینت، به IP tun0 سرور

# بررسی iptables
iptables -L INPUT -n | grep 2080
iptables -t nat -L PREROUTING -n

# بررسی rp_filter
sysctl net.ipv4.conf.all.rp_filter
```

برای مشکلات بیشتر، [`docs/troubleshooting.md`](docs/troubleshooting.md) را ببینید.

---

## مستندات

- [`docs/architecture.md`](docs/architecture.md) — معماری دقیق و جریان پکت
- [`docs/spoofing.md`](docs/spoofing.md) — نحوه عملکرد IP Spoofing
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — مشکلات رایج و راه‌حل‌ها
- [`docs/faq.md`](docs/faq.md) — سوالات متداول

---

## لایسنس

MIT — فایل [LICENSE](LICENSE) را ببینید.
