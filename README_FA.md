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
spoofctl forward list        # پورت‌های تنظیم‌شده و قوانین زنده‌ی iptables
spoofctl forward add 8443    # افزودن یک پورت بدون دست‌زدن به بقیه
spoofctl forward del 8443    # حذف یک پورت ('all' همه‌ی قوانین را پاک می‌کند)
spoofctl forward replace 443,80   # جایگزینی کل لیست
spoofctl forward apply       # اعمال مجدد قوانین بعد از flush دستی iptables
```

`add` و `del` لیست جداشده با کاما هم می‌پذیرند (`forward add 8443,2053`) و
بلافاصله iptables را تغییر می‌دهند — بدون restart سرویس. هر تغییر هم در
`tunnel.env` و هم در `config.yaml` نوشته می‌شود تا بعد از نصب مجدد باقی بماند.
اگر زیردستور را بدون آرگومان اجرا کنی، پورت‌ها را از تو می‌پرسد.

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
| `list` | نمایش همه‌ی تانل‌های تنظیم‌شده به‌صورت شماره‌دار |
| `spoof-ips` | به‌روزرسانی لیست IP‌های جعلی |
| `forward list\|add\|del\|replace\|apply` | مدیریت پورت‌های فوروارد (فقط کلاینت) |
| `create [NAME]` | ساخت تانل جدید با ویزارد |
| `delete [NAME]` | حذف یک تانل، بدون دست‌زدن به بقیه و به خود اسکریپت |
| `migrate [NAME]` | تبدیل هاست تک‌تانله به ساختار نام‌دار |
| `update` | دانلود و نصب آخرین نسخه (با rollback خودکار در صورت خطا) |
| `rollback` | بازگشت به نسخه قبلی |
| `uninstall` | حذف کامل از سیستم |

`forward-rules` به‌عنوان نام مستعار `forward replace` باقی مانده است.

## چند تانل روی یک هاست

یک هاست می‌تواند هم‌زمان چند تانل داشته باشد — مثلاً یک سرور ایران که از روی
همان کارت شبکه به چند سرور خارجی مختلف وصل است. هر تانل یک instance نام‌دار
است با کانفیگ، یونیت systemd، دیوایس TUN و قوانین فوروارد مخصوص خودش:

| | |
|---|---|
| کانفیگ | `/etc/spoof-tunnel/tunnels/<name>.yaml` |
| env | `/etc/spoof-tunnel/tunnels/<name>.env` |
| یونیت | `spoof-tunnel@<name>.service` |
| runtime | `/run/spoof-tunnel/<name>/health.json` |
| متریک | `/var/log/spoof-tunnel/<name>/metrics.jsonl` |

```bash
spoofctl create de1            # افزودن یک تانل
spoofctl list                  # جدول شماره‌دار همه‌ی تانل‌ها
spoofctl status de1            # یا: spoofctl status -t de1
spoofctl forward add 8443 -t de1
spoofctl delete de1            # فقط de1؛ بقیه دست‌نخورده کار می‌کنند
```

دستورهایی که روی یک تانل کار می‌کنند، نام آن را یا به‌صورت موقعیتی می‌گیرند یا
با `-t NAME`. اگر فقط یک تانل باشد نام اختیاری است. اگر چند تا باشد و نام
ندهی، یک انتخاب‌گر شماره‌دار باز می‌شود:

```
  Which tunnel?
   #  NAME         ROLE    PEER                     TUN     SERVICE  FORWARDED
   1  de1          client  198.51.100.7:2081        tun1    active   8443
   2  main         client  203.0.113.9:2080         tun0    active   443,80
  Choice [1-2]:
