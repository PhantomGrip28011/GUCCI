# GUCCI

راه‌اندازی پنل **3x-ui** با داکر — **پنل و لینک ساب با هم روی یک پورت واحد** (پیش‌فرض `2053`) بالا می‌آیند.

## معماری

```
                   ┌──  /        →  پنل وب        (داخلی 127.0.0.1:2053)
nginx (پورت 2053) ──┤
                   └──  /sub/    →  سرویس ساب     (داخلی 127.0.0.1:2096)
```

- از بیرون **فقط همین یک پورت** باز است؛ پنل و سرویس ساب فقط داخل کانتینر روی لوک‌بک گوش می‌دهند.
- nginx همیشه روی پورت ثابت `2053` گوش می‌دهد و اگر پلتفرم (مثل Railway) متغیر `PORT` با عدد متفاوتی تزریق کند، **روی آن هم هم‌زمان گوش می‌دهد** — پس با هر تنظیم Target Port بالا می‌آید.
- لینک ساب دقیقاً با **همان آدرس پنل** کار می‌کند — مثل ریپوی x4gKing — و برای همه‌ی نسخه‌های 3x-ui جواب است چون وابسته به نسخه نیست (فقط تقسیم ترافیک روی پورت‌هاست).

## آدرس‌ها

| سرویس | آدرس |
|---|---|
| پنل | `https://دامنه‌شما/` |
| صفحه و لینک ساب | `https://دامنه‌شما/sub/<SubID>` |
| ساب JSON (اگر روشن کنید) | `https://دامنه‌شما/json/<SubID>` |

> 🔑 لاگین پیش‌فرض نصب تازه: `admin / admin` — بلافاصله عوضش کنید!

## متغیر PUBLIC_URL

در **Railway / Render / Koyeb** نیازی به کاری نیست — دامنه عمومی به‌صورت خودکار از متغیرهای خود پلتفرم (`RAILWAY_PUBLIC_DOMAIN` و ...) خوانده می‌شود و لینک‌های ساب با همان ساخته می‌شوند.

اگر جای دیگری (مثلاً VPS) اجرا می‌کنید، خودتان ست کنید (بدون `/` آخر):

```
PUBLIC_URL=http://YOUR_IP:2053
```

یا از داخل پنل: **Settings → Subscription → Sub URI** را با همان دامنه پر کنید.

## دیپلوی روی Railway / Render / Koyeb

1. ریپو را وصل کنید (Deploy from Git — نوع Docker).
2. پورت عمومی (Target Port): `2053` — حتی اگر متغیر `PORT` پلتفرم عدد دیگری باشد، هر دو پوشش داده می‌شوند و بالا می‌آید.
3. برای ماندگاری تنظیمات بعد از Redeploy، یک Volume به مسیر `/etc/x-ui` وصل کنید.

## اجرا روی VPS

```bash
docker build -t gucci .
docker run -d --name gucci \
  -p 2053:2053 \
  -v x-ui-db:/etc/x-ui \
  -e PUBLIC_URL="http://YOUR_IP:2053" \
  --restart always gucci
```

پنل: `http://YOUR_IP:2053/` و ساب: `http://YOUR_IP:2053/sub/<SubID>`

## ⚠️ نکات

- از داخل پنل **پورت پنل، Web Base Path و Sub Path (`/sub/`) را تغییر ندهید** — این ایمیج آن‌ها را خودش مدیریت می‌کند و مسیرها به nginx وابسته‌اند.
- پورت‌های 2053 و 2096 فقط داخلی هستند؛ سرویسی از بیرون به آن‌ها دسترسی ندارد.

## لینک ساب (نسخه کارخانه‌ساز `/sub/`) + راه‌اندازی `/subfix/gucci`

- اینباند به‌خاطر اتصال به نود مبدأ (سرور قبلی)، مسیر پیش‌فرض `/sub/<subId>` آدرس قدیمی نود را نشان می‌دهد (محدودیت 3x-ui برای inboundهای node-linked — باگ سرویس ما نیست).
- **راه‌حل:** فید اشتراک همیشه-درست روی `https://دامنه/subfix/gucci` سرو می‌شود — همان لینک‌های VLESS+Reality با آدرس بدرستی TCP Proxy ریلی.
- لینک‌های modal پنل (دکمه کپی/QR کنار کلاینت) هم با `externalProxy` روی اینباند، آدرس درست پروکسی را می‌سازند.
- اگر پروکسی ریلی عوض شد (delete/create جدید)، `SUBFIX_B64` داخل `entrypoint.sh` را با base64 لینک‌های جدید به‌روزرسانی کنید و redeploy.

## 🕵️ Hidden panel + black splash (current setup)

- Panel opens ONLY at: **`https://<domain>/gucciBMW/`** (secret path — undiscoverable)
- Root `/` and every unknown path return a **plain BLACK page** (HTTP 200), never a railway error
- Subscription stays at: **`https://<domain>/sub/<subId>`** (short form `/<subId>` also works)
- Panel image pinned to **v2.9.0** (wide client compatibility incl. older Android cores)

> To change the secret path, edit `PANEL_PATH` in entrypoint (`-webBasePath`) **and** the two
> `location` blocks in `nginx.conf.template`, then push.

## Final architecture (Aug 2026)
- Panel: hidden at `/gucciBMW/` (everything else = pure black page), pinned v2.9.0
- Sub links (classic form): `https://vipermatrix7862.cc.cd:2096/sub/<id>`
  - Custom domain on Railway → Cloudflare (orange cloud) → Origin Rule rewrites
    any visitor port to origin :443 (CF's same-port default otherwise 522s on :2096)
  - entrypoint pins `SUB_URI` so the panel always advertises this base
- Link stability: entrypoint clears stale `hosts` rows + sub feed serves the live
  Railway TCP-proxy endpoint; telegram proxy via zephyr.proxy.rlwy.net:57073