```

### چیزهایی که تانل‌ها نباید مشترک داشته باشند

نصب‌کننده کانفیگی را که `tun_name`، `listen_port`، جفت IP داخلی TUN یا یک پورت
فوروارد را از تانل دیگری تکرار کند رد می‌کند. همین تضمین است که تانل‌ها را
مستقل نگه می‌دارد: قوانین DNAT بر اساس پورت و قوانین FORWARD/MASQUERADE بر
اساس دیوایس TUN ساخته می‌شوند، پس حذف یک تانل نمی‌تواند به تانل دیگر آسیب
بزند. ویزارد هم پیش‌فرض‌ها را از بین مقادیر آزاد انتخاب می‌کند، پس می‌توانی
همه‌ی پیش‌فرض‌ها را بپذیری و کانفیگ سالم بگیری.

### تنها چیزی که واقعاً مشترک است

‏`fq` مربوط به کارت شبکه‌ی فیزیکی است نه به تانل. وقتی چند تانل روی یک
اینترفیس هستند، هوک qdisc **بیشترین** `flow_limit` بین آن‌ها را اعمال می‌کند،
نه مقدار آخرین تانلی که استارت شده؛ پس نتیجه به ترتیب استارت وابسته نیست.
خروجی `spoofctl status` هم همین را توضیح می‌دهد و لاگ qdisc به‌ازای هر
اینترفیس نوشته می‌شود (`/var/log/spoof-tunnel/qdisc-<iface>.log`) نه هر تانل.

### مهاجرت هاستی که از قبل یک تانل دارد

هاست‌هایی که قبل از پشتیبانی چندتانله نصب شده‌اند دست‌نخورده کار می‌کنند —
‏`spoofctl update` آن‌ها را تبدیل نمی‌کند و تانل روی همان `spoof-tunnel.service`
می‌ماند. هر وقت خودت خواستی:

```bash
spoofctl migrate        # به‌صورت پیش‌فرض اسمش را 'main' می‌گذارد
```

‏`migrate` اول از کانفیگ و env و یونیت اسنپ‌شات می‌گیرد، بعد به
`spoof-tunnel@<name>` سوییچ می‌کند. تانل یک بار restart می‌شود. اگر بالا نیامد،
همه‌چیز برگردانده می‌شود و یونیت قبلی دوباره استارت می‌شود؛ یعنی مهاجرت ناموفق
تانل را قطع نمی‌گذارد. یونیت قدیمی هم به‌صورت
`spoof-tunnel.service.pre-migrate` نگه داشته می‌شود.

دستور `spoofctl create` روی هاست مهاجرت‌نکرده اجرا نمی‌شود و به همین‌جا ارجاع
می‌دهد، تا هیچ‌وقت دو ساختار هم‌زمان وجود نداشته باشند.

### حذف تانل

دستور `spoofctl delete` تانل تنظیم‌شده روی این هاست را برمی‌دارد، بدون اینکه
چیزی را از سیستم حذف کند:

- سرویس را stop و disable می‌کند (و تایمر Prometheus را اگر فعال باشد)
- تمام قوانین iptables متعلق به تانل را پاک می‌کند — DNAT و FORWARD و
  MASQUERADE مربوط به port forwarding، و همچنین قانون `INPUT ... -j DROP`
  که `spoof-tunnel-prepare` روی پورت UDP بیرونی می‌گذارد
- دیوایس TUN را حذف می‌کند
- از `config.yaml` و `tunnel.env` در مسیر
  `/var/backups/spoof-tunnel/deleted-<timestamp>/` بکاپ می‌گیرد و بعد پاکشان می‌کند

باینری، `spoofctl`، هوک‌های libexec و لاگ‌ها سر جایشان می‌مانند، پس بلافاصله
می‌توانی با `spoofctl create` یک تانل جدید بسازی. برای حذف کامل خود اسکریپت از
`spoofctl uninstall` استفاده کن.

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
   7) Port Forwarding...
   8) List Tunnels
   9) Switch Tunnel
  10) Create Tunnel
  11) Delete Tunnel
  12) Migrate to multi-tunnel layout
  13) Update
  14) Rollback
  15) Uninstall
  16) Exit
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
